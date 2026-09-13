import XCTest
@testable import OverlandCore

final class ConnectionProfileTests: XCTestCase {
    func testDefaultProfile() {
        let profile = ConnectionProfile.default
        XCTAssertEqual(profile.portal, "")
        XCTAssertEqual(profile.authMethod, .browserSSO)
        XCTAssertEqual(profile.privilegeMode, .helper)
        XCTAssertEqual(profile.browserMode, .systemDefault)
        XCTAssertEqual(profile.reconnectTimeout, 300)
        XCTAssertFalse(profile.disableIPv6)
        XCTAssertEqual(profile.mtu, 0)
        XCTAssertTrue(profile.knownGateways.isEmpty)
    }

    func testProfileRoundTrip() throws {
        var profile = ConnectionProfile(
            name: "Enterprise VPN",
            portal: "portal.corp.com",
            selectedGatewayServer: "gw1.corp.com",
            username: "alice",
            authMethod: .browserSSO,
            browserMode: .chrome,
            disableIPv6: true,
            noDTLS: true,
            ignoreTLSErrors: true,
            mtu: 1380,
            forceDPD: 30,
            reconnectTimeout: 60,
            enableHIP: true,
            vpncScriptPath: "/opt/vpnc-script",
            privilegeMode: .adminPrompt,
            autoConnect: true,
            knownGateways: [Gateway(name: "GW1", server: "gw1.corp.com", priority: 1)]
        )
        profile.fixOpenSSL = true

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile, decoded)
    }

    /// Profiles written by the first build of the app lack every key added
    /// since; they must still load with sensible defaults.
    func testDecodesLegacyProfileWithMissingKeys() throws {
        let legacy = """
        {"id":"2D6B9E0B-4B2F-4C51-8E39-3B7C5B2E0F11","name":"Old","portal":"vpn.old.com","username":"bob",
         "authMethod":"Username & Password","disableIPv6":false,"noDTLS":false,"ignoreTLSErrors":false,
         "fixOpenSSL":false,"mtu":0,"forceDPD":0,"autoConnect":false}
        """
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.portal, "vpn.old.com")
        XCTAssertEqual(decoded.username, "bob")
        XCTAssertEqual(decoded.privilegeMode, .helper)
        XCTAssertEqual(decoded.browserMode, .systemDefault)
        XCTAssertEqual(decoded.reconnectTimeout, 300)
        XCTAssertTrue(decoded.knownGateways.isEmpty)
    }

    /// Modes removed since earlier builds decode to the dialog rather than
    /// failing the whole profile.
    func testRemovedPrivilegeModesDecodeToAdminPrompt() throws {
        for legacy in ["sudoAskpass", "sudoNonInteractive", "direct", "bogus"] {
            let json = #"{"portal":"x","privilegeMode":"\#(legacy)"}"#
            let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.privilegeMode, .adminPrompt, legacy)
        }
        let helper = try JSONDecoder().decode(ConnectionProfile.self, from: Data(#"{"portal":"x","privilegeMode":"helper"}"#.utf8))
        XCTAssertEqual(helper.privilegeMode, .helper)
    }
}

final class GatewayTests: XCTestCase {
    func testGatewayDisplayName() {
        XCTAssertEqual(Gateway(name: "US East", server: "us-east.example.com").displayName, "US East (us-east.example.com)")
        XCTAssertEqual(Gateway(name: "us-east.example.com", server: "us-east.example.com").displayName, "us-east.example.com")
        XCTAssertEqual(Gateway(name: "", server: "gw.example.com").displayName, "gw.example.com")
    }

    func testGatewayCodableRoundTrip() throws {
        let original = Gateway(name: "Tokyo", server: "jp.example.com", priority: 2, latencyMs: 120.0, isManual: true)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Gateway.self, from: data), original)
    }

    func testGatewayDecodesWithoutOptionalKeys() throws {
        let decoded = try JSONDecoder().decode(Gateway.self, from: Data(#"{"name":"A","server":"a.example.com"}"#.utf8))
        XCTAssertEqual(decoded.priority, 1)
        XCTAssertFalse(decoded.isManual)
        XCTAssertNil(decoded.latencyMs)
    }
}

final class VpnStateTests: XCTestCase {
    func testDisconnectedStateProperties() {
        let state = VpnState.disconnected
        XCTAssertTrue(state.isDisconnected)
        XCTAssertFalse(state.isConnected)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.title, "Disconnected")
    }

    func testConnectingAndDisconnectingAreBusy() {
        XCTAssertTrue(VpnState.connecting(status: "Authenticating…").isBusy)
        XCTAssertTrue(VpnState.disconnecting.isBusy)
        XCTAssertFalse(VpnState.failed(message: "x").isBusy)
        XCTAssertEqual(VpnState.connecting(status: "").title, "Connecting…")
    }

    func testConnectedStateProperties() {
        let details = ConnectedDetails(
            portal: "vpn.corp.com",
            gatewayName: "US-East-1",
            gatewayServer: "us-east.vpn.corp.com",
            assignedIP: "10.0.1.50",
            interfaceName: "utun4",
            sessionExpiresAt: Date().addingTimeInterval(3600)
        )
        let state = VpnState.connected(details)
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.title, "Connected to US-East-1")
        XCTAssertGreaterThan(details.sessionRemainingSeconds ?? 0, 3500)
    }

    func testFailedStateProperties() {
        let state = VpnState.failed(message: "Invalid credentials")
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.title, "Connection Failed: Invalid credentials")
    }

    func testSessionMetricsFormatting() {
        var metrics = SessionMetrics(bytesReceived: 1_048_576, bytesSent: 2048, duration: 3725)
        XCTAssertEqual(metrics.formattedDuration, "01:02:05")
        metrics.duration = 65
        XCTAssertEqual(metrics.formattedDuration, "01:05")
        XCTAssertTrue(metrics.formattedBytesReceived.contains("MB"))
    }
}
