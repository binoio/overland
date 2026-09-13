import JeepNetCore
import SwiftUI

public struct LogsView: View {
    @ObservedObject var viewModel: VpnViewModel
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchQuery: String = ""
    @State private var autoScroll: Bool = true

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar header
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter logs…", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: 240)

                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .frame(width: 140)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                Button(action: {
                    viewModel.copyLogsToClipboard()
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button(action: {
                    viewModel.clearLogs()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Log Console
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Text("[\(entry.level.rawValue)]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(levelColor(entry.level))
                                    .frame(width: 60, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: viewModel.logs.count) {
                    if autoScroll, let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredLogs: [LogEntry] {
        viewModel.logs.filter { entry in
            if let level = selectedLevel, entry.level != level {
                return false
            }
            if !searchQuery.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchQuery)
            }
            return true
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .debug: return .secondary
        }
    }
}
