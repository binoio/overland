import XCTest
@testable import OverlandCore

final class GpclientCommandBuilderTests: XCTestCase {
    private let builder = GpclientCommandBuilder(
        gpclientPath: "/opt/gp/gpclient",
        gpauthPath: "/opt/gp/gpauth",
        tempDirectory: "/tmp/gp-test"
    )

    private let samlJSON = #"{"success":{"username":"alice","preloginCookie":"abc"}}"#

    // MARK: Browser step

    func testBrowserAuthCommandUsesGpauth() {
        let profile = ConnectionProfile(portal: "vpn.example.com", authMethod: .browserSSO, browserMode: .chrome)
        let cmd = builder.browserAuthCommand(profile: profile)

        XCTAssertEqual(cmd.executable, "/opt/gp/gpauth")
        XCTAssertEqual(cmd.arguments, ["--log-format", "json", "vpn.example.com", "--browser", "chrome"])
        XCTAssertNil(cmd.stdin)
        XCTAssertEqual(cmd.environment["TMPDIR"], "/tmp/gp-test", "gpauth writes gpcallback.port under TMPDIR")
        XCTAssertTrue(GpclientCommandBuilder.needsBrowserAuth(profile))
        XCTAssertFalse(GpclientCommandBuilder.needsBrowserAuth(ConnectionProfile(portal: "x", authMethod: .credentials)))
    }

    func testBrowserAuthAgainstGatewayPassesGatewayFlag() {
        var profile = ConnectionProfile(portal: "gw.example.com", authMethod: .browserSSO)
        profile.asGateway = true
        profile.ignoreTLSErrors = true
        let args = builder.browserAuthCommand(profile: profile).arguments
        XCTAssertEqual(args, ["--log-format", "json", "--ignore-tls-errors", "gw.example.com", "--gateway", "--browser", "default"])
    }

    // MARK: Tunnel (privileged) step

    func testTunnelCommandForSSOFeedsAuthResultOnStdin() {
        var profile = ConnectionProfile(portal: "vpn.example.com", authMethod: .browserSSO)
        profile.vpncScriptPath = "/opt/vpnc-script"
        let cmd = builder.tunnelCommand(profile: profile, password: nil, authResult: samlJSON)

        XCTAssertEqual(cmd.executable, "/opt/gp/gpclient")
        XCTAssertEqual(cmd.arguments, [
            "--log-format", "json",
            "connect", "vpn.example.com", "--auto-gateway", "--cookie-on-stdin",
            "--script", "/opt/vpnc-script"
        ])
        XCTAssertEqual(cmd.stdin, samlJSON + "\n")
        XCTAssertFalse(cmd.displayString.contains("preloginCookie"), "secrets must never appear in the logged command line")
    }

    func testTunnelCommandForCredentialsPassesUserAndPassword() {
        var profile = ConnectionProfile(portal: "vpn.example.com", selectedGatewayServer: "gw-eu.example.com", username: "alice", authMethod: .credentials)
        profile.vpncScriptPath = "/opt/vpnc-script"
        profile.disableIPv6 = true
        profile.noDTLS = true
        profile.mtu = 1400
        profile.forceDPD = 20
        profile.reconnectTimeout = 120
        profile.enableHIP = true
        let cmd = builder.tunnelCommand(profile: profile, password: "s3cret", authResult: nil)

        XCTAssertEqual(cmd.arguments, [
            "--log-format", "json",
            "connect", "vpn.example.com", "--gateway", "gw-eu.example.com",
            "--user", "alice", "--passwd-on-stdin",
            "--script", "/opt/vpnc-script",
            "--hip",
            "--disable-ipv6", "--no-dtls",
            "--mtu", "1400",
            "--force-dpd", "20",
            "--reconnect-timeout", "120"
        ])
        XCTAssertEqual(cmd.stdin, "s3cret\n")
        XCTAssertFalse(cmd.displayString.contains("s3cret"))
    }

    func testTunnelCommandForCertificate() {
        var profile = ConnectionProfile(portal: "vpn.example.com", authMethod: .clientCertificate)
        profile.certificatePath = "/keys/me.p12"
        profile.sslKeyPath = "/keys/me.key"
        let cmd = builder.tunnelCommand(profile: profile, password: "ignored", authResult: nil)
        XCTAssertTrue(cmd.arguments.contains(["--certificate", "/keys/me.p12"]))
        XCTAssertTrue(cmd.arguments.contains(["--sslkey", "/keys/me.key"]))
        XCTAssertFalse(cmd.arguments.contains("--passwd-on-stdin"))
        XCTAssertNil(cmd.stdin)
    }

