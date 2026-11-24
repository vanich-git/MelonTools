import SwiftUI

/// One AI client Melon Tools can point at its local gateway.
///
/// The catalog is data, not code: a new agent is one entry plus an adapter
/// case. Agents whose settings format is not a stable file (Cline, Windsurf
/// and friends keep them in app state) are listed honestly as manual
/// integrations: the screen shows the base URL and the env snippet, and never
/// pretends to have changed something.
struct AgentDefinition: Identifiable, Hashable {
    enum Group: String, CaseIterable, Identifiable {
        case terminal
        case editors
        case desktop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .terminal: return L("Terminal")
            case .editors: return L("Editors")
            case .desktop: return L("Desktop apps")
            }
        }
    }

    /// A setting the agent's config takes. The detail screen draws one
    /// control per field, so an adapter without a field never shows one.
    enum Field: String, Hashable, CaseIterable {
        case model
        case effort

        var title: String {
            switch self {
            case .model: return L("Model")
            case .effort: return L("Reasoning effort")
            }
        }
    }

    /// Where an installed copy is looked for. A config file alone is not
    /// proof the client runs: the user may have deleted the app and left its
    /// settings behind, and that is exactly the "CLI not found" row.
    struct Detection: Hashable {
        var binaries: [String] = []
        var bundles: [String] = []
    }

    var id: String
    var title: String
    var subtitle: String
    var systemImage: String
    var group: Group
    /// Config files this agent reads, most specific first. The first one
    /// that exists is the one the adapter edits; a missing one is created.
    var configPaths: [String]
    var integration: Integration
    var note: String
    var fields: [Field] = [.model]
    var effortOptions: [String] = []
    var detection: Detection = Detection()
    var installCommand: String?
    var restartHint: String?

    var tint: Color {
        switch group {
        case .terminal: return MTTheme.gold
        case .editors: return MTTheme.cyan
        case .desktop: return MTTheme.violet
        }
    }

    var isManaged: Bool {
        if case .manual = integration { return false }
        return true
    }

    /// The path shown in the list and on the detail card.
    var configPath: String? { configPaths.first }

    /// Absolute config URLs, with `~` expanded against the current user.
    var configURLs: [URL] {
        configPaths.map { path in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
    }

    var configURL: URL? { configURLs.first }
}

extension AgentDefinition {
    enum Integration: Hashable {
        /// `~/.codex/config.toml`, edited by `CodexConfigRoute`.
        case codex
        /// `~/.claude/settings.json` → `env.ANTHROPIC_*` and the effort.
        case claudeCode
        /// `~/.gemini/.env` → `GOOGLE_GEMINI_BASE_URL` / `GEMINI_API_KEY`.
        case geminiCLI
        /// `opencode.jsonc` or `opencode.json` → provider block.
        case openCode
        /// `~/.config/crush/crush.json` → providers block.
        case crush
        /// `~/.continue/config.json` → models array.
        case continueConfig
        /// Antigravity's own gateway block in `~/.gemini/config/config.json`
        /// (2.30 and later) and `~/.antigravity/settings.json` (before).
        case antigravity
        /// `~/.cursor/cli-config.json` → the model Cursor CLI starts on.
        case cursorCLI
        /// VS Code Chat: `settings.json` plus `chatLanguageModels.json`.
        case vscode
        /// `~/.dsh/profiles/<name>/cordis.patch.yml` → patch list entries.
        case dsh
        /// No file this app can safely edit; the screen shows the values.
        case manual(String)
    }
}

enum AgentCatalog {
    /// Every agent Magpie lists, plus the ones the gateway is commonly pointed
    /// at. Managed entries have a stable config file; the rest are manual.
    static let all: [AgentDefinition] = terminal + editors + desktop

    static func agent(id: String) -> AgentDefinition? {
        all.first { $0.id == id }
    }

    // MARK: - Terminal

