import SwiftUI

struct CustomAgentDraft: Identifiable {
    let id = UUID()
    let originalID: UUID?
    var agent: CustomAgent

    init(agent: CustomAgent?) {
        originalID = agent?.id
        self.agent = agent ?? CustomAgent(
            title: "",
            configPath: "~/.my-agent/config.json",
            format: .json,
            baseURLKey: "baseURL",
            apiKeyKey: "apiKey"
        )
    }
}

/// Add or edit a user-defined agent. Two formats cover most clients: a JSON
/// file with dotted keys and a dotenv file with plain keys.
struct CustomAgentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draft: CustomAgentDraft
    let onSave: (CustomAgent) -> String?

    @State private var agent: CustomAgent
    @State private var error: String?

    init(draft: CustomAgentDraft, onSave: @escaping (CustomAgent) -> String?) {
        self.draft = draft
        self.onSave = onSave
        _agent = State(initialValue: draft.agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.originalID == nil ? L("New agent") : L("Edit agent"))
                    .font(MTTheme.display(20))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(L("Any client with a JSON or env config can be connected here."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }

            field(L("Name"), placeholder: "My agent") {
                TextField("My agent", text: $agent.title)
                    .textFieldStyle(.mtInput)
                    .font(MTTheme.mono(11))
            }

            field(L("Config file"), placeholder: "~/.my-agent/config.json") {
                TextField("~/.my-agent/config.json", text: $agent.configPath)
                    .textFieldStyle(.mtInput)
                    .font(MTTheme.mono(11))
            }

            field(L("Format"), placeholder: "") {
                MTSegmented(
                    selection: $agent.format,
                    options: CustomAgent.Format.allCases.map { ($0, $0.title) }
                )
            }

            HStack(alignment: .top, spacing: MTTheme.s3) {
                field(L("Base URL key"), placeholder: "baseURL") {
                    TextField("baseURL", text: $agent.baseURLKey)
                        .textFieldStyle(.mtInput)
                        .font(MTTheme.mono(11))
                }
                field(L("API key key"), placeholder: "apiKey") {
                    TextField("apiKey", text: $agent.apiKeyKey)
                        .textFieldStyle(.mtInput)
                        .font(MTTheme.mono(11))
                }
            }

            field(L("Model key"), placeholder: L("Optional")) {
                TextField(L("Optional"), text: $agent.modelKey)
                    .textFieldStyle(.mtInput)
                    .font(MTTheme.mono(11))
            }

            field(L("Note"), placeholder: L("Optional")) {
                TextField(L("Optional"), text: $agent.note)
                    .textFieldStyle(.mtInput)
                    .font(MTTheme.mono(11))
            }

            Text(keyHint)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.danger)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 540)
        .background(MTTheme.background)
    }

    private var keyHint: String {
        switch agent.format {
        case .json:
            return L("JSON keys may be dotted: env.OPENAI_BASE_URL writes inside the env object.")
        case .env:
            return L("Env keys are plain names, for example OPENAI_BASE_URL. Existing lines are replaced in place.")
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        placeholder: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(MTTheme.mono(8.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(MTTheme.textTertiary)
            content()
        }
    }

    private func save() {
        var updated = agent
        updated.title = agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.configPath = agent.configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.baseURLKey = agent.baseURLKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.apiKeyKey = agent.apiKeyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.modelKey = agent.modelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = onSave(updated) {
            error = problem
        } else {
            dismiss()
        }
    }
}
