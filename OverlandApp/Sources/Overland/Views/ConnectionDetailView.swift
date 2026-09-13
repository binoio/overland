import OverlandCore
import SwiftUI

public struct ConnectionDetailView: View {
    @ObservedObject var viewModel: VpnViewModel

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroConnectionCard

                if let url = viewModel.manualAuthURL {
                    manualAuthBanner(url: url)
                }

                if case .connected(let details) = viewModel.state {
                    connectedMetricsSection(details: details)
                }

                if !viewModel.state.isConnected {
                    configurationSection
                }
            }
            .padding(24)
            .frame(maxWidth: 800)
        }
    }

    private var heroConnectionCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusGlowColor.opacity(0.12))
                    .frame(width: 96, height: 96)

                Image(systemName: statusIconName)
                    .font(.system(size: 44))
                    .foregroundStyle(statusGlowColor)
            }
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text(viewModel.state.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                if case .connected(let details) = viewModel.state {
                    Text("Portal: \(details.portal)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    SessionTimerView(
                        expiresAt: details.sessionExpiresAt,
                        allowExtend: false
                    )
                    .padding(.top, 4)
                } else if case .failed(let message) = viewModel.state {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .textSelection(.enabled)
                } else if let message = viewModel.statusMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .textSelection(.enabled)
                } else {
                    Text("Secure remote access powered by OpenConnect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: {
                viewModel.toggleConnection()
            }) {
                HStack(spacing: 8) {
                    if viewModel.state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(buttonTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(minWidth: 160, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .disabled(viewModel.state == .disconnecting || (!viewModel.state.isBusy && !viewModel.state.isConnected && viewModel.profile.portal.isEmpty))
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

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

    private func connectedMetricsSection(details: ConnectedDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection Information")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCardView(
                    title: "Tunnel Address",
                    value: details.assignedIP ?? "Detecting…",
                    iconName: "network",
                    iconColor: .blue
                )

                MetricCardView(
                    title: "Session Duration",
                    value: viewModel.metrics.formattedDuration,
                    iconName: "clock",
                    iconColor: .indigo
                )

                MetricCardView(
                    title: "Data Received",
                    value: viewModel.metrics.formattedBytesReceived,
                    iconName: "arrow.down.circle",
                    iconColor: .green
                )

                MetricCardView(
                    title: "Data Sent",
                    value: viewModel.metrics.formattedBytesSent,
                    iconName: "arrow.up.circle",
                    iconColor: .teal
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                detailRow(icon: "server.rack", text: "Gateway: \(details.gatewayServer)")
                if let iface = details.interfaceName {
                    detailRow(icon: "point.3.connected.trianglepath.dotted", text: "Interface: \(iface)")
                }
                if let cipher = details.cipher {
                    detailRow(icon: "lock.shield", text: "Transport: \(cipher)")
                }
                if !details.assignedDNS.isEmpty {
                    detailRow(icon: "globe", text: "DNS: \(details.assignedDNS.joined(separator: ", "))")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gateway & Portal Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Portal Address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. vpn.company.com", text: $viewModel.profile.portal)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.state.isBusy)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gateway")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("", selection: Binding(
                            get: { viewModel.profile.selectedGatewayServer ?? "" },
                            set: { viewModel.selectGateway($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Automatic (portal priority order)").tag("")
                            ForEach(viewModel.gateways) { gw in
                                Text(gw.displayName).tag(gw.server)
                            }
                        }
                        .labelsHidden()
                    }

                    Button(action: {
                        viewModel.refreshGateways()
                    }) {
                        if viewModel.isDiscoveringGateways {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Discover", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isDiscoveringGateways || viewModel.state.isBusy || viewModel.profile.portal.isEmpty)
                    .help("Log in to the portal and list its gateways without opening a tunnel")
                }
            }

            Divider()
                .padding(.vertical, 4)

            Text("Authentication")
                .font(.headline)

            Picker("Method", selection: $viewModel.profile.authMethod) {
                ForEach(AuthMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.profile.authMethod {
            case .credentials:
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Username", text: $viewModel.profile.username)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Save password securely in macOS Keychain", isOn: $viewModel.rememberPassword)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Portals that require a one-time code after the password are not yet supported in the app; use Single Sign-On or the gpclient CLI for those.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .browserSSO:
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Browser", selection: $viewModel.profile.browserMode) {
                        ForEach(BrowserMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    HStack {
                        Image(systemName: "safari")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        Text("gpclient serves the SAML page on localhost and opens it in the browser. When the identity provider finishes, macOS hands the globalprotectcallback: URL back to this app, which completes the login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            case .clientCertificate:
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Username", text: $viewModel.profile.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    pathField(title: "Client Certificate (.pem / .p12)", placeholder: "/path/to/cert.pem", binding: Binding(
                        get: { viewModel.profile.certificatePath ?? "" },
                        set: { viewModel.profile.certificatePath = $0.isEmpty ? nil : $0 }
                    ))
                    pathField(title: "Private Key (.pem, optional for .p12)", placeholder: "/path/to/key.pem", binding: Binding(
                        get: { viewModel.profile.sslKeyPath ?? "" },
                        set: { viewModel.profile.sslKeyPath = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: viewModel.profile.authMethod) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.browserMode) { viewModel.saveProfile() }
    }

    private func pathField(title: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        binding.wrappedValue = url.path
                    }
                }
            }
        }
    }

    private var statusIconName: String {
        switch viewModel.state {
        case .connected: return "checkmark.shield.fill"
        case .connecting: return "shield.lefthalf.filled"
        case .disconnecting: return "shield"
        case .disconnected: return "shield"
        case .failed: return "exclamationmark.shield.fill"
        }
    }

    private var statusGlowColor: Color {
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
