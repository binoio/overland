import OverlandCore
import SwiftUI
import AppKit

@main
struct OverlandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = VpnViewModel.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // `Overland --helper-status`: print the privileged helper's registration
        // state and exit. Handy when System Settings and the app disagree.
        if ProcessInfo.processInfo.arguments.contains("--helper-status") {
            HelperManager.printDiagnostics()
            exit(0)
        }
        _ = AppLocationCheck.promptToMoveOutOfDownloadsIfNeeded()
    }

    var body: some Scene {
        // Main Application Window
        // A single window: WindowGroup would open another one every time the
        // browser hands the globalprotectcallback: URL back to the app.
        Window("Overland", id: "main") {
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 800, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(viewModel.state.isConnected || viewModel.state.isConnecting ? "Disconnect VPN" : "Connect VPN") {
                    viewModel.toggleConnection()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(viewModel.state == .disconnecting)

                Button("Discover Gateways") {
                    viewModel.refreshGateways()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.isDiscoveringGateways || viewModel.state.isBusy)
            }

            CommandGroup(replacing: .help) {
                Button("Overland Help") {
                    if let url = URL(string: "https://github.com/yuezk/GlobalProtect-openconnect") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Native Menu Bar Extra Tray Icon
        MenuBarExtra {
            MenuBarExtraView(viewModel: viewModel) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: menuBarIconName)
                if viewModel.state.isConnecting {
                    Text("…")
                }
            }
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsView(viewModel: viewModel)
        }
    }

    private var menuBarIconName: String {
        switch viewModel.state {
        case .connected:
            return "checkmark.shield.fill"
        case .connecting:
            return "shield.lefthalf.filled"
        case .disconnecting:
            return "shield"
        case .disconnected:
            return "shield"
        case .failed:
            return "exclamationmark.shield.fill"
        }
    }
}
