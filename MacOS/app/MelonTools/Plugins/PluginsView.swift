import SwiftUI
import AppKit

/// Melon Plugins: the native CLIProxyAPI plugin store.
///
/// The page is split into two honest states: Discover (what the registry
/// offers) and Installed (what is on disk and whether the host loaded it).
/// Native plugins are trusted in-process code, so every install goes through a
/// consent sheet that names the publisher and the source.
struct PluginsView: View {
    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var models = PluginModelCatalog.shared

    @State private var tab: PluginTab = .discover
    @State private var filter: PluginFilter = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var pendingInstallID: String?
    @State private var configID: String?
    @State private var pendingRemoveID: String?
    @State private var confirmSafeMode = false

    private enum PluginTab: Hashable {
        case discover
        case installed
    }

    private enum PluginFilter: String, CaseIterable, Hashable {
        case all
        case updates
        case providers
        case interceptors
        case scheduling
        case usage
        case dashboards

        var title: String {
            switch self {
            case .all: return L("All")
            case .updates: return L("Updates")
            case .providers: return L("Providers")
            case .interceptors: return L("Interceptors")
            case .scheduling: return L("Scheduling")
            case .usage: return L("Usage")
            case .dashboards: return L("Dashboards")
            }
        }

        var tag: String? {
            switch self {
            case .all, .updates: return nil
            case .providers: return "provider"
            case .interceptors: return "interceptor"
            case .scheduling: return "scheduler"
            case .usage: return "usage"
            case .dashboards: return "dashboard"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                header
                hostCard
                if let error = store.lastError {
                    errorCard(error)
                }
                if store.restartNeeded {
                    restartCard
                }
                content
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .task {
            await store.refresh()
            await models.refresh()
        }
        .onChange(of: gateway.status) { _, status in
            guard case .running = status else { return }
            Task {
                await store.refresh()
                await models.refresh()
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedID != nil },
            set: { if !$0 { selectedID = nil } }
        )) {
            if let id = selectedID {
                PluginDetailSheet(
                    pluginID: id,
                    onConfigure: { configureID in
                        selectedID = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            configID = configureID
                        }
                    },
                    onInstall: { installID in
                        selectedID = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            pendingInstallID = installID
                        }
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingInstallID != nil },
            set: { if !$0 { pendingInstallID = nil } }
        )) {
            if let id = pendingInstallID {
                PluginConsentSheet(pluginID: id) {
                    pendingInstallID = nil
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { configID != nil },
            set: { if !$0 { configID = nil } }
        )) {
            if let id = configID {
                PluginConfigSheet(pluginID: id) {
                    configID = nil
                }
            }
        }
        .confirmationDialog(
            L("Remove this plugin?"),
            isPresented: Binding(
                get: { pendingRemoveID != nil },
                set: { if !$0 { pendingRemoveID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Remove"), role: .destructive) {
                if let id = pendingRemoveID {
                    Task { await store.remove(id: id) }
                }
                pendingRemoveID = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingRemoveID = nil }
        } message: {
            Text(L("The plugin file and its saved config are deleted from this Mac."))
        }
        .confirmationDialog(
            L("Turn off all plugins?"),
            isPresented: $confirmSafeMode,
            titleVisibility: .visible
        ) {
            Button(L("Turn off and restart"), role: .destructive) {
                Task { await store.setHostEnabled(false) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The gateway restarts without the plugin host. Installed files stay on disk and can be enabled again."))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: MTTheme.s4) {
            MTPageHeader(
                kicker: "melon plugins",
                title: L("Plugins"),
                subtitle: L("Extend Melon with native plugins from the community store.")
            )
            Spacer(minLength: MTTheme.s4)
            VStack(alignment: .trailing, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    if store.usingCache {
                        MTBadge(text: L("Cached"), tint: MTTheme.amber)
                    }
                    MTGlassButton(
                        title: L("Refresh"),
                        systemImage: "arrow.clockwise",
                        size: .small,
                        tint: MTTheme.cyan,
                        isLoading: store.isLoading
                    ) {
                        Task {
                            await store.refresh(force: true)
                            await models.refresh()
                        }
                    }
                }
                if let updated = store.lastUpdated {
                    Text(updated.formatted(date: .abbreviated, time: .shortened))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    // MARK: - Host

    private var hostCard: some View {
        MTCard(title: L("Native plugin host"), systemImage: "puzzlepiece.extension", accent: MTTheme.violet) {
            HStack(alignment: .top, spacing: MTTheme.s3) {
                MTGlyphTile(
                    systemImage: store.hostEnabled ? "bolt.fill" : "bolt.slash",
                    accent: store.hostEnabled ? MTTheme.violet : MTTheme.textTertiary,
                    size: 38
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: MTTheme.s2) {
                        Text(store.hostEnabled ? L("Host is on") : L("Host is off"))
                            .font(MTTheme.body(12.5, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                        MTStatusPill(
                            text: store.hostEnabled ? L("Running") : L("Safe"),
                            status: store.hostEnabled ? .ok : .idle
                        )
                    }
                    Text(store.hostEnabled
                         ? L("Native libraries load inside the gateway process. Install only plugins you trust.")
                         : L("Plugins are disabled. Installed files stay on disk and no plugin code runs."))
                        .font(MTTheme.body(10.5))
                        .foregroundStyle(MTTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: MTTheme.s2)
                if store.hostEnabled {
                    MTGlassButton(
                        title: L("Safe Mode"),
                        systemImage: "shield.lefthalf.filled",
                        size: .small,
                        tint: MTTheme.amber
                    ) {
                        confirmSafeMode = true
                    }
                } else {
                    MTGlassButton(
                        title: L("Turn on"),
                        systemImage: "bolt.fill",
                        size: .small,
                        tint: MTTheme.violet
                    ) {
                        Task { await store.setHostEnabled(true) }
                    }
                }
            }

            HStack(spacing: MTTheme.s5) {
                metric(value: store.installed.count, label: L("Installed"))
                metric(value: store.activeCount, label: L("Active"))
                metric(value: store.updateCount, label: L("Updates"))
                Divider().frame(height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Plugin folder"))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Text(store.pluginsDir)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if let source = store.sources.first(where: {
                    $0.url.localizedCaseInsensitiveContains("vanich-git/MelonTools")
                }) ?? store.sources.first {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L("Registry"))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(source.displayName)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func metric(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(MTTheme.display(20))
                .foregroundStyle(MTTheme.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
        }
        .frame(minWidth: 54, alignment: .leading)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack(spacing: MTTheme.s3) {
                MTSegmented(
                    selection: $tab,
                    options: [
                        (value: .discover, label: L("Discover")),
                        (value: .installed, label: L("Installed")),
                    ],
                    width: 210
                )
                searchField
                Spacer(minLength: 0)
                if tab == .discover {
                    Text(String(format: L("%d plugins"), store.catalog.count))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }

            if tab == .discover {
                discover
            } else {
                installedBoard
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: MTTheme.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MTTheme.textTertiary)
            TextField(L("Search plugins"), text: $query)
                .textFieldStyle(.plain)
                .font(MTTheme.mono(11))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(width: 260)
        .background(MTTheme.cardBackground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var discover: some View {
        MTChipPicker(
            items: PluginFilter.allCases,
            title: { item in
                if item == .updates, store.updateCount > 0 {
                    return "\(item.title) \(store.updateCount)"
                }
                return item.title
            },
            selection: $filter,
            accent: MTTheme.violet
        )

        if gateway.status == .stopped {
            gatewayOffCard
        } else if store.catalog.isEmpty && store.isLoading {
            loadingPlate
        } else if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label(L("No plugins found"), systemImage: "puzzlepiece.extension")
            } description: {
                Text(L("Try another search or clear the filter."))
            } actions: {
                if !query.isEmpty || filter != .all {
                    MTGlassButton(title: L("Clear filters"), size: .small, tint: MTTheme.cyan) {
                        query = ""
                        filter = .all
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            if filter == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let picks = store.picks
                if !picks.isEmpty {
                    sectionTitle(L("Melon Picks"), systemImage: "sparkles", accent: MTTheme.gold)
                    pluginGrid(picks, showSource: true)
                }
                let pickIDs = Set(picks.map(\.pluginID))
                let rest = filteredEntries.filter { !pickIDs.contains($0.pluginID) }
                if !rest.isEmpty {
                    sectionTitle(L("All plugins"), systemImage: "square.grid.2x2", accent: MTTheme.violet)
                    pluginGrid(rest, showSource: true)
                }
            } else {
                pluginGrid(filteredEntries, showSource: true)
            }
        }
    }

    private var filteredEntries: [PluginStoreEntry] {
        var list = store.filtered(query, updatesOnly: filter == .updates)
        if let tag = filter.tag {
            list = list.filter { entry in
                entry.tags.contains { $0.lowercased() == tag }
            }
        }
        return list
    }

    private func sectionTitle(_ title: String, systemImage: String, accent: Color) -> some View {
        HStack(spacing: MTTheme.s2) {
            MTCardSectionTitle(text: title, systemImage: systemImage, accent: accent)
            Text(String(format: L("%d"), title == L("Melon Picks") ? store.picks.count : filteredEntries.count))
                .font(MTTheme.mono(9, weight: .semibold))
                .foregroundStyle(MTTheme.textTertiary)
        }
        .padding(.top, MTTheme.s1)
    }

    private func pluginGrid(_ entries: [PluginStoreEntry], showSource: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: MTTheme.s3)],
            alignment: .leading,
            spacing: MTTheme.s3
        ) {
            ForEach(entries) { entry in
                PluginCard(
                    entry: entry,
                    installed: store.installedEntry(id: entry.pluginID),
                    isInstalling: store.installingID == entry.pluginID,
                    showSource: showSource,
                    onInstall: { pendingInstallID = entry.pluginID },
                    onDetails: { selectedID = entry.pluginID },
                    onConfigure: { configID = entry.pluginID }
                )
            }
        }
    }

    // MARK: - Installed

    @ViewBuilder
    private var installedBoard: some View {
        if store.installed.isEmpty {
            ContentUnavailableView {
                Label(L("No plugins installed"), systemImage: "puzzlepiece.extension")
            } description: {
                Text(L("Open Discover to install a native plugin."))
            } actions: {
                MTGlassButton(title: L("Browse plugins"), systemImage: "square.grid.2x2", tint: MTTheme.violet) {
                    tab = .discover
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            MTListCard {
                ForEach(Array(store.installed.enumerated()), id: \.element.id) { index, item in
                    installedRow(item)
                    if index < store.installed.count - 1 {
                        MTRowSeparator(inset: 64)
                    }
                }
            }
        }
    }

    private func installedRow(_ item: PluginInstalledEntry) -> some View {
        HStack(spacing: MTTheme.s3) {
            PluginLogo(url: item.logoURL, fallback: item.displayName, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MTTheme.s2) {
                    Text(item.displayName)
                        .font(MTTheme.body(12.5, weight: .medium))
                        .foregroundStyle(MTTheme.textPrimary)
                        .lineLimit(1)
                    if !item.version.isEmpty {
                        MTBadge(text: item.version, tint: MTTheme.textTertiary)
                    }
                }
                Text(item.author.isEmpty ? item.pluginID : "\(item.author) · \(item.pluginID)")
                    .font(MTTheme.mono(9.5))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: MTTheme.s2)
            MTStatusPill(text: item.statusText, status: item.status)
            Toggle("", isOn: Binding(
                get: { item.effectiveEnabled },
                set: { value in
                    Task { await store.setEnabled(id: item.pluginID, enabled: value) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(String(format: L("Enable %@"), item.displayName))
            MTGlassButton(title: L("Configure"), size: .small, tint: MTTheme.violet) {
                configID = item.pluginID
            }
            Button {
                pendingRemoveID = item.pluginID
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MTTheme.ruby)
                    .frame(width: 24, height: 22)
                    .background(Capsule().fill(MTTheme.ruby.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(L("Remove plugin"))
            .accessibilityLabel(String(format: L("Remove %@"), item.displayName))
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 10)
    }

    // MARK: - Banners

    private var gatewayOffCard: some View {
        MTCard(title: L("Gateway is off"), systemImage: "bolt.slash", accent: MTTheme.amber) {
            HStack(spacing: MTTheme.s3) {
                Text(L("The plugin store uses the gateway management API. Start the gateway to browse and install."))
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                Spacer()
                MTGlassButton(title: L("Start gateway"), systemImage: "play.fill", size: .small, tint: MTTheme.emerald) {
                    let codex = CodexStore.shared
                    Task {
                        await gateway.start(accounts: codex.accounts, priorities: codex.effectivePriorities())
                        await store.refresh()
                        await models.refresh()
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        MTCard(title: L("Plugin store"), systemImage: "exclamationmark.triangle", accent: MTTheme.ruby) {
            HStack(alignment: .top, spacing: MTTheme.s2) {
                Text(message)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    store.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Dismiss"))
            }
            if !store.sourceErrors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(store.sourceErrors.enumerated()), id: \.offset) { _, item in
                        Text("\(item.sourceName.isEmpty ? item.sourceURL : item.sourceName): \(item.message)")
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var restartCard: some View {
        MTCard(title: L("Restart required"), systemImage: "arrow.clockwise.circle", accent: MTTheme.amber) {
            HStack(spacing: MTTheme.s3) {
                Text(L("A loaded plugin cannot be replaced while the gateway runs. Restart it, then retry the update."))
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                Spacer()
                MTGlassButton(title: L("Restart"), systemImage: "arrow.clockwise", size: .small, tint: MTTheme.amber) {
                    Task { await store.restartGatewayNow() }
                }
            }
        }
    }

    private var loadingPlate: some View {
        HStack(spacing: MTTheme.s3) {
            ProgressView().controlSize(.small)
            Text(L("Loading the plugin store..."))
                .font(MTTheme.body(11))
                .foregroundStyle(MTTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous))
    }
}

// MARK: - Card

private struct PluginCard: View {
    let entry: PluginStoreEntry
    let installed: PluginInstalledEntry?
    let isInstalling: Bool
    let showSource: Bool
    let onInstall: () -> Void
    let onDetails: () -> Void
    let onConfigure: () -> Void

    @State private var hovering = false

    private var isInstalled: Bool { entry.installed || installed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(alignment: .top, spacing: MTTheme.s3) {
                PluginLogo(url: entry.logo, fallback: entry.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: onDetails) {
                        Text(entry.displayName)
                            .font(MTTheme.body(13, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    Text(entry.author.isEmpty ? entry.pluginID : entry.author)
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: MTTheme.s2)
                VStack(alignment: .trailing, spacing: 4) {
                    MTStatusPill(
                        text: entry.updateAvailable ? L("Update") : entry.statusText,
                        status: entry.status
                    )
                    if !entry.version.isEmpty {
                        Text(entry.version)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
            }

            Text(entry.description)
                .font(MTTheme.body(10.5))
                .foregroundStyle(MTTheme.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)

            HStack(spacing: 5) {
                ForEach(entry.tags.prefix(3), id: \.self) { tag in
                    MTBadge(text: tag, tint: MTTheme.violet)
                }
                Spacer(minLength: 0)
                if showSource, !entry.sourceLabel.isEmpty {
                    Text(entry.sourceLabel)
                        .font(MTTheme.mono(8.5))
                        .foregroundStyle(MTTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: MTTheme.s2) {
                Button(action: onDetails) {
                    Text(L("Details"))
                        .font(MTTheme.body(10.5, weight: .medium))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if isInstalled {
                    MTGlassButton(
                        title: entry.updateAvailable ? L("Update") : L("Configure"),
                        size: .small,
                        tint: MTTheme.violet,
                        prominent: entry.updateAvailable
                    ) {
                        entry.updateAvailable ? onInstall() : onConfigure()
                    }
                } else {
                    MTGlassButton(
                        title: L("Install"),
                        systemImage: "arrow.down.circle",
                        size: .small,
                        tint: MTTheme.violet,
                        prominent: true,
                        isLoading: isInstalling,
                        action: onInstall
                    )
                }
            }
        }
        .padding(MTTheme.s4)
        .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .fill(hovering ? MTTheme.cardBackground.opacity(0.92) : MTTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(
                    hovering ? MTTheme.violet.opacity(0.45) : MTTheme.borderColor.opacity(0.7),
                    lineWidth: hovering ? 1 : 0.75
                )
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Logo

struct PluginLogo: View {
    let url: String
    let fallback: String
    var size: CGFloat = 40

    private var monogram: String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "P"
    }

    var body: some View {
        Group {
            if let link = URL(string: url), !url.isEmpty {
                AsyncImage(url: link) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(MTTheme.violet.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            MTTheme.violet.opacity(0.14)
            Text(monogram)
                .font(MTTheme.body(size * 0.42, weight: .semibold))
                .foregroundStyle(MTTheme.violet)
        }
    }
}

// MARK: - Detail

private struct PluginDetailSheet: View {
    let pluginID: String
    let onConfigure: (String) -> Void
    let onInstall: (String) -> Void

    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss

    private var entry: PluginStoreEntry? {
        store.catalog.first { $0.pluginID == pluginID }
    }
    private var installed: PluginInstalledEntry? {
        store.installedEntry(id: pluginID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: MTTheme.s4) {
                        HStack(alignment: .top, spacing: MTTheme.s3) {
                            PluginLogo(url: entry.logo, fallback: entry.displayName, size: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.displayName)
                                    .font(MTTheme.display(22))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text(entry.author.isEmpty ? entry.pluginID : "\(entry.author) · \(entry.pluginID)")
                                    .font(MTTheme.mono(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                                HStack(spacing: MTTheme.s2) {
                                    if !entry.version.isEmpty {
                                        MTBadge(text: "v\(entry.version)", tint: MTTheme.violet)
                                    }
                                    if installed != nil || entry.installed {
                                        MTStatusPill(text: installed?.statusText ?? L("Installed"), status: installed?.status ?? .idle)
                                    }
                                    if let license = entry.license.nonEmpty {
                                        MTBadge(text: license, tint: MTTheme.textTertiary)
                                    }
                                }
                            }
                            Spacer()
                        }

                        Text(entry.description)
                            .font(MTTheme.body(12))
                            .foregroundStyle(MTTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 5) {
                            ForEach(entry.tags, id: \.self) { tag in
                                MTBadge(text: tag, tint: MTTheme.violet)
                            }
                        }

                        MTListCard {
                            infoRow(L("Publisher"), entry.author.isEmpty ? "Unknown" : entry.author)
                            MTRowSeparator()
                            infoRow(L("Source"), entry.sourceLabel)
                            MTRowSeparator()
                            infoRow(L("Install type"), entry.installType.isEmpty ? "GitHub release" : entry.installType)
                            if !entry.repository.isEmpty {
                                MTRowSeparator()
                                HStack {
                                    Text(L("Repository"))
                                        .font(MTTheme.mono(10))
                                        .foregroundStyle(MTTheme.textSecondary)
                                    Spacer()
                                    Link(L("Open"), destination: URL(string: entry.repository) ?? URL(string: "https://github.com")!)
                                        .font(MTTheme.body(11, weight: .medium))
                                        .foregroundStyle(MTTheme.cyan)
                                }
                                .padding(.horizontal, MTTheme.s3)
                                .padding(.vertical, 8)
                            }
                        }

                        if let installed, !installed.configFields.isEmpty {
                            VStack(alignment: .leading, spacing: MTTheme.s2) {
                                MTCardSectionTitle(text: L("Configuration"), systemImage: "slider.horizontal.3", accent: MTTheme.violet)
                                Text(String(format: L("%d settings exposed by the plugin."), installed.configFields.count))
                                    .font(MTTheme.body(10.5))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }

                        if !entry.platforms.isEmpty {
                            VStack(alignment: .leading, spacing: MTTheme.s2) {
                                MTCardSectionTitle(text: L("Platforms"), systemImage: "desktopcomputer", accent: MTTheme.cyan)
                                Text(entry.platforms.map(\.label).joined(separator: " · "))
                                    .font(MTTheme.mono(9.5))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }

                        Text(L("Native plugins run as trusted code inside the gateway process. A plugin can read the same files and network the gateway can reach. Install only publishers you trust."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(MTTheme.s5)
                }
                Divider()
                HStack(spacing: MTTheme.s2) {
                    Spacer()
                    MTGlassButton(title: L("Close"), size: .small, tint: MTTheme.textSecondary) {
                        dismiss()
                    }
                    if installed != nil || entry.installed {
                        MTGlassButton(
                            title: L("Configure"),
                            systemImage: "slider.horizontal.3",
                            size: .small,
                            tint: MTTheme.violet,
                            prominent: true
                        ) {
                            onConfigure(entry.pluginID)
                        }
                    } else {
                        MTGlassButton(
                            title: L("Install"),
                            systemImage: "arrow.down.circle",
                            size: .small,
                            tint: MTTheme.violet,
                            prominent: true,
                            isLoading: store.installingID == entry.pluginID
                        ) {
                            onInstall(entry.pluginID)
                        }
                    }
                }
                .padding(MTTheme.s4)
            } else {
                ContentUnavailableView(
                    L("Plugin not found"),
                    systemImage: "puzzlepiece.extension",
                    description: Text(L("The registry changed. Refresh the store and try again."))
                )
                .frame(width: 520, height: 300)
            }
        }
        .frame(width: 680, height: 640)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer()
            Text(value)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 8)
    }
}

// MARK: - Consent

private struct PluginConsentSheet: View {
    let pluginID: String
    let onClose: () -> Void

    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false

    private var entry: PluginStoreEntry? {
        store.catalog.first { $0.pluginID == pluginID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack(alignment: .top, spacing: MTTheme.s3) {
                PluginLogo(url: entry?.logo ?? "", fallback: entry?.displayName ?? pluginID, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Install native plugin?"))
                        .font(MTTheme.display(20))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(entry?.displayName ?? pluginID)
                        .font(MTTheme.body(12, weight: .medium))
                        .foregroundStyle(MTTheme.violet)
                    Text(entry?.author ?? "")
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
            }

            Text(L("This plugin is a native library. It runs inside the gateway with the same access as Melon Tools: it can read requests, credentials and files the gateway can reach."))
                .font(MTTheme.body(11.5))
                .foregroundStyle(MTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let entry {
                MTListCard {
                    consentRow(L("Version"), entry.version.isEmpty ? "Unknown" : entry.version)
                    MTRowSeparator()
                    consentRow(L("Source"), entry.sourceLabel)
                    MTRowSeparator()
                    consentRow(L("License"), entry.license.isEmpty ? "Unknown" : entry.license)
                    if !entry.repository.isEmpty {
                        MTRowSeparator()
                        consentRow(L("Repository"), entry.repository)
                    }
                }
            }

            Toggle(isOn: $accepted) {
                Text(L("I trust this publisher and understand that the plugin runs as native code."))
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let error = store.lastError {
                Text(error)
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.ruby)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                MTGlassButton(title: L("Cancel"), size: .small, tint: MTTheme.textSecondary) {
                    onClose()
                    dismiss()
                }
                MTGlassButton(
                    title: L("Install"),
                    systemImage: "arrow.down.circle",
                    size: .small,
                    tint: MTTheme.violet,
                    prominent: true,
                    isLoading: store.installingID == pluginID
                ) {
                    guard let entry else { return }
                    Task {
                        await store.install(entry)
                        if store.lastError == nil {
                            onClose()
                            dismiss()
                        }
                    }
                }
                .disabled(!accepted || store.installingID != nil)
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 540)
        .interactiveDismissDisabled(store.installingID == pluginID)
    }

    private func consentRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(MTTheme.mono(9.5))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(MTTheme.mono(9.5))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 7)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
