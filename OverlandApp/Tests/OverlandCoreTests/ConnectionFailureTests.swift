import XCTest
@testable import OverlandCore

final class ConnectionFailureTests: XCTestCase {
    func testClassifiesCommonFailures() {
        let cases: [(String, ConnectionFailure.Kind)] = [
            ("error sending request for url (https://portal.invalid/prelogin.esp) — failed to lookup address information: nodename nor servname provided", .portalUnreachable),
            ("error sending request for url (https://vpn.princeton.edu/…) — Network is unreachable (os error 51)", .portalUnreachable),
            ("Sign-in failed: No auth data found", .signInIncomplete),
            ("gpauth exited with code 1 without a sign-in result", .signInIncomplete),
            ("Administrator authorization was cancelled or denied. The tunnel needs root to create the utun device.", .authorizationDeclined),
            ("The privileged helper refused the request: request refused: refusing to run /x: only the bundled gpclient is allowed", .helperRefused),
            ("Another instance of the client is already running", .anotherClientRunning),
            ("The VPN tunnel dropped (gpclient exit code 2)", .tunnelDropped),
            ("Reconnect failed: Connection refused", .portalUnreachable),
            ("Cannot find gateway specified: gw9", .gatewayRejected),
            ("something entirely new", .other),
        ]
        for (message, kind) in cases {
            let f = ConnectionFailure.classify(message)
            XCTAssertEqual(f.kind, kind, message)
            XCTAssertEqual(f.detail, message)
            XCTAssertFalse(f.title.isEmpty)
            XCTAssertFalse(f.advice.isEmpty)
        }
    }

    func testParserEmitsSignInURL() {
        let events = GpclientOutputParser().parse(line: #"{"level":"INFO","message":"auth server started at: http://127.0.0.1:54321/abc","target":"auth"}"#)
        XCTAssertEqual(events.last, .signInURL("http://127.0.0.1:54321/abc"))
    }

    func testSSOIsTheDefaultAuthMethod() {
        XCTAssertEqual(ConnectionProfile().authMethod, .browserSSO)
    }
}
