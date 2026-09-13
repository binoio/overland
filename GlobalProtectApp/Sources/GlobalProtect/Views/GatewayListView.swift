import GlobalProtectCore
import SwiftUI

public struct GatewayListView: View {
    @ObservedObject var viewModel: VpnViewModel
    @State private var showingAddGatewaySheet = false
    @State private var newGatewayName = ""
    @State private var newGatewayServer = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gateways")
                        .font(.title2.weight(.bold))
                    Text("Gateways the portal advertised on the last login, plus any you added by hand")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: { showingAddGatewaySheet = true }) {
                    Label("Add Gateway", systemImage: "plus")
                }

                Button(action: { viewModel.refreshGateways() }) {
                    if viewModel.isDiscoveringGateways {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Discover", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isDiscoveringGateways || viewModel.state.isBusy || viewModel.profile.portal.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            if viewModel.gateways.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text("No Gateways Known")
                        .font(.headline)

                    Text("Discover logs in to the portal and lists its gateways without opening a tunnel. Gateways are also learned automatically on every connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)

                    Button("Discover Gateways") {
                        viewModel.refreshGateways()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isDiscoveringGateways || viewModel.state.isBusy || viewModel.profile.portal.isEmpty)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    Section {
                        gatewayRow(
                            name: "Automatic",
                            server: "gpclient tries gateways in the portal's priority order",
                            priority: nil,
                            isSelected: viewModel.profile.selectedGatewayServer == nil,
                            isManual: false,
                            onSelect: { viewModel.selectGateway(nil) },
                            onRemove: nil
                        )
                    }

                    Section("Known Gateways") {
                        ForEach(viewModel.gateways) { gw in
                            gatewayRow(
                                name: gw.name,
                                server: gw.server,
                                priority: gw.priority,
                                isSelected: viewModel.profile.selectedGatewayServer == gw.server,
                                isManual: gw.isManual,
                                onSelect: { viewModel.selectGateway(gw.server) },
                                onRemove: gw.isManual ? { viewModel.removeGateway(gw) } : nil
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingAddGatewaySheet) {
            VStack(spacing: 16) {
                Text("Add Gateway")
                    .font(.headline)

                TextField("Display name (optional)", text: $newGatewayName)
                    .textFieldStyle(.roundedBorder)

                TextField("Gateway hostname", text: $newGatewayServer)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Cancel") { showingAddGatewaySheet = false }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)

                    Button("Add") {
                        viewModel.addManualGateway(name: newGatewayName, server: newGatewayServer)
                        newGatewayName = ""
                        newGatewayServer = ""
                        showingAddGatewaySheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newGatewayServer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    private func gatewayRow(
        name: String,
        server: String,
        priority: Int?,
        isSelected: Bool,
        isManual: Bool,
        onSelect: @escaping () -> Void,
        onRemove: (() -> Void)?
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.body.weight(.medium))

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                    }

                    if isManual {
                        Text("manual")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(server)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let priority {
                Text("priority \(priority)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Remove this manual gateway")
            }

            Button(isSelected ? "Selected" : "Select") {
                onSelect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSelected)
        }
        .padding(.vertical, 4)
    }
}
