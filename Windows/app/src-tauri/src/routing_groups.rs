//! Model routing groups: one model name that several providers serve.
//!
//! The engine has no cross-provider group primitive. The trick used here is the
//! one it does support: the same alias is declared on every member's provider
//! entry, so `/v1/models` lists the alias once and a request fails over between
//! providers. Ordering across providers is decided by the engine (provider
//! model count, then name); ordering inside one provider is preserved.
//!
//! `routing-groups.json` lives next to the other app state and YAML generation
//! is a pure function of that list.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    /// macOS Codable writes `sourceID`/`modelID`; Windows writes camelCase
    /// `sourceId`/`modelId`. Accept both spellings so a vault copied between
    /// platforms keeps its groups; serialization stays camelCase.
    #[serde(alias = "sourceID")]
    pub source_id: String,
    #[serde(alias = "modelID")]
    pub model_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    pub alias: String,
    #[serde(default)]
    pub note: String,
    #[serde(default = "enabled_by_default")]
    pub enabled: bool,
    #[serde(default)]
    pub members: Vec<Member>,
}

fn enabled_by_default() -> bool {
    true
}

pub fn path() -> std::path::PathBuf {
    crate::paths::appdata_dir().join("routing-groups.json")
}

/// Maximum alias length accepted by the routing page and the engine catalog.
pub const MAX_ALIAS_LEN: usize = 64;

/// Groups as stored. A missing file is an empty list; an unreadable or broken
/// one is an error. Treating corruption as an empty list used to let the next
/// save overwrite every route without a trace.
pub fn load() -> Result<Vec<Group>, String> {
    read_groups(&path())
}

fn read_groups(file: &std::path::Path) -> Result<Vec<Group>, String> {
    let raw = match std::fs::read_to_string(file) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(format!(
                "cannot read routing-groups.json ({}): {error}",
                file.display()
            ))
        }
    };
    serde_json::from_str(&raw).map_err(|error| {
        format!(
            "routing-groups.json is corrupted ({}): {error}",
            file.display()
        )
    })
}

/// Serializes the read-modify-write commands. Without it two parallel saves
/// load the same list and the second one silently drops the first edit.
static GROUPS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn lock_groups() -> std::sync::MutexGuard<'static, ()> {
    GROUPS_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn save(groups: &[Group]) -> Result<(), String> {
    let file = path();
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let encoded = serde_json::to_string_pretty(groups).map_err(|error| error.to_string())?;
    crate::agents::write_atomic(&file, &encoded)
}

/// Client-facing model ids keep to the alphabet the provider loaders use.
pub fn normalize(alias: &str) -> String {
    alias.trim().to_lowercase().replace(' ', "-")
}

fn alias_problem(alias: &str, existing: &[String]) -> Option<&'static str> {
    if alias.is_empty() {
        return Some("aliasEmpty");
    }
    if alias.chars().count() > MAX_ALIAS_LEN {
        return Some("aliasTooLong");
    }
    let allowed = alias.chars().all(|c| {
        c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '.' | '_' | '/' | ':')
    });
    if !allowed {
        return Some("aliasChars");
    }
    if existing.iter().any(|other| other == alias) {
        return Some("aliasDuplicate");
    }
    None
}

/// Every alias the model answers to: its ordinary provider alias first, then
/// each active group that lists it. A model can be a member of more than one
/// group and none of those memberships may hide the others.
pub fn aliases_for(groups: &[Group], source: &str, model: &str, default: &str) -> Vec<String> {
    let mut aliases = vec![default.to_string()];
    for alias in group_aliases_for(groups, source, model) {
        if !aliases.iter().any(|existing| existing == &alias) {
            aliases.push(alias);
        }
    }
    aliases
}

/// The groups that route this model, without the ordinary provider alias.
/// A model the user disabled still answers to every active group that lists
/// it; disabling it hides the direct name, not the group membership.
pub fn group_aliases_for(groups: &[Group], source: &str, model: &str) -> Vec<String> {
    let mut aliases = Vec::new();
    for group in groups {
        if !group.enabled || group.members.is_empty() {
            continue;
        }
        let hit = group
            .members
            .iter()
            .any(|member| member.source_id == source && member.model_id == model);
        if hit && !aliases.iter().any(|alias| alias == &group.alias) {
            aliases.push(group.alias.clone());
        }
    }
    aliases
}

