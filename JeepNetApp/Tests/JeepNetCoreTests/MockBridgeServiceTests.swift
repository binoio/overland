import XCTest
@testable import JeepNetCore

final class MockBridgeServiceTests: XCTestCase {
    func testDiscoverGateways() async throws {
        let bridge = MockBridgeService(stepDelayNanoseconds: 0)
        let gateways = try await bridge.discoverGateways(profile: ConnectionProfile(portal: "vpn.corp.com"), password: nil)
        XCTAssertEqual(gateways, MockBridgeService.sampleGateways)
    }

    func testConnectEmitsLifecycleStates() async throws {
        let bridge = MockBridgeService(stepDelayNanoseconds: 0)
        let recorder = EventRecorder()
        recorder.attach(await bridge.events())
        defer { recorder.stop() }

        let profile = ConnectionProfile(portal: "vpn.example.com", selectedGatewayServer: "us-west.gp.example.com", username: "bob", authMethod: .browserSSO)
        try await bridge.connect(profile: profile, password: nil)

        let connected = await recorder.wait { $0.contains { if case .state(.connected) = $0 { return true } else { return false } } }
        XCTAssertTrue(connected)

        guard case .connected(let details)? = recorder.states.last else { return XCTFail("\(recorder.states)") }
        XCTAssertEqual(details.gatewayServer, "us-west.gp.example.com")
        XCTAssertEqual(details.gatewayName, "US West (Oregon)")
        XCTAssertNotNil(details.assignedIP)
        XCTAssertTrue(recorder.states.contains { if case .connecting(let s) = $0 { return s.contains("browser") } else { return false } })
        XCTAssertTrue(recorder.events.contains(.gateways(MockBridgeService.sampleGateways)))

        try await bridge.disconnect()
        let disconnected = await recorder.wait { $0.last == .state(.disconnected) }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(recorder.states.contains(.disconnecting))
    }

    func testDisconnectWhenIdleIsNoop() async throws {
        let bridge = MockBridgeService(stepDelayNanoseconds: 0)
        try await bridge.disconnect()
        let state = await bridge.currentState
        XCTAssertEqual(state, .disconnected)
    }
}
