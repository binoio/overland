// OverlandHelper: root launchd daemon that runs gpclient for the Overland app.
//
// Registered with SMAppService from the app bundle
// (Contents/Library/LaunchDaemons/io.bino.overland.helper.plist), started on
// demand through its Mach service, and exits when idle. Only a copy of
// Overland signed with the same Team ID may talk to it, and it only runs the
// gpclient sealed in its own bundle — see HelperRequestValidator and
// CodeSignature.
import Foundation
import Darwin
import os
import OverlandCore
import OverlandHelperShared

/// Everything the daemon needs, resolved once; immutable so it can be shared
/// with XPC callbacks on any thread.
final class Daemon: @unchecked Sendable {
    static let appBundleID = "io.bino.overland"
    static let idleExitAfter: TimeInterval = 60

    struct BinaryIdentity: Equatable {
        let inode: UInt64
        let modifiedSeconds: Int
    }

    let logger = Logger(subsystem: "io.bino.overland", category: "helper")
    let bundleURL: URL
    let helperPath: String
    let startupIdentity: BinaryIdentity?
    let gpclientPath: String
    let vpncScriptPath: String
    let teamID: String
    let clientRequirement: SecRequirement
    let binaryRequirement: SecRequirement

    private static func binaryIdentity(at path: String) -> BinaryIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return BinaryIdentity(inode: st.st_ino, modifiedSeconds: st.st_mtimespec.tv_sec)
    }

    init() throws {
        // The helper lives at <App>.app/Contents/MacOS/OverlandHelper. launchd
        // passes a bundle-relative argv[0], so ask the runtime for the real
        // executable path; the validator canonicalizes when comparing.
        let helperURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: Swift.CommandLine.arguments[0])).standardizedFileURL
        let macOSDir = helperURL.deletingLastPathComponent()
        bundleURL = macOSDir.deletingLastPathComponent().deletingLastPathComponent()
        helperPath = helperURL.path
        startupIdentity = Self.binaryIdentity(at: helperPath)
        gpclientPath = macOSDir.appendingPathComponent("gpclient").path
        vpncScriptPath = bundleURL.appendingPathComponent("Contents/Resources/vpnc-script").path

        teamID = try CodeSignature.selfTeamIdentifier()
        clientRequirement = try CodeSignature.clientRequirement(teamID: teamID, bundleID: Self.appBundleID)
        binaryRequirement = try CodeSignature.teamRequirement(teamID: teamID)
    }

    private func binaryUpdatedOnDisk() -> Bool {
        guard let startupIdentity, let current = Self.binaryIdentity(at: helperPath) else {
            return false
        }
        return current != startupIdentity
    }

    func run() -> Never {
        logger.info("starting; team \(self.teamID, privacy: .public), bundle \(self.bundleURL.path, privacy: .public), gpclient \(self.gpclientPath, privacy: .public)")

        let validator = HelperRequestValidator(gpclientPath: gpclientPath, vpncScriptPath: vpncScriptPath)
        let manager = TunnelManager(validator: validator, runnerFactory: { [self] in
            // Verify the binaries every time, right before they run as root.
            VerifiedRunner(checks: {
                try CodeSignature.pathSatisfies(self.binaryRequirement, path: self.gpclientPath)
                try CodeSignature.pathSatisfies(self.binaryRequirement, path: self.bundleURL.path)
            })
        })

        let delegate = HelperListenerDelegate(
            manager: manager,
            accept: { [self] connection in CodeSignature.connectionSatisfies(self.clientRequirement, connection: connection) },
            log: { [logger] message in logger.info("\(message, privacy: .public)") }
        )

        let listener = NSXPCListener(machServiceName: overlandHelperMachServiceName)
        listener.delegate = delegate
        listener.resume()

        // Idle exit & self-update reload: if Sparkle replaced Overland.app on
        // disk while no tunnel is active, exit promptly so launchd spawns the
        // new helper binary without touching SMAppService approval.
        let timer = Timer(timeInterval: 2, repeats: true) { [self] _ in
            guard !manager.isRunning else { return }
            if self.binaryUpdatedOnDisk() {
                self.logger.info("helper binary updated on disk; exiting so launchd spawns the new version")
                exit(0)
            }
            if delegate.openConnections == 0, delegate.idleSeconds > Self.idleExitAfter {
                self.logger.info("idle; exiting")
                exit(0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
        exit(0)
    }
}

do {
    try Daemon().run()
} catch {
    Logger(subsystem: "io.bino.overland", category: "helper").error("refusing to start: \(error.localizedDescription, privacy: .public)")
    exit(1)
}
