import OverlandCore
import SwiftUI

/// Dedicated window for viewing and editing connection parameters (portal, auth method, gateway).
public struct ConnectionEditView: View {
    @ObservedObject var viewModel: VpnViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    public init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection")
                .font(.title2.weight(.bold))

            ConnectionEditorView(viewModel: viewModel)

            HStack {
                Spacer()
                Button("Done") {
                    viewModel.saveProfile()
                    dismissWindow()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600)
    }
}
