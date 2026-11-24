import SwiftUI
import AppKit

/// Agents: point local AI clients at the gateway, with a backup of every file
/// that gets touched. Managed agents are edited in place; the rest show the
/// values to paste into their own settings, honestly labelled as manual.
struct AgentsView: View {
    @Binding var selection: MTSection

    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var sources = ModelSourcesStore.shared

    @State private var query = ""
    @State private var group: AgentDefinition.Group?
    @State private var selectedAgentID: String?
    @State private var customDraft: CustomAgentDraft?
    @State private var pendingDelete: CustomAgent?
    @State private var showNotSetUp = false
    @AppStorage("agents.getStartedCollapsed") private var getStartedCollapsed = false

    var body: some View {
        Group {
            if let id = selectedAgentID, let definition = definition(id: id) {
                AgentDetailView(
                    definition: definition,
                    onBack: { selectedAgentID = nil },
                    onEdit: { custom in customDraft = CustomAgentDraft(agent: custom) },
                    onDelete: { pendingDelete = $0 }
                )
            } else {
                board
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $customDraft) { draft in
            CustomAgentSheet(draft: draft) { agent in
                if draft.originalID == nil {
                    return store.addCustom(agent)
                }
                var updated = agent
                updated.id = draft.originalID ?? agent.id
                return store.updateCustom(updated)
            }
        }
        .confirmationDialog(
            L("Delete this agent?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                if let agent = pendingDelete {
                    store.removeCustom(id: agent.id)
                    selectedAgentID = nil
                }
                pendingDelete = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L("The agent disappears from the list. Its config file is restored from the backup if it was connected."))
        }
    }

