import SwiftUI

/// A provider the app can add in one click: either a built-in connection with
/// its own page, or a preset that only pre-fills the custom provider sheet.
struct ProviderPreset: Identifiable, Hashable {
    var id: String
    var title: String
    var baseURL: String
    var apiProtocol: ModelSource.APIProtocol
    var systemImage: String
    var tint: Color
    /// Built-in providers already have a page and a model loader; the picker
    /// opens that page instead of creating a custom source.
    var builtinRoute: CodexProvidersView.ProviderRoute?
    var note: String?
    var group: Group = .cloud

    enum Group: String, CaseIterable, Identifiable {
        case connected
        case subscription
        case cloud
        case local

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connected: return L("Ready to use")
            case .subscription: return L("Subscriptions")
            case .cloud: return L("API keys")
            case .local: return L("Local servers")
            }
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ProviderPreset, rhs: ProviderPreset) -> Bool { lhs.id == rhs.id }
}

/// Catalog of provider presets. The built-in six come first because they are
/// the ones Melon already knows how to drive; the remaining presets only fill
/// the custom provider form, so a new endpoint works without a code change.
enum ProviderCatalog {
    static let presets: [ProviderPreset] = [
        ProviderPreset(
            id: "openrouter", title: "OpenRouter", baseURL: ModelSourcesStore.openRouterBaseURL,
            apiProtocol: .openAIChat, systemImage: "point.3.connected.trianglepath.dotted",
            tint: MTTheme.cyan, builtinRoute: .openRouter, group: .cloud
        ),
        ProviderPreset(
            id: "opencode", title: "OpenCode", baseURL: ModelSourcesStore.openCodeBaseURL,
            apiProtocol: .openAIChat, systemImage: "chevron.left.forwardslash.chevron.right",
            tint: MTTheme.cyan, builtinRoute: .openCode, group: .cloud
        ),
        ProviderPreset(
            id: "commandcode", title: "CommandCode", baseURL: ModelSourcesStore.commandCodeBaseURL,
            apiProtocol: .openAIChat, systemImage: "terminal",
            tint: MTTheme.violet, builtinRoute: .commandCode, group: .cloud
        ),
        ProviderPreset(
            id: "deepinfra", title: "DeepInfra", baseURL: ModelSourcesStore.deepInfraBaseURL,
            apiProtocol: .openAIChat, systemImage: "server.rack",
            tint: MTTheme.cyan, builtinRoute: .deepInfra, group: .cloud
        ),
        ProviderPreset(
            id: "nvidia", title: "NVIDIA", baseURL: ModelSourcesStore.nvidiaBaseURL,
            apiProtocol: .openAIChat, systemImage: "server.rack",
            tint: MTTheme.emerald, builtinRoute: .nvidia, group: .cloud
        ),
        ProviderPreset(
            id: "vercel", title: "Vercel", baseURL: ModelSourcesStore.vercelBaseURL,
            apiProtocol: .openAIChat, systemImage: "triangle",
            tint: MTTheme.cyan, builtinRoute: .vercel, group: .cloud
        ),
        ProviderPreset(
            id: "zai", title: "Z.ai", baseURL: ModelSourcesStore.zaiBaseURL,
            apiProtocol: .openAIChat, systemImage: "atom",
            tint: MTTheme.violet, builtinRoute: .zai, group: .subscription
        ),
        ProviderPreset(
            id: "claude", title: "Claude", baseURL: "https://api.anthropic.com",
            apiProtocol: .anthropic, systemImage: "sparkles",
            tint: MTTheme.amber, builtinRoute: .claude, group: .subscription
        ),
        ProviderPreset(
            id: "antigravity", title: "Antigravity", baseURL: "https://generativelanguage.googleapis.com",
            apiProtocol: .gemini, systemImage: "globe.americas",
            tint: MTTheme.emerald, builtinRoute: .antigravity, group: .subscription
        ),
        ProviderPreset(
            id: "openai", title: "OpenAI", baseURL: "https://api.openai.com/v1",
            apiProtocol: .openAIChat, systemImage: "circle.hexagongrid.fill",
            tint: MTTheme.emerald, group: .cloud
        ),
        ProviderPreset(
            id: "deepseek", title: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
            apiProtocol: .openAIChat, systemImage: "water.waves",
            tint: MTTheme.cyan, group: .cloud
        ),
        ProviderPreset(
            id: "moonshot", title: "Moonshot Kimi", baseURL: "https://api.moonshot.ai/v1",
            apiProtocol: .openAIChat, systemImage: "moon.stars.fill",
            tint: MTTheme.violet, group: .cloud
        ),
        ProviderPreset(
            id: "zhipu", title: "Zhipu GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiProtocol: .openAIChat, systemImage: "atom",
            tint: MTTheme.violet, group: .cloud
        ),
        ProviderPreset(
            id: "qwen", title: "Qwen DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiProtocol: .openAIChat, systemImage: "cloud.fill",
            tint: MTTheme.cyan, group: .cloud
        ),
        ProviderPreset(
            id: "minimax", title: "MiniMax", baseURL: "https://api.minimax.io/v1",
            apiProtocol: .openAIChat, systemImage: "square.stack.3d.up.fill",
            tint: MTTheme.gold, group: .cloud
        ),
        ProviderPreset(
            id: "groq", title: "Groq", baseURL: "https://api.groq.com/openai/v1",
            apiProtocol: .openAIChat, systemImage: "bolt.fill",
            tint: MTTheme.ruby, group: .cloud
        ),
        ProviderPreset(
            id: "together", title: "Together AI", baseURL: "https://api.together.xyz/v1",
            apiProtocol: .openAIChat, systemImage: "person.3.fill",
            tint: MTTheme.cyan, group: .cloud
        ),
        ProviderPreset(
            id: "fireworks", title: "Fireworks AI", baseURL: "https://api.fireworks.ai/inference/v1",
            apiProtocol: .openAIChat, systemImage: "sparkles",
            tint: MTTheme.gold, group: .cloud
        ),
        ProviderPreset(
            id: "cerebras", title: "Cerebras", baseURL: "https://api.cerebras.ai/v1",
            apiProtocol: .openAIChat, systemImage: "memorychip.fill",
            tint: MTTheme.violet, group: .cloud
        ),
        ProviderPreset(
            id: "xai", title: "xAI Grok", baseURL: "https://api.x.ai/v1",
            apiProtocol: .openAIChat, systemImage: "xmark.circle.fill",
            tint: MTTheme.textSecondary, group: .cloud
        ),
        ProviderPreset(
            id: "mistral", title: "Mistral", baseURL: "https://api.mistral.ai/v1",
            apiProtocol: .openAIChat, systemImage: "wind",
            tint: MTTheme.gold, group: .cloud
        ),
        ProviderPreset(
            id: "ollama", title: "Ollama", baseURL: "http://127.0.0.1:11434/v1",
            apiProtocol: .openAIChat, systemImage: "cpu.fill",
            tint: MTTheme.emerald,
            note: L("Ollama exposes an OpenAI-compatible endpoint; any key is accepted."),
            group: .local
        ),
        ProviderPreset(
            id: "lmstudio", title: "LM Studio", baseURL: "http://127.0.0.1:1234/v1",
            apiProtocol: .openAIChat, systemImage: "desktopcomputer",
            tint: MTTheme.emerald,
            note: L("Start the LM Studio server first."),
            group: .local
        ),
        ProviderPreset(
            id: "vllm", title: "vLLM", baseURL: "http://127.0.0.1:8000/v1",
            apiProtocol: .openAIChat, systemImage: "server.rack",
            tint: MTTheme.cyan,
            note: L("vLLM serves an OpenAI-compatible API by default."),
            group: .local
        ),
    ]

