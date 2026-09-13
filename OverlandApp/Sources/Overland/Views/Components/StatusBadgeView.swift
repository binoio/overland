import OverlandCore
import SwiftUI

public struct StatusBadgeView: View {
    public let state: VpnState

    public init(state: VpnState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(state.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .clipShape(Capsule())
    }

    private var indicatorColor: Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnecting:
            return .yellow
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var textColor: Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnecting:
            return .yellow
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var backgroundColor: Color {
        indicatorColor.opacity(0.12)
    }
}
