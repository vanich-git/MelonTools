import Foundation
import Combine
import CryptoKit

/// Manages the local Codex API gateway (CLIProxyAPI sidecar) — a single shared service.
///
/// Lifecycle rules (v1.1.0):
/// - One instance for the whole app (`shared`): dashboard, API view and menu bar all observe the same state.
/// - Before spawning, the service health-checks the port. A healthy gateway is *adopted*, not duplicated.
/// - PIDs are tracked in `gateway.pid`; stop sends SIGTERM, waits, then SIGKILL.
/// - On app quit the gateway stops only if the "stop on quit" setting is on (default off).
@MainActor
final class CodexGatewayService: ObservableObject {
    static let shared = CodexGatewayService()

    enum Status: Equatable {
        case stopped
        case starting
        case running(baseURL: String)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return L("stopped")
            case .starting: return L("starting")
            case .running: return L("running")
            case .failed: return L("failed")
            }
        }
    }

    struct QoSMetric: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let auth: String
        let model: String
        let ttftMS: Int?
        let cooldownSeconds: Int?
        let strike: Int?
        let timedOut: Bool
    }

    struct GatewayRequest: Identifiable {
        let id = UUID()
        let time: Date
        let method: String
        let path: String
        let status: Int
        let duration: String
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastError: String?
    // The request journal and the log tail are NOT published: no view renders
    // them, and every publish would invalidate every observer of the service
    // on each gateway log line (dozens per second under agent load).
    private(set) var logLines: [String] = []
    private(set) var requests: [GatewayRequest] = []
    @Published private(set) var adopted = false
    @Published private(set) var lastQoS: QoSMetric?
    @Published private(set) var qosHistory: [QoSMetric] = []
    @Published private(set) var isStarting = false
    @Published private(set) var checkResult: String?
    @Published private(set) var checkPassed = false
    @Published private(set) var isChecking = false

    private var process: Process?
    private var healthTimer: Timer?
    private var startupProbeTask: Task<Void, Never>?
    private var logTailTimer: Timer?
    private var logReadOffset: UInt64 = 0
    private var logRemainder = ""
    private var userInitiatedStop = false
    /// Proxy URL currently written into config.yaml. The health timer compares
    /// it with the live system proxy so a PAC/VPN change is picked up without
    /// restarting the gateway.
    private var appliedProxyURL = ""

    // MARK: - Settings (persisted)

    @Published var port: Int = UserDefaults.standard.object(forKey: "gatewayPort") as? Int ?? 18317 {
        didSet { UserDefaults.standard.set(port, forKey: "gatewayPort") }
    }
    @Published var apiKey: String = CodexGatewayService.loadStoredApiKey() {
        didSet { CodexGatewayService.saveStoredApiKey(apiKey) }
    }

    /// Credential selection strategy (`routing.strategy` in config.yaml) is
    /// fixed to “fill-first”: the account order comes from the auth-file
    /// priorities that the pool planner computes (first account is used
    /// first, the next one takes over automatically).
    static let gatewayRoutingStrategy = "fill-first"

    /// Auth-file collision guard: two accounts whose display names sanitize to
    /// the same string would silently overwrite each other's gateway file and
    /// drop one account from routing. The id suffix makes names unique.
    nonisolated static func authFileName(for account: CodexAccount) -> String {
        let base = account.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let idSuffix = String(account.id.suffix(8))
        return "codex-\(base)-\(idSuffix).json"
    }

    /// Property observers do not fire during initialization, so persist the
    /// initial port explicitly. The key is persisted by its didSet-less init
    /// path via `saveStoredApiKey`.
    init() {
        UserDefaults.standard.set(port, forKey: "gatewayPort")
        CodexGatewayService.saveStoredApiKey(apiKey)
        // Migrate away from the legacy UserDefaults location.
        UserDefaults.standard.removeObject(forKey: "gatewayApiKey")
    }

    /// Stored in a dedicated 0600 file (not UserDefaults / not the world-
    /// readable plist) so the key stays off the default 0644 plist.
    static func apiKeyFile() -> URL {
        CodexStore.supportDir
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("api-key")
    }

    static func loadStoredApiKey() -> String {
        let url = apiKeyFile()
        if let data = SecureFile.read(url),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        // One-time migration from the legacy UserDefaults location.
        if let legacy = UserDefaults.standard.string(forKey: "gatewayApiKey"), !legacy.isEmpty {
            saveStoredApiKey(legacy)
            UserDefaults.standard.removeObject(forKey: "gatewayApiKey")
            return legacy
        }
        return generateKey()
    }

    static func saveStoredApiKey(_ value: String) {
        let url = apiKeyFile()
        try? SecureFile.write(value, to: url)
    }

    /// Management API secret for the sidecar (never empty). Kept next to the
    /// access key with the same 0600 permissions.
    static func managementSecretFile() -> URL {
        CodexStore.supportDir
            .appendingPathComponent("gateway", isDirectory: true)
            .appendingPathComponent("management-secret")
    }

    static let managementSecret: String = {
        let url = managementSecretFile()
        if let data = SecureFile.read(url),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        let generated = "melon-mgmt-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? SecureFile.write(generated, to: url)
        return generated
    }()

    static func generateKey() -> String {
        "melon-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
    }

    /// Rotate the gateway key and immediately rewrite both the engine config
    /// and the Codex provider token. Without the second write, Codex keeps the
    /// old bearer and starts returning 401.
    func rotateAPIKey() {
        let previous = apiKey
        apiKey = Self.generateKey()
        do {
            try writeConfig()
            if codexRoute == .melon {
                _ = enableCodexRoute()
            }
            auditLog("api key rotated and config/route rewritten")
        } catch {
            apiKey = previous
            lastError = L("Could not rotate the API key") + ": \(error.localizedDescription)"
        }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: - Paths

    static var gatewayDir: URL {
        let dir = CodexStore.supportDir.appendingPathComponent("gateway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static var authDir: URL {
        let dir = gatewayDir.appendingPathComponent("auths", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    var configPath: String { Self.gatewayDir.appendingPathComponent("config.yaml").path }
    var logPath: String { Self.gatewayDir.appendingPathComponent("gateway.log").path }
    var pidPath: String { Self.gatewayDir.appendingPathComponent("gateway.pid").path }

    /// Locate the sidecar binary: app bundle resources → extracted embedded
    /// engine → dev build → PATH.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("bin/cliproxyapi").path)
        }
        if let extracted = ensureEmbeddedEngine() {
            candidates.append(extracted.path)
        }
        // Dev fallback — only meaningful on the author's machine, but harmless
        // elsewhere (the path simply will not exist).
        #if DEBUG
        candidates.append(NSString(string: "~/Projects/MelonTools/build/cliproxyapi").expandingTildeInPath)
        #endif
        if let onPath = ShellService.which("cliproxyapi") { candidates.append(onPath) }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Extract the compressed universal engine into Application Support once
    /// per bundle version. The bundle stays ~24 MB instead of ~139 MB, and the
    /// extracted copy is re-hashed before every launch so a tampered or
    /// half-written engine is replaced instead of executed.
    static func ensureEmbeddedEngine() -> URL? {
        if let cached = cachedEmbeddedEngine { return cached }
        guard !AppRuntime.isTesting,
              let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = extractEngine(
            gzURL: resourceURL.appendingPathComponent("bin/cliproxyapi.gz"),
            hashURL: resourceURL.appendingPathComponent("bin/cliproxyapi.sha256"),
            targetDirectory: gatewayDir.appendingPathComponent("bin", isDirectory: true)
        )
        cachedEmbeddedEngine = url
        return url
    }

    private static var cachedEmbeddedEngine: URL?

    /// Extract and verify one compressed engine. Internal so the extraction
    /// path is covered by a unit test with a small gzip payload.
    static func extractEngine(gzURL: URL, hashURL: URL, targetDirectory: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: gzURL.path),
              let hashText = try? String(contentsOf: hashURL, encoding: .utf8),
              let expected = hashText.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              expected.count == 64 else { return nil }

        try? fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetDirectory.path)
        let target = targetDirectory.appendingPathComponent("cliproxyapi")

        if sha256Hex(at: target) == expected {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            return target
        }

        // Decompress to a hidden sibling, hash it, then rename atomically.
        let temp = targetDirectory.appendingPathComponent(".cliproxyapi.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o700]) else {
            return nil
        }
        defer { try? fm.removeItem(at: temp) }
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", gzURL.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  sha256Hex(at: temp) == expected else {
                return nil
            }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
            _ = try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
            return target
        } catch {
            return nil
        }
    }

    private static func sha256Hex(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Config generation

    /// Rewrite config.yaml after the Network/Proxy settings change. The engine
    /// watches the file; a running service picks up the new proxy without a
    /// restart.
    /// 0 disables the first-token watchdog. The engine watches config.yaml, so
    /// a running gateway picks the new threshold up without a restart.
    static var streamBootstrapTimeoutSeconds: Int {
        let stored = UserDefaults.standard.object(forKey: "streamBootstrapTimeoutSeconds") as? Int
        return min(300, max(0, stored ?? 60))
    }

    func applyStreamBootstrapTimeout() {
        guard isRunning else { return }
        do {
            try writeConfig()
            auditLog("stream bootstrap timeout applied: \(Self.streamBootstrapTimeoutSeconds)s")
        } catch {
            lastError = L("Apply failed") + ": " + error.localizedDescription
        }
    }

    func applyNetworkSettings() {
        NetworkProxy.invalidate()
        guard isRunning else { return }
        do {
            try writeConfig()
            auditLog("network proxy settings applied")
        } catch {
            lastError = L("Apply failed") + ": \(error.localizedDescription)"
        }
    }

    func writeConfig() throws {
        // api-key and paths are escaped: a key containing quotes/colons would
        // otherwise break the YAML and the gateway would never come up.
        var yaml = """
        # Melon Tools — Codex API gateway config (CLIProxyAPI)
        config-version: 8

        server:
          host: "127.0.0.1"
          port: \(port)

        access:
          api-keys:
            - "\(ModelSourcesStore.yamlEscape(apiKey))"

        oauth:
          auth-dir: "\(ModelSourcesStore.yamlEscape(Self.authDir.path))"

        remote-management:
          allow-remote: false
          secret-key: "\(ModelSourcesStore.yamlEscape(Self.managementSecret))"
          disable-control-panel: true
          disable-auto-update-panel: true

        routing:
          strategy: "\(Self.gatewayRoutingStrategy)"

        # Fail over to another account while the leader is cooling down.
        request-retry: 3
        max-retry-interval: 45
        transient-error-cooldown-seconds: 20

        # Fail over before the client commits when the first token is slow.
        stream-bootstrap-timeout-seconds: \(Self.streamBootstrapTimeoutSeconds)

        requests:
          proxy-url: "\(ModelSourcesStore.yamlEscape(NetworkProxy.activeURL() ?? ""))"
        """
        // The overlay adds the Antigravity ids the official catalog misses.
        // Only referenced once the file exists: a dangling path is refused.
        yaml += ModelCatalogOverlay.gatewayYAML()
        // External model sources (OpenRouter, OpenCode) ride in the same config;
        // the running service hot-reloads the file.
        yaml += ModelSourcesStore.shared.gatewayYAML()
        let data = Data(yaml.utf8)
        try SecureFile.write(data, to: URL(fileURLWithPath: configPath))
        appliedProxyURL = NetworkProxy.activeURL() ?? ""
    }

    /// The system proxy can change while the app is running (a VPN or proxy
    /// client toggles it). Rewrite config.yaml when that happens; the engine
    /// watches the file and swaps its upstream transport.
    private func refreshProxyIfNeeded() {
        guard NetworkProxy.isEnabled else { return }
        let current = NetworkProxy.activeURL() ?? ""
        guard current != appliedProxyURL else { return }
        do {
            try writeConfig()
            auditLog("network proxy changed; gateway config updated")
        } catch {
            auditLog("network proxy update failed: \(error.localizedDescription)")
        }
    }

    /// The overlay carries the Antigravity ids the official catalog omits.
    /// Refreshed off the health probe path so a slow fetch never delays it;
    /// a successful refresh also rewrites the config in case the overlay file
    /// appeared after the gateway started.
    private func refreshCatalogIfNeeded() {
        guard ModelCatalogOverlay.needsRefresh() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await ModelCatalogOverlay.refreshIfNeeded(timeout: 45) else { return }
            do {
                try self.writeConfig()
                self.auditLog("model catalog overlay refreshed")
            } catch {
                self.auditLog("model catalog overlay config write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Auth files account sync owns and may delete when the vault is
    /// re-synced. Only `codex-*.json` qualifies: Claude OAuth files
    /// (`claude-*.json`) written by the engine — and any other file in the
    /// auth dir — must survive the sync.
    nonisolated static func ownedAuthFileNames(in names: [String]) -> [String] {
        names.filter { $0.hasPrefix("codex-") && $0.hasSuffix(".json") }
    }

    /// Write each vault account as a CLIProxyAPI codex auth file.
    /// `priorities` maps account ids to a routing priority (higher = used sooner).
    /// `poolSlugs` is the visible pool; the payload lists the models the
    /// account must not receive. `nil` reads the pool from disk.
    func syncAccounts(
        accounts: [CodexAccount],
        priorities: [String: Int] = [:],
        poolSlugs: Set<String>? = nil
    ) throws {
        try Self.syncAccounts(
            accounts,
            priorities: priorities,
            authDir: Self.authDir,
            poolSlugs: poolSlugs
        )
    }

    /// Static core of the sync — the instance wrapper passes the live auth
    /// dir; tests pass a temporary directory.
    nonisolated static func syncAccounts(
        _ accounts: [CodexAccount],
        priorities: [String: Int],
        authDir directory: URL,
        poolSlugs: Set<String>? = nil
    ) throws {
        let fm = FileManager.default
        // The union is for the picker; routing exclusions are per account.
        let pool = poolSlugs ?? CodexModelCatalog.visiblePoolSnapshot()
        var desired: [(name: String, payload: [String: Any], preserveLegacyPause: Bool)] = []
        for account in accounts {
            guard let access = account.tokens.access_token, !access.isEmpty else { continue }
            let expired = account.accessTokenExpiry.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            var payload: [String: Any] = [
                "id_token": account.tokens.id_token ?? "",
                "access_token": access,
                "refresh_token": account.tokens.refresh_token ?? "",
                "account_id": account.accountId ?? account.tokens.account_id ?? "",
                "last_refresh": account.lastRefresh ?? ISO8601DateFormatter().string(from: Date()),
                "email": account.email ?? "",
                "type": "codex",
                "expired": expired,
                "plan_type": account.planType ?? "free",
            ]
            if let priority = priorities[account.id], priority > 0 {
                payload["priority"] = priority
            }
            // The engine routes a pool model only to accounts that allow it.
            // An empty exclusion list is omitted, not written as `[]`.
            let excluded = CodexPoolModelsStore.excludedSlugs(for: account, poolSlugs: pool)
            if !excluded.isEmpty {
                payload["excluded_models"] = excluded.sorted()
            }
            // Accounts the planner pauses — a window is exhausted or the
            // account dropped below the user's reserve — are excluded from
            // gateway routing until a fresh reading clears the block.
            if CodexRoutingPlanner.blockReason(account) != nil {
                payload["disabled"] = true
            }
            desired.append((
                name: authFileName(for: account),
                payload: payload,
                preserveLegacyPause: account.quotaBlock == nil && !CodexRoutingPlanner.quotaIsFresh(account)
            ))
        }

        // Diff the directory instead of deleting every file first. The engine
        // watches this directory; rewriting unchanged credentials makes it
        // re-read tokens and can briefly race an in-flight request. Only the
        // files this sync owns are considered, and only changed ones are
        // written.
        let desiredNames = Set(desired.map(\.name))
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for name in ownedAuthFileNames(in: names) where !desiredNames.contains(name) {
                try? fm.removeItem(atPath: directory.appendingPathComponent(name).path)
            }
        }
        for entry in desired {
            let fileURL = directory.appendingPathComponent(entry.name)
            var payload = entry.payload
            let existingObject = (try? Data(contentsOf: fileURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let existingDisabled = existingObject?["disabled"] as? Bool ?? false
            if entry.preserveLegacyPause && existingDisabled {
                payload["disabled"] = true
            }
            if let existingObject, jsonPayloadsMatch(existingObject, payload) {
                continue
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try SecureFile.write(data, to: fileURL)
        }
    }

    /// Compares an auth file with the desired payload. An explicit
    /// `disabled: false` is equivalent to an absent key, because the
    /// management API may persist either form.
    private nonisolated static func jsonPayloadsMatch(_ existing: [String: Any], _ desired: [String: Any]) -> Bool {
        var normalized = existing
        if normalized["disabled"] as? Bool == false {
            normalized.removeValue(forKey: "disabled")
        }
        guard let left = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: desired, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    // MARK: - Lifecycle

    /// Start the gateway. If a healthy gateway already owns the port, adopt it instead of spawning a duplicate.
    func start(accounts: [CodexAccount], priorities: [String: Int] = [:], force: Bool = false) async {
        guard !isStarting else { return }
        if !force, isRunning { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        checkResult = nil

        // A (forced) start must not leave the previous process running:
        // spawning again on the same port fails with “address in use”.
        if isRunning { await stop() }

        // Finish the model catalog before the config points at it. Bounded:
        // an unreachable host must not hold the gateway at `.starting`.
        await ModelCatalogOverlay.refreshIfNeeded(timeout: 8)

        // 1. Adopt an already-running gateway when it answers our key.
        if !force {
            switch await probeHealth() {
            case .ok:
                // Keep the adopted gateway aligned with the current vault and order.
                try? writeConfig()
                try? syncAccounts(accounts: accounts, priorities: priorities)
                adopted = true
                if let adoptedPID = adoptedListenerPID() {
                    writePIDFile(adoptedPID)
                }
                status = .running(baseURL: baseURL)
                auditLog(L("Adopted the running gateway."))
                startHealthCheck()
                startLogTail(replayLastBytes: true)
                return
            case .unauthorized:
                finishWithFailure(L("Port is busy: another service owns it with a different API key. Stop it first or change the port."))
                return
            case .unreachable:
                break
            }
        }

        status = .starting

        // 2. Clean up a stale child recorded in the PID file. The pid is only
        // trusted when it still runs our binary (PID-reuse guard).
        if let stale = Self.verifiedPIDFile(), stale != getpid(), Self.processAlive(stale) {
            auditLog("terminating stale gateway pid \(stale)")
            await terminateProcess(pid: stale, grace: 4)
            removePIDFile()
        } else if readPIDFile() != nil {
            // Stale PID that no longer matches our binary — just drop the file.
            removePIDFile()
        }

        // 3. Spawn.
        guard let binary = Self.locateBinary() else {
            finishWithFailure(L("The service component was not found — reinstall the app."))
            return
        }
        do {
            try writeConfig()
            try syncAccounts(accounts: accounts, priorities: priorities)
        } catch {
            finishWithFailure(L("Config write failed") + ": " + error.localizedDescription)
            return
        }
        logLines = []
        spawn(binary: binary)
    }

    func stop() async {
        userInitiatedStop = true
        defer { userInitiatedStop = false }
        healthTimer?.invalidate()
        healthTimer = nil
        startupProbeTask?.cancel()
        startupProbeTask = nil
        logTailTimer?.invalidate()
        logTailTimer = nil
        let pid = process?.processIdentifier ?? Self.verifiedPIDFile() ?? adoptedListenerPID()
        if let pid, pid != getpid() {
            await terminateProcess(pid: pid, grace: 5)
        }
        process?.terminationHandler = nil
        process = nil
        removePIDFile()
        adopted = false
        requests = []
        status = .stopped
    }

    /// Blocking stop used at app termination (SIGTERM → wait → SIGKILL).
    func stopSync() {
        userInitiatedStop = true
        healthTimer?.invalidate()
        healthTimer = nil
        startupProbeTask?.cancel()
        startupProbeTask = nil
        logTailTimer?.invalidate()
        logTailTimer = nil
        let pid = process?.processIdentifier ?? Self.verifiedPIDFile() ?? adoptedListenerPID()
        if let pid, pid != getpid() {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline, Self.processAlive(pid) {
                usleep(100_000)
            }
            if Self.processAlive(pid) {
                kill(pid, SIGKILL)
            }
        }
        process?.terminationHandler = nil
        process = nil
        removePIDFile()
        adopted = false
        status = .stopped
    }

    func restart(accounts: [CodexAccount], priorities: [String: Int] = [:]) async {
        await stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await start(accounts: accounts, priorities: priorities, force: true)
    }

    /// Re-sync account files without stopping (the gateway hot-reloads the auth dir).
    /// `poolSlugs` is the visible pool the auth payloads exclude from; `nil`
    /// falls back to the pool on disk.
    func syncAccountsLive(
        _ accounts: [CodexAccount],
        priorities: [String: Int] = [:],
        poolSlugs: Set<String>? = nil
    ) {
        do {
            try syncAccounts(accounts: accounts, priorities: priorities, poolSlugs: poolSlugs)
            auditLog("accounts synced (\(accounts.count))")
        } catch {
            auditLog("account sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Routing settings

    /// Applies the pool order: rewrites config.yaml (the strategy itself is
    /// fixed to “fill-first”; the order lives in the auth-file priorities) and
    /// hot-syncs the auth files. A running gateway picks the change up without
    /// a restart.
    func applyRouting(accounts: [CodexAccount], priorities: [String: Int]) async {
        do {
            try writeConfig()
        } catch {
            lastError = L("Config write failed") + ": " + error.localizedDescription
            return
        }
        if isRunning {
            syncAccountsLive(accounts, priorities: priorities)
        } else {
            do {
                try syncAccounts(accounts: accounts, priorities: priorities)
            } catch {
                lastError = L("Config write failed") + ": " + error.localizedDescription
                return
            }
        }
        auditLog("routing applied — \(priorities.count) account(s) in the pool")
    }

    // MARK: - Codex app route (~/.codex/config.toml)

    enum CodexRoute: Equatable {
        /// No provider configured — the Codex client talks to OpenAI directly.
        case none
        /// Routed through this gateway.
        case melon
        /// Routed through another local service (for example, Cockpit Tools).
        case other(String)
    }

    nonisolated static var codexConfigPath: String {
        NSString(string: "~/.codex/config.toml").expandingTildeInPath
    }

    static var codexConfigBackupPath: String {
        codexConfigPath + ".melon-backup"
    }

    private var codexConfigText: String {
        (try? String(contentsOfFile: Self.codexConfigPath, encoding: .utf8)) ?? ""
    }

    var codexRoute: CodexRoute {
        guard let provider = CodexConfigRoute.currentProvider(in: codexConfigText) else { return .none }
        if provider == CodexConfigRoute.providerID { return .melon }
        if provider == "openai" { return .none }
        return .other(provider)
    }

    /// Points the Codex client at this gateway. The previous config is backed
    /// up once, before the first takeover. Returns true when the file changed.
    @discardableResult
    func enableCodexRoute() -> Bool {
        let fm = FileManager.default
        let current = codexConfigText
        var updated = CodexConfigRoute.upsertRoute(in: current, baseURL: baseURL + "/v1", token: apiKey)
        // The Codex app refuses to boot when `model_catalog_json` points at a
        // missing file. Route owners (e.g. Cockpit Tools) clean their catalog
        // up once their route drops, so a stale reference can turn the next
        // app start into a “configuration could not be loaded” dialog. Drop
        // the dangling key — the backup keeps the original line for “remove
        // routing”.
        if let reference = CodexConfigRoute.modelCatalogPath(in: updated), reference.isEmpty == false {
            let configDir = (Self.codexConfigPath as NSString).deletingLastPathComponent
            let resolved = reference.hasPrefix("/")
                ? reference
                : (configDir as NSString).appendingPathComponent(reference)
            if fm.fileExists(atPath: resolved) == false {
                updated = CodexConfigRoute.removingTopLevelKey("model_catalog_json", in: updated)
                auditLog("dropped dangling model_catalog_json (\(reference))")
            }
        }
        guard updated != current else { return false }
        if codexRoute != .melon, fm.fileExists(atPath: Self.codexConfigPath) {
            // Refresh the backup on every takeover so “remove routing” always
            // restores the most recent non-Melon config.
            try? fm.removeItem(atPath: Self.codexConfigBackupPath)
            try? fm.copyItem(atPath: Self.codexConfigPath, toPath: Self.codexConfigBackupPath)
            // The backup carries tokens — never leave it world-readable.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.codexConfigBackupPath)
        }
        do {
            // The config carries the gateway bearer token — 0600 from creation.
            try SecureFile.write(updated, to: URL(fileURLWithPath: Self.codexConfigPath))
        } catch {
            lastError = L("Could not update the Codex config") + ": " + error.localizedDescription
            return false
        }
        // Fresh installs have no config until the route is enabled; add the
        // catalog reference only now, and only when the catalog actually exists.
        if FileManager.default.fileExists(atPath: CodexModelCatalog.targetPath) {
            try? CodexModelCatalog.ensureConfigReference()
        }
        auditLog("codex route enabled → \(CodexConfigRoute.providerID) @ \(baseURL)")
        return true
    }

    /// Removes the Melon route while preserving every other provider table.
    /// Previous versions restored the whole backup, which discarded provider
    /// sections added after the takeover. Only Melon's top-level keys and its
    /// own provider blocks are touched now; the legacy alias stays so old
    /// chats keep resolving to the local gateway.
    @discardableResult
    func disableCodexRoute() -> Bool {
        let fm = FileManager.default
        let current = codexConfigText
        let backup = try? String(contentsOfFile: Self.codexConfigBackupPath, encoding: .utf8)
        var updated = CodexConfigRoute.removeRoute(in: current)

        // Remove only the catalog reference Melon owns.
        if let reference = CodexConfigRoute.modelCatalogPath(in: updated),
           reference.hasSuffix(CodexModelCatalog.fileName) {
            updated = CodexConfigRoute.removingTopLevelKey("model_catalog_json", in: updated)
        }
        if let backup {
            if let provider = CodexConfigRoute.currentProvider(in: backup),
               provider != CodexConfigRoute.providerID,
               provider != "melon_local_access" {
                updated = CodexConfigRoute.upsertTopLevelKey(
                    "model_provider", value: provider, in: updated
                )
            }
            if let catalog = CodexConfigRoute.modelCatalogPath(in: backup),
               !catalog.isEmpty,
               !catalog.hasSuffix(CodexModelCatalog.fileName) {
                updated = CodexConfigRoute.upsertTopLevelKey(
                    "model_catalog_json", value: catalog, in: updated
                )
            }
        }
        guard updated != current else { return false }
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(atPath: Self.codexConfigPath)
        } else {
            try? SecureFile.write(updated, to: URL(fileURLWithPath: Self.codexConfigPath))
        }
        try? fm.removeItem(atPath: Self.codexConfigBackupPath)
        auditLog("codex route removed")
        return true
    }

    /// Keep the engine log private and bounded. The engine writes account
    /// identifiers and upstream errors, so 0644 or an unbounded file is not
    /// acceptable.
    private func prepareLogFile() {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: logPath)
        if let attributes = try? fm.attributesOfItem(atPath: logPath),
           let size = attributes[.size] as? NSNumber,
           size.intValue > 2 * 1024 * 1024 {
            let rotated = URL(fileURLWithPath: logPath + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
    }

    private func spawn(binary: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-config", configPath]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env

        // Log directly to a file (not a pipe): a pipe would break when the app quits
        // and Go's runtime would kill the child with SIGPIPE on the next log write.
        prepareLogFile()
        let logHandle = FileHandle(forWritingAtPath: logPath)
        if let logHandle {
            logHandle.seekToEndOfFile()
            p.standardOutput = logHandle
            p.standardError = logHandle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }

        p.terminationHandler = { [weak self] proc in
            logHandle?.closeFile()
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.userInitiatedStop else { return }
                self.process = nil
                self.healthTimer?.invalidate()
                self.healthTimer = nil
                self.adopted = false
                self.removePIDFile()
                let reason = self.friendlyExitReason()
                self.lastError = reason
                self.status = .failed(reason)
            }
        }

        do {
            try p.run()
        } catch {
            finishWithFailure(L("Launch failed") + ": " + error.localizedDescription)
            return
        }
        process = p
        writePIDFile(p.processIdentifier)
        adopted = false
        auditLog("gateway spawned pid \(p.processIdentifier)")
        hardenEngineLogs()
        startHealthCheck()
        startLogTail(replayLastBytes: false)
    }

    /// The engine creates its own request/error logs with the process umask.
    /// Tighten them after startup so backups and sync tools cannot read them.
    private func hardenEngineLogs() {
        let fm = FileManager.default
        let logs = Self.authDir.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logs.path)
        if let names = try? fm.contentsOfDirectory(atPath: logs.path) {
            for name in names {
                try? fm.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logs.appendingPathComponent(name).path
                )
            }
        }
    }

    private func finishWithFailure(_ message: String) {
        startupProbeTask?.cancel()
        startupProbeTask = nil
        status = .failed(message)
        lastError = message
    }

    /// Map raw exit statuses/log tails to human-readable reasons.
    private func friendlyExitReason() -> String {
        let tail = logLines.suffix(14).joined(separator: "\n").lowercased()
        if tail.contains("address already in use") {
            return L("Port is busy: another service already owns it. Try “Adopt running”.")
        }
        if tail.contains("permission denied") {
            return L("Permission denied while starting the service.")
        }
        if tail.contains("no such file") {
            return L("Service settings are missing — try “Restart”.")
        }
        if tail.contains("invalid config") || (tail.contains("config") && tail.contains("error")) {
            return L("The service rejected its settings — try “Restart”.")
        }
        return L("Service exited")
    }

    // MARK: - Health

    private enum Probe { case ok, unauthorized, unreachable }

    private func probeHealth() async -> Probe {
        var request = URLRequest(url: URL(string: "\(baseURL)/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        do {
            let (_, response) = try await NetworkProxy.directSession().data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if http.statusCode == 200 { return .ok }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        var misses = 0
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch await self.probeHealth() {
                case .ok:
                    misses = 0
                    if case .running = self.status {} else {
                        self.status = .running(baseURL: self.baseURL)
                    }
                    // Assign only on change: every write invalidates the views.
                    if self.lastError != nil { self.lastError = nil }
                    self.refreshProxyIfNeeded()
                    self.refreshCatalogIfNeeded()
                case .unauthorized, .unreachable:
                    misses += 1
                    if misses >= 3 {
                        if self.process == nil, self.adopted {
                            self.healthTimer?.invalidate()
                            self.healthTimer = nil
                            self.adopted = false
                            let reason = L("The running service stopped responding.")
                            self.lastError = reason
                            self.status = .failed(reason)
                        } else if self.process != nil {
                            // Repeated 401/unreachable after spawn: do not
                            // leave a broken child advertised as starting.
                            self.finishWithFailure(
                                L("The service did not answer healthy requests.")
                            )
                            Task { await self.stop() }
                        }
                    }
                }
            }
        }
        healthTimer?.tolerance = 1.0
        // The 30-second timer alone leaves `status` at `.starting` for up to
        // half a minute after launch. The live quota guard checks `isRunning`
        // every 1.5 seconds, so probe quickly until the engine answers.
        startupProbeTask?.cancel()
        startupProbeTask = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                if case .running = self.status { return }
                if case .ok = await self.probeHealth() {
                    self.status = .running(baseURL: self.baseURL)
                    if self.lastError != nil { self.lastError = nil }
                    return
                }
            }
        }
    }

    /// No-op kept for call-site compatibility; health is driven by the timer.
    func healthCheck() async {
        guard isRunning else { return }
        if case .ok = await probeHealth() {
            // `@Published` publishes on every assignment, even when the value
            // is unchanged: guard so the idle 5s health probe does not
            // invalidate every gateway observer forever.
            if lastError != nil { lastError = nil }
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// POST /v1/* requests in the last 60 seconds — the live pool load, parsed
    /// from the gateway log tail. This is what burns the rolling windows.
    var requestsLastMinute: Int {
        let cutoff = Date().addingTimeInterval(-60)
        return requests.filter {
            $0.time >= cutoff && $0.method == "POST" && $0.path.hasPrefix("/v1/")
        }.count
    }

    // MARK: - API check + launch

    /// GET /v1/models plus a tiny chat completion — proves end-to-end request handling.
    func checkAPI() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        checkResult = nil
        checkPassed = false

        guard isRunning else {
            checkResult = L("Service is not running")
            return
        }
        do {
            var listRequest = URLRequest(url: URL(string: "\(baseURL)/v1/models")!)
            listRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            listRequest.timeoutInterval = 8
            let (listData, listResponse) = try await NetworkProxy.directSession().data(for: listRequest)
            guard let listHTTP = listResponse as? HTTPURLResponse, listHTTP.statusCode == 200 else {
                let code = (listResponse as? HTTPURLResponse)?.statusCode ?? -1
                checkResult = L("Check failed") + ": HTTP \(code)"
                return
            }
            let listObject = try? JSONSerialization.jsonObject(with: listData) as? [String: Any]
            let models = (listObject?["data"] as? [[String: Any]]) ?? []
            let ids = models.compactMap { $0["id"] as? String }
            // Probe a model that is actually usable right now: a Go-covered
            // OpenCode model or an OpenRouter one. Balance-only OpenCode models
            // (not covered by the Go plan) would answer 402 with an empty
            // console balance and make a healthy gateway look broken.
            let goAliases = Set(ModelSourcesStore.shared.sources
                .filter { $0.kind == .openCode }
                .flatMap { source in source.models.filter { $0.goTier == true }.map(\.alias) })
            let model = ids.first { goAliases.contains($0) }
                ?? ids.first { $0.hasPrefix("openrouter/") }
                ?? ids.first { !$0.lowercased().contains("image") }
                ?? ids.first
                ?? "gpt-5.1-codex-mini"

            let started = Date()
            var chatRequest = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
            chatRequest.httpMethod = "POST"
            chatRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chatRequest.timeoutInterval = 90
            chatRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 8,
                "stream": false,
            ])
            let (chatData, chatResponse) = try await NetworkProxy.directSession().data(for: chatRequest)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            guard let chatHTTP = chatResponse as? HTTPURLResponse, (200..<300).contains(chatHTTP.statusCode) else {
                let code = (chatResponse as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(data: chatData, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
                checkResult = L("Check failed") + ": HTTP \(code) · \(snippet)"
                return
            }
            let usage = ((try? JSONSerialization.jsonObject(with: chatData)) as? [String: Any])?["usage"] as? [String: Any]
            let tokens = (usage?["total_tokens"] as? Int).map { " · \($0) tokens" } ?? ""
            checkPassed = true
            checkResult = L("Check passed") + " · \(ISODate.duration(elapsedMs)) · \(model)\(tokens)"
        } catch {
            checkResult = L("Check failed") + ": " + error.localizedDescription
        }
    }

    /// One-click “open Codex on this gateway”: starts the service when needed,
    /// points `~/.codex/config.toml` at it, then relaunches the Codex app so
    /// it rereads the route, applies the pool settings and attaches the
    /// composer chips through the debug port.
    ///
    /// Every launch restarts the app (like Cockpit Tools does for its default
    /// instance) — the app always comes up with the current routing.
    func launchCodexApp() async {
        let store = CodexStore.shared
        store.load()
        if !isRunning {
            await start(accounts: store.accounts, priorities: store.effectivePriorities())
        }
        guard isRunning else {
            auditLog(L("Launch failed:") + " " + (lastError ?? L("Service is not running")))
            return
        }
        enableCodexRoute()
        auditLog(L("Launching the Codex app through the service…"))
        // Opening Codex must not discard unsaved input; a route change has its
        // own explicit restart path.
        ComposerBridge.shared.launchOrActivateCodex(forceRestart: false)
    }

    /// Button wrapper for the API view and Settings.
    func launchThroughGateway() {
        Task { @MainActor in await launchCodexApp() }
    }

    // MARK: - Logs & request journal

    func auditLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        trimLog()
    }

    /// Appends a batch of gateway log lines with a single state publish.
    private func ingest(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        logLines.append(contentsOf: newLines)
        trimLog()
        var parsed: [GatewayRequest] = []
        for line in newLines {
            if let request = Self.parseRequestLine(line) { parsed.append(request) }
            if let metric = Self.parseQoSLine(line) {
                qosHistory.insert(metric, at: 0)
                if qosHistory.count > 30 { qosHistory.removeLast(qosHistory.count - 30) }
                lastQoS = metric
                if metric.timedOut {
                    auditLog("qos failover auth=\(metric.auth) model=\(metric.model) cooldown=\(metric.cooldownSeconds ?? 0)s")
                }
            }
        }
        if !parsed.isEmpty {
            requests.insert(contentsOf: parsed, at: 0)
            if requests.count > 100 {
                requests.removeLast(requests.count - 100)
            }
        }
    }

    private func trimLog() {
        if logLines.count > 800 {
            logLines.removeFirst(logLines.count - 800)
        }
    }

    // MARK: - Log tailing (gateway writes to gateway.log directly)

    /// Follow gateway.log. `replayLastBytes` reads the recent tail first (used when adopting).
    private func startLogTail(replayLastBytes: Bool) {
        logTailTimer?.invalidate()
        logTailTimer = nil
        logRemainder = ""
        let size = Self.fileSize(logPath)
        if replayLastBytes {
            logReadOffset = size > 65536 ? size - 65536 : 0
            readNewLogBytes()
        } else {
            logReadOffset = size
        }
        logTailTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readNewLogBytes()
            }
        }
        logTailTimer?.tolerance = 0.5
    }

    private func readNewLogBytes() {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < logReadOffset {
            // Log was recreated/truncated.
            logReadOffset = 0
            logRemainder = ""
        }
        guard size > logReadOffset else { return }
        try? handle.seek(toOffset: logReadOffset)
        let data = handle.readDataToEndOfFile()
        logReadOffset = size
        guard let text = String(data: data, encoding: .utf8) else { return }
        let combined = logRemainder + text
        var lines = combined.components(separatedBy: "\n")
        logRemainder = lines.popLast() ?? ""
        let fresh = lines.filter { !$0.isEmpty }
        if !fresh.isEmpty { ingest(fresh) }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    /// Parses the engine's `[qos]` telemetry lines emitted by the first-token
    /// watchdog. Logrus prefixes the message, so the parser only looks for the
    /// known key/value tokens.
    nonisolated static func parseQoSLine(_ line: String) -> QoSMetric? {
        guard line.contains("[qos]") else { return nil }
        let timedOut = line.contains("first_token_timeout")
        guard timedOut || line.contains("first_token") else { return nil }
        guard line.contains("provider=antigravity") else { return nil }
        func value(_ key: String) -> Int? {
            guard let range = line.range(of: key + "=") else { return nil }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            return Int(digits)
        }
        func text(_ key: String) -> String? {
            guard let range = line.range(of: key + "=") else { return nil }
            let rest = line[range.upperBound...]
            let token = rest.prefix { !$0.isWhitespace && $0 != "\"" }
            return token.isEmpty ? nil : String(token)
        }
        return QoSMetric(
            time: Date(),
            auth: text("auth") ?? "—",
            model: text("model") ?? "—",
            ttftMS: value("ttft_ms"),
            cooldownSeconds: value("cooldown_s"),
            strike: value("strike"),
            timedOut: timedOut
        )
    }

    /// Parse CLIProxyAPI gin logger lines (4+ pipe-separated columns):
    /// `[...] [gin_logger.go:56] 200 | 1.05s | 127.0.0.1 | GET "/v1/models"`
    private static func parseRequestLine(_ line: String) -> GatewayRequest? {
        guard line.contains("gin_logger") || line.contains("[GIN]") else { return nil }
        let parts = line.components(separatedBy: " | ")
        guard parts.count >= 4, let requestPart = parts.last else { return nil }
        let statusToken = parts[0].split(separator: " ").last.map(String.init) ?? ""
        guard let status = Int(statusToken) else { return nil }
        let duration = parts[1].trimmingCharacters(in: .whitespaces)
        guard let firstQuote = requestPart.firstIndex(of: "\""),
              let lastQuote = requestPart.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }
        let path = String(requestPart[requestPart.index(after: firstQuote)..<lastQuote])
        let method = String(requestPart[..<firstQuote]).trimmingCharacters(in: .whitespaces)
        guard !method.isEmpty, path.hasPrefix("/") else { return nil }
        return GatewayRequest(time: Date(), method: method, path: path, status: status, duration: duration)
    }

    // MARK: - PID helpers

    private func writePIDFile(_ pid: pid_t?) {
        guard let pid else {
            removePIDFile()
            return
        }
        try? String(pid).write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    private func readPIDFile() -> pid_t? {
        guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        guard let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }

    /// PID from the file only when it currently runs our binary — protects
    /// against PID reuse after a reboot.
    private static func verifiedPIDFile() -> pid_t? {
        let path = gatewayDir.appendingPathComponent("gateway.pid").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard isGatewayProcess(pid) else { return nil }
        return pid
    }

    private func removePIDFile() {
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// PID of the process listening on our port (covers gateways started outside the app).
    private func listenerPID() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let first = text.split(separator: "\n").first else { return nil }
        return pid_t(first.trimmingCharacters(in: .whitespaces))
    }

    private static func processAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True when `pid` runs our gateway binary. Guards against PID reuse
    /// (stale PID file after a reboot) and against killing an unrelated
    /// process that happened to grab our port.
    private static func isGatewayProcess(_ pid: pid_t) -> Bool {
        let maxPath = 4096
        var buffer = [UInt8](repeating: 0, count: maxPath)
        let length = proc_pidpath(pid, &buffer, UInt32(maxPath))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        if path.hasSuffix("/cliproxyapi") { return true }
        // Adopted gateways may run under a different binary name on a
        // non-standard port; the PID file is only trusted when the process
        // path still exists at all (killed/reaped pids report no path).
        return false
    }

    /// PID of a process listening on our port that is actually our binary.
    private func adoptedListenerPID() -> pid_t? {
        guard let pid = listenerPID(), Self.isGatewayProcess(pid) else { return nil }
        return pid
    }

    private func terminateProcess(pid: pid_t, grace: TimeInterval) async {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !Self.processAlive(pid) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        kill(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
