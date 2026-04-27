//
//  LogStreamer.swift
//  TestFS
//
//  Live tail of the FSKit-extension log via /usr/bin/log stream
//  with `--style ndjson`. We iterate the subprocess's stdout via
//  `FileHandle.bytes.lines` — the AsyncSequence handles
//  line-buffered chunking for free, so we just decode each line as
//  JSON and append to the ring buffer.
//
//  Why not OSLogStore.local()? — it's archive-only with no live
//  subscription API. `log stream` is Apple's documented surface
//  for live tailing and is what Console.app uses under the hood;
//  the underlying XPC to logd isn't public.
//
//  Why ndjson over the default syslog format? structured fields
//  (timestamp, subsystem, category, messageType, eventMessage) so
//  the UI gets proper colors/columns instead of regex-parsing.
//

import Foundation

@MainActor
final class LogStreamer: ObservableObject {
    enum Level {
        case debug, info, notice, error, fault, undefined
    }

    struct Entry: Identifiable {
        let id: Int
        let date: Date
        let category: String
        let level: Level
        let message: String
    }

    @Published private(set) var lines: [Entry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let maxLines = 5000
    private let trimBatch = 500

    private var process: Process?
    private var streamTask: Task<Void, Never>?
    private var nextID: Int = 0

    private static let predicate = "subsystem == \"\(TestFSConstants.logSubsystem)\""

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil

        streamTask = Task { [weak self] in
            await self?.runStream()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
        isRunning = false
    }

    /// Spawns `/usr/bin/log stream` with our subsystem predicate and
    /// pipes its NDJSON stdout into the ring buffer. Returns when
    /// the Task is cancelled in `stop()` or the subprocess exits.
    private func runStream() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--predicate", Self.predicate,
            "--style", "ndjson",
            "--level", "debug"
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        // Discard stderr — `log` writes the occasional informational
        // line ("Filtering the log data using ...") there, and we
        // don't surface it. nullDevice instead of an undrained Pipe
        // avoids the ~64 KB pipe-buffer-full block the child would
        // hit on a chatty stream.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastError = "failed to spawn log stream: \(error.localizedDescription)"
            return
        }
        process = proc

        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                if let entry = makeEntry(from: line) {
                    append(entry)
                }
            }
        } catch is CancellationError {
            // expected on stop()
        } catch {
            recordStreamError(error)
        }

        if proc.isRunning { proc.terminate() }
        proc.waitUntilExit()
        process = nil
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
    }

    // MARK: - per-line plumbing

    private static let decoder = JSONDecoder()

    private func makeEntry(from line: String) -> Entry? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let raw = try? Self.decoder.decode(NDJSONEntry.self, from: data) else {
            return nil
        }
        let id = nextID
        nextID &+= 1
        return Entry(
            id: id,
            date: Self.parseDate(raw.timestamp) ?? Date(),
            category: raw.category ?? "",
            level: Self.mapLevel(raw.messageType),
            message: raw.eventMessage ?? ""
        )
    }

    private func append(_ entry: Entry) {
        lines.append(entry)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - (maxLines - trimBatch))
        }
    }

    private func recordStreamError(_ error: Error) {
        lastError = "log stream read failed: \(error.localizedDescription)"
        isRunning = false
    }

    // MARK: - JSON shape

    private struct NDJSONEntry: Decodable {
        let timestamp: String?
        let subsystem: String?
        let category: String?
        let messageType: String?
        let eventMessage: String?
    }

    /// log-stream's ndjson timestamp shape:
    /// `2026-04-27 17:14:47.479578+0100`. Not strict ISO 8601
    /// (space, no T; microseconds; no colon in offset), so
    /// ISO8601DateFormatter rejects it. DateFormatter truncates
    /// the fractional part to milliseconds, which is fine for UI.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return timestampFormatter.date(from: raw)
    }

    private static func mapLevel(_ raw: String?) -> Level {
        switch raw?.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "default", "notice": return .notice
        case "error": return .error
        case "fault": return .fault
        default: return .undefined
        }
    }
}
