import OverlandCore
import SwiftUI
import AppKit

@main
struct OverlandApp: App {
    @NSApplicationDelegateAdaptor(SparkleAppDelegate.self) private var appDelegate
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
        // A single window: WindowGroup would open another one every time the
        // browser hands the globalprotectcallback: URL back to the app.
        Window("Overland", id: "main") {
            ContentView(viewModel: viewModel)
                .onOpenURL { appDelegate.handleURL($0) }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 820, height: 560)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Overland") { openWindow(id: "about") }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(viewModel: appDelegate.updaterViewModel)
            }

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

            CommandGroup(before: .windowList) {
                Button("Gateways") { openWindow(id: "gateways") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Activity Logs") { openWindow(id: "logs") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
            }

            CommandGroup(replacing: .help) {
                Button("Overland Help") {
                    if let url = URL(string: "https://github.com/yuezk/GlobalProtect-openconnect") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel, updatesSection: AnyView(UpdatesSectionView(viewModel: appDelegate.updaterViewModel)))
        }

        Window("About Overland", id: "about") {
            AboutView(viewModel: viewModel)
                .frame(width: 440, height: 400)
        }
        .windowResizability(.contentSize)

        Window("Gateways", id: "gateways") {
            GatewayListView(viewModel: viewModel)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 600, height: 420)

        Window("Activity Logs", id: "logs") {
            LogsView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 820, height: 480)

        MenuBarExtra {
            MenuBarExtraView(
                viewModel: viewModel,
                onOpenMainWindow: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                },
                onOpenWindow: { id in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: id)
                }
            )
            .onOpenURL { appDelegate.handleURL($0) }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let symbol = MenuBarIcon.symbol(for: viewModel.state)
        if viewModel.state.isConnecting {
            Image(systemName: symbol)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
        } else {
            Image(systemName: symbol)
        }
    }
}
