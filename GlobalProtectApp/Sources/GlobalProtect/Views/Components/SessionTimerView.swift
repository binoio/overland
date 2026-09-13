import GlobalProtectCore
import SwiftUI

public struct SessionTimerView: View {
    public let expiresAt: Date?
    public let allowExtend: Bool
    public let onExtend: () -> Void

    @State private var remainingTime: String = "--:--"
    @State private var timer: Timer?

    public init(expiresAt: Date?, allowExtend: Bool = false, onExtend: @escaping () -> Void = {}) {
        self.expiresAt = expiresAt
        self.allowExtend = allowExtend
        self.onExtend = onExtend
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)

            Text(expiresAt == nil ? "Session lifetime not reported" : "Expires in: \(remainingTime)")
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
        .onAppear {
            updateRemaining()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                updateRemaining()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateRemaining() {
        guard let expiresAt = expiresAt else {
            remainingTime = "–"
            return
        }

        let diff = expiresAt.timeIntervalSince(Date())
        guard diff > 0 else {
            remainingTime = "Expired"
            return
        }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        let seconds = Int(diff) % 60
        if hours > 0 {
            remainingTime = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            remainingTime = String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
