import OverlandCore
import Foundation
import AppKit

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Menu-bar-only mode: no Dock icon, and the window stays closed until
        // it is asked for from the menu bar.
        if VpnViewModel.shared.menuBarOnly, !VpnViewModel.shared.needsSetup {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows where window.canBecomeMain {
                window.orderOut(nil)
            }
        }
    }

    /// A connected tunnel is torn down before quitting. The reply is deferred
    /// so gpclient gets a chance to restore routes and DNS; a crash or force
    /// quit is covered by `adoptOrphanedSession` on the next launch.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let viewModel = VpnViewModel.shared
        guard viewModel.hasActiveSession else { return .terminateNow }
        Task { @MainActor in
            await viewModel.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        // Handle globalprotectcallback:<data>
        if url.scheme == "globalprotectcallback" {
            let data = (url as NSURL).resourceSpecifier ?? url.absoluteString
            NotificationCenter.default.post(
                name: .overlandAuthCallbackReceived,
                object: nil,
                userInfo: ["authData": data]
            )
        }
    }
}

extension Notification.Name {
    public static let overlandAuthCallbackReceived = Notification.Name("OverlandAuthCallbackReceived")
}
