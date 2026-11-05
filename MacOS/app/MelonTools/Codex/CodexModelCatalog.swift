import Foundation

/// Builds `~/.codex/melon-model-catalog.json` — the file the Codex app reads
/// through the `model_catalog_json` key in `~/.codex/config.toml` to fill its
/// model picker.
///
/// The base list (account-pool models) comes from the catalog a local route
/// owner produced, or from the copy bundled with the app. Every selected
/// source model is added as a clone of a reference entry with its own slug,
/// display name, context window and conservative capability flags.
@MainActor
enum CodexModelCatalog {
    static let fileName = "melon-model-catalog.json"

    /// Prompt and policy fields are delivered by model catalogs, but they may
    /// contain client-private instructions. Never bundle or forward them to
    /// third-party model providers when building a local catalog.
    private static let privateMetadataKeys: Set<String> = [
        "base_instructions",
        "model_messages",
        "policy",
        "policy_template",
        "node_repl_policy",
        "rejection_instructions",
        "timeout_instructions",
        "instructions_variables"
    ]

    nonisolated static func sanitizedEntries(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.map { sanitizeMetadata(in: $0) as? [String: Any] ?? [:] }
    }

    private nonisolated static func sanitizeMetadata(in value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                guard !privateMetadataKeys.contains(pair.key) else { return }
                result[pair.key] = sanitizeMetadata(in: pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map { sanitizeMetadata(in: $0) }
        }
        return value
    }

    nonisolated static var directory: String {
        (CodexGatewayService.codexConfigPath as NSString).deletingLastPathComponent
    }

    nonisolated static var targetPath: String {
        (directory as NSString).appendingPathComponent(fileName)
    }

    enum CatalogError: LocalizedError {
        case baseMissing
        var errorDescription: String? {
            switch self {
            case .baseMissing: return "Model catalog base is missing."
            }
        }
    }

    /// Regenerates the catalog. Returns the number of custom models written.
    /// The config reference is only rewritten when the caller owns the Codex
    /// route; a launch-time sync must not steal another tool’s route.
    ///
    /// `selectedPoolSlugs` is the union of the per-account selections. Only
    /// those visible pool models reach the picker; hidden entries always stay.
    /// `nil` keeps the legacy behavior (every visible pool model).
    @discardableResult
    static func sync(
        sources: [ModelSource],
        updateConfig: Bool = true,
        selectedPoolSlugs: Set<String>? = nil
    ) throws -> Int {
        guard let base = loadBaseEntries() else { throw CatalogError.baseMissing }
        // Visible pool models: bundled/base `list` entries plus visible
        // cache-only entries Codex discovered itself. Hidden base entries are
        // appended unchanged — they are internal routes, never selectable.
        // Hidden cache-only rows are internal routes too, so they stay as well,
        // unless the base already owns that slug.
        let cache = cacheEntries()
        var entries = mergedPoolEntries(base: base, cache: cache)
        entries.append(contentsOf: hiddenBaseEntries(in: base))
        let knownSlugs = Set(entries.compactMap { $0["slug"] as? String })
        entries.append(contentsOf: hiddenCacheEntries(in: cache, excluding: knownSlugs))
        let (result, custom) = generatedEntries(
            base: entries,
            sources: sources,
            defaults: SchemaDefaults.load(),
            selectedPoolSlugs: selectedPoolSlugs
        )
        let payload: [String: Any] = ["models": result]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try SecureFile.write(data, to: URL(fileURLWithPath: targetPath))
        if updateConfig {
            try ensureConfigReference()
        }
        return custom
    }

