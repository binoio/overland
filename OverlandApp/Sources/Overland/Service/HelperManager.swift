import Foundation
import ServiceManagement
import Security
import OverlandCore
import OverlandHelperShared

/// Registration and availability of the privileged helper daemon.
///
/// Registration goes through `SMAppService.daemon`, which needs the app and
/// helper signed with the same Developer ID: an unsigned (ad-hoc) build reports
/// `.unsignedBuild` and the app uses the administrator dialog instead. After
/// `register()` macOS asks the user to allow the item once in System Settings ›
/// Login Items & Extensions; from then on connecting never prompts.
@MainActor
public final class HelperManager: ObservableObject {
    public enum Status: Equatable, Sendable {
        case unsignedBuild
        case notRegistered
        case requiresApproval
        case enabled
        case requiresMoveToApplications
        case notFound

        public var title: String {
            switch self {
            case .unsignedBuild: return "Unavailable in this build (not signed with a Developer ID)"
            case .notRegistered: return "Not enabled"
            case .requiresApproval: return "Waiting for approval in System Settings › Login Items & Extensions"
            case .enabled: return "Enabled"
            case .requiresMoveToApplications: return "Move Overland to Applications to enable the helper"
            case .notFound: return "Helper missing from the app bundle"
            }
        }
    }

    @Published public private(set) var status: Status = .notRegistered
    @Published public private(set) var lastError: String?

    /// Thread-safe mirror of `status == .enabled` for the bridge's factories.
    public let availability = HelperAvailability()

    private let service: SMAppService
    private let bundleURL: URL

    public init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
        self.service = SMAppService.daemon(plistName: overlandHelperPlistName)
        refresh()
    }

    /// The Team ID the running app is signed with, if any.
    public static func bundleTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return nil
        }
        return team
    }

    public var isUsable: Bool { status == .enabled }

    /// Diagnostics for `Overland --helper-status`.
    public static func printDiagnostics() {
        let bundle = Bundle.main.bundleURL
        let service = SMAppService.daemon(plistName: overlandHelperPlistName)
        let raw: String
        switch service.status {
        case .enabled: raw = "enabled"
        case .requiresApproval: raw = "requiresApproval"
        case .notRegistered: raw = "notRegistered"
        case .notFound: raw = "notFound"
        @unknown default: raw = "unknown(\(service.status.rawValue))"
        }
        let plist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(overlandHelperPlistName)").path
        let helper = bundle.appendingPathComponent("Contents/MacOS/OverlandHelper").path
        print("bundle:        \(bundle.path)")
        print("bundle id:     \(Bundle.main.bundleIdentifier ?? "nil")")
        print("team id:       \(bundleTeamIdentifier() ?? "none (unsigned)")")
        print("plist present: \(FileManager.default.fileExists(atPath: plist))")
        print("helper exec:   \(FileManager.default.isExecutableFile(atPath: helper))")
        print("SMAppService:  \(raw)")
        print("service:       \(service)")
        if ProcessInfo.processInfo.arguments.contains("--helper-register") {
            do {
                try service.register()
                print("register():    ok (status now \(service.status.rawValue))")
            } catch {
                print("register():    \(error)")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--helper-unregister") {
            do {
                try service.unregister()
                print("unregister():  ok")
            } catch {
                print("unregister():  \(error)")
            }
        }
    }

    nonisolated public static func resolveStatus(
        filesExist: Bool,
        teamIdentifier: String?,
        inApprovedLocation: Bool,
        serviceStatus: SMAppService.Status
    ) -> Status {
        if !filesExist {
            return .notFound
        } else if teamIdentifier == nil {
            return .unsignedBuild
        } else {
            switch serviceStatus {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered, .notFound:
                return inApprovedLocation ? .notRegistered : .requiresMoveToApplications
            @unknown default: return .notRegistered
            }
        }
    }

    public func refresh() {
        let effectiveURL = AppLocationCheck.effectiveBundleURL(for: bundleURL)
        let plist = effectiveURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(overlandHelperPlistName)")
        let helper = effectiveURL.appendingPathComponent("Contents/MacOS/OverlandHelper")
        let fm = FileManager.default
        let filesExist = fm.fileExists(atPath: plist.path) && fm.isExecutableFile(atPath: helper.path)
        let approved = AppLocationCheck.approvedInstallDirectories()
        let inApprovedLocation = AppLocationCheck.isInApprovedLocation(bundleURL: effectiveURL, approvedDirectories: approved)

        status = Self.resolveStatus(
            filesExist: filesExist,
            teamIdentifier: Self.bundleTeamIdentifier(),
            inApprovedLocation: inApprovedLocation,
            serviceStatus: service.status
        )
        availability.enabled = status == .enabled
    }

    /// Register the daemon; opens System Settings when approval is needed.
    public func enable() {
        lastError = nil
        if status == .requiresMoveToApplications {
            _ = AppLocationCheck.promptToMoveToApplicationsIfNeeded()
            refresh()
            return
        }
        do {
            try service.register()
        } catch {
            // Until the user allows the item, register() reports "Operation
            // not permitted" even though the item is now listed in System
            // Settings; only a real failure (still not registered) is shown.
            refresh()
            if status == .notRegistered || status == .notFound || status == .requiresMoveToApplications {
                lastError = error.localizedDescription
            }
        }
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    public func disable() async {
        lastError = nil
        do {
            try await service.unregister()
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Bridge hooks

    /// `PrivilegedRunnerFactory` for the bridge.
    public nonisolated func privilegedRunnerFactory() -> GpclientBridgeService.PrivilegedRunnerFactory {
        let availability = self.availability
        return { mode in
            switch mode {
            case .helper:
                return availability.enabled ? HelperProcessRunner(mode: .start) : nil
            case .adminPrompt:
                return PrivilegedProcessRunner()
            }
        }
    }

    /// `HelperAttach` for the bridge: the tunnel the daemon is running, if any.
    public nonisolated func helperAttach() -> GpclientBridgeService.HelperAttach {
        let availability = self.availability
        return {
            guard availability.enabled else { return nil }
            let runner = HelperProcessRunner(mode: .attach)
            guard let st = try? await runner.status(), st.running else {
                await runner.close()
                return nil
            }
            return GpclientBridgeService.AttachedTunnel(runner: runner, arguments: st.arguments)
        }
    }
}

public final class HelperAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = false
    public var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }
    public init() {}
}
