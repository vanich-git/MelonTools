import Foundation
import os

/// Durable usage history: one JSONL file per local day under
/// `~/Library/Application Support/MelonTools/usage/`.
///
/// The gateway already prints `[usage]` lines; this store keeps them so the
/// Usage screen survives app restarts. Files are 0600, the folder is 0700, and
/// nothing here ever touches an API key: the record carries provider, auth
/// name, model and token counts only.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "Usage")

    /// Ascending by time: charts and "last events" both read it from the end.
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var lastRecordedAt: Date?
    @Published private(set) var error: String?

    private let baseDirectory: URL
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var openHandle: (day: String, handle: FileHandle)?

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDirectory = base
            .appendingPathComponent("MelonTools", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
    }

    var directory: URL { baseDirectory }

    // MARK: - Loading

    /// Reads the retained files once. Safe to call from every view's onAppear.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        load()
    }

    func reload() {
        load()
    }

    private func load() {
        var loaded: [UsageEvent] = []
        var identifiers: Set<String> = []
        do {
            try ensureDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasPrefix("usage-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(UsageHistory.retentionDays)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files {
                guard let data = try? Data(contentsOf: file) else { continue }
                for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    guard let event = try? decoder.decode(UsageEvent.self, from: Data(line)) else { continue }
                    if identifiers.insert(event.id).inserted {
                        loaded.append(event)
                    }
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("usage history load failed: \(error.localizedDescription, privacy: .public)")
        }
        events = loaded.sorted { $0.at < $1.at }
        seen = Set(events.map(\.id))
        seenOrder = events.map(\.id)
        isLoaded = true
        pruneFiles()
    }

    // MARK: - Recording

    /// Appends one parsed gateway usage line. Duplicates are ignored: a log
    /// tail restart replays the recent bytes and must not double count.
    func record(_ record: CodexGatewayService.UsageRecord) {
        loadIfNeeded()
        let event = UsageEvent(
            at: record.time,
            model: record.model,
            provider: record.provider,
            auth: record.auth,
            input: record.inputTokens,
            output: record.outputTokens,
            mode: record.mode,
            status: record.status
        )
        guard remember(event.id) else { return }
        events.append(event)
        if let last = events.dropLast().last, last.at > event.at {
            events.sort { $0.at < $1.at }
        }
        lastRecordedAt = event.at
        appendToDisk(event)
    }

    /// Replays the in-memory tail of the gateway service at launch, so the
    /// history has no hole when the app starts while the engine keeps running.
    func record(_ records: [CodexGatewayService.UsageRecord]) {
        for record in records.sorted(by: { $0.time < $1.time }) {
            self.record(record)
        }
    }

    private func remember(_ id: String) -> Bool {
        guard !seen.contains(id) else { return false }
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > 120_000 {
            let keep = seenOrder.suffix(60_000)
            seenOrder = Array(keep)
            seen = Set(keep)
        }
        return true
    }

    // MARK: - Files

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: baseDirectory.path, isDirectory: &isDirectory) {
            return
        }
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func fileURL(for day: String) -> URL {
        baseDirectory.appendingPathComponent("usage-\(day).jsonl")
    }

    private func appendToDisk(_ event: UsageEvent) {
        let day = Self.dayFormatter.string(from: event.at)
        do {
            try ensureDirectory()
            let handle: FileHandle
            if let openHandle, openHandle.day == day {
                handle = openHandle.handle
            } else {
                openHandle?.handle.closeFile()
                openHandle = nil
                let url = fileURL(for: day)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(
                        atPath: url.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                openHandle = (day, handle)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(event)
            data.append(UInt8(ascii: "\n"))
            try handle.write(contentsOf: data)
        } catch {
            self.error = error.localizedDescription
            Self.logger.error("usage append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops day files older than the retention window.
    private func pruneFiles() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -UsageHistory.retentionDays, to: Date()) else { return }
        let cutoffDay = Self.dayFormatter.string(from: cutoff)
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("usage-") {
            let day = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "usage-", with: "")
            if day < cutoffDay {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Removes every recorded event and every day file. Used by the explicit
    /// "Clear history" action only.
    func clear() {
        openHandle?.handle.closeFile()
        openHandle = nil
        guard let files = try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            events = []
            seen = []
            seenOrder = []
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("usage-") {
            try? FileManager.default.removeItem(at: file)
        }
        events = []
        seen = []
        seenOrder = []
        lastRecordedAt = nil
        error = nil
    }
}