    // MARK: - Board

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Agents"),
                    subtitle: L("Agents subtitle")
                )
                getStarted
                controls
                ForEach(visibleGroups, id: \.self) { group in
                    section(group)
                }
                notSetUpSection
                customSection
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MTTheme.textTertiary)
                TextField(L("Search agents"), text: $query)
                    .textFieldStyle(.plain)
                    .font(MTTheme.mono(11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(MTTheme.cardBackground, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
            .frame(width: 240)

            MTChipPicker(
                items: [nil] + AgentDefinition.Group.allCases.map(Optional.init),
                title: { $0?.title ?? L("All") },
                selection: $group
            )
            Spacer(minLength: MTTheme.s2)
            MTGlassButton(title: L("Add agent"), systemImage: "plus", tint: MTTheme.emerald) {
                customDraft = CustomAgentDraft(agent: nil)
            }
        }
    }

    // MARK: - Get started

    /// Onboarding checklist, as Magpie's Agents page: two required steps and
    /// an optional routing hint. Hidden once both required steps are done.
    private var hasModelSource: Bool { !sources.sources.isEmpty }

    private var hasConnectedAgent: Bool {
        AgentCatalog.all.contains { store.status(for: $0) == .connected }
    }

    private var getStartedDone: Int {
        (hasModelSource ? 1 : 0) + (hasConnectedAgent ? 1 : 0)
    }

    private var connectable: [AgentDefinition] {
        AgentCatalog.all.filter { store.status(for: $0) == .ready }
    }

    @ViewBuilder
    private var getStarted: some View {
        if getStartedDone < 2 {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(spacing: MTTheme.s2) {
                    MTCardSectionTitle(text: L("Get started"), systemImage: "sparkles")
                    Text(String(format: L("%d of 2 done"), getStartedDone))
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(getStartedDone == 0 ? MTTheme.textTertiary : MTTheme.emerald)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { getStartedCollapsed.toggle() }
                    } label: {
                        Image(systemName: getStartedCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(getStartedCollapsed ? L("Expand") : L("Collapse"))
                }
                if !getStartedCollapsed {
                    getStartedStep(
                        number: 1,
                        done: hasModelSource,
                        title: L("Add a model source"),
                        detail: L("A subscription you already pay for, a provider, or an API key.")
                    ) {
                        if !hasModelSource {
                            MTGlassButton(title: L("Add a provider"), systemImage: "plus", tint: MTTheme.emerald) {
                                selection = .providers
                            }
                        }
                    }
                    getStartedDivider
                    getStartedStep(
                        number: 2,
                        done: hasConnectedAgent,
                        title: L("Connect an agent"),
                        detail: L("Melon Tools found these on this computer. Click one to connect it.")
                    ) {
                        if connectable.isEmpty {
                            Text(L("Nothing found yet. Install an agent from the list below."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textTertiary)
                        } else {
                            HStack(spacing: MTTheme.s2) {
                                ForEach(connectable.prefix(5)) { agent in
                                    connectableChip(agent)
                                }
                            }
                        }
                    }
                    getStartedDivider
                    getStartedStep(
                        number: 3,
                        done: false,
                        title: L("Set up routing (optional)"),
                        detail: L("A routing group sends each request to the right model, and to the next one when a model fails.")
                    ) {
                        Button(L("Open routing")) { selection = .routing }
                            .buttonStyle(.plain)
                            .font(MTTheme.mono(10, weight: .semibold))
                            .foregroundStyle(MTTheme.cyan)
                    }
                }
            }
            .padding(MTTheme.s4)
            .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
        }
    }

    private func getStartedStep<Actions: View>(
        number: Int,
        done: Bool,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: MTTheme.s3) {
            ZStack {
                Circle()
                    .fill(done ? MTTheme.emerald.opacity(0.16) : MTTheme.cardBackground)
                Circle()
                    .strokeBorder(done ? MTTheme.emerald.opacity(0.45) : MTTheme.borderColor, lineWidth: 0.75)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(MTTheme.emerald)
                } else {
                    Text("\(number)")
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(title)
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(done ? MTTheme.textSecondary : MTTheme.textPrimary)
                Text(detail)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
    }

    private var getStartedDivider: some View {
        Rectangle()
            .fill(MTTheme.borderColor.opacity(0.55))
            .frame(height: 0.5)
            .padding(.leading, 32)
    }

    private func connectableChip(_ agent: AgentDefinition) -> some View {
        Button {
            selectedAgentID = agent.id
        } label: {
            HStack(spacing: 5) {
                AgentGlyph(agent: agent, size: 15)
                Text(agent.title)
                    .font(MTTheme.mono(10, weight: .medium))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(MTTheme.cardBackground, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.title)
    }

    /// Groups with at least one agent that is installed, connected or has
    /// settings. A missing client is folded away, as Magpie does.
    private var visibleGroups: [AgentDefinition.Group] {
        AgentDefinition.Group.allCases.filter { !visible(in: $0).isEmpty }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matching(in group: AgentDefinition.Group) -> [AgentDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return AgentCatalog.all.filter { agent in
            guard agent.group == group else { return false }
            guard trimmed.isEmpty
                || agent.title.localizedCaseInsensitiveContains(trimmed)
                || agent.subtitle.localizedCaseInsensitiveContains(trimmed)
                || agent.note.localizedCaseInsensitiveContains(trimmed)
            else { return false }
            return true
        }
    }

    /// Desktop apps is a filter, not a fourth group: it also shows the
    /// editors (Cursor, VS Code, Zed, JetBrains), which are GUI apps too.
    private func matchesFilter(_ group: AgentDefinition.Group) -> Bool {
        guard let filter = self.group else { return true }
        if filter == .desktop { return group == .desktop || group == .editors }
        return group == filter
    }

    private func visible(in group: AgentDefinition.Group) -> [AgentDefinition] {
        guard matchesFilter(group) else { return [] }
        return matching(in: group).filter { agent in
            if isSearching { return true }
            return store.status(for: agent) != .notDetected
        }
    }

    /// Everything not installed and not configured: the "Not set up" fold.
    private var notSetUp: [AgentDefinition] {
        let groupFilter = group
        return AgentCatalog.all.filter { agent in
            guard agent.isManaged else { return false }
            guard groupFilter == nil || agent.group == groupFilter
                || (groupFilter == .desktop && agent.group == .editors)
            else { return false }
            if isSearching {
                return matching(in: agent.group).contains(where: { $0.id == agent.id })
            }
            return store.status(for: agent) == .notDetected
        }
    }

    private func section(_ group: AgentDefinition.Group) -> some View {
        let agents = visible(in: group)
        return VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                MTCardSectionTitle(text: group.title, systemImage: groupIcon(group))
                Text("\(agents.count)")
                    .font(MTTheme.mono(9, weight: .semibold))
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                let connected = agents.filter { store.status(for: $0) == .connected }.count
                if connected > 0 {
                    Text(String(format: L("%d connected"), connected))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.emerald)
                }
            }
            MTListCard {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { MTRowSeparator() }
                        row(agent)
                    }
                }
            }
        }
    }

    private func groupIcon(_ group: AgentDefinition.Group) -> String {
        switch group {
        case .terminal: return "terminal"
        case .editors: return "square.split.2x1"
        case .desktop: return "desktopcomputer"
        }
    }

    private func row(_ agent: AgentDefinition) -> some View {
        let status = store.status(for: agent)
        return MTRow(
            title: agent.title,
            subtitle: resolvedPath(agent) ?? agent.subtitle,
            leading: AnyView(AgentGlyph(agent: agent)),
            accent: agent.tint,
            showsChevron: true,
            action: { selectedAgentID = agent.id }
        ) {
            statusBadge(status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.title), \(status.label)")
    }

    /// The path the adapter will edit: the first one that exists, else the one
    /// it creates.
    private func resolvedPath(_ agent: AgentDefinition) -> String? {
        let urls = store.configURLs(for: agent)
        if let existing = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return (existing.path as NSString).abbreviatingWithTildeInPath
        }
        return agent.configPath
    }

    private func statusBadge(_ status: AgentStatus) -> some View {
        let tint: Color
        switch status {
        case .connected: tint = MTTheme.emerald
        case .cliMissing: tint = MTTheme.amber
        case .manual, .notDetected: tint = MTTheme.textTertiary
        case .ready: tint = MTTheme.textSecondary
        }
        return MTBadge(text: status.label, tint: tint)
    }

    // MARK: - Not set up

    @ViewBuilder
    private var notSetUpSection: some View {
        let folded = notSetUp
        if !folded.isEmpty && !isSearching {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showNotSetUp.toggle() }
                } label: {
                    HStack(spacing: MTTheme.s2) {
                        Image(systemName: showNotSetUp ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(String(format: L("Not set up (%d)"), folded.count))
                            .font(MTTheme.mono(10, weight: .semibold))
                            .foregroundStyle(MTTheme.textSecondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: L("Not set up (%d)"), folded.count))

                if showNotSetUp {
                    MTListCard {
                        VStack(spacing: 0) {
                            ForEach(Array(folded.enumerated()), id: \.element.id) { index, agent in
                                if index > 0 { MTRowSeparator() }
                                installRow(agent)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A client that is not on this Mac: the row explains what it is and, when
    /// the catalog knows one, offers the command that installs it.
    private func installRow(_ agent: AgentDefinition) -> some View {
        MTRow(
            title: agent.title,
            subtitle: agent.installCommand ?? agent.subtitle,
            leading: AnyView(AgentGlyph(agent: agent)),
            accent: agent.tint,
            showsChevron: false
        ) {
            if let command = agent.installCommand {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("Copy the install command"))
                .accessibilityLabel(L("Copy the install command"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.title)
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                MTCardSectionTitle(text: L("Your agents"), systemImage: "person.crop.circle.badge.plus")
                Spacer()
                if !store.customAgents.isEmpty {
                    Text("\(store.customAgents.count)")
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
            if store.customAgents.isEmpty {
                Text(L("Add any client with a JSON or env config: name it, point to the file and name the keys."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            } else {
                MTListCard {
                    VStack(spacing: 0) {
                        ForEach(Array(store.customAgents.enumerated()), id: \.element.id) { index, custom in
                            if index > 0 { MTRowSeparator() }
                            customRow(custom)
                        }
                    }
                }
            }
        }
    }

    private func customRow(_ custom: CustomAgent) -> some View {
        let definition = store.customDefinitions.first { $0.id == "custom:\(custom.id.uuidString)" }
        let status = definition.map(store.status(for:)) ?? .manual
        return MTRow(
            title: custom.title,
            subtitle: "\(custom.format.title) · \(custom.configPath)",
            systemImage: custom.format == .json ? "curlybraces" : "doc.text",
            accent: MTTheme.violet,
            showsChevron: true,
            action: { selectedAgentID = "custom:\(custom.id.uuidString)" }
        ) {
            HStack(spacing: MTTheme.s2) {
                statusBadge(status)
                MTMenuButton(systemImage: "ellipsis.circle", tint: MTTheme.textSecondary, entries: [
                    .item(L("Edit"), systemImage: "pencil") { customDraft = CustomAgentDraft(agent: custom) },
                    .divider,
                    .item(L("Delete"), systemImage: "trash", destructive: true) { pendingDelete = custom }
                ])
            }
        }
    }

    private func definition(id: String) -> AgentDefinition? {
        AgentCatalog.agent(id: id) ?? store.customDefinitions.first { $0.id == id }
    }
}

// MARK: - Detail

private struct AgentDetailView: View {
    let definition: AgentDefinition
    var onBack: () -> Void
    var onEdit: (CustomAgent) -> Void
    var onDelete: (CustomAgent) -> Void

    @ObservedObject private var store = AgentStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var sources = ModelSourcesStore.shared

    @State private var model = ""
    @State private var effort = ""
    @State private var revealKey = false
    @State private var error: String?
    @State private var didLoad = false
    @State private var copied = false
    @State private var confirmRevert = false

    private var baseURL: String { gateway.baseURL + "/v1" }
    private var apiKey: String { gateway.apiKey }
    private var application: AgentApplication? { store.application(for: definition) }
    private var status: AgentStatus { store.status(for: definition) }
    private var custom: CustomAgent? { store.customAgent(for: definition) }
    private var showsModel: Bool { definition.fields.contains(.model) }
    private var showsEffort: Bool { definition.fields.contains(.effort) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                header
                if case .manual = definition.integration, custom == nil {
                    manualCard
                } else {
                    connectionCard
                    if showsModel { modelCard }
                    if showsEffort { effortCard }
                    if application != nil && store.drift(for: definition) { driftCard }
                    pathCard
                    if !store.backups(for: definition).isEmpty { backupsCard }
                }
                noteCard
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear(perform: loadModel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("All agents"))
                        .font(MTTheme.body(11))
                }
                .foregroundStyle(MTTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            HStack(spacing: MTTheme.s3) {
                AgentGlyph(agent: definition, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.title)
                        .font(MTTheme.display(24))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(definition.subtitle)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                statusPill
            }
        }
    }

    private var statusPill: some View {
        let tint: Color
        switch status {
        case .connected: tint = MTTheme.emerald
        case .ready: tint = MTTheme.cyan
        case .cliMissing: tint = MTTheme.amber
        case .notDetected: tint = MTTheme.textTertiary
        case .manual: tint = MTTheme.textTertiary
        }
        return HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(status.label.uppercased())
                .font(MTTheme.mono(9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(MTTheme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(MTTheme.cardBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75))
    }

    // MARK: Connection

    private var connectionCard: some View {
        MTCard(title: L("Connection"), systemImage: "link", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                valueRow(title: L("Base URL"), value: baseURL, mono: true) { EmptyView() }
                valueRow(
                    title: L("API key"),
                    value: revealKey ? apiKey : String(repeating: "•", count: 24),
                    mono: true
                ) {
                    Button(revealKey ? L("Hide") : L("Show")) { revealKey.toggle() }
                        .buttonStyle(.link)
                        .font(MTTheme.mono(9))
                }
                if !gateway.isRunning {
                    Text(L("The gateway is stopped. The values stay valid once it starts."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.amber)
                }
                if status == .cliMissing {
                    Text(L("The settings are still here, but the program is not. Install it again before connecting."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.amber)
                }
                HStack(spacing: MTTheme.s3) {
                    if application == nil {
                        MTGlassButton(
                            title: L("Connect"),
                            systemImage: "bolt.fill",
                            tint: MTTheme.emerald,
                            prominent: true,
                            isLoading: false
                        ) {
                            apply()
                        }
                        .disabled(gateway.apiKey.isEmpty)
                    } else {
                        MTGlassButton(title: L("Reapply"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                            apply()
                        }
                        MTGlassButton(title: L("Revert"), systemImage: "arrow.uturn.backward", tint: MTTheme.ruby) {
                            confirmRevert = true
                        }
                    }
                    Spacer(minLength: MTTheme.s2)
                    if let application {
                        Text(String(format: L("Connected %@"), application.appliedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                if application != nil, let hint = definition.restartHint {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                        Text(hint)
                            .font(MTTheme.mono(9))
                    }
                    .foregroundStyle(MTTheme.cyan)
                }
                if let error {
                    Text(error)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.danger)
                }
            }
            .confirmationDialog(
                L("Restore the config that was there before?"),
                isPresented: $confirmRevert,
                titleVisibility: .visible
            ) {
                Button(L("Revert"), role: .destructive) { revert() }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("The backup taken before the last connect is written back."))
            }
        }
    }

    private var modelCard: some View {
        MTCard(title: L("Model"), systemImage: "cube", accent: MTTheme.violet) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    modelMenu
                    TextField("gpt-5", text: $model)
                        .textFieldStyle(.mtInput)
                        .font(MTTheme.mono(11))
                }
                Text(L("Pick a model from Providers, or type the name the agent asks the gateway for."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(sources.sources.filter(\.enabled)) { source in
                let models = source.models.filter(\.enabled)
                if !models.isEmpty {
                    Section(source.title) {
                        ForEach(models) { item in
                            Button(item.alias) { model = item.alias }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10, weight: .semibold))
                Text(L("Choose"))
                    .font(MTTheme.mono(10, weight: .medium))
            }
            .foregroundStyle(MTTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(MTTheme.cardSoft, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("Choose a model"))
    }

    private var effortCard: some View {
        MTCard(title: L("Reasoning effort"), systemImage: "gauge.with.dots.needle.33percent", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                MTSelect(
                    selection: $effort,
                    options: [("", L("Default"))] + definition.effortOptions.map { ($0, $0) },
                    width: 180
                )
                Text(L("How much the model reasons before it answers. The agent may offer its own levels too."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    private var driftCard: some View {
        MTCard(title: L("Config changed"), systemImage: "exclamationmark.triangle", accent: MTTheme.amber) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(L("The config was edited outside Melon Tools after it was connected. Apply again to put the gateway values back."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                MTGlassButton(title: L("Apply again"), systemImage: "arrow.clockwise", tint: MTTheme.amber) {
                    apply()
                }
            }
        }
    }

    /// Files this apply will write. OpenCode and DSH move between names and
    /// profiles, so the other candidates stay visible as fallbacks instead of
    /// pretending they will be created.
    private var activeConfigURLs: Set<URL> {
        let urls = store.configURLs(for: definition)
        switch definition.integration {
        case .vscode:
            return Set(urls)
        case .antigravity:
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            return Set(existing.isEmpty ? Array(urls.prefix(1)) : existing)
        default:
            let existing = urls.first { FileManager.default.fileExists(atPath: $0.path) }
            return Set([existing ?? urls[0]])
        }
    }

    private var pathCard: some View {
        MTCard(title: L("Config file"), systemImage: "doc.text", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                ForEach(store.configURLs(for: definition), id: \.self) { url in
                    let isActive = activeConfigURLs.contains(url)
                    HStack(spacing: MTTheme.s2) {
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(isActive ? MTTheme.textPrimary : MTTheme.textTertiary)
                            .textSelection(.enabled)
                        if !isActive {
                            MTBadge(text: L("Fallback"), tint: MTTheme.textTertiary)
                        } else if FileManager.default.fileExists(atPath: url.path) {
                            MTBadge(text: L("Found"), tint: MTTheme.emerald)
                        } else {
                            MTBadge(text: L("Will be created"), tint: MTTheme.textTertiary)
                        }
                        Spacer(minLength: MTTheme.s2)
                        if FileManager.default.fileExists(atPath: url.path) {
                            Button(L("Reveal")) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .buttonStyle(.link)
                            .font(MTTheme.mono(9))
                        }
                    }
                }
                Text(definition.note)
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                if let custom {
                    HStack(spacing: MTTheme.s3) {
                        Button(L("Edit agent")) { onEdit(custom) }
                            .buttonStyle(.link)
                            .font(MTTheme.mono(9))
                        Button(L("Delete agent")) { onDelete(custom) }
                            .buttonStyle(.link)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.ruby)
                    }
                }
            }
        }
    }

    private var backupsCard: some View {
        MTCard(title: L("Backups"), systemImage: "clock.arrow.circlepath", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                ForEach(store.backups(for: definition).prefix(4), id: \.self) { url in
                    HStack(spacing: MTTheme.s2) {
                        Text(url.lastPathComponent)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: MTTheme.s2)
                        Button(L("Reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                        .font(MTTheme.mono(9))
                    }
                }
                Text(L("Backups are plain copies in Application Support and are never deleted automatically."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    // MARK: Manual

    private var manualCard: some View {
        MTCard(title: L("Manual setup"), systemImage: "hand.raised", accent: MTTheme.amber) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                Text(definition.note)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AgentAdapters.snippet(prefix: manualPrefix, context: context))
                    .font(MTTheme.mono(9.5))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(MTTheme.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(
                        title: copied ? L("Copied") : L("Copy values"),
                        systemImage: copied ? "checkmark" : "doc.on.doc",
                        tint: MTTheme.cyan
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            AgentAdapters.snippet(prefix: manualPrefix, context: context),
                            forType: .string
                        )
                        copied = true
                    }
                    Button(L("Reveal the API key")) { revealKey = true }
                        .buttonStyle(.link)
                        .font(MTTheme.mono(9))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var manualPrefix: String {
        if case .manual(let key) = definition.integration { return key }
        return "OPENAI_BASE_URL"
    }

    private var noteCard: some View {
        MTCard(title: L("What changes"), systemImage: "info.circle", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(definition.note)
                    .font(MTTheme.mono(9.5))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Melon Tools keeps a copy of the file before writing and never touches the other keys."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
        }
    }

    // MARK: Actions

    private var context: AgentApplyContext {
        AgentApplyContext(baseURL: baseURL, apiKey: apiKey, model: model, effort: effort)
    }

    private func loadModel() {
        guard !didLoad else { return }
        didLoad = true
        if let applied = application {
            model = applied.model
            effort = applied.effort ?? ""
            if !model.isEmpty { return }
        }
        model = sources.sources
            .flatMap(\.models)
            .first(where: { $0.enabled })?
            .alias ?? ""
    }

    private func apply() {
        do {
            _ = try store.apply(definition, context: context)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revert() {
        do {
            try store.revert(definition)
            effort = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func valueRow<Accessory: View>(
        title: String,
        value: String,
        mono: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(MTTheme.mono(8.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(MTTheme.textTertiary)
            HStack(spacing: MTTheme.s2) {
                Text(value)
                    .font(mono ? MTTheme.mono(10) : MTTheme.body(11))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                accessory()
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(L("Copy"))
                .accessibilityLabel(L("Copy"))
            }
        }
    }
}
