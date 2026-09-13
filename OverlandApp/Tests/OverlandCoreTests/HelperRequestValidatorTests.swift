import XCTest
@testable import OverlandCore

final class HelperRequestValidatorTests: XCTestCase {
    private let gp = "/Applications/Overland.app/Contents/MacOS/gpclient"
    private let script = "/Applications/Overland.app/Contents/Resources/vpnc-script"
    private let uid: UInt32 = 501

    private func validator(files: [String: HelperRequestValidator.FileInfo] = [:]) -> HelperRequestValidator {
        HelperRequestValidator(gpclientPath: gp, vpncScriptPath: script, fileInfo: { files[$0] })
    }

    /// Everything `GpclientCommandBuilder` can produce for the tunnel must pass.
    func testAcceptsEveryBuilderProducedTunnelCommand() throws {
        let builder = GpclientCommandBuilder(gpclientPath: gp, gpauthPath: "/x/gpauth")
        var sso = ConnectionProfile(portal: "vpn.example.com", selectedGatewayServer: "gw1.example.com", authMethod: .browserSSO)
        sso.vpncScriptPath = script
        sso.fixOpenSSL = true; sso.ignoreTLSErrors = true; sso.enableHIP = true
        sso.disableIPv6 = true; sso.noDTLS = true; sso.mtu = 1400; sso.forceDPD = 20; sso.reconnectTimeout = 60
        var pw = ConnectionProfile(portal: "vpn.example.com", username: "alice", authMethod: .credentials)
        pw.vpncScriptPath = script
        var cert = ConnectionProfile(portal: "vpn.example.com", authMethod: .clientCertificate)
        cert.vpncScriptPath = script
        cert.certificatePath = "/Users/alice/me.p12"; cert.sslKeyPath = "/Users/alice/me.key"
        var gw = ConnectionProfile(portal: "gw.example.com:443", authMethod: .browserSSO)
        gw.asGateway = true; gw.vpncScriptPath = script

        let files = [
            "/Users/alice/me.p12": HelperRequestValidator.FileInfo(isRegularFile: true, ownerUID: uid),
            "/Users/alice/me.key": HelperRequestValidator.FileInfo(isRegularFile: true, ownerUID: uid)
        ]
        let v = validator(files: files)
        for (profile, password, auth) in [(sso, nil, "{\"success\":{}}"), (pw, "pw", nil), (cert, nil, nil), (gw, nil, "{}")] as [(ConnectionProfile, String?, String?)] {
            let cmd = builder.tunnelCommand(profile: profile, password: password, authResult: auth)
            let approved = try v.validate(executable: cmd.executable, arguments: cmd.arguments, callerUID: uid)
            XCTAssertEqual(approved.arguments, cmd.arguments, "validated argv must be exactly what was asked")
        }
        let disconnect = builder.disconnectCommand(profile: pw)
        XCTAssertEqual(try v.validate(executable: disconnect.executable, arguments: disconnect.arguments, callerUID: uid).arguments, ["disconnect"])
    }

    private func reject(_ args: [String], executable: String? = nil, files: [String: HelperRequestValidator.FileInfo] = [:], line: UInt = #line) -> HelperRequestValidator.Rejection? {
        do {
            _ = try validator(files: files).validate(executable: executable ?? gp, arguments: args, callerUID: uid)
            XCTFail("expected rejection for \(args)", line: line)
            return nil
        } catch let r as HelperRequestValidator.Rejection {
            return r
        } catch {
            XCTFail("unexpected \(error)", line: line)
            return nil
        }
    }

