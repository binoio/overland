import OverlandCore
import SwiftUI

/// Dedicated window for pasting an authentication callback URL when automatic browser redirect is not available.
public struct ManualCallbackView: View {
    @ObservedObject var viewModel: VpnViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var manualCallbackText = ""

    public init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste Authentication Callback")
                .font(.headline)

            Text("If the browser showed \"Authentication complete\" but did not return to Overland automatically, copy the URL from the browser address bar or redirect page and paste it below:")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("globalprotectcallback:...", text: $manualCallbackText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel") {
                    dismissWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Submit") {
                    let trimmed = manualCallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        viewModel.deliverAuthCallback(trimmed)
                        manualCallbackText = ""
                        dismissWindow()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(manualCallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