/// First alias for the model, kept for the routing tests.
#[cfg(test)]
pub fn alias_for(groups: &[Group], source: &str, model: &str, default: &str) -> String {
    aliases_for(groups, source, model, default)
        .into_iter()
        .next()
        .unwrap_or_else(|| default.to_string())
}

fn model_ids(
    settings: &crate::settings::Settings,
    local_models: &[crate::local_ai::LocalModel],
) -> Vec<Value> {
    let mut out = Vec::new();
    let mut push = |id: String, title: String, models: Vec<Value>| {
        if models.is_empty() {
            return;
        }
        out.push(json!({"id": id, "title": title, "models": models}));
    };
    let model = |id: &str| json!({"id": id, "title": id});

    let opencode_models: Vec<Value> = if settings.opencode_models.is_empty() {
        crate::gateway::opencode_builtin_models()
            .iter()
            .map(|(name, display)| json!({"id": name, "title": display}))
            .collect()
    } else {
        settings
            .opencode_models
            .iter()
            .map(|m| model(&m.id))
            .collect()
    };
    if settings.opencode_enabled && !settings.opencode_key.trim().is_empty() {
        push("opencode".into(), "OpenCode".into(), opencode_models);
    }
    if settings.openrouter_enabled && !settings.openrouter_key.trim().is_empty() {
        push(
            "openrouter".into(),
            "OpenRouter".into(),
            settings
                .openrouter_models
                .iter()
                .map(|m| model(&m.id))
                .collect(),
        );
    }
    for (id, title, enabled, key, models) in [
        (
            "deepinfra",
            "DeepInfra",
            settings.deepinfra_enabled,
            settings.deepinfra_key.as_str(),
            &settings.deepinfra_models,
        ),
        (
            "nvidia",
            "NVIDIA",
            settings.nvidia_enabled,
            settings.nvidia_key.as_str(),
            &settings.nvidia_models,
        ),
        (
            "vercel",
            "Vercel",
            settings.vercel_enabled,
            settings.vercel_key.as_str(),
            &settings.vercel_models,
        ),
        (
            "zai",
            "Z.ai",
            settings.zai_enabled,
            settings.zai_key.as_str(),
            &settings.zai_models,
        ),
        (
            "commandcode",
            "CommandCode",
            settings.commandcode_enabled,
            settings.commandcode_key.as_str(),
            &settings.commandcode_models,
        ),
    ] {
        if enabled && !key.trim().is_empty() {
            push(
                id.into(),
                title.into(),
                models.iter().map(|m| model(&m.id)).collect(),
            );
        }
    }
    for provider in settings.custom_providers.iter().filter(|p| p.enabled) {
        push(
            provider.id.clone(),
            provider.name.clone(),
            provider
                .models
                .iter()
                .filter(|m| !m.id.trim().is_empty())
                .map(|m| model(&m.id))
                .collect(),
        );
    }
    if settings.claude_enabled && !settings.claude_api_key.trim().is_empty() {
        push(
            "claude".into(),
            "Claude".into(),
            crate::gateway::CLAUDE_MODELS
                .iter()
                .map(|(id, display)| json!({"id": id, "title": display}))
                .collect(),
        );
    }
    push(
        "local".into(),
        "Local AI".into(),
        local_models
            .iter()
            .map(|m| {
                let display = m.display_name.trim();
                json!({
                    "id": m.id.as_str(),
                    "title": if display.is_empty() { m.id.as_str() } else { display },
                })
            })
            .collect(),
    );
    out
}

/// Groups plus the providers that can carry an alias, for the routing page.
pub fn snapshot(settings: &crate::settings::Settings) -> Value {
    let (groups, error) = match load() {
        Ok(groups) => (groups, Value::Null),
        Err(error) => (Vec::new(), Value::String(error)),
    };
    let local_models = crate::gateway::servable_local_models();
    json!({
        "groups": groups,
        "sources": model_ids(settings, &local_models),
        "path": path().to_string_lossy(),
        "error": error,
    })
}