    func testTunnelCommandWithSimulatedHIPScript() {
        var profile = ConnectionProfile(portal: "vpn.example.com", authMethod: .browserSSO)
        profile.enableHIP = true
        profile.rotateHIPValues = true
        profile.customHIPScriptPath = "/tmp/overland-hip-simulated.sh"
        let cmd = builder.tunnelCommand(profile: profile, password: nil, authResult: samlJSON)
        XCTAssertTrue(cmd.arguments.contains(["--hip", "/tmp/overland-hip-simulated.sh"]))

        // Also test passing explicit hipScriptPath argument
        let cmdExplicit = builder.tunnelCommand(profile: profile, password: nil, authResult: samlJSON, hipScriptPath: "/custom/sim-hip.sh")
        XCTAssertTrue(cmdExplicit.arguments.contains(["--hip", "/custom/sim-hip.sh"]))
    }

    /// `--fix-openssl` and `--ignore-tls-errors` are global clap flags: gpclient
    /// rejects them after the subcommand.
    func testGlobalFlagsPrecedeSubcommand() {
        var profile = ConnectionProfile(portal: "vpn.example.com", authMethod: .credentials)
        profile.fixOpenSSL = true
        profile.ignoreTLSErrors = true
        let args = builder.tunnelCommand(profile: profile, password: nil, authResult: nil).arguments

        let connectIndex = args.firstIndex(of: "connect")!
        XCTAssertLessThan(args.firstIndex(of: "--fix-openssl")!, connectIndex)
        XCTAssertLessThan(args.firstIndex(of: "--ignore-tls-errors")!, connectIndex)
        XCTAssertLessThan(args.firstIndex(of: "--log-format")!, connectIndex)
    }

    func testAsGatewayTunnel() {
        var profile = ConnectionProfile(portal: "gw.example.com", selectedGatewayServer: "other", authMethod: .browserSSO)
        profile.asGateway = true
        let args = builder.tunnelCommand(profile: profile, password: nil, authResult: samlJSON).arguments
        XCTAssertTrue(args.contains("--as-gateway"))
        XCTAssertFalse(args.contains("--gateway"))
        XCTAssertFalse(args.contains("--auto-gateway"))
    }

    // MARK: Discovery

    func testDiscoveryCommandIsUnprivilegedCookieOnly() {
        let sso = ConnectionProfile(portal: "vpn.example.com", selectedGatewayServer: "pinned", authMethod: .browserSSO)
        let cmd = builder.discoveryCommand(profile: sso, password: nil, authResult: samlJSON)
        XCTAssertEqual(cmd.executable, "/opt/gp/gpclient")
        XCTAssertEqual(cmd.arguments, ["--log-format", "json", "connect", "vpn.example.com", "--cookie-only", "--auto-gateway", "--cookie-on-stdin"])
        XCTAssertEqual(cmd.stdin, samlJSON + "\n")

        let pw = ConnectionProfile(portal: "vpn.example.com", username: "bob", authMethod: .credentials)
        let pwCmd = builder.discoveryCommand(profile: pw, password: "pw", authResult: nil)
        XCTAssertEqual(pwCmd.arguments, ["--log-format", "json", "connect", "vpn.example.com", "--cookie-only", "--auto-gateway", "--user", "bob", "--passwd-on-stdin"])
        XCTAssertEqual(pwCmd.stdin, "pw\n")
    }

    // MARK: Allow-list contract with the helper

    func testEveryEmittedTunnelFlagIsInTheAllowList() {
        var profile = ConnectionProfile(portal: "vpn.example.com", selectedGatewayServer: "gw", username: "u", authMethod: .credentials)
        profile.vpncScriptPath = "/s"; profile.certificatePath = "/c"; profile.sslKeyPath = "/k"
        profile.fixOpenSSL = true; profile.ignoreTLSErrors = true; profile.enableHIP = true
        profile.disableIPv6 = true; profile.noDTLS = true; profile.mtu = 1; profile.forceDPD = 1; profile.reconnectTimeout = 1
        let args = builder.tunnelCommand(profile: profile, password: "p", authResult: nil).arguments
        let flags = args.filter { $0.hasPrefix("--") }
        XCTAssertEqual(Set(flags).subtracting(GpclientCommandBuilder.allowedTunnelFlags.keys), [], "every flag the app emits must be accepted by the helper")
        XCTAssertEqual(Set(GpclientCommandBuilder.allowedTunnelFlags.keys).subtracting(flags + ["--auto-gateway", "--as-gateway", "--cookie-on-stdin"]), [], "allow-list should not carry flags the app never emits")
    }

    func testDisplayStringQuotesSpaces() {
        let cmd = CommandLine(executable: "/bin/x", arguments: ["a b", "c"])
        XCTAssertEqual(cmd.displayString, "/bin/x 'a b' c")
    }
}

private extension Array where Element == String {
    func contains(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, count >= sequence.count else { return false }
        for start in 0...(count - sequence.count) where Array(self[start..<start + sequence.count]) == sequence {
            return true
        }
        return false
    }
}
