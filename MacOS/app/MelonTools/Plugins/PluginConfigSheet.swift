import SwiftUI
import AppKit

/// Editor for one plugin's `plugins.configs.<id>` object.
///
/// The raw object is kept and only the declared fields are replaced, so keys a
/// plugin writes for itself survive a save. The sheet deliberately supports the
/// scalar field types the host advertises; arrays and objects get a JSON editor
/// instead of a guessed form.
struct PluginConfigSheet: View {
    let pluginID: String
    let onClose: () -> Void

    @ObservedObject private var store = PluginStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var config: [String: PluginJSON] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var enabled = true
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var installed: PluginInstalledEntry? {
        store.installedEntry(id: pluginID)
    }
    private var fields: [PluginConfigField] {
        installed?.configFields ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: MTTheme.s3) {
                if let installed {
                    PluginLogo(url: installed.logoURL, fallback: installed.displayName, size: 42)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed?.displayName ?? pluginID)
                        .font(MTTheme.display(20))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(pluginID)
                        .font(MTTheme.mono(9.5))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                MTGlassButton(title: L("Close"), size: .small, tint: MTTheme.textSecondary) {
                    onClose()
                    dismiss()
                }
            }
            .padding(MTTheme.s5)

            Divider()

            if isLoading {
                VStack(spacing: MTTheme.s3) {
                    ProgressView().controlSize(.small)
                    Text(L("Reading plugin settings..."))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: MTTheme.s4) {
                        HStack(spacing: MTTheme.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Plugin enabled"))
                                    .font(MTTheme.body(12, weight: .medium))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text(L("Disabling keeps the file and its settings on disk."))
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                            Toggle("", isOn: $enabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .padding(MTTheme.s3)
                        .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))

                        if fields.isEmpty {
                            VStack(alignment: .leading, spacing: MTTheme.s2) {
                                Text(L("This plugin declares no settings."))
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                                Text(L("It may read its configuration from another file or its own menu."))
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(MTTheme.s4)
                            .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous))
                        } else {
                            ForEach(fields) { field in
                                fieldEditor(field)
                            }
                        }

                        if let error {
                            Text(error)
                                .font(MTTheme.body(10.5))
                                .foregroundStyle(MTTheme.ruby)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(L("Saving reloads the plugin. A running stream may finish before the new settings apply."))
                            .font(MTTheme.body(9.5))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                    .padding(MTTheme.s5)
                }
            }

            Divider()
            HStack {
                if installed?.registered == false {
                    Text(L("The plugin is installed but not loaded. Restart the gateway to load it."))
                        .font(MTTheme.body(9.5))
                        .foregroundStyle(MTTheme.amber)
                }
                Spacer()
                MTGlassButton(title: L("Cancel"), size: .small, tint: MTTheme.textSecondary) {
                    onClose()
                    dismiss()
                }
                MTGlassButton(
                    title: L("Save"),
                    systemImage: "checkmark",
                    size: .small,
                    tint: MTTheme.violet,
                    prominent: true,
                    isLoading: isSaving
                ) {
                    Task { await save() }
                }
                .disabled(isSaving || isLoading)
            }
            .padding(MTTheme.s4)
        }
        .frame(width: 700, height: 640)
        .task { await load() }
        .interactiveDismissDisabled(isSaving)
    }

    @ViewBuilder
    private func fieldEditor(_ field: PluginConfigField) -> some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: MTTheme.s2) {
                Text(field.name)
                    .font(MTTheme.mono(10.5, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(field.type.title)
                    .font(MTTheme.mono(8.5))
                    .foregroundStyle(MTTheme.textTertiary)
                Spacer()
            }
            if !field.description.isEmpty {
                Text(field.description)
                    .font(MTTheme.body(10))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch field.type {
            case .boolean:
                Toggle(isOn: boolBinding(field)) {
                    Text(boolBinding(field).wrappedValue ? L("On") : L("Off"))
                        .font(MTTheme.body(10.5))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            case .enum:
                if field.enumValues.isEmpty {
                    TextField("", text: textBinding(field))
                        .textFieldStyle(.mtInput)
                } else {
                    MTSearchableSelect(
                        selection: textBinding(field),
                        options: field.enumValues.map { (value: $0, label: $0) },
                        width: 280
                    )
                }
            case .array, .object:
                TextEditor(text: textBinding(field))
                    .font(MTTheme.mono(10))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 68)
                    .background(MTTheme.cardSoft, in: RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MTTheme.rSmall, style: .continuous)
                            .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
                    )
            case .number, .integer, .string, .unknown:
                TextField("", text: textBinding(field))
                    .textFieldStyle(.mtInput)
            }
        }
        .padding(MTTheme.s3)
        .background(MTTheme.cardBackground, in: RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }

    private func textBinding(_ field: PluginConfigField) -> Binding<String> {
        Binding(
            get: { drafts[field.name] ?? "" },
            set: { drafts[field.name] = $0 }
        )
    }

    private func boolBinding(_ field: PluginConfigField) -> Binding<Bool> {
        Binding(
            get: { bools[field.name] ?? (field.defaultValue?.boolValue ?? false) },
            set: { bools[field.name] = $0 }
        )
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let values = try await store.config(id: pluginID)
            config = values
            enabled = installed?.enabled ?? true
            drafts = [:]
            bools = [:]
            for field in fields {
                let value = values[field.name] ?? field.defaultValue
                if field.type == .boolean {
                    bools[field.name] = value?.boolValue ?? false
                } else {
                    drafts[field.name] = value?.editorText ?? ""
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        var payload = config
        do {
            for field in fields {
                switch field.type {
                case .boolean:
                    payload[field.name] = .bool(boolBinding(field).wrappedValue)
                case .array, .object, .integer, .number, .string, .enum, .unknown:
                    payload[field.name] = try PluginJSON.parseEditorText(
                        drafts[field.name] ?? "",
                        type: field.type
                    )
                }
            }
            try await store.saveConfig(id: pluginID, values: payload, enabled: enabled)
            onClose()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
