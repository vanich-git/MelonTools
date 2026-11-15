import Foundation

/// The Hub avatar endpoints return JSON (`{"avatarUrl": "https://…"}`), not
/// image bytes, so every publisher costs one or two requests. A catalogue page
/// shows about a dozen distinct publishers and the user re-opens it constantly,
/// therefore resolved URLs are cached in memory for the session and on disk for
/// a week, at most `maximumEntries` publishers. A publisher without an avatar is
/// cached too, but only when the Hub says so definitively: the answer will not
/// change between two sorts of the same list, while a throttled or unreachable
/// Hub is asked again later.
actor HFAvatarService {
    static let shared = HFAvatarService()

    private struct Entry: Codable {
        /// `nil` records "the Hub has no avatar for this publisher".
        var url: String?
        var at: Date
        /// LRU marker. Optional so a file written before the cache was bounded
        /// still decodes; entries without it fall back to `at`.
        var lastUsed: Date?

        var lastActivity: Date { lastUsed ?? at }
    }

    /// What one lookup produced. Only the first two are facts about the
    /// publisher; `failed` is a fact about the network.
    private enum Outcome {
        case found(URL)
        case absent
        case failed
    }

    private var requests: [String: Task<URL?, Never>] = [:]
    private var entries: [String: Entry]?

    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Publishers come and go; the cache must not grow with the catalogue.
    private static let maximumEntries = 200
    /// A stuck avatar must not pin its `requests` slot for the whole session.
    private static let timeout: TimeInterval = 30

    /// Cache lives next to the other app caches, not in Application Support:
    /// losing it only costs a few Hub requests.
    private static var cacheFile: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("MelonTools", isDirectory: true)
            .appendingPathComponent("hf-avatars.json")
    }

    func avatarURL(owner: String) async -> URL? {
        let key = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let entry = liveEntry(for: key) {
            return entry.url.flatMap(URL.init(string:))
        }
        if let request = requests[key] { return await request.value }
        let request = Task<URL?, Never> {
            let outcome = await Self.fetch(key)
            return store(outcome, for: key)
        }
        requests[key] = request
        // The creator retires the slot once the wait is over; otherwise a
        // finished request would stay referenced for the rest of the session.
        defer { requests[key] = nil }
        return await request.value
    }

    /// Resolves a whole page of publishers at once so the list does not fire
    /// thirty independent lookups while scrolling.
    func prefetch(owners: some Sequence<String>) async {
        let pending = owners
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && liveEntry(for: $0) == nil && requests[$0] == nil }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for owner in Set(pending) {
                group.addTask { _ = await self.avatarURL(owner: owner) }
            }
        }
    }

    // MARK: - Disk cache

    private func liveEntry(for owner: String) -> Entry? {
        var entries = self.entries ?? loadEntries()
        guard let entry = entries[owner] else {
            self.entries = entries
            return nil
        }
        if Date().timeIntervalSince(entry.at) > Self.lifetime {
            entries[owner] = nil
            self.entries = entries
            persist(entries)
            return nil
        }
        // Touch for the LRU order in memory only: persisting on every look would
        // rewrite the file per avatar, and the next real store saves the map.
        entries[owner]?.lastUsed = Date()
        self.entries = entries
        return entry
    }

    /// Records a real answer and returns the URL the caller should use.
    @discardableResult
    private func store(_ outcome: Outcome, for owner: String) -> URL? {
        let url: String?
        switch outcome {
        case .found(let avatar):
            url = avatar.absoluteString
        case .absent:
            url = nil
        case .failed:
            // A throttled or unreachable Hub must not hide the avatar for a week.
            return nil
        }
        var entries = self.entries ?? loadEntries()
        let now = Date()
        entries[owner] = Entry(url: url, at: now, lastUsed: now)
        evictOldest(&entries, keeping: owner)
        self.entries = entries
        persist(entries)
        return url.flatMap(URL.init(string:))
    }

    /// Drops the least recently used publishers until the cache fits again.
    private func evictOldest(_ entries: inout [String: Entry], keeping owner: String) {
        let excess = entries.count - Self.maximumEntries
        guard excess > 0 else { return }
        let victims = entries
            .filter { $0.key != owner }
            .sorted { $0.value.lastActivity < $1.value.lastActivity }
        for victim in victims.prefix(excess) {
            entries[victim.key] = nil
        }
    }

    private func loadEntries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: Self.cacheFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let file = Self.cacheFile
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Hub

    private static func fetch(_ owner: String) async -> Outcome {
        var notFound = 0
        var inconclusive = false
        for type in ["organizations", "users"] {
            let url = URL(string: "https://huggingface.co/api")!
                .appendingPathComponent(type).appendingPathComponent(owner).appendingPathComponent("avatar")
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.timeout
            do {
                let (data, response) = try await NetworkProxy.session().data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    inconclusive = true
                    continue
                }
                switch http.statusCode {
                case 200:
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
                    if let value = json?["avatarUrl"], let avatar = URL(string: value), avatar.scheme == "https" {
                        return .found(avatar)
                    }
                    // A 200 without a usable URL is odd; ask again next time.
                    inconclusive = true
                case 404:
                    notFound += 1
                default:
                    // 429/5xx and anything unexpected are transient.
                    inconclusive = true
                }
            } catch {
                inconclusive = true
            }
        }
        // Only the Hub's definitive "no such publisher" may be remembered.
        return notFound == 2 && !inconclusive ? .absent : .failed
    }
}
