import GlobalProtectCore
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var viewModel: VpnViewModel

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            networkTab
                .tabItem { Label("Network", systemImage: "network") }

            backendTab
                .tabItem { Label("Backend", systemImage: "terminal") }

            developerTab
                .tabItem { Label("Developer", systemImage: "hammer") }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private var generalTab: some View {
        Form {
            Section("Startup & Launch") {
                Toggle("Launch GlobalProtect at login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))

                Toggle("Auto-connect when app launches", isOn: $viewModel.profile.autoConnect)
                    .onChange(of: viewModel.profile.autoConnect) { viewModel.saveProfile() }
            }

            Section("Security & Credentials") {
                Toggle("Remember password in macOS Keychain", isOn: $viewModel.rememberPassword)
                    .onChange(of: viewModel.rememberPassword) { viewModel.saveProfile() }
            }
        }
        .formStyle(.grouped)
    }

    private var networkTab: some View {
        Form {
            Section("Tunnel Options") {
                Toggle("Disable IPv6", isOn: $viewModel.profile.disableIPv6)
                Toggle("Disable DTLS / ESP (force TCP/TLS)", isOn: $viewModel.profile.noDTLS)
                Toggle("Send HIP (Host Integrity) report", isOn: $viewModel.profile.enableHIP)
                Toggle("Treat the portal address as a gateway", isOn: $viewModel.profile.asGateway)
            }

            Section("TLS") {
                Toggle("Ignore TLS certificate errors", isOn: $viewModel.profile.ignoreTLSErrors)
                Toggle("Use extended OpenSSL compatibility mode", isOn: $viewModel.profile.fixOpenSSL)
            }

            Section("Advanced Tuning") {
                HStack {
                    Text("MTU (0 = automatic):")
                    Spacer()
                    TextField("0", value: $viewModel.profile.mtu, format: .number)
                        .frame(width: 80)
                }

                HStack {
                    Text("Dead peer detection interval (seconds):")
                    Spacer()
                    TextField("0", value: $viewModel.profile.forceDPD, format: .number)
                        .frame(width: 80)
                }

                HStack {
                    Text("Reconnect timeout (seconds):")
                    Spacer()
                    TextField("300", value: $viewModel.profile.reconnectTimeout, format: .number)
                        .frame(width: 80)
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

    private var backendTab: some View {
        Form {
            Section("gpclient") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Auto-detect", text: Binding(
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
            }

            Section("vpnc-script") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Auto-detect", text: Binding(
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
                    detectedRow(label: "Using", value: viewModel.resolvedVpncScriptPath)
                    Text("OpenConnect runs this script as root to configure the utun interface, routes and DNS.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privileges") {
                Picker("Run the tunnel with", selection: $viewModel.profile.privilegeMode) {
                    ForEach(PrivilegeMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: viewModel.profile.privilegeMode) { viewModel.saveProfile() }

                Text(privilegeHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Re-detect") { viewModel.refreshResolvedPaths() }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshResolvedPaths() }
    }

    private var privilegeHelp: String {
        switch viewModel.profile.privilegeMode {
        case .adminPrompt:
            return "macOS shows its standard authorization dialog each time the tunnel starts. It asks for an administrator's name and password, so it also works from a non-administrator account. Nothing is installed system-wide."
        case .sudoAskpass:
            return "A password dialog appears when the tunnel starts. sudo only accepts the password of the account running this app, which must be an administrator."
        case .sudoNonInteractive:
            let gp = viewModel.resolvedGpclientPath ?? "/path/to/gpclient"
            return "Requires a sudoers rule such as:\n\(NSUserName()) ALL=(root) NOPASSWD: \(gp)"
        case .direct:
            return "gpclient runs with this app's privileges. Only works if gpclient is setuid root or the app itself runs as root."
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

    private var developerTab: some View {
        Form {
            Section("Simulation & Mocking") {
                Toggle("Use Mock Bridge (offline simulation)", isOn: Binding(
                    get: { viewModel.useMockBridge },
                    set: { viewModel.setUseMockBridge($0) }
                ))

                Text("Simulates portal login, gateway discovery and an active tunnel without a VPN server, a gpclient build, or administrator privileges.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset Profile to Defaults") {
                    viewModel.resetProfile()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
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
