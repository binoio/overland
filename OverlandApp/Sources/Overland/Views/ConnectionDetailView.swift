import OverlandCore
import SwiftUI

public struct ConnectionDetailView: View {
    @ObservedObject var viewModel: VpnViewModel
    @State private var editing = false

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch viewModel.state {
                case .connected(let details):
                    connectedHeader(details)
                    throughputSection
                    detailsSection(details)
                case .connecting(let status):
                    connectingCard(status: status)
                case .disconnecting:
                    busyCard(title: "Disconnecting…")
                case .disconnected, .failed:
                    if let failure = viewModel.failure {
                        FailureCard(
                            failure: failure,
                            onRetry: { viewModel.connect() },
                            onShowLogs: { viewModel.selectedTab = .logs },
                            onDismiss: { viewModel.dismissFailure() }
                        )
                    }
                    idleCard
                }

                if let url = viewModel.manualAuthURL {
                    manualAuthBanner(url: url)
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
        }
        .sheet(isPresented: $editing) {
            editorSheet
        }
    }

    // MARK: Idle (same structure as Connected, unpopulated)

    private var idleCard: some View {
        VStack(spacing: 20) {
            idleHeader
            HStack(spacing: 12) {
                placeholderTile(title: "Received", icon: "arrow.down", color: .green)
                placeholderTile(title: "Sent", icon: "arrow.up", color: .teal)
            }
            idleDetails
        }
    }

    private var idleHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.10)).frame(width: 64, height: 64)
                Image(systemName: "shield")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Not connected")
                    .font(.title2.weight(.bold))
                Text(viewModel.profile.portal.isEmpty ? "No portal configured" : viewModel.profile.portal)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Change portal or sign-in…") { editing = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 2)
            }
            Spacer()
            Button {
                viewModel.connect()
            } label: {
                Text("Connect")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 120, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.profile.portal.isEmpty)
        }
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func placeholderTile(title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color.opacity(0.5))
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("—")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var gatewayLabel: String {
        viewModel.gateways.first { $0.server == viewModel.profile.selectedGatewayServer }?.name
            ?? viewModel.profile.selectedGatewayServer ?? "Automatic"
    }

    private var signInLabel: String {
        switch viewModel.profile.authMethod {
        case .browserSSO: return "Single Sign-On"
        case .credentials: return viewModel.profile.username.isEmpty ? "Username & password" : viewModel.profile.username
        case .clientCertificate: return "Client certificate"
        }
    }

    private var idleDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("Duration", "—")
            Divider()
            detailRow("Tunnel address", "—")
            Divider()
            detailRow("Gateway", gatewayLabel)
            Divider()
            detailRow("Portal", viewModel.profile.portal.isEmpty ? "—" : viewModel.profile.portal)
            Divider()
            detailRow("Sign in", signInLabel)
        }
        .padding(.horizontal, 16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection")
                .font(.title2.weight(.bold))
            ConnectionEditorView(viewModel: viewModel)
            HStack {
                Spacer()
                Button("Done") {
                    viewModel.saveProfile()
                    editing = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: Connecting

    private func connectingCard(status: String) -> some View {
        VStack(spacing: 8) {
            Text("Connecting to \(viewModel.profile.portal)")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 8)
            ConnectProgressView(
                phase: viewModel.connectPhase ?? .signIn,
                status: status,
                usesHelper: viewModel.profile.privilegeMode == .helper && viewModel.helperManager.isUsable,
                signInURL: viewModel.signInURL,
                onReopenSignIn: { viewModel.reopenSignInPage() },
                onCancel: { viewModel.disconnect() },
                onDeliverCallback: { viewModel.deliverAuthCallback($0) }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func busyCard(title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Connected

    private func connectedHeader(_ details: ConnectedDetails) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected")
                    .font(.title2.weight(.bold))
                Text(details.gatewayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SessionTimerView(expiresAt: details.sessionExpiresAt)
                    .padding(.top, 2)
            }
            Spacer()
            Button {
                viewModel.disconnect()
            } label: {
                Text("Disconnect")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 120, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var throughputSection: some View {
        HStack(spacing: 12) {
            throughputTile(title: "Received", total: viewModel.metrics.formattedBytesReceived,
                           rate: viewModel.throughputHistory.last?.bytesInPerSecond ?? 0,
                           keyPath: \.bytesInPerSecond, color: .green, icon: "arrow.down")
            throughputTile(title: "Sent", total: viewModel.metrics.formattedBytesSent,
                           rate: viewModel.throughputHistory.last?.bytesOutPerSecond ?? 0,
                           keyPath: \.bytesOutPerSecond, color: .teal, icon: "arrow.up")
        }
    }

    private func throughputTile(title: String, total: String, rate: Double, keyPath: KeyPath<ThroughputSample, Double>, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Self.rateText(rate))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(total)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            ThroughputSparkline(samples: viewModel.throughputHistory, keyPath: keyPath, color: color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func rateText(_ bytesPerSecond: Double) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    private func detailsSection(_ details: ConnectedDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailRow("Duration", viewModel.metrics.formattedDuration)
            Divider()
            detailRow("Tunnel address", details.assignedIP ?? "Detecting…")
            Divider()
            detailRow("Gateway", details.gatewayServer)
            Divider()
            detailRow("Portal", details.portal)
            if let iface = details.interfaceName {
                Divider()
                detailRow("Interface", iface)
            }
            if let cipher = details.cipher {
                Divider()
                detailRow("Transport", cipher)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 8)
    }

    // MARK: Manual auth (remote browser mode)

    private func manualAuthBanner(url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Manual sign-in required", systemImage: "link")
                .font(.headline)
            Text("Open this URL in a browser, then paste the resulting globalprotectcallback: data into the Activity Logs prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button("Open") {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
