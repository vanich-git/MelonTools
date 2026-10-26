import AppKit
import Foundation
import Combine

// MARK: - Low-quota notifications

/// One rolling quota window the notification policy watches.
enum QuotaNotificationWindow: String, CaseIterable {
    case hourly
    case weekly
}

/// What the policy last told the user about one account/window pair.
struct QuotaNotificationRecord: Codable, Equatable {
    var notifiedAt: Date
    /// Identity of the window (its reset timestamp); empty when unknown.
    var windowKey: String
}

/// Pure low-quota decision helper. The store owns persistence and delivery;
/// this type only answers which account/window pairs deserve a notification.
enum QuotaNotificationPolicy {
    /// Legacy weekly threshold when the account has no weekly reserve.
    static let weeklyDefaultThreshold: Double = 10
    /// Quota-reset notifications without a reset timestamp use the legacy
    /// six-hour debounce. Low-quota notices stay suppressed until recovery.
    static let fallbackDebounce: TimeInterval = 6 * 3600

    struct Decision: Equatable {
        let window: QuotaNotificationWindow
        let remaining: Double
        let threshold: Double
        let windowKey: String
        let stateKey: String
    }

    /// One decision per account/window that is at or below its threshold and
    /// has not been announced during this continuous low-quota period.
    ///
    /// The hourly window is opt-in through the account reserve: it moves fast
    /// and would be noisy. The weekly window keeps the legacy 10 % default and
    /// uses the weekly reserve when one is configured.
    static func decisions(
        accountId: String,
        hourlyRemaining: Double?,
        hourlyReset: Date?,
        hourlyReservePercent: Int?,
        weeklyRemaining: Double?,
        weeklyReset: Date?,
        weeklyReservePercent: Int?,
        records: [String: QuotaNotificationRecord]
    ) -> [Decision] {
        var result: [Decision] = []

        if let remaining = hourlyRemaining,
           let reserve = hourlyReservePercent, reserve > 0,
           let decision = decision(
               accountId: accountId,
               window: .hourly,
               remaining: remaining,
               threshold: Double(reserve),
               reset: hourlyReset,
               records: records
           ) {
            result.append(decision)
        }

        let weeklyThreshold = weeklyThreshold(for: weeklyReservePercent)
        if let remaining = weeklyRemaining,
           let decision = decision(
               accountId: accountId,
               window: .weekly,
               remaining: remaining,
               threshold: weeklyThreshold,
               reset: weeklyReset,
               records: records
           ) {
            result.append(decision)
        }

        return result
    }

    /// Remove low-quota markers only after the corresponding window recovers
    /// above its threshold. A new reset timestamp alone does not re-arm an
    /// alert while quota remains low.
    static func recordsAfterRecovery(
        accountId: String,
        hourlyRemaining: Double?,
        hourlyReservePercent: Int?,
        weeklyRemaining: Double?,
        weeklyReservePercent: Int?,
        records: [String: QuotaNotificationRecord]
    ) -> [String: QuotaNotificationRecord] {
        var updated = records
        let hourlyKey = "\(accountId):hourly"
        if let reserve = hourlyReservePercent, reserve > 0 {
            if let remaining = hourlyRemaining, remaining > Double(reserve) {
                updated.removeValue(forKey: hourlyKey)
            }
        } else {
            updated.removeValue(forKey: hourlyKey)
        }

        let weeklyKey = "\(accountId):weekly"
        if let remaining = weeklyRemaining,
           remaining > weeklyThreshold(for: weeklyReservePercent) {
            updated.removeValue(forKey: weeklyKey)
        }
        return updated
    }

    private static func weeklyThreshold(for reserve: Int?) -> Double {
        guard let reserve, reserve > 0 else { return weeklyDefaultThreshold }
        return Double(reserve)
    }

    /// Reset notifications are limited to one per reset window. If the reset
    /// timestamp is missing, the legacy time-based debounce applies.
    static func shouldNotify(
        stateKey: String,
        windowKey: String,
        records: [String: QuotaNotificationRecord],
        now: Date
    ) -> Bool {
        guard let record = records[stateKey] else { return true }
        if !windowKey.isEmpty, !record.windowKey.isEmpty {
            return windowKey != record.windowKey
        }
        return now.timeIntervalSince(record.notifiedAt) >= fallbackDebounce
    }

    /// Stable identity of a rolling window: its reset timestamp in seconds.
    static func windowKey(for reset: Date?) -> String {
        guard let reset else { return "" }
        return String(Int(reset.timeIntervalSince1970))
    }

    private static func decision(
        accountId: String,
        window: QuotaNotificationWindow,
        remaining: Double,
        threshold: Double,
        reset: Date?,
        records: [String: QuotaNotificationRecord]
    ) -> Decision? {
        guard remaining <= threshold else { return nil }
        let key = windowKey(for: reset)
        let stateKey = "\(accountId):\(window.rawValue)"
        // Low quota is one alert per continuous low period. Do not re-arm it
        // just because the provider advanced or changed its reset timestamp.
        guard records[stateKey] == nil else { return nil }
        return Decision(
            window: window,
            remaining: remaining,
            threshold: threshold,
            windowKey: key,
            stateKey: stateKey
        )
    }
}

// MARK: - Quota reset notifications

/// One account window at refresh time. `isBlocked` mirrors the routing
/// planner: a zero window or a window at/below its user reserve pauses the
/// account. No freshness check here — the transition compares what the last
/// refresh left behind with what the new refresh returned.
struct QuotaWindowState: Equatable {
    var remaining: Double? = nil
    var reset: Date? = nil
    var reservePercent: Int? = nil

    var isBlocked: Bool {
        guard let remaining else { return false }
        if remaining <= 0 { return true }
        if let reservePercent, reservePercent > 0, remaining <= Double(reservePercent) {
            return true
        }
        return false
    }

    var isUsable: Bool {
        remaining != nil && !isBlocked
    }
}

/// Pure reset decision helper. A notification is due only when the account
/// was blocked by at least one window before the refresh and is usable after
/// it. Every window that recovered gets its own notice, at most once per
/// reset window.
enum QuotaResetNotificationPolicy {
    struct Decision: Equatable {
        let window: QuotaNotificationWindow
        let remaining: Double
        let windowKey: String
        let stateKey: String
    }

