import OverlandCore
import Foundation
import SwiftUI
import ServiceManagement
import Combine

public enum NavigationTab: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case gateways = "Gateways"
    case logs = "Activity Logs"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .connection: return "shield.lefthalf.filled"
        case .gateways: return "network"
        case .logs: return "list.bullet.rectangle"
        }
    }
}

/// Persistence hooks so tests can run without touching real UserDefaults or
/// the login Keychain.
public struct VpnViewModelStorage: @unchecked Sendable {
    public var defaults: UserDefaults
    public var loadPassword: @Sendable (String) -> String?
    public var savePassword: @Sendable (String, String) throws -> Void
    public var deletePassword: @Sendable (String) throws -> Void

    public init(
        defaults: UserDefaults = .standard,
        loadPassword: @escaping @Sendable (String) -> String? = { KeychainService.shared.getPassword(for: $0) },
        savePassword: @escaping @Sendable (String, String) throws -> Void = { try KeychainService.shared.savePassword($0, for: $1) },
        deletePassword: @escaping @Sendable (String) throws -> Void = { try KeychainService.shared.deletePassword(for: $0) }
    ) {
        self.defaults = defaults
        self.loadPassword = loadPassword
        self.savePassword = savePassword
        self.deletePassword = deletePassword
    }

    /// Isolated, non-persisting storage for tests.
    public static func ephemeral(suiteName: String = "Overland.tests.\(UUID().uuidString)") -> VpnViewModelStorage {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vault = PasswordVault()
        return VpnViewModelStorage(
            defaults: defaults,
            loadPassword: { vault.get($0) },
            savePassword: { vault.set($0, for: $1) },
            deletePassword: { vault.remove($0) }
        )
    }
}

final class PasswordVault: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]
    func get(_ account: String) -> String? { lock.withLock { store[account] } }
    func set(_ password: String, for account: String) { lock.withLock { store[account] = password } }
    func remove(_ account: String) { lock.withLock { store[account] = nil } }
}

@MainActor
public final class VpnViewModel: ObservableObject {
    public static let shared = VpnViewModel()

    @Published public var state: VpnState = .disconnected
    @Published public var profile: ConnectionProfile
    @Published public var password: String = ""
    @Published public var rememberPassword: Bool = true
    @Published public var logs: [LogEntry] = []
    @Published public var metrics: SessionMetrics = SessionMetrics()
    @Published public var useMockBridge: Bool
    @Published public var launchAtLogin: Bool = false
    @Published public var statusMessage: String?
    @Published public var selectedTab: NavigationTab = .connection
    @Published public var customBinaryPath: String = ""
    @Published public var isDiscoveringGateways: Bool = false
    @Published public var manualAuthURL: String?
    @Published public var resolvedGpclientPath: String?
    @Published public var resolvedGpauthPath: String?
    /// Progress through a connection attempt; nil when not connecting.
    @Published public var connectPhase: ConnectPhase?
    /// gpauth's local sign-in page while it waits for the browser.
    @Published public var signInURL: String?
    /// The last failure, classified for display.
    @Published public var failure: ConnectionFailure?
    /// Per-second throughput samples (bytes/s) while connected, newest last.
    @Published public var throughputHistory: [ThroughputSample] = []
    /// Run without a Dock icon; the window opens from the menu bar.
    @Published public var menuBarOnly: Bool
    /// `gpclient --version` output, for About.
    @Published public var backendVersion: String?
    /// First run: no portal has been saved yet.
    @Published public var needsSetup: Bool
    @Published public var resolvedVpncScriptPath: String?

    public var gateways: [Gateway] {
        get { profile.knownGateways }
        set { profile.knownGateways = newValue }
    }

    public let helperManager: HelperManager

    private var bridge: BridgeServiceProtocol
    private let mockBridge: MockBridgeService
    private let liveBridge: GpclientBridgeService
    private let storage: VpnViewModelStorage
    private let statsReader: InterfaceStatsReader
    private var metricsTimer: Timer?
    private var eventTask: Task<Void, Never>?
    private var callbackObserver: NSObjectProtocol?
    private var baselineCounters: InterfaceStatsReader.Counters?

    private let profileDefaultsKey = "Overland.ConnectionProfile"
    private let useMockKey = "Overland.UseMockBridge"
    private let customBinaryKey = "Overland.CustomBinaryPath"
    private let menuBarOnlyKey = "Overland.MenuBarOnly"
    private let setupDoneKey = "Overland.SetupCompleted"
    private var lastCounters: InterfaceStatsReader.Counters?
    private var lastSampleAt: Date?

