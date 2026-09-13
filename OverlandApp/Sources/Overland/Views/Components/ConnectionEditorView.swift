import OverlandCore
import SwiftUI

/// Portal, sign-in method and gateway — the fields a connection needs.
/// Used by first-run setup and by "Change…" on the Connection tab.
struct ConnectionEditorView: View {
    @ObservedObject var viewModel: VpnViewModel
    var showGateway: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Portal address") {
                TextField("vpn.example.edu", text: $viewModel.profile.portal)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(viewModel.state.isBusy)
            }

            field("Sign in with") {
                Picker("", selection: $viewModel.profile.authMethod) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: viewModel.profile.authMethod) { viewModel.saveProfile() }
            }

            switch viewModel.profile.authMethod {
            case .browserSSO:
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Browser", selection: $viewModel.profile.browserMode) {
                        ForEach(BrowserMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .onChange(of: viewModel.profile.browserMode) { viewModel.saveProfile() }
                    Text("Your organization’s sign-in page opens in the browser; when it finishes, macOS hands the result back to Overland.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .credentials:
                VStack(alignment: .leading, spacing: 10) {
                    field("Username") {
                        TextField("Username", text: $viewModel.profile.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Password") {
                        SecureField("Password", text: $viewModel.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Remember in Keychain", isOn: $viewModel.rememberPassword)
                        .font(.caption)
                    Text("Portals that ask for a one-time code after the password aren’t supported here; use Single Sign-On for those.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            case .clientCertificate:
                VStack(alignment: .leading, spacing: 10) {
                    field("Username (optional)") {
                        TextField("Username", text: $viewModel.profile.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    pathField(title: "Client certificate (.pem / .p12)", placeholder: "/path/to/cert.p12", binding: Binding(
                        get: { viewModel.profile.certificatePath ?? "" },
                        set: { viewModel.profile.certificatePath = $0.isEmpty ? nil : $0 }
                    ))
                    pathField(title: "Private key (.pem, optional for .p12)", placeholder: "/path/to/key.pem", binding: Binding(
                        get: { viewModel.profile.sslKeyPath ?? "" },
                        set: { viewModel.profile.sslKeyPath = $0.isEmpty ? nil : $0 }
                    ))
                }
            }

            if showGateway {
                field("Gateway") {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { viewModel.profile.selectedGatewayServer ?? "" },
                            set: { viewModel.selectGateway($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Automatic (portal’s preferred order)").tag("")
                            ForEach(viewModel.gateways) { gw in
                                Text(gw.displayName).tag(gw.server)
                            }
                        }
                        .labelsHidden()

                        Button {
                            viewModel.refreshGateways()
                        } label: {
                            if viewModel.isDiscoveringGateways {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Discover", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.isDiscoveringGateways || viewModel.state.isBusy || viewModel.profile.portal.isEmpty)
                        .help("Sign in to the portal and list its gateways without opening a tunnel")
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func pathField(title: String, placeholder: String, binding: Binding<String>) -> some View {
        field(title) {
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
}