    static func decisions(
        accountId: String,
        hourlyBefore: QuotaWindowState,
        hourlyAfter: QuotaWindowState,
        weeklyBefore: QuotaWindowState,
        weeklyAfter: QuotaWindowState,
        records: [String: QuotaNotificationRecord],
        now: Date = Date()
    ) -> [Decision] {
        let wasBlocked = hourlyBefore.isBlocked || weeklyBefore.isBlocked
        let stillBlocked = hourlyAfter.isBlocked || weeklyAfter.isBlocked
        guard wasBlocked, !stillBlocked else { return [] }

        var result: [Decision] = []
        let pairs: [(QuotaNotificationWindow, QuotaWindowState, QuotaWindowState)] = [
            (.hourly, hourlyBefore, hourlyAfter),
            (.weekly, weeklyBefore, weeklyAfter),
        ]
        for (window, before, after) in pairs {
            guard before.isBlocked, after.isUsable, let remaining = after.remaining else { continue }
            let key = QuotaNotificationPolicy.windowKey(for: after.reset)
            let stateKey = "\(accountId):reset:\(window.rawValue)"
            guard QuotaNotificationPolicy.shouldNotify(
                stateKey: stateKey,
                windowKey: key,
                records: records,
                now: now
            ) else { continue }
            result.append(Decision(
                window: window,
                remaining: remaining,
                windowKey: key,
                stateKey: stateKey
            ))
        }
        return result
    }
}

// MARK: - Pool pause (preflight banner)

/// Pool-wide pause state: the pool is not empty and the routing planner pauses
/// every account. Pure, so the banner text, the reset countdown and the lift
/// action share one classification.
struct CodexPoolPauseSummary: Equatable {
    enum Reason: Equatable {
        /// Every pause is caused by the hourly reserve.
        case hourlyReserve
        /// Every pause is caused by the weekly reserve.
        case weeklyReserve
        /// Hourly/weekly reserves and/or exhausted windows are mixed.
        case mixed
        /// Every blocked window has no quota left; no reserve can be lifted.
        case exhausted
    }

    /// Blocked account id → planner cause.
    let causes: [String: CodexBlockCause]
    let reason: Reason
    /// Earliest reset of the windows that caused the pause.
    let resetAt: Date?
    /// At least one pause is a positive reserve with quota still left.
    let canLift: Bool

    /// Builds the summary when (and only when) every account is paused.
    static func make(accounts: [CodexAccount]) -> CodexPoolPauseSummary? {
        guard !accounts.isEmpty else { return nil }
        let resolution = CodexRoutingPlanner.resolve(
            accounts: accounts,
            strategy: .auto,
            manualOrder: []
        )
        guard resolution.blocked.count == accounts.count else { return nil }

        var causes: [String: CodexBlockCause] = [:]
        for account in accounts {
            guard let cause = CodexRoutingPlanner.blockCause(account) else { return nil }
            causes[account.id] = cause
        }

        let reserveCauses = causes.values.filter {
            $0 == .hourlyReserve || $0 == .weeklyReserve
        }
        let reason: Reason
        if reserveCauses.isEmpty {
            reason = .exhausted
        } else if reserveCauses.count == causes.count,
                  causes.values.allSatisfy({ $0 == .hourlyReserve }) {
            reason = .hourlyReserve
        } else if reserveCauses.count == causes.count,
                  causes.values.allSatisfy({ $0 == .weeklyReserve }) {
            reason = .weeklyReserve
        } else {
            reason = .mixed
        }

        var resets: [Date] = []
        var canLift = false
        for account in accounts {
            guard let cause = causes[account.id], let quota = account.quota else { continue }
            switch cause {
            case .hourlyReserve:
                if let reset = quota.hourlyResetAt { resets.append(reset) }
                if (quota.hourlyRemainingPercent ?? 0) > 0,
                   (account.hourlyReservePercent ?? 0) > 0 {
                    canLift = true
                }
            case .weeklyReserve:
                if let reset = quota.weeklyResetAt { resets.append(reset) }
                if (quota.weeklyRemainingPercent ?? 0) > 0,
                   (account.weeklyReservePercent ?? 0) > 0 {
                    canLift = true
                }
            case .hourlyExhausted:
                if let reset = quota.hourlyResetAt { resets.append(reset) }
            case .weeklyExhausted:
                if let reset = quota.weeklyResetAt { resets.append(reset) }
            }
        }

        return CodexPoolPauseSummary(
            causes: causes,
            reason: reason,
            resetAt: resets.min(),
            canLift: canLift
        )
    }
}

/// Codex account management: import, switch, quotas — one shared store for the whole app.
/// Account vault lives in ~/Library/Application Support/MelonTools/codex/accounts.json (0600).
@MainActor
final class CodexStore: ObservableObject {
    static let shared = CodexStore()

    @Published private(set) var accounts: [CodexAccount] = []
    @Published private(set) var currentAccountId: String?
    @Published private(set) var busyAccountIds: Set<String> = []
    @Published private(set) var lastMessage: String?

    /// High-level pool routing mode (persisted). Changing it re-applies the
    /// routing right away: auth files are hot-synced, the gateway needs no restart.
    @Published var routingStrategy: CodexRoutingStrategy = CodexRoutingStrategy.migrate(
        UserDefaults.standard.string(forKey: CodexStore.routingStrategyKey)
            ?? UserDefaults.standard.string(forKey: "gatewayRoutingStrategy")
    ) {
        didSet {
            guard oldValue != routingStrategy else { return }
            UserDefaults.standard.set(routingStrategy.rawValue, forKey: Self.routingStrategyKey)
            applyRoutingIfNeeded(reason: L("routing mode changed"))
        }
    }

    /// Last routing change, shown in the API control card and the mini card.
    @Published private(set) var routingNote: String?

    static let routingStrategyKey = "codexRoutingStrategy"
    private var appliedRoutingSignature = ""

    private let fm = FileManager.default

    // MARK: - Paths

