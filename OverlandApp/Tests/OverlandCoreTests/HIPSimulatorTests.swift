import XCTest
@testable import OverlandCore

final class HIPSimulatorTests: XCTestCase {
    func testSimulatedIdentityDerivationIsDeterministicAndRotates() {
        let id0 = HIPSimulator.identity(for: 0)
        let id0Again = HIPSimulator.identity(for: 0)
        let id1 = HIPSimulator.identity(for: 1)
        let id2 = HIPSimulator.identity(for: 2)

        XCTAssertEqual(id0, id0Again)
        XCTAssertNotEqual(id0.hostId, id1.hostId)
        XCTAssertNotEqual(id1.hostId, id2.hostId)

        // Check format of simulated values
        XCTAssertEqual(id0.computerName, "Overland-Test-Mac-01")
        XCTAssertEqual(id1.computerName, "Overland-Test-Mac-02")
        XCTAssertEqual(id0.macAddress, "02:50:41:00:00:01")
        XCTAssertEqual(id1.macAddress, "02:50:41:00:00:02")
        XCTAssertEqual(id0.hostId, id0.macAddress, "On macOS, primary MAC is the host ID")
        XCTAssertEqual(id0.ipv4Address, "10.254.1.1")
        XCTAssertEqual(id1.ipv4Address, "10.254.1.2")
        XCTAssertTrue(id0.ipv6Address.hasPrefix("fd00:5041::"))
    }

    func testNegativeIndexNormalizesToZero() {
        let idNeg = HIPSimulator.identity(for: -5)
        let id0 = HIPSimulator.identity(for: 0)
        XCTAssertEqual(idNeg, id0)
    }

    func testGenerateXMLProducesValidReportWithSimulatedValues() {
        let id = HIPSimulator.identity(for: 3)
        let xml = HIPSimulator.generateXML(
            identity: id,
            md5: "abc123md5sum",
            userName: "testalice",
            domain: "corp.example.com",
            clientVersion: "6.2.4-49",
            date: Date(timeIntervalSince1970: 1780000000) // Deterministic date
        )

        XCTAssertTrue(xml.contains("<hip-report name=\"hip-report\">"))
        XCTAssertTrue(xml.contains("<md5-sum>abc123md5sum</md5-sum>"))
        XCTAssertTrue(xml.contains("<user-name>testalice</user-name>"))
        XCTAssertTrue(xml.contains("<domain>corp.example.com.internal</domain>"))
        XCTAssertTrue(xml.contains("<host-name>\(id.computerName)</host-name>"))
        XCTAssertTrue(xml.contains("<host-id>\(id.hostId)</host-id>"))
        XCTAssertTrue(xml.contains("<mac-address>\(id.macAddress)</mac-address>"))
        XCTAssertTrue(xml.contains("<ip-address>\n\t\t\t\t\t\t<entry name=\"\(id.ipv4Address)\"/>"))
        XCTAssertTrue(xml.contains("<client-version>6.2.4-49</client-version>"))
        XCTAssertTrue(xml.contains("<os-vendor>Apple</os-vendor>"))
        XCTAssertTrue(xml.contains("Xprotect"))
        XCTAssertTrue(xml.contains("Gatekeeper"))
        XCTAssertTrue(xml.contains("FileVault"))
        XCTAssertTrue(xml.contains("Mac OS X Builtin Firewall"))
        XCTAssertTrue(xml.contains("</hip-report>"))
    }

    func testGenerateScriptAndExecute() throws {
        let id = HIPSimulator.identity(for: 5)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hip-sim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("test-hip.sh")
        try HIPSimulator.writeScript(to: scriptURL, identity: id)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))

        // Execute script with sample OpenConnect arguments
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            "--cookie", "user=bob&domain=corp.net",
            "--md5", "test-token-md5",
            "--client-version", "6.2.4-50",
            "--client-os", "Mac",
            "--os-version", "Apple Mac OS X 14.5.0",
            "--host-id", "ignored-host-id"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)

        XCTAssertTrue(output.contains("<hip-report name=\"hip-report\">"))
        XCTAssertTrue(output.contains("<md5-sum>test-token-md5</md5-sum>"))
        XCTAssertTrue(output.contains("<user-name>bob</user-name>"))
        XCTAssertTrue(output.contains("<domain>corp.net.internal</domain>"))
        XCTAssertTrue(output.contains("<host-name>\(id.computerName)</host-name>"))
        XCTAssertTrue(output.contains("<host-id>\(id.hostId)</host-id>"))
        XCTAssertTrue(output.contains("<mac-address>\(id.macAddress)</mac-address>"))
        XCTAssertTrue(output.contains("<client-version>6.2.4-50</client-version>"))
        XCTAssertTrue(output.contains("</hip-report>"))
    }
}
