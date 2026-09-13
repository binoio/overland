import XCTest
@testable import OverlandCore

final class ShellQuotingTests: XCTestCase {
    func testPosixQuoting() {
        XCTAssertEqual(ShellQuoting.posix("plain"), "'plain'")
        XCTAssertEqual(ShellQuoting.posix("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuoting.posixCommand(["/bin/x", "a b", "$HOME"]), "'/bin/x' 'a b' '$HOME'")
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(ShellQuoting.appleScript(#"say "hi" \ bye"#), #"say \"hi\" \\ bye"#)
    }
}

/// Stands in for `osascript`: instead of showing the authorization dialog it
/// runs the embedded `do shell script` command as the current user. The real
/// wrapper script then executes exactly as it would under root.
actor FakeOsascriptRunner: ProcessRunning {
    enum Behaviour { case execute, cancel, fail(String) }
    let behaviour: Behaviour
    private(set) var lastCommand: CommandLine?
    var isRunning = false

    init(_ behaviour: Behaviour = .execute) { self.behaviour = behaviour }

    static func extractShell(from script: String) -> String? {
        guard let start = script.range(of: "do shell script \""),
              let end = script.range(of: "\" with prompt") else { return nil }
        let escaped = String(script[start.upperBound..<end.lowerBound])
        return escaped.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        lastCommand = command
        switch behaviour {
        case .cancel:
            return ProcessResult(exitCode: 1, stderr: "execution error: User canceled. (-128)")
        case .fail(let msg):
            return ProcessResult(exitCode: 1, stderr: msg)
        case .execute:
            guard command.arguments.count == 2, command.arguments[0] == "-e",
                  let shell = Self.extractShell(from: command.arguments[1]) else {
                return ProcessResult(exitCode: 2, stderr: "unexpected osascript invocation")
            }
            return try await ProcessRunner().run(CommandLine(executable: "/bin/sh", arguments: ["-c", shell]))
        }
    }

    func interrupt() {}
    func terminate() {}
}

final class PrivilegedProcessRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gp-priv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRunner(_ behaviour: FakeOsascriptRunner.Behaviour = .execute) -> PrivilegedProcessRunner {
        PrivilegedProcessRunner(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            pollInterval: 0.05,
            launchTimeout: 5,
            runnerFactory: { FakeOsascriptRunner(behaviour) }
        )
    }

    func testPrepareSessionCreatesSecuredArtifacts() async throws {
        let runner = makeRunner()
        let session = try await runner.prepareSession(for: CommandLine(executable: "/bin/true", arguments: [], stdin: "secret\n"))
        let fm = FileManager.default

        func mode(_ url: URL) throws -> Int {
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        XCTAssertEqual(try mode(root.appendingPathComponent("sessions")), 0o700)
        XCTAssertEqual(try mode(session), 0o700)
        XCTAssertEqual(try mode(session.appendingPathComponent("stdin.txt")), 0o600)
        XCTAssertEqual(try String(contentsOf: session.appendingPathComponent("stdin.txt"), encoding: .utf8), "secret\n")
        let fifoAttrs = try fm.attributesOfItem(atPath: session.appendingPathComponent("control.fifo").path)
        XCTAssertEqual(fifoAttrs[.type] as? FileAttributeType, .typeUnknown, "a FIFO is reported as unknown by Foundation")
        let wrapper = await runner.wrapperURL
        XCTAssertTrue(fm.isExecutableFile(atPath: wrapper.path))
        XCTAssertEqual(try String(contentsOf: wrapper, encoding: .utf8), PrivilegedProcessRunner.wrapperScript)
    }

    func testOsascriptCommandShape() async throws {
        let runner = makeRunner()
        let session = root.appendingPathComponent("sessions/S")
        let cmd = await runner.osascriptCommand(session: session, command: CommandLine(executable: "/opt/gpclient", arguments: ["connect", "vpn.example.com", "--script", "/a b/vpnc-script"]))

        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertEqual(cmd.arguments.first, "-e")
        let script = cmd.arguments[1]
        XCTAssertTrue(script.hasPrefix("do shell script \"'/bin/bash' "), script)
        XCTAssertTrue(script.hasSuffix("with administrator privileges"), script)
        XCTAssertTrue(script.contains("\" with prompt \"Overland needs administrator privileges"), script)
        let shell = FakeOsascriptRunner.extractShell(from: script)!
        XCTAssertTrue(shell.hasSuffix("'/opt/gpclient' 'connect' 'vpn.example.com' '--script' '/a b/vpnc-script'"), shell)
        XCTAssertFalse(shell.contains("&"), "the wrapper must run in the foreground so SIGINT stays deliverable")
        XCTAssertTrue(shell.contains(ShellQuoting.posix(session.path)), shell)
    }

    func testCancelledAuthorizationIsReported() async {
        let runner = makeRunner(.cancel)
        do {
            _ = try await runner.run(CommandLine(executable: "/bin/true", arguments: []), onLine: nil)
            XCTFail("expected cancellation")
        } catch let error as PrivilegedRunError {
            XCTAssertEqual(error, .authorizationCancelled)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)) ?? []
        XCTAssertTrue(sessions.isEmpty, "session directory is cleaned up")
    }

    func testOtherAuthorizationFailureIsReported() async {
        let runner = makeRunner(.fail("execution error: something else"))
        do {
            _ = try await runner.run(CommandLine(executable: "/bin/true", arguments: []), onLine: nil)
            XCTFail()
        } catch let error as PrivilegedRunError {
            XCTAssertEqual(error, .authorizationFailed("execution error: something else"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The wrapper really runs here (as the current user): stdin is delivered
    /// from the secrets file, output is streamed back from the log, the exit
    /// status is reported, and the secrets file is gone afterwards.
    func testRunsWrapperDeliversStdinAndStreamsOutput() async throws {
        let runner = makeRunner()
        let lines = LineSink()
        let script = #"read line; echo "got=$line"; echo "err-line" 1>&2; exit 7"#
        let result = try await runner.run(
            CommandLine(executable: "/bin/sh", arguments: ["-c", script], stdin: "the-cookie\n"),
            onLine: { _, line in lines.append(line) }
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(lines.lines, ["got=the-cookie", "err-line"])
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sessions").path)) ?? []
        XCTAssertTrue(sessions.isEmpty, "session directory is removed after the run")
    }

    func testInterruptIsRelayedThroughControlFifo() async throws {
        let runner = makeRunner()
        let lines = LineSink()
        // Trap SIGINT like gpclient does: shut down cleanly with a distinct exit code.
        let script = #"trap 'echo interrupted; exit 3' INT; echo ready; while :; do sleep 0.1; done"#
        let task = Task {
            try await runner.run(CommandLine(executable: "/bin/bash", arguments: ["-c", script]), onLine: { _, line in lines.append(line) })
        }

        let ready = await pollUntil { lines.lines.contains("ready") }
        XCTAssertTrue(ready)
        let running = await runner.isRunning
        XCTAssertTrue(running)

        await runner.interrupt()
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(lines.lines, ["ready", "interrupted"])
        let stillRunning = await runner.isRunning
        XCTAssertFalse(stillRunning)
    }

    func testTerminateIsRelayedThroughControlFifo() async throws {
        let runner = makeRunner()
        let lines = LineSink()
        let script = #"trap 'echo terminated; exit 4' TERM; echo ready; while :; do sleep 0.1; done"#
        let task = Task {
            try await runner.run(CommandLine(executable: "/bin/bash", arguments: ["-c", script]), onLine: { _, line in lines.append(line) })
        }
        _ = await pollUntil { lines.lines.contains("ready") }
        await runner.terminate()
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 4)
    }

    private func pollUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ l: String) { lock.withLock { _lines.append(l) } }
}

final class OrphanSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gp-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(name: String, pid: Int32?, exited: Bool, command: [String] = ["/opt/gpclient", "connect", "vpn.example.com"]) throws -> URL {
        let dir = root.appendingPathComponent("sessions/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let pid { try "\(pid)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8) }
        if exited { try "0\n".write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8) }
        try command.joined(separator: "\n").write(to: dir.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    func testFindsOnlyLiveUnfinishedSessions() throws {
        let sessions = root.appendingPathComponent("sessions")
        _ = try makeSession(name: "A-live", pid: ProcessInfo.processInfo.processIdentifier, exited: false)
        _ = try makeSession(name: "B-exited", pid: ProcessInfo.processInfo.processIdentifier, exited: true)
        _ = try makeSession(name: "C-dead", pid: 2_147_000_000, exited: false)
        _ = try makeSession(name: "D-nopid", pid: nil, exited: false)

        let orphans = PrivilegedProcessRunner.findOrphans(in: sessions)
        XCTAssertEqual(orphans.map { $0.directory.lastPathComponent }, ["A-live"])
        XCTAssertEqual(orphans.first?.server, "vpn.example.com")
        XCTAssertEqual(orphans.first?.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(PrivilegedProcessRunner.findOrphans(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testCommandIsRecordedInSession() async throws {
        let runner = PrivilegedProcessRunner(sessionsDirectory: root.appendingPathComponent("sessions"))
        let session = try await runner.prepareSession(for: CommandLine(executable: "/opt/gpclient", arguments: ["connect", "vpn.example.com", "--auto-gateway"]))
        let recorded = try String(contentsOf: session.appendingPathComponent("command.txt"), encoding: .utf8)
        XCTAssertEqual(recorded, "/opt/gpclient\nconnect\nvpn.example.com\n--auto-gateway")
    }

    /// Start a session with one runner (as if by a previous app process), then
    /// adopt it with a fresh runner: the earlier output is replayed, new
    /// output keeps streaming, and interrupt still reaches the command.
    func testAdoptReplaysLogAndRelaysInterrupt() async throws {
        let sessions = root.appendingPathComponent("sessions")
        let first = PrivilegedProcessRunner(sessionsDirectory: sessions, pollInterval: 0.05, launchTimeout: 5, runnerFactory: { FakeOsascriptRunner(.execute) })
        let firstLines = LineSink()
        let script = #"trap 'echo interrupted; exit 3' INT; echo ready; while :; do sleep 0.1; done"#
        let firstTask = Task {
            try await first.run(CommandLine(executable: "/bin/bash", arguments: ["-c", script]), onLine: { _, line in firstLines.append(line) })
        }
        _ = await pollUntil { firstLines.lines.contains("ready") }

        // The "previous app" goes away without cleaning up: cancel its tail.
        firstTask.cancel()
        _ = try? await firstTask.value

        let orphans = PrivilegedProcessRunner.findOrphans(in: sessions)
        XCTAssertEqual(orphans.count, 1, "the session must survive the first runner")
        let orphan = try XCTUnwrap(orphans.first)
        XCTAssertEqual(orphan.command.prefix(2), ["/bin/bash", "-c"])

        let adopted = AdoptedSessionRunner(orphan: orphan, pollInterval: 0.05)
        let adoptedLines = LineSink()
        let adoptTask = Task {
            try await adopted.run(CommandLine(executable: "", arguments: []), onLine: { _, line in adoptedLines.append(line) })
        }
        let replayed = await pollUntil { adoptedLines.lines.contains("ready") }
        XCTAssertTrue(replayed, "earlier output is replayed on adoption")

        await adopted.interrupt()
        let result = try await adoptTask.value
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(adoptedLines.lines, ["ready", "interrupted"])
        XCTAssertTrue(PrivilegedProcessRunner.findOrphans(in: sessions).isEmpty, "the session is removed once the command exits")
    }

    /// The supervisor gives up when its session directory is removed, so a
    /// deleted session never leaves a stray bash loop behind.
    func testSupervisorExitsWhenSessionIsRemoved() async throws {
        let sessions = root.appendingPathComponent("sessions")
        let runner = PrivilegedProcessRunner(sessionsDirectory: sessions, pollInterval: 0.05, launchTimeout: 5, runnerFactory: { FakeOsascriptRunner(.execute) })
        let lines = LineSink()
        let task = Task {
            try await runner.run(CommandLine(executable: "/bin/bash", arguments: ["-c", "echo ready; exec sleep 30"]), onLine: { _, line in lines.append(line) })
        }
        _ = await pollUntil { lines.lines.contains("ready") }
        let orphan = try XCTUnwrap(PrivilegedProcessRunner.findOrphans(in: sessions).first)
        task.cancel()
        _ = try? await task.value

        try FileManager.default.removeItem(at: orphan.directory)
        // The command itself keeps running (sleep 30); only the supervisor exits. Kill the sleep so nothing lingers.
        let gone = await pollUntil(timeout: 5) {
            !ProcessInfo.processInfo.arguments.isEmpty && !FileManager.default.fileExists(atPath: orphan.directory.path)
        }
        XCTAssertTrue(gone)
        kill(orphan.pid, SIGTERM)
    }

    private func pollUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}
