import OverlandCore
import SwiftUI

/// Dedicated window for manually adding a gateway server.
public struct AddGatewayView: View {
    @ObservedObject var viewModel: VpnViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var newGatewayName = ""
    @State private var newGatewayServer = ""

    public init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Add Gateway")
                .font(.headline)

            TextField("Display name (optional)", text: $newGatewayName)
                .textFieldStyle(.roundedBorder)

            TextField("Gateway hostname", text: $newGatewayServer)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismissWindow()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    viewModel.addManualGateway(name: newGatewayName, server: newGatewayServer)
                    newGatewayName = ""
                    newGatewayServer = ""
                    dismissWindow()
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
