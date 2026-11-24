import SwiftUI

/// One group being created or edited in the sheet.
struct RoutingGroupDraft: Identifiable {
    let id = UUID()
    let originalID: UUID?
    var alias: String
    var note: String
    var enabled: Bool
    var members: [RoutingGroupMember]

    init(group: RoutingGroup?) {
        originalID = group?.id
        alias = group?.alias ?? ""
        note = group?.note ?? ""
        enabled = group?.enabled ?? true
        members = group?.members ?? []
    }
}

/// Editor for one routing group: a model name plus the upstream models that
/// serve it. The same alias is written to every member provider, which is what
/// makes the engine treat them as one model with failover.
struct RoutingGroupEditor: View {
    @Environment(\.dismiss) private var dismiss

    let draft: RoutingGroupDraft
    let onSave: (RoutingGroupDraft) -> String?

    @ObservedObject private var sources = ModelSourcesStore.shared

    @State private var alias: String
    @State private var note: String
    @State private var enabled: Bool
    @State private var members: [RoutingGroupMember]
    @State private var selectedSourceID: String = ""
    @State private var query = ""
    @State private var error: String?

    init(draft: RoutingGroupDraft, onSave: @escaping (RoutingGroupDraft) -> String?) {
        self.draft = draft
        self.onSave = onSave
        _alias = State(initialValue: draft.alias)
        _note = State(initialValue: draft.note)
        _enabled = State(initialValue: draft.enabled)
        _members = State(initialValue: draft.members)
        _selectedSourceID = State(initialValue: draft.members.first?.sourceID ?? "")
    }

    /// Sources that can carry an alias in `config.yaml`. Antigravity is
    /// OAuth-only and the Codex pool lives in auth files, so neither can be a
    /// group member.
    private var eligibleSources: [ModelSource] {
        sources.sources.filter { source in
            // Antigravity is OAuth-only: its models never appear in
            // `src/models`, so they cannot carry an alias.
            source.kind != .antigravity && !source.models.isEmpty
        }
    }

    private var currentSource: ModelSource? {
        eligibleSources.first { $0.id == selectedSourceID } ?? eligibleSources.first
    }

    private var candidateModels: [SourceModel] {
        guard let source = currentSource else { return [] }
        let used = Set(members.map { $0.sourceID + "|" + $0.modelID })
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return source.models.filter { model in
            guard !used.contains(source.id + "|" + model.id) else { return false }
            return trimmed.isEmpty
                || model.id.localizedCaseInsensitiveContains(trimmed)
                || model.display.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        // The member list and the candidate list both grow with the data, so
        // the sheet keeps its title bar and its buttons pinned and scrolls the
        // middle. Before this the whole sheet was one fixed frame and a full
        // group pushed the footer off the bottom edge.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.originalID == nil ? L("New model group") : L("Edit model group"))
                        .font(MTTheme.display(20))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("The alias becomes one model that every member provider can serve."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                Toggle(L("Enabled"), isOn: $enabled)
                    .toggleStyle(.switch)
                    .tint(MTTheme.emerald)
                    .controlSize(.small)
            }
            .padding(MTTheme.s5)

            Divider().overlay(MTTheme.borderColor)

            ScrollView {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        Text(L("Model name").uppercased())
                            .font(MTTheme.mono(9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(MTTheme.textTertiary)
                        TextField("fast", text: $alias)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.mono(11))
                        Text(L("Clients ask for this name. Lowercase letters, digits, dots, dashes, slashes or underscores."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                        TextField(L("Note (optional)"), text: $note)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.mono(11))
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        HStack {
                            MTCardSectionTitle(text: L("Members"), systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(members.count)")
                                .font(MTTheme.mono(9, weight: .semibold))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        if members.isEmpty {
                            Text(L("No members yet. Add at least one model below."))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        } else {
                            MTListCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                                        if index > 0 { MTRowSeparator() }
                                        memberRow(member)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        MTCardSectionTitle(text: L("Add a model"), systemImage: "plus")
                        HStack(spacing: MTTheme.s2) {
                            MTSelect(
                                selection: $selectedSourceID,
                                options: eligibleSources.map { ($0.id, $0.title) },
                                width: 210
                            )
                            TextField(L("Search models"), text: $query)
                                .textFieldStyle(.mtInput)
                                .font(MTTheme.mono(10))
                        }
                        // One scroller per sheet: this list used to scroll on
                        // its own inside the sheet's scroller, and the wheel
                        // stopped dead at the inner list's edge because the
                        // outer one never saw the event. Long lists are fine
                        // here, the sheet already scrolls.
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(candidateModels) { model in
                                addRow(source: currentSource, model: model)
                            }
                        }
                        .background(MTTheme.cardSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: MTTheme.rSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MTTheme.rSmall)
                                .strokeBorder(MTTheme.borderColor.opacity(0.6), lineWidth: 0.75)
                        )
                    }

                    if let error {
                        Text(error)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.danger)
                    }
                }
                .padding(MTTheme.s5)
            }

            Divider().overlay(MTTheme.borderColor)

            HStack {
                Text(L("The engine lists the alias once. The order between providers is decided by the engine, not by this list."))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(MTTheme.s5)
        }
        .frame(width: 640, height: 660)
        .background(MTTheme.background)
    }

    private func memberRow(_ member: RoutingGroupMember) -> some View {
        let source = sources.source(id: member.sourceID)
        let model = source?.models.first { $0.id == member.modelID }
        return MTRow(
            title: member.modelID,
            subtitle: source?.title ?? member.sourceID,
            systemImage: "square.stack.3d.up",
            accent: MTTheme.violet
        ) {
            HStack(spacing: MTTheme.s2) {
                Button {
                    members.removeAll { $0.id == member.id }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(MTTheme.ruby)
                }
                .buttonStyle(.plain)
                .help(L("Remove from the group"))
                .accessibilityLabel(L("Remove from the group"))
                if let context = model?.contextLength, context > 0 {
                    Text(context >= 1000 ? "\(context / 1000)K" : "\(context)")
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }
        }
    }

    private func addRow(source: ModelSource?, model: SourceModel) -> some View {
        let already = isMember(sourceID: source?.id, modelID: model.id)
        return HStack(spacing: MTTheme.s2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.display)
                    .font(MTTheme.body(11.5))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                if model.display != model.id {
                    Text(model.id)
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: MTTheme.s2)
            if already {
                Text(L("In the group"))
                    .font(MTTheme.body(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            Button {
                guard let source else { return }
                members.append(RoutingGroupMember(sourceID: source.id, modelID: model.id))
            } label: {
                Image(systemName: already ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(already ? MTTheme.textTertiary : MTTheme.emerald)
            }
            .buttonStyle(.plain)
            .disabled(already)
            .help(already ? L("Already in the group") : L("Add to the group"))
            .accessibilityLabel(L("Add to the group"))
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, 5)
    }

    /// Whether the group already routes this source and model, by the same
    /// rule the store dedupes with.
    private func isMember(sourceID: String?, modelID: String) -> Bool {
        guard let sourceID else { return false }
        return members.contains { $0.sourceID == sourceID && $0.modelID == modelID }
    }

    private func save() {
        var updated = draft
        updated.alias = alias
        updated.note = note
        updated.enabled = enabled
        updated.members = members
        if let problem = onSave(updated) {
            error = problem
        } else {
            dismiss()
        }
    }
}
