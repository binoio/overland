import XCTest
@testable import OverlandCore

final class TunInterfaceInspectorTests: XCTestCase {
    private let sample = """
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \tinet 127.0.0.1 netmask 0xff000000
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
    utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
    \tinet6 fe80::1%utun0 prefixlen 64 scopeid 0x10
    utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400
    \tinet 10.250.4.18 --> 10.250.4.18 netmask 0xffffffff
    """

    func testParsesUtunInterfacesWithIPv4() {
        let ifaces = TunInterfaceInspector.parse(sample)
        XCTAssertEqual(ifaces, [.init(name: "utun4", address: "10.250.4.18")])
    }

    func testNewInterfaceDetection() {
        let before: [TunInterfaceInspector.Interface] = [.init(name: "utun1", address: "10.0.0.1")]
        let after: [TunInterfaceInspector.Interface] = before + [.init(name: "utun4", address: "10.250.4.18")]
        XCTAssertEqual(TunInterfaceInspector.newInterface(before: before, after: after)?.name, "utun4")
        XCTAssertNil(TunInterfaceInspector.newInterface(before: before, after: before))
        XCTAssertNil(TunInterfaceInspector.newInterface(before: [], after: after), "ambiguous when two appeared")
    }

    func testSnapshotUsesInjectedReader() {
        let inspector = TunInterfaceInspector(readIfconfig: { "utun9: flags=0 mtu 1\n\tinet 1.2.3.4 --> 1.2.3.5 netmask 0xffffffff\n" })
        XCTAssertEqual(inspector.snapshot(), [.init(name: "utun9", address: "1.2.3.4")])
    }
}

final class InterfaceStatsReaderTests: XCTestCase {
    private let sample = """
    Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
    lo0        16384 <Link#1>                        12345     0    9876543    12345     0    9876543     0
    en0        1500  <Link#4>      aa:bb:cc:dd:ee:ff 100000     0  150000000    90000     0   80000000     0
    en0        1500  192.168.1     192.168.1.20      100000     -  150000000    90000     -   80000000     -
    utun4      1400  <Link#22>                         1234     0     567890      999     0     123456     0
    utun4      1400  10.250.4.18/32 10.250.4.18        1234     -     567890      999     -     123456     -
    """

    func testParsesLinkRowForInterface() {
        let counters = InterfaceStatsReader.parse(sample, interface: "utun4")
        XCTAssertEqual(counters, .init(packetsIn: 1234, bytesIn: 567890, packetsOut: 999, bytesOut: 123456))
    }

    func testParsesLinkRowWithAddressColumn() {
        let counters = InterfaceStatsReader.parse(sample, interface: "en0")
        XCTAssertEqual(counters, .init(packetsIn: 100000, bytesIn: 150000000, packetsOut: 90000, bytesOut: 80000000))
    }

    func testUnknownInterface() {
        XCTAssertNil(InterfaceStatsReader.parse(sample, interface: "utun7"))
    }
}

final class BinaryLocatorTests: XCTestCase {
    func testCustomPathWinsWhenExecutable() {
        let locator = BinaryLocator(
            fileExists: { _ in true },
            isExecutable: { $0 == "/custom/gpclient" },
            bundleURL: URL(fileURLWithPath: "/Applications/Overland.app"),
            searchPath: ["/opt/homebrew/bin"],
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(locator.resolveGpclient(custom: "/custom/gpclient"), "/custom/gpclient")
    }

    func testBundledBinaryPrecedesHomebrew() {
        let locator = BinaryLocator(
            fileExists: { _ in true },
            isExecutable: { $0.hasSuffix("Contents/MacOS/gpclient") || $0 == "/opt/homebrew/bin/gpclient" },
            bundleURL: URL(fileURLWithPath: "/Applications/Overland.app"),
            searchPath: [],
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(locator.resolveGpclient(custom: nil), "/Applications/Overland.app/Contents/MacOS/gpclient")
    }

    func testFallsBackToPathAndCargoTree() {
        let locator = BinaryLocator(
            fileExists: { _ in false },
            isExecutable: { $0 == "/Users/me/.homebrew/bin/gpclient" },
            bundleURL: nil,
            searchPath: ["/usr/bin", "/Users/me/.homebrew/bin"],
            workingDirectory: "/repo/OverlandApp"
        )
        XCTAssertEqual(locator.resolveGpclient(custom: nil), "/Users/me/.homebrew/bin/gpclient")

        let cargo = BinaryLocator(
            fileExists: { _ in false },
            isExecutable: { $0 == "/repo/target/release/gpclient" },
            bundleURL: nil,
            searchPath: [],
            workingDirectory: "/repo/OverlandApp"
        )
        XCTAssertEqual(cargo.resolveGpclient(custom: nil), "/repo/target/release/gpclient")
    }

    func testGpauthIsLookedUpNextToGpclientFirst() {
        let locator = BinaryLocator(
            fileExists: { _ in true },
            isExecutable: { $0 == "/custom/bin/gpauth" || $0 == "/opt/homebrew/bin/gpauth" },
            bundleURL: nil,
            searchPath: [],
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(locator.resolveGpauth(gpclientPath: "/custom/bin/gpclient"), "/custom/bin/gpauth")
        XCTAssertEqual(locator.resolveGpauth(gpclientPath: "/elsewhere/gpclient"), "/opt/homebrew/bin/gpauth")
        XCTAssertNil(BinaryLocator(fileExists: { _ in true }, isExecutable: { _ in false }, bundleURL: nil, searchPath: [], workingDirectory: "/").resolveGpauth(gpclientPath: nil))
    }

    func testVpncScriptSearchIncludesHomebrewPrefixFromPath() {
        let locator = BinaryLocator(
            fileExists: { _ in true },
            isExecutable: { $0 == "/Users/me/.homebrew/etc/vpnc/vpnc-script" },
            bundleURL: nil,
            searchPath: ["/Users/me/.homebrew/bin"],
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(locator.resolveVpncScript(custom: nil), "/Users/me/.homebrew/etc/vpnc/vpnc-script")
        XCTAssertNil(BinaryLocator(fileExists: { _ in true }, isExecutable: { _ in false }, bundleURL: nil, searchPath: [], workingDirectory: "/tmp").resolveVpncScript(custom: nil))
    }
}

final class SudoAskpassTests: XCTestCase {
    func testInstallWritesExecutableScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gp-askpass-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let askpass = SudoAskpass(directory: dir)
        let path = try askpass.install()

        XCTAssertEqual(path, dir.appendingPathComponent("overland-askpass.sh").path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o700)
        let body = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(body.contains("display dialog"))
        XCTAssertTrue(body.contains("with hidden answer"))

        // Second install is idempotent.
        XCTAssertEqual(try askpass.install(), path)
    }
}