    private static let terminal: [AgentDefinition] = [
        AgentDefinition(
            id: "codex",
            title: "Codex CLI",
            subtitle: L("OpenAI Codex terminal agent"),
            systemImage: "terminal",
            group: .terminal,
            configPaths: ["~/.codex/config.toml"],
            integration: .codex,
            note: L("Writes a model provider table, the default provider, the model and the reasoning effort."),
            fields: [.model, .effort],
            effortOptions: ["minimal", "low", "medium", "high"],
            detection: .init(binaries: ["codex"]),
            installCommand: "npm install -g @openai/codex",
            restartHint: L("Quit and reopen Codex to use the gateway.")
        ),
        AgentDefinition(
            id: "claude",
            title: "Claude Code",
            subtitle: L("Anthropic Claude terminal agent"),
            systemImage: "sparkles",
            group: .terminal,
            configPaths: ["~/.claude/settings.json"],
            integration: .claudeCode,
            note: L("Sets ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, the model and the effort in the settings env block."),
            fields: [.model, .effort],
            effortOptions: ["low", "medium", "high", "xhigh", "max"],
            detection: .init(binaries: ["claude"]),
            installCommand: "npm install -g @anthropic-ai/claude-code",
            restartHint: L("Start a new Claude Code session to use the gateway.")
        ),
        AgentDefinition(
            id: "gemini",
            title: "Gemini CLI",
            subtitle: L("Google Gemini terminal agent"),
            systemImage: "diamond",
            group: .terminal,
            configPaths: ["~/.gemini/.env", "~/.gemini/settings.json"],
            integration: .geminiCLI,
            note: L("Writes GOOGLE_GEMINI_BASE_URL and GEMINI_API_KEY into the env file."),
            fields: [.model],
            detection: .init(binaries: ["gemini"]),
            installCommand: "npm install -g @google/gemini-cli",
            restartHint: L("Start a new Gemini CLI session to use the gateway.")
        ),
        AgentDefinition(
            id: "opencode",
            title: "OpenCode",
            subtitle: L("Open-source terminal coding agent"),
            systemImage: "chevron.left.forwardslash.chevron.right",
            group: .terminal,
            configPaths: ["~/.config/opencode/opencode.jsonc", "~/.config/opencode/opencode.json"],
            integration: .openCode,
            note: L("Adds an OpenAI-compatible provider named Melon Tools to opencode.jsonc or opencode.json."),
            fields: [.model],
            detection: .init(binaries: ["opencode"], bundles: ["OpenCode.app"]),
            installCommand: "curl -fsSL https://opencode.ai/install | bash",
            restartHint: L("Restart OpenCode to use the gateway.")
        ),
        AgentDefinition(
            id: "crush",
            title: "Crush",
            subtitle: L("Charm terminal coding agent"),
            systemImage: "hammer",
            group: .terminal,
            configPaths: ["~/.config/crush/crush.json"],
            integration: .crush,
            note: L("Adds a Melon Tools provider to the providers block."),
            fields: [.model],
            detection: .init(binaries: ["crush"]),
            installCommand: "brew install charmbracelet/tap/crush",
            restartHint: L("Restart Crush to use the gateway.")
        ),
        AgentDefinition(
            id: "dsh",
            title: "DeepSeek Harness",
            subtitle: L("DeepSeek terminal and desktop agent"),
            systemImage: "waveform.path.ecg",
            group: .terminal,
            configPaths: [
                "~/.dsh/profiles/web/cordis.patch.yml",
                "~/.dsh/profiles/desktop/cordis.patch.yml"
            ],
            integration: .dsh,
            note: L("Adds the gateway provider and the model new sessions start on to the profile's patch list."),
            fields: [.model, .effort],
            effortOptions: ["off", "low", "high", "max"],
            detection: .init(binaries: ["dsh"], bundles: ["DeepSeek Harness.app"]),
            restartHint: L("Start a new DeepSeek Harness session to use the gateway.")
        ),
        AgentDefinition(
            id: "cursor-cli",
            title: "Cursor CLI",
            subtitle: L("Cursor's terminal agent"),
            systemImage: "cursorarrow.rays",
            group: .terminal,
            configPaths: ["~/.cursor/cli-config.json"],
            integration: .cursorCLI,
            note: L("Sets the model Cursor CLI starts on. Its endpoint stays Cursor's own, so no gateway key is written."),
            fields: [.model],
            detection: .init(binaries: ["cursor-agent"]),
            installCommand: "curl https://cursor.com/install -fsS | bash",
            restartHint: L("Restart cursor-agent to use the model.")
        ),
        AgentDefinition(
            id: "qwen",
            title: "Qwen Code",
            subtitle: L("Qwen terminal coding agent"),
            systemImage: "moon.stars",
            group: .terminal,
            configPaths: ["~/.qwen/.env"],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Qwen Code reads OpenAPI-compatible env values; set them in its shell profile.")
        ),
        AgentDefinition(
            id: "aider",
            title: "Aider",
            subtitle: L("AI pair programming in the terminal"),
            systemImage: "pencil.and.scribble",
            group: .terminal,
            configPaths: ["~/.aider.conf.yml"],
            integration: .manual("OPENAI_API_BASE"),
            note: L("Aider reads OPENAI_API_BASE and OPENAI_API_KEY from the environment.")
        ),
        AgentDefinition(
            id: "goose",
            title: "Goose",
            subtitle: L("Block local AI agent"),
            systemImage: "bird",
            group: .terminal,
            configPaths: [],
            integration: .manual("OPENAI_HOST"),
            note: L("Add a custom OpenAI provider in Goose settings with these values.")
        ),
        AgentDefinition(
            id: "amp",
            title: "Amp",
            subtitle: L("Sourcegraph terminal agent"),
            systemImage: "bolt",
            group: .terminal,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Amp reads a custom OpenAI endpoint from its environment.")
        ),
        AgentDefinition(
            id: "droid",
            title: "Droid",
            subtitle: L("Factory terminal agent"),
            systemImage: "gearshape.2",
            group: .terminal,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Configure a custom model provider in the Droid settings.")
        ),
        AgentDefinition(
            id: "openhands",
            title: "OpenHands",
            subtitle: L("Open-source software agent"),
            systemImage: "hand.raised",
            group: .terminal,
            configPaths: [],
            integration: .manual("LLM_BASE_URL"),
            note: L("Set the LLM base URL in the OpenHands runtime settings.")
        )
    ]

