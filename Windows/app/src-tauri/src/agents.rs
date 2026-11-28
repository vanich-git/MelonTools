//! Agents: point installed AI clients at the local gateway.
//!
//! Every managed agent owns one or more config files. Applying rewrites only
//! the keys the client needs, keeps a backup of the previous text and records
//! what was written so revert can restore it. Manual entries never touch a
//! file: the UI shows the base URL and the environment snippet instead of
//! pretending.
//!
//! Files touched: `agents.json` (state), `agent-backups/` (backups), and the
//! client configs the user connected. All of them live under `%APPDATA%`.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::paths;
use crate::settings;

// MARK: - State model

#[derive(Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct CustomAgent {
    pub id: String,
    pub title: String,
    pub config_path: String,
    /// `json` or `env`.
    pub format: String,
    pub base_url_key: String,
    pub api_key_key: String,
    pub model_key: String,
    pub note: String,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AppliedFile {
    pub path: String,
    pub backup_path: Option<String>,
    pub created: bool,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Application {
    pub agent_id: String,
    pub applied_at: String,
    pub config_path: String,
    pub backup_path: Option<String>,
    pub created_file: bool,
    pub model: String,
    #[serde(default)]
    pub effort: String,
    #[serde(default)]
    pub content_hash: Option<String>,
    #[serde(default)]
    pub files: Vec<AppliedFile>,
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct State {
    applications: BTreeMap<String, Application>,
    custom_agents: Vec<CustomAgent>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AgentInfo {
    pub id: String,
    pub title: String,
    pub subtitle_key: String,
    pub group: String,
    pub config_path: Option<String>,
    pub config_paths: Vec<String>,
    pub config_states: Vec<Value>,
    pub managed: bool,
    pub manual_key: Option<String>,
    pub note_key: String,
    pub status: String,
    pub custom: bool,
    pub installed: bool,
    pub drift: bool,
    pub effort_options: Vec<String>,
    pub restart_hint: Option<String>,
    pub install_command: Option<String>,
    pub applied: Option<Application>,
}

// MARK: - Catalog

struct Definition {
    id: &'static str,
    title: &'static str,
    subtitle_key: &'static str,
    group: &'static str,
    /// Every path the adapter may write; the first one is the default.
    configs: &'static [&'static str],
    /// Adapter id, or the environment key for manual entries.
    adapter: &'static str,
    manual: bool,
    note_key: &'static str,
    /// Command-line programs that prove the client is installed.
    binaries: &'static [&'static str],
    /// App executables, with `%VARS%` expanded at check time.
    apps: &'static [&'static str],
    effort_options: &'static [&'static str],
}

