import AppKit
import SwiftUI

// MARK: - Shared model-list controls and the custom provider editor

/// Catalog models that no connected Antigravity account can use. Collapsed by
/// default: a pool can list dozens of ids and would otherwise turn the
/// provider card into a wall of unavailable names.
struct AntigravityCatalogOnlyBlock: View {
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
struct SelectAllControls: View {
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
    var priority = ""
    var models: [SourceModel] = []

    init(source: ModelSource?) {
        originalID = source?.id
        identifier = source?.id ?? ""
        title = source?.title ?? ""
        baseURL = source?.baseURL ?? ""
        apiProtocol = source?.effectiveProtocol ?? .openAIChat
        apiKey = source?.apiKey ?? ""
        priority = source?.priority.map(String.init) ?? ""
        models = source?.models ?? []
    }
}

struct CustomProviderResult {
    var identifier: String
    var title: String
    var baseURL: String
    var apiProtocol: ModelSource.APIProtocol
    var apiKey: String
    var priority: Int?
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
    @State private var priority: String
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
        _priority = State(initialValue: draft.priority)
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
                        fieldLabel(L("Priority"))
                        TextField("0", text: $priority)
                            .textFieldStyle(.mtInput)
                            .font(MTTheme.mono(11))
                        // The engine asks the highest tier that still has a
                        // healthy credential and only then falls back, so a
                        // faster provider can be preferred without taking it
                        // out of the failover chain.
                        footnote(
                            L("Higher is tried first. Empty or 0 means no preference."),
                            color: MTTheme.textTertiary
                        )
                    }

                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        fieldLabel(L("API protocol"))
                        MTSelect(
                            selection: $apiProtocol,
                            options: ModelSource.APIProtocol.allCases.map { ($0, $0.title) },
                            width: 260
                        )
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
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " " + L("M")
        }
        if value >= 1_000 {
            return (Double(value) / 1_000).formatted(.number.precision(.fractionLength(0))) + " " + L("K")
        }
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
            priority: Int(priority.trimmingCharacters(in: .whitespacesAndNewlines)),
            models: models
        )
        error = onSave(result)
        if error == nil { dismiss() }
    }
}