    nonisolated static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MelonTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var codexDir: URL {
        let dir = supportDir.appendingPathComponent("codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var vaultPath: String { Self.codexDir.appendingPathComponent("accounts.json").path }

    var codexAuthPath: String {
        let configured = UserDefaults.standard.string(forKey: "codexHome")
        let home = configured
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath
        return (NSString(string: home).expandingTildeInPath as NSString).appendingPathComponent("auth.json")
    }

    // MARK: - Load / save

    struct Vault: Codable {
        var accounts: [CodexAccount]
        var currentAccountId: String?
    }

    func load() {
        let url = URL(fileURLWithPath: vaultPath)
        if FileManager.default.fileExists(atPath: vaultPath) {
            do {
                let data = try Data(contentsOf: url)
                let vault = try JSONDecoder().decode(Vault.self, from: data)
                accounts = vault.accounts
                currentAccountId = vault.currentAccountId
            } catch {
                // Never let a corrupt file be overwritten by an empty save:
                // back it up so the tokens are recoverable.
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("accounts.corrupt.\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                lastMessage = L("Save failed") + ": " + error.localizedDescription
                    + " (" + backup.lastPathComponent + ")"
            }
        }
        syncPriorityOrder()
        detectCurrent()
        // Older vaults did not persist the pause itself. Rebuild it from a
        // still-fresh reading so a stale gauge cannot lift an existing block.
        if reconcileQuotaBlocks() { save(immediately: true) }
        routingNote = routingNoteText()
    }

    // MARK: - Account priorities (routing order)

    static let priorityOrderKey = "accountPriorityOrder"

    /// Routing order of the pool: position 0 has the highest priority.
    @Published private(set) var priorityOrder: [String] = [] {
        didSet { UserDefaults.standard.set(priorityOrder, forKey: Self.priorityOrderKey) }
    }

    /// Keeps the saved order in sync with the vault: drops removed accounts,
    /// appends new ones at the end.
    func syncPriorityOrder() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.priorityOrderKey) ?? []
        let ids = accounts.map(\.id)
        var order = stored.filter { ids.contains($0) }
        for id in ids where !order.contains(id) { order.append(id) }
        priorityOrder = order
    }

    func moveAccountPriority(_ id: String, up: Bool) {
        guard let index = priorityOrder.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard priorityOrder.indices.contains(target) else { return }
        priorityOrder.swapAt(index, target)
        applyRoutingIfNeeded(reason: L("order changed"))
    }

    func resetPriorityOrder() {
        priorityOrder = accounts.map(\.id)
        applyRoutingIfNeeded(reason: L("order reset"))
    }

    /// Effective routing order for the current strategy plus per-account
    /// limits, “always first” and “backup” roles.
    func routingResolution() -> CodexRoutingPlanner.Resolution {
        CodexRoutingPlanner.resolve(accounts: accounts, strategy: routingStrategy, manualOrder: priorityOrder)
    }

    /// 1-based position of an account in the effective order (nil when unknown).
    func routingPosition(of accountId: String) -> Int? {
        guard let index = routingResolution().orderedIds.firstIndex(of: accountId) else { return nil }
        return index + 1
    }

    /// Gateway priorities: the first account gets the highest value — that is
    /// what the gateway’s “fill-first” mode uses first.
    func effectivePriorities() -> [String: Int] {
        CodexRoutingPlanner.priorities(from: routingResolution().orderedIds)
    }

    /// Banner state: non-nil only while the pool is non-empty and every
    /// account is paused by the routing planner.
    func poolPauseSummary() -> CodexPoolPauseSummary? {
        CodexPoolPauseSummary.make(accounts: accounts)
    }

    /// Lifts reserve pauses that still have quota left: clears the reserve
    /// that causes each pause, saves the vault, hot-syncs a running gateway
    /// and refreshes quotas. Accounts whose window is at 0 stay paused.
    func liftPoolPause() async {
        guard let summary = poolPauseSummary(), summary.canLift else { return }
        var changed = false
        for (id, cause) in summary.causes {
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { continue }
            switch cause {
            case .hourlyReserve:
                guard (accounts[index].quota?.hourlyRemainingPercent ?? 0) > 0 else { continue }
                accounts[index].hourlyReservePercent = nil
                changed = true
            case .weeklyReserve:
                guard (accounts[index].quota?.weeklyRemainingPercent ?? 0) > 0 else { continue }
                accounts[index].weeklyReservePercent = nil
                changed = true
            case .hourlyExhausted, .weeklyExhausted:
                continue
            }
        }
        guard changed else { return }

        save()

        let priorities = effectivePriorities()
        let gateway = CodexGatewayService.shared
        if gateway.isRunning {
            gateway.syncAccountsLive(accounts, priorities: priorities)
            appliedRoutingSignature = routingSignature(priorities: priorities)
        } else {
            appliedRoutingSignature = ""
        }

        await refreshAllQuotas()
        applyRoutingIfNeeded(reason: L("pool pause lifted"))
    }

    /// Saves per-account routing preferences and re-applies the pool order.
    func updateRoutingSettings(_ account: CodexAccount, hourlyPercent: Int?, weeklyPercent: Int?, preferredFirst: Bool, isBackup: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].hourlyReservePercent = (hourlyPercent ?? 0) > 0 ? hourlyPercent : nil
        accounts[index].weeklyReservePercent = (weeklyPercent ?? 0) > 0 ? weeklyPercent : nil
        accounts[index].preferredFirst = preferredFirst ? true : nil
        accounts[index].isBackup = isBackup ? true : nil
        save()
        applyRoutingIfNeeded(reason: L("account settings changed"))
        // A lowered reserve may make a paused account usable immediately.
        Task { await self.enforceQuotaGate(snapshot: nil) }
    }

    /// Pushes the current order to a running gateway when anything changed.
    /// Auth files are hot-reloaded by the gateway, so no restart is needed.
    /// Called after every quota refresh, account change and settings edit.
    func applyRoutingIfNeeded(reason: String) {
        let gateway = CodexGatewayService.shared
        guard gateway.isRunning else {
            appliedRoutingSignature = ""
            return
        }
        let priorities = effectivePriorities()
        let signature = routingSignature(priorities: priorities)
        guard signature != appliedRoutingSignature else { return }
        appliedRoutingSignature = signature
        gateway.syncAccountsLive(accounts, priorities: priorities)
        noteRoutingChange(reason: reason)
    }

    private func routingSignature(priorities: [String: Int]) -> String {
        let ids = accounts.map(\.id).joined(separator: ",")
        let values = priorities.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        // Tokens are written into the auth files, so a token refresh must
        // reach the gateway. Availability is deliberately absent: pauses go
        // through the management PATCH and must not trigger a full rewrite.
        let credentials = accounts.map { account in
            account.id + ":" + (account.lastRefresh ?? "")
        }.joined(separator: ",")
        return ids + "|" + values + "|" + credentials
    }

    private func routingNoteText() -> String? {
        let resolution = routingResolution()
        guard let firstId = resolution.orderedIds.first,
              let first = accounts.first(where: { $0.id == firstId }) else { return nil }
        if let blockedId = resolution.orderedIds.first(where: { resolution.blocked.contains($0) }),
           let blocked = accounts.first(where: { $0.id == blockedId }),
           let blockReason = resolution.blockReasons[blockedId] {
            return String(format: L("Routing: %@ is paused (%@) — %@ goes first."), blocked.displayName, blockReason, first.displayName)
        }
        return String(format: L("Routing: %@ goes first."), first.displayName)
    }

    private func noteRoutingChange(reason: String) {
        guard let note = routingNoteText() else { return }
        routingNote = note
        CodexGatewayService.shared.auditLog("\(note) · \(reason)")
    }

    private var saveTask: Task<Void, Never>?

