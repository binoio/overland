import XCTest
@testable import OverlandCore

/// Exercises the real `gpclient` binary through the real `ProcessRunner`.
///
/// Skipped when no gpclient is available (CI containers). Locally, a Cargo
/// build in the repository (`target/release/gpclient`) or a Homebrew install
/// is picked up automatically. No network access is required: the portal
/// name is under the reserved `.invalid` TLD, so DNS fails deterministically.
final class RealGpclientIntegrationTests: XCTestCase {
    private var gpclient: String?

    override func setUpWithError() throws {
        gpclient = BinaryLocator().resolveGpclient(custom: ProcessInfo.processInfo.environment["GPCLIENT"])
        try XCTSkipIf(gpclient == nil, "gpclient not found; build it with Scripts/build_gpclient.sh")
        // gpclient refuses to start while another instance holds its lock, so a
        // live VPN session on this machine would turn every run into a failure.
        try XCTSkipIf(Self.anotherGpclientIsRunning(), "a gpclient tunnel is running on this machine")
    }

    private static func anotherGpclientIsRunning() -> Bool {
        guard let text = try? String(contentsOfFile: "/var/run/gpclient.lock", encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func testVersionRunsThroughProcessRunner() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(CommandLine(executable: gpclient!, arguments: ["--version"]))
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stdout.hasPrefix("gpclient "), result.stdout)
    }

    func testDiscoveryAgainstUnresolvablePortalReportsDnsFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gp-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = GpclientBridgeService(
            customGpclientPath: gpclient,
            temporaryDirectory: tmp
        )
        let recorder = EventRecorder()
        recorder.attach(await service.events())
        defer { recorder.stop() }

        let profile = ConnectionProfile(portal: "portal.invalid", username: "alice", authMethod: .credentials)
        do {
            _ = try await service.discoverGateways(profile: profile, password: "pw")
            XCTFail("expected failure")
        } catch let error as BridgeError {
            guard case .authFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("portal.invalid"), reason)
            XCTAssertTrue(reason.lowercased().contains("lookup") || reason.lowercased().contains("dns"), reason)
        }

        // The JSON log stream was parsed into structured entries.
        XCTAssertTrue(recorder.logs.contains { $0.message.hasPrefix("gpclient started") })
        XCTAssertTrue(recorder.logs.contains { $0.message.hasPrefix("gpclient started") })
        XCTAssertTrue(recorder.logs.contains { $0.level == .error })
        let state = await service.currentState
        XCTAssertEqual(state, .disconnected, "discovery restores the idle state")
    }
}