    /// `/Applications` is a firmlink on APFS: the helper may see the bundle as
    /// /System/Volumes/Data/Applications while the app says /Applications.
    func testExecutableComparisonSurvivesSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hrv-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("real/MacOS"), withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real/MacOS/gpclient")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("real"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let viaLink = link.appendingPathComponent("MacOS/gpclient").path
        let v = HelperRequestValidator(gpclientPath: real.path, vpncScriptPath: script, fileInfo: { _ in nil })
        XCTAssertNoThrow(try v.validate(executable: viaLink, arguments: ["connect", "vpn.example.com"], callerUID: uid))
        let v2 = HelperRequestValidator(gpclientPath: viaLink, vpncScriptPath: script, fileInfo: { _ in nil })
        XCTAssertNoThrow(try v2.validate(executable: real.path, arguments: ["connect", "vpn.example.com"], callerUID: uid))
    }

    func testRejectsForeignExecutable() {
        XCTAssertEqual(reject(["connect", "vpn.example.com"], executable: "/tmp/gpclient"), .wrongExecutable("/tmp/gpclient"))
    }

    func testRejectsOtherSubcommandsAndArbitraryArgs() {
        XCTAssertEqual(reject(["launch-gui"]), .unknownSubcommand("launch-gui"))
        XCTAssertEqual(reject([]), .missingSubcommand)
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--script-tun"]), .unknownFlag("--script-tun"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--hip-user", "root"]), .unknownFlag("--hip-user"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "extra"]), .unknownFlag("extra"))
        XCTAssertEqual(reject(["disconnect", "--wait", "5"]), .unknownFlag("--wait"))
        XCTAssertEqual(reject(["--gateway", "x", "connect", "vpn.example.com"]), .unknownFlag("--gateway"), "connect-only flags are not global")
    }

    func testRejectsShellishServers() {
        XCTAssertEqual(reject(["connect", "vpn.example.com; rm -rf /"]), .badHostname("vpn.example.com; rm -rf /"))
        XCTAssertEqual(reject(["connect", "-evil"]), .badHostname("-evil"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--gateway", "gw example"]), .badHostname("gw example"))
        XCTAssertEqual(reject(["connect", "--gateway", "gw"]), .missingValue("connect <server>"))
    }

    func testRejectsBadValues() {
        XCTAssertEqual(reject(["--log-format", "yaml", "connect", "vpn.example.com"]), .badLogFormat("yaml"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--mtu", "big"]), .badNumber("--mtu", "big"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--mtu"]), .missingValue("--mtu"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--gateway", "a", "--gateway", "b"]), .duplicateFlag("--gateway"))
    }

    func testScriptMustBeTheBundledCopy() {
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--script", "/tmp/evil.sh"]), .scriptNotBundled("/tmp/evil.sh"))
    }

    func testCertificateFilesMustBelongToCaller() {
        let files = [
            "/etc/sudoers": HelperRequestValidator.FileInfo(isRegularFile: true, ownerUID: 0),
            "/Users/alice": HelperRequestValidator.FileInfo(isRegularFile: false, ownerUID: uid)
        ]
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--certificate", "/etc/sudoers"], files: files), .fileNotOwnedByCaller("/etc/sudoers"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--sslkey", "/Users/alice"], files: files), .fileNotReadable("/Users/alice"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--sslkey", "/nope"], files: files), .fileNotReadable("/nope"))
    }

    func testHipScriptValidation() throws {
        let files = [
            "/Users/alice/hip.sh": HelperRequestValidator.FileInfo(isRegularFile: true, ownerUID: uid),
            "/etc/sudoers": HelperRequestValidator.FileInfo(isRegularFile: true, ownerUID: 0),
            "/Users/alice/dir": HelperRequestValidator.FileInfo(isRegularFile: false, ownerUID: uid)
        ]
        let v = validator(files: files)
        // Valid file owned by caller
        let approved = try v.validate(executable: gp, arguments: ["connect", "vpn.example.com", "--hip", "/Users/alice/hip.sh"], callerUID: uid)
        XCTAssertEqual(approved.arguments, ["connect", "vpn.example.com", "--hip", "/Users/alice/hip.sh"])

        // --hip without path
        let approvedNoPath = try v.validate(executable: gp, arguments: ["connect", "vpn.example.com", "--hip", "--disable-ipv6"], callerUID: uid)
        XCTAssertEqual(approvedNoPath.arguments, ["connect", "vpn.example.com", "--hip", "--disable-ipv6"])

        // Rejections for not owned, directory, or missing
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--hip", "/etc/sudoers"], files: files), .fileNotOwnedByCaller("/etc/sudoers"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--hip", "/Users/alice/dir"], files: files), .fileNotReadable("/Users/alice/dir"))
        XCTAssertEqual(reject(["connect", "vpn.example.com", "--hip", "/missing.sh"], files: files), .fileNotReadable("/missing.sh"))
    }

    func testStatFileReportsOwnerAndType() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hrv-\(UUID().uuidString)")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let info = try XCTUnwrap(HelperRequestValidator.statFile(tmp.path))
        XCTAssertTrue(info.isRegularFile)
        XCTAssertEqual(info.ownerUID, getuid())
        XCTAssertNil(HelperRequestValidator.statFile("/definitely/missing"))
    }
}
