import Foundation

/// Completes the engine's general model catalog for Antigravity.
///
/// The engine ships one Antigravity entry per model family — `gemini-3.8-flash-high`
/// stands for all 3.8 Flash thinking levels. Google exposes a separate id for
/// each level and for Gemini 2.5 Pro, so those ids never pass the engine's
/// catalog ∩ account intersection and never reach `/v1/models`.
///
/// The app fetches the same official catalog the engine would fetch, adds the
/// missing Antigravity definitions, validates the result and writes it next to
/// the gateway config. `config.yaml` then points `models.catalog` at the file,
/// so the fix survives restarts and settings saves.
///
/// Merge and validation are `nonisolated` and take plain JSON values: tests
/// exercise them without touching the network or the live gateway.
enum ModelCatalogOverlay {
    /// Same sources, in the same order, as the engine's own catalog updater.
    static let officialURLs = [
        "https://raw.githubusercontent.com/router-for-me/models/refs/heads/main/models.json",
        "https://models.router-for.me/models.json",
    ]

    /// Sections the engine validates. A candidate missing one would replace
    /// the whole catalog and empty the affected providers.
    static let requiredSections = [
        "claude", "gemini", "vertex", "aistudio", "codex-free", "codex-team",
        "codex-plus", "codex-pro", "kimi", "antigravity", "xai", "meta",
    ]

    /// The engine re-reads its catalog source on this cadence; the overlay
    /// follows it so the file never lags behind the official one.
    static let refreshInterval: TimeInterval = 3 * 60 * 60
    /// A failed fetch is retried on this cadence, not on every health tick.
    static let retryInterval: TimeInterval = 15 * 60

    struct ExtraModel {
        let id: String
        let display: String
        /// Existing catalog entry to clone.
        let templateID: String
        let templateSection: String
    }

    /// Antigravity ids that are missing from the official catalog but are
    /// real, entitled models in the account catalog.
    static let extraModels = [
        ExtraModel(id: "gemini-3.8-flash-low",
                   display: "Gemini 3.8 Flash (Low)",
                   templateID: "gemini-3.8-flash-high",
                   templateSection: "antigravity"),
        ExtraModel(id: "gemini-3.8-flash-medium",
                   display: "Gemini 3.8 Flash (Medium)",
                   templateID: "gemini-3.8-flash-high",
                   templateSection: "antigravity"),
        ExtraModel(id: "gemini-2.5-pro",
                   display: "Gemini 2.5 Pro",
                   templateID: "gemini-2.5-pro",
                   templateSection: "gemini"),
    ]

    /// `gateway/models.json` next to the engine config.
    nonisolated static var fileURL: URL {
        CodexStore.supportDir
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("models.json")
    }

    /// Top-level YAML block for `config.yaml`; empty when the overlay is not
    /// on disk, so the engine keeps its own catalog.
    nonisolated static func gatewayYAML(catalogPath: String? = nil) -> String {
        let path = catalogPath ?? fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        // Leading newline: `writeConfig` appends this to a multiline literal
        // whose last line has no trailing newline, so without it `models:`
        // would glue onto the `proxy-url` line and break the YAML.
        return "\nmodels:\n  catalog: \"\(ModelSourcesStore.yamlEscape(path))\"\n"
    }

    // MARK: - Pure catalog work

    /// Dedupes every model array, then appends the extra Antigravity entries.
    ///
    /// Deduplication comes first: one duplicate id makes the engine reject the
    /// whole catalog, and the official catalog is the only source that can
    /// introduce one.
    nonisolated static func merge(_ catalog: [String: Any]) -> [String: Any] {
        var merged = catalog
        for key in Array(merged.keys) {
            guard let models = merged[key] as? [[String: Any]] else { continue }
            merged[key] = deduplicated(models)
        }

        var antigravity = (merged["antigravity"] as? [[String: Any]]) ?? []
        var known = Set(antigravity.compactMap { $0["id"] as? String })
        for extra in extras(in: merged) {
            guard let id = extra["id"] as? String, !known.contains(id) else { continue }
            antigravity.append(extra)
            known.insert(id)
        }
        merged["antigravity"] = antigravity
        return merged
    }

