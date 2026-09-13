import OverlandCore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var viewModel: VpnViewModel
    /// Sparkle's controls, injected by the app so previews/tests need no updater.
    var updatesSection: AnyView? = nil
    @State private var confirmingReset = false

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            networkTab
                .tabItem { Label("Network", systemImage: "network") }

            backendTab
                .tabItem { Label("Backend", systemImage: "terminal") }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 460, idealHeight: 520)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Behavior") {
                Toggle("Launch Overland at login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))

                Toggle("Connect automatically when Overland starts", isOn: $viewModel.profile.autoConnect)
                    .onChange(of: viewModel.profile.autoConnect) { viewModel.saveProfile() }
                    .disabled(viewModel.profile.portal.isEmpty)
                if viewModel.profile.portal.isEmpty {
                    Text("Configure a connection first.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show only in the menu bar", isOn: Binding(
                    get: { viewModel.menuBarOnly },
                    set: { viewModel.setMenuBarOnly($0) }
                ))
                Text("Hides the Dock icon. Open the window any time from the menu bar item.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let updatesSection {
                updatesSection
            }

            Section("Credentials") {
                Toggle("Remember password in macOS Keychain", isOn: $viewModel.rememberPassword)
                    .onChange(of: viewModel.rememberPassword) { viewModel.saveProfile() }
                Text("Only applies to the Username & Password sign-in method.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults…", role: .destructive) {
                    confirmingReset = true
                }
                .confirmationDialog("Reset Overland to defaults?", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) {
                        Task {
                            await viewModel.disconnectAndWait()
                            viewModel.resetProfile()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The configured connection — portal, sign-in method, gateways, saved password and options — will be removed and first-time setup will run again. If the VPN is connected it is disconnected first.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Network

    private var networkTab: some View {
        Form {
            Section("Tunnel") {
                // The profile keeps gpclient's negative flags; the UI shows the positive.
                Toggle("Enable IPv6", isOn: Binding(
                    get: { !viewModel.profile.disableIPv6 },
                    set: { viewModel.profile.disableIPv6 = !$0 }
                ))
                Toggle("Enable DTLS / ESP (UDP transport; off forces TCP/TLS)", isOn: Binding(
                    get: { !viewModel.profile.noDTLS },
                    set: { viewModel.profile.noDTLS = !$0 }
                ))
                Toggle("Send HIP (Host Integrity) report", isOn: $viewModel.profile.enableHIP)
                Toggle("Treat the portal address as a gateway", isOn: $viewModel.profile.asGateway)
            }

            Section("TLS") {
                Toggle("Ignore TLS certificate errors", isOn: $viewModel.profile.ignoreTLSErrors)
                Toggle("Use extended OpenSSL compatibility mode", isOn: $viewModel.profile.fixOpenSSL)
            }

            Section("Tuning") {
                LabeledContent("MTU (0 = automatic)") {
                    TextField("0", value: $viewModel.profile.mtu, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Dead peer detection interval (s)") {
                    TextField("0", value: $viewModel.profile.forceDPD, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Reconnect timeout (s)") {
                    TextField("300", value: $viewModel.profile.reconnectTimeout, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: viewModel.profile.disableIPv6) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.noDTLS) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.enableHIP) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.asGateway) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.ignoreTLSErrors) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.fixOpenSSL) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.mtu) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.forceDPD) { viewModel.saveProfile() }
        .onChange(of: viewModel.profile.reconnectTimeout) { viewModel.saveProfile() }
    }

    // MARK: Backend

    private var backendTab: some View {
        Form {
            Section("Privileges") {
                Picker("Open the tunnel with", selection: $viewModel.profile.privilegeMode) {
                    ForEach(PrivilegeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: viewModel.profile.privilegeMode) { viewModel.saveProfile() }

                Text(privilegeHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HelperStatusRow(manager: viewModel.helperManager, onUninstall: { await viewModel.uninstallHelper() })
            }

            Section("Binaries") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("gpclient (auto-detect)", text: Binding(
                            get: { viewModel.customBinaryPath },
                            set: { viewModel.setCustomBinaryPath($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            if let path = chooseFile() { viewModel.setCustomBinaryPath(path) }
                        }
                    }
                    detectedRow(label: "gpclient", value: viewModel.resolvedGpclientPath)
                    detectedRow(label: "gpauth (SSO)", value: viewModel.resolvedGpauthPath)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("vpnc-script (auto-detect)", text: Binding(
                            get: { viewModel.profile.vpncScriptPath ?? "" },
                            set: {
                                viewModel.profile.vpncScriptPath = $0.isEmpty ? nil : $0
                                viewModel.saveProfile()
                                viewModel.refreshResolvedPaths()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            if let path = chooseFile() {
                                viewModel.profile.vpncScriptPath = path
                                viewModel.saveProfile()
                                viewModel.refreshResolvedPaths()
                            }
                        }
                    }
                    detectedRow(label: "vpnc-script", value: viewModel.resolvedVpncScriptPath)
                }

                Button("Re-detect") { viewModel.refreshResolvedPaths() }
            }

            Section("Advanced") {
                Toggle("Use mock backend (offline simulation)", isOn: Binding(
                    get: { viewModel.useMockBridge },
                    set: { viewModel.setUseMockBridge($0) }
                ))
                Text("Simulates sign-in, gateway discovery and a tunnel without a VPN server, a gpclient build, or privileges.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshResolvedPaths() }
    }

    private var privilegeHelp: String {
        switch viewModel.profile.privilegeMode {
        case .helper:
            return "A small root helper inside the app is registered with launchd and approved once in System Settings › Login Items & Extensions. After that, connecting never prompts. Requires a signed build; falls back to the dialog when unavailable."
        case .adminPrompt:
            return "macOS shows its standard authorization dialog each time the tunnel starts. It asks for an administrator’s name and password, so it also works from a non-administrator account."
        }
    }

    private func detectedRow(label: String, value: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: value == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(value == nil ? Color.red : Color.green)
            Text("\(label): \(value ?? "not found")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Observes the helper manager directly so status changes re-render.
struct HelperStatusRow: View {
    @ObservedObject var manager: HelperManager
    var onUninstall: () async -> Void
    @State private var confirmingUninstall = false
    @State private var uninstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: manager.status == .enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(manager.status == .enabled ? Color.green : Color.secondary)
                Text("Helper: \(manager.status.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                switch manager.status {
                case .notRegistered:
                    Button("Enable…") { manager.enable() }
                        .controlSize(.small)
                case .requiresApproval:
                    Button("Open System Settings…") { manager.openSystemSettings() }
                        .controlSize(.small)
                    Button("Re-check") { manager.refresh() }
                        .controlSize(.small)
                case .enabled:
                    Button("Uninstall…") { confirmingUninstall = true }
                        .controlSize(.small)
                        .disabled(uninstalling)
                case .unsignedBuild, .notFound:
                    EmptyView()
                }
            }
            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { manager.refresh() }
        .confirmationDialog(
            "Uninstall the privileged helper?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                uninstalling = true
                Task {
                    await onUninstall()
                    uninstalling = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes Overland from Login Items & Extensions. If the VPN is connected it is disconnected first. Connecting will then show the administrator authorization dialog until the helper is enabled again. Trashing the app afterwards leaves nothing behind.")
        }
    }
}
