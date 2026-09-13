import Foundation

/// Everything the UI needs to hear from the backend, in one ordered stream.
public enum BridgeEvent: Equatable, Sendable {
    case log(LogEntry)
    case state(VpnState)
    case gateways([Gateway])
    case manualAuthURL(String)
}

public protocol BridgeServiceProtocol: Actor {
    /// Authenticate and open the tunnel. Returns once the tunnel process has
    /// been launched; progress and the eventual `.connected` arrive as events.
    func connect(profile: ConnectionProfile, password: String?) async throws
    func disconnect() async throws
    /// Log in to the portal and report its gateways without opening a tunnel.
    func discoverGateways(profile: ConnectionProfile, password: String?) async throws -> [Gateway]
    /// Hand a `globalprotectcallback:` payload to the login that is waiting for it.
    func deliverAuthCallback(_ data: String) async throws
    func events() -> AsyncStream<BridgeEvent>
    var currentState: VpnState { get }
}

/// Fan-out of `BridgeEvent`s to any number of `AsyncStream` subscribers.
final class BridgeEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]

    func stream() -> AsyncStream<BridgeEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func send(_ event: BridgeEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets {
            c.yield(event)
        }
    }
}
