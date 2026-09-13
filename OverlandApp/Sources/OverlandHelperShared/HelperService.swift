import Foundation

/// The object the helper exports on one XPC connection. Relays requests to
/// the shared `TunnelManager` and streams its output back to that
/// connection's client.
public final class HelperService: NSObject, OverlandHelperProtocol, @unchecked Sendable {
    private let manager: TunnelManager
    private let callerUID: UInt32
    private let client: OverlandHelperClientProtocol?
    private var observerID: UUID?

    public init(manager: TunnelManager, callerUID: UInt32, client: OverlandHelperClientProtocol?) {
        self.manager = manager
        self.callerUID = callerUID
        self.client = client
        super.init()
        if let client {
            // XPC proxies are thread-safe; wrap so the closures can be @Sendable.
            let box = ClientBox(client)
            observerID = manager.addObserver(TunnelManager.Observer(
                onLine: { line in box.client.didOutput(line) },
                onExit: { code, message in box.client.didExit(code: code, message: message) }
            ))
        }
    }

    /// Call when the connection goes away.
    public func invalidate() {
        if let observerID {
            manager.removeObserver(observerID)
            self.observerID = nil
        }
    }

    public func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(overlandHelperProtocolVersion)
    }

    public func startTunnel(request: Data, stdin: Data?, reply: @escaping (String?) -> Void) {
        let decoded: HelperTunnelRequest
        do {
            decoded = try JSONDecoder().decode(HelperTunnelRequest.self, from: request)
        } catch {
            reply("malformed request: \(error.localizedDescription)")
            return
        }
        do {
            try manager.start(request: decoded, stdin: stdin, callerUID: callerUID)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    public func stop() {
        manager.stop()
    }

    public func kill() {
        manager.kill()
    }

    public func status(reply: @escaping (Data) -> Void) {
        let data = (try? JSONEncoder().encode(manager.status())) ?? Data()
        reply(data)
    }
}

private final class ClientBox: @unchecked Sendable {
    let client: OverlandHelperClientProtocol
    init(_ client: OverlandHelperClientProtocol) { self.client = client }
}
