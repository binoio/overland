import OverlandCore
import SwiftUI

/// The menu bar popover: status, one-click connect/disconnect, essentials.
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
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            body(for: viewModel.state)

            primaryButton

            Divider()

            VStack(spacing: 2) {
                menuRow("Open Overland", systemImage: "macwindow") { onOpenMainWindow() }
                menuRow("Activity Logs", systemImage: "list.bullet.rectangle") { onOpenWindow("logs") }
                SettingsLink {
                    HStack {
                        Image(systemName: "gearshape").frame(width: 16)
                        Text("Settings…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.vertical, 3)
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Divider().padding(.vertical, 2)
                menuRow("Quit Overland", systemImage: "power") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: MenuBarIcon.symbol(for: viewModel.state))
                .foregroundStyle(MenuBarIcon.color(for: viewModel.state))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var headline: String {
        switch viewModel.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Not connected"
        case .failed: return viewModel.failure?.title ?? "Connection failed"
        }
    }

    private var subheadline: String {
        switch viewModel.state {
        case .connected(let d): return d.gatewayName
        case .connecting(let status): return status
        case .disconnecting: return viewModel.profile.portal
        case .disconnected: return viewModel.profile.portal.isEmpty ? "No portal configured" : viewModel.profile.portal
        case .failed: return viewModel.profile.portal
        }
    }

    @ViewBuilder
    private func body(for state: VpnState) -> some View {
        switch state {
        case .connected(let details):
            VStack(alignment: .leading, spacing: 6) {
                infoRow("Address", details.assignedIP ?? "detecting…")
                infoRow("Duration", viewModel.metrics.formattedDuration)
                infoRow("Traffic", "↓ \(viewModel.metrics.formattedBytesReceived)  ↑ \(viewModel.metrics.formattedBytesSent)")
                SessionTimerView(expiresAt: details.sessionExpiresAt)
                    .padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.quaternaryLabelColor).opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .connecting:
            if let phase = viewModel.connectPhase {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Step \(phase.rawValue + 1): \(phase.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if phase == .signIn, viewModel.signInURL != nil {
                        Spacer()
                        Button("Reopen sign-in") { viewModel.reopenSignInPage() }
                            .controlSize(.mini)
                    }
                }
            }
        case .failed:
            if let failure = viewModel.failure {
                Text(failure.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            EmptyView()
        }
    }

    private var primaryButton: some View {
        Button {
            viewModel.toggleConnection()
        } label: {
            HStack {
                if viewModel.state.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(buttonTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.state.isConnected || viewModel.state.isConnecting ? .red : .accentColor)
        .disabled(viewModel.state == .disconnecting || (viewModel.state.isDisconnected && viewModel.profile.portal.isEmpty))
    }

    private var buttonTitle: String {
        switch viewModel.state {
        case .connected: return "Disconnect"
        case .connecting: return "Cancel"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Connect"
        case .failed: return "Try again"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.medium)).font(.system(.caption, design: .monospaced))
        }
    }

    private func menuRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.vertical, 3)
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
