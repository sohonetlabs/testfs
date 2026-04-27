//
//  LogView.swift
//  TestFS
//
//  Streaming log window for the FSKit extension. Bound to a
//  LogStreamer; auto-scrolls to the bottom on each new batch unless
//  the user toggles Auto-scroll off.
//

import SwiftUI

struct LogView: View {
    @StateObject private var streamer = LogStreamer()
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                Button("Clear") { streamer.clear() }
                Spacer()
                Text("\(streamer.lines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let err = streamer.lastError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(streamer.lines) { entry in
                            row(for: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: streamer.lines.last?.id) { _, _ in
                    guard autoScroll, let last = streamer.lines.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 320)
        .task { streamer.start() }
        .onDisappear { streamer.stop() }
    }

    @ViewBuilder
    private func row(for entry: LogStreamer.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text("[\(entry.category)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .frame(width: 100, alignment: .leading)
            Text(Self.levelLabel(entry.level))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Self.levelColor(entry.level))
                .frame(width: 56, alignment: .leading)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func levelLabel(_ level: LogStreamer.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "—"
        }
    }

    private static func levelColor(_ level: LogStreamer.Level) -> Color {
        switch level {
        case .error, .fault: return .red
        case .notice: return .orange
        case .debug: return .secondary
        default: return .primary
        }
    }
}

#Preview {
    LogView()
}
