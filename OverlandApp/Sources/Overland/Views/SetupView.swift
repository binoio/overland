import OverlandCore
import SwiftUI

/// First run: portal, sign-in method, and the one-time helper approval.
struct SetupView: View {
    @ObservedObject var viewModel: VpnViewModel
    @ObservedObject var helper: HelperManager

    init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
        self.helper = viewModel.helperManager
    }

    private var canContinue: Bool {
        !viewModel.profile.portal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("Welcome to Overland")
                        .font(.largeTitle.weight(.bold))
                    Text("Three things and you’re on the road.")
                        .foregroundStyle(.secondary)
                }

                stepCard(number: 1, title: "Your VPN portal") {
                    ConnectionEditorView(viewModel: viewModel, showGateway: false)
                }

                stepCard(number: 2, title: "Privileged helper", subtitle: "Opening the tunnel needs root. Approve Overland once in System Settings and you’ll never see a password prompt for it again.") {
                    HelperStatusRow(manager: helper, onUninstall: { await viewModel.uninstallHelper() })
                    if helper.status == .unsignedBuild {
                        Text("This build isn’t signed, so the helper can’t be installed; Overland will ask for an administrator’s name and password each time it connects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                stepCard(number: 3, title: "Connect") {
                    HStack {
                        Text(canContinue ? "Save these settings and go to the connection screen." : "Enter a portal address to continue.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Continue") { viewModel.completeSetup() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canContinue)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { helper.refresh() }
    }

    private func stepCard<Content: View>(number: Int, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
