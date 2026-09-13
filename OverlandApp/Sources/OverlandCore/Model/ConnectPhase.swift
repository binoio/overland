import Foundation

/// Where a connection attempt is in its sequence, for progress UI.
public enum ConnectPhase: Int, CaseIterable, Sendable, Equatable {
    case signIn = 0
    case authorize = 1
    case tunnel = 2

    public var title: String {
        switch self {
        case .signIn: return "Sign in"
        case .authorize: return "Authorize"
        case .tunnel: return "Tunnel"
        }
    }
}

/// A connection failure reduced to something a person can act on. The raw
/// gpclient text stays available in the logs.
public struct ConnectionFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case portalUnreachable
        case signInIncomplete
        case authorizationDeclined
        case helperRefused
        case anotherClientRunning
        case tunnelDropped
        case gatewayRejected
        case other
    }

    public var kind: Kind
    public var title: String
    public var advice: String
    public var detail: String

    public init(kind: Kind, title: String, advice: String, detail: String) {
        self.kind = kind
        self.title = title
        self.advice = advice
        self.detail = detail
    }

    /// Map a raw failure message to a kind with a short title and advice.
    public static func classify(_ message: String) -> ConnectionFailure {
        let m = message.lowercased()

        func has(_ needles: String...) -> Bool {
            needles.contains { m.contains($0) }
        }

        if has("another instance of the client is already running") {
            return ConnectionFailure(kind: .anotherClientRunning, title: "Another VPN client is running",
                                     advice: "A gpclient tunnel started outside Overland is still up. End it with “sudo gpclient disconnect” and try again.", detail: message)
        }
        if has("dns error", "failed to lookup", "nodename nor servname", "network is unreachable", "connection refused", "error sending request", "timed out", "no route to host") {
            return ConnectionFailure(kind: .portalUnreachable, title: "Portal unreachable",
                                     advice: "Check the portal address and your network connection, then try again.", detail: message)
        }
        if has("sign-in failed", "no auth data", "without a sign-in result", "saml", "gpauth exited") {
            return ConnectionFailure(kind: .signInIncomplete, title: "Sign-in didn’t complete",
                                     advice: "Finish signing in in the browser and allow it to open Overland when asked. Cancel and connect again to retry.", detail: message)
        }
        if has("administrator authorization", "authorization was cancelled", "user canceled") {
            return ConnectionFailure(kind: .authorizationDeclined, title: "Authorization cancelled",
                                     advice: "Overland needs an administrator’s approval to open the tunnel. Enable the privileged helper in Settings ▸ Backend to avoid this prompt.", detail: message)
        }
        if has("helper refused", "refused the request", "privileged helper") {
            return ConnectionFailure(kind: .helperRefused, title: "Privileged helper refused the request",
                                     advice: "Re-enable the helper in Settings ▸ Backend; if this persists, reinstall Overland to /Applications.", detail: message)
        }
        if has("tunnel dropped", "reconnect failed", "connection lost", "dropped (gpclient") {
            return ConnectionFailure(kind: .tunnelDropped, title: "Connection lost",
                                     advice: "The tunnel went down. Connect again; if it keeps happening, try disabling DTLS in Settings ▸ Network.", detail: message)
        }
        if has("gateway", "invalid credentials", "login failed", "authentication failed") {
            return ConnectionFailure(kind: .gatewayRejected, title: "The gateway rejected the connection",
                                     advice: "Check the gateway choice and your credentials, then try again.", detail: message)
        }
        return ConnectionFailure(kind: .other, title: "Connection failed",
                                 advice: "See Activity Logs for what gpclient reported.", detail: message)
    }
}
