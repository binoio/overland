import Foundation

/// Bumped whenever the XPC contract changes; the app refuses to talk to a
/// helper with a different version (a stale daemon after an app update).
public let overlandHelperProtocolVersion = 1

public let overlandHelperMachServiceName = "io.bino.overland.helper"
public let overlandHelperPlistName = "io.bino.overland.helper.plist"

/// What the app asks the helper to run. The helper validates it against the
/// binaries sealed in its own bundle before anything is executed.
public struct HelperTunnelRequest: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var running: Bool
    public var pid: Int32?
    public var startedAt: Date?
    public var arguments: [String]
    /// The most recent output lines, so a re-attaching app can recover state.
    public var recentLines: [String]
    public var lastExitCode: Int32?

    public init(
        protocolVersion: Int = overlandHelperProtocolVersion,
        running: Bool,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        arguments: [String] = [],
        recentLines: [String] = [],
        lastExitCode: Int32? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.running = running
        self.pid = pid
        self.startedAt = startedAt
        self.arguments = arguments
        self.recentLines = recentLines
        self.lastExitCode = lastExitCode
    }
}

/// Exported by the helper on every connection.
@objc public protocol OverlandHelperProtocol {
    func protocolVersion(reply: @escaping (Int) -> Void)
    /// `request` is JSON `HelperTunnelRequest`; `stdin` is written to the
    /// command once and dropped. `reply` carries an error message or nil.
    func startTunnel(request: Data, stdin: Data?, reply: @escaping (String?) -> Void)
    func stop()
    func kill()
    /// JSON `HelperStatus`.
    func status(reply: @escaping (Data) -> Void)
}

/// Exported by the app on its side of the connection; the helper streams
/// through it.
@objc public protocol OverlandHelperClientProtocol {
    func didOutput(_ line: String)
    func didExit(code: Int32, message: String?)
}

public enum HelperInterfaces {
    public static func helper() -> NSXPCInterface {
        NSXPCInterface(with: OverlandHelperProtocol.self)
    }

    public static func client() -> NSXPCInterface {
        NSXPCInterface(with: OverlandHelperClientProtocol.self)
    }
}
