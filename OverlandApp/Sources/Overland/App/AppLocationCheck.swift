import OverlandCore
import Foundation
import AppKit

public enum AppLocationCheck {
    public static func effectiveBundleURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        // Resolve symlinks and path
        return bundleURL.resolvingSymlinksInPath()
    }

    public static func approvedInstallDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
        if let userApps = try? FileManager.default.url(
            for: .applicationDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            directories.append(userApps)
        }
        return directories
    }

    public static func isInApprovedLocation(bundleURL: URL, approvedDirectories: [URL]) -> Bool {
        let path = bundleURL.path
        // Development builds (swift run, Scripts/bundle.sh output) never nag.
        if path.contains("/.build/") || path.contains("/build/") || path.contains("/dist/") {
            return true
        }
        for dir in approvedDirectories {
            if path.hasPrefix(dir.path) {
                return true
            }
        }
        return false
    }

    @MainActor
    public static func promptToMoveOutOfDownloadsIfNeeded() -> Bool {
        let bundleURL = effectiveBundleURL()
        let approved = approvedInstallDirectories()

        guard !isInApprovedLocation(bundleURL: bundleURL, approvedDirectories: approved) else {
            return true
        }

        // Only prompt if running from Downloads
        if !bundleURL.path.contains("/Downloads") {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Overland to Applications?"
        alert.informativeText = "Running Overland from /Applications ensures reliable background helper integration and system permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Continue Running Here")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let dest = URL(fileURLWithPath: "/Applications/Overland.app")
            try? FileManager.default.moveItem(at: bundleURL, to: dest)
            NSWorkspace.shared.open(dest)
            return false
        }
        return true
    }
}
