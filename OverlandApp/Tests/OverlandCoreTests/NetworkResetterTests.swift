import XCTest
@testable import OverlandCore

private actor StubResetRunner: ProcessRunning {
    let result: ProcessResult
    let emittedLines: [String]
    private(set) var lastCommand: CommandLine?
    private(set) var isRunning = false

    init(result: ProcessResult = ProcessResult(exitCode: 0), emittedLines: [String] = []) {
        self.result = result
        self.emittedLines = emittedLines
    }

    func run(_ command: CommandLine, onLine: (@Sendable (ProcessStream, String) -> Void)?) async throws -> ProcessResult {
        lastCommand = command
        isRunning = true
        defer { isRunning = false }
        for line in emittedLines {
            onLine?(.stdout, line)
        }
        return result
    }

    func interrupt() {}
    func terminate() {}
}

final class NetworkResetterTests: XCTestCase {
    func testResetScriptHasValidBashSyntax() async throws {
        let runner = ProcessRunner()
        let cmd = CommandLine(executable: "/bin/bash", arguments: ["-n"], stdin: NetworkResetter.resetScript)
        let result = try await runner.run(cmd)
        XCTAssertEqual(result.exitCode, 0, "bash -n failed: \(result.stderr)")
    }

    func testResetScriptCoversAllOverlandNetworkArtifacts() {
        let script = NetworkResetter.resetScript
        XCTAssertTrue(script.contains("pkill -INT -x gpclient"))
        XCTAssertTrue(script.contains("pkill -KILL -x gpclient"))
        XCTAssertTrue(script.contains("State:/Network/Service/utun"))
        XCTAssertTrue(script.contains("scutil"))
        XCTAssertTrue(script.contains("networksetup -setdnsservers"))
        XCTAssertTrue(script.contains("networksetup -setsearchdomains"))
        XCTAssertTrue(script.contains("dscacheutil -flushcache"))
        XCTAssertTrue(script.contains("killall -HUP mDNSResponder"))
        XCTAssertTrue(script.contains("ipconfig set"))
        XCTAssertTrue(script.contains("/var/run/vpnc"))
        XCTAssertTrue(script.contains("#@VPNC_GENERATED@"))
    }

    func testRootCommandUsesBashWithScript() {
        let cmd = NetworkResetter.rootCommand()
        XCTAssertEqual(cmd.executable, "/bin/bash")
        XCTAssertEqual(cmd.arguments.first, "-c")
        XCTAssertEqual(cmd.arguments.last, NetworkResetter.resetScript)
    }

    func testAdminPromptCommandUsesBase64AndOsascript() {
        let cmd = NetworkResetter.adminPromptCommand()
        XCTAssertEqual(cmd.executable, "/usr/bin/osascript")
        XCTAssertEqual(cmd.arguments.first, "-e")
        let script = cmd.arguments.last ?? ""
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("/usr/bin/base64 -d | /bin/bash"))
    }

    func testRunAsRootStreamsOutputAndSucceeds() async throws {
        let stub = StubResetRunner(
            result: ProcessResult(exitCode: 0),
            emittedLines: ["Stopping any lingering VPN processes...", "Network reset complete."]
        )
        let collected = LineCollector()
        try await NetworkResetter.runAsRoot(using: stub) { line in
            collected.append(line)
        }
        let cmd = await stub.lastCommand
        XCTAssertEqual(cmd?.executable, "/bin/bash")
        XCTAssertEqual(collected.lines, ["Stopping any lingering VPN processes...", "Network reset complete."])
    }

    func testRunAsRootThrowsOnNonZeroExit() async {
        let stub = StubResetRunner(result: ProcessResult(exitCode: 1, stderr: "permission denied"))
        do {
            try await NetworkResetter.runAsRoot(using: stub)
            XCTFail("Expected failure")
        } catch let error as NetworkResetError {
            XCTAssertEqual(error, .failed("permission denied"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunWithAdminPromptDetectsUserCancel() async {
        let stub = StubResetRunner(result: ProcessResult(exitCode: 1, stderr: "execution error: User canceled. (-128)"))
        do {
            try await NetworkResetter.runWithAdminPrompt(using: stub)
            XCTFail("Expected cancellation")
        } catch let error as NetworkResetError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}