const CATALOG: &[Definition] = &[
    Definition {
        id: "codex",
        title: "Codex CLI",
        subtitle_key: "agentCodexSub",
        group: "terminal",
        configs: &["~/.codex/config.toml"],
        adapter: "codex",
        manual: false,
        note_key: "agentCodexNote",
        binaries: &["codex"],
        apps: &[],
        effort_options: &["minimal", "low", "medium", "high"],
    },
    Definition {
        id: "claude",
        title: "Claude Code",
        subtitle_key: "agentClaudeSub",
        group: "terminal",
        configs: &["~/.claude/settings.json"],
        adapter: "claude",
        manual: false,
        note_key: "agentClaudeNote",
        binaries: &["claude"],
        apps: &[],
        effort_options: &["low", "medium", "high", "xhigh", "max"],
    },
    Definition {
        id: "gemini",
        title: "Gemini CLI",
        subtitle_key: "agentGeminiSub",
        group: "terminal",
        configs: &["~/.gemini/.env", "~/.gemini/settings.json"],
        adapter: "gemini",
        manual: false,
        note_key: "agentGeminiNote",
        binaries: &["gemini"],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "opencode",
        title: "OpenCode",
        subtitle_key: "agentOpencodeSub",
        group: "terminal",
        configs: &[
            "~/.config/opencode/opencode.jsonc",
            "~/.config/opencode/opencode.json",
        ],
        adapter: "opencode",
        manual: false,
        note_key: "agentOpencodeNote",
        binaries: &["opencode"],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "crush",
        title: "Crush",
        subtitle_key: "agentCrushSub",
        group: "terminal",
        configs: &["~/.config/crush/crush.json"],
        adapter: "crush",
        manual: false,
        note_key: "agentCrushNote",
        binaries: &["crush"],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "dsh",
        title: "DeepSeek Harness",
        subtitle_key: "agentDshSub",
        group: "terminal",
        configs: &[
            "~/.dsh/profiles/web/cordis.patch.yml",
            "~/.dsh/profiles/desktop/cordis.patch.yml",
        ],
        adapter: "dsh",
        manual: false,
        note_key: "agentDshNote",
        binaries: &["dsh"],
        apps: &["%LOCALAPPDATA%/Programs/DeepSeek Harness/DeepSeek Harness.exe"],
        effort_options: &["off", "low", "high", "max"],
    },
    Definition {
        id: "cursor-cli",
        title: "Cursor CLI",
        subtitle_key: "agentCursorCliSub",
        group: "terminal",
        configs: &["~/.cursor/cli-config.json"],
        adapter: "cursor-cli",
        manual: false,
        note_key: "agentCursorCliNote",
        binaries: &["cursor-agent"],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "qwen",
        title: "Qwen Code",
        subtitle_key: "agentQwenSub",
        group: "terminal",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentQwenNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "aider",
        title: "Aider",
        subtitle_key: "agentAiderSub",
        group: "terminal",
        configs: &[],
        adapter: "OPENAI_API_BASE",
        manual: true,
        note_key: "agentAiderNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "goose",
        title: "Goose",
        subtitle_key: "agentGooseSub",
        group: "terminal",
        configs: &[],
        adapter: "OPENAI_HOST",
        manual: true,
        note_key: "agentGooseNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "amp",
        title: "Amp",
        subtitle_key: "agentAmpSub",
        group: "terminal",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentAmpNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "droid",
        title: "Droid",
        subtitle_key: "agentDroidSub",
        group: "terminal",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentDroidNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "openhands",
        title: "OpenHands",
        subtitle_key: "agentOpenhandsSub",
        group: "terminal",
        configs: &[],
        adapter: "LLM_BASE_URL",
        manual: true,
        note_key: "agentOpenhandsNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "vscode",
        title: "VS Code",
        subtitle_key: "agentVscodeSub",
        group: "editors",
        configs: &[
            "~/AppData/Roaming/Code/User/settings.json",
            "~/AppData/Roaming/Code/User/chatLanguageModels.json",
        ],
        adapter: "vscode",
        manual: false,
        note_key: "agentVscodeNote",
        binaries: &["code"],
        apps: &[
            "%LOCALAPPDATA%/Programs/Microsoft VS Code/Code.exe",
            "%PROGRAMFILES%/Microsoft VS Code/Code.exe",
        ],
        effort_options: &[],
    },
    Definition {
        id: "continue",
        title: "Continue",
        subtitle_key: "agentContinueSub",
        group: "editors",
        configs: &["~/.continue/config.json"],
        adapter: "continue",
        manual: false,
        note_key: "agentContinueNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "zed",
        title: "Zed",
        subtitle_key: "agentZedSub",
        group: "editors",
        configs: &[],
        adapter: "language_models.openai_compatible",
        manual: true,
        note_key: "agentZedNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "cursor",
        title: "Cursor",
        subtitle_key: "agentCursorSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentCursorNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "windsurf",
        title: "Windsurf",
        subtitle_key: "agentWindsurfSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentWindsurfNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "cline",
        title: "Cline",
        subtitle_key: "agentClineSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentClineNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "roo",
        title: "Roo Code",
        subtitle_key: "agentRooSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentRooNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "kilo",
        title: "Kilo Code",
        subtitle_key: "agentKiloSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentKiloNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "copilot",
        title: "GitHub Copilot",
        subtitle_key: "agentCopilotSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentCopilotNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "jetbrains",
        title: "JetBrains AI",
        subtitle_key: "agentJetbrainsSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentJetbrainsNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "void",
        title: "Void",
        subtitle_key: "agentVoidSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentVoidNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "trae",
        title: "Trae",
        subtitle_key: "agentTraeSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentTraeNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "kiro",
        title: "Kiro",
        subtitle_key: "agentKiroSub",
        group: "editors",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentKiroNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "antigravity",
        title: "Antigravity",
        subtitle_key: "agentAntigravitySub",
        group: "desktop",
        configs: &[
            "~/.gemini/config/config.json",
            "~/.antigravity/settings.json",
        ],
        adapter: "antigravity",
        manual: false,
        note_key: "agentAntigravityNote",
        binaries: &[],
        apps: &[
            "%LOCALAPPDATA%/Programs/Antigravity/Antigravity.exe",
            "%PROGRAMFILES%/Antigravity/Antigravity.exe",
        ],
        effort_options: &[],
    },
    Definition {
        id: "openwebui",
        title: "Open WebUI",
        subtitle_key: "agentOpenwebuiSub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_API_BASE_URL",
        manual: true,
        note_key: "agentOpenwebuiNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "librechat",
        title: "LibreChat",
        subtitle_key: "agentLibrechatSub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_REVERSE_PROXY",
        manual: true,
        note_key: "agentLibrechatNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "cherry",
        title: "Cherry Studio",
        subtitle_key: "agentCherrySub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentCherryNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "chatbox",
        title: "Chatbox",
        subtitle_key: "agentChatboxSub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentChatboxNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "lobe",
        title: "LobeChat",
        subtitle_key: "agentLobeSub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_PROXY_URL",
        manual: true,
        note_key: "agentLobeNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
    Definition {
        id: "chatgpt",
        title: "ChatGPT desktop",
        subtitle_key: "agentChatgptSub",
        group: "desktop",
        configs: &[],
        adapter: "OPENAI_BASE_URL",
        manual: true,
        note_key: "agentChatgptNote",
        binaries: &[],
        apps: &[],
        effort_options: &[],
    },
];

// MARK: - Paths

fn state_path() -> PathBuf {
    paths::appdata_dir().join("agents.json")
}

fn backup_dir() -> PathBuf {
    paths::appdata_dir().join("agent-backups")
}

fn profile_dir() -> String {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default()
}

/// Expands `%VAR%` and a leading `~`. The UI stores paths in the POSIX form
/// macOS uses, so both separators have to work.
fn expand_env(raw: &str) -> String {
    let mut text = raw.trim().to_string();
    for _ in 0..8 {
        let Some(start) = text.find('%') else { break };
        let Some(end) = text[start + 1..].find('%').map(|index| start + 1 + index) else {
            break;
        };
        let name = &text[start + 1..end];
        let value = std::env::var(name).unwrap_or_default();
        text.replace_range(start..=end, &value);
    }
    if let Some(rest) = text.strip_prefix("~/") {
        return PathBuf::from(profile_dir())
            .join(rest.replace('/', "\\"))
            .to_string_lossy()
            .to_string();
    }
    if let Some(rest) = text.strip_prefix("~\\") {
        return PathBuf::from(profile_dir())
            .join(rest)
            .to_string_lossy()
            .to_string();
    }
    text.replace('/', "\\")
}

pub fn expand_home(raw: &str) -> PathBuf {
    PathBuf::from(expand_env(raw))
}

fn load_state() -> State {
    std::fs::read_to_string(state_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_state(state: &State) -> Result<(), String> {
    let path = state_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let text = serde_json::to_string_pretty(state).map_err(|error| error.to_string())?;
    std::fs::write(&path, text).map_err(|error| error.to_string())
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

// MARK: - Detection

fn binary_found(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    let extensions: Vec<String> = std::env::var("PATHEXT")
        .unwrap_or_else(|_| ".EXE;.CMD;.BAT;.COM".to_string())
        .split(';')
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .collect();
    let path = std::env::var("PATH").unwrap_or_default();
    for folder in path.split(';').filter(|folder| !folder.trim().is_empty()) {
        let base = Path::new(folder).join(name);
        if base.is_file() {
            return true;
        }
        for extension in &extensions {
            if base
                .with_extension(extension.trim_start_matches('.'))
                .is_file()
            {
                return true;
            }
        }
    }
    false
}

fn installed(definition: &Definition) -> bool {
    definition.binaries.iter().any(|name| binary_found(name))
        || definition
            .apps
            .iter()
            .any(|path| expand_home(path).is_file())
}

/// OpenCode moved its config and lets users point `OPENCODE_CONFIG_DIR`
/// somewhere else. The override wins over the default pair.
fn configured_paths(definition: &Definition) -> Vec<String> {
    if definition.adapter == "opencode" {
        if let Ok(dir) = std::env::var("OPENCODE_CONFIG_DIR") {
            if !dir.trim().is_empty() {
                let base = dir.trim().trim_end_matches(['/', '\\']);
                return vec![
                    format!("{base}/opencode.jsonc"),
                    format!("{base}/opencode.json"),
                ];
            }
        }
    }
    definition
        .configs
        .iter()
        .map(|path| path.to_string())
        .collect()
}

fn config_exists(definition: &Definition) -> bool {
    configured_paths(definition)
        .iter()
        .any(|raw| expand_home(raw).is_file())
}

fn cli_missing(definition: &Definition, has_config: bool) -> bool {
    if !has_config || definition.manual {
        return false;
    }
    let has_detection = !definition.binaries.is_empty() || !definition.apps.is_empty();
    has_detection && !installed(definition)
}

fn content_hash(files: &[(String, String)]) -> String {
    let mut sorted = files.to_vec();
    sorted.sort_by(|left, right| left.0.cmp(&right.0));
    let joined = sorted
        .iter()
        .map(|(path, text)| format!("{path}\u{0}{text}"))
        .collect::<Vec<_>>()
        .join("\u{0}");
    let digest = Sha256::digest(joined.as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn drift(application: &Application) -> bool {
    let Some(expected) = application.content_hash.as_deref() else {
        return false;
    };
    let files = applied_files(application);
    if files.is_empty() {
        return false;
    }
    let mut texts = Vec::new();
    for file in files {
        let path = expand_home(&file.path);
        let Ok(text) = std::fs::read_to_string(&path) else {
            return true;
        };
        texts.push((path.to_string_lossy().to_string(), text));
    }
    content_hash(&texts) != expected
}

fn applied_files(application: &Application) -> Vec<AppliedFile> {
    if !application.files.is_empty() {
        return application.files.clone();
    }
    vec![AppliedFile {
        path: application.config_path.clone(),
        backup_path: application.backup_path.clone(),
        created: application.created_file,
    }]
}

// MARK: - Snapshot

/// The client reads its config at launch, so a fresh write needs a restart
/// or a new session before it takes effect. Keys stay in the UI dictionary.
fn restart_key(id: &str) -> Option<&'static str> {
    match id {
        "codex" => Some("agentRestartCodex"),
        "claude" => Some("agentRestartClaude"),
        "gemini" => Some("agentRestartGemini"),
        "opencode" => Some("agentRestartOpencode"),
        "crush" => Some("agentRestartCrush"),
        "dsh" => Some("agentRestartDsh"),
        "cursor-cli" => Some("agentRestartCursorCli"),
        "vscode" => Some("agentRestartVscode"),
        "continue" => Some("agentRestartContinue"),
        "antigravity" => Some("agentRestartAntigravity"),
        _ => None,
    }
}

/// Commands the UI offers for a client that is not installed. Only commands
/// that exist on Windows are listed; macOS-only curl installers stay out.
fn install_command(id: &str) -> Option<&'static str> {
    match id {
        "codex" => Some("npm install -g @openai/codex"),
        "claude" => Some("npm install -g @anthropic-ai/claude-code"),
        "gemini" => Some("npm install -g @google/gemini-cli"),
        "opencode" => Some("npm install -g opencode-ai"),
        "crush" => Some("go install github.com/charmbracelet/crush@latest"),
        "vscode" => Some("winget install --id Microsoft.VisualStudioCode"),
        _ => None,
    }
}

fn custom_info(agent: &CustomAgent, applied: Option<&Application>) -> AgentInfo {
    let path = expand_home(&agent.config_path);
    let status = if applied.is_some() {
        "connected"
    } else if path.exists() {
        "ready"
    } else {
        "notDetected"
    };
    let applied = applied.cloned();
    AgentInfo {
        id: agent.id.clone(),
        title: agent.title.clone(),
        subtitle_key: "agentCustomSub".to_string(),
        group: "custom".to_string(),
        config_path: Some(agent.config_path.clone()),
        config_paths: vec![agent.config_path.clone()],
        config_states: vec![
            json!({ "path": agent.config_path, "expanded": path.to_string_lossy(), "exists": path.exists() }),
        ],
        managed: !agent.config_path.trim().is_empty(),
        manual_key: None,
        note_key: "agentCustomNote".to_string(),
        status: status.to_string(),
        custom: true,
        installed: path.exists(),
        drift: applied.as_ref().map(drift).unwrap_or(false),
        effort_options: Vec::new(),
        restart_hint: None,
        install_command: None,
        applied,
    }
}

fn catalog_info(definition: &Definition, state: &State) -> AgentInfo {
    let applied = state.applications.get(definition.id).cloned();
    let has_config = config_exists(definition);
    let is_installed = installed(definition);
    let status = if applied.is_some() {
        if cli_missing(definition, has_config) {
            "cliMissing"
        } else {
            "connected"
        }
    } else if definition.manual {
        "manual"
    } else if has_config {
        if cli_missing(definition, true) {
            "cliMissing"
        } else {
            "ready"
        }
    } else if is_installed {
        "ready"
    } else {
        "notDetected"
    };
    let config_states: Vec<Value> = configured_paths(definition)
        .iter()
        .map(|raw| {
            let path = expand_home(raw);
            json!({ "path": raw, "expanded": path.to_string_lossy(), "exists": path.exists() })
        })
        .collect();
    AgentInfo {
        id: definition.id.to_string(),
        title: definition.title.to_string(),
        subtitle_key: definition.subtitle_key.to_string(),
        group: definition.group.to_string(),
        config_path: configured_paths(definition).first().cloned(),
        config_paths: configured_paths(definition),
        config_states,
        managed: !definition.manual,
        manual_key: if definition.manual {
            Some(definition.adapter.to_string())
        } else {
            None
        },
        note_key: definition.note_key.to_string(),
        status: status.to_string(),
        custom: false,
        installed: is_installed,
        drift: applied.as_ref().map(drift).unwrap_or(false),
        effort_options: definition
            .effort_options
            .iter()
            .map(|value| value.to_string())
            .collect(),
        restart_hint: restart_key(definition.id).map(str::to_string),
        install_command: install_command(definition.id).map(str::to_string),
        applied,
    }
}

/// The whole screen state: catalog, custom agents, backups and the base URL
/// the app would write right now.
pub fn snapshot() -> Value {
    let state = load_state();
    let settings = settings::load();
    let base_url = base_url(&settings);
    let mut agents: Vec<AgentInfo> = CATALOG
        .iter()
        .map(|definition| catalog_info(definition, &state))
        .collect();
    for custom in &state.custom_agents {
        let applied = state.applications.get(&custom.id);
        agents.push(custom_info(custom, applied));
    }
    let mut backups: Vec<Value> = Vec::new();
    for application in state.applications.values() {
        for file in applied_files(application) {
            if let Some(path) = file.backup_path {
                backups.push(json!({
                    "agentId": application.agent_id,
                    "path": path,
                    "target": file.path,
                    "appliedAt": application.applied_at,
                }));
            }
        }
    }
    json!({
        "agents": agents,
        "applications": state.applications,
        "customAgents": state.custom_agents,
        "backups": backups,
        "baseUrl": base_url,
        "apiKey": settings.api_key,
        "backupDirectory": backup_dir().to_string_lossy(),
    })
}

fn base_url(settings: &settings::Settings) -> String {
    format!("http://127.0.0.1:{}/v1", settings.port)
}

// MARK: - Apply

#[derive(Clone)]
struct Context {
    base_url: String,
    api_key: String,
    model: String,
    effort: String,
}

/// Small helpers shared by the JSON adapters.
fn object_mut<'a>(root: &'a mut Map<String, Value>, key: &str) -> &'a mut Map<String, Value> {
    if !root.get(key).map(Value::is_object).unwrap_or(false) {
        root.insert(key.to_string(), json!({}));
    }
    root.get_mut(key)
        .and_then(Value::as_object_mut)
        .expect("object inserted above")
}

fn set_dotted(root: &mut Map<String, Value>, path: &str, value: &str) {
    let parts: Vec<&str> = path.split('.').filter(|part| !part.is_empty()).collect();
    if parts.is_empty() {
        return;
    }
    let mut cursor = root;
    for part in &parts[..parts.len() - 1] {
        cursor = object_mut(cursor, part);
    }
    cursor.insert(
        parts[parts.len() - 1].to_string(),
        Value::String(value.to_string()),
    );
}

/// Strips `//` and `/* */` comments and trailing commas. VS Code and OpenCode
/// write JSONC; their files must parse without dropping the user's settings.
fn strip_jsonc(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    let mut in_string = false;
    let mut escaped = false;
    while index < chars.len() {
        let character = chars[index];
        if in_string {
            out.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            out.push(character);
            index += 1;
            continue;
        }
        if character == '/' && index + 1 < chars.len() {
            if chars[index + 1] == '/' {
                index += 2;
                while index < chars.len() && chars[index] != '\n' {
                    index += 1;
                }
                continue;
            }
            if chars[index + 1] == '*' {
                index += 2;
                while index + 1 < chars.len() && !(chars[index] == '*' && chars[index + 1] == '/') {
                    index += 1;
                }
                index = (index + 2).min(chars.len());
                continue;
            }
        }
        out.push(character);
        index += 1;
    }

    let chars: Vec<char> = out.chars().collect();
    let mut cleaned = String::with_capacity(chars.len());
    let mut in_string = false;
    let mut escaped = false;
    let mut index = 0;
    while index < chars.len() {
        let character = chars[index];
        if in_string {
            cleaned.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            cleaned.push(character);
            index += 1;
            continue;
        }
        if character == ',' {
            let mut next = index + 1;
            while next < chars.len() && chars[next].is_whitespace() {
                next += 1;
            }
            if next < chars.len() && (chars[next] == '}' || chars[next] == ']') {
                index += 1;
                continue;
            }
        }
        cleaned.push(character);
        index += 1;
    }
    cleaned
}

fn parse_json_value(text: &str, path: &Path) -> Result<Value, String> {
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str::<Value>(&strip_jsonc(text))
        .map_err(|error| format!("{} is not valid JSON: {error}", path.display()))
}

fn parse_json(text: &str, path: &Path) -> Result<Map<String, Value>, String> {
    match parse_json_value(text, path)? {
        Value::Object(map) => Ok(map),
        _ => Err(format!("{}: expected a JSON object.", path.display())),
    }
}

fn parse_json_array(text: &str, path: &Path) -> Result<Vec<Value>, String> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    match parse_json_value(text, path)? {
        Value::Array(list) => Ok(list),
        _ => Err(format!("{}: expected a JSON array.", path.display())),
    }
}

fn render_json(map: &Map<String, Value>) -> String {
    let mut text = serde_json::to_string_pretty(&Value::Object(map.clone()))
        .unwrap_or_else(|_| "{}".to_string());
    text.push('\n');
    text
}

fn render_json_value(value: &Value) -> String {
    let mut text = serde_json::to_string_pretty(value).unwrap_or_else(|_| "[]".to_string());
    text.push('\n');
    text
}

fn upsert_env(text: &str, key: &str, value: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut replaced = false;
    for line in text.lines() {
        let trimmed = line.trim_start();
        let matches = trimmed
            .strip_prefix(key)
            .map(|rest| rest.trim_start().starts_with('='))
            .unwrap_or(false);
        if matches {
            lines.push(format!("{key}={value}"));
            replaced = true;
        } else {
            lines.push(line.to_string());
        }
    }
    if !replaced {
        lines.push(format!("{key}={value}"));
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// Codex keeps a TOML file. The shared `codex_route` module owns the route
/// and top-level keys, so the app has one writer for the same file.
fn apply_codex(text: &str, context: &Context) -> Result<String, String> {
    if context.model.trim().is_empty() {
        return Err("emptyModel".to_string());
    }
    let mut out = crate::codex_route::upsert_route(text, &context.base_url, &context.api_key);
    out = crate::codex_route::upsert_top_level_key(&out, "model", context.model.trim());
    if !context.effort.trim().is_empty() {
        out = crate::codex_route::upsert_top_level_key(
            &out,
            "model_reasoning_effort",
            context.effort.trim(),
        );
    }
    Ok(out)
}

fn apply_vscode_settings(text: &str, path: &Path, context: &Context) -> Result<String, String> {
    require_model(context)?;
    let mut root = parse_json(text, path)?;
    root.insert("chat.defaultModel".to_string(), json!(context.model.trim()));
    Ok(render_json(&root))
}

fn apply_vscode_catalog(text: &str, path: &Path, context: &Context) -> Result<String, String> {
    require_model(context)?;
    let mut list = parse_json_array(text, path)?;
    let entry = json!({
        "id": context.model.trim(),
        "name": context.model.trim(),
        "url": format!("{}/chat/completions", context.base_url),
        "toolCalling": true,
        "requestHeaders": { "Authorization": format!("Bearer {}", context.api_key) },
    });
    let group = json!({
        "name": "Melon Tools",
        "vendor": "customendpoint",
        "apiType": "chat-completions",
        "models": [entry],
    });
    if let Some(index) = list.iter().position(|item| {
        item.get("name").and_then(Value::as_str) == Some("Melon Tools")
            && item.get("vendor").and_then(Value::as_str) == Some("customendpoint")
    }) {
        list[index] = group;
    } else {
        list.push(group);
    }
    Ok(render_json_value(&Value::Array(list)))
}

fn apply_antigravity(text: &str, path: &Path, context: &Context) -> Result<String, String> {
    require_model(context)?;
    let mut root = parse_json(text, path)?;
    root.insert(
        "gateway".to_string(),
        json!({
            "enabled": true,
            "url": context.base_url,
            "apiKey": context.api_key,
            "wireProtocol": "openai",
        }),
    );
    let models = object_mut(&mut root, "models");
    models.insert("defaultModelId".to_string(), json!(context.model.trim()));
    models.insert(
        "listSource".to_string(),
        json!(format!("{}/models?format=antigravity", context.base_url)),
    );
    Ok(render_json(&root))
}

fn apply_cursor_cli(text: &str, path: &Path, context: &Context) -> Result<String, String> {
    require_model(context)?;
    let mut root = parse_json(text, path)?;
    let model = object_mut(&mut root, "model");
    model.insert("modelId".to_string(), json!(context.model.trim()));
    model.insert("displayModelId".to_string(), json!(context.model.trim()));
    model.insert("displayName".to_string(), json!(context.model.trim()));
    root.insert("hasChangedDefaultModel".to_string(), json!(true));
    Ok(render_json(&root))
}

fn yaml_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn removing_marked_block(lines: &[String], id: &str) -> Vec<String> {
    let marker = format!("- id: {id} # melon-tools");
    let Some(start) = lines.iter().position(|line| line == &marker) else {
        return lines.to_vec();
    };
    let mut end = start + 1;
    while end < lines.len() && !lines[end].starts_with("- ") {
        end += 1;
    }
    let mut copy = lines.to_vec();
    copy.drain(start..end);
    copy
}

fn apply_dsh(text: &str, context: &Context) -> String {
    let mut lines: Vec<String> = if text.is_empty() {
        Vec::new()
    } else {
        text.lines().map(str::to_string).collect()
    };
    while lines.last().map(|line| line.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines = removing_marked_block(&lines, "llm-deepseek");
    lines = removing_marked_block(&lines, "agent-default-model");
    let level = if context.effort.trim().is_empty() {
        "high"
    } else {
        context.effort.trim()
    };
    let block = vec![
        "- id: llm-deepseek # melon-tools".to_string(),
        "  config:".to_string(),
        format!("    apiKey: {}", yaml_quote(&context.api_key)),
        format!("    baseURL: {}", yaml_quote(&context.base_url)),
        "    thinking: enabled".to_string(),
        format!("    reasoningEffort: {}", yaml_quote(level)),
        "    models:".to_string(),
        format!("      - id: {}", yaml_quote(context.model.trim())),
        format!("        name: {}", yaml_quote(context.model.trim())),
        "- id: agent-default-model # melon-tools".to_string(),
        "  config:".to_string(),
        "    provider: deepseek-official".to_string(),
        format!("    model: {}", yaml_quote(context.model.trim())),
    ];
    if !lines.is_empty() && lines.last().map(|line| !line.is_empty()).unwrap_or(false) {
        lines.push(String::new());
    }
    lines.extend(block);
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn apply_json_agent(
    adapter: &str,
    text: &str,
    path: &Path,
    context: &Context,
) -> Result<String, String> {
    let mut root = parse_json(text, path)?;
    match adapter {
        "claude" => {
            require_model(context)?;
            let env = object_mut(&mut root, "env");
            // The Anthropic SDK appends `/v1/messages` itself, so the stored
            // root must not keep the OpenAI-compatible `/v1` suffix.
            env.insert(
                "ANTHROPIC_BASE_URL".to_string(),
                json!(anthropic_base(&context.base_url)),
            );
            env.insert("ANTHROPIC_AUTH_TOKEN".to_string(), json!(context.api_key));
            env.insert("ANTHROPIC_MODEL".to_string(), json!(context.model.trim()));
            if context.effort.trim().is_empty() {
                env.remove("CLAUDE_CODE_EFFORT_LEVEL");
            } else {
                env.insert(
                    "CLAUDE_CODE_EFFORT_LEVEL".to_string(),
                    json!(context.effort.trim()),
                );
            }
        }
        "opencode" => {
            require_model(context)?;
            let providers = object_mut(&mut root, "provider");
            let mut models = Map::new();
            models.insert(
                context.model.trim().to_string(),
                json!({ "name": context.model.trim() }),
            );
            providers.insert(
                "melon".to_string(),
                json!({
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Melon Tools",
                    "options": { "baseURL": context.base_url, "apiKey": context.api_key },
                    "models": models,
                }),
            );
            root.insert(
                "model".to_string(),
                json!(format!("melon/{}", context.model.trim())),
            );
        }
        "crush" => {
            require_model(context)?;
            let providers = object_mut(&mut root, "providers");
            providers.insert(
                "melon".to_string(),
                json!({
                    "type": "openai",
                    "base_url": context.base_url,
                    "api_key": context.api_key,
                    "models": [{ "id": context.model.trim(), "name": context.model.trim() }],
                }),
            );
        }
        "continue" => {
            require_model(context)?;
            let entry = json!({
                "title": "Melon Tools",
                "provider": "openai",
                "model": context.model.trim(),
                "apiBase": context.base_url,
                "apiKey": context.api_key,
            });
            let models = root
                .entry("models".to_string())
                .or_insert_with(|| json!([]));
            let list = models
                .as_array_mut()
                .ok_or_else(|| "continue: models is not an array".to_string())?;
            if let Some(index) = list
                .iter()
                .position(|model| model.get("title").and_then(Value::as_str) == Some("Melon Tools"))
            {
                list[index] = entry;
            } else {
                list.push(entry);
            }
        }
        _ => return Err("unsupported".to_string()),
    }
    Ok(render_json(&root))
}

fn anthropic_base(base_url: &str) -> String {
    let mut value = base_url.trim().trim_end_matches('/').to_string();
    if value.ends_with("/v1") {
        value.truncate(value.len() - 3);
    }
    value
}

fn require_model(context: &Context) -> Result<(), String> {
    if context.model.trim().is_empty() {
        return Err("emptyModel".to_string());
    }
    Ok(())
}

fn apply_custom(
    agent: &CustomAgent,
    text: &str,
    path: &Path,
    context: &Context,
) -> Result<String, String> {
    if agent.format == "env" {
        let mut out = text.to_string();
        out = upsert_env(&out, &agent.base_url_key, &context.base_url);
        out = upsert_env(&out, &agent.api_key_key, &context.api_key);
        if !agent.model_key.trim().is_empty() && !context.model.trim().is_empty() {
            out = upsert_env(&out, &agent.model_key, context.model.trim());
        }
        return Ok(out);
    }
    let mut root = parse_json(text, path)?;
    set_dotted(&mut root, &agent.base_url_key, &context.base_url);
    set_dotted(&mut root, &agent.api_key_key, &context.api_key);
    if !agent.model_key.trim().is_empty() && !context.model.trim().is_empty() {
        set_dotted(&mut root, &agent.model_key, context.model.trim());
    }
    Ok(render_json(&root))
}

fn transform(
    definition: &Definition,
    index: usize,
    current: &str,
    path: &Path,
    context: &Context,
) -> Result<String, String> {
    if definition.manual {
        return Err("manualAgent".to_string());
    }
    match definition.adapter {
        "codex" => apply_codex(current, context),
        "claude" | "opencode" | "crush" | "continue" => {
            apply_json_agent(definition.adapter, current, path, context)
        }
        "gemini" => {
            let mut out = current.to_string();
            out = upsert_env(&out, "GOOGLE_GEMINI_BASE_URL", &context.base_url);
            out = upsert_env(&out, "GEMINI_API_KEY", &context.api_key);
            if !context.model.trim().is_empty() {
                out = upsert_env(&out, "GEMINI_MODEL", context.model.trim());
            }
            Ok(out)
        }
        "vscode" => {
            if index == 0 {
                apply_vscode_settings(current, path, context)
            } else {
                apply_vscode_catalog(current, path, context)
            }
        }
        "antigravity" => apply_antigravity(current, path, context),
        "cursor-cli" => apply_cursor_cli(current, path, context),
        "dsh" => {
            require_model(context)?;
            Ok(apply_dsh(current, context))
        }
        _ => Err("unsupported".to_string()),
    }
}

/// The files one apply touches. Agents move their config between releases
/// (OpenCode renamed `.json` to `.jsonc`), so an existing file always wins
/// over the preferred name.
fn target_paths(definition: &Definition) -> Vec<String> {
    let configs = configured_paths(definition);
    match definition.adapter {
        "vscode" => configs,
        "antigravity" => {
            let existing: Vec<String> = configs
                .iter()
                .filter(|path| expand_home(path).is_file())
                .cloned()
                .collect();
            if existing.is_empty() {
                configs.into_iter().take(1).collect()
            } else {
                existing
            }
        }
        "dsh" | "opencode" => {
            if let Some(path) = configs.iter().find(|path| expand_home(path).is_file()) {
                vec![path.clone()]
            } else {
                configs.into_iter().take(1).collect()
            }
        }
        _ => configs.into_iter().take(1).collect(),
    }
}

pub(crate) fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = crate::paths::tmp_path(path);
    std::fs::write(&temporary, text).map_err(|error| error.to_string())?;
    #[cfg(target_os = "windows")]
    {
        // `std::fs::rename` refuses to replace an existing file on Windows.
        // MoveFileExW replaces it in one filesystem operation, so a crash
        // cannot leave a half-copied config behind.
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        };
        let from: Vec<u16> = temporary
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let to: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let moved = unsafe {
            MoveFileExW(
                from.as_ptr(),
                to.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        };
        if moved == 0 {
            let error = std::io::Error::last_os_error();
            let _ = std::fs::remove_file(&temporary);
            return Err(error.to_string());
        }
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::fs::rename(&temporary, path).map_err(|error| error.to_string())
    }
}

/// Connects one agent. Returns the fresh snapshot.
pub fn apply(id: &str, model: &str, effort: &str) -> Result<Value, String> {
    let mut state = load_state();
    let settings = settings::load();
    let context = Context {
        base_url: base_url(&settings),
        api_key: settings.api_key.clone(),
        model: model.to_string(),
        effort: effort.to_string(),
    };
    let definition = CATALOG.iter().find(|entry| entry.id == id);
    let custom = state
        .custom_agents
        .iter()
        .find(|entry| entry.id == id)
        .cloned();
    if definition.is_none() && custom.is_none() {
        return Err(format!("Unknown agent: {id}"));
    }
    if let Some(agent) = custom.as_ref() {
        return apply_custom_agent(id, agent, &context, &mut state);
    }
    let definition = definition.expect("checked above");
    let raw_paths = target_paths(definition);
    if raw_paths.is_empty() {
        return Err("manualAgent".to_string());
    }

    let mut edits: Vec<(String, PathBuf, String, bool)> = Vec::new();
    for (index, raw) in raw_paths.iter().enumerate() {
        let path = expand_home(raw);
        let exists = path.is_file();
        let current = if exists {
            std::fs::read_to_string(&path).map_err(|error| error.to_string())?
        } else {
            String::new()
        };
        let updated = transform(definition, index, &current, &path, &context)?;
        edits.push((raw.clone(), path, updated, exists));
    }

    let mut files = Vec::new();
    for (index, (raw, path, text, existed)) in edits.iter().enumerate() {
        let backup_path = if *existed {
            std::fs::create_dir_all(backup_dir()).map_err(|error| error.to_string())?;
            let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
            let target = backup_dir().join(format!("{id}-{stamp}-{index}.bak"));
            std::fs::copy(path, &target).map_err(|error| error.to_string())?;
            Some(target.to_string_lossy().to_string())
        } else {
            None
        };
        write_atomic(path, text)?;
        files.push(AppliedFile {
            path: raw.clone(),
            backup_path,
            created: !*existed,
        });
    }

    let hash = content_hash(
        &edits
            .iter()
            .map(|(_, path, text, _)| (path.to_string_lossy().to_string(), text.clone()))
            .collect::<Vec<_>>(),
    );
    let first = files.first().expect("at least one file");
    state.applications.insert(
        id.to_string(),
        Application {
            agent_id: id.to_string(),
            applied_at: now_iso(),
            config_path: first.path.clone(),
            backup_path: first.backup_path.clone(),
            created_file: first.created,
            model: context.model.clone(),
            effort: context.effort.clone(),
            content_hash: Some(hash),
            files,
        },
    );
    save_state(&state)?;
    Ok(snapshot())
}

fn apply_custom_agent(
    id: &str,
    agent: &CustomAgent,
    context: &Context,
    state: &mut State,
) -> Result<Value, String> {
    let raw = agent.config_path.clone();
    let path = expand_home(&raw);
    let existed = path.is_file();
    let current = if existed {
        std::fs::read_to_string(&path).map_err(|error| error.to_string())?
    } else {
        String::new()
    };
    let updated = apply_custom(agent, &current, &path, context)?;
    let backup_path = if existed {
        std::fs::create_dir_all(backup_dir()).map_err(|error| error.to_string())?;
        let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
        let target = backup_dir().join(format!("{id}-{stamp}.bak"));
        std::fs::copy(&path, &target).map_err(|error| error.to_string())?;
        Some(target.to_string_lossy().to_string())
    } else {
        None
    };
    write_atomic(&path, &updated)?;
    let hash = content_hash(&[(path.to_string_lossy().to_string(), updated)]);
    state.applications.insert(
        id.to_string(),
        Application {
            agent_id: id.to_string(),
            applied_at: now_iso(),
            config_path: raw.clone(),
            backup_path: backup_path.clone(),
            created_file: !existed,
            model: context.model.clone(),
            effort: context.effort.clone(),
            content_hash: Some(hash),
            files: vec![AppliedFile {
                path: raw,
                backup_path,
                created: !existed,
            }],
        },
    );
    save_state(state)?;
    Ok(snapshot())
}

/// Restores the files this app replaced, or removes the ones it created.
pub fn revert(id: &str) -> Result<Value, String> {
    let mut state = load_state();
    let Some(application) = state.applications.remove(id) else {
        return Ok(snapshot());
    };
    for file in applied_files(&application) {
        let path = expand_home(&file.path);
        if file.created {
            let _ = std::fs::remove_file(&path);
        } else if let Some(backup) = file.backup_path {
            let backup = PathBuf::from(backup);
            if backup.exists() {
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                std::fs::copy(&backup, &path).map_err(|error| error.to_string())?;
            }
        }
    }
    save_state(&state)?;
    Ok(snapshot())
}

/// Adds or updates a custom agent. The id is generated for new entries.
pub fn save_custom(payload: &Value) -> Result<Value, String> {
    let title = payload
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let config_path = payload
        .get("configPath")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if title.is_empty() || config_path.is_empty() {
        return Err("customAgentIncomplete".to_string());
    }
    let format = payload
        .get("format")
        .and_then(Value::as_str)
        .unwrap_or("json");
    let base_url_key = payload
        .get("baseUrlKey")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let api_key_key = payload
        .get("apiKeyKey")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if base_url_key.is_empty() || api_key_key.is_empty() {
        return Err("customAgentKeys".to_string());
    }
    let mut state = load_state();
    let id = payload
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("custom-{}", uuid::Uuid::new_v4()));
    let agent = CustomAgent {
        id: id.clone(),
        title,
        config_path,
        format: format.to_string(),
        base_url_key,
        api_key_key,
        model_key: payload
            .get("modelKey")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string(),
        note: payload
            .get("note")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    };
    if let Some(existing) = state.custom_agents.iter_mut().find(|entry| entry.id == id) {
        *existing = agent;
    } else {
        state.custom_agents.push(agent);
    }
    save_state(&state)?;
    Ok(snapshot())
}

/// Drops a custom agent and restores its file when it is still connected.
pub fn remove_custom(id: &str) -> Result<Value, String> {
    if load_state().applications.contains_key(id) {
        revert(id)?;
    }
    let mut state = load_state();
    state.custom_agents.retain(|entry| entry.id != id);
    save_state(&state)?;
    Ok(snapshot())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> Context {
        Context {
            base_url: "http://127.0.0.1:18317/v1".to_string(),
            api_key: "sk-test".to_string(),
            model: "gpt-6".to_string(),
            effort: String::new(),
        }
    }

    #[test]
    fn codex_route_is_replaced_in_place() {
        let text = "model = \"old\"\n\n[model_providers.melon]\nname = \"Old\"\nbase_url = \"http://x\"\n\n[other]\nkeep = true\n";
        let out = apply_codex(text, &context()).expect("apply");
        assert!(out.starts_with("model_provider = \"melon_local_access\"\n"));
        assert!(out.contains("model = \"gpt-6\""));
        assert!(out.contains("name = \"Melon Tools API\""));
        assert!(out.contains("[other]\nkeep = true"));
        assert_eq!(
            out.matches("[model_providers.melon_local_access]").count(),
            1
        );
    }

    #[test]
    fn catalog_reports_restart_and_install_hints() {
        let codex = CATALOG
            .iter()
            .find(|definition| definition.id == "codex")
            .expect("codex");
        let info = catalog_info(codex, &State::default());
        assert_eq!(info.restart_hint.as_deref(), Some("agentRestartCodex"));
        assert_eq!(
            info.install_command.as_deref(),
            Some("npm install -g @openai/codex")
        );
        let qwen = CATALOG
            .iter()
            .find(|definition| definition.id == "qwen")
            .expect("qwen");
        let manual = catalog_info(qwen, &State::default());
        assert!(manual.restart_hint.is_none());
        assert!(manual.install_command.is_none());
    }

    #[test]
    fn codex_effort_is_written() {
        let mut ctx = context();
        ctx.effort = "high".to_string();
        let out = apply_codex("model = \"old\"\n", &ctx).expect("apply");
        assert!(out.contains("model_reasoning_effort = \"high\""));
    }

    #[test]
    fn claude_env_keeps_other_keys() {
        let text = r#"{"env":{"KEEP":"1"},"model":"opus"}"#;
        let out = apply_json_agent("claude", text, Path::new("settings.json"), &context())
            .expect("apply");
        let value: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(value["env"]["KEEP"], "1");
        assert_eq!(value["env"]["ANTHROPIC_AUTH_TOKEN"], "sk-test");
        assert_eq!(value["env"]["ANTHROPIC_BASE_URL"], "http://127.0.0.1:18317");
        assert_eq!(value["model"], "opus");
    }

    #[test]
    fn opencode_writes_model_root() {
        let out = apply_json_agent("opencode", "{}", Path::new("opencode.jsonc"), &context())
            .expect("apply");
        let value: Value = serde_json::from_str(&out).expect("json");
        assert_eq!(value["model"], "melon/gpt-6");
        assert_eq!(
            value["provider"]["melon"]["options"]["baseURL"],
            "http://127.0.0.1:18317/v1"
        );
    }

    #[test]
    fn jsonc_comments_and_trailing_commas_are_tolerated() {
        let text = "{\n  // keep\n  \"theme\": \"dark\",\n}\n";
        let value = parse_json(text, Path::new("opencode.jsonc")).expect("jsonc");
        assert_eq!(value["theme"], "dark");
    }

    #[test]
    fn vscode_catalog_replaces_our_group() {
        let text = r#"[{"name":"Other","vendor":"x"}]"#;
        let out = apply_vscode_catalog(text, Path::new("chatLanguageModels.json"), &context())
            .expect("apply");
        let value: Value = serde_json::from_str(&out).expect("json");
        let list = value.as_array().expect("array");
        assert_eq!(list.len(), 2);
        assert_eq!(list[1]["name"], "Melon Tools");
        assert_eq!(list[1]["vendor"], "customendpoint");
        assert_eq!(
            list[1]["models"][0]["url"],
            "http://127.0.0.1:18317/v1/chat/completions"
        );
    }

    #[test]
    fn dsh_patch_is_idempotent() {
        let mut ctx = context();
        ctx.model = "deepseek-v4".to_string();
        let once = apply_dsh("", &ctx);
        let twice = apply_dsh(&once, &ctx);
        assert_eq!(once, twice);
        assert_eq!(once.matches("llm-deepseek # melon-tools").count(), 1);
        assert_eq!(once.matches("agent-default-model # melon-tools").count(), 1);
        assert!(once.contains("reasoningEffort: \"high\""));
    }

    #[test]
    fn env_file_updates_instead_of_appending() {
        let text = "GEMINI_API_KEY=old\nOTHER=1\n";
        let out = upsert_env(text, "GEMINI_API_KEY", "new");
        assert_eq!(out, "GEMINI_API_KEY=new\nOTHER=1\n");
    }

    #[test]
    fn empty_model_is_rejected_for_model_bound_agents() {
        let mut ctx = context();
        ctx.model = "  ".to_string();
        let error = apply_codex("", &ctx).expect_err("model required");
        assert_eq!(error, "emptyModel");
    }

    #[test]
    fn dotted_path_creates_missing_objects() {
        let mut root = Map::new();
        set_dotted(&mut root, "providers.melon.baseURL", "http://x/v1");
        assert_eq!(root["providers"]["melon"]["baseURL"], "http://x/v1");
    }

    #[test]
    fn hash_is_stable_and_content_sensitive() {
        let first = content_hash(&[("a".to_string(), "one".to_string())]);
        let same = content_hash(&[("a".to_string(), "one".to_string())]);
        let changed = content_hash(&[("a".to_string(), "two".to_string())]);
        assert_eq!(first, same);
        assert_ne!(first, changed);
        assert_eq!(first.len(), 64);
    }
}
