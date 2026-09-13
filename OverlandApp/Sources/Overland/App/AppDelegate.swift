import OverlandCore
import Foundation
import AppKit

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastHandledURL: (url: URL, timestamp: Date)?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Register running bundle with LaunchServices for the globalprotectcallback scheme
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if let bundleId = Bundle.main.bundleIdentifier {
            LSSetDefaultHandlerForURLScheme("globalprotectcallback" as CFString, bundleId as CFString)
        }

        // Install system AppleEvent handler to directly capture kAEGetURL events.
        // SwiftUI apps often do not forward custom URL schemes through application(_:open:),
        // delivering an empty array instead. NSAppleEventManager intercepts the event reliably.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Menu-bar-only mode: no Dock icon, and the window stays closed until
        // it is asked for from the menu bar.
        if VpnViewModel.shared.menuBarOnly, !VpnViewModel.shared.needsSetup {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows where window.canBecomeMain {
                window.orderOut(nil)
            }
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        handleURL(url)
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

    public func handleURL(_ url: URL) {
        if let last = lastHandledURL, last.url == url, Date().timeIntervalSince(last.timestamp) < 2.0 {
            return
        }
        lastHandledURL = (url, Date())

        // Handle globalprotectcallback:<data>
        if url.scheme == "globalprotectcallback" {
            NSLog("[Overland] Handling auth callback URL: %@", url.absoluteString)
            let data = url.absoluteString
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
