import Foundation
import SwiftUI

// MARK: - Pure dashboard helpers

/// `@AppStorage` keys shared by the dashboard and the settings toggles.
enum DashboardWidgetKey {
    static let poolHealth = "dashboard.showPoolHealth"
    static let quotaTrends = "dashboard.showQuotaTrends"
    static let spend = "dashboard.showSpend"
    static let scheduler = "dashboard.showScheduler"
}

/// Pool counters and averages. Paused is the routing planner's decision, so
/// stale quota readings never park an account in the overview.
struct DashboardPoolHealth: Equatable {
    var total = 0
    var usable = 0
    var paused = 0
    var errors = 0
    var hourlyAverage: Double?
    var weeklyAverage: Double?

    static func make(accounts: [CodexAccount]) -> DashboardPoolHealth {
        var health = DashboardPoolHealth()
        health.total = accounts.count
        health.usable = accounts.filter { CodexRoutingPlanner.blockReason($0) == nil }.count
        health.paused = health.total - health.usable
        health.errors = accounts.filter { $0.quotaError != nil }.count
        health.hourlyAverage = DashboardMetrics.average(
            accounts.compactMap(\.quota?.hourlyRemainingPercent)
        )
        health.weeklyAverage = DashboardMetrics.average(
            accounts.compactMap(\.quota?.weeklyRemainingPercent)
        )
        return health
    }
}

struct DashboardQuotaTotals: Equatable {
    var hourly: Double?
    var weekly: Double?
    var max: Double
}

enum DashboardMetrics {
    static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Current pool totals, not history averages. The denominator is the
    /// number of accounts in the pool, so five accounts at 100% read 500%.
    static func quotaTotals(accounts: [CodexAccount]) -> DashboardQuotaTotals {
        let hourlyValues = accounts.compactMap(\.quota?.hourlyRemainingPercent)
        let weeklyValues = accounts.compactMap(\.quota?.weeklyRemainingPercent)
        return DashboardQuotaTotals(
            hourly: hourlyValues.isEmpty ? nil : hourlyValues.reduce(0, +),
            weekly: weeklyValues.isEmpty ? nil : weeklyValues.reduce(0, +),
            max: Double(accounts.count) * 100
        )
    }

    static func poolHealth(accounts: [CodexAccount]) -> DashboardPoolHealth {
        DashboardPoolHealth.make(accounts: accounts)
    }

    static func dueCount(tasks: [SchedulerTask], now: Date = Date()) -> Int {
        SchedulerPolicy.due(tasks, now: now).count
    }

    /// Earliest armed schedule; a past timestamp still counts (the task is due
    /// and the next tick will run it).
    static func nextRun(tasks: [SchedulerTask]) -> Date? {
        tasks.compactMap { task -> Date? in
            guard task.enabled, let stamp = task.nextRunAt else { return nil }
            return Date(timeIntervalSince1970: stamp)
        }.min()
    }

    /// Newest history entry wins; otherwise the most recently run task.
    static func lastStatus(
        tasks: [SchedulerTask],
        history: [SchedulerHistoryEntry]
    ) -> SchedulerTaskStatus? {
        if let newest = history.first { return newest.status }
        let ran = tasks.compactMap { task -> SchedulerTask? in
            task.lastRunAt == nil ? nil : task
        }
        return ran.max { ($0.lastRunAt ?? 0) < ($1.lastRunAt ?? 0) }?.lastStatus
    }
}

/// Aggregate quota history across all account/provider keys.
enum DashboardTrend {
    enum Field {
        case hourly
        case weekly
    }

    struct Point: Equatable {
        let start: Date
        let value: Double
    }

    /// Averages every sample that falls inside `window`, grouped by `bucket`.
    /// Buckets without samples are omitted rather than fabricated as zero.
    static func points(
        history: [String: [QuotaHistorySample]],
        field: Field,
        now: Date,
        window: TimeInterval,
        bucket: TimeInterval
    ) -> [Point] {
        guard window > 0, bucket > 0 else { return [] }
        let start = now.addingTimeInterval(-window)
        var groups: [Int: (sum: Double, count: Int)] = [:]

        for samples in history.values {
            for sample in samples {
                guard sample.at >= start, sample.at <= now else { continue }
                let value: Double?
                switch field {
                case .hourly: value = sample.hourly
                case .weekly: value = sample.weekly
                }
                guard let value else { continue }
                let offset = sample.at.timeIntervalSince(start)
                let index = Int(floor(offset / bucket))
                guard index >= 0 else { continue }
                let current = groups[index] ?? (0, 0)
                groups[index] = (current.sum + value, current.count + 1)
            }
        }

        return groups.keys.sorted().map { index in
            let group = groups[index] ?? (0, 1)
            return Point(
                start: start.addingTimeInterval(Double(index) * bucket),
                value: group.sum / Double(group.count)
            )
        }
    }
}

