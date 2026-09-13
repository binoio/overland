import Foundation

/// Offline simulation of the whole connect/disconnect lifecycle. Used by the
/// unit tests and by the in-app "Mock" switch so the UI can be exercised
/// without a portal, a gpclient build, or root.
public actor MockBridgeService: BridgeServiceProtocol {
    private let bus = BridgeEventBus()
    private(set) public var currentState: VpnState = .disconnected
    private var activeDetails: ConnectedDetails?
    /// Delay multiplier so tests can run instantly.
    private let stepDelay: UInt64

    public init(stepDelayNanoseconds: UInt64 = 250_000_000) {
        self.stepDelay = stepDelayNanoseconds
    }

    public func events() -> AsyncStream<BridgeEvent> {
        let stream = bus.stream()
        bus.send(.state(currentState))
        return stream
    }

    private func log(_ level: LogLevel, _ message: String) {
        bus.send(.log(LogEntry(level: level, message: message)))
    }

    private func setState(_ state: VpnState) {
        currentState = state
        bus.send(.state(state))
    }

    private func sleep() async throws {
        if stepDelay > 0 { try await Task.sleep(nanoseconds: stepDelay) }
    }

    public static let sampleGateways = [
        Gateway(name: "US East (N. Virginia)", server: "us-east.gp.example.com", priority: 1),
        Gateway(name: "US West (Oregon)", server: "us-west.gp.example.com", priority: 2),
        Gateway(name: "Europe Central (Frankfurt)", server: "eu-central.gp.example.com", priority: 3),
        Gateway(name: "Asia Pacific (Tokyo)", server: "ap-northeast.gp.example.com", priority: 4)
    ]

    public func discoverGateways(profile: ConnectionProfile, password: String?) async throws -> [Gateway] {
        let portal = profile.portal.isEmpty ? "vpn.example.com" : profile.portal
        log(.info, "Retrieve the portal config for \(portal)")
        try await sleep()
        log(.info, "Found \(Self.sampleGateways.count) gateways in portal config")
        for gw in Self.sampleGateways {
            log(.info, "Gateway: \(gw.name) (\(gw.server)) priority=\(gw.priority)")
        }
        bus.send(.gateways(Self.sampleGateways))
        return Self.sampleGateways
    }

    public func connect(profile: ConnectionProfile, password: String?) async throws {
        guard !currentState.isBusy, !currentState.isConnected else { return }

        let portal = profile.portal.isEmpty ? "vpn.example.com" : profile.portal
        let gateway = Self.sampleGateways.first { $0.server == profile.selectedGatewayServer } ?? Self.sampleGateways[0]

        setState(.connecting(status: "Authenticating with \(portal)…"))
        log(.info, "gpclient started: 2.6.5 (mock)")
        log(.info, "Performing prelogin on portal \(portal)")
        log(.debug, "Auth method: \(profile.authMethod.rawValue), user: \(profile.username)")

        try await sleep()
        if profile.authMethod == .browserSSO {
            setState(.connecting(status: "Waiting for browser sign-in…"))
            log(.info, "Launching the default browser...")
            try await sleep()
            log(.info, "Received the browser authentication data from the socket")
        }

        log(.info, "Found \(Self.sampleGateways.count) gateways in portal config")
        for gw in Self.sampleGateways {
            log(.info, "Gateway: \(gw.name) (\(gw.server)) priority=\(gw.priority)")
        }
        bus.send(.gateways(Self.sampleGateways))

        setState(.connecting(status: "Requesting administrator privileges…"))
        try await sleep()
        setState(.connecting(status: "Establishing tunnel to \(gateway.name)…"))
        log(.info, "VPNC_SCRIPT: /opt/homebrew/etc/vpnc/vpnc-script")
        log(.info, "Connected to HTTPS on \(gateway.server) with ciphersuite (TLS1.3)-(ECDHE-SECP256R1)-(RSA-PSS-RSAE-SHA256)-(AES-256-GCM)")
        try await sleep()
        log(.info, "ESP session established with server")
        log(.info, "Connected to VPN, pipe_fd: 7")
        log(.info, "VPN session info: lifetime_secs=28800 (8h), user_expires=none, lifetime_warning_prior=300 (5m), allow_extend_session=true")

        let details = ConnectedDetails(
            portal: portal,
            gatewayName: gateway.name,
            gatewayServer: gateway.server,
            assignedIP: "10.250.4.18",
            assignedDNS: ["10.250.0.2", "10.250.0.3"],
            interfaceName: "utun6",
            cipher: "AES-256-GCM (ESP)",
            connectedAt: Date(),
            sessionExpiresAt: Date().addingTimeInterval(8 * 3600),
            allowExtendSession: true
        )
        activeDetails = details
        setState(.connected(details))
    }

    public func disconnect() async throws {
        guard currentState.isConnected || currentState.isConnecting else { return }

        setState(.disconnecting)
        log(.info, "Received the interrupt signal, disconnecting...")
        try await sleep()
        activeDetails = nil
        log(.info, "Removing PID file")
        log(.info, "gpclient exited")
        setState(.disconnected)
    }

    public func deliverAuthCallback(_ data: String) async throws {
        log(.info, "Received auth callback data (mock): \(data.prefix(24))…")
    }
}
