import OverlandCore
import SwiftUI

public struct ContentView: View {
    @ObservedObject var viewModel: VpnViewModel
    // Collapsed on first open; the toolbar's sidebar button (or ⌃⌘S) reveals
    // it, and SwiftUI remembers the choice for later launches.
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    public init(viewModel: VpnViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.needsSetup {
            SetupView(viewModel: viewModel)
                .frame(minWidth: 620, minHeight: 560)
        } else {
            mainSplit
        }
    }

    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            detailContent
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            if viewModel.useMockBridge {
                ToolbarItem(placement: .status) {
                    Text("MOCK")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                        .help("Mock backend is enabled in Settings ▸ Backend ▸ Advanced")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    viewModel.toggleConnection()
                }) {
                    Label(
                        viewModel.state.isConnected ? "Disconnect" : (viewModel.state.isConnecting ? "Cancel" : "Connect"),
                        systemImage: viewModel.state.isConnected || viewModel.state.isConnecting ? "stop.circle" : "play.circle"
                    )
                }
                .tint(viewModel.state.isConnected || viewModel.state.isConnecting ? .red : .accentColor)
                .disabled(viewModel.state == .disconnecting || (viewModel.state.isDisconnected && viewModel.profile.portal.isEmpty))
            }
        }
        .onAppear {
            viewModel.handleLaunch()
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List(NavigationTab.allCases, selection: $viewModel.selectedTab) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.iconName)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "shield.fill")
                    .foregroundStyle(statusColor)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.profile.portal.isEmpty ? "No Portal" : viewModel.profile.portal)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text(viewModel.state.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.selectedTab {
        case .connection:
            ConnectionDetailView(viewModel: viewModel)
        case .gateways:
            GatewayListView(viewModel: viewModel)
        case .logs:
            LogsView(viewModel: viewModel)
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