    static func preset(id: String) -> ProviderPreset? {
        presets.first { $0.id == id }
    }

    /// Host shown in provider rows and page subtitles.
    static func host(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

/// Sheet that adds a provider: every preset that is not connected yet, grouped
/// by kind. Built-in providers open their page; presets open the custom form.
struct ProviderPresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    let configured: Set<String>
    let onPick: (ProviderPreset) -> Void

    @State private var query = ""

    private var sections: [(group: ProviderPreset.Group, presets: [ProviderPreset])] {
        ProviderPreset.Group.allCases.compactMap { group in
            let items = ProviderCatalog.presets.filter { preset in
                preset.group == group
                    && (query.isEmpty
                        || preset.title.localizedCaseInsensitiveContains(query)
                        || preset.baseURL.localizedCaseInsensitiveContains(query))
            }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Add provider"))
                        .font(MTTheme.display(20))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(L("Pick a provider and paste its key. Built-in providers open their own page."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                Button(L("Close")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(MTTheme.mono(10, weight: .semibold))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            TextField(L("Search providers"), text: $query)
                .textFieldStyle(.mtInput)
                .font(MTTheme.mono(11))
            ScrollView {
                VStack(alignment: .leading, spacing: MTTheme.s4) {
                    ForEach(sections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: MTTheme.s2) {
                            MTCardSectionTitle(text: section.group.title)
                            MTListCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(section.presets.enumerated()), id: \.element.id) { index, preset in
                                        if index > 0 { MTRowSeparator() }
                                        row(preset)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 560, height: 560)
        .background(MTTheme.background)
    }

    private func row(_ preset: ProviderPreset) -> some View {
        let isConfigured = configured.contains(preset.id)
        return MTRow(
            title: preset.title,
            subtitle: preset.builtinRoute == nil ? preset.baseURL : preset.baseURL,
            systemImage: preset.systemImage,
            accent: preset.tint,
            isEnabled: !isConfigured,
            action: { if !isConfigured { onPick(preset) } }
        ) {
            HStack(spacing: MTTheme.s2) {
                if let note = preset.note {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(MTTheme.textTertiary)
                        .help(note)
                }
                if isConfigured {
                    MTBadge(text: L("Added"), tint: MTTheme.emerald)
                } else if preset.builtinRoute != nil {
                    MTBadge(text: L("Built in"), tint: MTTheme.gold)
                } else {
                    MTBadge(text: L("Preset"), tint: MTTheme.textTertiary)
                }
            }
        }
    }
}