    public init(
        bridge: BridgeServiceProtocol? = nil,
        storage: VpnViewModelStorage = VpnViewModelStorage(),
        statsReader: InterfaceStatsReader = InterfaceStatsReader(),
        mockBridge: MockBridgeService = MockBridgeService(),
        liveBridge: GpclientBridgeService? = nil,
        helperManager: HelperManager = HelperManager()
    ) {
        self.storage = storage
        self.statsReader = statsReader
        self.mockBridge = mockBridge
        self.helperManager = helperManager

        let defaults = storage.defaults
        let storedMock = defaults.object(forKey: useMockKey) as? Bool ?? false
        self.useMockBridge = storedMock

        if let data = defaults.data(forKey: profileDefaultsKey),
           let saved = try? JSONDecoder().decode(ConnectionProfile.self, from: data) {
            self.profile = saved
        } else {
            self.profile = .default
        }

        let customPath = defaults.string(forKey: customBinaryKey) ?? ""
        self.customBinaryPath = customPath
        self.menuBarOnly = defaults.bool(forKey: menuBarOnlyKey)
        let savedProfile = defaults.data(forKey: profileDefaultsKey) != nil
        self.needsSetup = !(defaults.bool(forKey: setupDoneKey) || savedProfile)
        self.liveBridge = liveBridge ?? GpclientBridgeService(
            customGpclientPath: customPath.isEmpty ? nil : customPath,
            privilegedRunnerFactory: helperManager.privilegedRunnerFactory(),
            helperAttach: helperManager.helperAttach()
        )

        if let bridge {
            self.bridge = bridge
        } else {
            self.bridge = storedMock ? self.mockBridge : self.liveBridge
        }

        if !self.profile.username.isEmpty,
           let storedPass = storage.loadPassword(self.profile.username) {
            self.password = storedPass
            self.rememberPassword = true
        }

        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        subscribeToBridge()
        observeAuthCallbacks()
        refreshResolvedPaths()
        fetchBackendVersion()
    }

    public func completeSetup() {
        needsSetup = false
        storage.defaults.set(true, forKey: setupDoneKey)
        saveProfile()
    }

    public func setMenuBarOnly(_ enabled: Bool) {
        menuBarOnly = enabled
        storage.defaults.set(enabled, forKey: menuBarOnlyKey)
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func fetchBackendVersion() {
        Task {
            guard let path = await liveBridge.resolvedGpclientPath() else { return }
            let result = try? await ProcessRunner().run(CommandLine(executable: path, arguments: ["--version"]))
            if let out = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
                self.backendVersion = out.replacingOccurrences(of: "gpclient ", with: "")
            }
        }
    }

    isolated deinit {
        eventTask?.cancel()
        metricsTimer?.invalidate()
        if let callbackObserver {
            NotificationCenter.default.removeObserver(callbackObserver)
        }
    }

    // MARK: - Configuration

    public func setUseMockBridge(_ mock: Bool) {
        guard mock != useMockBridge || (mock ? bridge !== mockBridge : bridge !== liveBridge) else { return }
        useMockBridge = mock
        storage.defaults.set(mock, forKey: useMockKey)
        bridge = mock ? mockBridge : liveBridge
        subscribeToBridge()
    }

    public func setCustomBinaryPath(_ path: String) {
        customBinaryPath = path
        storage.defaults.set(path, forKey: customBinaryKey)
        Task {
            await liveBridge.setCustomGpclientPath(path.isEmpty ? nil : path)
            refreshResolvedPaths()
        }
    }

    public func refreshResolvedPaths() {
        let custom = profile.vpncScriptPath
        Task {
            let gp = await liveBridge.resolvedGpclientPath()
            let auth = await liveBridge.resolvedGpauthPath()
            let script = await liveBridge.resolvedVpncScriptPath(custom: custom)
            self.resolvedGpclientPath = gp
            self.resolvedGpauthPath = auth
            self.resolvedVpncScriptPath = script
        }
    }

    public func saveProfile() {
        if let data = try? JSONEncoder().encode(profile) {
            storage.defaults.set(data, forKey: profileDefaultsKey)
        }
        if rememberPassword, !profile.username.isEmpty, !password.isEmpty {
            try? storage.savePassword(password, profile.username)
        } else if !rememberPassword, !profile.username.isEmpty {
            try? storage.deletePassword(profile.username)
        }
    }

    /// Forget the configured connection and return to first-run setup.
    public func resetProfile() {
        if !profile.username.isEmpty {
            try? storage.deletePassword(profile.username)
        }
        profile = .default
        password = ""
        saveProfile()
        storage.defaults.removeObject(forKey: setupDoneKey)
        needsSetup = true
    }

    // MARK: - Bridge events

