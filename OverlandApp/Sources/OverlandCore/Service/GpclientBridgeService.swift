import Foundation

public enum BridgeError: Error, LocalizedError, Equatable {
    case gpclientNotFound
    case gpauthNotFound
    case vpncScriptNotFound
    case portalMissing
    case alreadyBusy
    case authFailed(String)
    case privilegeDenied
    case tunnelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .gpclientNotFound:
            return "gpclient was not found. Build it with Scripts/build_gpclient.sh, install it with Homebrew, or set its path in Settings ▸ Backend."
        case .gpauthNotFound:
            return "gpauth was not found next to gpclient. Single Sign-On needs it; build it with Scripts/build_gpclient.sh."
        case .vpncScriptNotFound:
            return "vpnc-script was not found. OpenConnect needs it to configure routes and DNS; set its path in Settings ▸ Backend."
        case .portalMissing:
            return "Enter a portal address before connecting."
        case .alreadyBusy:
            return "A connection attempt is already in progress."
        case .authFailed(let reason):
            return reason
        case .privilegeDenied:
            return "Administrator authorization was cancelled or denied. The tunnel needs root to create the utun device."
        case .tunnelFailed(let reason):
            return reason
        }
    }
}

/// Drives the real `gpclient` / `gpauth` binaries.
///
/// For Single Sign-On profiles, `gpauth` first runs as the current user so
/// the browser, Keychain and the `globalprotectcallback:` URL handler all
/// behave normally; it prints a `SamlAuthResult` JSON line. That line (or,
/// for password/certificate profiles, the credentials) is then handed on
/// stdin to a privileged `gpclient connect <portal>`, which retrieves the
/// portal config, logs in to the gateway and keeps the tunnel up. Disconnect
/// sends SIGINT, which gpclient treats as a clean shutdown request.
///
/// Root comes from one of the `PrivilegeMode`s: the standard macOS
/// authorization dialog (`PrivilegedProcessRunner`), or `sudo`.
public actor GpclientBridgeService: BridgeServiceProtocol {
    public typealias RunnerFactory = @Sendable () -> any ProcessRunning
    /// Returns nil when `mode` is not usable right now (helper not approved,
    /// unsigned build); the bridge then falls back to the administrator dialog.
    public typealias PrivilegedRunnerFactory = @Sendable (PrivilegeMode) -> (any ProcessRunning)?
    public typealias OrphanScanner = @Sendable () -> [PrivilegedProcessRunner.OrphanSession]
    /// Produces a runner whose `run` re-attaches to the given orphan instead of launching anything.
    public typealias AdoptedRunnerFactory = @Sendable (PrivilegedProcessRunner.OrphanSession) -> any ProcessRunning
    /// A tunnel the privileged helper is already running; `runner.run` replays
    /// and streams its output, `arguments` is the gpclient argv it was given.
    public struct AttachedTunnel: Sendable {
        public var runner: any ProcessRunning
        public var arguments: [String]
        public init(runner: any ProcessRunning, arguments: [String]) {
            self.runner = runner
            self.arguments = arguments
        }
    }
    public typealias HelperAttach = @Sendable () async -> AttachedTunnel?

    private let bus = BridgeEventBus()
    private let parser = GpclientOutputParser()
    private let locator: BinaryLocator
    private let tunInspector: TunInterfaceInspector
    private let callbackForwarder: AuthCallbackForwarder
    private let makeRunner: RunnerFactory
    private let makePrivilegedRunner: PrivilegedRunnerFactory
    private let scanOrphans: OrphanScanner
    private let makeAdoptedRunner: AdoptedRunnerFactory
    private let attachToHelper: HelperAttach
    private let temporaryDirectory: URL
    private let disconnectGracePeriod: TimeInterval

    private var customGpclientPath: String?
    private(set) public var currentState: VpnState = .disconnected

    private var authRunner: (any ProcessRunning)?
    private var tunnelRunner: (any ProcessRunning)?
    private var tunnelTask: Task<Void, Never>?
    private var disconnectRequested = false
    private var activeDetails: ConnectedDetails?
    private var sessionLifetime: TimeInterval?

    public init(
        customGpclientPath: String? = nil,
        locator: BinaryLocator = BinaryLocator(),
        tunInspector: TunInterfaceInspector = TunInterfaceInspector(),
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        disconnectGracePeriod: TimeInterval = 8,
        runnerFactory: @escaping RunnerFactory = { ProcessRunner() },
        privilegedRunnerFactory: PrivilegedRunnerFactory? = nil,
        orphanScanner: @escaping OrphanScanner = { PrivilegedProcessRunner.findOrphans() },
        adoptedRunnerFactory: @escaping AdoptedRunnerFactory = { AdoptedSessionRunner(orphan: $0) },
        helperAttach: @escaping HelperAttach = { nil }
    ) {
        self.customGpclientPath = customGpclientPath
        self.locator = locator
        self.tunInspector = tunInspector
        self.temporaryDirectory = temporaryDirectory
        self.callbackForwarder = AuthCallbackForwarder(temporaryDirectory: temporaryDirectory)
        self.disconnectGracePeriod = disconnectGracePeriod
        self.makeRunner = runnerFactory
        self.makePrivilegedRunner = privilegedRunnerFactory ?? { mode in
            mode == .adminPrompt ? PrivilegedProcessRunner() : nil
        }
        self.scanOrphans = orphanScanner
        self.makeAdoptedRunner = adoptedRunnerFactory
        self.attachToHelper = helperAttach
    }

    public func setCustomGpclientPath(_ path: String?) {
        customGpclientPath = path
    }

    public func events() -> AsyncStream<BridgeEvent> {
        let stream = bus.stream()
        bus.send(.state(currentState))
        return stream
    }

    public func resolvedGpclientPath() -> String? {
        locator.resolveGpclient(custom: customGpclientPath)
    }

    public func resolvedGpauthPath() -> String? {
        locator.resolveGpauth(gpclientPath: resolvedGpclientPath())
    }

    public func resolvedVpncScriptPath(custom: String?) -> String? {
        locator.resolveVpncScript(custom: custom)
    }

    // MARK: - Event plumbing

    private func log(_ level: LogLevel, _ message: String) {
        bus.send(.log(LogEntry(level: level, message: message)))
    }

    private func setState(_ state: VpnState) {
        currentState = state
        bus.send(.state(state))
    }

    private func makeBuilder(profile: ConnectionProfile) throws -> GpclientCommandBuilder {
        guard let gpclient = locator.resolveGpclient(custom: customGpclientPath) else {
            throw BridgeError.gpclientNotFound
        }
        let gpauth = locator.resolveGpauth(gpclientPath: gpclient)
        if GpclientCommandBuilder.needsBrowserAuth(profile), gpauth == nil {
            throw BridgeError.gpauthNotFound
        }
        return GpclientCommandBuilder(
            gpclientPath: gpclient,
            gpauthPath: gpauth ?? "",
            tempDirectory: temporaryDirectory.path
        )
    }

    /// Resolve the vpnc-script into the profile so gpclient receives an
    /// explicit `--script`; its built-in search list does not cover custom
    /// Homebrew prefixes or the copy bundled with this app.
    private func withResolvedVpncScript(_ profile: ConnectionProfile) throws -> ConnectionProfile {
        var resolved = profile
        guard let script = locator.resolveVpncScript(custom: profile.vpncScriptPath) else {
            throw BridgeError.vpncScriptNotFound
        }
        resolved.vpncScriptPath = script
        return resolved
    }

    // MARK: - Unprivileged phases

    private struct UnprivilegedOutcome {
        var authResult: String?
        var authFailure: String?
        var gateways: [Gateway] = []
        var lastError: String?
        var result: ProcessResult
    }

    /// Run an unprivileged gpauth/gpclient command, streaming its log and
    /// collecting what the caller needs from it.
    private func runUnprivileged(_ command: CommandLine) async throws -> UnprivilegedOutcome {
        log(.debug, "Running: \(command.displayString)")

        let runner = makeRunner()
        authRunner = runner
        defer { authRunner = nil }

        let collector = OutputCollector()
        let bus = self.bus
        let parser = self.parser
        let stateSink: @Sendable (VpnState) -> Void = { [weak self] state in
            Task { await self?.setState(state) }
        }

        let result = try await runner.run(command) { _, line in
            for event in parser.parse(line: line) {
                switch event {
                case .log(let entry):
                    bus.send(.log(entry))
                case .authResult(let json):
                    collector.authResult = json
                case .authFailure(let message):
                    collector.authFailure = message
                case .gatewayDiscovered(let gateway):
                    collector.gateways.append(gateway)
                case .browserLaunched, .awaitingBrowser:
                    stateSink(.connecting(status: "Waiting for browser sign-in…"))
                case .manualAuthURL(let url):
                    bus.send(.manualAuthURL(url))
                    stateSink(.connecting(status: "Open the sign-in URL in a browser…"))
                case .authDataReceived:
                    stateSink(.connecting(status: "Browser sign-in received…"))
                case .fatalError(let message):
                    collector.lastError = message
                default:
                    break
                }
            }
        }

        return UnprivilegedOutcome(
            authResult: collector.authResult,
            authFailure: collector.authFailure,
            gateways: collector.gateways,
            lastError: collector.lastError,
            result: result
        )
    }

    /// Phase 1 for SSO profiles: returns the SamlAuthResult JSON line.
    private func runBrowserAuth(builder: GpclientCommandBuilder, profile: ConnectionProfile) async throws -> String {
        setState(.connecting(status: "Signing in to \(profile.portal)…"))
        let outcome = try await runUnprivileged(builder.browserAuthCommand(profile: profile))
        if let failure = outcome.authFailure {
            throw BridgeError.authFailed("Sign-in failed: \(failure)")
        }
        guard outcome.result.isSuccess, let json = outcome.authResult else {
            throw BridgeError.authFailed(outcome.lastError ?? "gpauth exited with code \(outcome.result.exitCode) without a sign-in result")
        }
        return json
    }

    public func discoverGateways(profile: ConnectionProfile, password: String?) async throws -> [Gateway] {
        guard !profile.portal.isEmpty else { throw BridgeError.portalMissing }
        guard !currentState.isBusy else { throw BridgeError.alreadyBusy }

        let builder = try makeBuilder(profile: profile)
        let previous = currentState
        disconnectRequested = false
        defer { if !currentState.isConnected { setState(previous) } }

        do {
            var authResult: String? = nil
            if GpclientCommandBuilder.needsBrowserAuth(profile) {
                authResult = try await runBrowserAuth(builder: builder, profile: profile)
                if disconnectRequested { return [] }
            }

            setState(.connecting(status: "Discovering gateways from \(profile.portal)…"))
            let outcome = try await runUnprivileged(builder.discoveryCommand(profile: profile, password: password, authResult: authResult))
            if outcome.gateways.isEmpty && !outcome.result.isSuccess {
                throw BridgeError.authFailed(outcome.lastError ?? "gpclient exited with code \(outcome.result.exitCode)")
            }
            if !outcome.gateways.isEmpty {
                bus.send(.gateways(outcome.gateways))
            }
            return outcome.gateways
        } catch {
            if disconnectRequested { return [] }
            throw error
        }
    }

    // MARK: - Connect

    public func connect(profile rawProfile: ConnectionProfile, password: String?) async throws {
        guard !rawProfile.portal.isEmpty else { throw BridgeError.portalMissing }
        guard !currentState.isBusy, !currentState.isConnected else { throw BridgeError.alreadyBusy }

        let builder = try makeBuilder(profile: rawProfile)
        let profile = try withResolvedVpncScript(rawProfile)

        disconnectRequested = false
        activeDetails = nil
        sessionLifetime = nil

        var authResult: String? = nil
        if GpclientCommandBuilder.needsBrowserAuth(profile) {
            do {
                authResult = try await runBrowserAuth(builder: builder, profile: profile)
            } catch {
                if disconnectRequested {
                    setState(.disconnected)
                    return
                }
                setState(.failed(message: error.localizedDescription))
                throw error
            }
            if disconnectRequested {
                setState(.disconnected)
                return
            }
            log(.info, "Browser sign-in succeeded")
        }

        let selectedName = profile.knownGateways.first { $0.server == profile.selectedGatewayServer }?.name
        activeDetails = ConnectedDetails(
            portal: profile.portal,
            gatewayName: selectedName ?? profile.selectedGatewayServer ?? profile.portal,
            gatewayServer: profile.selectedGatewayServer ?? profile.portal,
            cipher: profile.noDTLS ? "TLS" : "ESP / DTLS",
            connectedAt: Date()
        )

        startTunnel(builder: builder, profile: profile, password: password, authResult: authResult)
    }

    // MARK: - Privileged phase

    private func startTunnel(builder: GpclientCommandBuilder, profile: ConnectionProfile, password: String?, authResult: String?) {
        let command = builder.tunnelCommand(profile: profile, password: password, authResult: authResult)

        var mode = profile.privilegeMode
        var runner = makePrivilegedRunner(mode)
        if runner == nil, mode != .adminPrompt {
            log(.warn, "The privileged helper is not available (not approved, or an unsigned build); using the administrator authorization dialog instead")
            mode = .adminPrompt
            runner = makePrivilegedRunner(.adminPrompt)
        }
        guard let runner else {
            setState(.failed(message: BridgeError.privilegeDenied.localizedDescription))
            return
        }

        log(.debug, "Running (privileged, \(mode.rawValue)): \(command.displayString)")
        switch mode {
        case .helper:
            setState(.connecting(status: "Connecting to \(profile.portal)…"))
        case .adminPrompt:
            setState(.connecting(status: "Requesting administrator privileges…"))
        }

        superviseTunnel(runner: runner, command: command, interfacesBefore: tunInspector.snapshot())
    }

    /// Adopt a tunnel left behind by a previous app process (quit or crash
    /// while connected). Its log is replayed, so the parser recovers the
    /// gateway, connected state and session lifetime; Disconnect works as usual.
    public func adoptOrphanedSession() async -> Bool {
        guard currentState.isDisconnected, tunnelRunner == nil else { return false }

        if let attached = await attachToHelper() {
            let portal = Self.server(in: attached.arguments)
            log(.info, "Re-attaching to the VPN session the privileged helper is running (\(portal ?? "unknown portal"))")
            beginAttached(portal: portal)
            superviseTunnel(runner: attached.runner, command: CommandLine(executable: "", arguments: attached.arguments), interfacesBefore: [])
            return true
        }

        guard let orphan = scanOrphans().first else { return false }
        let server = orphan.server ?? "the previous session"
        log(.info, "Re-attaching to the VPN session left running by a previous Overland process (pid \(orphan.pid), \(server))")
        beginAttached(portal: orphan.server)
        // No "before" snapshot exists for an adopted tunnel; any utun that
        // carries an IPv4 address is a candidate, and a single one is taken.
        superviseTunnel(runner: makeAdoptedRunner(orphan), command: CommandLine(executable: "", arguments: orphan.command), interfacesBefore: [])
        return true
    }

    private func beginAttached(portal: String?) {
        disconnectRequested = false
        sessionLifetime = nil
        activeDetails = ConnectedDetails(
            portal: portal ?? "",
            gatewayName: portal ?? "the previous session",
            gatewayServer: portal ?? "",
            cipher: nil,
            connectedAt: Date()
        )
        setState(.connecting(status: "Re-attaching to the running session…"))
    }

    /// The portal or gateway a `gpclient connect` argv names, if recognisable.
    static func server(in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "connect"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Run `command` on `runner` and drive the connection state from its output
    /// until it exits. Used both for freshly launched and adopted tunnels.
    private func superviseTunnel(runner: any ProcessRunning, command: CommandLine, interfacesBefore: [TunInterfaceInspector.Interface]) {
        tunnelRunner = runner

        tunnelTask = Task { [weak self] in
            guard let self else { return }
            let bus = self.bus
            let parser = self.parser
            let tracker = TunnelTracker()

            let result: ProcessResult
            do {
                result = try await runner.run(command) { _, line in
                    for event in parser.parse(line: line) {
                        switch event {
                        case .log(let entry):
                            bus.send(.log(entry))
                            if entry.message.lowercased().hasPrefix("sudo:") {
                                tracker.sawSudoFailure = true
                            }
                        case .gatewayDiscovered(let gateway):
                            tracker.gateways.append(gateway)
                            let all = tracker.gateways
                            Task { await self.handleGateways(all) }
                        case .gatewaySelected(let name, let server):
                            Task { await self.handleGatewaySelected(name: name, server: server) }
                        case .tunnelConnected:
                            Task { await self.handleTunnelConnected(before: interfacesBefore) }
                        case .sessionInfo(let lifetime, let expires, let allowExtend):
                            Task { await self.handleSessionInfo(lifetime: lifetime, expires: expires, allowExtend: allowExtend) }
                        case .sessionExtended:
                            Task { await self.handleSessionExtended() }
                        case .sessionWarning(let message):
                            bus.send(.log(LogEntry(level: .warn, message: "Session warning: \(message)")))
                        case .browserLaunched, .awaitingBrowser:
                            // Happens when a password profile hits a SAML portal: gpclient
                            // spawns gpauth as root. Surface it so the user switches to SSO.
                            bus.send(.log(LogEntry(level: .warn, message: "The portal requires browser sign-in; select Single Sign-On as the authentication method.")))
                        case .fatalError(let message):
                            tracker.lastError = message
                        default:
                            break
                        }
                    }
                }
            } catch let error as PrivilegedRunError {
                await self.finishTunnel(exitCode: -1, lastError: error.localizedDescription, privilegeDenied: true)
                return
            } catch {
                await self.finishTunnel(exitCode: -1, lastError: error.localizedDescription, privilegeDenied: false)
                return
            }
            await self.finishTunnel(exitCode: result.exitCode, lastError: tracker.lastError, privilegeDenied: tracker.sawSudoFailure)
        }
    }

    private func handleGateways(_ gateways: [Gateway]) {
        bus.send(.gateways(gateways))
    }

    private func handleGatewaySelected(name: String, server: String) {
        guard var details = activeDetails else { return }
        details.gatewayName = name
        details.gatewayServer = server
        activeDetails = details
        setState(.connecting(status: "Connecting to gateway \(name)…"))
    }

    private func handleTunnelConnected(before: [TunInterfaceInspector.Interface]) {
        guard var details = activeDetails else { return }
        let after = tunInspector.snapshot()
        if let iface = TunInterfaceInspector.newInterface(before: before, after: after) {
            details.interfaceName = iface.name
            details.assignedIP = iface.address
        }
        details.connectedAt = Date()
        if let lifetime = sessionLifetime, details.sessionExpiresAt == nil {
            details.sessionExpiresAt = details.connectedAt.addingTimeInterval(lifetime)
        }
        activeDetails = details
        setState(.connected(details))
    }

    private func handleSessionInfo(lifetime: Int?, expires: Date?, allowExtend: Bool) {
        guard var details = activeDetails else { return }
        if let lifetime {
            sessionLifetime = TimeInterval(lifetime)
        }
        if let expires {
            details.sessionExpiresAt = expires
        } else if let lifetime {
            details.sessionExpiresAt = Date().addingTimeInterval(TimeInterval(lifetime))
        }
        details.allowExtendSession = allowExtend
        activeDetails = details
        if currentState.isConnected {
            setState(.connected(details))
        }
    }

    private func handleSessionExtended() {
        guard var details = activeDetails, let lifetime = sessionLifetime else { return }
        details.sessionExpiresAt = Date().addingTimeInterval(lifetime)
        activeDetails = details
        log(.info, "Session extended by the gateway; new expiry \(details.sessionExpiresAt!)")
        if currentState.isConnected {
            setState(.connected(details))
        }
    }

    private func finishTunnel(exitCode: Int32, lastError: String?, privilegeDenied: Bool) {
        tunnelRunner = nil
        tunnelTask = nil
        let wasConnected = currentState.isConnected
        activeDetails = nil

        if disconnectRequested {
            log(.info, "Tunnel closed (exit code \(exitCode))")
            setState(.disconnected)
            return
        }

        if privilegeDenied && !wasConnected {
            log(.error, lastError ?? BridgeError.privilegeDenied.localizedDescription)
            setState(.failed(message: BridgeError.privilegeDenied.localizedDescription))
            return
        }

        if exitCode == 0 {
            log(.info, "gpclient exited normally")
            setState(.disconnected)
        } else {
            let reason = lastError ?? (wasConnected
                ? "The VPN tunnel dropped (gpclient exit code \(exitCode))"
                : "gpclient exited with code \(exitCode) before the tunnel came up")
            log(.error, reason)
            setState(.failed(message: reason))
        }
    }

    // MARK: - Disconnect

    public func disconnect() async throws {
        disconnectRequested = true

        if let auth = authRunner {
            setState(.disconnecting)
            log(.info, "Cancelling sign-in…")
            await auth.terminate()
            // The unprivileged caller observes disconnectRequested and settles the state.
            return
        }

        guard let runner = tunnelRunner else {
            if !currentState.isDisconnected {
                setState(.disconnected)
            }
            return
        }

        setState(.disconnecting)
        log(.info, "Sending interrupt to gpclient…")
        await runner.interrupt()

        let deadline = Date().addingTimeInterval(disconnectGracePeriod)
        while await runner.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if await runner.isRunning {
            log(.warn, "gpclient did not exit after \(Int(disconnectGracePeriod))s; terminating")
            await runner.terminate()
        }
    }

    // MARK: - Browser callback

    public func deliverAuthCallback(_ data: String) async throws {
        log(.info, "Received browser authentication callback; forwarding to gpauth")
        do {
            try await callbackForwarder.forward(authData: data)
        } catch {
            log(.error, error.localizedDescription)
            throw error
        }
    }
}

/// Mutable scratch shared between the output callback (arbitrary thread) and
/// the actor that reads it after the process exits.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _authResult: String?
    private var _authFailure: String?
    private var _gateways: [Gateway] = []
    private var _lastError: String?

    var authResult: String? {
        get { lock.withLock { _authResult } }
        set { lock.withLock { _authResult = newValue } }
    }
    var authFailure: String? {
        get { lock.withLock { _authFailure } }
        set { lock.withLock { _authFailure = newValue } }
    }
    var gateways: [Gateway] {
        get { lock.withLock { _gateways } }
        set { lock.withLock { _gateways = newValue } }
    }
    var lastError: String? {
        get { lock.withLock { _lastError } }
        set { lock.withLock { _lastError = newValue } }
    }
}

