import XCTest
@testable import Overland

final class AppLocationCheckTests: XCTestCase {
    private let approved = AppLocationCheck.approvedInstallDirectories(realHome: "/Users/testuser")

    func testApprovedDirectoriesCoverSystemAndUserApplications() {
        XCTAssertEqual(approved.map(\.path), ["/Applications", "/Users/testuser/Applications"])
    }

    func testSystemApplicationsIsApproved() {
        let url = URL(fileURLWithPath: "/Applications/Overland.app")
        XCTAssertTrue(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testUserApplicationsIsApproved() {
        let url = URL(fileURLWithPath: "/Users/testuser/Applications/Overland.app")
        XCTAssertTrue(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testSubdirectoryOfApplicationsIsApproved() {
        let url = URL(fileURLWithPath: "/Applications/Utilities/Overland.app")
        XCTAssertTrue(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testDownloadsIsNotApproved() {
        let url = URL(fileURLWithPath: "/Users/testuser/Downloads/Overland.app")
        XCTAssertFalse(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testSimilarlyNamedDirectoryIsNotApproved() {
        let url = URL(fileURLWithPath: "/ApplicationsBackup/Overland.app")
        XCTAssertFalse(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testTranslocationStylePathIsNotApprovedWithoutResolution() {
        let url = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-5678/d/Overland.app")
        XCTAssertFalse(AppLocationCheck.isInApprovedLocation(bundleURL: url, approvedDirectories: approved))
    }

    func testDevelopmentBuildPathsAreApproved() {
        let buildUrl = URL(fileURLWithPath: "/Users/testuser/repo/.build/arm64-apple-macosx/release/Overland.app")
        let distUrl = URL(fileURLWithPath: "/Users/testuser/repo/dist/Overland.app")
        XCTAssertTrue(AppLocationCheck.isInApprovedLocation(bundleURL: buildUrl, approvedDirectories: approved))
        XCTAssertTrue(AppLocationCheck.isInApprovedLocation(bundleURL: distUrl, approvedDirectories: approved))
    }

    func testRealUserHomeIsNotTheSandboxContainer() {
        let home = AppLocationCheck.realUserHome()
        XCTAssertFalse(home.contains("/Library/Containers/"))
        XCTAssertTrue(home.hasPrefix("/"))
    }

    func testEffectiveBundleURLReturnsInputWhenNotTranslocated() {
        let url = URL(fileURLWithPath: "/Applications/Overland.app")
        XCTAssertEqual(AppLocationCheck.effectiveBundleURL(for: url), url)
    }

    func testUntranslocatedBundleURLIsNilForOrdinaryPath() {
        XCTAssertNil(AppLocationCheck.untranslocatedBundleURL(for: URL(fileURLWithPath: "/Applications/Overland.app")))
    }

    func testStripQuarantineOnTemporaryFile() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempFile = tempDir.appendingPathComponent("test.txt")
        try? "test".data(using: .utf8)?.write(to: tempFile)

        // Calling stripQuarantine should succeed cleanly without crashing
        AppLocationCheck.stripQuarantine(from: tempFile)
    }
}
