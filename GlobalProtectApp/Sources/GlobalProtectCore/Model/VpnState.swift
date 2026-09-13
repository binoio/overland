import Foundation

public struct ConnectedDetails: Equatable, Sendable, Codable {
    public var portal: String
    public var gatewayName: String
    public var gatewayServer: String
    public var assignedIP: String?
    public var assignedDNS: [String]
    public var interfaceName: String?
    public var cipher: String?
    public var connectedAt: Date
    public var sessionExpiresAt: Date?
    public var allowExtendSession: Bool

    public init(
        portal: String,
        gatewayName: String,
        gatewayServer: String,
        assignedIP: String? = nil,
        assignedDNS: [String] = [],
        interfaceName: String? = nil,
        cipher: String? = nil,
        connectedAt: Date = Date(),
        sessionExpiresAt: Date? = nil,
        allowExtendSession: Bool = false
    ) {
        self.portal = portal
        self.gatewayName = gatewayName
        self.gatewayServer = gatewayServer
        self.assignedIP = assignedIP
        self.assignedDNS = assignedDNS
        self.interfaceName = interfaceName
        self.cipher = cipher
        self.connectedAt = connectedAt
        self.sessionExpiresAt = sessionExpiresAt
        self.allowExtendSession = allowExtendSession
    }

    public var sessionRemainingSeconds: TimeInterval? {
        guard let expiresAt = sessionExpiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(Date()))
    }
}

public enum VpnState: Equatable, Sendable {
    case disconnected
    case connecting(status: String)
    case connected(ConnectedDetails)
    case disconnecting
    case failed(message: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    public var isBusy: Bool {
        isConnecting || self == .disconnecting
    }

    public var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting(let status):
            return status.isEmpty ? "Connecting…" : status
        case .connected(let details):
            return "Connected to \(details.gatewayName)"
        case .disconnecting:
            return "Disconnecting…"
        case .failed(let message):
            return "Connection Failed: \(message)"
        }
    }
}
