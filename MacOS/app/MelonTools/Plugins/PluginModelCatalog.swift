import Foundation
import Combine

/// One provider-like group of models contributed by an installed native
/// plugin. The gateway exposes plugin executors through the same `/v1/models`
/// response as account-pool models, and `owned_by` is the only stable hint the
/// app gets about which upstream produced a row.
struct PluginModelGroup: Identifiable {
    let provider: String
    let models: [SourceModel]

    var id: String { provider }
    var title: String { provider }
}

/// Discovers plugin-provided models and turns them into synthetic
/// `ModelSource` rows for the Codex picker.
///
/// These sources are never saved and never reach `api-keys`: the plugin owns
/// its executor and the gateway already routes the model. They exist only so
/// the picker and the Providers page can show the model with the right
/// provider name.
@MainActor
final class PluginModelCatalog: ObservableObject {
    static let shared = PluginModelCatalog()

    @Published private(set) var groups: [PluginModelGroup] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    var sources: [ModelSource] {
        groups.map { group in
            ModelSource(
                id: "plugin-\((group.provider.isEmpty ? "models" : group.provider).lowercased())",
                kind: .plugin,
                title: group.title,
                baseURL: "",
                apiKey: "",
                enabled: true,
                models: group.models
            )
        }
    }

    /// Rebuilds the synthetic sources from the live gateway model list.
    ///
    /// The list also contains the account pool and every configured external
    /// provider. Rows whose slug already exists in the bundled catalog or in a
    /// configured source are skipped, so the plugin band can never shadow a
    /// real provider row. Provider matching is deliberately conservative: the
    /// gateway does not expose a `plugin_id` on `/v1/models`, so only owners
    /// that look like an installed plugin are accepted.
    func refresh() async {
        guard !isRefreshing else { return }
        guard CodexGatewayService.shared.isRunning else {
            groups = []
            return
        }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        var request = URLRequest(url: URL(string: "\(CodexGatewayService.shared.baseURL)/v1/models")!)
        request.setValue("Bearer \(CodexGatewayService.shared.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        do {
            let (data, response) = try await NetworkProxy.directSession().data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = L("The gateway did not return the model list.")
                return
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = object?["data"] as? [[String: Any]] ?? []
            let aliases = await installedProviderAliases()
            guard !aliases.isEmpty else {
                groups = []
                return
            }

            let known = knownSlugs()
            var byOwner: [String: [String]] = [:]
            for row in rows {
                guard let slug = row["id"] as? String, !slug.isEmpty else { continue }
                guard !known.contains(slug) else { continue }
                let owner = (row["owned_by"] as? String ?? "").lowercased()
                guard !owner.isEmpty, aliases.contains(owner) else { continue }
                byOwner[owner, default: []].append(slug)
            }

            let built = byOwner.sorted { $0.key < $1.key }.map { owner, slugs in
                PluginModelGroup(
                    provider: owner,
                    models: slugs.sorted().map { slug in
                        SourceModel(
                            id: slug,
                            display: slug,
                            contextLength: nil,
                            enabled: true,
                            alias: slug
                        )
                    }
                )
            }
            groups = built
            if !built.isEmpty {
                ModelSourcesStore.shared.syncCatalogIfNeeded()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Owned-by names that plausibly belong to an installed plugin. A plugin
    /// id often carries a capability suffix (`cursor-agent`, `deepseek-cpa`),
    /// while the provider key is the short prefix, so both forms are accepted.
    private func installedProviderAliases() async -> Set<String> {
        var installed = PluginStore.shared.installed
        if installed.isEmpty {
            // The Plugins page may never have been opened. The alias set still
            // needs the installed manifest, not the store catalog.
            installed = (try? await PluginAPIClient().installed(at: .current()))?.plugins ?? []
        }
        var aliases = Set<String>()
        for plugin in installed {
            let id = plugin.pluginID.lowercased()
            aliases.insert(id)
            if !plugin.oauthProvider.isEmpty { aliases.insert(plugin.oauthProvider.lowercased()) }
            if !plugin.quotaProvider.isEmpty { aliases.insert(plugin.quotaProvider.lowercased()) }
            if let prefix = id.split(separator: "-").first, prefix.count >= 4 {
                aliases.insert(String(prefix))
            }
            let name = plugin.displayName.lowercased()
                .replacingOccurrences(of: " ", with: "-")
            if name.count >= 4 { aliases.insert(name) }
        }
        return aliases
    }

    private func knownSlugs() -> Set<String> {
        var known = Set<String>()
        if let base = CodexModelCatalog.baseEntries() {
            for entry in base {
                if let slug = entry["slug"] as? String { known.insert(slug) }
            }
        }
        for source in ModelSourcesStore.shared.effectiveSources {
            for model in source.models {
                known.insert(model.id)
                known.insert(model.alias)
            }
        }
        return known
    }
}
