import AppKit
import SwiftUI

/// Connections: the Codex account pool plus the key-based sources (OpenRouter,
/// OpenCode, DeepInfra, Vercel AI Gateway, Claude and Antigravity). Every card
/// spans the full board width and stacks vertically; «Настройки» opens the key
/// and model picker of the source, while the pool card leads to Accounts.
struct CodexProvidersView: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var sources = ModelSourcesStore.shared
    @ObservedObject private var store = CodexStore.shared
    @ObservedObject private var pool = CodexPoolModelsStore.shared
    @ObservedObject private var usage = ProviderUsageStore.shared
    @ObservedObject private var quotaHistory = QuotaHistoryStore.shared
    @ObservedObject private var claudeAuth = ClaudeAuthService.shared
    @ObservedObject private var antigravityAuth = AntigravityAuthService.shared
    @ObservedObject private var diagnostics = ProviderDiagnosticsStore.shared
    @ObservedObject private var localStore = LocalModelStore.shared
    @ObservedObject private var localRuntime = LocalInferenceService.shared
    @Binding var selection: MTSection

    @State private var route: ProviderRoute?
    @State private var searches: [String: String] = [:]
    @State private var openRouterFreeOnly = false
    @State private var poolSearch = ""
    @State private var poolError: String?
    @State private var confirmClaudeDisconnect = false
    @State private var confirmAntigravityDisconnect = false
    @State private var antigravityIssue: AntigravityAuthService.VerificationIssue?
    @ObservedObject private var antigravityPool = AntigravityPoolStore.shared
    @State private var pendingAntigravityRemoval: AntigravityAccount?
    @State private var pendingProxyAccount: AntigravityAccount?
    @State private var proxyDraft: String = ""
    @State private var customEditor: CustomProviderDraft?
    @State private var pendingCustomRemoval: ModelSource?

    /// Sub-pages of the provider board.
    enum ProviderRoute: String, Identifiable {
        case openRouter
        case openCode
        case commandCode
        case deepInfra
        case nvidia
        case vercel
        case zai
        case claude
        case antigravity
        case codexPool

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .openCode: return "OpenCode"
            case .commandCode: return "CommandCode"
            case .deepInfra: return "DeepInfra"
            case .nvidia: return "NVIDIA"
            case .vercel: return "Vercel"
            case .zai: return "Z.ai"
            case .claude: return "Claude"
            case .antigravity: return "Antigravity"
            case .codexPool: return "Codex"
            }
        }

        var systemImage: String {
            switch self {
            case .openRouter: return "point.3.connected.trianglepath.dotted"
            case .openCode: return "chevron.left.forwardslash.chevron.right"
            case .commandCode: return "terminal"
            case .deepInfra, .nvidia: return "server.rack"
            case .vercel: return "triangle"
            case .zai: return "atom"
            case .claude: return "sparkles"
            case .antigravity: return "globe.americas"
            case .codexPool: return "person.2"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                if let route {
                    settingsPage(route)
                } else {
                    MTPageHeader(kicker: "codex", title: L("Connections"), subtitle: L("Connections subtitle"))
                    diagnosticsCard
                    poolCard
                    openRouterCard
                    openCodeCard
                    commandCodeCard
                    deepInfraCard
                    nvidiaCard
                    vercelCard
                    zaiCard
                    claudeCard
                    antigravityCard
                    customProvidersCard
                    localAICard
                    applyCard
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.providers")
        }
        .background(MTTheme.background)
        .onAppear {
            sources.load()
            store.load()
            Task {
                await sources.refreshOpenCodeGoAccess()
                await usage.refresh()
                await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
            }
        }
        .sheet(item: $customEditor) { draft in
            CustomProviderSheet(draft: draft) { result in
                if let error = sources.saveCustomSource(
                    originalID: draft.originalID,
                    identifier: result.identifier,
                    title: result.title,
                    baseURL: result.baseURL,
                    apiProtocol: result.apiProtocol,
                    apiKey: result.apiKey,
                    models: result.models
                ) {
                    return error
                }
                customEditor = nil
                return nil
            }
        }
        .confirmationDialog(
            L("Delete this provider?"),
            isPresented: Binding(
                get: { pendingCustomRemoval != nil },
                set: { if !$0 { pendingCustomRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                if let provider = pendingCustomRemoval {
                    sources.removeCustomSource(id: provider.id)
                }
                pendingCustomRemoval = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingCustomRemoval = nil }
        } message: {
            Text(pendingCustomRemoval?.title ?? "")
        }
    }

    // MARK: - Custom providers

    /// One generic card for user-defined endpoints. Unlike the branded cards
    /// above it has no settings sub-page: the same sheet creates and edits,
    /// and the routing identifier doubles as the model prefix.
    private var customProvidersCard: some View {
        MTCard(title: L("Custom providers"), systemImage: "plus.rectangle.on.rectangle", accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    VStack(alignment: .leading, spacing: MTTheme.s1) {
                        Text(L("Connect any endpoint that speaks OpenAI Chat, OpenAI Responses, Anthropic Messages or Gemini."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        Text(L("Models are namespaced by the provider identifier, so they never collide with the account pool."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    MTGlassButton(title: L("Add provider"), systemImage: "plus", tint: MTTheme.violet, prominent: true) {
                        customEditor = CustomProviderDraft(source: nil)
                    }
                }

                if sources.customSources.isEmpty {
                    VStack(spacing: MTTheme.s1) {
                        Text(L("No custom providers yet"))
                            .font(MTTheme.body(12))
                            .foregroundStyle(MTTheme.textSecondary)
                        Text(L("Add a relay or a self-hosted gateway to route its models through Melon Tools."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MTTheme.s4)
                    .background(
                        RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                            .strokeBorder(MTTheme.borderColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
                } else {
                    ForEach(sources.customSources) { provider in
                        customProviderRow(provider)
                    }
                }
            }
        }
    }

    private func customProviderRow(_ provider: ModelSource) -> some View {
        HStack(alignment: .center, spacing: MTTheme.s3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MTTheme.violet)
                .frame(width: 26, height: 26)
                .background(Circle().fill(MTTheme.violet.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MTTheme.s2) {
                    Text(provider.title)
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(provider.effectiveProtocol.title)
                        .font(MTTheme.mono(8))
                        .foregroundStyle(MTTheme.violet)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(MTTheme.violet.opacity(0.12)))
                    Text(provider.id)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                Text(provider.baseURL)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
                Text(String(format: L("%d models, %d enabled"), provider.models.count, provider.selectedModels.count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            Spacer(minLength: MTTheme.s2)
            Toggle("", isOn: Binding(
                get: { provider.enabled },
                set: { sources.setCustomSourceEnabled(provider.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(MTTheme.violet)
            .help(L("Enable provider"))
            MTGlassButton(title: L("Edit"), systemImage: "slider.horizontal.3", tint: MTTheme.cyan) {
                customEditor = CustomProviderDraft(source: provider)
            }
            MTGlassButton(title: L("Delete"), systemImage: "trash", tint: MTTheme.danger) {
                pendingCustomRemoval = provider
            }
        }
        .padding(MTTheme.s3)
        .background(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .fill(MTTheme.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .strokeBorder(MTTheme.borderColor, lineWidth: 1)
                )
        )
        .opacity(provider.enabled ? 1 : 0.62)
    }

    // MARK: - Connection check

    /// Compact, read-only health summary: gateway `/v1/models`, auth files or
    /// keys, model counts and the last quota poll. The probe never writes.
    private var diagnosticsCard: some View {
        MTCard(title: L("Connection check"), systemImage: "checklist", accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    if let evidence = diagnostics.evidence {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: MTTheme.s2) {
                                MTStatusPill(
                                    text: gatewayPill(evidence),
                                    status: diagnostics.gatewayOK ? .ok : .error
                                )
                                if let finished = diagnostics.finishedAt {
                                    Text(L("Updated") + " " + Self.timeFormatter.string(from: finished))
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textTertiary)
                                }
                            }
                            Text(diagnosticsCaption(evidence))
                                .font(MTTheme.mono(9))
                                .foregroundStyle(evidence.gatewayError == nil && evidence.modelsError == nil ? MTTheme.textSecondary : MTTheme.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L("Read-only check of the service, auth files, model list and quota updates."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Check"), systemImage: "arrow.clockwise", tint: MTTheme.cyan, isLoading: diagnostics.isRunning) {
                        Task { await diagnostics.run() }
                    }
                }
                if !diagnostics.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(diagnostics.rows) { row in
                            diagnosticRow(row)
                        }
                    }
                } else {
                    Text(L("Not checked yet."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private func gatewayPill(_ evidence: ProviderDiagnostics.Evidence) -> String {
        if let code = evidence.gatewayStatusCode { return "HTTP \(code)" }
        return L("Unreachable")
    }

    private func diagnosticsCaption(_ evidence: ProviderDiagnostics.Evidence) -> String {
        if let error = evidence.gatewayError { return error }
        if let error = evidence.modelsError { return error }
        return String(format: L("Gateway model list: %d"), evidence.models.count)
    }

    private func diagnosticRow(_ row: ProviderDiagnostics.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: MTTheme.s2) {
                MTStatusDot(status: rowStatus(row.status), size: 6)
                Text(L(row.title))
                    .font(MTTheme.body(11, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                    .frame(width: 96, alignment: .leading)
                Text(authDetail(row))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(row.authPresent ? MTTheme.textSecondary : MTTheme.warn)
                Spacer(minLength: MTTheme.s2)
                Text(row.modelCount.map { String(format: L("Models: %d"), $0) } ?? L("No model list"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                Text("·")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(row.quotaUpdatedAt.map { L("Quota updated") + " " + Self.timeFormatter.string(from: $0) } ?? L("No quota data"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                diagnosticHistory(row.id)
            }
            if let error = row.error {
                Text(error)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.danger)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private func authDetail(_ row: ProviderDiagnostics.Row) -> String {
        if row.id == "localai" {
            return row.hasKey ? L("Internal token") : L("No ready models")
        }
        if row.authFileCount > 0 {
            return String(format: L("Auth files: %d"), row.authFileCount)
        }
        return row.hasKey ? L("Key configured") : L("No credentials")
    }

    private func rowStatus(_ status: ProviderDiagnostics.Status) -> MTStatus {
        switch status {
        case .ok: return .ok
        case .warning: return .warn
        case .failed: return .error
        case .idle: return .idle
        }
    }

    /// Read-only history line for diagnostics rows that have a series. Only
    /// the provider-wide keys exist here; per-account history stays in the
    /// account cards.
    @ViewBuilder
    private func diagnosticHistory(_ id: String) -> some View {
        if id == "claude" {
            let samples = quotaHistory.samples(for: id)
            if samples.count >= 2 {
                HStack(spacing: 2) {
                    QuotaSparkline(samples: samples, field: .hourly, width: 36, height: 11)
                    QuotaSparkline(samples: samples, field: .weekly, tint: MTTheme.info, width: 36, height: 11)
                }
            }
        } else if id == "openrouter" {
            let samples = quotaHistory.samples(for: id)
            if samples.count >= 2 {
                QuotaSparkline(samples: samples, field: .balance, tint: MTTheme.ok, width: 48, height: 11)
            }
        }
    }

    // MARK: - Board: the pool

    private var poolCard: some View {
        MTCard(title: L("Codex pool"), systemImage: "person.2", accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                    Text("\(store.accounts.count)")
                        .font(MTTheme.display(30))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Accounts"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer(minLength: MTTheme.s2)
                    MTStatusPill(text: gateway.status.label, status: gateway.status.pillStatus)
                }
                if let pause = store.poolPauseSummary() {
                    CodexPoolPauseBanner(summary: pause)
                }
                quotaRow(title: L("5 h"), fraction: poolQuota(\.hourlyRemainingPercent))
                quotaRow(title: L("Week"), fraction: poolQuota(\.weeklyRemainingPercent))
                HStack(spacing: MTTheme.s4) {
                    healthStat(L("Working"), count: poolHealth.working, status: .ok)
                    healthStat(L("Failed"), count: poolHealth.failed, status: .error)
                    healthStat(L("Paused"), count: poolHealth.paused, status: .warn)
                }
                Text(String(format: L("Models in pool: %d of %d"), poolUnionCount, pool.models.count))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Accounts"), systemImage: "person.2", tint: MTTheme.cyan) {
                        selection = .codexAccounts
                    }
                    MTGlassButton(title: L("Models"), systemImage: "square.grid.2x2", tint: MTTheme.violet) {
                        route = .codexPool
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Pool-wide share of quota still available (mean over accounts with data).
    private func poolQuota(_ keyPath: KeyPath<CodexQuota, Double?>) -> Double? {
        let values = store.accounts.filter { $0.poolEnabled != false }.compactMap { $0.quota?[keyPath: keyPath] }
        guard !values.isEmpty else { return nil }
        return min(1, max(0, values.reduce(0, +) / Double(values.count) / 100))
    }

    private var poolHealth: (working: Int, failed: Int, paused: Int) {
        let total = store.accounts.count
        let failed = store.accounts.filter { $0.quotaError != nil }.count
        let paused = store.accounts.filter { account in
            guard account.quotaError == nil else { return false }
            if account.poolEnabled == false { return true }
            guard let quota = account.quota else { return false }
            return (quota.hourlyRemainingPercent ?? 1) <= 0 || (quota.weeklyRemainingPercent ?? 1) <= 0
        }.count
        return (max(0, total - failed - paused), failed, paused)
    }

    // MARK: - Pool model selection

    /// Slugs every account supports (checked rows of the pool page). With no
    /// accounts nothing is checked, so the rows start from an empty state.
    private var poolSupportedSlugs: Set<String> {
        guard !store.accounts.isEmpty else { return [] }
        return Set(pool.models.map(\.slug)).filter { slug in
            store.accounts.allSatisfy { account in
                store.effectiveSelectedModels(for: account).contains(slug)
            }
        }
    }

    /// How many accounts support one pool slug.
    private func poolSupportCount(_ slug: String) -> Int {
        store.accounts.filter { account in
            store.effectiveSelectedModels(for: account).contains(slug)
        }.count
    }

    private var poolUnionCount: Int {
        CodexPoolModelsStore.unionSelection(
            accounts: store.accounts,
            poolSlugs: pool.slugs
        ).count
    }

    private var filteredPoolModels: [CodexPoolModel] {
        let query = poolSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return pool.models }
        return pool.models.filter {
            $0.slug.localizedCaseInsensitiveContains(query) || $0.display.localizedCaseInsensitiveContains(query)
        }
    }

    private func togglePoolModel(_ slug: String) {
        let enable = !poolSupportedSlugs.contains(slug)
        poolError = store.setPoolModel(slug, enabled: enable)
    }

    private func quotaRow(title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: fraction)
        }
    }

    private func healthStat(_ title: String, count: Int, status: MTStatus) -> some View {
        HStack(spacing: 5) {
            MTStatusDot(status: status, size: 6)
            Text("\(count)")
                .font(MTTheme.mono(10, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
            Text(title)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    // MARK: - Board: OpenCode

    private var openCodeCard: some View {
        let configured = !sources.openCodeKey.isEmpty
        return MTCard(title: "OpenCode", systemImage: ProviderRoute.openCode.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                }
                keyValueRow(L("Workspace"), usage.openCode?.workspace ?? "—")
                if let source = sources.openCodeSource {
                    modelsMeter(source: source)
                    let goCount = source.models.filter { $0.goTier == true }.count
                    if goCount > 0 {
                        Text(String(format: L("Go plan: %d models"), goCount))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                sessionLine(provider: "opencode")
                Text(L("Free OpenCode models only work inside the OpenCode app itself."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(L("Go limits and subscription live in the OpenCode console."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Open console"), systemImage: "arrow.up.forward.app", tint: MTTheme.cyan) {
                        if let url = URL(string: "https://opencode.ai/console") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .openCode
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Board: OpenRouter

    private var openRouterCard: some View {
        let configured = !sources.openRouterKey.isEmpty
        let stats = usage.openRouter
        let keyRemaining: Double? = {
            if let remaining = stats?.keyRemaining { return max(0, remaining) }
            guard let limit = stats?.keyLimit, let used = stats?.keyUsage else { return nil }
            return max(0, limit - used)
        }()
        return MTCard(title: "OpenRouter", systemImage: ProviderRoute.openRouter.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("Available"),
                            value: stats.creditsRemaining.map(money) ?? "—",
                            caption: L("Balance"),
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Credits spent"),
                            value: stats.creditsUsage.map(money) ?? "—",
                            caption: stats.creditsTotal.map { L("Lifetime") + " · " + L("Purchased").lowercased() + " " + money($0) },
                            valueColor: MTTheme.amber,
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Key limit remaining"),
                            value: keyRemaining.map(money) ?? "—",
                            caption: stats.keyLimit.map { L("Key limit").lowercased() + " " + money($0) },
                            fraction: fraction(keyRemaining, stats.keyLimit),
                            tint: MTTheme.cyan
                        )
                    }
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                } else {
                    Text(L("Paste the OpenRouter key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                sessionLine(provider: "openrouter")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Price routing: cheapest providers first."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Refresh"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                        Task {
                            await usage.refresh(force: true)
                            await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
                        }
                    }
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .openRouter
                    }
                }
            }
        }
    }

    // MARK: - Board: CommandCode

    private var commandCodeCard: some View {
        let configured = !sources.commandCodeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = sources.commandCodeSource
        let anthropicCount = source?.models.filter { $0.anthropicOnly == true }.count ?? 0
        return MTCard(title: "CommandCode", systemImage: ProviderRoute.commandCode.systemImage, accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                }
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    MTMetricTile(
                        title: L("Models"),
                        value: "\(source?.models.count ?? 0)",
                        caption: L("Available")
                    )
                    MTMetricTile(
                        title: L("Anthropic models"),
                        value: "\(anthropicCount)",
                        caption: L("Served over /messages"),
                        valueColor: MTTheme.amber
                    )
                }
                Text(L("CommandCode serves OpenAI-compatible models and Claude models through the matching gateway upstream."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                HStack(spacing: MTTheme.s3) {
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .commandCode
                    }
                }
            }
        }
    }

    // MARK: - Board: DeepInfra

    private var deepInfraCard: some View {
        let configured = !sources.deepInfraKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = sources.deepInfraSource
        let spend = usage.sessionSpend?.stats(for: "deepinfra")
        return MTCard(title: "DeepInfra", systemImage: ProviderRoute.deepInfra.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                }
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    MTMetricTile(
                        title: L("Models"),
                        value: "\(source?.models.count ?? 0)",
                        caption: L("Available")
                    )
                    MTMetricTile(
                        title: L("Session spend"),
                        value: spend?.usd.map { "≈ " + money($0) } ?? "—",
                        caption: L("Estimate")
                    )
                }
                HStack(spacing: MTTheme.s3) {
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .deepInfra
                    }
                }
            }
        }
    }

    private var nvidiaCard: some View {
        let configured = !sources.nvidiaKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return MTCard(title: "NVIDIA", systemImage: ProviderRoute.nvidia.systemImage, accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                MTMetricTile(title: L("Models"), value: "\(sources.nvidiaSource?.models.count ?? 0)", caption: L("Available"))
                HStack {
                    Spacer()
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .nvidia
                    }
                }
            }
        }
    }

    // MARK: - Board: Vercel AI Gateway

    private var vercelCard: some View {
        let configured = !sources.vercelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = sources.vercelSource
        let stats = usage.vercel
        return MTCard(title: "Vercel", systemImage: ProviderRoute.vercel.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    MTMetricTile(
                        title: L("Available"),
                        value: stats?.balance.map(money) ?? "—",
                        caption: L("Team balance"),
                        tint: MTTheme.emerald
                    )
                    MTMetricTile(
                        title: L("Lifetime spend"),
                        value: stats?.totalUsed.map(money) ?? "—",
                        caption: L("Team total")
                    )
                    MTMetricTile(
                        title: L("Models"),
                        value: "\(source?.models.count ?? 0)",
                        caption: L("Available")
                    )
                }
                if let error = stats?.error {
                    Text(error)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.danger)
                }
                sessionLine(provider: "vercel")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Vercel AI Gateway balance is shared by the whole team."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Refresh"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                        Task {
                            await usage.refresh(force: true)
                            await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
                        }
                    }
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .vercel
                    }
                }
            }
        }
    }

    // MARK: - Board: Z.ai

    private var zaiCard: some View {
        let configured = !sources.zaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let source = sources.zaiSource
        return MTCard(title: "Z.ai", systemImage: ProviderRoute.zai.systemImage, accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: configured ? L("Key configured") : L("No key"), status: configured ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                }
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    MTMetricTile(
                        title: L("Models"),
                        value: "\(source?.models.count ?? 0)",
                        caption: L("Available")
                    )
                    MTMetricTile(
                        title: L("Plan"),
                        value: "GLM",
                        caption: L("Coding Plan")
                    )
                }
                Text(L("GLM-5.3 and GLM-5.3-Flash are served through the Z.ai Coding endpoint."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                HStack(spacing: MTTheme.s3) {
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .zai
                    }
                }
            }
        }
    }

    // MARK: - Board: Claude

    private var claudeCard: some View {
        let stats = usage.claude
        let connected = stats?.connected == true
        return MTCard(title: "Claude", systemImage: ProviderRoute.claude.systemImage, accent: MTTheme.amber, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: connected ? L("Connected") : L("Not connected"), status: connected ? .ok : .idle)
                    Spacer(minLength: MTTheme.s2)
                    if let updated = stats?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                keyValueRow(L("Account"), stats?.email ?? "—")
                keyValueRow(L("Plan"), stats?.plan ?? "—")
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("5 h"),
                            value: percentText(stats.fiveHourPercent),
                            caption: resetCaption(prefix: L("left"), date: stats.fiveHourReset),
                            fraction: stats.fiveHourPercent.map { min(1, max(0, $0 / 100)) },
                            tint: MTTheme.emerald
                        )
                        MTMetricTile(
                            title: L("Week"),
                            value: percentText(stats.weeklyPercent),
                            caption: resetCaption(prefix: L("left"), date: stats.weeklyReset),
                            fraction: stats.weeklyPercent.map { min(1, max(0, $0 / 100)) }
                        )
                        MTMetricTile(
                            title: L("Models"),
                            value: "\(stats.modelCount)",
                            caption: L("Selected for Codex")
                        )
                    }
                    QuotaHistorySparklineStrip(
                        samples: quotaHistory.samples(for: "claude"),
                        hourlyTitle: L("5 h"),
                        weeklyTitle: L("Week")
                    )
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                } else {
                    Text(L("Connect your Claude account to use subscription models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                sessionLine(provider: "Claude")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Quota windows come from the connected Anthropic account."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Refresh"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                        Task {
                            await usage.refresh(force: true)
                            await usage.refreshSession(threadUUID: ComposerBridge.shared.activeThreadID)
                        }
                    }
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .claude
                    }
                }
            }
        }
    }

    // MARK: - Board: Antigravity

    /// Presentation state for the Local AI card. Only `.ready` rows are
    /// published routes; installed-only rows stay visible as downloads and
    /// must never look like a working gateway.
    struct LocalAICardState: Equatable {
        enum Mode: Equatable {
            case empty
            case downloadedOnly
            case runningNoReady
            case ready(running: Bool)
            case publicationFailed
        }

        let downloadedCount: Int
        let readyCount: Int
        let isRunning: Bool
        let publicationError: String?
        let currentModelName: String?

        var mode: Mode {
            if publicationError != nil { return .publicationFailed }
            if readyCount > 0 { return .ready(running: isRunning) }
            if isRunning { return .runningNoReady }
            return downloadedCount > 0 ? .downloadedOnly : .empty
        }

        var pillStatus: MTStatus {
            switch mode {
            case .publicationFailed: return .error
            case .ready(let running): return running ? .ok : .warn
            case .runningNoReady, .downloadedOnly, .empty: return .idle
            }
        }

        var pillText: String {
            switch mode {
            case .publicationFailed:
                return L("Publication failed")
            case .ready(let running):
                if running, let currentModelName, !currentModelName.isEmpty {
                    return "\(currentModelName) · \(readyCount) " + L("ready")
                }
                return "\(readyCount) " + L("ready") + " · " + L("engine stopped")
            case .runningNoReady:
                return L("Running · no ready models")
            case .downloadedOnly:
                return "\(downloadedCount) " + L("downloaded") + " · " + L("none ready")
            case .empty:
                return L("No models")
            }
        }
    }

    private var localAICard: some View {
        let state = LocalAICardState(
            downloadedCount: localStore.models.filter {
                $0.runtimeStatus == .installed || $0.runtimeStatus == .ready
            }.count,
            readyCount: localStore.models.filter { $0.runtimeStatus == .ready }.count,
            isRunning: localRuntime.status.isRunning,
            publicationError: localRuntime.publicationError,
            currentModelName: localRuntime.currentModel?.displayName
        )
        return MTCard(title: "Local AI", systemImage: "cpu.fill", accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(text: state.pillText, status: state.pillStatus)
                    Spacer(minLength: MTTheme.s2)
                    if state.isRunning {
                        Text("http://127.0.0.1:\(localRuntime.port)/v1")
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.emerald)
                    } else {
                        Text(LocalHardwareService.formatBytes(localStore.totalDiskBytes))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }

                if state.downloadedCount == 0 {
                    Text(L("Download GGUF models from Hugging Face or import local files."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    HStack(alignment: .top, spacing: MTTheme.s3) {
                        MTMetricTile(
                            title: L("Downloaded"),
                            value: "\(state.downloadedCount)",
                            caption: L("Models"),
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Ready"),
                            value: "\(state.readyCount)",
                            caption: L("Published"),
                            valueColor: state.readyCount > 0 ? MTTheme.emerald : MTTheme.textSecondary,
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Disk used"),
                            value: LocalHardwareService.formatBytes(localStore.totalDiskBytes),
                            caption: L("Storage"),
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Engine"),
                            value: state.isRunning ? L("Active") : L("Standby"),
                            caption: localRuntime.isBinaryAvailable ? "llama-server" : L("No binary"),
                            valueColor: state.isRunning ? MTTheme.emerald : MTTheme.textSecondary,
                            reservesMeterSpace: true
                        )
                    }
                }

                if let error = state.publicationError {
                    HStack(alignment: .top, spacing: MTTheme.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MTTheme.danger)
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Local Models"), systemImage: "cpu.fill", tint: MTTheme.emerald) {
                        selection = .localAI
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var antigravityCard: some View {
        let accounts = antigravityPool.accounts
        let connected = !accounts.isEmpty || usage.antigravity?.connected == true
        return MTCard(title: "Antigravity", systemImage: ProviderRoute.antigravity.systemImage, accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTStatusPill(
                        text: connected ? String(format: L("Accounts in the pool: %d"), accounts.count) : L("Not connected"),
                        status: connected ? .ok : .idle
                    )
                    Spacer(minLength: MTTheme.s2)
                    if let updated = antigravityPool.lastUpdated ?? usage.antigravity?.updatedAt {
                        Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                if let qos = gateway.lastQoS {
                    HStack(spacing: MTTheme.s1) {
                        Image(systemName: qos.timedOut ? "arrow.triangle.2.circlepath" : "bolt.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text(qos.timedOut
                             ? L("Last switch") + ": " + qos.auth + " · " + qos.model + " · " + String(qos.cooldownSeconds ?? 0) + " " + L("sec")
                             : L("First token") + ": " + String(qos.ttftMS ?? 0) + " ms · " + qos.model)
                            .font(MTTheme.mono(9))
                    }
                    .foregroundStyle(qos.timedOut ? MTTheme.warn : MTTheme.textTertiary)
                }
                if accounts.isEmpty {
                    Text(L("Connect your Google account to use Antigravity models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(accounts) { account in
                        antigravityAccountRow(account)
                    }
                }
                if let issue = antigravityIssue {
                    HStack(alignment: .top, spacing: MTTheme.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MTTheme.warn)
                        VStack(alignment: .leading, spacing: MTTheme.s1) {
                            Text(L("Antigravity verification required"))
                                .font(MTTheme.body(11, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            Text(issue.message)
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textSecondary)
                            if let url = issue.url, let target = URL(string: url) {
                                Button(L("Verify account")) {
                                    NSWorkspace.shared.open(target)
                                }
                                .buttonStyle(.link)
                                .font(MTTheme.mono(10, weight: .semibold))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(MTTheme.s2)
                    .background(MTTheme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
                }
                if let error = antigravityPool.lastError {
                    Text(error)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.danger)
                }
                AntigravityCatalogOnlyBlock(models: antigravityPool.catalogOnly)
                Text(L("The first-token timeout applies only to Antigravity accounts."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                sessionLine(provider: "Antigravity")
                HStack(spacing: MTTheme.s3) {
                    Text(L("Google account login; no API key is needed."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Add Google account"), systemImage: "person.badge.plus", tint: MTTheme.violet, isLoading: antigravityAuth.login.isBusy) {
                        Task { await antigravityAuth.startLogin() }
                    }
                    if !accounts.isEmpty {
                        MTGlassButton(title: L("Warm up all"), systemImage: "flame", tint: MTTheme.gold, isLoading: !antigravityPool.warmingUpAccountNames.isEmpty) {
                            Task { await antigravityPool.warmupAll() }
                        }
                    }
                    MTGlassButton(title: L("Refresh"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                        Task {
                            await antigravityPool.refresh(forceQuota: true)
                            antigravityIssue = AntigravityAuthService.latestVerificationIssue()
                        }
                    }
                    MTGlassButton(title: L("Settings"), systemImage: "slider.horizontal.3", tint: MTTheme.amber) {
                        route = .antigravity
                    }
                }
            }
        }
        .onAppear {
            antigravityIssue = AntigravityAuthService.latestVerificationIssue()
            antigravityPool.start()
            Task { await antigravityPool.refresh(forceQuota: false) }
        }
        .onDisappear { antigravityPool.stop() }
        .onChange(of: antigravityAuth.login) { value in
            if case .connected = value {
                Task { await antigravityPool.refresh(forceQuota: true) }
            }
        }
        .confirmationDialog(
            L("Remove this account from the pool?"),
            isPresented: Binding(
                get: { pendingAntigravityRemoval != nil },
                set: { if !$0 { pendingAntigravityRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Remove account"), role: .destructive) {
                if let account = pendingAntigravityRemoval {
                    pendingAntigravityRemoval = nil
                    Task {
                        await antigravityPool.remove(account)
                        _ = await antigravityAuth.refreshCredential()
                        await usage.refreshAntigravityNow()
                    }
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingAntigravityRemoval = nil }
        } message: {
            Text(pendingAntigravityRemoval?.email ?? pendingAntigravityRemoval?.name ?? "")
        }
        .sheet(item: $pendingProxyAccount) { account in
            antigravityProxySheet(account)
        }
    }

    /// One proxy per account. The reason this exists at all: Google ties an
    /// OAuth grant to the address it was issued from, so mixing a login from one
    /// country with traffic from another is itself a signal. Pinning each
    /// account to its own egress keeps that stable and stops one banned address
    /// from taking the whole pool down.
    private func antigravityProxySheet(_ account: AntigravityAccount) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            Text(L("Proxy for this account"))
                .font(MTTheme.body(13, weight: .semibold))
            Text(account.email ?? account.name)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            TextField("socks5://user:pass@host:port", text: $proxyDraft)
                .textFieldStyle(.roundedBorder)
                .font(MTTheme.mono(10))
            Text(L("Leave empty to use the global proxy. The engine applies the value without a restart."))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            HStack {
                Spacer()
                Button(L("Cancel")) { pendingProxyAccount = nil }
                Button(L("Save")) {
                    let value = proxyDraft
                    pendingProxyAccount = nil
                    Task {
                        _ = await AntigravityPoolStore.setProxy(name: account.name, proxyURL: value)
                        await antigravityPool.refresh(forceQuota: false)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MTTheme.s4)
        .frame(width: 420)
        .onAppear { proxyDraft = account.proxyURL ?? "" }
    }

    @ViewBuilder
    private func antigravityAccountRow(_ account: AntigravityAccount) -> some View {
        let cooldown = account.activeCooldown
        let isWarmingUp = antigravityPool.warmingUpAccountNames.contains(account.name)
        let status: MTStatus = account.isPaused ? .idle : cooldown != nil ? .warn : (isWarmingUp ? .running : .ok)
        let statusText = account.isPaused ? L("Paused") : cooldown != nil ? L("Quarantined") : (isWarmingUp ? L("Warming up...") : L("Connected"))
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                MTStatusPill(text: statusText, status: status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email ?? account.name)
                        .font(MTTheme.mono(10, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    if let project = account.projectID, !project.isEmpty {
                        Text(project)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                Spacer(minLength: MTTheme.s2)
                Text(String(format: L("Models in account: %d"), account.modelIDs.count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                if account.priority != 0 {
                    Text("P\(account.priority)")
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(MTTheme.gold)
                }
                MTMenuButton(systemImage: "ellipsis.circle", tint: MTTheme.textSecondary, entries: [
                    .item(L("Warm up account"), systemImage: "flame") {
                        Task {
                            _ = await antigravityPool.warmupAccount(account)
                        }
                    },
                    .item(L("Refresh sign-in"), systemImage: "arrow.clockwise") {
                        Task {
                            _ = await antigravityAuth.refreshCredential(name: account.name)
                            await antigravityPool.refresh(forceQuota: true)
                        }
                    },
                    .item(account.isPaused ? L("Resume account") : L("Pause account"),
                          systemImage: account.isPaused ? "play.circle" : "pause.circle") {
                        Task { _ = await antigravityPool.setPaused(account, paused: !account.isPaused) }
                    }
                ] + (AntigravityPoolStore.watchdogModels(in: account.cooldowns).isEmpty ? [] : [
                    // Only a first-token cooldown can be released by the probe;
                    // a quota or sign-in cooldown stays with the engine.
                    .item(L("Probe"), systemImage: "waveform.path.ecg") {
                        Task {
                            _ = await antigravityPool.probe(account)
                            await antigravityPool.refresh(forceQuota: true)
                        }
                    }
                ]) + [
                    .divider,
                    .item(L("Raise priority"), systemImage: "arrow.up") {
                        Task { _ = await antigravityPool.setPriority(account, priority: account.priority + 1) }
                    },
                    .item(L("Lower priority"), systemImage: "arrow.down") {
                        Task { _ = await antigravityPool.setPriority(account, priority: account.priority - 1) }
                    },
                    .divider,
                    .item(L("Bind proxy to this account"), systemImage: "network") {
                        pendingProxyAccount = account
                    },
                    .divider,
                    .item(L("Remove account"), systemImage: "trash", destructive: true) {
                        pendingAntigravityRemoval = account
                    }
                ])
            }
            if let cooldown {
                HStack(spacing: MTTheme.s1) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("Quarantined until") + " " + (cooldown.retryAt.map { Self.resetFormatter.string(from: $0) } ?? "—"))
                        .font(MTTheme.mono(9))
                    if let reason = Self.cooldownReason(cooldown) {
                        Text("· " + reason)
                            .font(MTTheme.mono(9))
                    }
                }
                .foregroundStyle(MTTheme.warn)
            }
            egressRow(account)
            if let gemini = account.geminiQuota {
                antigravityQuotaRow(title: L("Gemini pool"), window: gemini)
            }
            if let claude = account.claudeQuota {
                antigravityQuotaRow(title: L("Claude / GPT pool"), window: claude)
            }
            if account.geminiQuota == nil, account.claudeQuota == nil, let error = account.quotaError {
                // A ban or a denial is a real problem, not a quiet footnote:
                // the row has to look broken, because it is.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text(error)
                        .font(MTTheme.mono(9))
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(MTTheme.danger)
            }
        }
        .padding(MTTheme.s2)
        .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
    }

    @ViewBuilder
    private func antigravityQuotaRow(title: String, window: AntigravityQuotaWindow) -> some View {
        HStack(spacing: MTTheme.s2) {
            Text(title)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 92, alignment: .leading)
            ProgressView(value: min(1, max(0, window.remaining)))
                .progressViewStyle(.linear)
                .tint(window.remaining > 0.5 ? MTTheme.ok : window.remaining > 0.2 ? MTTheme.warn : MTTheme.danger)
                .frame(maxWidth: 220)
            Text("\(Int((window.remaining * 100).rounded()))%")
                .font(MTTheme.mono(9, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
                .frame(width: 38, alignment: .trailing)
            if let reset = window.resetAt {
                Text(L("Reset") + " " + Self.resetFormatter.string(from: reset))
                    .font(MTTheme.mono(8))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var connectAntigravityButton: some View {
        MTGlassButton(title: L("Connect Antigravity"), systemImage: "link", tint: MTTheme.emerald, prominent: true, isLoading: antigravityAuth.login.isBusy) {
            Task { await antigravityAuth.startLogin() }
        }
    }

    /// Disconnect removes only the Antigravity auth files. The selected models
    /// are cleared and the catalog regenerated so the picker drops the entries
    /// until the account is connected again.
    private func disconnectAntigravity() {
        antigravityAuth.disconnect()
        sources.setAllModels("antigravity", enabled: false)
        Task {
            await usage.refreshAntigravityNow()
            await sources.apply()
        }
    }

    /// Disconnect removes only the Claude auth files. The selected Claude
    /// models are cleared and the catalog regenerated too, so the Codex picker
    /// drops the entries instead of keeping models that can no longer run.
    private func disconnectClaude() {
        claudeAuth.disconnect()
        sources.setAllModels("claude", enabled: false)
        Task {
            await usage.refreshClaudeNow()
            await sources.apply()
        }
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func resetCaption(prefix: String, date: Date?) -> String {
        guard let date else { return prefix }
        return prefix + " · " + Self.resetFormatter.string(from: date)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        // Without an explicit zone the formatter follows the process locale, so a
        // row could render a reset instant in a zone the user never selected and
        // disagree with the same timestamp shown elsewhere in the app.
        formatter.timeZone = .current
        return formatter
    }()

    /// Why the account is quarantined: the badge alone cannot tell a
    /// first-token timeout from an exhausted Google quota window.
    /// The address Google actually sees for this account. Shown on the row so a
    /// geo or country mismatch is visible before it turns into a 403, instead
    /// of being buried in a global proxy setting.
    private func egressRow(_ account: AntigravityAccount) -> some View {
        HStack(spacing: MTTheme.s2) {
            Image(systemName: account.proxyURL == nil ? "globe" : "arrow.triangle.branch")
                .font(.system(size: 9))
            Text(account.proxyURL.map { Self.proxyLabel($0) } ?? L("Global proxy"))
                .font(MTTheme.mono(9))
                .lineLimit(1)
                .truncationMode(.middle)
            if account.proxyURL != nil {
                Button {
                    Task { _ = await AntigravityPoolStore.setProxy(name: account.name, proxyURL: "") ; await antigravityPool.refresh(forceQuota: false) }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help(L("Use the global proxy"))
            }
        }
        .foregroundStyle(MTTheme.textSecondary)
    }

    /// Credentials in a proxy URL must never reach the screen. Show scheme, host
    /// and port only, so a shared screenshot cannot leak the login pair.
    static func proxyLabel(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return L("Custom proxy") }
        components.user = nil
        components.password = nil
        let host = components.host ?? ""
        let port = components.port.map { ":\($0)" } ?? ""
        return (components.scheme ?? "proxy") + "://" + host + port
    }

    private static func cooldownReason(_ cooldown: AntigravityCooldown) -> String? {
        if cooldown.httpStatus == 504 { return L("Waiting for the first token") }
        switch cooldown.reason {
        case "quota", "credential_quota": return L("Quota exhausted")
        case "cloudflare_challenge": return L("Cloudflare challenge")
        case "unauthorized", "invalid_grant": return L("Sign in again")
        // 403 from Cloud Code splits three ways, and none of them is billing.
        // "payment_required" is the legacy label the gateway used for the whole
        // 403 family; existing cooldown snapshots may still carry it, so it maps
        // to the same explanation as an explicit TOS block.
        case "tos_violation", "payment_required": return L("Blocked by Google")
        case "validation_required": return L("Account frozen")
        case "model_not_supported": return L("Model not supported")
        case "transient_error": return L("Upstream error")
        default: return nil
        }
    }

    // MARK: - Shared rows

    private func keyValueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(title)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer(minLength: MTTheme.s2)
            Text(value)
                .font(MTTheme.mono(10, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
        }
    }

    /// Models of a source: selected share with a meter and a percent figure.
    private func modelsMeter(source: ModelSource) -> some View {
        let selected = source.selectedModels.count
        let total = source.models.count
        let share = total > 0 ? Double(selected) / Double(total) : nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L("Models").uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(String(format: L("Selected %d of %d"), selected, total)
                    + (share.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""))
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: share)
        }
    }

    /// Session numbers of one provider: spend estimate plus tokens, cache share
    /// and turns that this provider's models ran.
    @ViewBuilder
    private func sessionLine(provider: String) -> some View {
        let stats = usage.sessionSpend?.stats(for: provider)
        let amount = stats?.usd
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Session spend (estimate)").uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(MTTheme.textTertiary)
            Text(amount.map { "≈ " + money($0) } ?? "—")
                .font(MTTheme.display(18, weight: .semibold))
                .foregroundStyle(amount != nil ? MTTheme.textPrimary : MTTheme.textTertiary)
            if let stats, stats.turns > 0 {
                Text(sessionDetail(stats))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Text(sessionCaption(stats: stats, amount: amount))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    private func sessionDetail(_ stats: SessionSpend.ProviderStats) -> String {
        var parts = [L("Tokens") + " " + tokens(stats.tokens), L("Turns") + " " + "\(stats.turns)"]
        if let hit = stats.cacheHitPercent { parts.append(L("Cache") + " " + "\(hit)%") }
        return parts.joined(separator: " · ")
    }

    private func sessionCaption(stats: SessionSpend.ProviderStats?, amount: Double?) -> String {
        guard stats != nil else {
            return L("Session data appears when a thread runs this provider's models.")
        }
        if amount != nil {
            var caption = L("Estimated from tokens and the model price.")
            if usage.sessionSpend?.scaled == true {
                caption += " " + L("Older turns are outside the read window; the estimate is scaled.")
            }
            return caption
        }
        return L("No pricing data for this model.")
    }

    private func tokens(_ value: Int) -> String {
        let n = Double(value)
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", n / 1_000) }
        return "\(value)"
    }

    private func fraction(_ part: Double?, _ whole: Double?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return min(1, max(0, part / whole))
    }

    /// `$3.03`, `$30`, `$1000` — locale-independent, same as the composer chips.
    private func money(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005, value.magnitude >= 1 {
            return String(format: "$%.0f", rounded)
        }
        return String(format: "$%.2f", value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Settings sub-pages

    @ViewBuilder
    private func settingsPage(_ route: ProviderRoute) -> some View {
        HStack(spacing: MTTheme.s3) {
            MTGlassButton(title: L("Back"), systemImage: "chevron.left", tint: MTTheme.textSecondary) {
                self.route = nil
            }
            Spacer(minLength: 0)
        }
        MTPageHeader(
            kicker: "provider settings",
            title: String(format: L("Settings · %@"), route.title),
            subtitle: routeSubtitle(route)
        )
        switch route {
        case .openRouter:
            openRouterSettings
        case .openCode:
            openCodeSettings
        case .commandCode:
            commandCodeSettings
        case .deepInfra:
            deepInfraSettings
        case .nvidia:
            nvidiaSettings
        case .vercel:
            vercelSettings
        case .zai:
            zaiSettings
        case .claude:
            claudeSettings
        case .antigravity:
            antigravitySettings
        case .codexPool:
            codexPoolSettings
        }
        applyCard
    }

    private func routeSubtitle(_ route: ProviderRoute) -> String {
        switch route {
        case .openRouter: return L("Price routing: cheapest providers first.")
        case .openCode: return L("Paid models use your OpenCode account balance.")
        case .commandCode: return L("Models served by CommandCode with your provider API key.")
        case .deepInfra: return L("Chat models served by DeepInfra with your API key.")
        case .nvidia: return L("Models served by NVIDIA with your API key.")
        case .vercel: return L("Language models served by the Vercel AI Gateway with your gateway key.")
        case .zai: return L("GLM Coding Plan models served by Z.ai with your Coding Plan API key.")
        case .claude: return L("Connect your Claude subscription or paste an Anthropic API key.")
        case .antigravity: return L("Connect your Google account to use Antigravity models.")
        case .codexPool: return L("Codex models subtitle")
        }
    }

    private var openRouterSettings: some View {
        MTCard(title: "OpenRouter", systemImage: ProviderRoute.openRouter.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.openRouterKey) {
                    Task { await sources.loadOpenRouterModels() }
                }
                if let source = sources.openRouterSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the OpenRouter key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private var openCodeSettings: some View {
        MTCard(title: "OpenCode", systemImage: ProviderRoute.openCode.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.openCodeKey) {
                    Task { await sources.loadOpenCodeModels() }
                }
                if let source = sources.openCodeSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the OpenCode key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Go models route through the Go endpoints (Go plan); other models use the console balance."))
                    Text(L("Free OpenCode models only work inside the OpenCode app itself."))
                    Text(L("Paid models use your OpenCode account balance."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var commandCodeSettings: some View {
        MTCard(title: "CommandCode", systemImage: ProviderRoute.commandCode.systemImage, accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.commandCodeKey) {
                    Task { await sources.loadCommandCodeModels() }
                }
                if let source = sources.commandCodeSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the CommandCode key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("The CommandCode model list is public, so a wrong key only fails on the first request."))
                    Text(L("Claude models are served through /messages: the gateway gets them as an Anthropic upstream."))
                    Text(L("CommandCode publishes no prices, so the session estimate shows no cost for its models."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var deepInfraSettings: some View {
        MTCard(title: "DeepInfra", systemImage: ProviderRoute.deepInfra.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.deepInfraKey) {
                    Task { await sources.loadDeepInfraModels() }
                }
                if let source = sources.deepInfraSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the DeepInfra key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Only chat models are shown; DeepInfra filters out non-chat models."))
                    Text(L("DeepInfra API keys have no balance endpoint; the card shows model count and session spend only."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var nvidiaSettings: some View {
        MTCard(title: "NVIDIA", systemImage: ProviderRoute.nvidia.systemImage, accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.nvidiaKey) {
                    Task { await sources.loadNvidiaModels() }
                }
                if let source = sources.nvidiaSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the NVIDIA API key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Text(L("NVIDIA limit: 40 requests per minute per key. Requests wait when the limit is reached."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(L("NVIDIA's model list is public; the key is verified on the first request. Some listed models may not support chat."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var vercelSettings: some View {
        MTCard(title: "Vercel", systemImage: ProviderRoute.vercel.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.vercelKey) {
                    Task { await sources.loadVercelModels() }
                }
                if let source = sources.vercelSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the Vercel AI Gateway key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Use a Vercel AI Gateway key (AI_GATEWAY_API_KEY), not a personal Vercel token."))
                    Text(L("Balance and lifetime spend come from the team wallet."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var zaiSettings: some View {
        MTCard(title: "Z.ai", systemImage: ProviderRoute.zai.systemImage, accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyRow(key: $sources.zaiKey) {
                    Task { await sources.loadZaiModels() }
                }
                if let source = sources.zaiSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Paste the Z.ai Coding Plan key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Use a key from Personal Coding Plan → Plan Overview, not a standard API key."))
                    Text(L("The Coding endpoint is required for plan quota; the general API endpoint is billed per token."))
                    Text(L("GLM Coding Plan is limited to Z.ai's supported tools. Direct gateway use is at your own risk."))
                }
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var claudeSettings: some View {
        let stats = usage.claude
        let connected = stats?.connected == true
        return MTCard(title: "Claude", systemImage: ProviderRoute.claude.systemImage, accent: MTTheme.amber, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if connected {
                    keyValueRow(L("Account"), stats?.email ?? "—")
                    keyValueRow(L("Plan"), stats?.plan ?? "—")
                    HStack(spacing: MTTheme.s3) {
                        MTGlassButton(title: L("Refresh login"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                            Task {
                                _ = await claudeAuth.refreshCredential()
                                await usage.refreshClaudeNow()
                            }
                        }
                        MTGlassButton(title: L("Disconnect"), systemImage: "xmark.circle", tint: MTTheme.ruby) {
                            confirmClaudeDisconnect = true
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    switch claudeAuth.login {
                    case .starting, .waiting:
                        HStack(spacing: MTTheme.s2) {
                            ProgressView().controlSize(.small)
                            Text(L("Waiting for the browser…"))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        MTGlassButton(title: L("Cancel login"), systemImage: "xmark", tint: MTTheme.ruby) {
                            Task { await claudeAuth.cancelLogin() }
                        }
                    case .failed(let message):
                        Text(message)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.danger)
                        connectClaudeButton
                    default:
                        connectClaudeButton
                    }
                }
                Text(L("The login opens in your browser; the service stores the account itself."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)

                HStack(spacing: MTTheme.s2) {
                    SecureField(L("Anthropic API key (fallback)"), text: $sources.claudeKey)
                        .textFieldStyle(.mtInput)
                        .font(MTTheme.mono(11))
                        .frame(maxWidth: 360)
                    MTGlassButton(title: L("Load models"), systemImage: "arrow.down.circle", tint: MTTheme.cyan, prominent: true, isLoading: sources.isBusy) {
                        Task { await sources.loadClaudeModels() }
                    }
                    Spacer()
                }
                Text(L("The fallback key is only used when no OAuth account serves the models."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                if let source = sources.claudeSource {
                    modelBlock(source: source)
                } else {
                    Text(L("Start the service and connect an account, then load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
        .confirmationDialog(L("Disconnect this Claude account?"), isPresented: $confirmClaudeDisconnect, titleVisibility: .visible) {
            Button(L("Disconnect"), role: .destructive) {
                disconnectClaude()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(usage.claude?.email ?? "")
        }
    }

    private var antigravitySettings: some View {
        let accounts = antigravityPool.accounts
        return MTCard(title: "Antigravity", systemImage: ProviderRoute.antigravity.systemImage, accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if accounts.isEmpty {
                    Text(L("Connect your Google account to use Antigravity models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(accounts) { account in
                        antigravityAccountRow(account)
                    }
                }
                if let error = antigravityPool.lastError {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                }
                switch antigravityAuth.login {
                case .starting, .waiting:
                    HStack(spacing: MTTheme.s2) {
                        ProgressView().controlSize(.small)
                        Text(L("Waiting for the browser…"))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    MTGlassButton(title: L("Cancel login"), systemImage: "xmark", tint: MTTheme.ruby) {
                        Task { await antigravityAuth.cancelLogin() }
                    }
                case .failed(let message):
                    Text(message)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                default:
                    EmptyView()
                }
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Add Google account"), systemImage: "person.badge.plus", tint: MTTheme.violet, isLoading: antigravityAuth.login.isBusy) {
                        Task { await antigravityAuth.startLogin() }
                    }
                    if !accounts.isEmpty {
                        MTGlassButton(title: L("Warm up all"), systemImage: "flame", tint: MTTheme.gold, isLoading: !antigravityPool.warmingUpAccountNames.isEmpty) {
                            Task { await antigravityPool.warmupAll() }
                        }
                        MTGlassButton(title: L("Disconnect all"), systemImage: "xmark.circle", tint: MTTheme.ruby) {
                            confirmAntigravityDisconnect = true
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(L("The login opens in your browser; the service stores the account itself."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)

                Text(L("The first-token timeout applies only to Antigravity accounts."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)

                HStack(spacing: MTTheme.s2) {
                    MTGlassButton(title: L("Load models"), systemImage: "arrow.down.circle", tint: MTTheme.emerald, prominent: true, isLoading: sources.isBusy) {
                        Task { await sources.loadAntigravityModels() }
                    }
                    Spacer()
                }
                Text(L("Antigravity models are served by the engine from the connected Google account."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                AntigravityCatalogOnlyBlock(models: antigravityPool.catalogOnly)
                if let source = sources.antigravitySource {
                    modelBlock(source: source)
                } else {
                    Text(L("Start the service and connect an account, then load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
        .onAppear {
            antigravityPool.start()
            Task { await antigravityPool.refresh(forceQuota: false) }
        }
        .onDisappear { antigravityPool.stop() }
        .confirmationDialog(L("Disconnect this Antigravity account?"), isPresented: $confirmAntigravityDisconnect, titleVisibility: .visible) {
            Button(L("Disconnect"), role: .destructive) {
                disconnectAntigravity()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("Accounts in the pool: %d"), accounts.count))
        }
        .confirmationDialog(
            L("Remove this account from the pool?"),
            isPresented: Binding(
                get: { pendingAntigravityRemoval != nil },
                set: { if !$0 { pendingAntigravityRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Remove account"), role: .destructive) {
                if let account = pendingAntigravityRemoval {
                    pendingAntigravityRemoval = nil
                    Task {
                        await antigravityPool.remove(account)
                        _ = await antigravityAuth.refreshCredential()
                        await usage.refreshAntigravityNow()
                    }
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingAntigravityRemoval = nil }
        } message: {
            Text(pendingAntigravityRemoval?.email ?? pendingAntigravityRemoval?.name ?? "")
        }
    }

    // MARK: - Board: Codex pool models

    /// Global per-model toggles across the account pool. One switch writes
    /// every account at once; an account that would end with no model blocks
    /// the whole change (see `CodexStore.setPoolModel`).
    private var codexPoolSettings: some View {
        MTCard(title: L("Codex models"), systemImage: ProviderRoute.codexPool.systemImage, accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    Text(String(format: L("Models in pool: %d of %d"), poolUnionCount, pool.models.count))
                        .font(MTTheme.mono(10, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Load models"), systemImage: "arrow.down.circle", tint: MTTheme.cyan, isLoading: pool.isRefreshing) {
                        Task { await pool.refreshFromServer(accounts: store.accounts) }
                    }
                }
                Text(L("New models are off until you check them."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(L("Relaunch Codex to refresh the model picker."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                if let error = poolError ?? pool.refreshError {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                        .textSelection(.enabled)
                }
                HStack(spacing: MTTheme.s2) {
                    SelectAllControls(
                        search: $poolSearch,
                        placeholder: L("Search"),
                        onSelectAll: { query in
                            for model in filteredPool(matching: query) {
                                if !poolSupportedSlugs.contains(model.slug) {
                                    poolError = store.setPoolModel(model.slug, enabled: true)
                                    if poolError != nil { break }
                                }
                            }
                        },
                        onClear: { query in
                            for model in filteredPool(matching: query) {
                                if poolSupportedSlugs.contains(model.slug) {
                                    poolError = store.setPoolModel(model.slug, enabled: false)
                                    if poolError != nil { break }
                                }
                            }
                        }
                    )
                }
                poolModelList
            }
        }
    }

    private var poolModelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredPoolModels) { model in
                    poolModelRow(model)
                }
            }
            .padding(.vertical, MTTheme.s1)
        }
        .frame(height: 320)
        .background(MTTheme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.6), lineWidth: 0.75)
        )
    }

    /// Tri-state row: checked when every account supports the model, mixed
    /// when only some do, unchecked when none does.
    private func poolModelRow(_ model: CodexPoolModel) -> some View {
        let total = store.accounts.count
        let support = poolSupportCount(model.slug)
        return HStack(spacing: MTTheme.s2) {
            poolCheckbox(all: total > 0 && support == total, some: support > 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.display)
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                if model.display != model.slug {
                    Text(model.slug)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MTTheme.s2)
            if let context = model.contextLength, context > 0 {
                Text(context >= 1000 ? "\(context / 1000)K" : "\(context)")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Text(String(format: L("%d of %d accounts"), support, total))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { togglePoolModel(model.slug) }
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.display)
        .accessibilityValue("\(support)/\(total)")
        .accessibilityAddTraits(.isButton)
        .onKeyPress(.space) {
            togglePoolModel(model.slug)
            return .handled
        }
    }

    /// Pure-SwiftUI tri-state mark: one AppKit checkbox per row makes a long
    /// lazy list janky (same reasoning as `checkbox` in the model lists).
    private func poolCheckbox(all: Bool, some: Bool) -> some View {
        Image(systemName: all ? "checkmark.square.fill" : (some ? "minus.square.fill" : "square"))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(all || some ? MTTheme.gold : MTTheme.textTertiary)
    }

    private func filteredPool(matching query: String) -> [CodexPoolModel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return pool.models }
        return pool.models.filter {
            $0.slug.localizedCaseInsensitiveContains(trimmed) || $0.display.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var connectClaudeButton: some View {
        MTGlassButton(title: L("Connect Claude"), systemImage: "link", tint: MTTheme.amber, prominent: true, isLoading: claudeAuth.login.isBusy) {
            Task { await claudeAuth.startLogin() }
        }
    }

    // MARK: - Key + model list

    private func keyRow(key: Binding<String>, action: @escaping () -> Void) -> some View {
        HStack(spacing: MTTheme.s2) {
            SecureField(L("API key"), text: key)
                .textFieldStyle(.mtInput)
                .font(MTTheme.mono(11))
                .frame(maxWidth: 360)
            MTGlassButton(title: L("Load models"), systemImage: "arrow.down.circle", tint: MTTheme.cyan, prominent: true, isLoading: sources.isBusy, action: action)
            Spacer()
        }
    }

    private func modelBlock(source: ModelSource) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
              HStack(spacing: MTTheme.s2) {
                Toggle(isOn: Binding(
                    get: { source.enabled },
                    set: { sources.setSourceEnabled(source.id, enabled: $0) }
                )) {
                    Text(L("Enable source"))
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.textPrimary)
                }
                .toggleStyle(.checkbox)
                Text(String(format: L("Selected %d of %d"), source.selectedModels.count, source.models.count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
              }
              if source.kind == .openRouter {
                  Toggle(L("Free only"), isOn: $openRouterFreeOnly)
                      .toggleStyle(.checkbox)
                      .font(MTTheme.mono(10))
              }
              ScrollView(.horizontal, showsIndicators: false) {
                SelectAllControls(
                    search: searchBinding(source.id),
                    placeholder: L("Search"),
                    onSelectAll: { query in
                        sources.setAllModels(source.id, enabled: true, matching: query,
                                             freeOnly: source.kind == .openRouter && openRouterFreeOnly)
                    },
                    onClear: { query in
                        sources.setAllModels(source.id, enabled: false, matching: query,
                                             freeOnly: source.kind == .openRouter && openRouterFreeOnly)
                    }
                )
                .fixedSize(horizontal: true, vertical: false)
              }
            }
            modelList(source: source, height: 320)
        }
    }

    private func modelList(source: ModelSource, height: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered(source)) { model in
                    modelRow(sourceId: source.id, model: model)
                }
            }
            .padding(.vertical, MTTheme.s1)
        }
        .frame(height: height)
        .background(MTTheme.cardBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.6), lineWidth: 0.75)
        )
    }

    /// A pure-SwiftUI checkbox mark: real Toggles host an AppKit control per
    /// row, and re-hosting them while scrolling a 400+ row list shows as jank.
    private func checkbox(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.square.fill" : "square")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? MTTheme.gold : MTTheme.textTertiary)
    }

    /// Compact image-capability switch. A plain Button keeps the lazy list
    /// free of one AppKit control per row (see `checkbox` above).
    private func imagesToggle(sourceId: String, model: SourceModel) -> some View {
        let on = model.supportsImages == true
        return Button {
            sources.setModelSupportsImages(sourceId, modelId: model.id, supportsImages: !on)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "photo")
                Text(L("Images"))
            }
            .font(MTTheme.mono(9, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? MTTheme.gold : MTTheme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(on ? MTTheme.gold.opacity(0.12) : MTTheme.cardSoft.opacity(0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Images"))
        .accessibilityLabel(L("Images"))
        .accessibilityValue(on ? L("On") : L("Off"))
    }

    private func modelRow(sourceId: String, model: SourceModel) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s1) {
          HStack(spacing: MTTheme.s2) {
            Button {
                sources.setModel(sourceId, modelId: model.id, enabled: !model.enabled)
            } label: {
                HStack(spacing: MTTheme.s2) {
                    checkbox(model.enabled)
                    modelLabel(model)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.display)
            .accessibilityValue(model.enabled ? L("On") : L("Off"))
            .help(model.id)
            Spacer(minLength: MTTheme.s2)
            if model.goTier == true {
                MTStatusPill(text: "Go", status: .ok)
            }
            if sources.sources.first(where: { $0.id == sourceId })?.kind == .openRouter {
                if model.isOpenRouterFree { MTStatusPill(text: L("Free"), status: .ok) }
            } else if model.freeTier == true {
                MTStatusPill(text: L("App Only"), status: .ok)
            }
            imagesToggle(sourceId: sourceId, model: model)
            if let context = model.contextLength, context > 0 {
                Text(context >= 1000 ? "\(context / 1000)K" : "\(context)")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
          }

          if sources.sources.first(where: { $0.id == sourceId })?.kind == .openRouter {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: MTTheme.s2) {
                // Provider routing controls
                TextField(L("Provider slug"), text: Binding(
                    get: { model.provider ?? "" },
                    set: { sources.setModelProvider(sourceId, modelId: model.id, provider: $0.isEmpty ? nil : $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .font(MTTheme.mono(10))
                .help(L("Provider identifier help"))
                .accessibilityLabel(L("Provider slug"))

                Picker(L("Routing priority"), selection: Binding(
                    get: { model.sortOrder == "speed" ? "throughput" : (model.sortOrder ?? "price") },
                    set: { sources.setModelSortOrder(sourceId, modelId: model.id, sortOrder: $0) }
                )) {
                    Text(L("Price")).tag("price")
                    Text(L("Throughput")).tag("throughput")
                    Text(L("Latency")).tag("latency")
                }
                .labelsHidden()
                .frame(width: 180)
                .font(MTTheme.mono(10))
                .help(L("Routing priority help"))

                Toggle(L("Fallback"), isOn: Binding(
                    get: { model.fallback ?? true },
                    set: { sources.setModelFallback(sourceId, modelId: model.id, fallback: $0) }
                ))
                .font(MTTheme.mono(10))
                .help(L("Fallback help"))

                Toggle(L("Floor"), isOn: Binding(
                    get: { model.isFloorModel ?? false },
                    set: { sources.setModelIsFloorModel(sourceId, modelId: model.id, isFloorModel: $0) }
                ))
                .font(MTTheme.mono(10))
                .help(L("Floor help"))

                Toggle(L("Nitro"), isOn: Binding(
                    get: { model.isNitroModel ?? false },
                    set: { sources.setModelIsNitroModel(sourceId, modelId: model.id, isNitroModel: $0) }
                ))
                .font(MTTheme.mono(10))
                .help(L("Nitro help"))
              }
              .fixedSize(horizontal: true, vertical: false)
            }
          }
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, MTTheme.s1)
    }

    private func modelLabel(_ model: SourceModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.display)
                .font(MTTheme.body(12))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
            if model.display != model.id {
                Text(model.id)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func filtered(_ source: ModelSource) -> [SourceModel] {
        let query = (searches[source.id] ?? "").trimmingCharacters(in: .whitespaces)
        return source.models.filter { model in
            let freeMatches = source.kind != .openRouter || !openRouterFreeOnly || model.isOpenRouterFree
            return freeMatches && (query.isEmpty || model.id.localizedCaseInsensitiveContains(query) || model.display.localizedCaseInsensitiveContains(query))
        }
    }

    private func searchBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { searches[id] ?? "" },
            set: { searches[id] = $0 }
        )
    }

    // MARK: - Apply

    private var autoApply: Binding<Bool> {
        Binding(
            get: { ModelSourcesStore.autoApplyEnabled },
            set: { ModelSourcesStore.autoApplyEnabled = $0 }
        )
    }

    private var applyCard: some View {
        MTCard(title: L("Apply"), systemImage: "checkmark.seal", accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Apply"), systemImage: "checkmark", tint: MTTheme.emerald, prominent: true) {
                        Task { await sources.apply() }
                    }
                    MTGlassButton(title: L("Apply and relaunch Codex"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                        Task { await sources.applyAndRelaunch() }
                    }
                    Spacer()
                    Text(String(format: L("Selected %d of %d"), sources.selectedCount, sources.sources.reduce(0) { $0 + $1.models.count }))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                // Auto-apply is the default: a click on a model reaches the API
                // within a second, without this button.
                HStack(spacing: MTTheme.s2) {
                    Toggle(L("Apply model changes automatically"), isOn: autoApply)
                        .toggleStyle(.switch)
                        .tint(MTTheme.emerald)
                        .controlSize(.small)
                    Spacer()
                }
                Text(autoApply.wrappedValue
                     ? L("Every model you select is written to the gateway config and reloaded automatically.")
                     : L("Apply manually after changing the model selection."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                Text(String(format: L("Models in pool: %d of %d"), poolUnionCount, pool.models.count))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                if let note = sources.note {
                    Text(note)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                        .textSelection(.enabled)
                }
                if let lastApply = sources.lastApply {
                    Text(lastApply)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.gold)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private extension CodexGatewayService.Status {
    var pillStatus: MTStatus {
        switch self {
        case .running: return .ok
        case .starting: return .warn
        case .failed: return .error
        case .stopped: return .idle
        }
    }
}

/// Catalog models that no connected Antigravity account can use. Collapsed by
/// default: a pool can list dozens of ids and would otherwise turn the
/// provider card into a wall of unavailable names.
private struct AntigravityCatalogOnlyBlock: View {
    let models: [AntigravityCatalogOnlyModel]
    @State private var expanded = false

    var body: some View {
        if models.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: MTTheme.s1) {
                Divider()
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: MTTheme.s1) {
                        Text(L("The model is defined in the catalog, but none of the connected Google accounts is entitled to it."))
                            .font(MTTheme.mono(8))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 210), spacing: MTTheme.s2, alignment: .leading)],
                                alignment: .leading,
                                spacing: 4
                            ) {
                                ForEach(models) { model in
                                    HStack(spacing: MTTheme.s1) {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8, weight: .semibold))
                                        Text(model.displayName)
                                            .font(MTTheme.mono(9))
                                        Text(model.id)
                                            .font(MTTheme.mono(8))
                                            .foregroundStyle(MTTheme.textTertiary)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(MTTheme.textTertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 170)
                    }
                    .padding(.top, MTTheme.s1)
                } label: {
                    HStack(spacing: MTTheme.s1) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(L("In the catalog, unavailable to the account"))
                            .font(MTTheme.mono(9, weight: .semibold))
                            .foregroundStyle(MTTheme.textSecondary)
                        Text("\(models.count)")
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
            }
        }
    }
}

/// Search well + select-all/clear buttons shared by every model list.
private struct SelectAllControls: View {
    @Binding var search: String
    let placeholder: String
    let onSelectAll: (String) -> Void
    let onClear: (String) -> Void

    var body: some View {
        HStack(spacing: MTTheme.s2) {
            TextField(placeholder, text: $search)
                .textFieldStyle(.mtInput)
                .font(MTTheme.mono(10))
                .frame(width: 170)
            MTGlassButton(title: L("Select all"), size: .small, tint: MTTheme.cyan) { onSelectAll(search) }
                .fixedSize()
            MTGlassButton(title: L("Clear"), size: .small, tint: MTTheme.textSecondary) { onClear(search) }
                .fixedSize()
        }
    }
}

// MARK: - Custom provider editor

/// Initial values for the create/edit sheet. The sheet owns a working copy;
/// nothing reaches `ModelSourcesStore` until Save succeeds.
struct CustomProviderDraft: Identifiable {
    let id = UUID()
    let originalID: String?
    var identifier = ""
    var title = ""
    var baseURL = ""
    var apiProtocol: ModelSource.APIProtocol = .openAIChat
    var apiKey = ""
    var models: [SourceModel] = []

    init(source: ModelSource?) {
        originalID = source?.id
        identifier = source?.id ?? ""
        title = source?.title ?? ""
        baseURL = source?.baseURL ?? ""
        apiProtocol = source?.effectiveProtocol ?? .openAIChat
        apiKey = source?.apiKey ?? ""
        models = source?.models ?? []
    }
}

struct CustomProviderResult {
    var identifier: String
    var title: String
    var baseURL: String
    var apiProtocol: ModelSource.APIProtocol
    var apiKey: String
    var models: [SourceModel]
}

/// One sheet for both create and edit. Field order and wording follow the
/// provider sheet in the product design: identity, endpoint, protocol, key,
/// then the model list.
struct CustomProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: CustomProviderDraft
    let onSave: (CustomProviderResult) -> String?

    @State private var identifier: String
    @State private var title: String
    @State private var baseURL: String
    @State private var apiProtocol: ModelSource.APIProtocol
    @State private var apiKey: String
    @State private var models: [SourceModel]
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var error: String?
    @State private var addingModel = false
    @State private var newModelID = ""
    @State private var newModelDisplay = ""

    init(draft: CustomProviderDraft, onSave: @escaping (CustomProviderResult) -> String?) {
        self.draft = draft
        self.onSave = onSave
        _identifier = State(initialValue: draft.identifier)
        _title = State(initialValue: draft.title)
        _baseURL = State(initialValue: draft.baseURL)
        _apiProtocol = State(initialValue: draft.apiProtocol)
        _apiKey = State(initialValue: draft.apiKey)
        _models = State(initialValue: draft.models)
    }

    private var isEditing: Bool { draft.originalID != nil }

    private var identifierProblem: String? {
        ModelSourcesStore.customIdentifierProblem(identifier, sources: ModelSourcesStore.shared.sources, excluding: draft.originalID)
    }

    private var titleProblem: String? {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Enter a display name.") : nil
    }

    private var baseURLProblem: String? {
        ModelSourcesStore.normalizedBaseURL(baseURL) == nil ? L("Enter a valid http or https base URL.") : nil
    }

    private var keyProblem: String? {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Enter an API key.") : nil
    }

    private var modelsProblem: String? {
        models.contains(where: \.enabled) ? nil : L("Enable at least one model.")
    }

    private var canSave: Bool {
        identifierProblem == nil && titleProblem == nil && baseURLProblem == nil && keyProblem == nil && modelsProblem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: MTTheme.s3) {
                VStack(alignment: .leading, spacing: MTTheme.s1) {
                    Text(isEditing ? L("Edit provider") : L("New provider"))
                        .font(MTTheme.display(18))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Point Melon Tools at any relay, gateway or self-hosted endpoint."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }
            .padding(MTTheme.s5)

            Divider().overlay(MTTheme.borderColor)

            ScrollView {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("Provider identifier"))
                        TextField("acme-gateway", text: $identifier)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.mono(11))
                        if let problem = identifierProblem, !identifier.isEmpty {
                            footnote(problem, color: MTTheme.danger)
                        } else {
                            footnote(L("Lowercase letters, digits and hyphens. Used as the model prefix."), color: MTTheme.textTertiary)
                        }
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("Display name"))
                        TextField("Acme Gateway", text: $title)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.body(12))
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("Base URL"))
                        TextField("https://gateway.example/v1", text: $baseURL)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.mono(11))
                        if let problem = baseURLProblem, !baseURL.isEmpty {
                            footnote(problem, color: MTTheme.danger)
                        }
                        footnote(apiProtocol.baseURLHint, color: MTTheme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("API protocol"))
                        Picker("", selection: $apiProtocol) {
                            ForEach(ModelSource.APIProtocol.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 280, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("Custom provider API key"))
                        HStack(spacing: MTTheme.s2) {
                            SecureField(L("Custom provider API key"), text: $apiKey)
                                .textFieldStyle(.mtInput)
                                .font(MTTheme.mono(11))
                            MTGlassButton(
                                title: L("Get available models"),
                                systemImage: "arrow.down.circle",
                                tint: MTTheme.cyan,
                                prominent: true,
                                isLoading: isFetching
                            ) {
                                Task { await fetchModels() }
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURLProblem != nil || isFetching)
                        }
                        footnote(L("The key is stored in the app settings and written only to the local gateway config."), color: MTTheme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        HStack(spacing: MTTheme.s2) {
                            fieldLabel(L("Models"))
                            Text("\(models.count)")
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textTertiary)
                            Spacer(minLength: 0)
                            if !models.isEmpty {
                                Button(L("Select all")) { setAllModels(enabled: true) }
                                    .buttonStyle(.plain)
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.cyan)
                                Button(L("Clear")) { setAllModels(enabled: false) }
                                    .buttonStyle(.plain)
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textTertiary)
                            }
                        }
                        if let fetchError {
                            footnote(fetchError, color: MTTheme.danger)
                        }
                        if models.isEmpty {
                            VStack(spacing: MTTheme.s1) {
                                Text(L("No models yet"))
                                    .font(MTTheme.body(12))
                                    .foregroundStyle(MTTheme.textSecondary)
                                Text(L("Fetch the endpoint list or add a model id manually."))
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, MTTheme.s4)
                            .background(
                                RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                                    .strokeBorder(MTTheme.borderColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach($models) { $model in
                                    modelRow(model: $model)
                                    if model.id != models.last?.id {
                                        Divider().overlay(MTTheme.borderColor.opacity(0.6))
                                    }
                                }
                            }
                            .padding(.horizontal, MTTheme.s3)
                            .background(
                                RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                                    .fill(MTTheme.surface.opacity(0.6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                                            .strokeBorder(MTTheme.borderColor, lineWidth: 1)
                                    )
                            )
                        }
                        if addingModel {
                            HStack(spacing: MTTheme.s2) {
                                TextField(L("Model id"), text: $newModelID)
                                    .textFieldStyle(.mtInput)
                                    .font(MTTheme.mono(10))
                                TextField(L("Display name"), text: $newModelDisplay)
                                    .textFieldStyle(.mtInput)
                                    .font(MTTheme.mono(10))
                                MTGlassButton(title: L("Add"), tint: MTTheme.cyan) {
                                    addManualModel()
                                }
                                .disabled(newModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(L("Cancel")) {
                                    addingModel = false
                                    newModelID = ""
                                    newModelDisplay = ""
                                }
                                .buttonStyle(.plain)
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textTertiary)
                            }
                        } else {
                            Button {
                                addingModel = true
                            } label: {
                                Label(L("+ Add model"), systemImage: "plus")
                                    .font(MTTheme.mono(10, weight: .semibold))
                                    .foregroundStyle(MTTheme.cyan)
                            }
                            .buttonStyle(.plain)
                        }
                        if let problem = modelsProblem, !models.isEmpty {
                            footnote(problem, color: MTTheme.danger)
                        }
                    }
                }
                .padding(MTTheme.s5)
            }

            Divider().overlay(MTTheme.borderColor)

            HStack(spacing: MTTheme.s2) {
                if let error {
                    Text(error)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.danger)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                MTGlassButton(title: L("Cancel"), tint: MTTheme.textSecondary) { dismiss() }
                MTGlassButton(
                    title: isEditing ? L("Save provider") : L("Create provider"),
                    systemImage: "checkmark",
                    tint: MTTheme.violet,
                    prominent: true
                ) {
                    save()
                }
                .disabled(!canSave)
            }
            .padding(MTTheme.s5)
        }
        .frame(width: 640, height: 720)
        .background(MTTheme.background)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(MTTheme.mono(9, weight: .semibold))
            .foregroundStyle(MTTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func footnote(_ text: String, color: Color) -> some View {
        Text(text)
            .font(MTTheme.mono(9))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelRow(model: Binding<SourceModel>) -> some View {
        HStack(spacing: MTTheme.s2) {
            Toggle("", isOn: model.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(L("Enable model"))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.wrappedValue.display.isEmpty ? model.wrappedValue.id : model.wrappedValue.display)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: MTTheme.s2) {
                    Text(model.wrappedValue.id)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                        .lineLimit(1)
                    if let context = model.wrappedValue.contextLength, context > 0 {
                        Text(String(format: L("%@ context"), formattedTokens(context)))
                            .font(MTTheme.mono(8))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                let id = model.wrappedValue.id
                models.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(L("Remove model"))
            .accessibilityLabel(L("Remove model"))
        }
        .padding(.vertical, MTTheme.s2)
    }

    private func formattedTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }

    private func setAllModels(enabled: Bool) {
        for index in models.indices { models[index].enabled = enabled }
    }

    private func addManualModel() {
        let id = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !models.contains(where: { $0.id == id }) else { return }
        let display = newModelDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        models.append(SourceModel(
            id: id,
            display: display.isEmpty ? id : display,
            contextLength: nil,
            enabled: true,
            alias: ModelSourcesStore.customAlias(identifier: identifier, modelID: id)
        ))
        newModelID = ""
        newModelDisplay = ""
        addingModel = false
    }

    private func fetchModels() async {
        isFetching = true
        fetchError = nil
        do {
            let fetched = try await ModelSourcesStore.shared.fetchCustomModels(
                identifier: identifier,
                baseURL: baseURL,
                apiProtocol: apiProtocol,
                apiKey: apiKey
            )
            var merged = fetched
            for existing in models where !merged.contains(where: { $0.id == existing.id }) {
                merged.append(existing)
            }
            for index in merged.indices {
                if let old = models.first(where: { $0.id == merged[index].id }) {
                    merged[index].enabled = old.enabled
                    if !old.display.isEmpty, old.display != old.id { merged[index].display = old.display }
                }
            }
            models = ModelSourcesStore.normalizedCustomModels(identifier: identifier, models: merged)
        } catch {
            fetchError = error.localizedDescription
        }
        isFetching = false
    }

    private func save() {
        let result = CustomProviderResult(
            identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiProtocol: apiProtocol,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            models: models
        )
        error = onSave(result)
        if error == nil { dismiss() }
    }
}
