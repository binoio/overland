import XCTest
import ServiceManagement
@testable import Overland

@MainActor
final class HelperManagerTests: XCTestCase {
    func testMissingFilesYieldsNotFound() {
        let status = HelperManager.resolveStatus(
            filesExist: false,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: true,
            serviceStatus: .enabled
        )
        XCTAssertEqual(status, .notFound)
    }

    func testUnsignedYieldsUnsignedBuildWhenFilesExist() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: nil,
            inApprovedLocation: true,
            serviceStatus: .notRegistered
        )
        XCTAssertEqual(status, .unsignedBuild)
    }

    func testEnabledStatusWhenRegistered() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: true,
            serviceStatus: .enabled
        )
        XCTAssertEqual(status, .enabled)
    }

    func testRequiresApprovalStatus() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: true,
            serviceStatus: .requiresApproval
        )
        XCTAssertEqual(status, .requiresApproval)
    }

    func testLaunchdNotFoundStatusMappedToNotRegisteredWhenInApprovedLocation() {
        // When launchd has never seen the daemon, SMAppService returns .notFound.
        // If the files are physically present on disk, this should be treated as .notRegistered
        // so the user gets an "Enable..." button rather than an error stating the helper is missing.
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: true,
            serviceStatus: .notFound
        )
        XCTAssertEqual(status, .notRegistered)
    }

    func testLaunchdNotFoundStatusMappedToRequiresMoveWhenOutsideApprovedLocation() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: false,
            serviceStatus: .notFound
        )
        XCTAssertEqual(status, .requiresMoveToApplications)
    }

    func testNotRegisteredStatusMappedToRequiresMoveWhenOutsideApprovedLocation() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: false,
            serviceStatus: .notRegistered
        )
        XCTAssertEqual(status, .requiresMoveToApplications)
    }

    func testNotRegisteredStatusInApprovedLocation() {
        let status = HelperManager.resolveStatus(
            filesExist: true,
            teamIdentifier: "ABCDE12345",
            inApprovedLocation: true,
            serviceStatus: .notRegistered
        )
        XCTAssertEqual(status, .notRegistered)
    }
}