    /// Persist the vault. Live quota readings arrive several times per second
    /// and are coalesced for two seconds; every user action and every block
    /// transition still writes immediately.
    private func save(immediately: Bool = true) {
        if !immediately {
            guard saveTask == nil else { return }
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                self?.flushSave()
            }
            return
        }
        saveTask?.cancel()
        saveTask = nil
        flushSave()
    }

    func flushSave() {
        let vault = Vault(accounts: accounts, currentAccountId: currentAccountId)
        do {
            let data = try JSONEncoder.pretty.encode(vault)
            try SecureFile.write(data, to: URL(fileURLWithPath: vaultPath))
        } catch {
            lastMessage = L("Save failed") + ": \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    /// Import the account currently logged into the Codex CLI (~/.codex/auth.json).
    @discardableResult
    func importFromCodexCLI() -> CodexAccount? {
        guard let auth = try? CodexAuthFile.load(from: codexAuthPath), let tokens = auth.tokens else {
            lastMessage = L("No Codex CLI login found — use browser or device login.")
            return nil
        }
        let claims = JWT.codexClaims(idToken: tokens.id_token)
        let account = CodexAccount(
            email: claims.email,
            planType: claims.planType,
            accountId: claims.accountId ?? tokens.account_id,
            userId: claims.userId,
            subscriptionActiveUntil: claims.subscriptionUntil,
            tokens: tokens,
            lastRefresh: auth.last_refresh
        )
        upsert(account)
        // upsert may merge into an existing record and keep its stable id.
        currentAccountId = accounts.first {
            ($0.accountId != nil && $0.accountId == account.accountId)
                || ($0.email != nil && $0.email == account.email)
        }?.id ?? account.id
        save()
        applyRoutingIfNeeded(reason: L("account added"))
        lastMessage = L("Imported") + " \(account.displayName)"
        return account
    }

    /// Add an account from a pasted auth.json payload (string).
    @discardableResult
    func importFromJSON(_ text: String) -> CodexAccount? {
        guard let data = text.data(using: .utf8),
              let auth = try? JSONDecoder().decode(CodexAuthFile.self, from: data),
              let tokens = auth.tokens, tokens.access_token != nil || tokens.refresh_token != nil else {
            lastMessage = L("That JSON is not a Codex login file (tokens missing)")
            return nil
        }
        let claims = JWT.codexClaims(idToken: tokens.id_token)
        let account = CodexAccount(
            email: claims.email,
            planType: claims.planType,
            accountId: claims.accountId ?? tokens.account_id,
            userId: claims.userId,
            subscriptionActiveUntil: claims.subscriptionUntil,
            tokens: tokens,
            lastRefresh: auth.last_refresh
        )
        upsert(account)
        save()
        applyRoutingIfNeeded(reason: L("account added"))
        lastMessage = L("Imported") + " \(account.displayName)"
        return account
    }

    /// Insert or merge (by accountId/email) into the vault.
    private func upsert(_ account: CodexAccount) {
        if let idx = accounts.firstIndex(where: {
            ($0.accountId != nil && $0.accountId == account.accountId) ||
            ($0.email != nil && $0.email == account.email)
        }) {
            let old = accounts[idx]
            var merged = account
            merged.id = old.id // keep stable id
            merged.quota = old.quota
            merged.quotaUpdatedAt = old.quotaUpdatedAt
            merged.note = old.note
            merged.hourlyReservePercent = old.hourlyReservePercent
            merged.weeklyReservePercent = old.weeklyReservePercent
            merged.preferredFirst = old.preferredFirst
            merged.isBackup = old.isBackup
            merged.subscriptionUpdatedAt = old.subscriptionUpdatedAt
            accounts[idx] = merged
        } else {
            accounts.append(account)
        }
    }

    // MARK: - Current account detection / switch

    func detectCurrent() {
        guard let auth = try? CodexAuthFile.load(from: codexAuthPath), let tokens = auth.tokens else {
            currentAccountId = nil
            return
        }
        let claims = JWT.codexClaims(idToken: tokens.id_token)
        if let match = accounts.first(where: {
            ($0.accountId != nil && $0.accountId == (claims.accountId ?? tokens.account_id)) ||
            (claims.email != nil && $0.email == claims.email)
        }) {
            currentAccountId = match.id
        } else {
            currentAccountId = nil
        }
    }

    /// Write the account's tokens into ~/.codex/auth.json, backing up the previous file.
    func switchTo(_ account: CodexAccount) async {
        let backupPath = codexAuthPath + ".melon-backup"
        do {
            if fm.fileExists(atPath: codexAuthPath) {
                try? fm.removeItem(atPath: backupPath)
                try fm.copyItem(atPath: codexAuthPath, toPath: backupPath)
                // The backup carries tokens — never leave it world-readable.
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
            }
            let auth = CodexAuthFile.make(from: account)
            let data = try auth.encoded()
            let authURL = URL(fileURLWithPath: codexAuthPath)
            try SecureFile.write(data, to: authURL)

            currentAccountId = account.id
            save()
            lastMessage = L("Switched to") + " \(account.displayName) " + L("— the previous login is kept as a backup.")
        } catch {
            lastMessage = L("Switch failed") + ": \(error.localizedDescription)"
        }
    }

    // MARK: - Device login

    @Published private(set) var deviceSession: CodexService.DeviceLoginSession?
    @Published private(set) var deviceLoginStatus: String = ""
    private var devicePollTask: Task<Void, Never>?

    func startDeviceLogin() {
        guard devicePollTask == nil else { return }
        deviceLoginStatus = L("Requesting device code…")
        devicePollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await CodexService.startDeviceLogin()
                self.deviceSession = session
                self.deviceLoginStatus = L("Enter the code at") + " \(session.verificationURL)"
                if let url = URL(string: session.verificationURL) {
                    NSWorkspace.shared.open(url)
                }
                var failures = 0
                while !Task.isCancelled {
                    let interval = max(1, session.interval)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                        if let tokens = try await CodexService.pollDeviceLogin(session: session) {
                            let name = self.completeLogin(tokens)
                            self.deviceLoginStatus = String(format: L("Logged in as %@"), name)
                            self.deviceSession = nil
                            self.devicePollTask = nil
                            return
                        }
                        failures = 0
                    } catch {
                        if Task.isCancelled { return }
                        failures += 1
                        // Transient network errors must not kill the whole
                        // login, but an endless retry loop is worse: give up
                        // after 30 consecutive failures (~5 min).
                        guard failures < 30 else {
                            self.deviceLoginStatus = L("Login failed: ") + error.localizedDescription
                            self.deviceSession = nil
                            self.devicePollTask = nil
                            return
                        }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            } catch {
                self.deviceLoginStatus = L("Login failed: ") + error.localizedDescription
                self.devicePollTask = nil
            }
        }
    }

    func cancelDeviceLogin() {
        devicePollTask?.cancel()
        devicePollTask = nil
        deviceSession = nil
        deviceLoginStatus = ""
    }

    // MARK: - Browser login (PKCE + loopback)

    @Published private(set) var browserLoginActive = false
    @Published private(set) var browserLoginStatus: String = ""
    private var browserTask: Task<Void, Never>?
    private var loopback: LoopbackServer?

    func startBrowserLogin() {
        guard browserTask == nil else { return }
        browserLoginActive = true
        browserLoginStatus = L("Opening browser…")
        browserTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let pkce = CodexService.makePKCE() else {
                    throw CodexService.CodexError.decoding("PKCE generation failed")
                }
                let server = LoopbackServer()
                self.loopback = server
                let port = try await server.start(expectedState: pkce.state)
                let redirect = "http://localhost:\(port)/auth/callback"
                let url = CodexService.authorizationURL(challenge: pkce.challenge, state: pkce.state, redirectURI: redirect)
                self.browserLoginStatus = L("Complete sign-in in the browser…")
                NSWorkspace.shared.open(url)
                let code = try await server.waitForCode()
                self.browserLoginStatus = L("Exchanging the code…")
                let tokens = try await CodexService.exchangeCode(code: code, verifier: pkce.verifier, redirectURI: redirect)
                let name = self.completeLogin(tokens)
                self.browserLoginStatus = String(format: L("Logged in as %@"), name)
                self.browserLoginActive = false
                self.loopback = nil
                self.browserTask = nil
            } catch {
                self.browserLoginStatus = L("Login failed: ") + error.localizedDescription
                self.browserLoginActive = false
                self.loopback = nil
                self.browserTask = nil
            }
        }
    }

    func cancelBrowserLogin() {
        loopback?.cancel()
        loopback = nil
        browserTask?.cancel()
        browserTask = nil
        browserLoginActive = false
        browserLoginStatus = ""
    }

    /// Shared tail of both login flows: claims → vault → quota refresh.
    private func completeLogin(_ tokens: CodexTokens) -> String {
        let claims = JWT.codexClaims(idToken: tokens.id_token)
        let account = CodexAccount(
            email: claims.email,
            planType: claims.planType,
            accountId: claims.accountId ?? tokens.account_id,
            userId: claims.userId,
            subscriptionActiveUntil: claims.subscriptionUntil,
            tokens: tokens,
            lastRefresh: ISO8601DateFormatter().string(from: Date())
        )
        upsert(account)
        save()
        applyRoutingIfNeeded(reason: L("account added"))
        let resolved = accounts.first(where: {
            ($0.accountId != nil && $0.accountId == account.accountId) ||
            ($0.email != nil && $0.email == account.email)
        }) ?? account
        Task { await refreshQuota(for: resolved.id) }
        return resolved.displayName
    }

    // MARK: - Quota

    private var quotaTimer: Timer?
    private var quotaRefreshTask: Task<Void, Never>?
    /// Combine newly-low accounts found by a bulk refresh into one notification.
    private var isCollectingLowQuotaNotifications = false
    private var pendingLowQuotaNotifications: [String: String] = [:]
    /// 1–2 second guard over the gateway's passive quota headers. This is the
    /// primary source for reserve pauses; `/wham/usage` stays the fallback.
    private var liveQuotaTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Prevents App Nap from coalescing the 1.5-second guard when the window
    /// is closed. Idle system sleep stays allowed.
    private var liveQuotaActivity: NSObjectProtocol?
    private var lastResetProbe: [String: Date] = [:]
    private var resetProbeFailures: [String: Int] = [:]

    /// When the bulk quota refresh last ran — the adaptive scheduler uses it
    /// to throttle itself while the gateway is under load.
    private var lastQuotaRefreshAt: Date?

    /// Periodic quota refresh. Interval comes from settings (default 5 min, 0 = off).
    func startQuotaScheduler() {
        quotaTimer?.invalidate()
        quotaTimer = nil
        startLiveQuotaGuard()
        let interval = UserDefaults.standard.object(forKey: "quotaRefreshInterval") as? Int ?? 300
        guard interval > 0 else { return }
        // `/wham/usage` is the slower fallback and reset probe. Reserve
        // enforcement itself runs on the 1.5-second live guard below.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard CodexGatewayService.shared.isRunning else { return }
                let elapsed = Date().timeIntervalSince(self.lastQuotaRefreshAt ?? .distantPast)
                let due = elapsed >= Double(interval)
                let urgent = CodexGatewayService.shared.requestsLastMinute > 0 && elapsed >= 30
                guard due || urgent else { return }
                await self.refreshAllQuotas()
            }
        }
        timer.tolerance = 3.0
        RunLoop.main.add(timer, forMode: .common)
        quotaTimer = timer
    }

    /// Starts the live guard once. It is independent of the `/wham/usage`
    /// interval so turning that interval off cannot silently disable reserves.
    private func startLiveQuotaGuard() {
        guard liveQuotaTask == nil else { return }
        if liveQuotaActivity == nil {
            liveQuotaActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Live Codex quota enforcement"
            )
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastResetProbe.removeAll()
                    self.resetProbeFailures.removeAll()
                    await self.liveQuotaTick()
                }
            }
        }
        liveQuotaTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.liveQuotaTick()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// One live pass: merge passive quota headers, reconcile sticky pauses,
    /// and probe accounts whose reset time has passed.
    private func liveQuotaTick() async {
        let gateway = CodexGatewayService.shared
        guard gateway.isRunning else { return }
        guard !accounts.isEmpty else { return }
        let snapshot = await gateway.fetchManagementAuths()
        if let snapshot {
            mergeLiveQuota(snapshot)
        }
        await enforceQuotaGate(snapshot: snapshot)
        await probeBlockedResets(snapshot: snapshot)
    }

    private func mergeLiveQuota(_ snapshot: CodexManagementSnapshot) {
        let files = snapshot.codexFiles
        guard !files.isEmpty else { return }
        var changed = false
        for index in accounts.indices {
            let account = accounts[index]
            guard account.tokens.access_token?.isEmpty == false else { continue }
            guard let file = liveFile(for: account, in: files),
                  let signals = file.quota?.signals, !signals.isEmpty else { continue }
            let observed = file.quota?.observedAt ?? snapshot.observedAt
            guard let observed else { continue }
            // A stale passive signal must never overwrite a newer usage read.
            if let cached = accounts[index].quotaUpdatedAt,
               observed < cached.addingTimeInterval(-0.5),
               accounts[index].quotaSource == "usage" {
                continue
            }
            guard let reading = CodexLiveQuota.parse(signals: signals, observedAt: observed) else {
                continue
            }
            accounts[index].quota = CodexLiveQuota.merging(reading, into: accounts[index].quota)
            accounts[index].quotaUpdatedAt = observed
            accounts[index].quotaSource = "gateway"
            accounts[index].quotaError = nil
            if let plan = reading.quota.planType { accounts[index].planType = plan }
            changed = true
        }
        if changed { save(immediately: false) }
    }

    private func liveFile(for account: CodexAccount, in files: [CodexManagementAuthFile]) -> CodexManagementAuthFile? {
        let expected = CodexGatewayService.authFileName(for: account)
        if let exact = files.first(where: { $0.name == expected }) { return exact }
        guard let email = account.email?.lowercased(), !email.isEmpty else { return nil }
        let matches = files.filter { ($0.email ?? "").lowercased() == email }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Creates and clears sticky pauses from the cached readings. Pure state
    /// changes only; the caller persists them and then touches the gateway.
    @discardableResult
    private func reconcileQuotaBlocks(now: Date = Date()) -> Bool {
        var mutated = false
        for index in accounts.indices {
            let account = accounts[index]
            if let block = account.quotaBlock {
                if !reserveStillApplies(block.cause, account: account) {
                    accounts[index].quotaBlock = nil
                    mutated = true
                    continue
                }
                var effectiveBlock = block
                switch block.cause {
                case .hourlyReserve: effectiveBlock.thresholdPercent = account.hourlyReservePercent
                case .weeklyReserve: effectiveBlock.thresholdPercent = account.weeklyReservePercent
                case .hourlyExhausted, .weeklyExhausted: break
                }
                if effectiveBlock != block {
                    accounts[index].quotaBlock = effectiveBlock
                    mutated = true
                }
                guard quotaIsActionable(account), let quota = account.quota else { continue }
                if CodexRoutingPlanner.blockRecovered(
                    effectiveBlock,
                    quota: quota,
                    hourlyReserve: account.hourlyReservePercent,
                    weeklyReserve: account.weeklyReservePercent,
                    isFresh: true
                ) {
                    accounts[index].quotaBlock = nil
                    mutated = true
                    // Another window may still be exhausted (for example, the
                    // 5-hour reset arrives while the weekly window is at 0).
                    // Replace the pause instead of enabling for one tick.
                    if let next = CodexRoutingPlanner.quotaBlockCause(
                        quota: quota,
                        hourlyReserve: account.hourlyReservePercent,
                        weeklyReserve: account.weeklyReservePercent,
                        isFresh: true
                    ), let replacement = blockState(account: account, cause: next, quota: quota, now: now) {
                        accounts[index].quotaBlock = replacement
                    }
                }
                continue
            }
            guard quotaIsActionable(account), let quota = account.quota else { continue }
            guard let cause = CodexRoutingPlanner.quotaBlockCause(
                quota: quota,
                hourlyReserve: account.hourlyReservePercent,
                weeklyReserve: account.weeklyReservePercent,
                isFresh: true
            ), let block = blockState(account: account, cause: cause, quota: quota, now: now) else { continue }
            accounts[index].quotaBlock = block
            mutated = true
        }
        return mutated
    }

    private func blockState(
        account: CodexAccount,
        cause: CodexBlockCause,
        quota: CodexQuota,
        now: Date
    ) -> CodexQuotaBlock? {
        let remaining: Double?
        let reset: Date?
        switch cause {
        case .hourlyExhausted, .hourlyReserve:
            remaining = quota.hourlyRemainingPercent
            reset = quota.hourlyResetAt
        case .weeklyExhausted, .weeklyReserve:
            remaining = quota.weeklyRemainingPercent
            reset = quota.weeklyResetAt
        }
        guard let remaining else { return nil }
        let threshold: Int?
        switch cause {
        case .hourlyReserve: threshold = account.hourlyReservePercent
        case .weeklyReserve: threshold = account.weeklyReservePercent
        case .hourlyExhausted, .weeklyExhausted: threshold = nil
        }
        return CodexQuotaBlock(
            cause: cause,
            remainingPercent: remaining,
            thresholdPercent: threshold,
            resetAt: reset,
            blockedAt: now,
            source: account.quotaSource
        )
    }

    /// Applies exact reserve decisions and keeps the gateway's `disabled`
    /// flags aligned. Blocks are persisted before the auth file changes.
    private func enforceQuotaGate(snapshot: CodexManagementSnapshot?) async {
        let gateway = CodexGatewayService.shared
        guard gateway.isRunning else { return }
        let mutated = reconcileQuotaBlocks()
        if mutated { save(immediately: true) }

        let files: [CodexManagementAuthFile]
        if let snapshot {
            files = snapshot.codexFiles
        } else {
            files = (await gateway.fetchManagementAuths()?.codexFiles) ?? []
        }
        guard !files.isEmpty else {
            if mutated { gateway.syncAccountsLive(accounts, priorities: effectivePriorities()) }
            return
        }
        var fallback = false
        for account in accounts {
            guard account.tokens.access_token?.isEmpty == false else { continue }
            guard let file = liveFile(for: account, in: files) else {
                if account.quotaBlock != nil { fallback = true }
                continue
            }
            // Preserve a legacy disabled file until a fresh reading proves
            // that it can be re-enabled. A stale cache must never lift it.
            let desired = account.quotaBlock != nil
                || (file.disabled && account.quotaBlock == nil && !quotaIsActionable(account))
            guard file.disabled != desired else { continue }
            let ok = await gateway.setManagementAuthDisabled(
                name: file.name,
                authIndex: file.authIndex,
                disabled: desired
            )
            if !ok { fallback = true }
        }
        if fallback {
            gateway.syncAccountsLive(accounts, priorities: effectivePriorities())
            appliedRoutingSignature = routingSignature(priorities: effectivePriorities())
        }
    }

    /// `/wham/usage` remains believable for 30 minutes; a passive gateway
    /// header only for two minutes. Stale data cannot create or lift a pause.
    private func quotaIsActionable(_ account: CodexAccount) -> Bool {
        guard let updated = account.quotaUpdatedAt else { return false }
        if account.quotaSource == "gateway" {
            return CodexLiveQuota.isFresh(updated)
        }
        return Date().timeIntervalSince(updated) < CodexRoutingPlanner.quotaFreshness
    }

    private func reserveStillApplies(_ cause: CodexBlockCause, account: CodexAccount) -> Bool {
        switch cause {
        case .hourlyReserve: return (account.hourlyReservePercent ?? 0) > 0
        case .weeklyReserve: return (account.weeklyReservePercent ?? 0) > 0
        case .hourlyExhausted, .weeklyExhausted: return true
        }
    }

    /// When the 5-hour window resets, the gateway has no passive header to
    /// tell us: disabled accounts serve no traffic. Probe `/wham/usage` just
    /// after the known reset, with backoff, then unblock on a fresh reading.
    private func probeBlockedResets(snapshot: CodexManagementSnapshot?) async {
        let now = Date()
        for account in accounts {
            let fileDisabled = snapshot.flatMap { snap in
                liveFile(for: account, in: snap.codexFiles)?.disabled
            }
            let mustProbe: Bool
            if let block = account.quotaBlock {
                if let reset = block.resetAt {
                    mustProbe = now >= reset
                } else {
                    mustProbe = now.timeIntervalSince(block.blockedAt) >= 60
                }
            } else if fileDisabled == true {
                // A disabled auth file without a persisted block can be a
                // leftover from an older build. Verify it before enabling.
                mustProbe = !quotaIsActionable(account)
            } else {
                mustProbe = false
            }
            guard mustProbe else { continue }
            let failures = resetProbeFailures[account.id] ?? 0
            let delay = min(60, 8 * Double(max(1, failures)))
            if let next = lastResetProbe[account.id], now < next { continue }
            lastResetProbe[account.id] = now.addingTimeInterval(delay)
            guard !busyAccountIds.contains(account.id) else { continue }
            await refreshQuota(for: account.id)
            if accounts.first(where: { $0.id == account.id })?.quotaError == nil {
                resetProbeFailures[account.id] = 0
            } else {
                resetProbeFailures[account.id] = min(8, failures + 1)
            }
        }
    }

    func refreshQuota(for accountId: String, forceTokens: Bool = false) async {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        // Timer, Accounts, Providers and Composer can all request a refresh.
        // Never rotate the same refresh token concurrently.
        guard !busyAccountIds.contains(accountId) else { return }
        busyAccountIds.insert(accountId)
        defer { busyAccountIds.remove(accountId) }

        var account = accounts[idx]
        let beforeHourly = QuotaWindowState(
            remaining: account.quota?.hourlyRemainingPercent,
            reset: account.quota?.hourlyResetAt,
            reservePercent: account.hourlyReservePercent
        )
        let beforeWeekly = QuotaWindowState(
            remaining: account.quota?.weeklyRemainingPercent,
            reset: account.quota?.weeklyResetAt,
            reservePercent: account.weeklyReservePercent
        )
        do {
            if forceTokens || account.needsRefresh {
                // A forced refresh re-reads the id_token claims — that is how a
                // just-renewed subscription becomes visible without waiting for
                // the token to age out.
                let tokens = try await CodexService.refreshTokens(account)
                account.tokens = tokens
                account.lastRefresh = ISO8601DateFormatter().string(from: Date())
                let claims = JWT.codexClaims(idToken: tokens.id_token)
                account.email = claims.email ?? account.email
                account.planType = claims.planType ?? account.planType
                account.accountId = claims.accountId ?? tokens.account_id ?? account.accountId
                // The claim can be stale (OpenAI caches subscription checks) —
                // fill only a missing date; the backend fetch below is
                // authoritative and runs in the same pass.
                if account.subscriptionActiveUntil == nil, let until = claims.subscriptionUntil, !until.isEmpty {
                    account.subscriptionActiveUntil = until
                }
            }
            let quotaResult = try await CodexService.fetchQuota(account: account)
            if account.tokens.access_token != quotaResult.tokens.access_token {
                account.tokens = quotaResult.tokens
                account.lastRefresh = ISO8601DateFormatter().string(from: Date())
            }
            var quota = quotaResult.quota
            // Subscription end date: the backend value is authoritative and is
            // re-read every 30 minutes — or immediately when a paid plan's
            // stored period has ended (that combination means "renewed, but
            // the date has not caught up yet").
            let subscriptionAge = account.subscriptionUpdatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let storedUntil = account.subscriptionActiveUntil.flatMap { ISO8601DateFormatter().date(from: $0) }
            let storedPlan = (account.planType ?? "").lowercased()
            let paidPlan = !storedPlan.isEmpty && storedPlan != "free"
            let needsSubscriptionCheck = account.subscriptionActiveUntil == nil
                || subscriptionAge >= 1800
                || (paidPlan && storedUntil.map { $0 < Date() } == true)
            if needsSubscriptionCheck {
                if let subscription = try? await CodexService.fetchSubscription(account: account) {
                    if let until = subscription.activeUntil, !until.isEmpty {
                        account.subscriptionActiveUntil = until
                    }
                    if let plan = subscription.plan, !plan.isEmpty {
                        account.planType = plan
                    }
                    account.subscriptionUpdatedAt = Date()
                }
            }
            // Reset-credit detail only matters while some resets are available.
            if (quota.resetCreditsAvailable ?? 0) > 0 {
                if let resets = try? await CodexService.fetchResetCredits(account: account) {
                    quota.resetCreditsNextExpiry = resets.nextExpiry
                    if let available = resets.available {
                        quota.resetCreditsAvailable = available
                    }
                }
            }
            account.quota = quota
            account.quotaUpdatedAt = Date()
            account.quotaError = nil
            account.quotaSource = "usage"
            if let plan = quota.planType { account.planType = plan }
            if let idx = accounts.firstIndex(where: { $0.id == accountId }) {
                // Merge only fetched fields: a stale snapshot must not erase
                // reserves, preferred/backup flags or subscription edits.
                var merged = accounts[idx]
                merged.tokens = account.tokens
                merged.lastRefresh = account.lastRefresh
                merged.email = account.email
                merged.planType = account.planType
                merged.accountId = account.accountId
                merged.subscriptionActiveUntil = account.subscriptionActiveUntil
                merged.subscriptionUpdatedAt = account.subscriptionUpdatedAt
                merged.quota = account.quota
                merged.quotaUpdatedAt = account.quotaUpdatedAt
                merged.quotaError = nil
                merged.quotaSource = account.quotaSource
                accounts[idx] = merged
            }
            save(immediately: false)
            QuotaHistoryStore.shared.record(
                QuotaHistorySample(
                    at: Date(),
                    hourly: account.quota?.hourlyRemainingPercent,
                    weekly: account.quota?.weeklyRemainingPercent
                ),
                for: accountId
            )
            maybeNotifyQuotaReset(
                account: account,
                beforeHourly: beforeHourly,
                beforeWeekly: beforeWeekly
            )
            maybeNotifyLowQuota(account)
            // Clear a recovered pause immediately so the UI and the next
            // routing read do not wait for the 1.5-second live tick.
            if reconcileQuotaBlocks() { save(immediately: true) }
            applyRoutingIfNeeded(reason: L("quota refreshed"))
            return
        } catch {
            account.quotaError = error.localizedDescription
        }
        if let idx = accounts.firstIndex(where: { $0.id == accountId }) {
            var merged = accounts[idx]
            merged.quotaError = account.quotaError
            accounts[idx] = merged
        }
        save(immediately: false)
        applyRoutingIfNeeded(reason: L("quota refreshed"))
    }

    func refreshAllQuotas(forceTokens: Bool = false) async {
        // Coalesce timer/manual requests. A second caller waits for the
        // in-flight pass instead of starting a parallel token rotation.
        if let existing = quotaRefreshTask {
            await existing.value
            return
        }
        isCollectingLowQuotaNotifications = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isCollectingLowQuotaNotifications = false
                self.postPendingLowQuotaNotification()
            }
            self.lastQuotaRefreshAt = Date()
            for account in self.accounts {
                await self.refreshQuota(for: account.id, forceTokens: forceTokens)
            }
        }
        quotaRefreshTask = task
        await task.value
        quotaRefreshTask = nil
    }

    private static let notificationRecordsKey = "quotaNotificationRecords"

    /// Persisted per account/window bookkeeping. Low-quota markers remain set
    /// until that window recovers above its threshold.
    private var notificationRecords: [String: QuotaNotificationRecord] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.notificationRecordsKey),
                  let records = try? JSONDecoder().decode([String: QuotaNotificationRecord].self, from: data) else {
                return [:]
            }
            return records
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.notificationRecordsKey)
        }
    }

    /// One notification per account/window when a blocked or exhausted
    /// account becomes usable again after a quota refresh. The persisted
    /// reset marker suppresses repeats of the same reset window.
    private func maybeNotifyQuotaReset(
        account: CodexAccount,
        beforeHourly: QuotaWindowState,
        beforeWeekly: QuotaWindowState
    ) {
        guard UserDefaults.standard.bool(forKey: "quotaNotifications") else { return }
        guard let quota = account.quota else { return }

        let afterHourly = QuotaWindowState(
            remaining: quota.hourlyRemainingPercent,
            reset: quota.hourlyResetAt,
            reservePercent: account.hourlyReservePercent
        )
        let afterWeekly = QuotaWindowState(
            remaining: quota.weeklyRemainingPercent,
            reset: quota.weeklyResetAt,
            reservePercent: account.weeklyReservePercent
        )
        var records = notificationRecords
        let now = Date()
        let decisions = QuotaResetNotificationPolicy.decisions(
            accountId: account.id,
            hourlyBefore: beforeHourly,
            hourlyAfter: afterHourly,
            weeklyBefore: beforeWeekly,
            weeklyAfter: afterWeekly,
            records: records,
            now: now
        )
        guard !decisions.isEmpty else { return }

        for decision in decisions {
            records[decision.stateKey] = QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: decision.windowKey
            )
            let windowLabel: String
            switch decision.window {
            case .hourly: windowLabel = L("hourly")
            case .weekly: windowLabel = L("weekly")
            }
            MTNotificationCenter.post(
                title: L("Codex quota reset"),
                body: "\(account.displayName): \(windowLabel) \(Int(decision.remaining.rounded()))%",
                identifier: "quota-reset-\(decision.stateKey)-\(Int(now.timeIntervalSince1970))"
            )
        }
        notificationRecords = records
    }

    /// One notification per account/window when the remaining quota reaches
    /// the configured reserve threshold (weekly defaults to 10 %). Called only
    /// after a successful quota refresh.
    private func maybeNotifyLowQuota(_ account: CodexAccount) {
        guard UserDefaults.standard.bool(forKey: "quotaNotifications") else { return }
        guard let quota = account.quota else { return }

        let storedRecords = notificationRecords
        var records = QuotaNotificationPolicy.recordsAfterRecovery(
            accountId: account.id,
            hourlyRemaining: quota.hourlyRemainingPercent,
            hourlyReservePercent: account.hourlyReservePercent,
            weeklyRemaining: quota.weeklyRemainingPercent,
            weeklyReservePercent: account.weeklyReservePercent,
            records: storedRecords
        )
        let decisions = QuotaNotificationPolicy.decisions(
            accountId: account.id,
            hourlyRemaining: quota.hourlyRemainingPercent,
            hourlyReset: quota.hourlyResetAt,
            hourlyReservePercent: account.hourlyReservePercent,
            weeklyRemaining: quota.weeklyRemainingPercent,
            weeklyReset: quota.weeklyResetAt,
            weeklyReservePercent: account.weeklyReservePercent,
            records: records
        )
        guard !decisions.isEmpty else {
            if records != storedRecords { notificationRecords = records }
            return
        }

        let now = Date()
        for decision in decisions {
            records[decision.stateKey] = QuotaNotificationRecord(
                notifiedAt: now,
                windowKey: decision.windowKey
            )
            let windowLabel: String
            switch decision.window {
            case .hourly: windowLabel = L("hourly")
            case .weekly: windowLabel = L("weekly")
            }
            pendingLowQuotaNotifications[decision.stateKey] =
                "\(account.displayName): \(windowLabel) \(Int(decision.remaining.rounded()))%"
        }
        notificationRecords = records
        if !isCollectingLowQuotaNotifications {
            postPendingLowQuotaNotification()
        }
    }

    /// Deliver one summary for all newly-low accounts found in this refresh
    /// pass. Retain the first few details so the notification stays readable.
    private func postPendingLowQuotaNotification() {
        guard !pendingLowQuotaNotifications.isEmpty else { return }
        let details = pendingLowQuotaNotifications.values.sorted()
        pendingLowQuotaNotifications.removeAll()

        let visibleDetails = Array(details.prefix(4))
        var body = visibleDetails.joined(separator: "\n")
        if details.count > visibleDetails.count {
            body += "\n\(String(format: L("+%d more"), details.count - visibleDetails.count))"
        }
        MTNotificationCenter.post(
            title: L("Low Codex quota"),
            body: body,
            identifier: "low-codex-quota-\(Int(Date().timeIntervalSince1970))"
        )
    }

    // MARK: - Launch in Codex

    /// Launch the Codex app on the gateway — the account pool routes every
    /// account, so this opens the app itself with the current routing instead
    /// of a per-account CLI instance in Terminal (instances live in
    /// Codex → Instances).
    func launchInCodex(_ account: CodexAccount) {
        lastMessage = String(format: L("Launching the Codex app: %@"), account.displayName)
        CodexGatewayService.shared.launchThroughGateway()
    }

    // MARK: - Mutations

    func remove(_ account: CodexAccount) {
        let wasCurrent = currentAccountId == account.id
        accounts.removeAll { $0.id == account.id }
        if wasCurrent {
            currentAccountId = nil
            // Removing the active account must not leave its Codex login and
            // backup behind. The caller already showed a destructive confirm.
            try? FileManager.default.removeItem(atPath: codexAuthPath)
            try? FileManager.default.removeItem(atPath: codexAuthPath + ".melon-backup")
        }
        QuotaHistoryStore.shared.remove(account.id)
        var records = notificationRecords
        let prefix = account.id + ":"
        records = records.filter { !$0.key.hasPrefix(prefix) }
        notificationRecords = records
        save()
        applyRoutingIfNeeded(reason: L("account removed"))
    }

    func setNote(_ account: CodexAccount, note: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].note = note.isEmpty ? nil : note
        save()
    }
}