    /// Mirrors the engine's `validateModelSection`: required sections must be
    /// arrays of objects with non-empty, unique ids.
    nonisolated static func validate(_ catalog: [String: Any]) -> String? {
        for section in requiredSections {
            guard let raw = catalog[section] else { return "missing section \(section)" }
            guard let models = raw as? [[String: Any]] else {
                return "section \(section) is not a model array"
            }
            var seen = Set<String>()
            for (index, model) in models.enumerated() {
                let id = (model["id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty else { return "\(section)[\(index)] has an empty id" }
                guard seen.insert(id).inserted else {
                    return "\(section) contains duplicate id \(id)"
                }
            }
        }
        return nil
    }

    nonisolated static func decodedCatalog(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func encodedCatalog(_ catalog: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }

    /// Clones a template entry and rewrites the identity fields.
    private nonisolated static func extras(in catalog: [String: Any]) -> [[String: Any]] {
        extraModels.compactMap { extra in
            let section = (catalog[extra.templateSection] as? [[String: Any]]) ?? []
            guard var entry = section.first(where: { $0["id"] as? String == extra.templateID }) else {
                return nil
            }
            entry["id"] = extra.id
            entry["name"] = extra.id
            entry["display_name"] = extra.display
            entry["description"] = extra.display
            if extra.templateSection != "antigravity" {
                entry["owned_by"] = "antigravity"
                entry["type"] = "antigravity"
                // Gemini-section entries carry the window as inputTokenLimit;
                // mirror it in the flat keys `/v1/models` consumers read.
                if let input = entry["inputTokenLimit"] as? Int {
                    entry["context_length"] = input
                }
                if let output = entry["outputTokenLimit"] as? Int {
                    entry["max_completion_tokens"] = output
                }
            }
            return entry
        }
    }

    private nonisolated static func deduplicated(_ models: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        return models.filter { model in
            let id = (model["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return false }
            return seen.insert(id).inserted
        }
    }

    // MARK: - Refresh

    /// Whether the overlay is missing or older than the refresh cadence.
    nonisolated static func needsRefresh(now: Date = Date(), path: String? = nil) -> Bool {
        let target = path ?? fileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(modified) >= refreshInterval
    }

    @MainActor private static var isRefreshing = false
    @MainActor private static var lastAttempt: Date?

    /// Refreshes the overlay when it is missing or stale.
    ///
    /// Returns `true` when a new file was written. `timeout` bounds the whole
    /// operation so gateway startup never waits on an unreachable host.
    @MainActor
    @discardableResult
    static func refreshIfNeeded(force: Bool = false, timeout: TimeInterval = 20) async -> Bool {
        guard !AppRuntime.isTesting else { return false }
        guard !isRefreshing else { return false }
        if !force {
            guard needsRefresh() else { return false }
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < retryInterval {
                return false
            }
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let updated = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await performRefresh() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        lastAttempt = updated ? nil : Date()
        return updated
    }

    private nonisolated static func performRefresh() async -> Bool {
        guard let data = await fetchCatalog(),
              let root = decodedCatalog(data) else { return false }
        let merged = merge(root)
        guard validate(merged) == nil,
              let encoded = encodedCatalog(merged) else { return false }
        guard !Task.isCancelled else { return false }
        do {
            try SecureFile.write(encoded, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func fetchCatalog() async -> Data? {
        for candidate in officialURLs {
            guard let url = URL(string: candidate), !Task.isCancelled else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("MelonTools/1.4", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await NetworkProxy.session().data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty else { continue }
                return data
            } catch {
                continue
            }
        }
        return nil
    }
}
