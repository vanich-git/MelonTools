import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var composer = ComposerBridge.shared

    @AppStorage("gatewayAutoStart") private var gatewayAutoStart = true
    @AppStorage("gatewayStopOnQuit") private var gatewayStopOnQuit = false
    @AppStorage("networkProxyEnabled") private var networkProxyEnabled = false
    @AppStorage("networkProxyURL") private var savedProxyURL = ""
    @AppStorage("networkProxyBypass") private var networkProxyBypass = "127.0.0.1,localhost"
    @State private var proxyURLDraft = ""
    @State private var proxyURLSaved = false
    @AppStorage("streamBootstrapTimeoutSeconds") private var streamBootstrapTimeoutSeconds = 60
    @AppStorage("quotaRefreshInterval") private var quotaRefreshInterval = 300
    @AppStorage("quotaNotifications") private var quotaNotifications = false
    @AppStorage(NotchHUDController.enabledDefaultsKey) private var notchHUDEnabled = true
    @AppStorage(NotchHUDController.styleDefaultsKey) private var notchHUDCompactStyle = NotchHUDCompactStyle.inside.rawValue
    @AppStorage("taskNotifications") private var taskNotifications = true
    @AppStorage(DashboardWidgetKey.poolHealth) private var showPoolHealth = true
    @AppStorage(DashboardWidgetKey.antigravityPool) private var showAntigravityPool = true
    @AppStorage(DashboardWidgetKey.spend) private var showSpend = true
    @AppStorage(DashboardWidgetKey.scheduler) private var showScheduler = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    @State private var backupPassword = ""
    @State private var backupTask: Task<Void, Never>?
    @State private var backupBusy = false
    @State private var backupNotice: String?
    @State private var backupNoticeIsError = false
    @State private var backupRefresh = 0
    @State private var supportNotice: String?
    @State private var pendingImportURL: URL?

    private var proxyURLIsDirty: Bool {
        proxyURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != savedProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveProxyURL() {
        let trimmed = proxyURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        proxyURLDraft = trimmed
        savedProxyURL = trimmed
        CodexGatewayService.shared.applyNetworkSettings()
        withAnimation(.easeOut(duration: 0.15)) { proxyURLSaved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { proxyURLSaved = false }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(kicker: "melon tools", title: L("Settings"), subtitle: L("Settings subtitle"))

                MTCard(title: L("Appearance"), systemImage: "paintbrush", accent: MTTheme.amber, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Theme"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            MTSegmented(selection: $app.appearance, options: AppState.Appearance.allCases.map {
                                ($0, $0.title)
                            }, width: 280)
                            .onChange(of: app.appearance) { app.applyAppearance() }
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Language"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            MTSegmented(selection: $l10n.code, options: L10n.available.map {
                                ($0.code, $0.title)
                            }, width: 280)
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Accent"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Circle()
                                .fill(MTTheme.amber)
                                .frame(width: 16, height: 16)
                            Text(L("golden melon"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Status island"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            Toggle(L("Show a compact island at the top of the screen"), isOn: $notchHUDEnabled)
                                .toggleStyle(.switch)
                                .font(MTTheme.body(12))
                                .onChange(of: notchHUDEnabled) { _, enabled in
                                    NotchHUDController.shared.setEnabled(enabled)
                                }
                        }
                        if notchHUDEnabled {
                            HStack(spacing: MTTheme.s3) {
                                Text(L("Compact island"))
                                    .font(MTTheme.mono(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                                    .frame(width: 130, alignment: .leading)
                                MTSegmented(selection: $notchHUDCompactStyle, options: NotchHUDCompactStyle.allCases.map {
                                    ($0.rawValue, $0.title)
                                }, width: 280)
                                .onChange(of: notchHUDCompactStyle) { _, value in
                                    NotchHUDController.shared.setCompactStyle(
                                        NotchHUDCompactStyle(rawValue: value) ?? .inside
                                    )
                                }
                            }
                        }
                    }
                }

                MTCard(title: L("Network / Proxy"), systemImage: "network", accent: MTTheme.cyan, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Toggle(L("Use proxy for OpenAI and providers"), isOn: $networkProxyEnabled)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Proxy URL"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            HStack(spacing: MTTheme.s2) {
                                TextField("socks5h://127.0.0.1:1080", text: $proxyURLDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(MTTheme.mono(11))
                                    .frame(width: 300)
                                    .onSubmit { saveProxyURL() }
                                if proxyURLIsDirty {
                                    Button(action: saveProxyURL) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(MTTheme.onGold)
                                            .frame(width: 27, height: 27)
                                            .background(Circle().fill(MTTheme.gold))
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("Save proxy URL"))
                                    .accessibilityLabel(L("Save proxy URL"))
                                    .transition(.scale.combined(with: .opacity))
                                } else if proxyURLSaved {
                                    MTStatusPill(text: L("Saved"), status: .ok)
                                        .transition(.opacity)
                                }
                            }
                            .animation(.easeOut(duration: 0.15), value: proxyURLIsDirty)
                        }
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Bypass"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            TextField("127.0.0.1,localhost", text: $networkProxyBypass)
                                .textFieldStyle(.roundedBorder)
                                .font(MTTheme.mono(11))
                                .frame(width: 300)
                        }
                        Text(L("Leave the URL empty to use the macOS system proxy. The local gateway always stays direct."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .onAppear {
                        // A new visit starts from the saved value: an unsaved
                        // edit must not survive navigating away and back.
                        proxyURLDraft = savedProxyURL
                        proxyURLSaved = false
                    }
                    .onDisappear {
                        proxyURLDraft = savedProxyURL
                        proxyURLSaved = false
                    }
                    .onChange(of: savedProxyURL) { newValue in
                        if !proxyURLIsDirty { proxyURLDraft = newValue }
                    }
                    .onChange(of: networkProxyEnabled) { _ in
                        CodexGatewayService.shared.applyNetworkSettings()
                    }
                    .onChange(of: networkProxyBypass) { _ in
                        CodexGatewayService.shared.applyNetworkSettings()
                    }
                }

                MTCard(title: L("Antigravity first-token failover"), systemImage: "speedometer", accent: MTTheme.emerald, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Toggle(L("Switch Antigravity accounts when the first token is slow"), isOn: Binding(
                            get: { streamBootstrapTimeoutSeconds > 0 },
                            set: { enabled in
                                streamBootstrapTimeoutSeconds = enabled ? 60 : 0
                                CodexGatewayService.shared.applyStreamBootstrapTimeout()
                            }
                        ))
                        .toggleStyle(.switch)
                        .font(MTTheme.body(12))

                        HStack(spacing: MTTheme.s3) {
                            Text(L("First token timeout"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 180, alignment: .leading)
                            Stepper(value: Binding(
                                get: { max(15, streamBootstrapTimeoutSeconds) },
                                set: { streamBootstrapTimeoutSeconds = $0; CodexGatewayService.shared.applyStreamBootstrapTimeout() }
                            ), in: 15...300, step: 15) {
                                Text("\(streamBootstrapTimeoutSeconds) " + L("sec"))
                                    .font(MTTheme.mono(11))
                                    .foregroundStyle(streamBootstrapTimeoutSeconds > 0 ? MTTheme.textPrimary : MTTheme.textTertiary)
                            }
                            .disabled(streamBootstrapTimeoutSeconds == 0)
                        }
                        Text(L("Antigravity only: if the first token does not arrive in time, the engine retries the request on another Google account before the client sees the stream. Codex, Claude and API-key providers are not affected. The slow account cools down for 60 s, then 5 min, 30 min and 2 h on repeated failures."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MTCard(title: L("Dashboard widgets"), systemImage: "square.grid.2x2", accent: MTTheme.cyan, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(L("Show pool health"), isOn: $showPoolHealth)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show Antigravity pool health"), isOn: $showAntigravityPool)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show spend & top providers"), isOn: $showSpend)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Show scheduler summary"), isOn: $showScheduler)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                    }
                }

                MTCard(title: L("Codex"), systemImage: "arrow.triangle.2.circlepath", accent: MTTheme.violet, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(isOn: $composer.autoRetryEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Auto-continue after capacity errors"))
                                    .font(MTTheme.body(12))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text(L("Press Codex Retry automatically. If Codex stops offering Retry, send a short continuation message."))
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(MTTheme.amber)
                        if let last = composer.lastAutoRetryAt {
                            Text(L("Last automatic action:") + " " + last.formatted(date: .omitted, time: .shortened))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                    }
                }

                MTCard(title: L("Service settings"), systemImage: "network", accent: MTTheme.cyan, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(L("Start the service at app launch"), isOn: $gatewayAutoStart)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Stop the service on quit"), isOn: $gatewayStopOnQuit)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Text(L("When “stop on quit” is off, the service keeps running in the background and the app adopts it on the next launch."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        if let loginItemError {
                            Text(loginItemError)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.danger)
                        }
                    }
                }

                MTCard(title: L("Quotas section"), systemImage: "gauge.with.dots.needle.33percent", accent: MTTheme.emerald, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Auto-refresh"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            MTSelect(selection: $quotaRefreshInterval, options: [
                                (0, L("Off")),
                                (60, L("1 min")),
                                (300, L("5 min")),
                                (900, L("15 min")),
                                (1800, L("30 min")),
                            ], width: 160)
                            .onChange(of: quotaRefreshInterval) {
                                CodexStore.shared.startQuotaScheduler()
                            }
                        }
                        Toggle(L("Notifications when quota is low"), isOn: $quotaNotifications)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Notifications after scheduled runs"), isOn: $taskNotifications)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                        Toggle(L("Launch at login"), isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .font(MTTheme.body(12))
                            .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                    }
                }

                MTCard(title: L("Backup"), systemImage: "externaldrive.badge.timemachine", accent: MTTheme.amber, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Text(L("Encrypted backup of the scheduler, settings, accounts with auth files and model sources. Logs and gateway keys are not included."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        HStack(spacing: MTTheme.s3) {
                            Text(L("Backup password"))
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 130, alignment: .leading)
                            SecureField(L("Password"), text: $backupPassword)
                                .textFieldStyle(.roundedBorder)
                                .font(MTTheme.mono(11))
                                .frame(width: 240)
                                .disabled(backupBusy)
                        }
                        HStack(spacing: MTTheme.s2) {
                            MTGlassButton(title: L("Export backup…"), systemImage: "square.and.arrow.up", tint: MTTheme.amber, prominent: true) {
                                exportBackup()
                            }
                            MTGlassButton(title: L("Import backup…"), systemImage: "square.and.arrow.down", tint: MTTheme.amber) {
                                chooseBackupToImport()
                            }
                        }
                        .disabled(backupBusy)
                        if backupBusy {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(L("Processing backup…"))
                                Button(L("Cancel")) { backupTask?.cancel() }
                            }
                            .font(MTTheme.mono(11))
                        }
                        Text(lastBackupText)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textTertiary)
                        if let backupNotice {
                            Text(backupNotice)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(backupNoticeIsError ? MTTheme.danger : MTTheme.ok)
                        }
                    }
                }
                .onAppear { backupRefresh += 1 }
                .alert(
                    L("Restore backup?"),
                    isPresented: Binding(
                        get: { pendingImportURL != nil },
                        set: { if !$0 { pendingImportURL = nil } }
                    ),
                    presenting: pendingImportURL
                ) { url in
                    Button(L("Import"), role: .destructive) {
                        pendingImportURL = nil
                        importBackup(from: url)
                    }
                    Button(L("Cancel"), role: .cancel) {
                        pendingImportURL = nil
                    }
                } message: { url in
                    Text(String(format: L("The live scheduler, settings, accounts and auth files will be replaced by “%@”."), url.lastPathComponent))
                }

                MTCard(title: L("Support bundle"), systemImage: "ladybug", accent: MTTheme.ruby, isBento: true) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Text(L("Export a redacted diagnostics file: versions, gateway state, log tails and file sizes. Tokens and keys are removed."))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        MTGlassButton(title: L("Export support bundle…"), systemImage: "square.and.arrow.up", tint: MTTheme.ruby) {
                            exportSupportBundle()
                        }
                        if let supportNotice {
                            Text(supportNotice)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                }

                MTCard(title: L("About"), systemImage: "info.circle", accent: MTTheme.amber, isBento: true) {
                    HStack(alignment: .center, spacing: MTTheme.s3) {
                        MelonAssets.logoImage(size: 48)
                        VStack(alignment: .leading, spacing: MTTheme.s2) {
                            Text("Melon Tools \(appVersion)")
                                .font(MTTheme.mono(11, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            Text(L("A personal console for the Scheduler and the Codex account pool."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.settings")
        }
        .background(MTTheme.background)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = L("Launch at login failed") + ": \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Backup

    /// Last export time. Reading `backupRefresh` ties the value to a state
    /// the card bumps after every export/import and on appear, so the date
    /// re-renders without a store.
    private var lastBackupText: String {
        _ = backupRefresh
        guard let date = BackupService.lastBackupAt else { return L("No backup yet") }
        return String(format: L("Last backup: %@"), date.formatted(date: .abbreviated, time: .shortened))
    }

    private func exportBackup() {
        let password = backupPassword
        guard !password.isEmpty else {
            backupNoticeIsError = true
            backupNotice = L("Enter a backup password.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data, .json]
        panel.nameFieldStringValue = "MelonTools-backup-\(Self.backupDateFormatter.string(from: Date())).melon"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The panel may append its own allowed extension to the ".melon"
        // default; keep the melon suffix unless the user picked another one.
        let destination = url.pathExtension.lowercased() == "melon"
            ? url
            : url.deletingPathExtension().appendingPathExtension("melon")
        runBackupOperation {
            try BackupService.export(to: destination, password: password)
        }
    }

    private func exportSupportBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MelonTools-support-\(Self.backupDateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = url.pathExtension.lowercased() == "json"
            ? url
            : url.appendingPathExtension("json")
        do {
            try SupportBundleService.export(to: destination)
            supportNotice = L("Support bundle exported") + " — " + destination.lastPathComponent
        } catch {
            supportNotice = L("Support bundle export failed") + ": \(error.localizedDescription)"
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
    }

    private func importBackup(from url: URL) {
        let password = backupPassword
        guard !password.isEmpty else {
            backupNoticeIsError = true
            backupNotice = L("Enter a backup password.")
            return
        }
        runBackupOperation {
            try BackupService.prepareImport(from: url, password: password)
        } commit: { payload in
            try BackupService.restorePayload(payload, supportDir: CodexStore.supportDir, defaults: .standard)
        }
    }

    /// PBKDF2 and filesystem work must not occupy the main actor. Cancellation
    /// is checked before the atomic commit; an in-progress PBKDF2 call itself
    /// cannot be interrupted, but the UI remains responsive throughout it.
    private func runBackupOperation<Value: Sendable>(
        operation: @escaping @Sendable () throws -> Value,
        commit: (@MainActor (Value) throws -> BackupSummary)? = nil
    ) {
        let importing = commit != nil
        guard !backupBusy else { return }
        backupBusy = true
        backupNotice = nil
        backupTask = Task { @MainActor in
            var suspended = false
            var restored = false
            defer {
                if suspended { SchedulerStore.shared.endBackupRestore(restored: restored) }
                backupBusy = false
                backupTask = nil
            }
            do {
                if importing {
                    try await SchedulerStore.shared.beginBackupRestore()
                    suspended = true
                } else {
                    await SchedulerStore.shared.flushPendingWrites()
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try operation()
                }
                let value = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: { worker.cancel() })
                let summary: BackupSummary
                if let commit {
                    try Task.checkCancellation()
                    summary = try commit(value)
                    restored = true
                    // reloadAfterRestore reads all stores synchronously before
                    // its first await, preventing delayed quota writes racing
                    // the restore. Only the gateway restart is asynchronous.
                    await BackupService.reloadAfterRestore()
                } else {
                    guard let exported = value as? BackupSummary else { return }
                    summary = exported
                }
                backupNoticeIsError = false
                backupNotice = L(importing ? "Backup imported" : "Backup exported") + " — " + Self.backupSummaryText(summary)
                backupRefresh += 1
            } catch is CancellationError {
                backupNoticeIsError = false
                backupNotice = L("Backup cancelled.")
            } catch {
                backupNoticeIsError = true
                backupNotice = L(importing ? "Backup import failed" : "Backup export failed") + ": \(error.localizedDescription)"
            }
        }
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func backupSummaryText(_ summary: BackupSummary) -> String {
        let modelSources = summary.modelSourcesIncluded ? L("included") : L("not included")
        return String(
            format: L("Tasks %d · history %d · accounts %d · auth files %d · model sources %@ · settings %d"),
            summary.schedulerTasks,
            summary.schedulerHistory,
            summary.accounts,
            summary.authFiles,
            modelSources,
            summary.settingsKeys
        )
    }
}

// MARK: - Menu bar panel

/// Menu bar panel: compact pool totals, quick actions and the live service
/// state. Everything is one click away without opening the main window.
///
/// The panel is a plain SwiftUI window (`.menuBarExtraStyle(.window)`), so it has
/// no AppKit menu chrome: rows need their own hover highlight, and the labels use
/// SF Pro like the rest of the app instead of the monospaced data face — a mono
/// menu read as "strange font" at 10 pt.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var codex = CodexStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var scheduler = SchedulerStore.shared

    /// One scheduler window for the app lifetime; reopening brings it back.
    private static var schedulerWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            header
            poolTotals
            divider
            quickActions
            divider
            serviceRow
            if gateway.isRunning {
                MenuBarActionRow(icon: "arrow.up.forward.app", title: L("Launch Codex")) {
                    gateway.launchThroughGateway()
                }
            }
        }
        .padding(MTTheme.s3)
        .frame(width: 300)
        .onAppear {
            codex.load()
            scheduler.start()
            Task { await gateway.healthCheck() }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(MTTheme.borderColor.opacity(0.6))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    // MARK: - Header and totals

    private var header: some View {
        HStack(spacing: MTTheme.s2) {
            MelonAssets.logoImage(size: 16)
            Text("Melon Tools")
                .font(MTTheme.body(12.5, weight: .semibold))
                .foregroundStyle(MTTheme.textPrimary)
            Spacer()
            Button(action: openMainWindow) {
                Image(systemName: "macwindow")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MTTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Open window"))
        }
    }

    /// Pool totals, not averages: five accounts at 100% must read 500%, so the
    /// number always means "how much quota is left across the whole pool".
    private var poolTotals: some View {
        let totals = DashboardMetrics.quotaTotals(accounts: codex.accounts)
        return HStack(alignment: .bottom, spacing: MTTheme.s5) {
            compactMetric(title: L("5 h"), value: totals.hourly)
            compactMetric(title: L("Week"), value: totals.weekly)
            Spacer(minLength: 0)
            Text(String(format: L("Accounts in pool: %d"), codex.accounts.count))
                .font(MTTheme.body(10))
                .foregroundStyle(MTTheme.textTertiary)
                .padding(.bottom, 1)
        }
    }

    private func compactMetric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(MTTheme.body(9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(MTTheme.textTertiary)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? MTTheme.textTertiary : MTTheme.textPrimary)
        }
    }

    // MARK: - Quick actions

    private var dueTasks: [SchedulerTask] {
        SchedulerPolicy.due(scheduler.tasks, now: Date())
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuBarActionRow(icon: "macwindow", title: L("Open Melon Tools")) {
                openMainWindow()
            }
            MenuBarActionRow(icon: "clock.badge.checkmark", title: L("Scheduler")) {
                openSchedulerWindow()
            }
            MenuBarActionRow(
                icon: "play.circle",
                title: L("Run next due task") + (dueTasks.isEmpty ? "" : " (\(dueTasks.count))"),
                disabled: dueTasks.isEmpty || !gateway.isRunning || scheduler.isRunning
            ) {
                guard let task = dueTasks.first else { return }
                Task { await scheduler.runNow(id: task.id) }
            }
            MenuBarActionRow(
                icon: gateway.isRunning ? "pause.circle" : "play.circle",
                title: gateway.isRunning ? L("Pause API") : L("Resume API"),
                disabled: gateway.isStarting
            ) {
                toggleGateway()
            }
            MenuBarActionRow(icon: "power", title: L("Quit Melon Tools")) {
                NSApp.terminate(nil)
            }
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSchedulerWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.schedulerWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SchedulerView().environmentObject(app)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Melon Tools — " + L("Scheduler")
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.schedulerWindow = window
    }

    private func toggleGateway() {
        if gateway.isRunning {
            Task { await gateway.stop() }
        } else {
            codex.load()
            Task {
                await gateway.start(
                    accounts: codex.accounts,
                    priorities: codex.effectivePriorities()
                )
            }
        }
    }

    // MARK: - Service

    private var serviceRow: some View {
        HStack(spacing: MTTheme.s2) {
            Circle()
                .fill(gateway.isRunning ? MTTheme.ok : MTTheme.textTertiary)
                .frame(width: 7, height: 7)
            Text(gateway.isRunning ? L("service running") : L("service stopped"))
                .font(MTTheme.body(11))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// One clickable row of the menu bar panel with an AppKit-like hover highlight.
private struct MenuBarActionRow: View {
    let icon: String
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 16, alignment: .leading)
                Text(title)
                    .font(MTTheme.body(12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MTTheme.s2)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered && !disabled ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? MTTheme.textTertiary : MTTheme.textPrimary)
        .onHover { hovered = $0 }
    }
}
