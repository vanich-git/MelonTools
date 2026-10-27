import Combine
import Foundation

/// One model of the Codex account pool as the user can select it.
struct CodexPoolModel: Identifiable, Equatable {
    var slug: String
    var display: String
    var contextLength: Int?
    var priority: Int

    var id: String { slug }
}

/// The shared pool of visible Codex models.
///
/// The pool is the bundled `BaseModelCatalog.json` `list` entries merged with
/// the visible models Codex discovered in `~/.codex/models_cache.json`. The
/// per-account selection is stored on `CodexAccount`; the union of every
/// account's selection is the common pool the Codex picker offers. There is no
/// separate global filter.
@MainActor
final class CodexPoolModelsStore: ObservableObject {
    static let shared = CodexPoolModelsStore()

    @Published private(set) var models: [CodexPoolModel] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?

    var slugs: Set<String> { Set(models.map(\.slug)) }

    init() {
        models = Self.loadModels()
    }

    /// Re-reads the bundled catalog and Codex's model cache. The picker index
    /// cache is dropped so the next read sees the new pool.
    func refresh() {
        let loaded = Self.loadModels()
        if loaded != models { models = loaded }
        CodexModelCatalog.invalidatePoolCaches()
    }

    /// Fetch the official Codex client model list, merge it into Codex's
    /// `models_cache.json`, then regenerate the pool. This is what the
    /// "Load models" button must do: reading the local cache alone can never
    /// discover a model OpenAI has just released.
    func refreshFromServer(accounts: [CodexAccount]) async {
        guard !isRefreshing else { return }
        guard let account = accounts.first(where: {
            !($0.tokens.access_token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            refreshError = L("Add a Codex account before loading models.")
            return
        }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        do {
            let result = try await CodexService.fetchModelCatalog(account: account)
            try Self.writeModelsCache(result.models)
            refresh()
        } catch {
            refreshError = L("Could not load the official model list.")
                + " " + error.localizedDescription
        }
    }

    /// Pure merge used by the writer and tests. Codex owns the cache metadata,
    /// so keep `identity` and `etag` intact and replace only the model list.
    nonisolated static func mergedCacheObject(
        existing: [String: Any]?,
        models: [[String: Any]],
        fetchedAt: Date = Date()
    ) -> [String: Any] {
        var object = existing ?? [:]
        object["models"] = models
        object["fetched_at"] = ISO8601DateFormatter().string(from: fetchedAt)
        object["client_version"] = CodexService.modelsClientVersion
        return object
    }

    private static func writeModelsCache(_ models: [[String: Any]]) throws {
        let directory = CodexModelCatalog.directory
        let url = URL(fileURLWithPath: directory).appendingPathComponent("models_cache.json")
        let existing: [String: Any]? = {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }()
        let object = mergedCacheObject(existing: existing, models: models)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try SecureFile.write(data, to: url)
    }

    // MARK: - Loading

    /// Visible pool models, ordered by picker priority.
    nonisolated static func loadModels() -> [CodexPoolModel] {
        CodexModelCatalog.mergedPoolEntries().compactMap(model(from:)).sorted {
            ($0.priority, $0.display.lowercased(), $0.slug)
                < ($1.priority, $1.display.lowercased(), $1.slug)
        }
    }

    nonisolated static func model(from entry: [String: Any]) -> CodexPoolModel? {
        guard let slug = entry["slug"] as? String, !slug.isEmpty else { return nil }
        return CodexPoolModel(
            slug: slug,
            display: entry["display_name"] as? String ?? slug,
            contextLength: intValue(entry["context_window"]),
            priority: intValue(entry["priority"]) ?? 50
        )
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }

    // MARK: - Selection helpers

    /// Pool models the account may route. `nil` selection means the whole
    /// visible pool (legacy vaults). Explicit slugs outside the pool are
    /// ignored — they cannot appear in the picker anyway.
    nonisolated static func effectiveSelection(
        for account: CodexAccount,
        poolSlugs: Set<String>
    ) -> Set<String> {
        guard let selected = account.selectedModels else { return poolSlugs }
        return poolSlugs.intersection(selected)
    }

    /// Union of every account's effective selection: the common picker pool.
    /// No accounts keeps the baseline (every visible model). An empty union
    /// (all explicit lists point at models that no longer exist) also falls
    /// back to the full pool so the picker cannot become unusable.
    nonisolated static func unionSelection(
        accounts: [CodexAccount],
        poolSlugs: Set<String>
    ) -> Set<String> {
        guard !accounts.isEmpty else { return poolSlugs }
        var union: Set<String> = []
        for account in accounts {
            union.formUnion(effectiveSelection(for: account, poolSlugs: poolSlugs))
        }
        return union.isEmpty ? poolSlugs : union
    }

    /// Visible pool slugs the account must not receive from the gateway.
    nonisolated static func excludedSlugs(
        for account: CodexAccount,
        poolSlugs: Set<String>
    ) -> Set<String> {
        poolSlugs.subtracting(effectiveSelection(for: account, poolSlugs: poolSlugs))
    }

    /// Valid account selection for a UI edit: unknown slugs are dropped and
    /// an empty result is rejected (`nil`) — an account needs one model.
    nonisolated static func validatedSelection(
        _ selected: Set<String>,
        poolSlugs: Set<String>
    ) -> Set<String>? {
        let valid = poolSlugs.intersection(selected)
        return valid.isEmpty ? nil : valid
    }

    // MARK: - Global toggle

    /// Result of turning one pool model on or off for every account.
    struct PoolTogglePlan: Equatable {
        /// Account id → new explicit selection.
        var selections: [String: Set<String>] = [:]
        /// Display names that would be left with no model. Non-empty means the
        /// whole operation must be rejected.
        var emptyAccounts: [String] = []
    }

    /// Computes the explicit selections a global enable/disable would write.
    /// Every account is materialized (an account with `nil` becomes the full
    /// pool minus the disabled slug), so a later “Load models” run cannot
    /// silently re-add what the user just turned off.
    nonisolated static func poolTogglePlan(
        slug: String,
        enabled: Bool,
        accounts: [CodexAccount],
        poolSlugs: Set<String>
    ) -> PoolTogglePlan {
        var plan = PoolTogglePlan()
        for account in accounts {
            var selection = effectiveSelection(for: account, poolSlugs: poolSlugs)
            if enabled {
                selection.insert(slug)
            } else {
                selection.remove(slug)
            }
            plan.selections[account.id] = selection
            if selection.isEmpty {
                plan.emptyAccounts.append(account.displayName)
            }
        }
        return plan
    }
}