    /// Appends the selected source models to the sanitized base list and gives
    /// every final entry the fields current Codex requires. Internal so tests
    /// can drive generation with a fixture base and a fixture cache.
    ///
    /// `selectedPoolSlugs` filters visible base entries at the final output;
    /// hidden entries stay, and the full base still provides the template and
    /// the pool-slug shadow protection (an unselected pool slug must never be
    /// taken over by a third-party provider).
    static func generatedEntries(
        base entries: [[String: Any]],
        sources: [ModelSource],
        defaults: SchemaDefaults?,
        selectedPoolSlugs: Set<String>? = nil
    ) -> (entries: [[String: Any]], custom: Int) {
        guard let template = referenceEntry(in: entries) else {
            return (applyRequiredSchema(to: filteredPoolEntries(entries, selected: selectedPoolSlugs), defaults: defaults), 0)
        }
        var pending: [(entry: [String: Any], display: String, provider: String)] = []
        // Every pool slug reserves its name, selected or not.
        let poolSlugs = Set(entries.compactMap { $0["slug"] as? String })
        for source in sources where source.enabled {
            for (position, model) in source.selectedModels.enumerated() {
                // Never shadow an account-pool model.
                if poolSlugs.contains(model.alias) { continue }
                if var entry = makeEntry(from: template, model: model, source: source) {
                    // The Codex picker sorts its list by `priority`, so one
                    // band per provider keeps the models grouped in the menu
                    // (pool → OpenCode → OpenRouter → DeepInfra → Vercel → Z.ai →
                    // Claude → Antigravity). Cap the per-provider index so a
                    // large list cannot spill into the next band.
                    entry["priority"] = priorityBase(for: source.kind) + min(position, 99)
                    pending.append((
                        entry: entry,
                        display: entry["display_name"] as? String ?? model.alias,
                        provider: source.title
                    ))
                }
            }
        }

        let visible = filteredPoolEntries(entries, selected: selectedPoolSlugs)

        // The Codex picker keys rows by display name. When the same model is
        // offered by two providers (for example Gemini 3.5 Flash Lite from
        // OpenCode and Antigravity), identical names collapse into one row and
        // the surviving provider steals the other provider's slot. Keep both
        // rows by qualifying only the colliding names with the provider.
        var displayCounts: [String: Int] = [:]
        for entry in visible {
            guard let name = entry["display_name"] as? String else { continue }
            displayCounts[name.lowercased(), default: 0] += 1
        }
        for item in pending {
            displayCounts[item.display.lowercased(), default: 0] += 1
        }
        var result = visible
        for item in pending {
            var entry = item.entry
            if displayCounts[item.display.lowercased(), default: 0] > 1 {
                entry["display_name"] = Self.disambiguatedDisplayName(
                    item.display,
                    provider: item.provider
                )
            }
            result.append(entry)
        }
        return (applyRequiredSchema(to: result, defaults: defaults), pending.count)
    }

    /// Keeps hidden entries and drops visible entries the account union does
    /// not select. Entries without a slug stay: they cannot be filtered safely.
    nonisolated static func filteredPoolEntries(
        _ entries: [[String: Any]],
        selected: Set<String>?
    ) -> [[String: Any]] {
        guard let selected else { return entries }
        return entries.filter { entry in
            guard isVisiblePoolEntry(entry), let slug = entry["slug"] as? String else { return true }
            return selected.contains(slug)
        }
    }

    /// The picker's deduplication key is the display name, so a shared model
    /// needs a provider suffix to stay visible in both provider sections.
    nonisolated static func disambiguatedDisplayName(_ display: String, provider: String) -> String {
        "\(display) (\(provider))"
    }

    // MARK: - Required schema fields

    /// Instructions and tool lists that current Codex requires in every
    /// entry. They are read from Codex's local cache at generation time, so
    /// prompt text never lives in this repository.
    struct SchemaDefaults {
        var bySlug: [String: [String: Any]]
        var template: [String: Any]?

        static func decode(_ data: Data) -> SchemaDefaults? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [[String: Any]], !models.isEmpty else { return nil }
            var bySlug: [String: [String: Any]] = [:]
            for entry in models {
                guard let slug = entry["slug"] as? String else { continue }
                bySlug[slug] = entry
            }
            return SchemaDefaults(bySlug: bySlug, template: bySlug["gpt-6.1-sol"] ?? models.first)
        }

        /// `~/.codex/models_cache.json` — written by Codex itself.
        @MainActor
        static func load() -> SchemaDefaults? {
            let url = URL(fileURLWithPath: (directory as NSString).appendingPathComponent("models_cache.json"))
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
    }

    static let fallbackInstructions = "You are Codex, a coding agent. Follow the user's instructions and use the available tools."
    static let fallbackTools = ["send_user_message_async", "clock"]

