import Foundation

/// Accepts XPC connections, wires each to a `HelperService`, and tracks how
/// many are open (for the daemon's idle exit). The accept policy is injected:
/// the real helper checks code signatures, tests accept everything.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public typealias AcceptPolicy = @Sendable (NSXPCConnection) -> Bool

    public let manager: TunnelManager
    private let accept: AcceptPolicy
    private let lock = NSLock()
    private var open = 0
    private var lastActivity = Date()
    private let log: @Sendable (String) -> Void

    public init(manager: TunnelManager, accept: @escaping AcceptPolicy, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.manager = manager
        self.accept = accept
        self.log = log
    }

    public var openConnections: Int {
        lock.withLock { open }
    }

    /// Seconds since the last connection closed (or since start).
    public var idleSeconds: TimeInterval {
        lock.withLock { Date().timeIntervalSince(lastActivity) }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard accept(connection) else {
            log("rejected connection from pid \(connection.processIdentifier)")
            return false
        }

        connection.exportedInterface = HelperInterfaces.helper()
        connection.remoteObjectInterface = HelperInterfaces.client()
        let client = connection.remoteObjectProxyWithErrorHandler { [log] error in
            log("client proxy error: \(error.localizedDescription)")
        } as? OverlandHelperClientProtocol

        let service = HelperService(manager: manager, callerUID: connection.effectiveUserIdentifier, client: client)
        connection.exportedObject = service

        lock.withLock { open += 1; lastActivity = Date() }
        log("accepted connection from pid \(connection.processIdentifier) uid \(connection.effectiveUserIdentifier)")

        connection.invalidationHandler = { [weak self] in
            service.invalidate()
            guard let self else { return }
            self.lock.withLock { self.open -= 1; self.lastActivity = Date() }
            self.log("connection from pid \(connection.processIdentifier) closed")
        }
        connection.resume()
        return true
    }
}
