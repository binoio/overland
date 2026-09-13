import OverlandCore
import SwiftUI

/// Content of the menu bar item, rendered as a standard macOS menu: status
/// lines are disabled items, actions are real menu items with shortcuts.
public struct MenuBarExtraView: View {
    @ObservedObject var viewModel: VpnViewModel
    public let onOpenMainWindow: () -> Void
    public let onOpenWindow: (String) -> Void

    public init(viewModel: VpnViewModel, onOpenMainWindow: @escaping () -> Void = {}, onOpenWindow: @escaping (String) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenWindow = onOpenWindow
    }

    public var body: some View {
        // Status (non-interactive)
        Text(headline)
        if let sub = subheadline {
            Text(sub)
        }
        if case .connected(let details) = viewModel.state {
            Text("Address: \(details.assignedIP ?? "detecting…")")
            Text("Duration: \(viewModel.metrics.formattedDuration)")
            Text("↓ \(viewModel.metrics.formattedBytesReceived)   ↑ \(viewModel.metrics.formattedBytesSent)")
            if let expires = details.sessionExpiresAt {
                Text("Expires: \(expires.formatted(date: .omitted, time: .shortened))")
            }
        }

        Divider()

        Button(primaryTitle) { viewModel.toggleConnection() }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(viewModel.state == .disconnecting || (viewModel.state.isDisconnected && viewModel.profile.portal.isEmpty))

        if viewModel.state.isConnecting, viewModel.connectPhase == .signIn, viewModel.signInURL != nil {
            Button("Reopen Sign-in Page") { viewModel.reopenSignInPage() }
        }

        Divider()

        Button("Open Overland") { onOpenMainWindow() }
            .keyboardShortcut("o", modifiers: [.command])
        Button("Activity Logs") { onOpenWindow("logs") }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit Overland") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }

    private var headline: String {
        switch viewModel.state {
        case .connected(let d): return "Connected · \(d.gatewayName)"
        case .connecting(let status): return "Connecting… \(status)"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Not connected"
        case .failed: return viewModel.failure?.title ?? "Connection failed"
        }
    }

    private var subheadline: String? {
        switch viewModel.state {
        case .connected(let d): return d.portal
        case .connecting: return viewModel.connectPhase.map { "Step \($0.rawValue + 1): \($0.title)" }
        case .disconnecting: return nil
        case .disconnected: return viewModel.profile.portal.isEmpty ? "No portal configured" : viewModel.profile.portal
        case .failed: return viewModel.failure?.advice
        }
    }

    private var primaryTitle: String {
        switch viewModel.state {
        case .connected: return "Disconnect"
        case .connecting: return "Cancel Connection"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Connect"
        case .failed: return "Try Again"
        }
    }
}

/// Menu bar status icon per state.
enum MenuBarIcon {
    static func symbol(for state: VpnState) -> String {
        switch state {
        case .connected: return "checkmark.shield.fill"
        case .connecting: return "shield.lefthalf.filled"
        case .disconnecting: return "shield"
        case .disconnected: return "shield"
        case .failed: return "exclamationmark.shield.fill"
        }
    }

    static func color(for state: VpnState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
