import Combine
import Foundation

/// Multi-account Antigravity pool.
///
/// The gateway already loads every `antigravity-*.json` auth file and routes
/// across them. This store only projects that state into the UI: identity,
/// per-account models, cooldowns, the two 5-hour quota pools and the catalog
/// entries none of the connected accounts can use.
/// The one place the Antigravity client identity is defined for the app process.
///
/// Google compares the advertised client against the real one, so the version and
/// the changelist must stay a matched pair taken from the official build. The pair
/// is calibrated, not discovered: the app never auto-bumps the version, because a
/// version without its changelist is a stronger tell than an older version.
enum AntigravityClientIdentity {
    /// Official Hub release this build impersonates.
    static let version = "2.28.0"
    /// Changelist that ships with that release.
    static let changeList = "1008300195"
    /// Platform segment, matching the process architecture.
    static var platform: String {
        #if arch(arm64)
        "os_type=darwin; arch=arm64"
        #else
        "os_type=darwin; arch=x86_64"
        #endif
    }
    /// Full User-Agent for calls made from the app itself.
    static var userAgent: String {
        "antigravity/hub/\(version) (aidev_client; \(platform); cl=\(changeList))"
    }
}

@MainActor
final class AntigravityPoolStore: ObservableObject {
    static let shared = AntigravityPoolStore()