    // MARK: - Editors

    private static let editors: [AgentDefinition] = [
        AgentDefinition(
            id: "vscode",
            title: "VS Code",
            subtitle: L("GitHub Copilot Chat with a custom endpoint"),
            systemImage: "square.split.2x1",
            group: .editors,
            configPaths: [
                "~/Library/Application Support/Code/User/settings.json",
                "~/Library/Application Support/Code/User/chatLanguageModels.json"
            ],
            integration: .vscode,
            note: L("Adds a Melon Tools Custom Endpoint group to chatLanguageModels.json and points chat.defaultModel at it."),
            fields: [.model],
            detection: .init(binaries: ["code"], bundles: ["Visual Studio Code.app"]),
            installCommand: "brew install --cask visual-studio-code",
            restartHint: L("Reload the VS Code window to use the gateway.")
        ),
        AgentDefinition(
            id: "continue",
            title: "Continue",
            subtitle: L("Open-source IDE assistant"),
            systemImage: "arrow.uturn.forward",
            group: .editors,
            configPaths: ["~/.continue/config.json"],
            integration: .continueConfig,
            note: L("Adds a Melon Tools model to the models list."),
            fields: [.model],
            restartHint: L("Reload the editor window to use the gateway.")
        ),
        AgentDefinition(
            id: "zed",
            title: "Zed",
            subtitle: L("Native collaborative editor"),
            systemImage: "square.split.2x1",
            group: .editors,
            configPaths: [],
            integration: .manual("language_models.openai_compatible"),
            note: L("Add an OpenAI-compatible provider in Zed settings.")
        ),
        AgentDefinition(
            id: "cursor",
            title: "Cursor",
            subtitle: L("AI-first code editor"),
            systemImage: "cursorarrow.rays",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Cursor keeps providers in app state; use its custom API base setting.")
        ),
        AgentDefinition(
            id: "windsurf",
            title: "Windsurf",
            subtitle: L("Codeium editor"),
            systemImage: "wind",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Windsurf keeps providers in app state; use its custom endpoint setting.")
        ),
        AgentDefinition(
            id: "cline",
            title: "Cline",
            subtitle: L("VS Code autonomous agent"),
            systemImage: "wand.and.stars",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Cline stores settings in VS Code state; pick OpenAI Compatible and paste the values.")
        ),
        AgentDefinition(
            id: "roo",
            title: "Roo Code",
            subtitle: L("VS Code coding agent"),
            systemImage: "kangaroo",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Roo Code stores settings in VS Code state; pick OpenAI Compatible and paste the values.")
        ),
        AgentDefinition(
            id: "kilo",
            title: "Kilo Code",
            subtitle: L("VS Code coding agent"),
            systemImage: "k.circle",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Kilo Code stores settings in VS Code state; pick OpenAI Compatible and paste the values.")
        ),
        AgentDefinition(
            id: "copilot",
            title: "GitHub Copilot",
            subtitle: L("VS Code assistant"),
            systemImage: "checkmark.seal",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Copilot does not accept a custom base URL; use a local model on the gateway instead.")
        ),
        AgentDefinition(
            id: "jetbrains",
            title: "JetBrains AI",
            subtitle: L("JetBrains IDE assistant"),
            systemImage: "curlybraces",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("JetBrains AI keeps providers in app state; use its OpenAI-compatible provider.")
        ),
        AgentDefinition(
            id: "void",
            title: "Void",
            subtitle: L("Open-source AI editor"),
            systemImage: "circle.dashed",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Void keeps providers in app state; use its OpenAI-compatible provider.")
        ),
        AgentDefinition(
            id: "trae",
            title: "Trae",
            subtitle: L("ByteDance AI IDE"),
            systemImage: "square.stack",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Trae keeps providers in app state; use its custom model provider.")
        ),
        AgentDefinition(
            id: "kiro",
            title: "Kiro",
            subtitle: L("AWS spec-driven agent IDE"),
            systemImage: "list.bullet.rectangle",
            group: .editors,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Kiro keeps providers in app state; use its custom model provider.")
        )
    ]

