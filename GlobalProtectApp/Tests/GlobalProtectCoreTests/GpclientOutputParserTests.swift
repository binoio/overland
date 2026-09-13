import XCTest
@testable import GlobalProtectCore

final class GpclientOutputParserTests: XCTestCase {
    private let parser = GpclientOutputParser()

    func testParsesJsonRecordIntoLogEntry() {
        let events = parser.parse(line: jsonLog("WARN", "TLS errors will be ignored"))
        guard case .log(let entry)? = events.first else { return XCTFail("expected log event") }
        XCTAssertEqual(entry.level, .warn)
        XCTAssertEqual(entry.message, "TLS errors will be ignored")
        XCTAssertEqual(events.count, 1)
    }

    func testTimestampIsTakenFromRecord() {
        let events = parser.parse(line: jsonLog("INFO", "hello"))
        guard case .log(let entry)? = events.first else { return XCTFail() }
        let expected = try! Date("2026-09-13T02:24:56.810Z", strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMapsTraceAndDebugLevels() {
        for level in ["TRACE", "DEBUG"] {
            guard case .log(let entry)? = parser.parse(line: jsonLog(level, "x")).first else { return XCTFail() }
            XCTAssertEqual(entry.level, .debug)
        }
    }

    func testCookieAndHostLines() {
        XCTAssertEqual(parser.parse(line: "COOKIE='abc=='"), [.cookie("abc==")])
        XCTAssertEqual(parser.parse(line: "HOST='gw.example.com'"), [.host("gw.example.com")])
    }

    func testGpauthResultLines() {
        let success = #"{"success":{"username":"alice","preloginCookie":"abc","portalUserauthcookie":null}}"#
        XCTAssertEqual(parser.parse(line: success), [.authResult(success)])
        XCTAssertEqual(parser.parse(line: #"{"failure":"No auth data found"}"#), [.authFailure("No auth data found")])
    }

    func testGatewaySelectedLines() {
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Connecting to the selected gateway: US East (us1.vpn.example.com)")).last,
                       .gatewaySelected(name: "US East", server: "us1.vpn.example.com"))
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Connecting to the only available gateway: gw (gw.example.com)")).last,
                       .gatewaySelected(name: "gw", server: "gw.example.com"))
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Auto-gateway: attempting gateway EU (eu.example.com)")).last,
                       .gatewaySelected(name: "EU", server: "eu.example.com"))
    }

    func testGatewayInventoryLine() {
        let events = parser.parse(line: jsonLog("INFO", "Gateway: US East (us1.vpn.example.com) priority=1"))
        XCTAssertEqual(events.last, .gatewayDiscovered(Gateway(name: "US East", server: "us1.vpn.example.com", priority: 1)))
    }

    func testGatewayInventoryLineWithEmptyName() {
        let events = parser.parse(line: jsonLog("INFO", "Gateway:  (gw.example.com) priority=0"))
        XCTAssertEqual(events.last, .gatewayDiscovered(Gateway(name: "gw.example.com", server: "gw.example.com", priority: 0)))
    }

    func testGatewayCountLine() {
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Found 3 gateways in portal config")).last, .gatewayCount(3))
    }

    func testTunnelConnected() {
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Connected to VPN, pipe_fd: 7")).last, .tunnelConnected)
    }

    func testSessionInfoParsing() {
        let msg = "VPN session info: lifetime_secs=28800 (8h), user_expires=1789200000 (2026-09-13 12:00:00, in 2h), lifetime_warning_prior=300 (5m), allow_extend_session=true"
        let events = parser.parse(line: jsonLog("INFO", msg))
        XCTAssertEqual(events.last, .sessionInfo(lifetimeSeconds: 28800, userExpires: Date(timeIntervalSince1970: 1_789_200_000), allowExtend: true))
    }

    func testSessionInfoWithoutValues() {
        let msg = "VPN session info: lifetime_secs=none, user_expires=none, lifetime_warning_prior=none, allow_extend_session=false"
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", msg)).last, .sessionInfo(lifetimeSeconds: nil, userExpires: nil, allowExtend: false))
    }

    func testSessionExtendedAndWarnings() {
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Session extended.")).last, .sessionExtended)
        XCTAssertEqual(parser.parse(line: jsonLog("WARN", "WARNING: Your session will expire in 5 minutes")).last, .sessionWarning("Your session will expire in 5 minutes"))
    }

    func testBrowserEvents() {
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Launching the default browser...")).last, .browserLaunched)
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Launching browser: /Applications/Google Chrome.app")).last, .browserLaunched)
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Please continue the authentication process in the default browser")).last, .awaitingBrowser)
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", "Received the browser authentication data from the socket")).last, .authDataReceived)
    }

    func testManualAuthURL() {
        let msg = "\n\n==== Manual Authentication Required ====\n\nPlease open the following URL in your browser:\n\nhttp://192.168.1.5:54321/\n\nAfter completing..."
        XCTAssertEqual(parser.parse(line: jsonLog("INFO", msg)).last, .manualAuthURL("http://192.168.1.5:54321/"))
    }

    func testErrorRecordProducesFatalErrorWithRootCause() {
        let anyhow = "error sending request for url (https://portal.invalid/prelogin.esp)\n\nCaused by:\n    0: client error (Connect)\n    1: dns error\n    2: failed to lookup address information: nodename nor servname provided, or not known"
        let events = parser.parse(line: jsonLog("ERROR", anyhow))
        XCTAssertEqual(events.last, .fatalError("error sending request for url (https://portal.invalid/prelogin.esp) — failed to lookup address information: nodename nor servname provided, or not known"))
    }

    func testErrorWithoutCauseChainKeepsHeadline() {
        XCTAssertEqual(parser.parse(line: jsonLog("ERROR", "Another instance of the client is already running")).last,
                       .fatalError("Another instance of the client is already running"))
    }

    func testPlainTextSudoFailureIsAnError() {
        let events = parser.parse(line: "sudo: a password is required")
        guard case .log(let entry)? = events.first else { return XCTFail() }
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(events.last, .fatalError("sudo: a password is required"))
    }

    func testPlainTextInfoLine() {
        let events = parser.parse(line: "Password:")
        XCTAssertEqual(events.count, 1)
        guard case .log(let entry)? = events.first else { return XCTFail() }
        XCTAssertEqual(entry.level, .info)
    }

    func testBlankLinesAreIgnored() {
        XCTAssertTrue(parser.parse(line: "   \n").isEmpty)
    }
}
