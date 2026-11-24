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
    pub source_id: String,
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

/// Groups as stored. A broken file behaves like an empty list so the gateway
/// still starts; the routing page surfaces the read error separately.
pub fn load() -> Vec<Group> {
    let raw = match std::fs::read_to_string(path()) {
        Ok(raw) => raw,
        Err(_) => return Vec::new(),
    };
    serde_json::from_str(&raw).unwrap_or_default()
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

/// Enabled groups only: the YAML side never sees paused ones.
pub fn enabled_alias(groups: &[Group], source: &str, model: &str) -> Option<String> {
    groups.iter().find_map(|group| {
        if !group.enabled || group.members.is_empty() {
            return None;
        }
        let hit = group
            .members
            .iter()
            .any(|member| member.source_id == source && member.model_id == model);
        hit.then(|| group.alias.clone())
    })
}

/// Alias to write into the gateway config: the group name when the model is a
/// member, the caller's default otherwise.
pub fn alias_for(groups: &[Group], source: &str, model: &str, default: &str) -> String {
    enabled_alias(groups, source, model).unwrap_or_else(|| default.to_string())
}

fn model_ids(settings: &crate::settings::Settings) -> Vec<Value> {
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
                .filter(|m| m.enabled)
                .map(|m| model(&m.id))
                .collect(),
        );
    }
    out
}

/// Groups plus the providers that can carry an alias, for the routing page.
pub fn snapshot(settings: &crate::settings::Settings) -> Value {
    json!({
        "groups": load(),
        "sources": model_ids(settings),
        "path": path().to_string_lossy(),
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
    let incoming = session_group(&value)?;
    let mut groups = load();
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
    let mut groups = load();
    groups.retain(|group| group.id != id);
    save(&groups)?;
    Ok(json!({ "groups": groups }))
}

pub fn set_enabled(id: &str, enabled: bool) -> Result<Value, String> {
    let mut groups = load();
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
        assert_eq!(
            alias_for(&groups, "opencode", "gpt-5", "opencode/gpt-5"),
            "smart"
        );
        assert_eq!(alias_for(&groups, "zai", "glm-5.3", "zai/glm-5.3"), "smart");
        assert_eq!(
            alias_for(&groups, "nvidia", "gpt-5", "nvidia/gpt-5"),
            "nvidia/gpt-5"
        );
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
