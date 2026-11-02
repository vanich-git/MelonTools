import Combine
import Foundation

/// Multi-account Antigravity pool.
///
/// The gateway already loads every `antigravity-*.json` auth file and routes
/// across them. This store only projects that state into the UI: identity,
/// per-account models, cooldowns, the two 5-hour quota pools and the catalog
/// entries none of the connected accounts can use.
@MainActor
final class AntigravityPoolStore: ObservableObject {
    static let shared = AntigravityPoolStore()

    @Published private(set) var accounts: [AntigravityAccount] = []
    @Published private(set) var catalogOnly: [AntigravityCatalogOnlyModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    private var quotaCache: [String: CachedQuota] = [:]
    private var refreshTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private let quotaTTL: TimeInterval = 300

    struct CachedQuota {
        var fetchedAt: Date
        var gemini: AntigravityQuotaWindow?
        var claude: AntigravityQuotaWindow?
        var error: String?
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard autoTask == nil else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh(forceQuota: true)
            }
        }
    }

    func stop() {
        autoTask?.cancel()
        autoTask = nil
    }

    // MARK: - Refresh

    func refresh(forceQuota: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let files = AntigravityAuthService.authFiles()
        let management = await Self.fetchManagement()
        var next: [AntigravityAccount] = []

        for file in files {
            let entry = management[file.name]
            let models = await Self.fetchModels(name: file.name, authIndex: entry?.authIndex)
            let quota: CachedQuota?
            if !forceQuota, let cached = quotaCache[file.name], Date().timeIntervalSince(cached.fetchedAt) < quotaTTL {
                quota = cached
            } else {
                let fetched = await Self.fetchQuota(for: file)
                quotaCache[file.name] = fetched
                quota = fetched
            }
            let quotaModels = (quota?.gemini?.modelIDs ?? []) + (quota?.claude?.modelIDs ?? [])
            let accountModels = models.isEmpty ? Array(Set(quotaModels)).sorted() : models
            next.append(AntigravityAccount(
                name: file.name,
                email: file.email,
                projectID: file.projectID,
                authIndex: entry?.authIndex,
                priority: entry?.priority ?? 0,
                disabled: entry?.disabled ?? false,
                status: entry?.status,
                statusMessage: entry?.statusMessage,
                unavailable: entry?.unavailable ?? false,
                cooldowns: entry?.cooldowns ?? [],
                modelIDs: accountModels,
                geminiQuota: quota?.gemini,
                claudeQuota: quota?.claude,
                quotaError: quota?.error
            ))
        }

        next.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return (lhs.email ?? lhs.name).localizedCaseInsensitiveCompare(rhs.email ?? rhs.name) == .orderedAscending
        }
        accounts = next
        let union = Set(next.flatMap(\.modelIDs))
        catalogOnly = Self.catalogOnlyModels(entitled: union)
        lastUpdated = Date()
    }

    func refreshQuotaOnly() async {
        guard !accounts.isEmpty else { return }
        let files = Dictionary(uniqueKeysWithValues: AntigravityAuthService.authFiles().map { ($0.name, $0) })
        for index in accounts.indices {
            guard let file = files[accounts[index].name] else { continue }
            let quota = await Self.fetchQuota(for: file)
            quotaCache[file.name] = quota
            accounts[index].geminiQuota = quota.gemini
            accounts[index].claudeQuota = quota.claude
            accounts[index].quotaError = quota.error
        }
        lastUpdated = Date()
    }

    // MARK: - Account actions

    func remove(_ account: AntigravityAccount) async {
        guard AntigravityAuthService.shared.deleteAuthFile(named: account.name) else {
            lastError = L("Could not remove the account file.")
            return
        }
        quotaCache.removeValue(forKey: account.name)
        await refresh(forceQuota: true)
    }

    @discardableResult
    func setPaused(_ account: AntigravityAccount, paused: Bool) async -> Bool {
        let ok = await Self.setDisabled(name: account.name, authIndex: account.authIndex, disabled: paused)
        if ok { await refresh(forceQuota: false) } else { lastError = L("Could not change the account state.") }
        return ok
    }

    @discardableResult
    func setPriority(_ account: AntigravityAccount, priority: Int) async -> Bool {
        let ok = await Self.setPriority(name: account.name, priority: priority)
        if ok { await refresh(forceQuota: false) } else { lastError = L("Could not change the account priority.") }
        return ok
    }

    /// Lightweight health probe used for a quarantined account. A successful
    /// model-list fetch clears only the first-token cooldown; generation quota
    /// cooldowns are left to the engine.
    func probe(_ account: AntigravityAccount) async -> Bool {
        guard let file = AntigravityAuthService.authFiles().first(where: { $0.name == account.name }) else { return false }
        let ok = await Self.fetchModelsDirect(for: file)
        guard ok, let authIndex = account.authIndex else { return false }
        return await Self.clearBootstrapCooldown(authIndex: authIndex, model: account.cooldowns.first?.modelKey ?? "")
    }

    // MARK: - Management API

    struct ManagementEntry {
        var authIndex: String?
        var priority: Int
        var disabled: Bool
        var status: String?
        var statusMessage: String?
        var unavailable: Bool
        var cooldowns: [AntigravityCooldown]
    }

    private static func managementRequest(path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(CodexGatewayService.shared.port)/v0/management\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 6
        request.setValue("Bearer \(CodexGatewayService.managementSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func fetchManagement() async -> [String: ManagementEntry] {
        guard let request = managementRequest(path: "/auth-files"),
              let (data, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { return [:] }
        var result: [String: ManagementEntry] = [:]
        for raw in files {
            guard let name = raw["name"] as? String else { continue }
            result[name] = ManagementEntry(
                authIndex: raw["auth_index"] as? String,
                priority: Self.intValue(raw["priority"]) ?? 0,
                disabled: raw["disabled"] as? Bool ?? false,
                status: raw["status"] as? String,
                statusMessage: raw["status_message"] as? String,
                unavailable: raw["unavailable"] as? Bool ?? false,
                cooldowns: Self.parseCooldowns(raw["cooldowns"])
            )
        }
        return result
    }

    private static func parseCooldowns(_ raw: Any?) -> [AntigravityCooldown] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let scope = item["scope"] as? String ?? "model"
            let model = item["model_key"] as? String
            let reason = item["reason"] as? String ?? "cooldown"
            let retry = (item["retry_at"] as? String).flatMap(ISODate.parse)
            let remaining = Self.intValue(item["remaining_seconds"]) ?? 0
            let status = Self.intValue(item["http_status"])
            return AntigravityCooldown(scope: scope, modelKey: model, reason: reason, retryAt: retry, remainingSeconds: remaining, httpStatus: status)
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private static func setDisabled(name: String, authIndex: String?, disabled: Bool) async -> Bool {
        var body: [String: Any] = ["name": name, "disabled": disabled]
        if let authIndex, !authIndex.isEmpty { body["auth_index"] = authIndex }
        guard let request = managementRequest(path: "/auth-files/status", method: "PATCH", body: body),
              let (_, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    private static func setPriority(name: String, priority: Int) async -> Bool {
        let body: [String: Any] = ["name": name, "priority": priority]
        guard let request = managementRequest(path: "/auth-files/fields", method: "PATCH", body: body),
              let (_, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    private static func clearBootstrapCooldown(authIndex: String, model: String) async -> Bool {
        guard !model.isEmpty else { return false }
        let body: [String: Any] = ["auth_index": authIndex, "model": model]
        guard let request = managementRequest(path: "/routing/bootstrap-cooldown/reset", method: "POST", body: body),
              let (_, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    // MARK: - Per-account models

    private static func fetchModels(name: String, authIndex: String?) async -> [String] {
        var path = "/auth-files/models?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
        if let authIndex, !authIndex.isEmpty {
            path += "&auth_index=\(authIndex)"
        }
        guard let request = managementRequest(path: path),
              let (data, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["id"] as? String }
    }

    // MARK: - Quota

    private static func fetchQuota(for file: AntigravityAuthService.AuthFile) async -> CachedQuota {
        var token = file.accessToken
        var project = file.projectID
        if token == nil || token?.isEmpty == true {
            let reread = AntigravityAuthService.authFiles().first(where: { $0.name == file.name })
            token = reread?.accessToken
            project = reread?.projectID ?? project
        }
        guard let token, !token.isEmpty else {
            return CachedQuota(fetchedAt: Date(), gemini: nil, claude: nil, error: L("Sign in again to read the quota."))
        }
        if let quota = await requestQuota(token: token, project: project) {
            return quota
        }
        // A stale access token is the common failure; ask the engine to refresh
        // and retry once with the new file contents.
        _ = await AntigravityAuthService.shared.refreshCredential(name: file.name)
        let refreshed = AntigravityAuthService.authFiles().first(where: { $0.name == file.name })
        if let refreshedToken = refreshed?.accessToken, refreshedToken != token,
           let quota = await requestQuota(token: refreshedToken, project: refreshed?.projectID ?? project) {
            return quota
        }
        return CachedQuota(fetchedAt: Date(), gemini: nil, claude: nil, error: L("Quota is unavailable right now."))
    }

    private static func requestQuota(token: String, project: String?) async -> CachedQuota? {
        guard let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project ?? ""])
        guard let (data, response) = try? await NetworkProxy.session().data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return parseQuota(data: data)
    }

    nonisolated static func parseQuota(data: Data) -> CachedQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else { return nil }
        var geminiFraction: Double?
        var geminiReset: Date?
        var geminiModels: [String] = []
        var claudeFraction: Double?
        var claudeReset: Date?
        var claudeModels: [String] = []
        for (id, raw) in models {
            guard let entry = raw as? [String: Any],
                  let quota = entry["quotaInfo"] as? [String: Any],
                  let fraction = doubleValue(quota["remainingFraction"]) else { continue }
            let reset = (quota["resetTime"] as? String).flatMap(ISODate.parse)
            let provider = entry["modelProvider"] as? String ?? ""
            if provider == "MODEL_PROVIDER_GOOGLE" {
                geminiModels.append(id)
                geminiFraction = min(geminiFraction ?? fraction, fraction)
                if let reset { geminiReset = min(geminiReset ?? reset, reset) }
            } else {
                claudeModels.append(id)
                claudeFraction = min(claudeFraction ?? fraction, fraction)
                if let reset { claudeReset = min(claudeReset ?? reset, reset) }
            }
        }
        guard geminiFraction != nil || claudeFraction != nil else { return nil }
        return CachedQuota(
            fetchedAt: Date(),
            gemini: geminiFraction.map { AntigravityQuotaWindow(remaining: $0, resetAt: geminiReset, modelIDs: geminiModels.sorted()) },
            claude: claudeFraction.map { AntigravityQuotaWindow(remaining: $0, resetAt: claudeReset, modelIDs: claudeModels.sorted()) },
            error: nil
        )
    }

    nonisolated private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func fetchModelsDirect(for file: AntigravityAuthService.AuthFile) async -> Bool {
        guard let token = file.accessToken, !token.isEmpty,
              let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": file.projectID ?? ""])
        guard let (_, response) = try? await NetworkProxy.session().data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Catalog

    nonisolated static func catalogOnlyModels(entitled: Set<String>, catalogURL: URL = ModelCatalogOverlay.fileURL) -> [AntigravityCatalogOnlyModel] {
        guard let data = try? Data(contentsOf: catalogURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["antigravity"] as? [[String: Any]] else { return [] }
        var result: [AntigravityCatalogOnlyModel] = []
        for entry in entries {
            guard let id = entry["id"] as? String, !entitled.contains(id) else { continue }
            let display = entry["display_name"] as? String ?? id
            result.append(AntigravityCatalogOnlyModel(id: id, displayName: display))
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Models

struct AntigravityQuotaWindow: Equatable {
    var remaining: Double
    var resetAt: Date?
    var modelIDs: [String]
}

struct AntigravityCooldown: Equatable, Identifiable {
    var scope: String
    var modelKey: String?
    var reason: String
    var retryAt: Date?
    var remainingSeconds: Int
    var httpStatus: Int?

    var id: String { "\(scope)|\(modelKey ?? "")|\(retryAt?.timeIntervalSince1970 ?? 0)" }
}

struct AntigravityAccount: Identifiable, Equatable {
    var name: String
    var email: String?
    var projectID: String?
    var authIndex: String?
    var priority: Int
    var disabled: Bool
    var status: String?
    var statusMessage: String?
    var unavailable: Bool
    var cooldowns: [AntigravityCooldown]
    var modelIDs: [String]
    var geminiQuota: AntigravityQuotaWindow?
    var claudeQuota: AntigravityQuotaWindow?
    var quotaError: String?

    var id: String { name }

    var isPaused: Bool { disabled || status == "disabled" }
    var activeCooldown: AntigravityCooldown? { cooldowns.first }
}

struct AntigravityCatalogOnlyModel: Identifiable, Equatable {
    var id: String
    var displayName: String
}