    // MARK: - Desktop

    private static let desktop: [AgentDefinition] = [
        AgentDefinition(
            id: "antigravity",
            title: "Antigravity",
            subtitle: L("Google's desktop coding agent"),
            systemImage: "paperplane",
            group: .desktop,
            configPaths: [
                "~/.gemini/config/config.json",
                "~/.antigravity/settings.json"
            ],
            integration: .antigravity,
            note: L("Turns on Antigravity's own gateway: it reads models from Melon Tools and starts on the model picked here."),
            fields: [.model],
            detection: .init(bundles: ["Antigravity.app"]),
            restartHint: L("Restart Antigravity to use the gateway.")
        ),
        AgentDefinition(
            id: "openwebui",
            title: "Open WebUI",
            subtitle: L("Self-hosted chat interface"),
            systemImage: "bubble.left.and.bubble.right",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_API_BASE_URL"),
            note: L("Add an OpenAI connection with this base URL and key.")
        ),
        AgentDefinition(
            id: "librechat",
            title: "LibreChat",
            subtitle: L("Open-source chat platform"),
            systemImage: "text.bubble",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_REVERSE_PROXY"),
            note: L("Point the custom endpoint in librechat.yaml at the gateway.")
        ),
        AgentDefinition(
            id: "cherry",
            title: "Cherry Studio",
            subtitle: L("Desktop AI client"),
            systemImage: "circle.grid.2x2",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Add an OpenAI-compatible provider in Cherry Studio settings.")
        ),
        AgentDefinition(
            id: "chatbox",
            title: "Chatbox",
            subtitle: L("Desktop chat client"),
            systemImage: "message",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("Add an OpenAI API compatible model in Chatbox settings.")
        ),
        AgentDefinition(
            id: "lobe",
            title: "LobeChat",
            subtitle: L("Open-source chat UI"),
            systemImage: "brain",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_PROXY_URL"),
            note: L("Set OPENAI_PROXY_URL and OPENAI_API_KEY for the container.")
        ),
        AgentDefinition(
            id: "chatgpt",
            title: "ChatGPT desktop",
            subtitle: L("OpenAI desktop app"),
            systemImage: "desktopcomputer",
            group: .desktop,
            configPaths: [],
            integration: .manual("OPENAI_BASE_URL"),
            note: L("The ChatGPT app does not accept a custom endpoint; use the Codex route instead.")
        )
    ]
}
