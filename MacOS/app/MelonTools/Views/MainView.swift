import AppKit
import SwiftUI

enum MTSection: String, CaseIterable, Identifiable {
    case dashboard
    case agents
    case codexInstances
    case codexComposer
    case providers
    case plugins
    case routing
    case usage
    case codexAPI
    case localAI
    case scheduler
    case codexAccounts
    case settings
    case donate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("Dashboard")
        case .agents: return L("Agents")
        case .codexInstances: return L("Instances")
        case .codexComposer: return L("Composer Chips")
        case .providers: return L("Providers")
        case .plugins: return L("Plugins")
        case .routing: return L("Routing")
        case .usage: return L("Usage")
        case .codexAPI: return L("Codex API")
        case .localAI: return L("Local AI")
        case .scheduler: return L("Scheduler")
        case .codexAccounts: return L("Accounts")
        case .settings: return L("Settings")
        case .donate: return L("Donate")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .agents: return "person.crop.rectangle.stack"
        case .codexInstances: return "square.on.square"
        case .codexComposer: return "capsule"
        case .providers: return "square.stack.3d.up"
        case .plugins: return "puzzlepiece.extension"
        case .routing: return "arrow.triangle.branch"
        case .usage: return "chart.bar.xaxis"
        case .codexAPI: return "network"
        case .localAI: return "cpu.fill"
        case .scheduler: return "clock.badge.checkmark"
        case .codexAccounts: return "person.2"
        case .settings: return "gear"
        case .donate: return "heart.circle.fill"
        }
    }

    /// Semantic accent color for Apple-style multi-accent navigation and glowing indicators.
    var accentColor: Color {
        switch self {
        case .dashboard: return MTTheme.cyan
        case .agents: return MTTheme.violet
        case .codexInstances: return MTTheme.amber
        case .codexComposer: return MTTheme.cyan
        case .providers: return MTTheme.emerald
        case .plugins: return MTTheme.violet
        case .routing: return MTTheme.cyan
        case .usage: return MTTheme.emerald
        case .codexAPI: return MTTheme.cyan
        case .localAI: return MTTheme.emerald
        case .scheduler: return MTTheme.amber
        case .codexAccounts: return MTTheme.violet
        case .settings: return MTTheme.textSecondary
        case .donate: return MTTheme.ruby
        }
    }

    struct Group {
        let title: String
        let sections: [MTSection]
    }

    /// Sidebar groups follow the model Magpie uses: day-to-day work first, then
    /// the places models are configured, then the numbers about them.
    static var groups: [Group] {
        [
            Group(title: L("Overview"), sections: [.dashboard]),
            Group(title: L("Work"), sections: [.agents]),
            Group(title: L("Extend"), sections: [.plugins]),
            Group(title: L("Models"), sections: [.codexAPI, .routing, .providers, .localAI]),
            Group(title: L("Insights"), sections: [.usage]),
            Group(title: L("Automation"), sections: [.scheduler]),
            Group(title: L("Accounts"), sections: [.codexAccounts]),
            Group(title: L("App"), sections: [.settings, .donate]),
        ]
    }

    /// Sidebar order, flattened: also the order of the Cmd-1…9 shortcuts.
    /// Sections missing from `groups` are reachable only by their own page and
    /// stay in the enum so a stored selection still decodes.
    static var visibleSections: [MTSection] {
        groups.flatMap(\.sections)
    }

    static func initialSelection() -> MTSection {
        let saved = MTSection(rawValue: UserDefaults.standard.string(forKey: "mainSelection") ?? "") ?? .dashboard
        return visibleSections.contains(saved) ? saved : .settings
    }
}