    /// Fills the fields Codex validates for every entry. The bundled base
    /// catalog stores no prompt text, so both instructions and tools are
    /// added here, after sanitization, from the local Codex cache.
    static func applyRequiredSchema(
        to entries: [[String: Any]],
        defaults: SchemaDefaults?
    ) -> [[String: Any]] {
        entries.map { entry in
            var output = entry
            let slug = entry["slug"] as? String
            if !hasInstructions(output) {
                let candidates = [slug.flatMap { defaults?.bySlug[$0] }, defaults?.template].compactMap { $0 }
                for source in candidates {
                    if let payload = instructions(from: source) {
                        output[payload.key] = payload.value
                        break
                    }
                }
            }
            if !hasInstructions(output) {
                output["base_instructions"] = fallbackInstructions
            }
            let currentTools = output["experimental_supported_tools"] as? [String]
            if currentTools == nil || currentTools?.isEmpty == true {
                let templateTools = defaults?.template?["experimental_supported_tools"] as? [String]
                if let templateTools, !templateTools.isEmpty {
                    output["experimental_supported_tools"] = templateTools
                } else {
                    output["experimental_supported_tools"] = fallbackTools
                }
            }
            return output
        }
    }

    private static func hasInstructions(_ entry: [String: Any]) -> Bool {
        instructions(from: entry) != nil
    }

    /// `model_messages.instructions_template` is the preferred form; a plain
    /// `base_instructions` string is the fallback. Empty values do not count.
    private static func instructions(from entry: [String: Any]) -> (key: String, value: Any)? {
        if let messages = entry["model_messages"] as? [String: Any],
           let template = messages["instructions_template"] as? String,
           !template.isEmpty {
            return ("model_messages", messages)
        }
        if let base = entry["base_instructions"] as? String, !base.isEmpty {
            return ("base_instructions", base)
        }
        return nil
    }

    /// Points `model_catalog_json` at our file (top-level key).
    static func ensureConfigReference() throws {
        let path = CodexGatewayService.codexConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = CodexConfigRoute.upsertTopLevelKey("model_catalog_json", value: fileName, in: text)
        guard updated != text else { return }
        try SecureFile.write(updated, to: URL(fileURLWithPath: path))
    }