    private func subscribeToBridge() {
        eventTask?.cancel()
        let currentBridge = bridge

        eventTask = Task { [weak self] in
            let stream = await currentBridge.events()
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .log(let entry):
            appendLog(entry)
        case .state(let newState):
            updateState(newState)
        case .gateways(let discovered):
            mergeGateways(discovered)
        case .manualAuthURL(let url):
            manualAuthURL = url
        case .signInURL(let url):
            signInURL = url
        case .phase(let phase):
            connectPhase = phase
        }
    }

    public func reopenSignInPage() {
        if let url = signInURL.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
    }

    private func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > 5000 {
            logs.removeFirst(1000)
        }
    }

    /// Replace discovered gateways while keeping the user's manual entries.
    public func mergeGateways(_ discovered: [Gateway]) {
        guard !discovered.isEmpty else { return }
        let manual = profile.knownGateways.filter { existing in
            existing.isManual && !discovered.contains(where: { $0.server == existing.server })
        }
        profile.knownGateways = discovered.sorted { $0.priority < $1.priority } + manual
        saveProfile()
    }

    private func updateState(_ newState: VpnState) {
        let wasConnected = state.isConnected
        state = newState
        switch newState {
        case .connected(let details):
            statusMessage = nil
            failure = nil
            manualAuthURL = nil
            signInURL = nil
            connectPhase = nil
            if !wasConnected {
                startMetricsTimer(interface: details.interfaceName, connectedAt: details.connectedAt)
            }
        case .disconnected:
            stopMetricsTimer()
            metrics = SessionMetrics()
            manualAuthURL = nil
            signInURL = nil
            connectPhase = nil
        case .failed(let msg):
            stopMetricsTimer()
            metrics = SessionMetrics()
            statusMessage = msg
            failure = ConnectionFailure.classify(msg)
            manualAuthURL = nil
            signInURL = nil
            connectPhase = nil
        case .connecting:
            failure = nil
            if connectPhase == nil { connectPhase = .signIn }
        case .disconnecting:
            break
        }
    }

    // MARK: - Actions

    public func toggleConnection() {
        if state.isConnected || state.isConnecting {
            disconnect()
        } else {
            connect()
        }
    }

    public func connect() {
        guard !state.isBusy else { return }
        statusMessage = nil
        failure = nil
        connectPhase = GpclientCommandBuilder.needsBrowserAuth(profile) ? .signIn : (helperManager.isUsable ? .tunnel : .authorize)
        saveProfile()

        let profile = self.profile
        let password = self.password.isEmpty ? nil : self.password
        Task {
            do {
                try await self.bridge.connect(profile: profile, password: password)
            } catch {
                self.statusMessage = error.localizedDescription
                self.appendLog(LogEntry(level: .error, message: "Connection error: \(error.localizedDescription)"))
                if !self.state.isConnected {
                    self.updateState(.failed(message: error.localizedDescription))
                }
            }
        }
    }

    public func disconnect() {
        Task {
            do {
                try await self.bridge.disconnect()
            } catch {
                self.appendLog(LogEntry(level: .error, message: "Disconnect error: \(error.localizedDescription)"))
            }
        }
    }

    public func refreshGateways() {
        guard !isDiscoveringGateways, !state.isBusy else { return }
        isDiscoveringGateways = true
        saveProfile()

        let profile = self.profile
        let password = self.password.isEmpty ? nil : self.password
        Task {
            defer { self.isDiscoveringGateways = false }
            do {
                let list = try await self.bridge.discoverGateways(profile: profile, password: password)
                self.mergeGateways(list)
                if list.isEmpty {
                    self.appendLog(LogEntry(level: .warn, message: "The portal did not list any gateways"))
                }
            } catch {
                self.statusMessage = error.localizedDescription
                self.appendLog(LogEntry(level: .warn, message: "Failed to fetch gateways: \(error.localizedDescription)"))
            }
        }
    }

    public func addManualGateway(name: String, server: String) {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !profile.knownGateways.contains(where: { $0.server == trimmed }) else { return }
        let gw = Gateway(name: name.isEmpty ? trimmed : name, server: trimmed, priority: 99, isManual: true)
        profile.knownGateways.append(gw)
        saveProfile()
    }

    public func removeGateway(_ gateway: Gateway) {
        profile.knownGateways.removeAll { $0.server == gateway.server }
        if profile.selectedGatewayServer == gateway.server {
            profile.selectedGatewayServer = nil
        }
        saveProfile()
    }

    public func selectGateway(_ server: String?) {
        profile.selectedGatewayServer = server
        saveProfile()
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func dismissFailure() {
        failure = nil
        statusMessage = nil
        if case .failed = state {
            state = .disconnected
        }
    }

    public var logsAsText: String {
        logs.map { "[\($0.formattedTimestamp)] [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
    }

    public func copyLogsToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logsAsText, forType: .string)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            self.launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            self.appendLog(LogEntry(level: .error, message: "Failed to update launch at login: \(error.localizedDescription)"))
        }
    }

    /// Called once the UI is up: re-attaches to a tunnel a previous process
    /// left running, otherwise honors the profile's auto-connect flag.
    public func handleLaunch() {
        helperManager.refresh()
        Task {
            let adopted = await self.bridge.adoptOrphanedSession()
            if !adopted, self.profile.autoConnect, !self.profile.portal.isEmpty, self.state.isDisconnected {
                self.connect()
            }
        }
    }

    /// Whether quitting now would leave a tunnel behind.
    public var hasActiveSession: Bool {
        state.isConnected || state.isConnecting
    }

    /// Tear the tunnel down before the process exits, waiting up to
    /// `timeout` for gpclient to finish so routes and DNS are restored.
    public func prepareForTermination(timeout: TimeInterval = 10) async {
        guard hasActiveSession else { return }
        appendLog(LogEntry(level: .info, message: "Quitting: disconnecting the VPN first"))
        await disconnectAndWait(timeout: timeout)
    }

    /// Disconnect and wait (bounded) for gpclient to finish tearing down.
    public func disconnectAndWait(timeout: TimeInterval = 10) async {
        guard hasActiveSession else { return }
        disconnect()
        let deadline = Date().addingTimeInterval(timeout)
        while !state.isDisconnected, Date() < deadline {
            if case .failed = state { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Remove the privileged helper's background item. Disconnects first if
    /// a tunnel is up (the helper owns it), then unregisters with launchd.
    /// Until it is enabled again, connecting uses the administrator dialog.
    public func uninstallHelper() async {
        if hasActiveSession {
            appendLog(LogEntry(level: .info, message: "Uninstalling the helper: disconnecting the VPN first"))
            await disconnectAndWait()
        }
        await helperManager.disable()
        if helperManager.status == .notRegistered {
            appendLog(LogEntry(level: .info, message: "Privileged helper uninstalled; the administrator dialog will be used until it is enabled again"))
        } else if let error = helperManager.lastError {
            appendLog(LogEntry(level: .error, message: "Could not uninstall the helper: \(error)"))
        }
    }

    // MARK: - Browser callback

    private func observeAuthCallbacks() {
        callbackObserver = NotificationCenter.default.addObserver(
            forName: .overlandAuthCallbackReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?["authData"] as? String else { return }
            Task { @MainActor in
                self?.deliverAuthCallback(data)
            }
        }
    }

    public func deliverAuthCallback(_ data: String) {
        Task {
            do {
                try await self.bridge.deliverAuthCallback(data)
            } catch {
                self.appendLog(LogEntry(level: .error, message: error.localizedDescription))
            }
        }
    }

    // MARK: - Metrics

    private func startMetricsTimer(interface: String?, connectedAt: Date) {
        metricsTimer?.invalidate()
        baselineCounters = interface.flatMap { statsReader.counters(for: $0) }
        lastCounters = baselineCounters
        lastSampleAt = Date()
        throughputHistory = []
        metrics = SessionMetrics()
        refreshMetrics(interface: interface, connectedAt: connectedAt)

        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMetrics(interface: interface, connectedAt: connectedAt)
            }
        }
    }

    public func refreshMetrics(interface: String?, connectedAt: Date) {
        guard state.isConnected else { return }
        var updated = metrics
        updated.duration = Date().timeIntervalSince(connectedAt)

        if let interface, let counters = statsReader.counters(for: interface) {
            let base = baselineCounters ?? counters
            updated.bytesReceived = counters.bytesIn &- base.bytesIn
            updated.bytesSent = counters.bytesOut &- base.bytesOut
            updated.packetsReceived = counters.packetsIn &- base.packetsIn
            updated.packetsSent = counters.packetsOut &- base.packetsOut

            let now = Date()
            if let last = lastCounters, let lastAt = lastSampleAt {
                let seconds = max(now.timeIntervalSince(lastAt), 0.001)
                let sample = ThroughputSample(
                    time: now,
                    bytesInPerSecond: Double(counters.bytesIn &- last.bytesIn) / seconds,
                    bytesOutPerSecond: Double(counters.bytesOut &- last.bytesOut) / seconds
                )
                throughputHistory.append(sample)
                if throughputHistory.count > 120 {
                    throughputHistory.removeFirst(throughputHistory.count - 120)
                }
            }
            lastCounters = counters
            lastSampleAt = now
        }
        metrics = updated
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        baselineCounters = nil
        lastCounters = nil
        lastSampleAt = nil
        throughputHistory = []
    }
}

public struct ThroughputSample: Identifiable, Equatable, Sendable {
    public var id: Date { time }
    public var time: Date
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
}
