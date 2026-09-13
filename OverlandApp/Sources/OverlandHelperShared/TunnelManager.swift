import Foundation
import OverlandCore

/// The helper's single tunnel: owns the gpclient process, keeps a bounded log
/// history, and fans output out to every connected app.
///
/// One instance lives for the life of the daemon; each XPC connection gets a
/// `HelperService` that subscribes here. State is guarded by a serial queue
/// because XPC delivers messages on arbitrary threads.
public final class TunnelManager: @unchecked Sendable {
    public struct Observer {
        public var onLine: @Sendable (String) -> Void
        public var onExit: @Sendable (Int32, String?) -> Void
        public init(onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32, String?) -> Void) {
            self.onLine = onLine
            self.onExit = onExit
        }
    }

    public enum StartError: Error, LocalizedError, Equatable {
        case alreadyRunning
        case rejected(String)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "a tunnel is already running"
            case .rejected(let why): return "request refused: \(why)"
            case .launchFailed(let why): return "could not start gpclient: \(why)"
            }
        }
    }

    private let queue = DispatchQueue(label: "io.bino.overland.helper.tunnel")
    private let validator: HelperRequestValidator
    private let makeRunner: @Sendable () -> any ProcessRunning
    private let historyLimit: Int

    private var runner: (any ProcessRunning)?
    private var runTask: Task<Void, Never>?
    private var arguments: [String] = []
    private var startedAt: Date?
    private var pid: Int32?
    private var history: [String] = []
    private var lastExitCode: Int32?
    private var observers: [UUID: Observer] = [:]
    private var running = false

    public init(
        validator: HelperRequestValidator,
        historyLimit: Int = 1000,
        runnerFactory: @escaping @Sendable () -> any ProcessRunning = { ProcessRunner() }
    ) {
        self.validator = validator
        self.historyLimit = historyLimit
        self.makeRunner = runnerFactory
    }

    // MARK: Observers

    @discardableResult
    public func addObserver(_ observer: Observer) -> UUID {
        let id = UUID()
        queue.sync { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) {
        queue.sync { observers[id] = nil }
    }

    public var observerCount: Int {
        queue.sync { observers.count }
    }

    // MARK: Control

    public func start(request: HelperTunnelRequest, stdin: Data?, callerUID: UInt32) throws {
        let approved: HelperRequestValidator.Approved
        do {
            approved = try validator.validate(executable: request.executable, arguments: request.arguments, callerUID: callerUID)
        } catch {
            throw StartError.rejected(error.localizedDescription)
        }

        try queue.sync {
            guard !running else { throw StartError.alreadyRunning }
            running = true
            arguments = approved.arguments
            startedAt = Date()
            history.removeAll()
            lastExitCode = nil
        }

        let runner = makeRunner()
        queue.sync { self.runner = runner }
        let command = CommandLine(
            executable: approved.executable,
            arguments: approved.arguments,
            stdin: stdin.flatMap { String(data: $0, encoding: .utf8) }
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let result: ProcessResult
            do {
                result = try await runner.run(command) { [weak self] _, line in
                    self?.record(line)
                }
            } catch {
                self.finish(code: -1, message: error.localizedDescription)
                return
            }
            self.finish(code: result.exitCode, message: nil)
        }
        queue.sync { runTask = task }
    }

    public func stop() {
        let runner = queue.sync { self.runner }
        Task { await runner?.interrupt() }
    }

    public func kill() {
        let runner = queue.sync { self.runner }
        Task { await runner?.terminate() }
    }

    public var isRunning: Bool {
        queue.sync { running }
    }

    public func status() -> HelperStatus {
        queue.sync {
            HelperStatus(
                running: running,
                pid: pid,
                startedAt: startedAt,
                arguments: arguments,
                recentLines: history,
                lastExitCode: lastExitCode
            )
        }
    }

    // MARK: Internals

    private func record(_ line: String) {
        let targets: [Observer] = queue.sync {
            history.append(line)
            if history.count > historyLimit {
                history.removeFirst(history.count - historyLimit)
            }
            return Array(observers.values)
        }
        for o in targets { o.onLine(line) }
    }

    private func finish(code: Int32, message: String?) {
        let targets: [Observer] = queue.sync {
            running = false
            runner = nil
            runTask = nil
            pid = nil
            lastExitCode = code
            return Array(observers.values)
        }
        for o in targets { o.onExit(code, message) }
    }
}
