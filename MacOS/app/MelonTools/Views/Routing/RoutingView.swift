import SwiftUI

/// Routing: how the engine picks a credential, and which model names map to
/// several upstream providers.
///
/// Two layers live here. The top card writes the `routing` block of
/// `config.yaml` (strategy, session affinity, retries). The bottom card manages
/// model groups: one alias declared on several providers, so a client asks for
/// one name and the engine fails over. The engine decides the provider order
/// across providers; the screen states that instead of implying control it
/// does not have.
struct RoutingContent: View {
    @Binding var selection: MTSection

    @ObservedObject private var groups = RoutingGroupsStore.shared
    @ObservedObject private var sources = ModelSourcesStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    @State private var strategy: CodexGatewayService.GatewayStrategy = .weighted
    @State private var affinity = true
    @State private var affinityTTL = "2h"
    @State private var retry = 1
    @State private var cooldown = 60
    @State private var didLoadSettings = false
    @State private var draft: RoutingGroupDraft?
    @State private var pendingDelete: RoutingGroup?

    private let ttlOptions = ["30m", "1h", "2h", "4h", "8h", "24h"]

    /// The stored value stays an engine token (`2h`); the picker shows a
    /// localized label so the selector is not half English.
    private func ttlTitle(_ value: String) -> String {
        switch value {
        case "30m": return L("30 min")
        case "1h": return L("1 hour")
        case "2h": return L("2 hours")
        case "4h": return L("4 hours")
        case "8h": return L("8 hours")
        case "24h": return L("24 hours")
        default: return value
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Routing"),
                    subtitle: L("Routing subtitle")
                )
                engineCard
                groupsCard
                explanationCard
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: loadSettings)
        .sheet(item: $draft) { draft in
            RoutingGroupEditor(draft: draft) { updated in
                let result: String?
                if let originalID = updated.originalID {
                    var group = groups.groups.first { $0.id == originalID } ?? RoutingGroup(alias: updated.alias)
                    group.alias = updated.alias
                    group.note = updated.note
                    group.enabled = updated.enabled
                    group.members = updated.members
                    result = groups.update(group)
                } else {
                    result = groups.add(alias: updated.alias, note: updated.note, members: updated.members)
                }
                if result == nil {
                    Task { await sources.apply() }
                }
                return result
            }
        }
        .confirmationDialog(
            L("Delete this model group?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                if let group = pendingDelete, groups.remove(id: group.id) == nil {
                    Task { await sources.apply() }
                }
                pendingDelete = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L("The alias disappears from the gateway config on the next apply. Provider models stay untouched."))
        }
    }

    // MARK: - Settings

    private func loadSettings() {
        strategy = CodexGatewayService.gatewayStrategy
        affinity = CodexGatewayService.gatewaySessionAffinity
        affinityTTL = CodexGatewayService.gatewaySessionAffinityTTL
        retry = CodexGatewayService.gatewayRequestRetry
        cooldown = CodexGatewayService.gatewayTransientCooldown
        didLoadSettings = true
    }

    private var settingsDirty: Bool {
        strategy != CodexGatewayService.gatewayStrategy
            || affinity != CodexGatewayService.gatewaySessionAffinity
            || affinityTTL != CodexGatewayService.gatewaySessionAffinityTTL
            || retry != CodexGatewayService.gatewayRequestRetry
            || cooldown != CodexGatewayService.gatewayTransientCooldown
    }

    private var engineCard: some View {
        MTCard(title: L("Engine routing"), systemImage: "arrow.triangle.branch", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                HStack(spacing: MTTheme.s3) {
                    MTStatusPill(text: gateway.status.label, status: gateway.status.pillStatus)
                    Text(gateway.isRunning ? L("Changes reload the running gateway.") : L("Changes apply when the gateway starts."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: MTTheme.s2) {
                    MTCardSectionTitle(text: L("Strategy"), systemImage: "shuffle")
                    MTChipPicker(
                        items: CodexGatewayService.GatewayStrategy.allCases,
                        title: { $0.title },
                        selection: $strategy
                    )
                    Text(strategy.detail)
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.4)

                HStack(alignment: .top, spacing: MTTheme.s5) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Toggle(L("Session affinity"), isOn: $affinity)
                            .toggleStyle(.switch)
                            .tint(MTTheme.emerald)
                            .controlSize(.small)
                        Text(L("Keeps one conversation on one account, so the upstream cache is reused."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Affinity window"))
                            .font(MTTheme.mono(9, weight: .semibold))
                            .foregroundStyle(MTTheme.textSecondary)
                        MTSelect(
                            selection: $affinityTTL,
                            options: ttlOptions.map { ($0, ttlTitle($0)) },
                            width: 120
                        )
                        .disabled(!affinity)
                    }
                }

                HStack(alignment: .top, spacing: MTTheme.s5) {
                    stepperField(
                        title: L("Retries per request"),
                        value: $retry,
                        range: 0...5,
                        note: L("Extra attempts on another credential before the client sees an error.")
                    )
                    stepperField(
                        title: L("Transient cooldown"),
                        value: $cooldown,
                        range: 0...600,
                        step: 15,
                        note: L("Seconds a credential rests after a transient stream error."),
                        suffix: L("sec")
                    )
                }

                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(
                        title: L("Apply routing"),
                        systemImage: "checkmark.circle",
                        tint: MTTheme.cyan,
                        prominent: settingsDirty
                    ) {
                        CodexGatewayService.gatewayStrategy = strategy
                        CodexGatewayService.gatewaySessionAffinity = affinity
                        CodexGatewayService.gatewaySessionAffinityTTL = affinityTTL
                        CodexGatewayService.gatewayRequestRetry = retry
                        CodexGatewayService.gatewayTransientCooldown = cooldown
                        gateway.applyRoutingSettings()
                    }
                    .disabled(!settingsDirty)
                    if settingsDirty {
                        Text(L("Unsaved changes."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.amber)
                        Button(L("Revert")) { loadSettings() }
                            .buttonStyle(.link)
                            .font(MTTheme.mono(9))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func stepperField(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        note: String,
        suffix: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: MTTheme.s2) {
                Text(title)
                    .font(MTTheme.mono(9, weight: .semibold))
                    .foregroundStyle(MTTheme.textSecondary)
                MTStepperField(value: value, range: range, step: step, suffix: suffix)
            }
            Text(note)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300, alignment: .leading)
    }

    // MARK: - Groups

    private var groupsCard: some View {
        MTCard(title: L("Model groups"), systemImage: "square.stack.3d.up", accent: MTTheme.violet) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if groups.groups.isEmpty {
                    MTEmptyState(
                        systemImage: "square.stack.3d.up",
                        title: L("No model groups yet"),
                        subtitle: L("A group gives one model name to several providers, so a failing upstream is replaced automatically.")
                    )
                    .frame(height: 150)
                } else {
                    MTListCard {
                        VStack(spacing: 0) {
                            ForEach(groups.groups) { group in
                                groupRow(group)
                                if group.id != groups.groups.last?.id {
                                    MTRowSeparator()
                                }
                            }
                        }
                    }
                }
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("New group"), systemImage: "plus", tint: MTTheme.violet) {
                        draft = RoutingGroupDraft(group: nil)
                    }
                    if let error = groups.error {
                        Text(error)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.danger)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func groupRow(_ group: RoutingGroup) -> some View {
        let providers = providerTitles(for: group)
        return MTRow(
            title: group.alias,
            subtitle: group.note.isEmpty
                ? String(format: L("%d providers"), providers.count)
                : group.note,
            systemImage: "square.stack.3d.up",
            accent: group.enabled ? MTTheme.violet : MTTheme.textTertiary,
            isEnabled: group.enabled,
            // Without an action the row drew a chevron that did nothing, so the
            // arrow on the right of a group looked clickable and was not.
            action: { draft = RoutingGroupDraft(group: group) }
        ) {
            HStack(spacing: MTTheme.s2) {
                ForEach(providers.prefix(2), id: \.self) { title in
                    MTBadge(text: title, tint: MTTheme.textSecondary)
                }
                if providers.count > 2 {
                    MTBadge(text: "+\(providers.count - 2)", tint: MTTheme.textTertiary)
                }
                Text("\(group.members.count)")
                    .font(MTTheme.mono(9, weight: .semibold))
                    .foregroundStyle(MTTheme.textTertiary)
                Toggle("", isOn: Binding(
                    get: { group.enabled },
                    set: { value in
                        if groups.setEnabled(id: group.id, enabled: value) == nil {
                            Task { await sources.apply() }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(MTTheme.emerald)
                MTMenuButton(systemImage: "ellipsis.circle", tint: MTTheme.textSecondary, entries: [
                    .item(L("Edit"), systemImage: "pencil") { draft = RoutingGroupDraft(group: group) },
                    .divider,
                    .item(L("Delete"), systemImage: "trash", destructive: true) { pendingDelete = group }
                ])
            }
        }
    }

    private func providerTitles(for group: RoutingGroup) -> [String] {
        var seen: Set<String> = []
        var titles: [String] = []
        for member in group.members {
            guard seen.insert(member.sourceID).inserted else { continue }
            titles.append(sources.source(id: member.sourceID)?.title ?? member.sourceID)
        }
        return titles
    }

    // MARK: - Explanation

    private var explanationCard: some View {
        MTCard(title: L("How failover works"), systemImage: "info.circle", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                bullet(L("The alias is written to every member provider, so the gateway lists it once."))
                bullet(L("A failed request moves to another member provider before the client sees an error."))
                bullet(L("The engine orders providers by model count, then by name; inside one provider the order is kept."))
                bullet(L("A group is not a load balancer: the engine still applies the routing strategy and cooldowns above."))
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: MTTheme.s2) {
            Circle()
                .fill(MTTheme.violet.opacity(0.7))
                .frame(width: 4, height: 4)
                .padding(.top, 5)
            Text(text)
                .font(MTTheme.mono(9.5))
                .foregroundStyle(MTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One entry point for the gateway: routing rules and model groups. The API
/// service used to live here as a second tab; it is its own sidebar section
/// now, so this view no longer carries a tab bar.
struct RoutingView: View {
    @Binding var selection: MTSection

    var body: some View {
        RoutingContent(selection: $selection)
            .background(MTTheme.background)
    }
}

/// Open the API service section from anywhere in the app. The old deep link
/// also asked for a tab on this page; that tab is gone, so the call keeps its
/// shape and only moves the selection.
enum GatewayDeepLink {
    static func openAPI(selection: Binding<MTSection>) {
        selection.wrappedValue = .codexAPI
    }
}
