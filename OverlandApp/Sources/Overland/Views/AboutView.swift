import OverlandCore
import SwiftUI

public struct AboutView: View {
    @ObservedObject var viewModel: VpnViewModel

    public init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { $0 == short ? short : "\(short) (\($0))" } ?? short
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(radius: 8)

            VStack(spacing: 4) {
                Text("Overland")
                    .font(.title2.weight(.bold))

                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A native macOS client for GlobalProtect VPN portals. Drives the gpclient CLI from GlobalProtect-openconnect, built with Swift and SwiftUI.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Divider()
                .frame(maxWidth: 320)

            VStack(spacing: 8) {
                HStack {
                    Text("Backend:")
                        .foregroundStyle(.secondary)
                    Text("gpclient \(viewModel.backendVersion ?? "(not found)") · OpenConnect")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("Privileges:")
                        .foregroundStyle(.secondary)
                    Text(viewModel.helperManager.isUsable ? "Privileged helper (approved)" : "Administrator dialog")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("License:")
                        .foregroundStyle(.secondary)
                    Text("GPL-3.0 (OpenConnect: LGPL-2.1, vpnc-script: GPL-2.0+)")
                        .fontWeight(.medium)
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
