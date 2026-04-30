import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

/// Reads recent log entries emitted by Orbit Dictation's own subsystem from
/// the macOS unified log store. Lets users see what `AXIsProcessTrusted()`
/// (and other instrumented checks) are actually returning without dropping
/// to Terminal and running `log stream`.
///
/// Limitations: `OSLogStore(scope: .currentProcessIdentifier)` only sees
/// log entries emitted by the *current* process — quitting and relaunching
/// the app starts a fresh window. That matches the diagnostic case (grant a
/// permission, watch the next check fire) but doesn't recover history from
/// a previous session.
@MainActor
final class LogReader: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    @Published var entries: [Entry] = []
    @Published var error: String?
    @Published var isLoading: Bool = false

    private let subsystem: String

    init(subsystem: String = "team.yourorbit.OrbitDictation") {
        self.subsystem = subsystem
    }

    /// Re-query the unified log store. Runs the disk read off the main
    /// thread because `getEntries(at:)` can block briefly while the store
    /// scans on-disk pages.
    func refresh(lookback: TimeInterval = 1800, maxEntries: Int = 300) {
        isLoading = true

        let subsystem = self.subsystem
        Task.detached {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let cutoff = store.position(date: Date().addingTimeInterval(-lookback))
                let raw = try store.getEntries(at: cutoff)

                let filtered = raw
                    .compactMap { $0 as? OSLogEntryLog }
                    .filter { $0.subsystem == subsystem }

                let mapped = filtered.suffix(maxEntries).map { entry -> Entry in
                    Entry(
                        date: entry.date,
                        category: entry.category,
                        level: Self.levelString(entry.level),
                        message: entry.composedMessage
                    )
                }

                await MainActor.run {
                    self.entries = Array(mapped)
                    self.error = nil
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.entries = []
                    self.isLoading = false
                }
            }
        }
    }

    // `nonisolated` so the detached refresh Task can call it without
    // hopping back to the main actor. The function is pure — no state
    // access — so isolation isn't needed.
    nonisolated private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "—"
        case .debug:     return "DEBUG"
        case .info:      return "INFO"
        case .notice:    return "NOTE"
        case .error:     return "ERROR"
        case .fault:     return "FAULT"
        @unknown default: return "—"
        }
    }
}

/// Disclosure-style log viewer for the Troubleshooting card. Auto-refreshes
/// on appear; users can hit Refresh to re-read after granting a permission
/// or whatever other event they want to confirm. Copy-to-clipboard returns
/// a plain-text dump suitable for pasting into a GitHub issue or chat.
struct LiveLogsView: View {
    @StateObject private var reader = LogReader()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    reader.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(reader.isLoading)

                Button {
                    copyToPasteboard()
                } label: {
                    Label("Copy logs", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(reader.entries.isEmpty)

                if reader.isLoading {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Text("\(reader.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = reader.error {
                Text("Error reading log store: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if reader.entries.isEmpty && reader.error == nil {
                Text("No log entries from this process yet. Trigger an action (e.g., grant Accessibility, click Recheck) and refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(reader.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Self.timeFormatter.string(from: entry.date)) · \(entry.level) · \(entry.category)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 260)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear {
            reader.refresh()
        }
    }

    private func copyToPasteboard() {
        let lines = reader.entries.map { e -> String in
            "\(Self.timeFormatter.string(from: e.date)) [\(e.level)] [\(e.category)] \(e.message)"
        }
        let payload = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}
