import Foundation
import OverlandCore
import OverlandHelperShared

public enum HelperClientError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case protocolMismatch(helper: Int, app: Int)
    case refused(String)
    case nothingRunning

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let why): return "Could not reach the Overland privileged helper: \(why)"
        case .protocolMismatch(let helper, let app): return "The privileged helper (protocol \(helper)) does not match this app (protocol \(app)); re-enable it in Settings ▸ Backend."
        case .refused(let why): return "The privileged helper refused the request: \(why)"
        case .nothingRunning: return "The privileged helper is not running a tunnel."
        }
    }
}

/// Receives the helper's stream on the app side of the connection.
final class HelperClient: NSObject, OverlandHelperClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var onLine: (@Sendable (String) -> Void)?
    private var onExit: (@Sendable (Int32, String?) -> Void)?

    func set(onLine: (@Sendable (String) -> Void)?, onExit: (@Sendable (Int32, String?) -> Void)?) {
        lock.withLock {
            self.onLine = onLine
            self.onExit = onExit
        }
    }

    func didOutput(_ line: String) {
        lock.withLock { onLine }?(line)
    }

    func didExit(code: Int32, message: String?) {
        let handler = lock.withLock { () -> (@Sendable (Int32, String?) -> Void)? in
            let h = onExit
            onExit = nil
            return h
        }
        handler?(code, message)
    }
}

/// Runs the tunnel through the privileged helper over XPC.
///
/// In `.start` mode `run` asks the helper to launch the command; in `.attach`
/// mode it re-joins the tunnel the helper is already running, replaying the
/// helper's recent output first. Either way `run` resolves when the helper
/// reports the command's exit, and `interrupt`/`terminate` map to stop/kill.
public actor HelperProcessRunner: ProcessRunning {
    public typealias ConnectionFactory = @Sendable () -> NSXPCConnection

    public enum Mode: Sendable {
        case start
        case attach
    }

    public static let defaultConnectionFactory: ConnectionFactory = {
        NSXPCConnection(machServiceName: overlandHelperMachServiceName, options: .privileged)
    }

    private let makeConnection: ConnectionFactory
    private let mode: Mode
    private let client = HelperClient()
    private var connection: NSXPCConnection?
    private var running = false
    private var exitContinuation: CheckedContinuation<ProcessResult, Never>?
    private var pendingResult: ProcessResult?

    public init(mode: Mode = .start, connectionFactory: @escaping ConnectionFactory = HelperProcessRunner.defaultConnectionFactory) {
        self.mode = mode
        self.makeConnection = connectionFactory
    }

    public var isRunning: Bool { running }

    // MARK: Connection

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = makeConnection()
        c.remoteObjectInterface = HelperInterfaces.helper()
        c.exportedInterface = HelperInterfaces.client()
        c.exportedObject = client
        c.invalidationHandler = { [weak self] in
            Task { await self?.connectionLost("connection invalidated") }
        }
        c.resume()
        connection = c
        return c
    }

    /// One request/reply exchange. XPC delivers exactly one of the reply or
    /// the error handler, so the continuation is always settled — a rejected
    /// or dead connection surfaces as `connectionFailed` instead of a hang.
    private func call<T: Sendable>(_ body: @escaping @Sendable (OverlandHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async throws -> T {
        let connection = ensureConnection()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce()
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                once.run { continuation.resume(throwing: HelperClientError.connectionFailed(error.localizedDescription)) }
                Task { await self?.connectionLost(error.localizedDescription) }
            }
            guard let helper = proxy as? OverlandHelperProtocol else {
                once.run { continuation.resume(throwing: HelperClientError.connectionFailed("no proxy")) }
                return
            }
            body(helper) { value in
                once.run { continuation.resume(returning: value) }
            }
        }
    }

    /// Fire-and-forget message.
    private func send(_ body: @escaping @Sendable (OverlandHelperProtocol) -> Void) {
        let connection = ensureConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { await self?.connectionLost(error.localizedDescription) }
        }
        if let helper = proxy as? OverlandHelperProtocol {
            body(helper)
        }
    }

    private func connectionLost(_ reason: String) {
        finish(ProcessResult(exitCode: -1, stderr: "helper: \(reason)"))
    }

    /// Settle `run` with `result`; harmless if nothing is running.
    private func finish(_ result: ProcessResult) {
        guard running else { return }
        running = false
        client.set(onLine: nil, onExit: nil)
        if let c = exitContinuation {
            exitContinuation = nil
            c.resume(returning: result)
        } else {
            pendingResult = result
        }
    }

    private func awaitExit() async -> ProcessResult {
        if let r = pendingResult {
            pendingResult = nil
            return r
        }
        return await withCheckedContinuation { exitContinuation = $0 }
    }

    public func close() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: Queries

    public func helperProtocolVersion() async throws -> Int {
        try await call { helper, reply in helper.protocolVersion(reply: reply) }
    }

    public func status() async throws -> HelperStatus {
        let data: Data = try await call { helper, reply in helper.status(reply: reply) }
        do {
            return try JSONDecoder().decode(HelperStatus.self, from: data)
        } catch {
            throw HelperClientError.connectionFailed("unreadable status: \(error.localizedDescription)")
        }
    }

    private func checkVersion() async throws {
        let v = try await helperProtocolVersion()
        guard v == overlandHelperProtocolVersion else {
            throw HelperClientError.protocolMismatch(helper: v, app: overlandHelperProtocolVersion)
        }
    }

    // MARK: ProcessRunning

    public func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        try await checkVersion()

        // Handlers go in before anything can produce output.
        running = true
        pendingResult = nil
        client.set(
            onLine: { line in onLine?(.stderr, line) },
            onExit: { [weak self] code, message in
                Task { await self?.finish(ProcessResult(exitCode: code, stderr: message ?? "")) }
            }
        )

        switch mode {
        case .start:
            let request = try JSONEncoder().encode(HelperTunnelRequest(executable: command.executable, arguments: command.arguments))
            let stdin = command.stdin?.data(using: .utf8)
            let error: String?
            do {
                error = try await call { helper, reply in helper.startTunnel(request: request, stdin: stdin, reply: reply) }
            } catch {
                running = false
                client.set(onLine: nil, onExit: nil)
                throw error
            }
            if let error {
                running = false
                client.set(onLine: nil, onExit: nil)
                throw HelperClientError.refused(error)
            }
        case .attach:
            let st = try await status()
            guard st.running else {
                running = false
                client.set(onLine: nil, onExit: nil)
                throw HelperClientError.nothingRunning
            }
            for line in st.recentLines {
                onLine?(.stderr, line)
            }
        }

        return await awaitExit()
    }

    public func interrupt() {
        send { $0.stop() }
    }

    public func terminate() {
        send { $0.kill() }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
