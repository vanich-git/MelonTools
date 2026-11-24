import AppKit
import SwiftUI

/// Providers: the Codex account pool, the OAuth providers and every key-based
/// model source. The board is a grouped list, one row per provider; a row opens
/// the provider's own page with its connection, models, accounts, routing and
/// advanced sections.
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
    @ObservedObject private var antigravityPool = AntigravityPoolStore.shared
    @Binding var selection: MTSection

    @State private var route: ProviderRoute?
    @State private var providerSection: ProviderSection = .connection
    @State private var searches: [String: String] = [:]
    @State private var openRouterFreeOnly = false
    @State private var poolSearch = ""
    @State private var poolError: String?
    @State private var confirmClaudeDisconnect = false
    @State private var confirmAntigravityDisconnect = false
    @State private var antigravityIssue: AntigravityAuthService.VerificationIssue?
    @State private var pendingAntigravityRemoval: AntigravityAccount?
    @State private var pendingProxyAccount: AntigravityAccount?
    @State private var proxyDraft: String = ""
    @State private var customEditor: CustomProviderDraft?
    @State private var pendingCustomRemoval: ModelSource?
    @State private var presetPickerShown = false

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

        var accent: Color {
            switch self {
            case .openRouter, .openCode, .deepInfra, .vercel, .codexPool: return MTTheme.cyan
            case .commandCode, .zai: return MTTheme.violet
            case .nvidia, .antigravity: return MTTheme.emerald
            case .claude: return MTTheme.amber
            }
        }

        /// The model source behind a key-based provider, when it has one.
        var sourceID: String? {
            switch self {
            case .openRouter: return "openrouter"
            case .openCode: return "opencode"
            case .commandCode: return "commandcode"
            case .deepInfra: return "deepinfra"
            case .nvidia: return "nvidia"
            case .vercel: return "vercel"
            case .zai: return "zai"
            case .claude: return "claude"
            case .antigravity: return "antigravity"
            case .codexPool: return nil
            }
        }
    }

    /// Sections of a provider page. Accounts only appear for providers that own
    /// a credential list instead of a single key.
    enum ProviderSection: String, CaseIterable, Identifiable {
        case connection
        case models
        case accounts
        case routing
        case advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connection: return L("Connection")
            case .models: return L("Models")
            case .accounts: return L("Accounts")
            case .routing: return L("Routing")
            case .advanced: return L("Advanced")
            }
        }

        var systemImage: String {
            switch self {
            case .connection: return "cable.connector"
            case .models: return "square.grid.2x2"
            case .accounts: return "person.2"
            case .routing: return "arrow.triangle.branch"
            case .advanced: return "gearshape.2"
            }
        }
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter
    }()

    static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                if let route {
                    settingsPage(route)
                } else {
                    providerBoard
                }
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: route) { _, _ in
            providerSection = .connection
        }
        .sheet(item: $customEditor) { draft in
            CustomProviderSheet(draft: draft) { result in
                sources.saveCustomSource(
                    originalID: draft.originalID,
                    identifier: result.identifier,
                    title: result.title,
                    baseURL: result.baseURL,
                    apiProtocol: result.apiProtocol,
                    apiKey: result.apiKey,
                    priority: result.priority,
                    models: result.models
                )
            }
        }
        .sheet(isPresented: $presetPickerShown) {
            ProviderPresetPicker(
                configured: configuredPresetIDs,
                onPick: { preset in
                    presetPickerShown = false
                    open(preset)
                }
            )
        }
        .confirmationDialog(
            L("Remove this provider?"),
            isPresented: Binding(
                get: { pendingCustomRemoval != nil },
                set: { if !$0 { pendingCustomRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Remove"), role: .destructive) {
                if let source = pendingCustomRemoval {
                    pendingCustomRemoval = nil
                    sources.removeCustomSource(id: source.id)
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingCustomRemoval = nil }
        } message: {
            Text(pendingCustomRemoval?.title ?? "")
        }
    }

    // MARK: - Board

    private var providerBoard: some View {
        VStack(alignment: .leading, spacing: MTTheme.s5) {
            MTPageHeader(
                kicker: "melon tools",
                title: L("Providers"),
                subtitle: L("Providers subtitle")
            )
            MTListCard {
                VStack(spacing: 0) {
                    codexRow
                    MTRowSeparator()
                    claudeRow
                    MTRowSeparator()
                    antigravityRow
                    MTRowSeparator()
                    keySourceRow(.openRouter)
                    MTRowSeparator()
                    keySourceRow(.openCode)
                    MTRowSeparator()
                    keySourceRow(.commandCode)
                    MTRowSeparator()
                    keySourceRow(.deepInfra)
                    MTRowSeparator()
                    keySourceRow(.nvidia)
                    MTRowSeparator()
                    keySourceRow(.vercel)
                    MTRowSeparator()
                    keySourceRow(.zai)
                    if !sources.customSources.isEmpty {
                        ForEach(sources.customSources) { source in
                            MTRowSeparator()
                            customSourceRow(source)
                        }
                    }
                    MTRowSeparator()
                    localAIRow
                }
            }
            HStack(spacing: MTTheme.s3) {
                MTGlassButton(title: L("Add provider"), systemImage: "plus", tint: MTTheme.gold) {
                    presetPickerShown = true
                }
                MTGlassButton(title: L("Add custom provider"), systemImage: "slider.horizontal.3", tint: MTTheme.violet) {
                    customEditor = CustomProviderDraft(source: nil)
                }
                Spacer(minLength: 0)
            }
            diagnosticsCard
            applyCard
        }
    }

    // MARK: - Provider rows

    private var codexSubtitle: String {
        let accounts = store.accounts.count
        let models = poolUnionCount
        return String(format: L("%d accounts · %d models"), accounts, models)
    }

    private var codexRow: some View {
        MTRow(
            title: "Codex",
            subtitle: codexSubtitle,
            systemImage: ProviderRoute.codexPool.systemImage,
            accent: ProviderRoute.codexPool.accent,
            action: { route = .codexPool }
        ) {
            HStack(spacing: MTTheme.s2) {
                MTBadge(text: gateway.status.label, tint: gateway.status.pillStatus.color)
                MTKeyPill(
                    status: gateway.isRunning ? .ok : .idle,
                    key: gateway.apiKey,
                    placeholder: L("OAuth")
                )
            }
        }
    }

    private var claudeSubtitle: String {
        if let stats = usage.claude, stats.connected {
            if let email = stats.email, !email.isEmpty {
                return String(format: L("signed in as %@"), email)
            }
            return L("Connected")
        }
        let models = sources.claudeSource?.selectedModels.count ?? 0
        return "api.anthropic.com · " + String(format: L("Models: %d"), models)
    }

    private var claudeRow: some View {
        MTRow(
            title: "Claude",
            subtitle: claudeSubtitle,
            systemImage: ProviderRoute.claude.systemImage,
            accent: ProviderRoute.claude.accent,
            action: { route = .claude }
        ) {
            HStack(spacing: MTTheme.s2) {
                if !sources.claudeKey.isEmpty {
                    MTKeyPill(status: .ok, key: sources.claudeKey)
                } else {
                    MTKeyPill(
                        status: usage.claude?.connected == true ? .ok : .idle,
                        key: "",
                        placeholder: usage.claude?.connected == true ? L("Connected") : L("No key")
                    )
                }
            }
        }
    }

    private var antigravitySubtitle: String {
        let accounts = antigravityPool.accounts.count
        let models = sources.antigravitySource?.selectedModels.count ?? 0
        if accounts == 0 {
            return "generativelanguage.googleapis.com · " + String(format: L("Models: %d"), models)
        }
        return String(format: L("%d accounts · %d models"), accounts, models)
    }

    private var antigravityRow: some View {
        MTRow(
            title: "Antigravity",
            subtitle: antigravitySubtitle,
            systemImage: ProviderRoute.antigravity.systemImage,
            accent: ProviderRoute.antigravity.accent,
            action: { route = .antigravity }
        ) {
            MTKeyPill(
                status: antigravityPool.accounts.isEmpty ? .idle : .ok,
                key: "",
                placeholder: antigravityPool.accounts.isEmpty ? L("Not connected") : L("Connected")
            )
        }
    }

    private func sourceKey(_ route: ProviderRoute) -> String {
        switch route {
        case .openRouter: return sources.openRouterKey
        case .openCode: return sources.openCodeKey
        case .commandCode: return sources.commandCodeKey
        case .deepInfra: return sources.deepInfraKey
        case .nvidia: return sources.nvidiaKey
        case .vercel: return sources.vercelKey
        case .zai: return sources.zaiKey
        case .claude: return sources.claudeKey
        case .antigravity, .codexPool: return ""
        }
    }

    private func sourceHost(_ route: ProviderRoute) -> String {
        let baseURL: String
        switch route {
        case .openRouter: baseURL = ModelSourcesStore.openRouterBaseURL
        case .openCode: baseURL = ModelSourcesStore.openCodeBaseURL
        case .commandCode: baseURL = ModelSourcesStore.commandCodeBaseURL
        case .deepInfra: baseURL = ModelSourcesStore.deepInfraBaseURL
        case .nvidia: baseURL = ModelSourcesStore.nvidiaBaseURL
        case .vercel: baseURL = ModelSourcesStore.vercelBaseURL
        case .zai: baseURL = ModelSourcesStore.zaiBaseURL
        case .claude: baseURL = "https://api.anthropic.com"
        case .antigravity: baseURL = "https://generativelanguage.googleapis.com"
        case .codexPool: baseURL = ""
        }
        return ProviderCatalog.host(baseURL)
    }

    private func keySourceRow(_ route: ProviderRoute) -> some View {
        let source = route.sourceID.flatMap { sources.source(id: $0) }
        let models = source?.selectedModels.count ?? 0
        let key = sourceKey(route)
        let configured = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let subtitle = sourceHost(route) + " · " + String(format: L("Models: %d"), models)
        return MTRow(
            title: route.title,
            subtitle: subtitle,
            systemImage: route.systemImage,
            accent: route.accent,
            action: { self.route = route }
        ) {
            HStack(spacing: MTTheme.s3) {
                if route == .openRouter, let balance = usage.openRouter?.creditsRemaining {
                    MTBadge(text: money(balance), tint: MTTheme.emerald)
                }
                MTKeyPill(status: configured ? .ok : .idle, key: key)
                if let source {
                    Toggle("", isOn: Binding(
                        get: { source.enabled },
                        set: { sources.setSourceEnabled(source.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(MTTheme.emerald)
                    .accessibilityLabel(String(format: L("Enable %@"), route.title))
                    .accessibilityValue(L("On"))
                }
            }
        }
    }

    private func customSourceRow(_ source: ModelSource) -> some View {
        let models = source.selectedModels.count
        let subtitle = ProviderCatalog.host(source.baseURL) + " · " + String(format: L("Models: %d"), models)
        return MTRow(
            title: source.title,
            subtitle: subtitle,
            systemImage: "server.rack",
            accent: MTTheme.violet,
            action: { customEditor = CustomProviderDraft(source: source) }
        ) {
            HStack(spacing: MTTheme.s2) {
                MTBadge(text: source.effectiveProtocol.title, tint: MTTheme.violet)
                MTKeyPill(status: source.apiKey.isEmpty ? .idle : .ok, key: source.apiKey)
                Toggle("", isOn: Binding(
                    get: { source.enabled },
                    set: { sources.setCustomSourceEnabled(source.id, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(MTTheme.emerald)
                .accessibilityLabel(String(format: L("Enable %@"), source.title))
                    .accessibilityValue(L("On"))
                MTMenuButton(systemImage: "ellipsis.circle", tint: MTTheme.textSecondary, entries: [
                    .item(L("Edit"), systemImage: "pencil") {
                        customEditor = CustomProviderDraft(source: source)
                    },
                    .divider,
                    .item(L("Remove"), systemImage: "trash", destructive: true) {
                        pendingCustomRemoval = source
                    }
                ])
            }
        }
    }

    private var localAIRow: some View {
        let ready = localStore.models.filter { $0.runtimeStatus == .ready }.count
        let subtitle = (localRuntime.isBinaryAvailable ? "llama-server" : L("No binary"))
            + " · \(ready) " + L("ready")
        return MTRow(
            title: L("Local AI"),
            subtitle: subtitle,
            systemImage: "cpu.fill",
            accent: MTTheme.emerald,
            action: { selection = .localAI }
        ) {
            MTBadge(
                text: localRuntime.status.isRunning ? L("Running") : L("Standby"),
                tint: localRuntime.status.isRunning ? MTTheme.emerald : MTTheme.textTertiary
            )
        }
    }

    // MARK: - Add provider

    /// Presets that already have a configured key: the picker marks them as
    /// connected instead of offering the same provider twice.
    private var configuredPresetIDs: Set<String> {
        var ids: Set<String> = []
        if !sources.openRouterKey.isEmpty { ids.insert("openrouter") }
        if !sources.openCodeKey.isEmpty { ids.insert("opencode") }
        if !sources.commandCodeKey.isEmpty { ids.insert("commandcode") }
        if !sources.deepInfraKey.isEmpty { ids.insert("deepinfra") }
        if !sources.nvidiaKey.isEmpty { ids.insert("nvidia") }
        if !sources.vercelKey.isEmpty { ids.insert("vercel") }
        if !sources.zaiKey.isEmpty { ids.insert("zai") }
        if !sources.claudeKey.isEmpty || usage.claude?.connected == true { ids.insert("claude") }
        if !antigravityPool.accounts.isEmpty { ids.insert("antigravity") }
        if !store.accounts.isEmpty { ids.insert("codex") }
        for source in sources.customSources { ids.insert(source.id) }
        return ids
    }

    private func open(_ preset: ProviderPreset) {
        if let route = preset.builtinRoute {
            self.route = route
            return
        }
        var draft = CustomProviderDraft(source: nil)
        draft.identifier = preset.id
        draft.title = preset.title
        draft.baseURL = preset.baseURL
        draft.apiProtocol = preset.apiProtocol
        customEditor = draft
    }

    // MARK: - Provider page

    private func providerSections(for route: ProviderRoute) -> [ProviderSection] {
        switch route {
        case .codexPool, .claude, .antigravity:
            return [.connection, .models, .accounts, .routing, .advanced]
        default:
            return [.connection, .models, .routing, .advanced]
        }
    }

    private func settingsPage(_ route: ProviderRoute) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack(alignment: .center, spacing: MTTheme.s3) {
                Button {
                    self.route = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MTTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("Back to providers"))
                .accessibilityLabel(L("Back to providers"))
                    .accessibilityValue(L("Back"))

                MTGlyphTile(systemImage: route.systemImage, accent: route.accent, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title)
                        .font(MTTheme.display(21))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(routeSubtitle(route))
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: MTTheme.s2)
                MTStatusPill(text: providerStatusText(route), status: providerStatus(route))
            }
            MTChipPicker(
                items: providerSections(for: route),
                title: { $0.title },
                selection: $providerSection,
                accent: MTTheme.gold
            )
            providerSectionContent(route)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            L("Disconnect this Claude account?"),
            isPresented: $confirmClaudeDisconnect,
            titleVisibility: .visible
        ) {
            Button(L("Disconnect"), role: .destructive) { disconnectClaude() }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Disconnect this Antigravity account?"),
            isPresented: $confirmAntigravityDisconnect,
            titleVisibility: .visible
        ) {
            Button(L("Disconnect"), role: .destructive) { disconnectAntigravity() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("Accounts in the pool: %d"), antigravityPool.accounts.count))
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
        .onAppear {
            if route == .antigravity {
                antigravityIssue = AntigravityAuthService.latestVerificationIssue()
                antigravityPool.start()
                Task { await antigravityPool.refresh(forceQuota: false) }
            }
        }
        .onDisappear {
            if route == .antigravity { antigravityPool.stop() }
        }
    }

    @ViewBuilder
    private func providerSectionContent(_ route: ProviderRoute) -> some View {
        switch providerSection {
        case .connection: connectionSection(route)
        case .models: modelsSection(route)
        case .accounts: accountsSection(route)
        case .routing: routingSection(route)
        case .advanced: advancedSection(route)
        }
    }

    private func routeSubtitle(_ route: ProviderRoute) -> String {
        switch route {
        case .codexPool:
            return L("Codex models subtitle")
        case .claude:
            return usage.claude?.email ?? "api.anthropic.com"
        case .antigravity:
            return "generativelanguage.googleapis.com"
        default:
            return sourceHost(route)
        }
    }

    private func providerStatus(_ route: ProviderRoute) -> MTStatus {
        switch route {
        case .codexPool:
            return gateway.status.pillStatus
        case .claude:
            return usage.claude?.connected == true || !sources.claudeKey.isEmpty ? .ok : .idle
        case .antigravity:
            return antigravityPool.accounts.isEmpty ? .idle : .ok
        default:
            let key = sourceKey(route).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? .idle : .ok
        }
    }

    private func providerStatusText(_ route: ProviderRoute) -> String {
        switch route {
        case .codexPool:
            return gateway.status.label
        case .claude:
            if usage.claude?.connected == true { return L("Connected") }
            return sources.claudeKey.isEmpty ? L("Not connected") : L("Key configured")
        case .antigravity:
            return antigravityPool.accounts.isEmpty
                ? L("Not connected")
                : String(format: L("Accounts in the pool: %d"), antigravityPool.accounts.count)
        default:
            return sourceKey(route).isEmpty ? L("No key") : L("Key configured")
        }
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
            Text(amount.map { "≈ " + money($0) } ?? "-")
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
        if amount == nil {
            return L("Prices are unknown for these models, so the estimate is hidden.")
        }
        return L("Estimate from list prices and the tokens this app saw.")
    }

    private func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " " + L("M")
        }
        if value >= 1_000 {
            return (Double(value) / 1_000).formatted(.number.precision(.fractionLength(1))) + " " + L("K")
        }
        return "\(value)"
    }

    private func fraction(_ part: Double?, _ whole: Double?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return min(1, max(0, part / whole))
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int(value.rounded()))%"
    }

    private func resetCaption(prefix: String, date: Date?) -> String {
        guard let date else { return prefix }
        return prefix + " · " + Self.resetFormatter.string(from: date)
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
            modelList(source: source)
        }
    }

    private func modelList(source: ModelSource) -> some View {
        // One scroller for the page; see poolModelList.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(filtered(source)) { model in
                modelRow(sourceId: source.id, model: model)
            }
        }
        .padding(.vertical, MTTheme.s1)
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
                    .accessibilityValue(L("Preview"))
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
                    .accessibilityValue(L("Model"))
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
                .textFieldStyle(.mtInput(size: .small))
                .frame(width: 130)
                .font(MTTheme.mono(10))
                .help(L("Provider identifier help"))
                .accessibilityLabel(L("Provider slug"))

                MTSelect(
                    selection: Binding(
                        get: { model.sortOrder == "speed" ? "throughput" : (model.sortOrder ?? "price") },
                        set: { sources.setModelSortOrder(sourceId, modelId: model.id, sortOrder: $0) }
                    ),
                    options: [
                        ("price", L("Price")),
                        ("throughput", L("Throughput")),
                        ("latency", L("Latency"))
                    ],
                    width: 190
                )
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

    // MARK: - Pool helpers used by the Codex page

    /// Pool-wide share of quota still available (mean over accounts with data).
    func poolQuota(_ keyPath: KeyPath<CodexQuota, Double?>) -> Double? {
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

    private func poolSupportCount(_ slug: String) -> Int {
        store.accounts.filter { store.effectiveSelectedModels(for: $0).contains(slug) }.count
    }

    private var poolUnionCount: Int {
        CodexPoolModelsStore.unionSelection(
            accounts: store.accounts,
            poolSlugs: pool.slugs
        ).count
    }

    private var filteredPoolModels: [CodexPoolModel] {
        filteredPool(matching: poolSearch)
    }

    private func filteredPool(matching query: String) -> [CodexPoolModel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return pool.models }
        return pool.models.filter {
            $0.slug.localizedCaseInsensitiveContains(trimmed) || $0.display.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func togglePoolModel(_ slug: String) {
        poolError = store.setPoolModel(slug, enabled: !poolSupportedSlugs.contains(slug))
    }
}


// MARK: - Provider page sections

/// Content of the five provider sections. Kept in an extension of the same
/// file so it can reach the board's private stores and helpers without
/// widening their access.
extension CodexProvidersView {

    // MARK: Connection

    @ViewBuilder
    func connectionSection(_ route: ProviderRoute) -> some View {
        switch route {
        case .openRouter: openRouterConnection
        case .openCode: openCodeConnection
        case .commandCode: keyConnection(route, notes: [
            L("The CommandCode model list is public, so a wrong key only fails on the first request."),
            L("Claude models are served through /messages: the gateway gets them as an Anthropic upstream."),
            L("CommandCode publishes no prices, so the session estimate shows no cost for its models."),
        ])
        case .deepInfra: keyConnection(route, notes: [
            L("Only chat models are shown; DeepInfra filters out non-chat models."),
            L("DeepInfra API keys have no balance endpoint; the card shows model count and session spend only."),
        ])
        case .nvidia: keyConnection(route, notes: [
            L("NVIDIA limit: 40 requests per minute per key. Requests wait when the limit is reached."),
            L("NVIDIA's model list is public; the key is verified on the first request. Some listed models may not support chat."),
        ])
        case .vercel: vercelConnection
        case .zai: keyConnection(route, notes: [
            L("Use a key from Personal Coding Plan → Plan Overview, not a standard API key."),
            L("The Coding endpoint is required for plan quota; the general API endpoint is billed per token."),
            L("GLM Coding Plan is limited to Z.ai's supported tools. Direct gateway use is at your own risk."),
        ])
        case .claude: claudeConnection
        case .antigravity: antigravityConnection
        case .codexPool: codexConnection
        }
    }

    private var openRouterConnection: some View {
        let stats = usage.openRouter
        let budget = fraction(stats?.keyUsage, stats?.keyLimit)
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                keyRow(key: $sources.openRouterKey) {
                    Task { await sources.loadOpenRouterModels() }
                }
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        MTMetricTile(
                            title: L("Available"),
                            value: stats.creditsRemaining.map(money) ?? "-",
                            caption: L("Credits left on the account"),
                            tint: MTTheme.emerald
                        )
                        MTMetricTile(
                            title: L("Key spent"),
                            value: stats.keyUsage.map(money) ?? "-",
                            caption: stats.keyLimit.map { L("Limit") + " " + money($0) } ?? L("No key limit"),
                            fraction: budget,
                            tint: budget.map { $0 > 0.85 ? MTTheme.ruby : MTTheme.cyan } ?? MTTheme.cyan,
                            reservesMeterSpace: true
                        )
                        MTMetricTile(
                            title: L("Models"),
                            value: "\(sources.openRouterSource?.selectedModels.count ?? 0)",
                            caption: L("Selected in this app")
                        )
                    }
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: MTTheme.s3) {
                        MTGlassButton(title: L("Refresh balance"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                            Task { await usage.refresh(force: true) }
                        }
                        if let updated = stats.updatedAt {
                            Text(L("Updated") + " " + Self.timeFormatter.string(from: updated))
                                .font(MTTheme.mono(9))
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    sessionLine(provider: "openrouter")
                } else {
                    Text(L("Paste the OpenRouter key to load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private var openCodeConnection: some View {
        let stats = usage.openCode
        let goCount = sources.openCodeSource?.models.filter { $0.goTier == true }.count ?? 0
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                keyRow(key: $sources.openCodeKey) {
                    Task { await sources.loadOpenCodeModels() }
                }
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        MTMetricTile(title: L("Workspace"), value: stats.workspace ?? "-", caption: stats.orgID ?? L("Personal"))
                        MTMetricTile(title: L("Go models"), value: "\(goCount)", caption: L("Covered by the Go plan"))
                        MTMetricTile(title: L("Models"), value: "\(sources.openCodeSource?.selectedModels.count ?? 0)", caption: L("Selected in this app"))
                    }
                } else {
                    keyValueRow(L("Workspace"), "-")
                }
                sessionLine(provider: "opencode")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Go models route through the Go endpoints (Go plan); other models use the console balance."))
                    Text(L("Free OpenCode models only work inside the OpenCode app itself."))
                    Text(L("Paid models use your OpenCode account balance."))
                }
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Open console"), systemImage: "arrow.up.forward.app", tint: MTTheme.cyan) {
                        if let url = URL(string: "https://opencode.ai/console") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func keyConnection(_ route: ProviderRoute, notes: [String]) -> some View {
        let source = route.sourceID.flatMap { sources.source(id: $0) }
        let binding: Binding<String> = {
            switch route {
            case .commandCode: return $sources.commandCodeKey
            case .deepInfra: return $sources.deepInfraKey
            case .nvidia: return $sources.nvidiaKey
            case .zai: return $sources.zaiKey
            default: return .constant("")
            }
        }()
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: route.accent) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                keyRow(key: binding) {
                    Task {
                        switch route {
                        case .commandCode: await sources.loadCommandCodeModels()
                        case .deepInfra: await sources.loadDeepInfraModels()
                        case .nvidia: await sources.loadNvidiaModels()
                        case .zai: await sources.loadZaiModels()
                        default: break
                        }
                    }
                }
                if source != nil {
                    modelsMeter(source: source!)
                }
                sessionLine(provider: providerSessionKey(route))
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(note)
                        }
                    }
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private var vercelConnection: some View {
        let stats = usage.vercel
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                keyRow(key: $sources.vercelKey) {
                    Task { await sources.loadVercelModels() }
                }
                if let stats {
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        MTMetricTile(title: L("Balance"), value: stats.balance.map(money) ?? "-", caption: L("Team wallet"), tint: MTTheme.emerald)
                        MTMetricTile(title: L("Lifetime spend"), value: stats.totalUsed.map(money) ?? "-", caption: L("All requests"))
                        MTMetricTile(title: L("Models"), value: "\(sources.vercelSource?.selectedModels.count ?? 0)", caption: L("Selected in this app"))
                    }
                    if let error = stats.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                }
                sessionLine(provider: "vercel")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Use a Vercel AI Gateway key (AI_GATEWAY_API_KEY), not a personal Vercel token."))
                    Text(L("Balance and lifetime spend come from the team wallet."))
                }
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var claudeConnection: some View {
        let stats = usage.claude
        let connected = stats?.connected == true
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.amber) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                if connected {
                    HStack(alignment: .top, spacing: MTTheme.s4) {
                        MTMetricTile(title: L("Account"), value: stats?.email ?? "-", caption: L("Claude subscription"))
                        MTMetricTile(title: L("Plan"), value: stats?.plan ?? "-", caption: L("Reported by Anthropic"))
                        MTMetricTile(title: L("Models"), value: "\(stats?.modelCount ?? 0)", caption: L("Available to the account"))
                    }
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
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Divider()
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
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                sessionLine(provider: "claude")
            }
        }
    }

    private var antigravityConnection: some View {
        let accounts = antigravityPool.accounts
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                HStack(alignment: .top, spacing: MTTheme.s4) {
                    MTMetricTile(title: L("Accounts"), value: "\(accounts.count)", caption: L("Google accounts in the pool"))
                    MTMetricTile(title: L("Models"), value: "\(sources.antigravitySource?.selectedModels.count ?? 0)", caption: L("Selected in this app"))
                    MTMetricTile(
                        title: L("Catalog only"),
                        value: "\(antigravityPool.catalogOnly.count)",
                        caption: L("Not entitled to any account")
                    )
                }
                if accounts.isEmpty {
                    Text(L("Connect your Google account to use Antigravity models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
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
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                sessionLine(provider: "Antigravity")
            }
        }
    }

    private var codexConnection: some View {
        let health = poolHealth
        return MTCard(title: L("Connection"), systemImage: "cable.connector", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                    Text("\(store.accounts.count)")
                        .font(MTTheme.display(30))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Accounts"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer(minLength: MTTheme.s2)
                    MTBadge(text: L("OAuth"), tint: MTTheme.violet)
                }
                if let pause = store.poolPauseSummary() {
                    CodexPoolPauseBanner(summary: pause)
                }
                quotaRow(title: L("5 h"), fraction: poolQuota(\.hourlyRemainingPercent))
                quotaRow(title: L("Week"), fraction: poolQuota(\.weeklyRemainingPercent))
                HStack(spacing: MTTheme.s4) {
                    healthStat(L("Working"), count: health.working, status: .ok)
                    healthStat(L("Failed"), count: health.failed, status: .error)
                    healthStat(L("Paused"), count: health.paused, status: .warn)
                }
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Manage accounts"), systemImage: "person.2", tint: MTTheme.cyan, prominent: true) {
                        selection = .codexAccounts
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                keyValueRow(L("Gateway"), gateway.baseURL)
                keyValueRow(L("API key"), gateway.apiKey.isEmpty ? "-" : L("Stored in the app settings"))
            }
        }
    }

    // MARK: Models

    @ViewBuilder
    func modelsSection(_ route: ProviderRoute) -> some View {
        if route == .codexPool {
            codexModelsCard
        } else if let source = route.sourceID.flatMap({ sources.source(id: $0) }) {
            MTCard(title: L("Models"), systemImage: "square.grid.2x2", accent: route.accent) {
                VStack(alignment: .leading, spacing: MTTheme.s3) {
                    modelsMeter(source: source)
                    modelBlock(source: source)
                }
            }
        } else {
            MTCard(title: L("Models"), systemImage: "square.grid.2x2", accent: route.accent) {
                VStack(alignment: .leading, spacing: MTTheme.s3) {
                    Text(L("Start the service and connect an account, then load the model list."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    MTGlassButton(title: L("Load models"), systemImage: "arrow.down.circle", tint: route.accent, prominent: true, isLoading: sources.isBusy) {
                        Task {
                            switch route {
                            case .claude: await sources.loadClaudeModels()
                            case .antigravity: await sources.loadAntigravityModels()
                            default: break
                            }
                        }
                    }
                }
            }
        }
    }

    private var codexModelsCard: some View {
        MTCard(title: L("Models"), systemImage: "square.grid.2x2", accent: MTTheme.cyan) {
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
        // The page already scrolls, so this list must not: a capped inner
        // scroller trapped the wheel and the page stopped at its edge.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(filteredPoolModels) { model in
                poolModelRow(model)
            }
        }
        .padding(.vertical, MTTheme.s1)
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
                    .accessibilityValue(L("Model"))
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

    // MARK: Accounts

    @ViewBuilder
    func accountsSection(_ route: ProviderRoute) -> some View {
        switch route {
        case .claude: claudeAccounts
        case .antigravity: antigravityAccounts
        case .codexPool: codexAccounts
        default: EmptyView()
        }
    }

    private var claudeAccounts: some View {
        let stats = usage.claude
        return MTCard(title: L("Accounts"), systemImage: "person.2", accent: MTTheme.amber) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                if stats?.connected == true {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s2) {
                            MTStatusPill(text: L("Connected"), status: .ok)
                            Text(stats?.email ?? "-")
                                .font(MTTheme.mono(10, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            Spacer(minLength: MTTheme.s2)
                            if let plan = stats?.plan {
                                MTBadge(text: plan, tint: MTTheme.amber)
                            }
                        }
                        quotaRow(title: L("5 h"), fraction: fraction(stats?.fiveHourPercent, 100))
                        quotaRow(title: L("Week"), fraction: fraction(stats?.weeklyPercent, 100))
                        Text(L("Reset") + " " + resetCaption(prefix: "", date: stats?.fiveHourReset))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                    .padding(MTTheme.s3)
                    .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
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
                    Text(L("No Claude subscription account is connected. The API key on the Connection tab still works."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    connectClaudeButton
                }
                sessionLine(provider: "claude")
            }
        }
    }

    private var antigravityAccounts: some View {
        let accounts = antigravityPool.accounts
        return MTCard(title: L("Accounts"), systemImage: "person.2", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if accounts.isEmpty {
                    Text(L("Connect your Google account to use Antigravity models."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                    connectAntigravityButton
                } else {
                    ForEach(accounts) { account in
                        antigravityAccountRow(account)
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
                AntigravityCatalogOnlyBlock(models: antigravityPool.catalogOnly)
                sessionLine(provider: "Antigravity")
            }
        }
    }

    private var codexAccounts: some View {
        MTCard(title: L("Accounts"), systemImage: "person.2", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if store.accounts.isEmpty {
                    Text(L("No Codex accounts yet. Import them on the Accounts screen."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(store.accounts) { account in
                        codexAccountSummary(account)
                    }
                }
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Manage accounts"), systemImage: "person.2", tint: MTTheme.cyan, prominent: true) {
                        selection = .codexAccounts
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func codexAccountSummary(_ account: CodexAccount) -> some View {
        let quota = account.quota
        let paused = account.poolEnabled == false || (quota?.hourlyRemainingPercent ?? 1) <= 0
        return VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                MTStatusDot(status: paused ? .idle : (account.quotaError != nil ? .error : .ok), size: 6)
                Text(account.email ?? account.accountId ?? account.id)
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                if let plan = account.planType {
                    MTBadge(text: plan, tint: MTTheme.violet)
                }
                Spacer(minLength: MTTheme.s2)
                Text(String(format: L("Models: %d"), store.effectiveSelectedModels(for: account).count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            if let quota {
                quotaRow(title: L("5 h"), fraction: quota.hourlyRemainingPercent.map { min(1, max(0, $0 / 100)) })
                quotaRow(title: L("Week"), fraction: quota.weeklyRemainingPercent.map { min(1, max(0, $0 / 100)) })
            }
            if let error = account.quotaError {
                Text(error)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(MTTheme.s3)
        .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
    }

    // MARK: Routing

    func routingSection(_ route: ProviderRoute) -> some View {
        MTCard(title: L("Routing"), systemImage: "arrow.triangle.branch", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                HStack(spacing: MTTheme.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Gateway strategy").uppercased())
                            .font(MTTheme.mono(9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(CodexGatewayService.gatewayStrategy.title)
                            .font(MTTheme.mono(11, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                    }
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Open Routing"), systemImage: "arrow.triangle.branch", tint: MTTheme.cyan) {
                        selection = .routing
                    }
                }
                Text(routeRoutingNote(route))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if route == .openRouter {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Per-model upstream routing (provider slug, price or speed, fallback) is set in the model list."))
                        Text(L("OpenRouter applies those fields per request; the gateway keeps its own retry."))
                    }
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                }
                if route == .codexPool || route == .claude || route == .antigravity {
                    Text(L("Accounts are ordered by priority inside this provider. Higher priority numbers are tried first."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private func routeRoutingNote(_ route: ProviderRoute) -> String {
        switch route {
        case .openRouter:
            return L("OpenRouter models take part in gateway routing like any other upstream.")
        case .openCode:
            return L("Go models and paid models use different endpoints; the gateway routes each model to the matching base URL.")
        case .commandCode:
            return L("Claude models go through the Anthropic upstream; every other model uses the OpenAI-compatible upstream.")
        case .deepInfra, .nvidia, .vercel, .zai:
            return L("Models of this provider are grouped under the gateway provider entry of the same name.")
        case .claude:
            return L("The Claude subscription is one upstream with its own quota windows; the account is used until a window runs out.")
        case .antigravity:
            return L("Google accounts share one upstream; the pool picks an account and fails over to the next one when the first token is late.")
        case .codexPool:
            return L("Codex accounts are balanced by quota and priority; the planner pauses an account that hits its reserve.")
        }
    }

    private func providerSessionKey(_ route: ProviderRoute) -> String {
        switch route {
        case .openRouter: return "openrouter"
        case .openCode: return "opencode"
        case .commandCode: return "commandcode"
        case .deepInfra: return "deepinfra"
        case .nvidia: return "nvidia"
        case .vercel: return "vercel"
        case .zai: return "zai"
        case .claude: return "claude"
        case .antigravity: return "Antigravity"
        case .codexPool: return "codex"
        }
    }

    // MARK: Advanced

    func advancedSection(_ route: ProviderRoute) -> some View {
        MTCard(title: L("Advanced"), systemImage: "gearshape.2", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                keyValueRow(L("Base URL"), routeBaseURL(route))
                keyValueRow(L("Protocol"), routeProtocol(route))
                if let source = route.sourceID.flatMap({ sources.source(id: $0) }) {
                    keyValueRow(L("Source identifier"), source.id)
                    keyValueRow(L("Enabled"), source.enabled ? L("On") : L("Off"))
                }
                keyValueRow(L("Gateway"), gateway.baseURL)
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Check connection"), systemImage: "checklist", tint: MTTheme.cyan, isLoading: diagnostics.isRunning) {
                        Task { await diagnostics.run() }
                    }
                    MTGlassButton(title: L("Apply config"), systemImage: "checkmark.seal", tint: MTTheme.emerald) {
                        Task { await sources.apply() }
                    }
                    Spacer(minLength: 0)
                }
                Text(routeAdvancedNote(route))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = sources.lastApply {
                    Text(note)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.gold)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func routeBaseURL(_ route: ProviderRoute) -> String {
        if let source = route.sourceID.flatMap({ sources.source(id: $0) }) {
            return source.baseURL
        }
        switch route {
        case .codexPool: return gateway.baseURL
        default: return "-"
        }
    }

    private func routeProtocol(_ route: ProviderRoute) -> String {
        if let source = route.sourceID.flatMap({ sources.source(id: $0) }) {
            return source.effectiveProtocol.title
        }
        switch route {
        case .codexPool: return L("Codex responses API")
        default: return "-"
        }
    }

    private func routeAdvancedNote(_ route: ProviderRoute) -> String {
        switch route {
        case .codexPool:
            return L("The pool is served by the local gateway; Codex points at it with the API key above.")
        case .claude:
            return L("OAuth auth files live in the gateway auth folder; the fallback key is written to config.yaml.")
        case .antigravity:
            return L("Antigravity auth files are managed by the engine; proxy binding is per account.")
        default:
            return L("The provider entry is written to config.yaml and hot-reloaded by the engine.")
        }
    }

    // MARK: Shared bits of the sections

    func quotaRow(title: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title.uppercased())
                    .font(MTTheme.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "-")
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
            }
            MTMeter(fraction: fraction)
        }
    }

    func healthStat(_ title: String, count: Int, status: MTStatus) -> some View {
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

    private var connectClaudeButton: some View {
        MTGlassButton(title: L("Connect Claude"), systemImage: "link", tint: MTTheme.cyan, prominent: true, isLoading: claudeAuth.login.isBusy) {
            Task { await claudeAuth.startLogin() }
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

    // MARK: Antigravity rows

    private func antigravityProxySheet(_ account: AntigravityAccount) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            Text(L("Proxy for this account"))
                .font(MTTheme.body(13, weight: .semibold))
            Text(account.email ?? account.name)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            TextField("socks5://user:pass@host:port", text: $proxyDraft)
                .textFieldStyle(.mtInput)
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
                    Text(L("Quarantined until") + " " + (cooldown.retryAt.map { Self.resetFormatter.string(from: $0) } ?? "-"))
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

    static func cooldownReason(_ cooldown: AntigravityCooldown) -> String? {
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
}

extension CodexGatewayService.Status {
    var pillStatus: MTStatus {
        switch self {
        case .running: return .ok
        case .starting: return .warn
        case .failed: return .error
        case .stopped: return .idle
        }
    }
}

extension CodexProvidersView {
    /// Presentation state for the Local AI summary. Only `.ready` rows are
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
                return String(format: L("Ready: %d"), readyCount) + " · " + L("engine stopped")
            case .runningNoReady:
                return L("Running · no ready models")
            case .downloadedOnly:
                return String(format: L("Downloaded: %d"), downloadedCount) + " · " + L("none ready")
            case .empty:
                return L("No models")
            }
        }
    }
}
