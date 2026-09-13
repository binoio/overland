import GlobalProtectCore
import SwiftUI

public struct AboutView: View {
    public var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(radius: 8)

            VStack(spacing: 4) {
                Text("GlobalProtect for macOS")
                    .font(.title2.weight(.bold))

                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · Native SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A native macOS client for GlobalProtect VPN. Drives the gpclient CLI from GlobalProtect-openconnect, built with Swift and SwiftUI.")
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
                    Text("gpclient (GlobalProtect-openconnect) + OpenConnect")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("Privileges:")
                        .foregroundStyle(.secondary)
                    Text("Tunnel runs via sudo; authentication runs as you")
                        .fontWeight(.medium)
                }
                .font(.caption)

                HStack {
                    Text("License:")
                        .foregroundStyle(.secondary)
                    Text("App: MIT · gpclient: GPL-3.0 · OpenConnect: LGPL-2.1")
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
