import XCTest
@testable import OverlandCore
@testable import OverlandHelperShared

/// Minimal scripted runner for the helper tests: emits lines, then either
/// exits or waits for interrupt/terminate.
actor ScriptedRunner: ProcessRunning {
    let lines: [String]
    let exitCode: Int32
    let waitForSignal: Bool
    private(set) var isRunning = false
    private(set) var lastCommand: CommandLine?
    private var continuation: CheckedContinuation<Int32, Never>?
    private let journal: Journal

    final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var _interrupts = 0
        private var _terminates = 0
        private var _commands: [CommandLine] = []
        var interrupts: Int { lock.withLock { _interrupts } }
        var terminates: Int { lock.withLock { _terminates } }
        var commands: [CommandLine] { lock.withLock { _commands } }
        func interrupt() { lock.withLock { _interrupts += 1 } }
        func terminate() { lock.withLock { _terminates += 1 } }
        func record(_ c: CommandLine) { lock.withLock { _commands.append(c) } }
    }

    init(lines: [String], exitCode: Int32 = 0, waitForSignal: Bool = false, journal: Journal) {
        self.lines = lines
        self.exitCode = exitCode
        self.waitForSignal = waitForSignal
        self.journal = journal
    }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        journal.record(command)
        lastCommand = command
        isRunning = true
        defer { isRunning = false }
        for line in lines {
            onLine?(.stderr, line)
            await Task.yield()
        }
        if waitForSignal {
            let code = await withCheckedContinuation { continuation = $0 }
            return ProcessResult(exitCode: code)
        }
        return ProcessResult(exitCode: exitCode)
    }

    func interrupt() {
        journal.interrupt()
        continuation?.resume(returning: 3)
        continuation = nil
    }

    func terminate() {
        journal.terminate()
        continuation?.resume(returning: 15)
        continuation = nil
    }
}

final class RecordingClient: NSObject, OverlandHelperClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _exit: (Int32, String?)?
    var lines: [String] { lock.withLock { _lines } }
    var exit: (Int32, String?)? { lock.withLock { _exit } }
    func didOutput(_ line: String) { lock.withLock { _lines.append(line) } }
    func didExit(code: Int32, message: String?) { lock.withLock { _exit = (code, message) } }
}

@MainActor
final class HelperServiceTests: XCTestCase {
    private let gp = "/App/Contents/MacOS/gpclient"
    private let script = "/App/Contents/Resources/vpnc-script"

    private func manager(lines: [String], exitCode: Int32 = 0, waitForSignal: Bool = false, journal: ScriptedRunner.Journal, historyLimit: Int = 1000) -> TunnelManager {
        TunnelManager(
            validator: HelperRequestValidator(gpclientPath: gp, vpncScriptPath: script, fileInfo: { _ in nil }),
            historyLimit: historyLimit,
            runnerFactory: { ScriptedRunner(lines: lines, exitCode: exitCode, waitForSignal: waitForSignal, journal: journal) }
        )
    }

    private func requestData(_ args: [String]) -> Data {
        try! JSONEncoder().encode(HelperTunnelRequest(executable: gp, arguments: args))
    }

    private func start(_ service: HelperService, _ args: [String], stdin: Data? = nil) async -> String? {
        await withCheckedContinuation { c in
            service.startTunnel(request: requestData(args), stdin: stdin) { c.resume(returning: $0) }
        }
    }

