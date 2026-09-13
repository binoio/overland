import GlobalProtectCore
import SwiftUI

public struct MenuBarExtraView: View {
    @ObservedObject var viewModel: VpnViewModel
    public let onOpenMainWindow: () -> Void

    public init(viewModel: VpnViewModel, onOpenMainWindow: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onOpenMainWindow = onOpenMainWindow
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .font(.system(size: 14))

                    Text("GlobalProtect")
                        .font(.system(size: 13, weight: .bold))
                }

                Spacer()

                StatusBadgeView(state: viewModel.state)
            }

            Divider()

            // Active Connection / Portal info
            if case .connected(let details) = viewModel.state {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Gateway:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(details.gatewayName)
                            .font(.caption.weight(.medium))
                    }

                    HStack {
                        Text("IP:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(details.assignedIP ?? "detecting…")
                            .font(.caption.weight(.medium))
                    }

                    SessionTimerView(expiresAt: details.sessionExpiresAt)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(NSColor.quaternaryLabelColor).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Portal: \(viewModel.profile.portal.isEmpty ? "None configured" : viewModel.profile.portal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let selectedGw = viewModel.profile.selectedGatewayServer {
                        Text("Gateway: \(selectedGw)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Quick Connect / Disconnect Action Button
            Button(action: {
                viewModel.toggleConnection()
            }) {
                HStack {
                    if viewModel.state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .disabled(viewModel.state == .disconnecting)

            Divider()

            // Navigation Actions
            VStack(spacing: 4) {
                Button(action: {
                    onOpenMainWindow()
                }) {
                    HStack {
                        Image(systemName: "macwindow")
                        Text("Open GlobalProtect Window")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)

                Button(action: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings…")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)

                Divider()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit GlobalProtect")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 290)
    }

    private var iconName: String {
        switch viewModel.state {
        case .connected: return "checkmark.shield.fill"
        case .connecting: return "shield.lefthalf.filled"
        case .disconnecting: return "shield"
        case .disconnected: return "shield"
        case .failed: return "exclamationmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch viewModel.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var buttonTitle: String {
        switch viewModel.state {
        case .connected: return "Disconnect"
        case .connecting: return "Cancel"
        case .disconnecting: return "Disconnecting…"
        case .disconnected, .failed: return "Connect"
        }
    }

    private var buttonTint: Color {
        switch viewModel.state {
        case .connected, .connecting: return .red
        default: return .accentColor
        }
    }
}