fn session_group(value: &Value) -> Result<Group, String> {
    let alias = normalize(
        value
            .get("alias")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    );
    let note = value
        .get("note")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let enabled = value
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let members: Vec<Member> = value
        .get("members")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|row| {
                    let source = row.get("sourceId").and_then(Value::as_str)?.trim();
                    let model = row.get("modelId").and_then(Value::as_str)?.trim();
                    if source.is_empty() || model.is_empty() {
                        return None;
                    }
                    Some(Member {
                        source_id: source.to_string(),
                        model_id: model.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if members.is_empty() {
        return Err("membersEmpty".to_string());
    }
    Ok(Group {
        id: value
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_string)
            .filter(|id| !id.trim().is_empty())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
        alias,
        note,
        enabled,
        members,
    })
}

/// Insert or update one group and write the list back.
/// Drops the rows that would take the same share twice.
///
/// Two rows for one provider and the very same model id are one route, and the
/// engine weights the route, not the row: leaving both in doubles that
/// provider's share of the traffic without giving it anything to serve it
/// with. The comparison is the raw id on purpose. Two spellings of one model id
/// are two different ids as far as the upstream is concerned, and folding them
/// together would silently drop a member the user added.
pub fn unique_members(members: &[Member]) -> Vec<Member> {
    let mut seen: Vec<(String, String)> = Vec::new();
    let mut unique = Vec::with_capacity(members.len());
    for member in members {
        let key = (member.source_id.clone(), member.model_id.clone());
        if !seen.contains(&key) {
            seen.push(key);
            unique.push(member.clone());
        }
    }
    unique
}

pub fn upsert(value: Value) -> Result<Value, String> {
    let _guard = lock_groups();
    let incoming = session_group(&value)?;
    let mut groups = load()?;
    let mut saved = incoming;
    saved.members = unique_members(&saved.members);
    if saved.members.is_empty() {
        return Err("Add at least one model to the group.".to_string());
    }
    let others: Vec<String> = groups
        .iter()
        .filter(|group| group.id != saved.id)
        .map(|group| group.alias.clone())
        .collect();
    if let Some(problem) = alias_problem(&saved.alias, &others) {
        return Err(problem.to_string());
    }
    match groups.iter_mut().find(|group| group.id == saved.id) {
        Some(slot) => *slot = saved,
        None => groups.push(saved),
    }
    save(&groups)?;
    Ok(json!({ "groups": groups }))
}

pub fn remove(id: &str) -> Result<Value, String> {
    let _guard = lock_groups();
    let mut groups = load()?;
    groups.retain(|group| group.id != id);
    save(&groups)?;
    Ok(json!({ "groups": groups }))
}

pub fn set_enabled(id: &str, enabled: bool) -> Result<Value, String> {
    let _guard = lock_groups();
    let mut groups = load()?;
    if let Some(group) = groups.iter_mut().find(|group| group.id == id) {
        group.enabled = enabled;
    }
    save(&groups)?;
    Ok(json!({ "groups": groups }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn member(source: &str, model: &str) -> Member {
        Member {
            source_id: source.into(),
            model_id: model.into(),
        }
    }

    #[test]
    fn unique_members_counts_one_route_per_provider_and_model() {
        // The same model on two providers is two routes and is kept twice.
        let both = vec![
            member("dotai", "deepseek-v4.1-flash"),
            member("astraapi", "deepseek-v4.1-flash"),
        ];
        assert_eq!(unique_members(&both).len(), 2);

        // A repeated row of one provider and model is one route.
        let repeated = vec![
            member("dotai", "deepseek-v4.1-flash"),
            member("dotai", "deepseek-v4.1-flash"),
            member("bashapi", "deepseek-v4.1-flash"),
        ];
        let unique = unique_members(&repeated);
        assert_eq!(unique.len(), 2);
        assert_eq!(unique[0].source_id, "dotai");
        assert_eq!(unique[1].source_id, "bashapi");

        // Two ids that only look alike are two rows: the user added both on
        // purpose and folding them would drop a member silently.
        let spellings = vec![
            member("dotai", "deepseek-v4.1-flash"),
            member("dotai", "deepseek-v4-1-flash"),
        ];
        assert_eq!(unique_members(&spellings).len(), 2);

        // Different models in one group are all kept.
        let mixed = vec![
            member("million-deepseek", "deepseek-v4.1-flash-free"),
            member("dotai", "deepseek-v4.1-flash"),
            member("iishko", "qwen4-max"),
        ];
        assert_eq!(unique_members(&mixed).len(), 3);
    }

    #[test]
    fn alias_replaces_the_default_only_for_members() {
        let groups = vec![Group {
            id: "g1".into(),
            alias: "smart".into(),
            note: String::new(),
            enabled: true,
            members: vec![member("opencode", "gpt-5"), member("zai", "glm-5.3")],
        }];
        let aliases = aliases_for(&groups, "opencode", "gpt-5", "opencode/gpt-5");
        assert_eq!(
            aliases,
            vec!["opencode/gpt-5".to_string(), "smart".to_string()]
        );
        let others = aliases_for(&groups, "nvidia", "gpt-5", "nvidia/gpt-5");
        assert_eq!(others, vec!["nvidia/gpt-5".to_string()]);
    }

    #[test]
    fn every_active_group_alias_is_kept_alongside_the_default() {
        let groups = vec![
            Group {
                id: "g1".into(),
                alias: "smart".into(),
                note: String::new(),
                enabled: true,
                members: vec![member("opencode", "gpt-5"), member("zai", "glm-5.3")],
            },
            Group {
                id: "g2".into(),
                alias: "fast".into(),
                note: String::new(),
                enabled: true,
                members: vec![member("opencode", "gpt-5")],
            },
            Group {
                id: "g3".into(),
                alias: "paused".into(),
                note: String::new(),
                enabled: false,
                members: vec![member("opencode", "gpt-5")],
            },
            Group {
                id: "g4".into(),
                alias: "smart".into(),
                note: String::new(),
                enabled: true,
                members: vec![member("opencode", "gpt-5")],
            },
        ];
        assert_eq!(
            aliases_for(&groups, "opencode", "gpt-5", "opencode/gpt-5"),
            vec!["opencode/gpt-5", "smart", "fast"]
        );
        assert_eq!(
            aliases_for(&groups, "zai", "glm-5.3", "zai/glm-5.3"),
            vec!["zai/glm-5.3", "smart"]
        );
    }

    #[test]
    fn disabled_group_member_keeps_the_group_alias() {
        let groups = vec![Group {
            id: "g1".into(),
            alias: "smart".into(),
            note: String::new(),
            enabled: true,
            members: vec![member("acme", "paused")],
        }];
        assert_eq!(
            group_aliases_for(&groups, "acme", "paused"),
            vec!["smart".to_string()]
        );
        assert!(group_aliases_for(&groups, "acme", "other").is_empty());
        assert_eq!(
            aliases_for(&groups, "acme", "paused", "acme/paused"),
            vec!["acme/paused".to_string(), "smart".to_string()]
        );
    }

    fn custom_provider(
        id: &str,
        models: Vec<crate::settings::CustomProviderModel>,
    ) -> crate::settings::CustomProvider {
        crate::settings::CustomProvider {
            id: id.into(),
            name: id.into(),
            base_url: "https://relay.example/v1".into(),
            protocol: "openai-chat".into(),
            api_key: "sk-test".into(),
            enabled: true,
            models,
            priority: None,
            headers: std::collections::BTreeMap::new(),
        }
    }

    fn custom_model(id: &str, enabled: bool) -> crate::settings::CustomProviderModel {
        crate::settings::CustomProviderModel {
            id: id.into(),
            display: id.into(),
            context_window: None,
            enabled,
            alias: String::new(),
        }
    }

    fn source_ids(sources: &[Value], source: &str) -> Vec<String> {
        sources
            .iter()
            .find(|entry| entry["id"] == source)
            .and_then(|entry| entry["models"].as_array())
            .map(|models| {
                models
                    .iter()
                    .filter_map(|model| model["id"].as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn routing_page_lists_every_custom_model_before_it_is_grouped() {
        let settings = crate::settings::Settings {
            custom_providers: vec![custom_provider(
                "acme",
                vec![custom_model("live", true), custom_model("paused", false)],
            )],
            ..Default::default()
        };

        // The editor is where a disabled model gets added to a new group: it
        // must be selectable before any membership exists.
        let sources = model_ids(&settings, &[]);
        assert_eq!(source_ids(&sources, "acme"), vec!["live", "paused"]);
    }

    #[test]
    fn routing_page_lists_claude_builtins_and_local_models() {
        let settings = crate::settings::Settings {
            claude_enabled: true,
            claude_api_key: "sk-ant-test".into(),
            ..Default::default()
        };
        let sources = model_ids(&settings, &[]);
        assert_eq!(
            source_ids(&sources, "claude").len(),
            crate::gateway::CLAUDE_MODELS.len()
        );

        let local = crate::local_ai::LocalModel {
            id: "local/qwen2.5-coder-7b".into(),
            schema_version: None,
            display_name: "Qwen 2.5 Coder 7B".into(),
            provider: "Local AI".into(),
            source: "huggingface".into(),
            repo_id: None,
            revision: None,
            files: Vec::new(),
            file_size: 0,
            quantization: String::new(),
            format: "GGUF".into(),
            context_length: 32768,
            configured_context: 32768,
            backend: crate::local_ai::InferenceBackend::Cpu,
            gpu_offload: None,
            threads: None,
            runtime_status: crate::local_ai::ModelRuntimeStatus::Ready,
            capabilities: vec![crate::local_ai::ModelCapability::Text],
            installed_at: String::new(),
            updated_at: String::new(),
            last_used_at: None,
            license: None,
            checksum: None,
            architecture: None,
            user_settings: crate::local_ai::LocalModelSettings::default(),
        };
        let sources = model_ids(&settings, &[local]);
        let source = sources
            .iter()
            .find(|entry| entry["id"] == "local")
            .expect("local source");
        assert_eq!(source["models"][0]["id"], "local/qwen2.5-coder-7b");
        assert_eq!(source["models"][0]["title"], "Qwen 2.5 Coder 7B");
    }

    /// A group file copied from macOS uses Swift's `ID` capitalization.
    /// Reading it must work; writing must normalize back to camelCase.
    #[test]
    fn macos_member_key_spelling_is_read_and_rewritten_as_camel_case() {
        let decoded: Vec<Group> = serde_json::from_str(
            r#"[{"id":"g1","alias":"smart","enabled":true,"members":[{"sourceID":"acme","modelID":"paused"}]}]"#,
        )
        .expect("macOS spelling");
        assert_eq!(decoded[0].members[0].source_id, "acme");
        assert_eq!(decoded[0].members[0].model_id, "paused");
        let encoded = serde_json::to_value(&decoded).unwrap();
        assert_eq!(encoded[0]["members"][0]["sourceId"], "acme");
        assert_eq!(encoded[0]["members"][0]["modelId"], "paused");
        assert!(encoded[0]["members"][0].get("sourceID").is_none());
        assert!(encoded[0]["members"][0].get("modelID").is_none());
    }

    #[test]
    fn corrupt_store_is_an_error_instead_of_an_empty_list() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("test-routing-groups-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join("routing-groups.json");
        assert!(read_groups(&file)
            .expect("missing file is empty")
            .is_empty());
        std::fs::write(&file, "{not json").expect("write broken file");
        let error = read_groups(&file).expect_err("broken file must fail");
        assert!(error.contains("corrupted"), "{error}");
        std::fs::write(&file, "[]").expect("write valid file");
        assert!(read_groups(&file).expect("valid file").is_empty());
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn alias_length_is_capped_at_64_characters() {
        assert_eq!(alias_problem(&"a".repeat(64), &[]), None);
        assert_eq!(alias_problem(&"a".repeat(65), &[]), Some("aliasTooLong"));
        assert_eq!(alias_problem(&"я".repeat(65), &[]), Some("aliasTooLong"));
    }

    #[test]
    fn paused_groups_do_not_touch_the_config() {
        let groups = vec![Group {
            id: "g1".into(),
            alias: "smart".into(),
            note: String::new(),
            enabled: false,
            members: vec![member("opencode", "gpt-5")],
        }];
        assert_eq!(
            alias_for(&groups, "opencode", "gpt-5", "opencode/gpt-5"),
            "opencode/gpt-5"
        );
    }

    #[test]
    fn alias_is_normalized_and_validated() {
        assert_eq!(normalize("  Smart Model  "), "smart-model");
        assert_eq!(alias_problem("", &[]), Some("aliasEmpty"));
        assert_eq!(alias_problem("bad name", &[]), Some("aliasChars"));
        assert_eq!(
            alias_problem("smart", &["smart".to_string()]),
            Some("aliasDuplicate")
        );
        assert_eq!(alias_problem("smart", &[]), None);
    }

    #[test]
    fn session_requires_a_member() {
        let error = session_group(&json!({"alias": "smart", "members": []})).unwrap_err();
        assert_eq!(error, "membersEmpty");
        let group = session_group(&json!({
            "alias": " Smart ",
            "members": [{"sourceId": "opencode", "modelId": "gpt-5"}],
        }))
        .unwrap();
        assert_eq!(group.alias, "smart");
        assert!(group.enabled);
        assert_eq!(group.members.len(), 1);
    }
}
