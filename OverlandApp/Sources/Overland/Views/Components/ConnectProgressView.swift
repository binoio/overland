import OverlandCore
import SwiftUI

/// Sign in → Authorize → Tunnel, with the current step highlighted.
struct ConnectProgressView: View {
    let phase: ConnectPhase
    let status: String
    let usesHelper: Bool
    let signInURL: String?
    let onReopenSignIn: () -> Void
    let onCancel: () -> Void

    private var steps: [ConnectPhase] {
        // With the helper there is no separate authorization step to show.
        usesHelper ? [.signIn, .tunnel] : ConnectPhase.allCases
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    stepView(step)
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(step.rawValue < phase.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(height: 2)
                            .frame(maxWidth: 60)
                    }
                }
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.subheadline)
                }
                if phase == .signIn, signInURL != nil {
                    Button("Reopen sign-in page") { onReopenSignIn() }
                        .controlSize(.small)
                        .help("If the browser tab was closed or lost, open the sign-in page again")
                }
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func stepView(_ step: ConnectPhase) -> some View {
        let done = step.rawValue < phase.rawValue
        let current = step == phase
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(done || current ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(current ? .white : .secondary)
                }
            }
            Text(step.title)
                .font(.caption)
                .foregroundStyle(current ? .primary : .secondary)
        }
        .frame(width: 88)
    }
}
