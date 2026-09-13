import Foundation
@testable import GlobalProtectCore

/// A scripted stand-in for `ProcessRunner`.
///
/// Each invocation is matched against `scripts` in order; the first script
/// whose `matches` predicate accepts the command is played back. A script can
/// emit lines, exit immediately, or hang until `interrupt()`/`terminate()` is
/// called (the tunnel process behaves like that).
actor FakeProcessRunner: ProcessRunning {
    struct Script {
        var matches: @Sendable (CommandLine) -> Bool
        var lines: [(ProcessStream, String)]
        var exitCode: Int32
        var waitForSignal: Bool
        var exitCodeAfterSignal: Int32

        init(
            matches: @escaping @Sendable (CommandLine) -> Bool,
            lines: [(ProcessStream, String)] = [],
            exitCode: Int32 = 0,
            waitForSignal: Bool = false,
            exitCodeAfterSignal: Int32 = 0
        ) {
            self.matches = matches
            self.lines = lines
            self.exitCode = exitCode
            self.waitForSignal = waitForSignal
            self.exitCodeAfterSignal = exitCodeAfterSignal
        }
    }

    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [CommandLine] = []
        private var _interrupts = 0
        private var _terminates = 0

        var commands: [CommandLine] { lock.withLock { _commands } }
        var interrupts: Int { lock.withLock { _interrupts } }
        var terminates: Int { lock.withLock { _terminates } }

        func record(_ c: CommandLine) { lock.withLock { _commands.append(c) } }
        func recordInterrupt() { lock.withLock { _interrupts += 1 } }
        func recordTerminate() { lock.withLock { _terminates += 1 } }
    }

    private let scripts: [Script]
    private let journal: Journal
    private var running = false
    private var signalContinuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    init(scripts: [Script], journal: Journal) {
        self.scripts = scripts
        self.journal = journal
    }

    var isRunning: Bool { running }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        journal.record(command)
        guard let script = scripts.first(where: { $0.matches(command) }) else {
            throw NSError(domain: "FakeProcessRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "no script for \(command.displayString)"])
        }

        running = true
        defer { running = false }

        for (stream, line) in script.lines {
            onLine?(stream, line)
            // Let event handlers scheduled on other actors run between lines.
            await Task.yield()
        }

        if script.waitForSignal && !signalled {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                signalContinuation = c
            }
            return ProcessResult(exitCode: script.exitCodeAfterSignal)
        }
        return ProcessResult(exitCode: script.exitCode)
    }

    func interrupt() {
        journal.recordInterrupt()
        signal()
    }

    func terminate() {
        journal.recordTerminate()
        signal()
    }

    private func signal() {
        signalled = true
        signalContinuation?.resume()
        signalContinuation = nil
    }
}

func jsonLog(_ level: String, _ message: String) -> String {
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return #"{"timestamp":"2026-09-13T02:24:56.810Z","level":"\#(level)","target":"gpclient","message":"\#(escaped)"}"#
}

/// Collects bridge events on a background task for assertions.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [BridgeEvent] = []
    private var task: Task<Void, Never>?

    var events: [BridgeEvent] { lock.withLock { _events } }
    var states: [VpnState] {
        events.compactMap { if case .state(let s) = $0 { return s } else { return nil } }
    }
    var logs: [LogEntry] {
        events.compactMap { if case .log(let l) = $0 { return l } else { return nil } }
    }

    func attach(_ stream: AsyncStream<BridgeEvent>) {
        task = Task {
            for await event in stream {
                lock.withLock { _events.append(event) }
            }
        }
    }

    func stop() { task?.cancel() }

    /// Poll until `predicate` holds or the timeout elapses.
    func wait(timeout: TimeInterval = 3, until predicate: @escaping ([BridgeEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(events) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate(events)
    }
}

/// Poll a condition on the main actor.
@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A one-shot loopback TCP server that records the first payload it receives.
/// Plays the role of the `gpclient` process waiting for browser auth data.
final class LoopbackListener: @unchecked Sendable {
    final class ReceivedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        var value: String? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    let port: UInt16
    private let fd: Int32
    private let box = ReceivedBox()
    private let done = DispatchSemaphore(value: 0)

    var received: String? { box.value }

    init() throws {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let serverFd = socket(AF_INET, streamType, 0)
        guard serverFd >= 0 else { throw NSError(domain: "LoopbackListener", code: 1) }

        var one: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(serverFd, 1) == 0 else {
            close(serverFd)
            throw NSError(domain: "LoopbackListener", code: 2)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(serverFd, $0, &len) }
        }

        self.fd = serverFd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let box = self.box
        let done = self.done
        Thread.detachNewThread {
            let client = accept(serverFd, nil, nil)
            defer { done.signal() }
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            var collected = [UInt8]()
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                collected.append(contentsOf: buffer[0..<n])
            }
            close(client)
            box.value = String(decoding: collected, as: UTF8.self)
        }
    }

    /// Wait for the client to send and close.
    func waitForPayload(timeout: TimeInterval = 5) -> String? {
        _ = done.wait(timeout: .now() + timeout)
        return received
    }

    deinit { close(fd) }
}
