import Foundation
import Combine

/// Observable facade for the native plugin store.
///
/// The heavy `PluginStoreEntry` list is fetched once and filtered in memory;
/// search is local so typing never hits the gateway. A successful response is
/// cached so the Plugins page still explains itself when GitHub is down.
@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    static let melonPicks: [String] = [
        "codex-token-usage",
        "jshandler",
        "github-copilot",
        "cursor-agent",
        "deepseek-cpa",
        "model-router",
        "prompt-rules",
        "pii-filter",
    ]

    @Published private(set) var catalog: [PluginStoreEntry] = []
    @Published private(set) var installed: [PluginInstalledEntry] = []
    @Published private(set) var sources: [PluginStoreSource] = []
    @Published private(set) var sourceErrors: [PluginSourceError] = []
    @Published private(set) var isLoading = false
    @Published private(set) var installingID: String?
    @Published private(set) var removingID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var usingCache = false
    @Published private(set) var restartNeeded = false
    @Published var hostEnabled: Bool = PluginSettings.isEnabled

    private let api = PluginAPIClient()
    private var didLoad = false
    private var lastRefresh: Date?

    /// Several views are created and torn down while the user moves around the
    /// app, and each one asks for a refresh on appear. Without a floor that
    /// turns into a burst of identical store fetches. An explicit refresh after
    /// a mutation passes `force: true` and always goes out.
    private static let minimumRefreshInterval: TimeInterval = 5

    var picks: [PluginStoreEntry] {
        let byID = Dictionary(catalog.map { ($0.pluginID, $0) }, uniquingKeysWith: { first, _ in first })
        return Self.melonPicks.compactMap { byID[$0] }
    }

    var updateCount: Int {
        catalog.filter(\.updateAvailable).count
    }

    var activeCount: Int {
        installed.filter(\.effectiveEnabled).count
    }

    var pluginsDir: String {
        PluginSettings.pluginsDir.path
    }

    func installedEntry(id: String) -> PluginInstalledEntry? {
        installed.first { $0.pluginID == id }
    }

    func filtered(_ query: String, updatesOnly: Bool = false) -> [PluginStoreEntry] {
        var result = catalog
        if updatesOnly {
            result = result.filter(\.updateAvailable)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return result }
        return result.filter { entry in
            entry.displayName.lowercased().contains(trimmed)
                || entry.pluginID.lowercased().contains(trimmed)
                || entry.description.lowercased().contains(trimmed)
                || entry.author.lowercased().contains(trimmed)
                || entry.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    /// Loads the store and the installed list. A stop of the gateway is not an
    /// error worth clearing the page: cached rows stay visible and the banner
    /// tells the user why refresh did nothing.
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.minimumRefreshInterval {
            return
        }
        guard CodexGatewayService.shared.isRunning else {
            loadCache()
            // The page must say why nothing loads even when a cache hit leaves
            // `didLoad` false: otherwise Discover silently shows an empty grid.
            if lastError == nil {
                lastError = L("Start the gateway to load the plugin store.")
            }
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let endpoint = PluginEndpoint.current()
        do {
            let store = try await api.store(at: endpoint)
            catalog = Self.dedupe(store.plugins)
            sources = store.sources
            sourceErrors = store.sourceErrors
            // The engine reports the config it booted with. That value is a
            // seed for a fresh profile only: an adopted or stale gateway must
            // not flip the switch the user set here, or a restart would fight
            // the toggle on every refresh.
            if !PluginSettings.hasHostPreference {
                PluginSettings.isEnabled = store.pluginsEnabled
            }
            hostEnabled = PluginSettings.isEnabled
            usingCache = false
            lastUpdated = Date()
            didLoad = true
            // Only a successful fetch starts the quiet window. Stamping it
            // before the request made the retry button a no-op for five
            // seconds after every failure.
            lastRefresh = Date()
            saveCache(store)
        } catch {
            loadCache()
            lastError = friendly(error)
            if !didLoad { usingCache = false }
        }

        do {
            let list = try await api.installed(at: endpoint)
            installed = list.plugins
        } catch {
            if lastError == nil {
                lastError = friendly(error)
            }
        }
    }

    /// Enables or disables the native host itself. Disabling is the Safe Mode
    /// escape hatch: it rewrites the config and restarts the child so no plugin
    /// code stays loaded in process.
    func setHostEnabled(_ enabled: Bool) async {
        guard enabled != PluginSettings.isEnabled else { return }
        let previous = PluginSettings.isEnabled
        PluginSettings.isEnabled = enabled
        hostEnabled = enabled
        lastError = nil
        do {
            try CodexGatewayService.shared.writeConfig(reason: "plugin host", force: true)
            if CodexGatewayService.shared.isRunning {
                await restartGateway()
            }
            await refresh(force: true)
        } catch {
            PluginSettings.isEnabled = previous
            hostEnabled = previous
            lastError = friendly(error)
        }
    }

    func install(_ entry: PluginStoreEntry) async {
        guard installingID == nil else { return }
        if let blocker = entry.installBlocker {
            lastError = blocker
            return
        }
        installingID = entry.pluginID
        lastError = nil
        defer { installingID = nil }

        // The host must be enabled before the install route can load the new
        // library. On a fresh profile this is the first moment native code is
        // allowed, and the UI has already shown the consent sheet.
        if !PluginSettings.isEnabled {
            PluginSettings.isEnabled = true
            hostEnabled = true
            do {
                try CodexGatewayService.shared.writeConfig(reason: "first plugin install", force: true)
                if CodexGatewayService.shared.isRunning {
                    await restartGateway()
                }
            } catch {
                lastError = friendly(error)
                return
            }
        }

        do {
            let result = try await api.install(
                id: entry.pluginID,
                version: entry.version,
                sourceID: entry.sourceID,
                at: PluginEndpoint.current()
            )
            if result.restartRequired {
                await restartGateway()
            }
            await refresh(force: true)
            await PluginModelCatalog.shared.refresh()
        } catch {
            lastError = friendly(error)
        }
    }

    func remove(id: String) async {
        guard removingID == nil else { return }
        removingID = id
        lastError = nil
        defer { removingID = nil }
        do {
            try await api.remove(id: id, at: PluginEndpoint.current())
            await refresh(force: true)
            await PluginModelCatalog.shared.refresh()
        } catch {
            lastError = friendly(error)
        }
    }

    func setEnabled(id: String, enabled: Bool) async {
        lastError = nil
        do {
            try await api.setEnabled(id: id, enabled: enabled, at: PluginEndpoint.current())
            await refresh(force: true)
            await PluginModelCatalog.shared.refresh()
        } catch {
            lastError = friendly(error)
        }
    }

    func config(id: String) async throws -> [String: PluginJSON] {
        try await api.config(id: id, at: PluginEndpoint.current())
    }

    func clearError() {
        lastError = nil
    }

    func saveConfig(id: String, values: [String: PluginJSON], enabled: Bool) async throws {
        let endpoint = PluginEndpoint.current()
        try await api.saveConfig(id: id, values: values, at: endpoint)
        // PUT only persists the object. PATCH on the same plugin triggers the
        // engine's config reload, so the plugin sees the new values without a
        // full gateway restart.
        try await api.setEnabled(id: id, enabled: enabled, at: endpoint)
        await refresh(force: true)
        await PluginModelCatalog.shared.refresh()
    }

    /// The registry URL lives in the gateway config, so a change is only real
    /// after that config is written again. The official source is always
    /// prepended by the engine, so this URL is an additional source.
    func setRegistryURL(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? PluginSettings.defaultRegistryURL : trimmed
        guard value != PluginSettings.registryURL else { return }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host() != nil
        else {
            lastError = L("The registry URL must be an http or https address.")
            return
        }
        let previous = PluginSettings.registryURL
        PluginSettings.registryURL = value
        hostEnabled = PluginSettings.isEnabled
        lastError = nil
        do {
            try CodexGatewayService.shared.writeConfig(reason: "plugin registry", force: true)
            if CodexGatewayService.shared.isRunning {
                await restartGateway()
            }
            await refresh(force: true)
        } catch {
            PluginSettings.registryURL = previous
            lastError = friendly(error)
        }
    }

    func restartGatewayNow() async {
        guard CodexGatewayService.shared.isRunning else { return }
        await restartGateway()
        // The restart is the fix for an update that could not replace a loaded
        // library. Clearing the flag only after the child answered keeps the
        // banner alive when the restart failed and the ask is still valid.
        if CodexGatewayService.shared.isRunning {
            restartNeeded = false
        }
        await refresh(force: true)
        await PluginModelCatalog.shared.refresh()
    }

    // MARK: - Helpers

    private func restartGateway() async {
        let codex = CodexStore.shared
        await CodexGatewayService.shared.restart(
            accounts: codex.accounts,
            priorities: codex.effectivePriorities()
        )
    }

    private func friendly(_ error: Error) -> String {
        if let apiError = error as? PluginAPIError {
            switch apiError.code {
            case "plugin_update_requires_restart":
                restartNeeded = true
                return L("A loaded plugin cannot be replaced. Restart the gateway and retry.")
            case "plugin_install_failed":
                return L("The plugin could not be installed.") + " " + apiError.message
            case "plugin_store_source_invalid", "plugin_store_rate_limited":
                return apiError.message
            default:
                if !apiError.message.isEmpty { return apiError.message }
                return "HTTP \(apiError.status)"
            }
        }
        return error.localizedDescription
    }

    // MARK: - Cache

    private var cacheURL: URL {
        CodexGatewayService.gatewayDir.appendingPathComponent("plugin-store-cache.json")
    }

    /// The official registry is always fetched first, then custom sources. The
    /// same plugin can legitimately be listed by two registries, but one card
    /// and one install source is enough: keep the first (official) entry.
    private static func dedupe(_ entries: [PluginStoreEntry]) -> [PluginStoreEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.pluginID).inserted }
    }

    private func saveCache(_ response: PluginStoreResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? SecureFile.write(data, to: cacheURL)
    }

    private func loadCache() {
        guard let data = SecureFile.read(cacheURL),
              let response = try? JSONDecoder().decode(PluginStoreResponse.self, from: data) else {
            return
        }
        catalog = Self.dedupe(response.plugins)
        sources = response.sources
        sourceErrors = response.sourceErrors
        usingCache = true
        if !didLoad { lastUpdated = nil }
    }
}
