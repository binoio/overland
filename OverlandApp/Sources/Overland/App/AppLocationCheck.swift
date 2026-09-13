import OverlandCore
import Foundation
import AppKit
import Darwin

public enum AppLocationCheck {
    public static func approvedInstallDirectories(realHome: String = realUserHome()) -> [URL] {
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        return [systemApplications, userApplications]
    }

    /// Under App Sandbox or varying runtime contexts, homeDirectoryForCurrentUser
    /// may resolve to a container home (~/Library/Containers/…). Resolve the real
    /// home via the passwd database instead.
    public static func realUserHome() -> String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    public static func isInApprovedLocation(bundleURL: URL, approvedDirectories: [URL]) -> Bool {
        let parentPath = bundleURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .standardizedFileURL.path
        // Development builds (swift run, Scripts/bundle.sh output) never nag.
        let fullPath = bundleURL.standardizedFileURL.path
        if fullPath.contains("/.build/") || fullPath.contains("/build/") || fullPath.contains("/dist/") {
            return true
        }
        return approvedDirectories.contains { allowed in
            let allowedPath = allowed.standardizedFileURL.path
            return parentPath == allowedPath || parentPath.hasPrefix(allowedPath + "/")
        }
    }

    /// Gatekeeper app translocation runs a quarantined app from a randomized
    /// read-only mount (/private/var/…/AppTranslocation/…), so the bundle URL
    /// no longer reflects where the user actually put the app. Map the running
    /// URL back to the on-disk original when translocated.
    public static func untranslocatedBundleURL(for bundleURL: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(security) }

        typealias IsTranslocatedFn = @convention(c) (
            CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Bool
        typealias OriginalPathFn = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?

        guard let isTranslocatedSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPathSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }

        let isTranslocated = unsafeBitCast(isTranslocatedSym, to: IsTranslocatedFn.self)
        let originalPath = unsafeBitCast(originalPathSym, to: OriginalPathFn.self)

        var translocated = false
        guard isTranslocated(bundleURL as CFURL, &translocated, nil), translocated else {
            return nil
        }
        return originalPath(bundleURL as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// The URL to judge the install location by: the translocation original
    /// when running translocated, otherwise the bundle URL itself.
    public static func effectiveBundleURL(for bundleURL: URL = Bundle.main.bundleURL) -> URL {
        untranslocatedBundleURL(for: bundleURL) ?? bundleURL.resolvingSymlinksInPath()
    }

    public static func stripQuarantine(from url: URL) {
        let quarantineProc = Process()
        quarantineProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        quarantineProc.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? quarantineProc.run()
        quarantineProc.waitUntilExit()
    }

    public static func relaunch(at url: URL) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if error == nil {
                DispatchQueue.main.async {
                    exit(0)
                }
            }
        }
        return false
    }

    @MainActor
    @discardableResult
    public static func promptToMoveOutOfDownloadsIfNeeded() -> Bool {
        promptToMoveToApplicationsIfNeeded()
    }

    @MainActor
    @discardableResult
    public static func promptToMoveToApplicationsIfNeeded() -> Bool {
        let bundleURL = effectiveBundleURL()
        let approved = approvedInstallDirectories()

        // If running translocated from an approved location, strip quarantine and relaunch directly.
        let isTranslocated = untranslocatedBundleURL(for: Bundle.main.bundleURL) != nil
        if isInApprovedLocation(bundleURL: bundleURL, approvedDirectories: approved) {
            if isTranslocated {
                stripQuarantine(from: bundleURL)
                return relaunch(at: bundleURL)
            }
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Overland to Applications?"
        alert.informativeText = "Running Overland from Applications ensures reliable background privileged helper integration and permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Continue Running Here")

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return moveToApplications(sourceURL: bundleURL)
        }
        return true
    }

    @MainActor
    @discardableResult
    public static func moveToApplications(sourceURL: URL = effectiveBundleURL()) -> Bool {
        let fm = FileManager.default
        let systemDest = URL(fileURLWithPath: "/Applications/Overland.app")
        let userDest = URL(fileURLWithPath: realUserHome(), isDirectory: true)
            .appendingPathComponent("Applications/Overland.app")

        // If source is already at destination, strip quarantine and ensure de-translocation
        if sourceURL.standardizedFileURL.path == systemDest.standardizedFileURL.path ||
           sourceURL.standardizedFileURL.path == userDest.standardizedFileURL.path {
            stripQuarantine(from: sourceURL)
            if untranslocatedBundleURL(for: Bundle.main.bundleURL) != nil {
                return relaunch(at: sourceURL)
            }
            return true
        }

        // Prefer /Applications if writable, otherwise ~/Applications
        var target = systemDest
        if !fm.isWritableFile(atPath: "/Applications") {
            target = userDest
            try? fm.createDirectory(at: userDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        do {
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: sourceURL, to: target)
            stripQuarantine(from: target)

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: target, configuration: config) { _, error in
                if error == nil {
                    try? fm.removeItem(at: sourceURL)
                    DispatchQueue.main.async {
                        exit(0)
                    }
                }
            }
            return false
        } catch {
            if target != userDest {
                do {
                    try? fm.createDirectory(at: userDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: userDest.path) {
                        try fm.removeItem(at: userDest)
                    }
                    try fm.copyItem(at: sourceURL, to: userDest)
                    stripQuarantine(from: userDest)

                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: userDest, configuration: config) { _, error in
                        if error == nil {
                            try? fm.removeItem(at: sourceURL)
                            DispatchQueue.main.async { exit(0) }
                        }
                    }
                    return false
                } catch {}
            }
            NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            return true
        }
    }
}