// MARK: - Dashboard

/// Overview: the scheduler, the Codex account pool and the gateway at a glance.
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @Binding var selection: MTSection

    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var usage = ProviderUsageStore.shared
    @ObservedObject private var scheduler = SchedulerStore.shared
    @ObservedObject private var modelSources = ModelSourcesStore.shared
    @ObservedObject private var antigravity = AntigravityPoolStore.shared

    /// Claude OAuth accounts are plain files on disk, so they are read once per
    /// appearance instead of being polled on every render.
    @State private var claudeAccounts: [ClaudeAuthService.AuthFile] = []

    @AppStorage(DashboardWidgetKey.poolHealth) private var showPoolHealth = true
    @AppStorage(DashboardWidgetKey.quotaTrends) private var showQuotaTrends = true
    @AppStorage(DashboardWidgetKey.spend) private var showSpend = true
    @AppStorage(DashboardWidgetKey.scheduler) private var showScheduler = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                heroGreetingBanner

                bentoRow {
                    providersCard
                    poolsCard
                }

                if showPoolHealth || showQuotaTrends {
                    bentoRow {
                        if showPoolHealth { poolHealthCard }
                        if showQuotaTrends { quotaTrendsCard }
                    }
                }

                if showScheduler || showSpend {
                    bentoRow {
                        if showScheduler { schedulerCard }
                        if showSpend { spendCard }
                    }
                }

                gatewayCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .mtScrollMemory("scroll.dashboard")
        }
        .background(MTTheme.background)
        .onAppear {
            codex.load()
            scheduler.start()
            antigravity.start()
            claudeAccounts = ClaudeAuthService.authFiles()
            Task { await gateway.healthCheck() }
            Task { await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID) }
            Task { await antigravity.refresh() }
        }
    }

    /// One bento row. Cards share the row height (`fillsHeight`), so a short
    /// card never leaves a hole under itself and the board reads as a grid.
    private func bentoRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: MTTheme.s3) {
            content()
        }
    }

    // MARK: - Hero Greeting Banner

    private var heroGreetingBanner: some View {
        HStack(alignment: .center, spacing: MTTheme.s4) {
            MelonAssets.logoImage(size: 56)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: MTTheme.s2) {
                    Text("Melon Tools")
                        .font(MTTheme.display(22, weight: .bold))
                        .foregroundStyle(MTTheme.textPrimary)

                    Circle()
                        .fill(gateway.isRunning ? MTTheme.emerald : MTTheme.amber)
                        .frame(width: 8, height: 8)

                    Text(gateway.isRunning ? L("running") : L("stopped"))
                        .font(MTTheme.body(10, weight: .semibold))
                        .foregroundStyle(gateway.isRunning ? MTTheme.emerald : MTTheme.textSecondary)
                }

                Text(L("Dashboard subtitle"))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: MTTheme.s3)

            HStack(spacing: MTTheme.s2) {
                if gateway.isRunning {
                    MTGlassButton(title: L("Stop"), systemImage: "stop.fill", tint: MTTheme.ruby) {
                        Task { await gateway.stop() }
                    }
                } else {
                    MTGlassButton(
                        title: L("Start"),
                        systemImage: "play.fill",
                        tint: MTTheme.emerald,
                        prominent: true,
                        isLoading: gateway.isStarting
                    ) {
                        codex.load()
                        Task { await gateway.start(accounts: codex.accounts, priorities: codex.effectivePriorities()) }
                    }
                }

                MTGlassButton(title: L("Accounts"), systemImage: "person.2", tint: MTTheme.cyan) {
                    selection = .codexAccounts
                }
            }
        }
        .padding(MTTheme.s4)
        .mtBentoCard(accent: MTTheme.amber, cornerRadius: MTTheme.rBento)
    }

    // MARK: - Pool health

    private var poolHealth: DashboardPoolHealth {
        DashboardMetrics.poolHealth(accounts: codex.accounts)
    }

    private var poolHealthCard: some View {
        let health = poolHealth
        let totals = DashboardMetrics.quotaTotals(accounts: codex.accounts)
        return MTCard(title: L("Codex pool health"), systemImage: "heart.text.square", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: MTTheme.s2)],
                    spacing: MTTheme.s2
                ) {
                    MTMetricTile(title: L("Total"), value: "\(health.total)", tint: MTTheme.cyan)
                    MTMetricTile(title: L("Usable"), value: "\(health.usable)", tint: MTTheme.emerald)
                    MTMetricTile(title: L("Paused"), value: "\(health.paused)", tint: MTTheme.amber)
                    MTMetricTile(
                        title: L("Errors"),
                        value: "\(health.errors)",
                        tint: health.errors > 0 ? MTTheme.ruby : MTTheme.textTertiary
                    )
                }
                HStack(spacing: MTTheme.s3) {
                    totalCell(
                        title: L("Total left 5 h"),
                        value: totals.hourly,
                        limit: totals.max,
                        tint: MTTheme.cyan
                    )
                    totalCell(
                        title: L("Total left weekly"),
                        value: totals.weekly,
                        limit: totals.max,
                        tint: MTTheme.emerald
                    )
                }
            }
        }
    }

    /// Pool sum, not an average: five accounts at 100% read 500% of 500%.
    private func totalCell(title: String, value: Double?, limit: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(MTTheme.body(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(MTTheme.display(18, weight: .semibold))
                    .foregroundStyle(value == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
                if value != nil {
                    Text(String(format: L("of %d%%"), Int(limit)))
                        .font(MTTheme.body(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
            MTMeter(fraction: limit > 0 ? Swift.min(1, Swift.max(0, (value ?? 0) / limit)) : 0, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Quota limits

    /// Current pool totals. This is intentionally not a history average:
    /// five accounts at 100% must read 500%, and the value must agree with the
    /// quota bars on the account cards.
    private var quotaLimitTotals: DashboardQuotaTotals {
        DashboardMetrics.quotaTotals(accounts: codex.accounts)
    }

    private var quotaTrendsCard: some View {
        let totals = quotaLimitTotals
        let hourlyFraction = totals.max > 0 ? (totals.hourly.map { min(1, max(0, $0 / totals.max)) }) : nil
        let weeklyFraction = totals.max > 0 ? (totals.weekly.map { min(1, max(0, $0 / totals.max)) }) : nil

        return MTCard(title: L("Quota limits"), systemImage: "gauge.with.dots.needle.33percent", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s3) {
                    HStack(spacing: MTTheme.s2) {
                        MTQuotaRing(
                            fraction: hourlyFraction,
                            size: 56,
                            ringTint: MTTheme.cyan,
                            strokeWidth: 5
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("hourly").uppercased())
                                .font(MTTheme.mono(9, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(MTTheme.textTertiary)
                            Text(totals.hourly.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(MTTheme.mono(13, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: MTTheme.s2) {
                        MTQuotaRing(
                            fraction: weeklyFraction,
                            size: 56,
                            ringTint: MTTheme.emerald,
                            strokeWidth: 5
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("weekly").uppercased())
                                .font(MTTheme.mono(9, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(MTTheme.textTertiary)
                            Text(totals.weekly.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(MTTheme.mono(13, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)

                Divider().overlay(MTTheme.borderColor)

                HStack(spacing: MTTheme.s2) {
                    Text(String(format: L("Accounts in pool: %d"), codex.accounts.count))
                    Spacer(minLength: 0)
                    Text(String(format: L("of %d%%"), Int(totals.max)))
                }
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func quotaLimitRow(title: String, value: Double?, limit: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: limit > 0 ? min(1, max(0, (value ?? 0) / limit)) : 0)
        }
    }

    // MARK: - Spend and top providers

    private var spendCard: some View {
        MTCard(title: L("Spend & top providers"), systemImage: "dollarsign.circle", accent: MTTheme.violet) {
            if let spend = usage.sessionSpend, !spend.providers.isEmpty {
                VStack(alignment: .leading, spacing: MTTheme.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                        Text(L("Session spend (estimate)").uppercased())
                            .font(MTTheme.mono(9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(MTTheme.textTertiary)
                        Spacer()
                        Text(spend.hasData ? "≈ " + money(spend.totalUSD) : "—")
                            .font(MTTheme.display(20, weight: .semibold))
                            .foregroundStyle(spend.hasData ? MTTheme.violet : MTTheme.textTertiary)
                    }
                    Divider().overlay(MTTheme.borderColor)
                    ForEach(spend.topProviders(), id: \.provider) { row in
                        providerRow(row)
                    }
                    if spend.scaled {
                        Text(L("Older turns are outside the read window; the estimate is scaled."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }
            } else {
                Text(L("Session data appears when a thread runs this provider's models."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func providerRow(_ row: SessionSpend.ProviderRanking) -> some View {
        HStack(spacing: MTTheme.s2) {
            Text(providerTitle(row.provider))
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MTTheme.s2)
            Text(tokens(row.stats.tokens))
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Text(row.stats.usd.map { "≈ " + money($0) } ?? "—")
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(row.stats.usd == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
            Text("\(row.stats.turns) " + L("Turns").lowercased())
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
    }

    private func providerTitle(_ tag: String) -> String {
        switch tag.lowercased() {
        case "openrouter": return "OpenRouter"
        case "opencode": return "OpenCode"
        case "claude": return "Claude"
        case "antigravity": return "Antigravity"
        default: return tag.capitalized
        }
    }

    // MARK: - Scheduler summary

    private var schedulerCard: some View {
        let now = Date()
        let due = SchedulerPolicy.due(scheduler.tasks, now: now)
        let next = DashboardMetrics.nextRun(tasks: scheduler.tasks)
        let last = DashboardMetrics.lastStatus(tasks: scheduler.tasks, history: scheduler.history)
        return MTCard(title: L("Scheduler summary"), systemImage: "clock.badge.checkmark", accent: MTTheme.amber) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    MTMetricTile(title: L("Due now"), value: "\(due.count)", tint: due.isEmpty ? MTTheme.textTertiary : MTTheme.amber)
                    MTMetricTile(title: L("Next run"), value: next.map { ISODate.until($0) } ?? "—", tint: MTTheme.cyan)
                }
                HStack(spacing: MTTheme.s2) {
                    Text(L("Last status").uppercased())
                        .font(MTTheme.mono(9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(MTTheme.textTertiary)
                    statusPill(last)
                    Spacer()
                    MTGlassButton(
                        title: L("Run next"),
                        systemImage: "play.fill",
                        tint: MTTheme.amber,
                        isLoading: scheduler.isRunning
                    ) {
                        guard gateway.isRunning, let task = due.first else { return }
                        Task { await scheduler.runNow(id: task.id) }
                    }
                    .disabled(due.isEmpty || scheduler.isRunning || !gateway.isRunning)
                }
                if !gateway.isRunning {
                    Text(L("Scheduled runs wait until the service is running."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                } else if due.isEmpty {
                    Text(L("No due tasks"))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ status: SchedulerTaskStatus?) -> some View {
        switch status {
        case .ok:
            MTStatusPill(text: L("ok"), status: .ok)
        case .error:
            MTStatusPill(text: L("error"), status: .error)
        case .running:
            MTStatusPill(text: L("running"), status: .running)
        case .cancelled:
            MTStatusPill(text: L("cancelled"), status: .absent)
        case .never, .none:
            MTStatusPill(text: L("Never"), status: .absent)
        }
    }

    // MARK: - Existing pool and API cards

    // MARK: - Providers and pools

    /// Every upstream the gateway can use, key-based and OAuth alike, so the
    /// board answers "what is connected" without opening the sources page.
    private var providersCard: some View {
        let lines = providerLines
        return MTCard(
            title: L("Providers"),
            systemImage: "point.3.connected.trianglepath.dotted",
            accent: MTTheme.violet,
            fillsHeight: true
        ) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                if lines.isEmpty {
                    Text(L("No providers connected yet."))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(lines) { line in
                        providerLineView(line)
                    }
                    Divider().overlay(MTTheme.borderColor)
                    HStack(spacing: MTTheme.s2) {
                        Text(L("Connected") + ": \(lines.filter(\.isOn).count)")
                            .font(MTTheme.body(9.5))
                            .foregroundStyle(MTTheme.textTertiary)
                        Spacer(minLength: 0)
                        Text(modelsLabel(lines.reduce(0) { $0 + $1.modelCount }))
                            .font(MTTheme.body(9.5))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
            }
        }
    }

    private struct ProviderLine: Identifiable {
        var id: String
        var title: String
        var detail: String
        var tint: Color
        var isOn: Bool
        var modelCount: Int
    }

    private var providerLines: [ProviderLine] {
        var lines = modelSources.sources
            .filter { !$0.title.isEmpty }
            .map { source in
                let models = source.selectedModels.count
                return ProviderLine(
                    id: source.id,
                    title: source.title,
                    detail: models > 0
                        ? modelsLabel(models)
                        : (source.enabled ? L("no models") : L("Disabled")),
                    tint: providerTint(source.kind),
                    isOn: source.enabled && (models > 0 || source.kind == .claude || source.kind == .antigravity),
                    modelCount: models
                )
            }

        // OAuth providers live outside `sources` (there is no key to store), so
        // they are added from the pools they actually serve.
        if !lines.contains(where: { $0.id == "oauth.codex" }), !codex.accounts.isEmpty {
            lines.append(ProviderLine(
                id: "oauth.codex",
                title: "Codex",
                detail: accountsLabel(codex.accounts.count),
                tint: MTTheme.cyan,
                isOn: true,
                modelCount: 0
            ))
        }
        if !lines.contains(where: { $0.id == "oauth.claude" }), !claudeAccounts.isEmpty {
            lines.append(ProviderLine(
                id: "oauth.claude",
                title: "Claude",
                detail: accountsLabel(claudeAccounts.count),
                tint: MTTheme.amber,
                isOn: true,
                modelCount: 0
            ))
        }

        return lines.sorted { lhs, rhs in
            if lhs.isOn != rhs.isOn { return lhs.isOn && !rhs.isOn }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func providerTint(_ kind: ModelSource.Kind) -> Color {
        switch kind {
        case .openRouter: return MTTheme.violet
        case .openCode: return MTTheme.cyan
        case .deepInfra: return MTTheme.emerald
        case .vercel: return MTTheme.textSecondary
        case .zai: return MTTheme.amber
        case .claude: return MTTheme.amber
        case .antigravity: return MTTheme.cyan
        case .localAI: return MTTheme.emerald
        }
    }

    private func providerLineView(_ line: ProviderLine) -> some View {
        HStack(spacing: MTTheme.s2) {
            Circle()
                .fill(line.isOn ? line.tint : MTTheme.textTertiary)
                .frame(width: 6, height: 6)
            Text(line.title)
                .font(MTTheme.body(11.5, weight: .medium))
                .foregroundStyle(line.isOn ? MTTheme.textPrimary : MTTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: MTTheme.s2)
            Text(line.detail)
                .font(MTTheme.body(10))
                .foregroundStyle(MTTheme.textTertiary)
                .lineLimit(1)
        }
    }

    /// Every account pool the app can route through: Codex OAuth, the
    /// Antigravity OAuth pool and the Claude OAuth accounts.
    private var poolsCard: some View {
        MTCard(
            title: L("Account pools"),
            systemImage: "square.stack.3d.up",
            accent: MTTheme.emerald,
            fillsHeight: true
        ) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                poolLine(
                    icon: "person.2",
                    title: L("Codex pool"),
                    tint: MTTheme.cyan,
                    accounts: codex.accounts.count,
                    metrics: [
                        (L("5 h"), poolHealth.hourlyAverage),
                        (L("Week"), poolHealth.weeklyAverage)
                    ]
                )
                Divider().overlay(MTTheme.borderColor)
                poolLine(
                    icon: "atom",
                    title: "Antigravity",
                    tint: MTTheme.violet,
                    accounts: antigravity.accounts.count,
                    metrics: [
                        ("Gemini", antigravityGeminiAverage),
                        ("Claude", antigravityClaudeAverage)
                    ]
                )
                if !claudeAccounts.isEmpty {
                    Divider().overlay(MTTheme.borderColor)
                    poolLine(
                        icon: "c.circle",
                        title: "Claude",
                        tint: MTTheme.amber,
                        accounts: claudeAccounts.count,
                        metrics: []
                    )
                }
                Divider().overlay(MTTheme.borderColor)
                HStack(spacing: MTTheme.s2) {
                    Text(L("All pools"))
                        .font(MTTheme.body(9.5))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: 0)
                    Text(accountsLabel(totalPoolAccounts))
                        .font(MTTheme.body(9.5))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private func poolLine(
        icon: String,
        title: String,
        tint: Color,
        accounts: Int,
        metrics: [(String, Double?)]
    ) -> some View {
        HStack(spacing: MTTheme.s2) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MTTheme.body(11.5, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(String(format: L("Accounts in pool: %d"), accounts))
                    .font(MTTheme.body(9.5))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            Spacer(minLength: MTTheme.s2)
            HStack(spacing: MTTheme.s3) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(metric.0.uppercased())
                            .font(MTTheme.body(8, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(metric.1.map { "\(Int($0.rounded()))%" } ?? "—")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(metric.1 == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
                    }
                }
            }
        }
    }

    private var totalPoolAccounts: Int {
        codex.accounts.count + antigravity.accounts.count + claudeAccounts.count
    }

    /// Russian needs three plural forms; the app ships RU and EN, so the rule
    /// lives here instead of a format string.
    private func accountsLabel(_ count: Int) -> String {
        guard L10n.shared.isRU else {
            return count == 1 ? "1 account" : "\(count) accounts"
        }
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if mod100 >= 11 && mod100 <= 14 {
            word = "аккаунтов"
        } else if mod10 == 1 {
            word = "аккаунт"
        } else if mod10 >= 2 && mod10 <= 4 {
            word = "аккаунта"
        } else {
            word = "аккаунтов"
        }
        return "\(count) \(word)"
    }

    private func modelsLabel(_ count: Int) -> String {
        guard L10n.shared.isRU else {
            return count == 1 ? "1 model" : "\(count) models"
        }
        let mod100 = count % 100
        let mod10 = count % 10
        let word: String
        if mod100 >= 11 && mod100 <= 14 {
            word = "моделей"
        } else if mod10 == 1 {
            word = "модель"
        } else if mod10 >= 2 && mod10 <= 4 {
            word = "модели"
        } else {
            word = "моделей"
        }
        return "\(count) \(word)"
    }

    private var antigravityGeminiAverage: Double? {
        DashboardMetrics.average(
            antigravity.accounts.compactMap { $0.geminiQuota?.remaining }.map { $0 * 100 }
        )
    }

    private var antigravityClaudeAverage: Double? {
        DashboardMetrics.average(
            antigravity.accounts.compactMap { $0.claudeQuota?.remaining }.map { $0 * 100 }
        )
    }

    private var gatewayCard: some View {
        let gatewayAccent: Color = {
            switch gateway.status {
            case .running: return MTTheme.emerald
            case .starting: return MTTheme.amber
            case .failed: return MTTheme.ruby
            case .stopped: return MTTheme.cyan
            }
        }()

        return MTCard(title: L("Codex API"), systemImage: "network", accent: gatewayAccent) {
            HStack(spacing: MTTheme.s3) {
                switch gateway.status {
                case .stopped: MTStatusPill(text: L("stopped"), status: .absent)
                case .starting: MTStatusPill(text: L("starting"), status: .warn)
                case .running: MTStatusPill(text: L("running"), status: .ok)
                case .failed: MTStatusPill(text: L("failed"), status: .error)
                }
                if let error = gateway.lastError, case .failed = gateway.status {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.ruby)
                        .lineLimit(1)
                }
                Spacer()
                if gateway.isRunning {
                    MTGlassButton(title: L("Stop"), systemImage: "stop.fill", tint: MTTheme.ruby) {
                        Task { await gateway.stop() }
                    }
                } else {
                    MTGlassButton(
                        title: L("Start"),
                        systemImage: "play.fill",
                        tint: MTTheme.emerald,
                        prominent: true,
                        isLoading: gateway.isStarting
                    ) {
                        codex.load()
                        Task { await gateway.start(accounts: codex.accounts, priorities: codex.effectivePriorities()) }
                    }
                }
                MTGlassButton(title: L("Open"), systemImage: "arrow.right", tint: MTTheme.cyan) {
                    selection = .codexAPI
                }
            }
        }
    }

    // MARK: - Formatting

    private func tokens(_ value: Int) -> String {
        let n = Double(value)
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return "\(value)"
    }

    /// `$3.03`, `$30`, `$1000` — locale-independent, same as the composer chips.
    private func money(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005, value.magnitude >= 1 {
            return String(format: "$%.0f", rounded)
        }
        return String(format: "$%.2f", value)
    }
}
