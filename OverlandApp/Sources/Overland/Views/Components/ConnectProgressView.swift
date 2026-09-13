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
    var onDeliverCallback: ((String) -> Void)? = nil

    @State private var showingManualCallbackSheet = false
    @State private var manualCallbackText = ""

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
                if phase == .signIn {
                    HStack(spacing: 12) {
                        if signInURL != nil {
                            Button("Reopen sign-in page") { onReopenSignIn() }
                                .controlSize(.small)
                                .help("If the browser tab was closed or lost, open the sign-in page again")
                        }
                        if onDeliverCallback != nil {
                            Button("Paste callback URL…") {
                                manualCallbackText = ""
                                showingManualCallbackSheet = true
                            }
                            .controlSize(.small)
                            .help("If your browser didn't return to Overland automatically, paste the callback URL or data here")
                        }
                    }
                }
            }

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .sheet(isPresented: $showingManualCallbackSheet) {
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
                    Button("Cancel") { showingManualCallbackSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Submit") {
                        let trimmed = manualCallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onDeliverCallback?(trimmed)
                            showingManualCallbackSheet = false
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
