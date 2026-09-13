// OverlandHelper: root launchd daemon that runs gpclient for the Overland app.
//
// Registered with SMAppService from the app bundle
// (Contents/Library/LaunchDaemons/io.bino.overland.helper.plist), started on
// demand through its Mach service, and exits when idle. Only a copy of
// Overland signed with the same Team ID may talk to it, and it only runs the
// gpclient sealed in its own bundle — see HelperRequestValidator and
// CodeSignature.
import Foundation
import os
import OverlandCore
import OverlandHelperShared

/// Everything the daemon needs, resolved once; immutable so it can be shared
/// with XPC callbacks on any thread.
final class Daemon: @unchecked Sendable {
    static let appBundleID = "io.bino.overland"
    static let idleExitAfter: TimeInterval = 60

    let logger = Logger(subsystem: "io.bino.overland", category: "helper")
    let bundleURL: URL
    let gpclientPath: String
    let vpncScriptPath: String
    let teamID: String
    let clientRequirement: SecRequirement
    let binaryRequirement: SecRequirement

    init() throws {
        // The helper lives at <App>.app/Contents/MacOS/OverlandHelper.
        let helperURL = URL(fileURLWithPath: Swift.CommandLine.arguments[0]).resolvingSymlinksInPath()
        let macOSDir = helperURL.deletingLastPathComponent()
        bundleURL = macOSDir.deletingLastPathComponent().deletingLastPathComponent()
        gpclientPath = macOSDir.appendingPathComponent("gpclient").path
        vpncScriptPath = bundleURL.appendingPathComponent("Contents/Resources/vpnc-script").path

        teamID = try CodeSignature.selfTeamIdentifier()
        clientRequirement = try CodeSignature.clientRequirement(teamID: teamID, bundleID: Self.appBundleID)
        binaryRequirement = try CodeSignature.teamRequirement(teamID: teamID)
    }

    func run() -> Never {
        logger.info("starting; team \(self.teamID, privacy: .public), bundle \(self.bundleURL.path, privacy: .public)")

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

        // Idle exit: launchd relaunches us on the next connection.
        let timer = Timer(timeInterval: 15, repeats: true) { [logger] _ in
            if !manager.isRunning, delegate.openConnections == 0, delegate.idleSeconds > Self.idleExitAfter {
                logger.info("idle; exiting")
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