    private func status(_ service: HelperService) async -> HelperStatus {
        await withCheckedContinuation { c in
            service.status { data in c.resume(returning: try! JSONDecoder().decode(HelperStatus.self, from: data)) }
        }
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testStartStreamsLinesAndReportsExit() async {
        let journal = ScriptedRunner.Journal()
        let m = manager(lines: ["one", "two"], exitCode: 0, journal: journal)
        let client = RecordingClient()
        let service = HelperService(manager: m, callerUID: 501, client: client)

        let error = await start(service, ["--log-format", "json", "connect", "vpn.example.com", "--auto-gateway", "--cookie-on-stdin"], stdin: Data("{\"success\":{}}\n".utf8))
        XCTAssertNil(error)
        let exited = await eventually { client.exit != nil }
        XCTAssertTrue(exited)
        XCTAssertEqual(client.lines, ["one", "two"])
        XCTAssertEqual(client.exit?.0, 0)
        XCTAssertEqual(journal.commands.first?.stdin, "{\"success\":{}}\n", "stdin reaches the process")
        XCTAssertEqual(journal.commands.first?.executable, gp)

        let st = await status(service)
        XCTAssertFalse(st.running)
        XCTAssertEqual(st.lastExitCode, 0)
        XCTAssertEqual(st.recentLines, ["one", "two"])
    }

    func testRejectsInvalidRequestWithoutRunningAnything() async {
        let journal = ScriptedRunner.Journal()
        let m = manager(lines: [], journal: journal)
        let service = HelperService(manager: m, callerUID: 501, client: nil)

        let error = await start(service, ["connect", "vpn.example.com", "--script", "/tmp/evil"])
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("vpnc-script"), error!)
        XCTAssertTrue(journal.commands.isEmpty)
        XCTAssertFalse(m.isRunning)

        let foreign = try! JSONEncoder().encode(HelperTunnelRequest(executable: "/tmp/gpclient", arguments: ["connect", "x"]))
        let msg: String? = await withCheckedContinuation { c in service.startTunnel(request: foreign, stdin: nil) { c.resume(returning: $0) } }
        XCTAssertTrue(msg?.contains("only the bundled gpclient") == true, msg ?? "nil")

        let garbage: String? = await withCheckedContinuation { c in service.startTunnel(request: Data("nope".utf8), stdin: nil) { c.resume(returning: $0) } }
        XCTAssertTrue(garbage?.hasPrefix("malformed request") == true)
    }

    func testOnlyOneTunnelAtATimeAndStopInterruptsIt() async {
        let journal = ScriptedRunner.Journal()
        let m = manager(lines: ["ready"], waitForSignal: true, journal: journal)
        let client = RecordingClient()
        let service = HelperService(manager: m, callerUID: 501, client: client)

        let r1 = await start(service, ["connect", "vpn.example.com", "--auto-gateway"])
        XCTAssertNil(r1)
        _ = await eventually { client.lines.contains("ready") }
        XCTAssertTrue(m.isRunning)

        let second = await start(service, ["connect", "vpn.example.com", "--auto-gateway"])
        XCTAssertEqual(second, "a tunnel is already running")

        service.stop()
        let exited = await eventually { client.exit != nil }
        XCTAssertTrue(exited)
        XCTAssertEqual(journal.interrupts, 1)
        XCTAssertEqual(client.exit?.0, 3)
        XCTAssertFalse(m.isRunning)

        // A new tunnel may start afterwards.
        let r2 = await start(service, ["connect", "vpn.example.com", "--auto-gateway"])
        XCTAssertNil(r2)
        service.kill()
        _ = await eventually { journal.terminates == 1 }
        XCTAssertEqual(journal.terminates, 1)
    }

    /// A second connection (the app relaunched) sees history through status
    /// and live lines from then on; a dropped connection stops receiving.
    func testLateClientGetsHistoryThenLiveLinesAndInvalidateUnsubscribes() async {
        let journal = ScriptedRunner.Journal()
        let m = manager(lines: ["a", "b", "c"], waitForSignal: true, journal: journal, historyLimit: 2)
        let first = RecordingClient()
        let firstService = HelperService(manager: m, callerUID: 501, client: first)
        let r3 = await start(firstService, ["connect", "vpn.example.com", "--auto-gateway"])
        XCTAssertNil(r3)
        _ = await eventually { first.lines.count == 3 }

        let st = await status(firstService)
        XCTAssertTrue(st.running)
        XCTAssertEqual(st.recentLines, ["b", "c"], "history is bounded")
        XCTAssertEqual(st.arguments, ["connect", "vpn.example.com", "--auto-gateway"])

        let second = RecordingClient()
        let secondService = HelperService(manager: m, callerUID: 501, client: second)
        XCTAssertEqual(m.observerCount, 2)

        firstService.invalidate()
        XCTAssertEqual(m.observerCount, 1)

        secondService.stop()
        let exited = await eventually { second.exit != nil }
        XCTAssertTrue(exited)
        XCTAssertNil(first.exit, "an invalidated connection is not notified")
        XCTAssertEqual(second.exit?.0, 3)
    }

    func testProtocolVersion() async {
        let service = HelperService(manager: manager(lines: [], journal: .init()), callerUID: 0, client: nil)
        let v: Int = await withCheckedContinuation { c in service.protocolVersion { c.resume(returning: $0) } }
        XCTAssertEqual(v, overlandHelperProtocolVersion)
    }
}