    @Published private(set) var accounts: [AntigravityAccount] = []
    @Published private(set) var catalogOnly: [AntigravityCatalogOnlyModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var warmingUpAccountNames: Set<String> = []
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
                // The 5-hour windows only change while requests are running, so
                // an idle gateway does not need a Google round trip every five
                // minutes: poll fast under load and slowly when nothing uses the
                // pool. This mirrors the Windows quota loop and avoids both
                // battery drain and upstream 429s on the quota endpoint.
                let busy = CodexGatewayService.shared.requestsLastMinute > 0
                let seconds: UInt64 = busy ? 60 : 900
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if Task.isCancelled { return }
                // Never force the quota round trip here. A forced refresh ignores the
                // per-account TTL, so the tick rate would silently become the upstream
                // poll rate: one fetchAvailableModels per account per minute, forever.
                // The quota windows only move when a request actually runs, and
                // quotaTTL already shortens the wait under load.
                await self?.refresh(forceQuota: false)
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
            let disabled = entry?.disabled ?? false
            // A disabled account is disabled on purpose: blocked upstream, paused by
            // the operator, or awaiting re-authentication. Probing it still spends a
            // request on a credential Google already refuses, so render the stored
            // management state and touch no upstream endpoint for it.
            let models = disabled ? [] : await Self.fetchModels(name: file.name, authIndex: entry?.authIndex)
            let quota: CachedQuota?
            if disabled {
                quota = quotaCache[file.name]
            } else if !forceQuota, let cached = quotaCache[file.name], Date().timeIntervalSince(cached.fetchedAt) < quotaTTL {
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
                disabled: disabled,
                status: entry?.status,
                statusMessage: entry?.statusMessage,
                unavailable: entry?.unavailable ?? false,
                cooldowns: entry?.cooldowns ?? [],
                modelIDs: accountModels,
                proxyURL: file.proxyURL,
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
    /// model-list fetch clears every first-token cooldown of the account;
    /// generation quota cooldowns are left to the engine.
    func probe(_ account: AntigravityAccount) async -> Bool {
        guard let file = AntigravityAuthService.authFiles().first(where: { $0.name == account.name }) else { return false }
        let ok = await Self.fetchModelsDirect(for: file)
        guard ok, let authIndex = account.authIndex else { return false }
        // One timeout can quarantine several models of the same account: the
        // engine keys the watchdog state by auth/model, so every 504 cooldown
        // must be released or the account stays quarantined after a good probe.
        let models = Self.watchdogModels(in: account.cooldowns)
        guard !models.isEmpty else { return false }
        var clearedAll = true
        for model in models {
            if await Self.clearBootstrapCooldown(authIndex: authIndex, model: model) == false {
                clearedAll = false
            }
        }
        return clearedAll
    }

    // MARK: - Warmup

    /// Send a minimal generate-content request to activate the 5-hour quota window
    /// and verify account viability before heavy workloads.
    @discardableResult
    func warmupAccount(_ account: AntigravityAccount, model: String? = nil) async -> Bool {
        guard !warmingUpAccountNames.contains(account.name) else { return false }
        warmingUpAccountNames.insert(account.name)
        defer { warmingUpAccountNames.remove(account.name) }

        let success = await Self.performWarmup(
            name: account.name,
            model: model,
            project: account.projectID,
            modelIDs: account.modelIDs
        )
        await refresh(forceQuota: true)
        return success
    }

    func warmupAll(model: String? = nil) async {
        for account in accounts where !account.disabled {
            _ = await warmupAccount(account, model: model)
        }
    }

    private static func performWarmup(
        name: String,
        model: String?,
        project: String?,
        modelIDs: [String]
    ) async -> Bool {
        let files = AntigravityAuthService.authFiles()
        guard let file = files.first(where: { $0.name == name }) else { return false }
        var token = file.accessToken
        var effectiveProject = file.projectID ?? project
        if token == nil || token?.isEmpty == true {
            _ = await AntigravityAuthService.shared.refreshCredential(name: name)
            let refreshed = AntigravityAuthService.authFiles().first(where: { $0.name == name })
            token = refreshed?.accessToken
            effectiveProject = refreshed?.projectID ?? effectiveProject
        }
        guard let validToken = token, !validToken.isEmpty else { return false }

        let chosenModel: String = {
            if let m = model, !m.isEmpty { return m }
            if modelIDs.contains("gemini-2.5-pro") { return "gemini-2.5-pro" }
            if modelIDs.contains("gemini-2.5-flash") { return "gemini-2.5-flash" }
            if let first = modelIDs.first(where: { !$0.isEmpty }) { return first }
            return "gemini-2.5-pro"
        }()

        let outcome = await sendWarmupRequest(token: validToken, project: effectiveProject, model: chosenModel)
        switch outcome {
        case .ok:
            return true
        case .unauthorized:
            _ = await AntigravityAuthService.shared.refreshCredential(name: name)
            let refreshed = AntigravityAuthService.authFiles().first(where: { $0.name == name })
            if let refreshedToken = refreshed?.accessToken, !refreshedToken.isEmpty {
                let retryOutcome = await sendWarmupRequest(
                    token: refreshedToken,
                    project: refreshed?.projectID ?? effectiveProject,
                    model: chosenModel
                )
                return retryOutcome == .ok
            }
            return false
        case .failed:
            return false
        }
    }

    private enum WarmupResult {
        case ok
        case unauthorized
        case failed
    }

    private static func sendWarmupRequest(
        token: String,
        project: String?,
        model: String
    ) async -> WarmupResult {
        guard let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse") else {
            return .failed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AntigravityClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "project": project ?? "",
            "model": model,
            "request": [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": "hi"]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0,
                    "maxOutputTokens": 1
                ]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await NetworkProxy.session().data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 401 {
                return .unauthorized
            }
            if (200..<300).contains(http.statusCode) {
                return .ok
            }
            return .failed
        } catch {
            return .failed
        }
    }

    /// Models whose cooldown came from the first-token watchdog. Quota and
    /// sign-in cooldowns stay with the engine; only a 504 is releasable here.
    nonisolated static func watchdogModels(in cooldowns: [AntigravityCooldown]) -> [String] {
        let models = cooldowns
            .filter { $0.httpStatus == 504 }
            .compactMap(\.modelKey)
            .filter { !$0.isEmpty }
        return Array(Set(models)).sorted()
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

    /// Bind one account to one egress proxy.
    ///
    /// The engine already reads `proxy_url` out of the auth file and prefers it
    /// over the global `requests.proxy-url`, so writing the field here is the
    /// whole feature - no engine change and no restart. An empty string removes
    /// the binding, which puts the account back on the global proxy.
    static func setProxy(name: String, proxyURL: String) async -> Bool {
        let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = ["proxy_url": trimmed]
        guard let request = managementRequest(path: "/auth-files/fields", method: "PATCH", body: body),
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

    /// Outcome of one quota probe. A `retryable` failure is worth repeating
    /// with a refreshed token; a `fatal` one (ban, missing access) is not, and
    /// its message explains why to the user.
    private enum QuotaProbe {
        case ok(CachedQuota)
        case retryable
        case fatal(String)
    }

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
        switch await requestQuota(token: token, project: project) {
        case .ok(let quota):
            return quota
        case .fatal(let reason):
            return CachedQuota(fetchedAt: Date(), gemini: nil, claude: nil, error: reason)
        case .retryable:
            break
        }
        // A stale access token is the common failure; ask the engine to refresh
        // and retry once with the new file contents.
        _ = await AntigravityAuthService.shared.refreshCredential(name: file.name)
        let refreshed = AntigravityAuthService.authFiles().first(where: { $0.name == file.name })
        if let refreshedToken = refreshed?.accessToken, refreshedToken != token {
            switch await requestQuota(token: refreshedToken, project: refreshed?.projectID ?? project) {
            case .ok(let quota):
                return quota
            case .fatal(let reason):
                return CachedQuota(fetchedAt: Date(), gemini: nil, claude: nil, error: reason)
            case .retryable:
                break
            }
        }
        return CachedQuota(fetchedAt: Date(), gemini: nil, claude: nil, error: L("Quota is unavailable right now."))
    }

    private static func requestQuota(token: String, project: String?) async -> QuotaProbe {
        guard let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels") else {
            return .retryable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AntigravityClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["project": project ?? ""])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await NetworkProxy.session().data(for: request)
        } catch {
            return .retryable
        }
        guard let http = response as? HTTPURLResponse else { return .retryable }
        if (200..<300).contains(http.statusCode) {
            guard let quota = parseQuota(data: data) else { return .retryable }
            return .ok(quota)
        }
        // The body carries the real reason - a Terms-of-Service ban says so in
        // plain text. Dropping it here is what turned a ban into "unavailable".
        let body = String(data: data, encoding: .utf8) ?? ""
        if let reason = Self.finalReason(status: http.statusCode, body: body) {
            return .fatal(reason)
        }
        return .retryable
    }

    /// User-facing words for an Antigravity error response, or `nil` when the
    /// failure is worth one retry with a fresh token (401, 5xx, network blip).
    ///
    /// A Terms-of-Service ban is final and says so in the body - before this
    /// existed, every non-2xx collapsed into "Quota is unavailable right now.",
    /// which reads as a passing glitch for an account that is gone for good.
    nonisolated static func finalReason(status: Int, body: String) -> String? {
        let detail = body.lowercased()
        if detail.contains("terms of service") || detail.contains("violation") {
            return L("Blocked by Google for a Terms of Service violation - the account cannot be used.")
        }
        switch status {
        case 401:
            return nil
        case 403:
            return L("Access denied by Google (403) - the account cannot read its quota.")
        case 429:
            return L("Rate limited by Google - try again later.")
        default:
            return nil
        }
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
        request.setValue(AntigravityClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
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
    /// Per-account egress proxy from the auth file; nil means the global one.
    var proxyURL: String?
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
