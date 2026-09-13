import OverlandCore
import SwiftUI

public struct SessionTimerView: View {
    public let expiresAt: Date?
    public let allowExtend: Bool
    public let onExtend: () -> Void

    public init(expiresAt: Date?, allowExtend: Bool = false, onExtend: @escaping () -> Void = {}) {
        self.expiresAt = expiresAt
        self.allowExtend = allowExtend
        self.onExtend = onExtend
    }

    public var body: some View {
        // TimelineView re-evaluates with the current `expiresAt` on every tick,
        // unlike a Timer closure, which would capture the value at creation.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)

                Text(label(at: context.date))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))

                if allowExtend {
                    Button(action: onExtend) {
                        Text("Extend")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.quaternaryLabelColor).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func label(at now: Date) -> String {
        guard let expiresAt else { return "Session lifetime not reported" }
        return "Expires in: \(Self.format(expiresAt.timeIntervalSince(now)))"
    }

    static func format(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Expired" }
        let total = Int(remaining)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
