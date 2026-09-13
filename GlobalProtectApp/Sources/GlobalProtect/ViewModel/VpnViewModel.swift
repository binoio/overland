import GlobalProtectCore
import Foundation
import SwiftUI
import ServiceManagement
import Combine

public enum NavigationTab: String, CaseIterable, Identifiable {
    case connection = "Connection"
    case gateways = "Gateways"
    case logs = "Activity Logs"
    case settings = "Settings"
    case about = "About"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .connection: return "shield.lefthalf.filled"
        case .gateways: return "network"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        case .about: return "info.circle"
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
    public static func ephemeral(suiteName: String = "GlobalProtect.tests.\(UUID().uuidString)") -> VpnViewModelStorage {
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
    @Published public var resolvedVpncScriptPath: String?

    public var gateways: [Gateway] {
        get { profile.knownGateways }
        set { profile.knownGateways = newValue }
    }

    private var bridge: BridgeServiceProtocol
    private let mockBridge: MockBridgeService
    private let liveBridge: GlobalProtectBridgeService
    private let storage: VpnViewModelStorage
    private let statsReader: InterfaceStatsReader
    private var metricsTimer: Timer?
    private var eventTask: Task<Void, Never>?
    private var callbackObserver: NSObjectProtocol?
    private var baselineCounters: InterfaceStatsReader.Counters?

    private let profileDefaultsKey = "GlobalProtect.ConnectionProfile"
    private let useMockKey = "GlobalProtect.UseMockBridge"
    private let customBinaryKey = "GlobalProtect.CustomBinaryPath"

    public init(
        bridge: BridgeServiceProtocol? = nil,
        storage: VpnViewModelStorage = VpnViewModelStorage(),
        statsReader: InterfaceStatsReader = InterfaceStatsReader(),
        mockBridge: MockBridgeService = MockBridgeService(),
        liveBridge: GlobalProtectBridgeService? = nil
    ) {
        self.storage = storage
        self.statsReader = statsReader
        self.mockBridge = mockBridge

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
        self.liveBridge = liveBridge ?? GlobalProtectBridgeService(customGpclientPath: customPath.isEmpty ? nil : customPath)

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

    public func resetProfile() {
        profile = .default
        password = ""
        saveProfile()
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
            manualAuthURL = nil
            if !wasConnected {
                startMetricsTimer(interface: details.interfaceName, connectedAt: details.connectedAt)
            }
        case .disconnected:
            stopMetricsTimer()
            metrics = SessionMetrics()
            manualAuthURL = nil
        case .failed(let msg):
            stopMetricsTimer()
            metrics = SessionMetrics()
            statusMessage = msg
            manualAuthURL = nil
        case .connecting, .disconnecting:
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
                    self.state = .failed(message: error.localizedDescription)
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

    /// Called once the UI is up. Honors the profile's auto-connect flag.
    public func handleLaunch() {
        if profile.autoConnect, !profile.portal.isEmpty, state.isDisconnected {
            connect()
        }
    }

    // MARK: - Browser callback

    private func observeAuthCallbacks() {
        callbackObserver = NotificationCenter.default.addObserver(
            forName: .globalProtectAuthCallbackReceived,
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
        }
        metrics = updated
    }

    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        baselineCounters = nil
    }
}
