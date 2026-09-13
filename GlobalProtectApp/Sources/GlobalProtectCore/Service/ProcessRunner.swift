import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var isSuccess: Bool { exitCode == 0 }
}

public enum ProcessStream: Sendable {
    case stdout
    case stderr
}

/// Accumulates bytes and hands back complete lines, so a JSON record that
/// arrives across two reads is never delivered half-parsed.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        all.append(data)
        pending.append(data)

        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [line]
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }
}

/// Anything that can execute a `CommandLine` and stream its output.
public protocol ProcessRunning: Actor {
    func run(
        _ command: CommandLine,
        onLine: (@Sendable (ProcessStream, String) -> Void)?
    ) async throws -> ProcessResult

    func interrupt()
    func terminate()
    var isRunning: Bool { get }
}

public actor ProcessRunner: ProcessRunning {
    private var currentProcess: Process?

    public init() {}

    public var isRunning: Bool {
        currentProcess?.isRunning ?? false
    }

    public func run(
        _ command: CommandLine,
        onLine: (@Sendable (ProcessStream, String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments

        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in command.environment {
            mergedEnv[k] = v
        }
        process.environment = mergedEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let stdoutBuffer = LineBuffer()
        let stderrBuffer = LineBuffer()

        self.currentProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in stdoutBuffer.append(data) {
                    onLine?(.stdout, line)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in stderrBuffer.append(data) {
                    onLine?(.stderr, line)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let restOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                for line in stdoutBuffer.append(restOut) + stdoutBuffer.flush() {
                    onLine?(.stdout, line)
                }
                for line in stderrBuffer.append(restErr) + stderrBuffer.flush() {
                    onLine?(.stderr, line)
                }

                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutBuffer.text,
                    stderr: stderrBuffer.text
                ))
            }

            do {
                try process.run()
                if let stdin = command.stdin, let data = stdin.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                // gpclient reads the password / cookie up to EOF, so close our end.
                try? stdinPipe.fileHandleForWriting.close()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// SIGINT — gpclient treats it as "disconnect cleanly", and sudo relays
    /// it to the child it is running.
    public func interrupt() {
        if let process = currentProcess, process.isRunning {
            process.interrupt()
        }
    }

    public func terminate() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
        currentProcess = nil
    }
}
