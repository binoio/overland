import XCTest
@testable import GlobalProtectCore

final class AuthCallbackForwarderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-cb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingPortFileMeansNoPendingLogin() async {
        let forwarder = AuthCallbackForwarder(temporaryDirectory: tempDir)
        XCTAssertNil(forwarder.readPort())
        do {
            try await forwarder.forward(authData: "globalprotectcallback:abc")
            XCTFail("expected an error")
        } catch let error as AuthCallbackForwarder.ForwardError {
            XCTAssertEqual(error, .noPendingLogin)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReadsPortFile() throws {
        try "  54321\n".write(to: tempDir.appendingPathComponent(AuthCallbackForwarder.portFileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(AuthCallbackForwarder(temporaryDirectory: tempDir).readPort(), 54321)
    }

    func testConnectionRefusedIsReported() async throws {
        // Port 1 (tcpmux) is closed on every development machine.
        try "1".write(to: tempDir.appendingPathComponent(AuthCallbackForwarder.portFileName), atomically: true, encoding: .utf8)
        do {
            try await AuthCallbackForwarder(temporaryDirectory: tempDir).forward(authData: "x")
            XCTFail("expected connection failure")
        } catch let error as AuthCallbackForwarder.ForwardError {
            guard case .connectionFailed = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// End-to-end over loopback: a listener plays the role of the waiting
    /// gpclient and must receive the payload byte-for-byte.
    func testForwardsPayloadToLoopbackListener() async throws {
        let listener = try LoopbackListener()
        try "\(listener.port)".write(to: tempDir.appendingPathComponent(AuthCallbackForwarder.portFileName), atomically: true, encoding: .utf8)

        let payload = "globalprotectcallback:cas-as=1&un=alice@example.com&token=tok"
        try await AuthCallbackForwarder(temporaryDirectory: tempDir).forward(authData: payload)

        XCTAssertEqual(listener.waitForPayload(), payload)
    }
}
