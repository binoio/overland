import XCTest
@testable import Overland
@testable import OverlandCore
@testable import OverlandHelperShared

/// Real XPC round trips over an anonymous in-process listener hosting the
/// same delegate/service the daemon uses (accept policy: everyone).
@MainActor
final class HelperProcessRunnerTests: XCTestCase {
    private let gp = "/App/Contents/MacOS/gpclient"
    private let script = "/App/Contents/Resources/vpnc-script"
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var journal: ScriptedRunner.Journal!

    private func host(lines: [String], exitCode: Int32 = 0, waitForSignal: Bool = false) {
        journal = ScriptedRunner.Journal()
        let j = journal!
        let manager = TunnelManager(
            validator: HelperRequestValidator(gpclientPath: gp, vpncScriptPath: script, fileInfo: { _ in nil }),
            runnerFactory: { ScriptedRunner(lines: lines, exitCode: exitCode, waitForSignal: waitForSignal, journal: j) }
        )
        delegate = HelperListenerDelegate(manager: manager, accept: { _ in true })
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
    }

    private func makeRunner(mode: HelperProcessRunner.Mode = .start) -> HelperProcessRunner {
        let endpoint = listener.endpoint
        return HelperProcessRunner(mode: mode, connectionFactory: { NSXPCConnection(listenerEndpoint: endpoint) })
    }

    override func tearDown() {
        listener?.invalidate()
        listener = nil
    }

    private func eventually(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testVersionAndStatusOverXPC() async throws {
        host(lines: [])
        let runner = makeRunner()
        let v = try await runner.helperProtocolVersion()
        XCTAssertEqual(v, overlandHelperProtocolVersion)
        let st = try await runner.status()
        XCTAssertFalse(st.running)
        XCTAssertEqual(st.protocolVersion, overlandHelperProtocolVersion)
        await runner.close()
    }

    func testRunStreamsLinesAndReturnsExitCode() async throws {
        host(lines: ["a", "b"], exitCode: 4)
        let runner = makeRunner()
        let sink = LineSink()
        let result = try await runner.run(
            CommandLine(executable: gp, arguments: ["--log-format", "json", "connect", "vpn.example.com", "--auto-gateway", "--cookie-on-stdin"], stdin: "cookie\n"),
            onLine: { _, line in sink.append(line) }
        )
        XCTAssertEqual(result.exitCode, 4)
        XCTAssertEqual(sink.lines, ["a", "b"])
        XCTAssertEqual(journal.commands.first?.stdin, "cookie\n", "stdin crossed XPC intact")
        let running = await runner.isRunning
        XCTAssertFalse(running)
        await runner.close()
    }

    func testRefusedRequestThrows() async throws {
        host(lines: [])
        let runner = makeRunner()
        do {
            _ = try await runner.run(CommandLine(executable: "/tmp/gpclient", arguments: ["connect", "x"]), onLine: nil)
            XCTFail("expected refusal")
        } catch let error as HelperClientError {
            guard case .refused(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("only the bundled gpclient"), why)
        }
        XCTAssertTrue(journal.commands.isEmpty)
        await runner.close()
    }

    func testInterruptStopsTunnelThroughHelper() async throws {
        host(lines: ["ready"], waitForSignal: true)
        let runner = makeRunner()
        let sink = LineSink()
        let task = Task { try await runner.run(CommandLine(executable: gp, arguments: ["connect", "vpn.example.com", "--auto-gateway"]), onLine: { _, l in sink.append(l) }) }
        let ready = await eventually { sink.lines.contains("ready") }
        XCTAssertTrue(ready)
        let running = await runner.isRunning
        XCTAssertTrue(running)

        await runner.interrupt()
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(journal.interrupts, 1)
        await runner.close()
    }

    /// The app "restarts": a second runner attaches, gets the replayed history,
    /// then live lines and the exit — and can stop the tunnel.
    func testAttachReplaysAndControlsExistingTunnel() async throws {
        host(lines: ["one", "two"], waitForSignal: true)
        let first = makeRunner()
        let firstSink = LineSink()
        let firstTask = Task { try await first.run(CommandLine(executable: gp, arguments: ["connect", "vpn.example.com", "--auto-gateway"]), onLine: { _, l in firstSink.append(l) }) }
        let seen = await eventually { firstSink.lines.count == 2 }
        XCTAssertTrue(seen)

        // The first app process goes away without stopping the tunnel.
        await first.close()
        _ = try? await firstTask.value

        let second = makeRunner(mode: .attach)
        let st = try await second.status()
        XCTAssertTrue(st.running)
        XCTAssertEqual(st.arguments, ["connect", "vpn.example.com", "--auto-gateway"])

        let secondSink = LineSink()
        let attachTask = Task { try await second.run(CommandLine(executable: "", arguments: []), onLine: { _, l in secondSink.append(l) }) }
        let replayed = await eventually { secondSink.lines == ["one", "two"] }
        XCTAssertTrue(replayed, "\(secondSink.lines)")

        await second.terminate()
        let result = try await attachTask.value
        XCTAssertEqual(result.exitCode, 15)
        XCTAssertEqual(journal.terminates, 1)
        await second.close()
    }

    func testAttachWithNothingRunningThrows() async throws {
        host(lines: [])
        let runner = makeRunner(mode: .attach)
        do {
            _ = try await runner.run(CommandLine(executable: "", arguments: []), onLine: nil)
            XCTFail()
        } catch let error as HelperClientError {
            XCTAssertEqual(error, .nothingRunning)
        }
        await runner.close()
    }

    func testListenerRejectsWhenPolicySaysNo() async throws {
        journal = ScriptedRunner.Journal()
        let j = journal!
        let manager = TunnelManager(validator: HelperRequestValidator(gpclientPath: gp, vpncScriptPath: script), runnerFactory: { ScriptedRunner(lines: [], journal: j) })
        delegate = HelperListenerDelegate(manager: manager, accept: { _ in false })
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let runner = makeRunner()
        do {
            _ = try await runner.status()
            XCTFail("a rejected connection must surface as an error, not hang or succeed")
        } catch let error as HelperClientError {
            guard case .connectionFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(delegate.openConnections, 0)
        await runner.close()
    }
}

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ l: String) { lock.withLock { _lines.append(l) } }
}
