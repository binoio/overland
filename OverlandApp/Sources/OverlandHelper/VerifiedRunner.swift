import Foundation
import OverlandCore

/// A `ProcessRunner` that performs the code-signature checks immediately
/// before launching, so a binary swapped after validation is still refused.
actor VerifiedRunner: ProcessRunning {
    private let inner = ProcessRunner()
    private let checks: @Sendable () throws -> Void
    private var running = false

    init(checks: @escaping @Sendable () throws -> Void) {
        self.checks = checks
    }

    var isRunning: Bool { running }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        try checks()
        running = true
        defer { running = false }
        return try await inner.run(command, onLine: onLine)
    }

    func interrupt() {
        Task { await inner.interrupt() }
    }

    func terminate() {
        Task { await inner.terminate() }
    }
}