/// Bento layout: one solid card on the left (navigation), a card board on the right.
struct MainView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = UpdaterStore.shared
    @State private var selection: MTSection = MTSection.initialSelection()
    /// First-run guide: shown once, then never again on this account.
    @AppStorage("onboardingDone") private var onboardingDone = false

    private static let sidebarWidth: CGFloat = 236

    var body: some View {
        HStack(spacing: 0) {
            sidebarBoard
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MTTheme.background)
        .onChange(of: selection) { _, section in
            // The language switch recreates MainView via .id; keep the user on
            // the same section instead of dropping them on Dashboard.
            UserDefaults.standard.set(section.rawValue, forKey: "mainSelection")
        }
        .onAppear {
            // Normalize a stored pointer to a merged or hidden section once, so
            // the next launch does not have to remap it again.
            if UserDefaults.standard.string(forKey: "mainSelection") != selection.rawValue {
                UserDefaults.standard.set(selection.rawValue, forKey: "mainSelection")
            }
            app.applyAppearance()
            if let window = NSApp.windows.first(where: { $0.title == "Melon Tools" }) {
                window.identifier = NSUserInterfaceItemIdentifier("main")
            }
            // The island lives outside the SwiftUI scene graph, so it borrows
            // this action to reopen the main window after the user closed it.
            NotchHUDController.shared.registerOpenMainWindow {
                openWindow(id: "main")
            }
            if !AppRuntime.isTesting {
                Task { await updater.check(manual: false) }
            }
        }
        .onChange(of: app.appearance) { app.applyAppearance() }
        .sheet(isPresented: $updater.sheetPresented) {
            UpdateSheet()
        }
        .sheet(isPresented: onboardingPresented) {
            OnboardingView(selection: $selection)
        }
        .overlay {
            // Cmd-1…9 jump to the first nine sidebar sections in display order.
            ForEach(Array(MTSection.visibleSections.prefix(9).enumerated()), id: \.offset) { index, section in
                Button("") { selection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The sheet is visible only while the defaults key is unset; dismissing
    /// it (or picking a destination) writes the key once.
    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !onboardingDone },
            set: { presented in
                if !presented { onboardingDone = true }
            }
        )
    }

    /// Sidebar update control: Apple Liquid Glass translucent capsule CTA.
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .available(let version, _) = updater.phase {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MTTheme.amber)
                    Text(String(format: L("Update %@ is available"), version))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                updater.sheetPresented = true
                Task { await updater.check(manual: true) }
            } label: {
                HStack(spacing: 6) {
                    if isUpdateAvailable {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isUpdateAvailable ? L("Update") : L("Check for updates"))
                        .font(MTTheme.body(11.5, weight: isUpdateAvailable ? .semibold : .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(isUpdateAvailable ? MTTheme.onGold : MTTheme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .fill(isUpdateAvailable ? MTTheme.gold : MTTheme.cardSoft.opacity(0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                        .strokeBorder(
                            isUpdateAvailable ? MTTheme.gold.opacity(0.4) : MTTheme.borderColor,
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.top, MTTheme.s2)
        .padding(.bottom, MTTheme.s1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.75)
        }
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    // MARK: - Floating Sidebar Card

    private var sidebarBoard: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    ForEach(MTSection.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: MTTheme.s1) {
                            Text(group.title)
                                .font(MTTheme.mono(9, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(1.1)
                                .foregroundStyle(MTTheme.textTertiary)
                                .padding(.horizontal, MTTheme.s3)
                            ForEach(group.sections) { section in
                                NavRow(section: section, isSelected: selection == section) { picked in
                                    selection = picked
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, MTTheme.s2)
                .padding(.vertical, MTTheme.s3)
            }
            Spacer(minLength: 0)
            updateRow
            GatewayFooter()
        }
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .mtFloatingSidebar(cornerRadius: MTTheme.rSidebar)
        .padding(.leading, MTTheme.s4)
        .padding(.vertical, MTTheme.s4)
        .padding(.trailing, MTTheme.s3)
    }

    private var brandHeader: some View {
        HStack(spacing: MTTheme.s2 + 2) {
            MelonAssets.logoImage(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Melon Tools")
                    .font(MTTheme.body(13, weight: .bold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(L("providers, agents and routing"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.top, MTTheme.s3 + 2)
        .padding(.bottom, MTTheme.s3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.75)
        }
    }

    /// A sidebar row with its own hover state and Apple-style Liquid Glass highlight.
    private struct NavRow: View {
        let section: MTSection
        let isSelected: Bool
        let select: (MTSection) -> Void
        @State private var hovered = false

        var body: some View {
            Button {
                select(section)
            } label: {
                HStack(spacing: MTTheme.s3) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(section.accentColor)
                        .frame(width: 18, alignment: .center)

                    Text(section.title)
                        .font(MTTheme.body(12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MTTheme.textPrimary : (hovered ? MTTheme.textPrimary : MTTheme.textSecondary))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isSelected {
                        Circle()
                            .fill(section.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, MTTheme.s3)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall + 2, style: .continuous)
                        .fill(isSelected ? section.accentColor.opacity(0.22) : (hovered ? Color.primary.opacity(0.06) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MTTheme.rSmall + 2, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? section.accentColor.opacity(0.45)
                                : (hovered ? MTTheme.borderColor : Color.clear),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: MTTheme.rSmall + 2, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

/// Sidebar footer: live gateway status indicator and version badge.
private struct GatewayFooter: View {
    @ObservedObject private var gateway = CodexGatewayService.shared

    var body: some View {
        HStack(spacing: MTTheme.s2) {
            Circle()
                .fill(gateway.status.color)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))

            Text(gateway.status.label)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)

            Spacer(minLength: 0)

            Text("v" + MainView.appVersion)
                .font(MTTheme.mono(9, weight: .medium))
                .foregroundStyle(MTTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, MTTheme.s2 + 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.75)
        }
    }
}

    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    // MARK: - Detail board

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard: DashboardView(selection: $selection)
        case .agents: AgentsView(selection: $selection)
        case .codexInstances: CodexInstancesView()
        case .codexComposer: CodexComposerView()
        case .providers: CodexProvidersView(selection: $selection)
        case .plugins: PluginsView()
        case .routing: RoutingView(selection: $selection)
        case .usage: UsageView(selection: $selection)
        case .codexAPI: CodexAPIView()
        case .localAI: LocalAIView()
        case .scheduler: SchedulerView()
        case .codexAccounts: CodexAccountsView(selection: $selection)
        case .settings: SettingsView()
        case .donate: DonateView()
        }
    }
}

private extension CodexGatewayService.Status {
    var color: Color {
        switch self {
        case .running: return MTTheme.ok
        case .starting: return MTTheme.gold
        case .stopped: return MTTheme.textTertiary
        case .failed: return MTTheme.danger
        }
    }
}