final class TunnelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastError: String?
    private var _sawSudoFailure = false
    private var _gateways: [Gateway] = []

    var lastError: String? {
        get { lock.withLock { _lastError } }
        set { lock.withLock { _lastError = newValue } }
    }
    var sawSudoFailure: Bool {
        get { lock.withLock { _sawSudoFailure } }
        set { lock.withLock { _sawSudoFailure = newValue } }
    }
    var gateways: [Gateway] {
        get { lock.withLock { _gateways } }
        set { lock.withLock { _gateways = newValue } }
    }
}

/// A `ProcessRunning` whose `run` re-attaches to an orphaned privileged
/// session instead of launching the command it is given.
public actor AdoptedSessionRunner: ProcessRunning {
    private let orphan: PrivilegedProcessRunner.OrphanSession
    private let inner: PrivilegedProcessRunner
    private var running = false

    public init(orphan: PrivilegedProcessRunner.OrphanSession, pollInterval: TimeInterval = 0.15) {
        self.orphan = orphan
        self.inner = PrivilegedProcessRunner(sessionsDirectory: orphan.directory.deletingLastPathComponent(), pollInterval: pollInterval)
    }

    public var isRunning: Bool { running }

    public func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        running = true
        defer { running = false }
        return try await inner.adopt(orphan, onLine: onLine)
    }

    public func interrupt() {
        Task { await inner.interrupt() }
    }

    public func terminate() {
        Task { await inner.terminate() }
    }
}