    /// Slugs the catalog currently lists for the third-party sources
    /// (`openrouter/…`, `opencode/…`, slash-less `claude-*`). Used to detect a
    /// stale file at launch.
    static func thirdPartySlugs() -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return Set(models.compactMap { $0["slug"] as? String }.filter { isThirdPartySlug($0) })
    }

    /// Third-party slugs: namespaced ids (`openrouter/…`, `opencode/…`),
    /// slash-less Claude ids (`claude-*`), and the slash-less Antigravity ids
    /// (`gemini-*`, `gpt-oss-*`, …). The account pool never uses those.
    nonisolated static func isThirdPartySlug(_ slug: String) -> Bool {
        slug.contains("/")
            || slug.hasPrefix("claude-")
            || AntigravityModelRegistry.ids.contains(slug)
    }

    // MARK: - Provider bands

    /// Priority band per provider kind. The base catalog uses 0…8 for the
    /// account-pool models (1000 = hidden), so third-party models start above
    /// that and keep the picker grouped.
    static func priorityBase(for kind: ModelSource.Kind) -> Int {
        switch kind {
        case .openCode: return 100
        case .openRouter: return 200
        case .deepInfra: return 300
        case .vercel: return 400
        case .zai: return 500
        case .commandCode: return 550
        case .claude: return 600
        case .antigravity: return 700
        case .localAI: return 800
        }
    }

    /// Provider tag used by the composer bridge and the picker grouping.
    static func providerTag(for kind: ModelSource.Kind) -> String {
        switch kind {
        case .openCode: return "opencode"
        case .openRouter: return "openrouter"
        case .deepInfra: return "deepinfra"
        case .vercel: return "vercel"
        case .zai: return "zai"
        case .commandCode: return "commandcode"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .localAI: return "Local AI"
        }
    }

    // MARK: - Picker index

    /// One picker row: the display name the Codex app shows, the provider it
    /// belongs to and the slug the gateway routes on.
    struct PickerModel: Equatable {
        var name: String
        var provider: String
        var slug: String
    }

    /// Pool names from the merged visible pool (cached — the files rarely
    /// change). Every pool slug stays known here, even when the account union
    /// hides the row, so price attribution still recognizes pool models.
    private static var cachedBaseNames: [PickerModel]?

    /// Everything the picker may show, before the account union is applied.
    static func basePickerModels() -> [PickerModel] {
        if let cachedBaseNames { return cachedBaseNames }
        let list: [PickerModel] = mergedPoolEntries().compactMap { entry in
            guard let slug = entry["slug"] as? String else { return nil }
            return PickerModel(
                name: entry["display_name"] as? String ?? slug,
                provider: "openai",
                slug: slug
            )
        }
        cachedBaseNames = list
        return list
    }

    /// Pool rows the account union allows. `nil` keeps every visible row.
    static func basePickerModels(selectedPoolSlugs: Set<String>?) -> [PickerModel] {
        let all = basePickerModels()
        guard let selectedPoolSlugs else { return all }
        return all.filter { selectedPoolSlugs.contains($0.slug) }
    }

    /// Drops the pool caches after `~/.codex/models_cache.json` or the bundled
    /// catalog changed.
    static func invalidatePoolCaches() {
        cachedBaseNames = nil
    }

    /// Every model the picker can show, with its provider. Names must match
    /// the generated catalog, including provider suffixes for shared models;
    /// otherwise the composer cannot tell which provider row is selected.
    ///
    /// `selectedPoolSlugs` is the union of the account selections: pool rows
    /// outside it are omitted exactly like the generated catalog does.
    static func pickerIndex(
        sources: [ModelSource],
        selectedPoolSlugs: Set<String>? = nil
    ) -> [PickerModel] {
        let base = basePickerModels(selectedPoolSlugs: selectedPoolSlugs)
        var pending: [(display: String, provider: String, title: String, slug: String)] = []
        for source in sources where source.enabled {
            for model in source.selectedModels {
                pending.append((
                    display: model.display.isEmpty ? model.alias : model.display,
                    provider: providerTag(for: source.kind),
                    title: source.title,
                    slug: model.alias
                ))
            }
        }
        var counts: [String: Int] = [:]
        for entry in base {
            counts[entry.name.lowercased(), default: 0] += 1
        }
        for entry in pending {
            counts[entry.display.lowercased(), default: 0] += 1
        }
        var list = base
        for entry in pending {
            let name = counts[entry.display.lowercased(), default: 0] > 1
                ? disambiguatedDisplayName(entry.display, provider: entry.title)
                : entry.display
            list.append(PickerModel(name: name, provider: entry.provider, slug: entry.slug))
        }
        return list
    }

    // MARK: - Pool entries

    /// Bundled/base catalog entries, sanitized. `nonisolated` so the gateway
    /// can snapshot the pool from a background-safe call path.
    nonisolated static func baseEntries() -> [[String: Any]]? {
        loadBaseEntries()
    }

    /// `~/.codex/models_cache.json` entries written by Codex itself.
    nonisolated static func cacheEntries() -> [[String: Any]] {
        let url = URL(fileURLWithPath: (directory as NSString).appendingPathComponent("models_cache.json"))
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return sanitizedEntries(models)
    }

    /// A catalog entry the Codex picker may list and the user may select.
    /// Missing `visibility` means `list` (the schema default).
    nonisolated static func isVisiblePoolEntry(_ entry: [String: Any]) -> Bool {
        (entry["visibility"] as? String ?? "list") == "list"
    }

    /// Merged visible pool: base `list` entries first (bundled wins on a
    /// duplicate slug), then visible cache-only entries Codex discovered.
    /// Hidden entries never appear here.
    nonisolated static func mergedPoolEntries(
        base: [[String: Any]]? = nil,
        cache: [[String: Any]]? = nil
    ) -> [[String: Any]] {
        let baseEntries = base ?? loadBaseEntries() ?? []
        let cacheEntries = cache ?? self.cacheEntries()
        var result: [[String: Any]] = []
        var seen: Set<String> = []
        for entry in baseEntries + cacheEntries {
            guard isVisiblePoolEntry(entry),
                  let slug = entry["slug"] as? String, !slug.isEmpty,
                  !seen.contains(slug) else { continue }
            seen.insert(slug)
            result.append(entry)
        }
        return result
    }

    /// Internal rows (`visibility != "list"`) stay in the generated catalog so
    /// Codex keeps its hidden routes, but they are never offered as choices.
    nonisolated static func hiddenBaseEntries(in entries: [[String: Any]]) -> [[String: Any]] {
        entries.filter { !isVisiblePoolEntry($0) }
    }

    /// Hidden rows that exist only in Codex's cache are internal routes too.
    /// `knownSlugs` already holds every slug in the output, so a bundled base
    /// entry stays authoritative on a shared slug and duplicates collapse.
    nonisolated static func hiddenCacheEntries(
        in cache: [[String: Any]],
        excluding knownSlugs: Set<String>
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seen: Set<String> = []
        for entry in cache {
            guard !isVisiblePoolEntry(entry),
                  let slug = entry["slug"] as? String, !slug.isEmpty,
                  !knownSlugs.contains(slug), !seen.contains(slug) else { continue }
            seen.insert(slug)
            result.append(entry)
        }
        return result
    }

    /// Visible pool slugs read from disk. The gateway uses this default when a
    /// caller does not pass the live union.
    nonisolated static func visiblePoolSnapshot() -> Set<String> {
        Set(mergedPoolEntries().compactMap { $0["slug"] as? String })
    }

    // MARK: - Base catalog

    nonisolated private static func loadBaseEntries() -> [[String: Any]]? {
        let fm = FileManager.default
        var candidates: [URL] = []
        // A catalog written by another local route owner (freshest first).
        let owned = (directory as NSString).appendingPathComponent("cockpit-model-catalog.json")
        if fm.fileExists(atPath: owned) {
            candidates.append(URL(fileURLWithPath: owned))
        }
        // Shipped copy — always present in the app bundle.
        if let bundled = Bundle.main.url(forResource: "BaseModelCatalog", withExtension: "json") {
            candidates.append(bundled)
        }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = root["models"] as? [[String: Any]], !models.isEmpty {
                return sanitizedEntries(models)
            }
        }
        return nil
    }

    /// Preferred template slugs: a balanced model without speed tiers quirks.
    private static var templatePreference: [String] {
        ["gpt-5.6-luna", "gpt-6-luna", "gpt-5.6-terra", "gpt-5.5", "gpt-6-sol", "gpt-6.1-sol"]
    }

    private static func referenceEntry(in entries: [[String: Any]]) -> [String: Any]? {
        for slug in templatePreference {
            if let entry = entries.first(where: { ($0["slug"] as? String) == slug }) {
                return entry
            }
        }
        return entries.first
    }

    // MARK: - Custom entries

    static func makeEntry(from template: [String: Any], model: SourceModel, source: ModelSource) -> [String: Any]? {
        guard !model.alias.isEmpty else { return nil }
        var entry = template
        // No fabricated floor: a 2048-token local model advertised as 8000 made
        // Codex build prompts the engine then truncated, and the auto-compact
        // threshold was off by the same factor. `contextLength` on the source
        // model is already the **per-slot** window.
        let templateContext = template["context_window"] as? Int ?? 128_000
        let context = max(1, model.contextLength ?? templateContext)

        entry["slug"] = model.alias
        let display = model.display.isEmpty ? model.alias : model.display
        entry["display_name"] = display
        entry["description"] = "\(display) · \(source.title)"
        entry["context_window"] = context
        entry["max_context_window"] = context
        entry["auto_compact_token_limit"] = max(1, Int(Double(context) * 0.85))
        entry["effective_context_window_percent"] = 95

        // Third-party upstreams do not implement OpenAI speed tiers or hosted
        // search, and the Codex app must not offer those switches for them.
        entry["additional_speed_tiers"] = []
        entry["service_tiers"] = []
        entry["default_service_tier"] = NSNull()
        entry["supported_in_api"] = true
        entry["visibility"] = "list"
        entry["prefer_websockets"] = false
        entry["use_responses_lite"] = false
        entry["supports_search_tool"] = false
        // The template usually advertises text+image; a provider model must
        // carry only the modalities its upstream actually accepts. Unknown
        // (`nil`, old stores) stays text-only until the user toggles it.
        let supportsImages = model.supportsImages ?? false
        entry["input_modalities"] = supportsImages ? ["text", "image"] : ["text"]
        entry["supports_image_detail_original"] = false
        return entry
    }
}
