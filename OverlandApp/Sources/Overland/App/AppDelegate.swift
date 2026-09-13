import OverlandCore
import Foundation
import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
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
