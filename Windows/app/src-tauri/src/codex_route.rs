//! The Codex client route: `model_provider` + `[model_providers.<id>]` in
//! `%USERPROFILE%\.codex\config.toml` (line-based editing, ported from the
//! macOS app) plus the model catalog the Codex picker reads.

use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use crate::paths;
use crate::vault::Account;

pub const PROVIDER_ID: &str = "melon_local_access";
/// Legacy provider id used by older chats and earlier Melon routes. Keeping
/// this table makes those chats resolve to the local gateway instead of
/// failing with "Model provider not found".
pub const LEGACY_PROVIDER_ID: &str = "codex_local_access";
const PROVIDER_NAME: &str = "Melon Tools API";
pub const CATALOG_FILE: &str = "melon-model-catalog.json";

pub fn catalog_path() -> PathBuf {
    paths::codex_home().join(CATALOG_FILE)
}
const MODELS_CACHE_FILE: &str = "models_cache.json";
const DEFAULT_CATALOG_TOOLS: &[&str] = &["send_user_message_async", "clock"];
const FALLBACK_BASE_INSTRUCTIONS: &str =
    "You are Codex, a coding agent. Follow the user's instructions and use the available tools when they help.";

fn config_path() -> PathBuf {
    paths::codex_home().join("config.toml")
}

// MARK: - Line transforms (pure, mirrored from CodexConfigRoute.swift)

fn first_header(lines: &[String]) -> usize {
    lines
        .iter()
        .position(|l| l.trim_start().starts_with('['))
        .unwrap_or(lines.len())
}

fn raw_value(line: &str, key: &str) -> Option<String> {
    let trimmed = line.trim();
    if !trimmed.starts_with(key) {
        return None;
    }
    let rest = trimmed[key.len()..].trim_start();
    if !rest.starts_with('=') {
        return None;
    }
    let mut value = rest[1..].trim().to_string();
    if let Some(hash) = value.find('#') {
        value = value[..hash].trim().to_string();
    }
    Some(value.trim_matches(|c| c == '"' || c == '\'').to_string())
}

fn provider_value(line: &str) -> Option<String> {
    raw_value(line, "model_provider").filter(|v| !v.is_empty())
}

fn top_level_value(text: &str, key: &str) -> Option<String> {
    let lines = to_lines(text);
    let header = first_header(&lines);
    lines
        .iter()
        .take(header)
        .find_map(|line| raw_value(line, key))
        .filter(|value| !value.is_empty())
}

fn table_bounds(lines: &[String], id: &str) -> Option<(usize, usize)> {
    let header = format!("[model_providers.{}]", id);
    let mut start: Option<usize> = None;
    for (index, raw) in lines.iter().enumerate() {
        let line = raw.trim();
        if line == header {
            if start.is_none() {
                start = Some(index);
            }
            continue;
        }
        if let Some(s) = start {
            if index > s && line.starts_with('[') {
                return Some((s, index));
            }
        }
    }
    start.map(|s| (s, lines.len()))
}

fn normalized(mut lines: Vec<String>, ends_with_newline: bool) -> String {
    if ends_with_newline {
        if lines.last().map(|l| !l.is_empty()).unwrap_or(true) {
            lines.push(String::new());
        }
    } else if lines.last().map(|l| l.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines.join("\n")
}

fn to_lines(text: &str) -> Vec<String> {
    text.split('\n').map(String::from).collect()
}

pub fn upsert_route(in_text: &str, base_url: &str, token: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    let provider_line = format!("model_provider = \"{}\"", PROVIDER_ID);
    let mut replaced = false;
    for line in lines.iter_mut().take(header) {
        if provider_value(line).is_some() {
            *line = provider_line.clone();
            replaced = true;
            break;
        }
    }
    if !replaced {
        lines.insert(0, provider_line);
        if lines.len() > 1 && !lines[1].is_empty() {
            lines.insert(1, String::new());
        }
    }
    let block = vec![
        format!("[model_providers.{}]", PROVIDER_ID),
        format!("name = \"{}\"", PROVIDER_NAME),
        format!("base_url = \"{}\"", base_url),
        "wire_api = \"responses\"".to_string(),
        "requires_openai_auth = true".to_string(),
        format!("experimental_bearer_token = \"{}\"", token),
        "supports_websockets = false".to_string(),
    ];
    if let Some((start, end)) = table_bounds(&lines, PROVIDER_ID) {
        let mut replacement = block;
        if end < lines.len() {
            replacement.push(String::new());
        }
        lines.splice(start..end, replacement);
    } else {
        if lines.last().map(|l| !l.is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        lines.extend(block);
    }

    // Legacy alias for chats saved with the older provider id. All other
    // provider tables are left untouched; only this known alias is refreshed
    // to the current gateway address.
    let legacy_block = vec![
        format!("[model_providers.{}]", LEGACY_PROVIDER_ID),
        format!("name = \"{} (legacy)\"", PROVIDER_NAME),
        format!("base_url = \"{}\"", base_url),
        "wire_api = \"responses\"".to_string(),
        "requires_openai_auth = true".to_string(),
        format!("experimental_bearer_token = \"{}\"", token),
        "supports_websockets = false".to_string(),
    ];
    if let Some((start, end)) = table_bounds(&lines, LEGACY_PROVIDER_ID) {
        let mut replacement = legacy_block;
        if end < lines.len() {
            replacement.push(String::new());
        }
        lines.splice(start..end, replacement);
    } else {
        if lines.last().map(|l| !l.is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        lines.extend(legacy_block);
    }
    normalized(lines, ends)
}

pub fn remove_route(in_text: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    if let Some((start, end)) = table_bounds(&lines, PROVIDER_ID) {
        lines.drain(start..end);
    }
    let header = first_header(&lines);
    for index in 0..header {
        if provider_value(&lines[index]).as_deref() == Some(PROVIDER_ID) {
            lines.remove(index);
            break;
        }
    }
    normalized(lines, ends)
}

pub fn upsert_top_level_key(in_text: &str, key: &str, value: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    let replacement = format!("{} = \"{}\"", key, value);
    for line in lines.iter_mut().take(header) {
        if raw_value(line, key).is_some() {
            *line = replacement.clone();
            return normalized(lines, ends);
        }
    }
    let insert_at = lines
        .iter()
        .take(header)
        .position(|line| provider_value(line).is_some())
        .map(|index| index + 1)
        .unwrap_or(0);
    lines.insert(insert_at, replacement);
    normalized(lines, ends)
}

pub fn remove_top_level_key(in_text: &str, key: &str) -> String {
    let ends = in_text.ends_with('\n');
    let mut lines = to_lines(in_text);
    let header = first_header(&lines);
    for index in 0..header {
        if raw_value(&lines[index], key).is_some() {
            lines.remove(index);
            break;
        }
    }
    normalized(lines, ends)
}

// MARK: - High level

/// Atomic replace: the sibling temp file is renamed over the target, so a
/// crash mid-write cannot truncate config.toml. The file holds the gateway
/// bearer token, hence 0600 on Unix hosts (Windows uses the user-profile ACL).
fn write_atomic(path: &Path, data: &str) -> Result<(), String> {
    let tmp = paths::tmp_path(path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Writes (or updates) the Melon route in config.toml, pointing Codex at the
/// local gateway. A one-time backup of the previous file is kept.
pub fn apply(port: u16, api_key: &str) -> Result<(), String> {
    let path = config_path();
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    if !current.is_empty() {
        let backup = path.with_extension("toml.melon-backup");
        if !backup.exists() {
            let _ = std::fs::copy(&path, &backup);
        }
    }
    let mut updated = upsert_route(&current, &format!("http://127.0.0.1:{}/v1", port), api_key);
    if catalog_path().exists() {
        updated = upsert_top_level_key(&updated, "model_catalog_json", CATALOG_FILE);
    } else if top_level_value(&updated, "model_catalog_json")
        .map(|value| value.ends_with(CATALOG_FILE))
        .unwrap_or(false)
    {
        // Remove only our own catalog reference; a catalog configured by the
        // user or another tool must survive a Melon route change.
        updated = remove_top_level_key(&updated, "model_catalog_json");
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    write_atomic(&path, &updated)
}

/// Removes the Melon route and its catalog reference while preserving every
/// other provider table. The legacy `codex_local_access` alias stays so old
/// chats keep resolving to the local gateway. The one-time backup is only used
/// to restore the original top-level provider/catalog values, never to replace
/// the whole file: provider sections added after the takeover must survive.
pub fn remove() -> Result<(), String> {
    let path = config_path();
    let backup = path.with_extension("toml.melon-backup");
    let Ok(current) = std::fs::read_to_string(&path) else {
        return Ok(());
    };
    let backup_text = std::fs::read_to_string(&backup).ok();
    let mut updated = remove_route(&current);

    // Drop only the catalog reference Melon owns.
    if top_level_value(&updated, "model_catalog_json")
        .map(|value| value.ends_with(CATALOG_FILE))
        .unwrap_or(false)
    {
        updated = remove_top_level_key(&updated, "model_catalog_json");
    }

    if let Some(backup_text) = backup_text {
        if let Some(provider) = top_level_value(&backup_text, "model_provider") {
            if provider != PROVIDER_ID {
                updated = upsert_top_level_key(&updated, "model_provider", &provider);
            }
        }
        if let Some(catalog) = top_level_value(&backup_text, "model_catalog_json") {
            if !catalog.ends_with(CATALOG_FILE) {
                updated = upsert_top_level_key(&updated, "model_catalog_json", &catalog);
            }
        }
    }

    write_atomic(&path, &updated)?;
    let _ = std::fs::remove_file(&backup);
    Ok(())
}

/// What the route looks like right now, for the UI.
pub fn status() -> Value {
    let path = config_path();
    let current = std::fs::read_to_string(&path).unwrap_or_default();
    let lines = to_lines(&current);
    let header = first_header(&lines);
    let provider = lines
        .iter()
        .take(header)
        .find_map(|line| provider_value(line));
    let catalog = paths::codex_home().join(CATALOG_FILE);
    json!({
        "configPath": path.to_string_lossy(),
        "provider": provider,
        "ours": provider.as_deref() == Some(PROVIDER_ID),
        "catalogExists": catalog.exists(),
        "catalogPath": catalog.to_string_lossy(),
    })
}

// MARK: - Model catalog

/// Readable name for a raw model id. Numeric groups keep their dotted form
/// (`claude-opus-5-5` → `Claude Opus 5.5`), matching the macOS catalogue.
pub fn prettify(alias: &str) -> String {
    let tail = alias.rsplit('/').next().unwrap_or(alias);
    let mut words: Vec<String> = Vec::new();
    let mut previous_numeric = false;
    for word in tail.split(['-', '_']) {
        if word.is_empty() {
            continue;
        }
        let numeric = word.chars().all(|c| c.is_ascii_digit());
        if numeric && previous_numeric {
            if let Some(last) = words.last_mut() {
                last.push('.');
                last.push_str(word);
                continue;
            }
        }
        words.push(capitalize(word));
        previous_numeric = numeric;
    }
    words.join(" ")
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Best-effort vision-capability heuristic for a gateway model id.
///
/// Codex decides whether the composer accepts pasted images from the catalog
/// entry's `input_modalities`. Provider entries are cloned from a base entry,
/// so the per-model answer has to come from the id. Routing prefixes
/// (`openrouter/anthropic/...`) are ignored, and the heuristic is deliberately
/// conservative: unknown ids stay text-only until the family is known here.
pub fn vision_capable(model_id: &str, owned_by: Option<&str>) -> bool {
    let id = model_id.to_ascii_lowercase();
    let tail = id.rsplit('/').next().unwrap_or(&id);
    let owner = owned_by.unwrap_or("").to_ascii_lowercase();

    // Text-only and generation-only families first: they must not inherit
    // vision from a broader prefix below.
    if tail.starts_with("gpt-oss-") {
        return false;
    }
    if [
        "dall-e",
        "flux",
        "stable-diffusion",
        "imagen",
        "gpt-image",
        "embed",
    ]
    .iter()
    .any(|marker| tail.contains(marker))
    {
        return false;
    }

    // Claude and Gemini are multimodal on every gateway this app routes.
    // `gemini-*-image` still accepts image input, so the whole family is true.
    if tail.starts_with("claude-") || owner.contains("anthropic") {
        return true;
    }
    if tail.starts_with("gemini-") || owner.contains("antigravity") {
        return true;
    }

    // OpenAI GPT families with image input.
    if tail.starts_with("gpt-4o")
        || tail.starts_with("gpt-4.1")
        || tail.starts_with("gpt-5")
        || tail.starts_with("gpt-6")
    {
        return true;
    }

    // OpenRouter vision families.
    if (tail.starts_with("qwen") && tail.contains("-vl"))
        || (tail.starts_with("llama") && tail.contains("vision"))
        || (tail.starts_with("mistral") && tail.contains("vision"))
        || (tail.starts_with("gemma") && tail.contains("vision"))
        || (tail.starts_with("grok-") && tail.contains("vision"))
        || tail.contains("pixtral")
        || tail.contains("internvl")
        || tail.contains("llava")
        || tail == "glm-5.3-flash"
        || tail.starts_with("glm-5.3-flash-")
        || (tail.starts_with("glm-") && glm_vision_suffix(tail))
    {
        return true;
    }

    false
}

/// `glm-*-v` ids (`glm-4.5v`, `glm-4.6-v`) but not plain `glm-5.3`.
fn glm_vision_suffix(tail: &str) -> bool {
    tail.split('-').skip(1).any(|part| {
        part == "v"
            || (part.ends_with('v') && part[..part.len() - 1].chars().any(|c| c.is_ascii_digit()))
    })
}

/// Priority band and provider tag of a gateway model id. One band per provider
/// keeps the Codex picker grouped (pool → OpenCode → OpenRouter → DeepInfra →
/// Vercel → Z.ai → Claude → Antigravity); `None` for ids this app does not publish.
///
/// Antigravity also serves `claude-*` ids, so its registry allowlist is checked
/// before the Claude prefix. Callers that have the `/v1/models` entry should
/// use [`third_party_band_for_model`] so ownership wins over id overlap.
pub fn third_party_band(id: &str) -> Option<(&'static str, i32)> {
    if crate::antigravity::is_antigravity_model_id(id) {
        Some(("Antigravity", 700))
    } else if id.starts_with("opencode/") {
        Some(("opencode", 100))
    } else if id.starts_with("openrouter/") {
        Some(("openrouter", 200))
    } else if id.starts_with("deepinfra/") {
        Some(("deepinfra", 300))
    } else if id.starts_with("vercel/") {
        Some(("vercel", 400))
    } else if id.starts_with("zai/") {
        Some(("zai", 500))
    } else if id.starts_with("commandcode/") {
        Some(("commandcode", 550))
    } else if crate::claude::is_claude_model_id(id) {
        Some(("Claude", 600))
    } else if id.starts_with("local/") {
        Some(("Local AI", 800))
    } else {
        None
    }
}

/// Band for a full `/v1/models` entry. Ownership data (`owned_by`/`type`) wins
/// when the engine provides it, which resolves the `claude-sonnet-4-6` overlap
/// between the Claude and Antigravity registries.
pub fn third_party_band_for_model(entry: &Value) -> Option<(&'static str, i32)> {
    let id = entry.get("id").and_then(|value| value.as_str())?;
    if crate::antigravity::is_antigravity_model_entry(entry) {
        Some(("Antigravity", 700))
    } else if id.starts_with("opencode/") {
        Some(("opencode", 100))
    } else if id.starts_with("openrouter/") {
        Some(("openrouter", 200))
    } else if id.starts_with("deepinfra/") {
        Some(("deepinfra", 300))
    } else if id.starts_with("vercel/") {
        Some(("vercel", 400))
    } else if id.starts_with("zai/") {
        Some(("zai", 500))
    } else if id.starts_with("commandcode/") {
        Some(("commandcode", 550))
    } else if crate::claude::is_claude_model_id(id) {
        Some(("Claude", 600))
    } else if id.starts_with("local/")
        || entry.get("owned_by").and_then(|v| v.as_str()) == Some("local")
    {
        Some(("Local AI", 800))
    } else {
        None
    }
}

/// Provider tag shown by the picker and the chips. Consumed by the tests and
/// kept as the shared contract for the bridge's provider labels (`bridge.rs`
/// still maps everything unknown to `openai` — wiring it up is a follow-up).
#[allow(dead_code)]
pub fn provider_tag(slug: &str) -> &'static str {
    third_party_band(slug)
        .map(|(tag, _)| tag)
        .unwrap_or("openai")
}

const PRIVATE_CATALOG_KEYS: &[&str] = &[
    "base_instructions",
    "model_messages",
    "policy",
    "policy_template",
    "node_repl_policy",
    "rejection_instructions",
    "timeout_instructions",
    "instructions_variables",
];

fn strip_private_catalog_metadata(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for key in PRIVATE_CATALOG_KEYS {
                object.remove(*key);
            }
            for child in object.values_mut() {
                strip_private_catalog_metadata(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                strip_private_catalog_metadata(item);
            }
        }
        _ => {}
    }
}

// MARK: - Schema injection from the Codex model cache

/// The Codex app stores the model metadata it fetched from the service here.
/// The catalog needs that metadata restored after the bundled template's
/// private keys are stripped, otherwise Codex rejects the schema.
fn models_cache_path() -> PathBuf {
    paths::codex_home().join(MODELS_CACHE_FILE)
}

fn load_models_cache() -> Option<Value> {
    let text = std::fs::read_to_string(models_cache_path()).ok()?;
    serde_json::from_str(&text).ok()
}

struct ModelsCache {
    by_slug: HashMap<String, Value>,
    template: Value,
}

/// Ordered entries of the Codex model cache. The file stores `models` as an
/// array; a slug-keyed object is also accepted for older/newer layouts (keys
/// are sorted so the pool order stays stable). Private metadata is kept: the
/// catalog schema injection reads `base_instructions`/`model_messages` from
/// these entries.
fn models_cache_entries(value: &Value) -> Vec<Value> {
    let raw = value.get("models").unwrap_or(value);
    let mut entries: Vec<Value> = Vec::new();
    match raw {
        Value::Array(items) => {
            for item in items {
                let Some(slug) = item
                    .get("slug")
                    .and_then(Value::as_str)
                    .filter(|slug| !slug.is_empty())
                else {
                    continue;
                };
                let mut entry = item.clone();
                entry["slug"] = json!(slug);
                entries.push(entry);
            }
        }
        Value::Object(map) => {
            let mut slugs: Vec<&String> = map.keys().collect();
            slugs.sort();
            for slug in slugs {
                let item = &map[slug];
                if !item.is_object() || slug.is_empty() {
                    continue;
                }
                let mut entry = item.clone();
                entry["slug"] = json!(slug);
                entries.push(entry);
            }
        }
        _ => {}
    }
    entries
}

/// Parses the cache into a by-slug map plus a fallback entry for gateway ids
/// the cache does not know.
fn models_cache_from_value(value: &Value) -> Option<ModelsCache> {
    let entries: Vec<(String, Value)> = models_cache_entries(value)
        .into_iter()
        .filter_map(|entry| {
            let slug = entry.get("slug").and_then(Value::as_str)?.to_string();
            Some((slug, entry))
        })
        .collect();
    if entries.is_empty() {
        return None;
    }
    let by_slug: HashMap<String, Value> = entries.iter().cloned().collect();
    let template = by_slug
        .get("gpt-6.1-sol")
        .cloned()
        .or_else(|| {
            entries
                .iter()
                .find(|(_, entry)| {
                    instructions_template(entry).is_some() || base_instructions(entry).is_some()
                })
                .map(|(_, entry)| entry.clone())
        })
        .or_else(|| entries.first().map(|(_, entry)| entry.clone()))?;
    Some(ModelsCache { by_slug, template })
}

fn instructions_template(entry: &Value) -> Option<&str> {
    entry
        .get("model_messages")
        .and_then(|messages| messages.get("instructions_template"))
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
}

fn base_instructions(entry: &Value) -> Option<&str> {
    entry
        .get("base_instructions")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
}

fn has_instructions(entry: &Value) -> bool {
    instructions_template(entry).is_some() || base_instructions(entry).is_some()
}

/// Copies `model_messages` (preferred) or `base_instructions` from a cache
/// entry. Returns false when the source has neither.
fn copy_instructions(source: &Value, target: &mut Value) -> bool {
    if let Some(messages) = source.get("model_messages") {
        if instructions_template(source).is_some() {
            target["model_messages"] = messages.clone();
            return true;
        }
    }
    if let Some(base) = source.get("base_instructions") {
        if base_instructions(source).is_some() {
            target["base_instructions"] = base.clone();
            return true;
        }
    }
    false
}

fn inject_entry_schema(entry: &mut Value, source: Option<&Value>) {
    if !has_instructions(entry) {
        let copied = source
            .map(|source| copy_instructions(source, entry))
            .unwrap_or(false);
        if !copied {
            entry["base_instructions"] = json!(FALLBACK_BASE_INSTRUCTIONS);
        }
    }
    if entry.get("experimental_supported_tools").is_none() {
        let tools = source
            .and_then(|source| source.get("experimental_supported_tools"))
            .cloned();
        entry["experimental_supported_tools"] =
            tools.unwrap_or_else(|| json!(DEFAULT_CATALOG_TOOLS));
    }
}

/// Every final catalog entry needs tools and an instructions block. Existing
/// values win; a missing one is filled from the cache entry for that slug,
/// then from the cache template, then from the minimal fallback.
fn inject_catalog_schema(models: &mut [Value], cache: Option<&ModelsCache>) {
    for entry in models.iter_mut() {
        let slug = entry
            .get("slug")
            .and_then(Value::as_str)
            .map(str::to_string);
        let source = cache.map(|cache| {
            slug.as_deref()
                .and_then(|slug| cache.by_slug.get(slug))
                .unwrap_or(&cache.template)
        });
        inject_entry_schema(entry, source);
    }
}

// MARK: - Account model pool

/// Priority used when a cache entry does not carry one (schema default).
const DEFAULT_POOL_PRIORITY: i64 = 50;

/// One selectable model of the shared Codex account pool. Mirrors the macOS
/// `CodexPoolModel` shape the picker consumes.
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PoolModel {
    pub slug: String,
    pub display: String,
    pub context_length: Option<u64>,
    pub priority: i64,
}

fn bundled_base_catalog() -> Result<Value, String> {
    serde_json::from_str(include_str!("../../resources/BaseModelCatalog.json"))
        .map_err(|e| e.to_string())
}

/// The `models` array of a catalog value, as independent clones.
fn catalog_models(value: &Value) -> Vec<Value> {
    value
        .get("models")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn bundled_base_entries() -> Vec<Value> {
    bundled_base_catalog()
        .map(|value| catalog_models(&value))
        .unwrap_or_default()
}

/// A catalog entry the picker may list and the user may select. Missing
/// `visibility` means `list` (the schema default); anything else is an
/// internal route and is never selectable.
fn is_visible_pool_entry(entry: &Value) -> bool {
    entry
        .get("visibility")
        .and_then(Value::as_str)
        .unwrap_or("list")
        == "list"
}

fn entry_slug(entry: &Value) -> Option<&str> {
    entry
        .get("slug")
        .and_then(Value::as_str)
        .filter(|slug| !slug.is_empty())
}

/// Visible pool entries: bundled `list` entries first, then visible cache-only
/// entries Codex discovered. A duplicate slug keeps the bundled entry.
fn merge_pool_entries(base: &[Value], cache: &[Value]) -> Vec<Value> {
    let mut merged: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for entry in base.iter().chain(cache.iter()) {
        if !is_visible_pool_entry(entry) {
            continue;
        }
        let Some(slug) = entry_slug(entry) else {
            continue;
        };
        if seen.insert(slug.to_string()) {
            merged.push(entry.clone());
        }
    }
    merged
}

/// Internal base rows (`visibility != "list"`) stay in the generated catalog
/// so Codex keeps its hidden routes, but they are never offered as choices.
fn hidden_base_entries(base: &[Value]) -> Vec<Value> {
    base.iter()
        .filter(|entry| !is_visible_pool_entry(entry))
        .cloned()
        .collect()
}

/// Hidden cache-only rows (`visibility != "list"`) that Codex discovered but
/// the bundled base does not own. The bundled base stays authoritative for a
/// slug it already carries, and a repeated cache slug appears only once.
fn hidden_cache_entries(base: &[Value], cache: &[Value]) -> Vec<Value> {
    let mut seen: HashSet<String> = base
        .iter()
        .filter_map(entry_slug)
        .map(String::from)
        .collect();
    let mut hidden: Vec<Value> = Vec::new();
    for entry in cache {
        let Some(slug) = entry_slug(entry) else {
            continue;
        };
        let is_new = seen.insert(slug.to_string());
        if is_new && !is_visible_pool_entry(entry) {
            hidden.push(entry.clone());
        }
    }
    hidden
}

/// Slugs reach the UI inside `onclick`/`onchange` attribute strings, so only
/// the ASCII characters real model ids use are accepted. A tampered cache file
/// cannot break out of the JavaScript string this way.
fn is_safe_pool_slug(slug: &str) -> bool {
    !slug.is_empty()
        && slug.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'/' | b'-')
        })
}

fn pool_model_from_entry(entry: &Value) -> Option<PoolModel> {
    let slug = entry_slug(entry)?;
    if !is_safe_pool_slug(slug) {
        return None;
    }
    let slug = slug.to_string();
    let display = entry
        .get("display_name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|display| !display.is_empty())
        .map(String::from)
        .unwrap_or_else(|| slug.clone());
    Some(PoolModel {
        slug,
        display,
        context_length: entry.get("context_window").and_then(Value::as_u64),
        priority: entry
            .get("priority")
            .and_then(Value::as_i64)
            .unwrap_or(DEFAULT_POOL_PRIORITY),
    })
}

/// Pool models from explicit base and cache entries, ordered by priority,
/// display name and slug like the macOS picker.
fn pool_models_in(base: &[Value], cache: &[Value]) -> Vec<PoolModel> {
    let mut models: Vec<PoolModel> = merge_pool_entries(base, cache)
        .iter()
        .filter_map(pool_model_from_entry)
        .collect();
    models.sort_by(|left, right| {
        left.priority
            .cmp(&right.priority)
            .then_with(|| {
                left.display
                    .to_lowercase()
                    .cmp(&right.display.to_lowercase())
            })
            .then_with(|| left.slug.cmp(&right.slug))
    });
    models
}

/// Visible pool models for the picker: bundled `BaseModelCatalog.json` `list`
/// entries merged with the visible models Codex discovered.
pub fn pool_models() -> Vec<PoolModel> {
    let base = bundled_base_entries();
    let cache = load_models_cache()
        .map(|value| models_cache_entries(&value))
        .unwrap_or_default();
    pool_models_in(&base, &cache)
}

fn visible_pool_slugs_in(base: &[Value], cache: &[Value]) -> HashSet<String> {
    merge_pool_entries(base, cache)
        .iter()
        .filter_map(entry_slug)
        .map(String::from)
        .collect()
}

/// Slugs of the visible pool (the only models an account may select).
pub fn visible_pool_slugs() -> HashSet<String> {
    let base = bundled_base_entries();
    let cache = load_models_cache()
        .map(|value| models_cache_entries(&value))
        .unwrap_or_default();
    visible_pool_slugs_in(&base, &cache)
}

/// Pool models an account may route. `None` selection means the whole visible
/// pool (legacy vaults); an explicit list is an allowlist. Slugs outside the
/// pool are ignored — they cannot appear in the picker anyway.
pub fn effective_selected_models(account: &Account, all: &HashSet<String>) -> HashSet<String> {
    let Some(selected) = &account.selected_models else {
        return all.clone();
    };
    let mut effective: HashSet<String> = HashSet::new();
    for value in selected {
        let slug = value.trim();
        if !slug.is_empty() && all.contains(slug) {
            effective.insert(slug.to_string());
        }
    }
    effective
}

/// Union of every account's effective selection: the common picker pool. No
/// accounts means the whole visible pool. A union emptied by stale explicit
/// lists also falls back to the full pool so the picker cannot become
/// unusable.
pub fn selected_pool_slugs_in(accounts: &[Account], all: &HashSet<String>) -> HashSet<String> {
    if accounts.is_empty() {
        return all.clone();
    }
    let mut union: HashSet<String> = HashSet::new();
    for account in accounts {
        union.extend(effective_selected_models(account, all));
    }
    if union.is_empty() {
        all.clone()
    } else {
        union
    }
}

/// Union of the account selections against the live visible pool.
pub fn selected_pool_slugs(accounts: &[Account]) -> HashSet<String> {
    selected_pool_slugs_in(accounts, &visible_pool_slugs())
}

/// Visible pool slugs the gateway must not route to this account. Sorted so
/// the auth file payload stays stable between syncs.
pub fn excluded_models_for(account: &Account, all: &HashSet<String>) -> Vec<String> {
    let effective = effective_selected_models(account, all);
    let mut excluded: Vec<String> = all.difference(&effective).cloned().collect();
    excluded.sort();
    excluded
}

/// Keeps hidden entries and visible entries the union selects. Entries
/// without a slug stay: they cannot be filtered safely.
fn filtered_pool_entries(entries: &[Value], selected: Option<&HashSet<String>>) -> Vec<Value> {
    let Some(selected) = selected else {
        return entries.to_vec();
    };
    entries
        .iter()
        .filter(|entry| {
            if !is_visible_pool_entry(entry) {
                return true;
            }
            match entry_slug(entry) {
                Some(slug) => selected.contains(slug),
                None => true,
            }
        })
        .cloned()
        .collect()
}

/// Builds one provider catalog entry from the bundled base template. Image
/// input is written explicitly: a plain clone would keep the template's
/// modalities for every provider model, which is what made Codex reject pasted
/// images for vision ids (and would otherwise advertise them for text-only ids).
fn custom_catalog_entry(
    template: &Value,
    id: &str,
    owned_by: Option<&str>,
    band: i32,
    index: usize,
) -> Value {
    let mut entry = template.clone();
    entry["slug"] = json!(id);
    entry["display_name"] = json!(prettify(id));
    // Keep one provider inside its band even when its model list is large.
    entry["priority"] = json!(band + index.min(99) as i32);
    entry["input_modalities"] = if vision_capable(id, owned_by) {
        json!(["text", "image"])
    } else {
        json!(["text"])
    };
    entry["supports_image_detail_original"] = json!(false);
    // Never inherit the pool template's provider-specific capabilities.
    entry["description"] = json!(prettify(id));
    entry["context_window"] = json!(128_000);
    entry["max_context_window"] = json!(128_000);
    entry["auto_compact_token_limit"] = json!(108_800);
    entry["effective_context_window_percent"] = json!(95);
    entry["additional_speed_tiers"] = json!([]);
    entry["service_tiers"] = json!([]);
    entry["default_service_tier"] = Value::Null;
    entry["supports_search_tool"] = json!(false);
    entry["use_responses_lite"] = json!(false);
    entry["prefer_websockets"] = json!(false);
    entry["visibility"] = json!("list");
    entry["supported_in_api"] = json!(true);
    if entry.get("experimental_supported_tools").is_none() {
        entry["experimental_supported_tools"] = json!(["send_user_message_async", "clock"]);
    }
    entry
}

/// Human-readable provider tag used only when a display name is shared.
fn provider_display_name(tag: &str) -> &str {
    match tag {
        "opencode" => "OpenCode",
        "openrouter" => "OpenRouter",
        "deepinfra" => "DeepInfra",
        "vercel" => "Vercel",
        "zai" => "Z.ai",
        "commandcode" => "CommandCode",
        "local" | "Local AI" => "Local AI",
        other => other,
    }
}

/// The Codex picker keys rows by display name. A model offered by both
/// OpenCode and Antigravity (for example Gemini 3.5 Flash Lite) would
/// otherwise render once and steal the other provider's slot. Qualify only
/// colliding names with the provider so both rows stay selectable.
fn append_unique_catalog_entries(models: &mut Vec<Value>, pending: Vec<(Value, String)>) -> usize {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for entry in models.iter() {
        if let Some(name) = entry.get("display_name").and_then(Value::as_str) {
            *counts.entry(name.to_lowercase()).or_default() += 1;
        }
    }
    for (entry, _) in &pending {
        if let Some(name) = entry.get("display_name").and_then(Value::as_str) {
            *counts.entry(name.to_lowercase()).or_default() += 1;
        }
    }
    let custom = pending.len();
    for (mut entry, provider) in pending {
        let display = entry
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if counts.get(&display.to_lowercase()).copied().unwrap_or(0) > 1 {
            entry["display_name"] = json!(format!("{} ({})", display, provider));
        }
        models.push(entry);
    }
    custom
}

/// Appends one catalog entry per gateway model outside the pool
/// (opencode/*, openrouter/*, deepinfra/*, vercel/*, Claude, Antigravity).
/// Every pool slug — selected or not — keeps its name, so a third-party model
/// can never shadow an account-pool route. Returns the custom count.
fn append_third_party_catalog_entries(
    models: &mut Vec<Value>,
    template: &Value,
    mut entries: Vec<Value>,
    pool_slugs: &HashSet<String>,
) -> usize {
    // Ownership-aware: when the same id is served by both Claude and
    // Antigravity, the Antigravity entry wins the band.
    entries.sort_by_key(|entry| !crate::antigravity::is_antigravity_model_entry(entry));

    let mut pending: Vec<(Value, String)> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut opencode_index = 0usize;
    let mut openrouter_index = 0usize;
    let mut deepinfra_index = 0usize;
    let mut vercel_index = 0usize;
    let mut claude_index = 0usize;
    let mut antigravity_index = 0usize;
    let mut local_ai_index = 0usize;
    for entry in entries {
        let Some(id) = entry.get("id").and_then(|v| v.as_str()).map(String::from) else {
            continue;
        };
        if pool_slugs.contains(&id) || !seen.insert(id.clone()) {
            continue;
        }
        let Some((tag, band)) = third_party_band_for_model(&entry) else {
            continue;
        };
        let index = match tag {
            "opencode" => {
                let index = opencode_index;
                opencode_index += 1;
                index
            }
            "openrouter" => {
                let index = openrouter_index;
                openrouter_index += 1;
                index
            }
            "deepinfra" => {
                let index = deepinfra_index;
                deepinfra_index += 1;
                index
            }
            "vercel" => {
                let index = vercel_index;
                vercel_index += 1;
                index
            }
            "Antigravity" => {
                let index = antigravity_index;
                antigravity_index += 1;
                index
            }
            "Local AI" => {
                let index = local_ai_index;
                local_ai_index += 1;
                index
            }
            _ => {
                let index = claude_index;
                claude_index += 1;
                index
            }
        };
        let owned_by = entry.get("owned_by").and_then(|v| v.as_str());
        let generated = custom_catalog_entry(template, &id, owned_by, band, index);
        pending.push((generated, provider_display_name(tag).to_string()));
    }
    append_unique_catalog_entries(models, pending)
}

/// Assembles the generated catalog: visible pool entries selected by the
/// account union, hidden base routes, then third-party models. The template
/// and the shadow-protection slug set come from the full pool, not the
/// filtered output.
fn build_catalog_models(
    base_entries: &[Value],
    cache_entries: &[Value],
    gateway_entries: Vec<Value>,
    selected: Option<&HashSet<String>>,
) -> Result<(Vec<Value>, usize), String> {
    if base_entries.is_empty() {
        return Err("базовый каталог пуст".to_string());
    }
    let mut entries = merge_pool_entries(base_entries, cache_entries);
    entries.extend(hidden_base_entries(base_entries));
    entries.extend(hidden_cache_entries(base_entries, cache_entries));
    // Every pool slug — visible or hidden — reserves its name, selected or
    // not, so a third-party model can never shadow an account-pool route.
    let pool_slugs: HashSet<String> = entries
        .iter()
        .filter_map(entry_slug)
        .map(String::from)
        .collect();
    for entry in &mut entries {
        strip_private_catalog_metadata(entry);
    }
    let template = entries
        .iter()
        .find(|entry| entry_slug(entry) == Some("gpt-6.1-sol"))
        .or_else(|| {
            entries
                .iter()
                .find(|entry| entry.get("context_window").is_some())
        })
        .cloned()
        .ok_or_else(|| "нет шаблонной записи".to_string())?;
    let mut models = filtered_pool_entries(&entries, selected);
    let custom =
        append_third_party_catalog_entries(&mut models, &template, gateway_entries, &pool_slugs);
    Ok((models, custom))
}

/// Regenerates `%~/.codex/melon-model-catalog.json`: the visible account-pool
/// models selected by at least one account, the hidden base routes, plus one
/// cloned entry per gateway model outside the pool. Returns the custom count.
pub async fn sync_catalog(
    client: &reqwest::Client,
    port: u16,
    api_key: &str,
) -> Result<usize, String> {
    // The common pool is the union of every account's selection; no accounts
    // means every visible model.
    let selected = selected_pool_slugs(&crate::vault::accounts());
    sync_catalog_with_selection(client, port, api_key, Some(&selected)).await
}

async fn sync_catalog_with_selection(
    client: &reqwest::Client,
    port: u16,
    api_key: &str,
    selected: Option<&HashSet<String>>,
) -> Result<usize, String> {
    let base = bundled_base_catalog()?;
    let base_entries = catalog_models(&base);
    if base_entries.is_empty() {
        return Err("базовый каталог пуст".to_string());
    }
    let cache_value = load_models_cache();
    let cache_entries = cache_value
        .as_ref()
        .map(models_cache_entries)
        .unwrap_or_default();

    let list: Value = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    let gateway_entries: Vec<Value> = list
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .unwrap_or_default();

    let (mut models, custom) =
        build_catalog_models(&base_entries, &cache_entries, gateway_entries, selected)?;

    // Pool entries were stripped of private metadata above; restore the
    // schema-required fields from the Codex cache (best effort).
    let cache = cache_value.as_ref().and_then(models_cache_from_value);
    inject_catalog_schema(&mut models, cache.as_ref());

    let payload = json!({ "models": models });
    let path = paths::codex_home().join(CATALOG_FILE);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string(&payload).map_err(|e| e.to_string())?;
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(custom)
}

#[cfg(test)]
mod tests {
    use super::{
        append_unique_catalog_entries, build_catalog_models, custom_catalog_entry,
        effective_selected_models, entry_slug, excluded_models_for, inject_catalog_schema,
        merge_pool_entries, models_cache_from_value, pool_models_in, prettify,
        provider_display_name, provider_tag, remove_route, selected_pool_slugs_in,
        strip_private_catalog_metadata, third_party_band, third_party_band_for_model, upsert_route,
        visible_pool_slugs_in, vision_capable, LEGACY_PROVIDER_ID, PROVIDER_ID,
    };
    use crate::vault::Account;
    use serde_json::{json, Value};
    use std::collections::HashSet;

    #[test]
    fn claude_ids_get_band_600_and_the_claude_tag() {
        assert_eq!(third_party_band("claude-opus-5-5"), Some(("Claude", 600)));
        assert_eq!(
            third_party_band("claude-haiku-4-5-20251001"),
            Some(("Claude", 600))
        );
        assert_eq!(provider_tag("claude-opus-5-5"), "Claude");
        // The existing bands stay untouched.
        assert_eq!(
            third_party_band("opencode/glm-5.3"),
            Some(("opencode", 100))
        );
        assert_eq!(
            third_party_band("openrouter/x-ai/grok-4.7"),
            Some(("openrouter", 200))
        );
        // Account-pool ids are not published by this path.
        assert_eq!(third_party_band("gpt-6.1-sol"), None);
        assert_eq!(provider_tag("gpt-6.1-sol"), "openai");
    }

    #[test]
    fn local_ai_ids_get_band_800_and_the_local_ai_tag() {
        assert_eq!(
            third_party_band("local/qwen-2.5-7b"),
            Some(("Local AI", 800))
        );
        assert_eq!(provider_tag("local/qwen-2.5-7b"), "Local AI");
        assert_eq!(
            third_party_band_for_model(&json!({
                "id": "local/llama-3.2-3b",
                "owned_by": "local"
            })),
            Some(("Local AI", 800))
        );
    }

    #[test]
    fn antigravity_ids_get_band_700_and_the_antigravity_tag() {
        assert_eq!(
            third_party_band("gemini-3-flash"),
            Some(("Antigravity", 700))
        );
        assert_eq!(
            third_party_band("claude-opus-4-6-thinking"),
            Some(("Antigravity", 700))
        );
        // Antigravity also serves claude-* ids; its allowlist must win over
        // the Claude prefix.
        assert_eq!(
            third_party_band("claude-sonnet-4-6"),
            Some(("Antigravity", 700))
        );
        assert_eq!(provider_tag("gemini-3-flash"), "Antigravity");
        assert_eq!(provider_tag("claude-opus-4-6-thinking"), "Antigravity");

        // Ownership data resolves the overlap: an anthropic-owned
        // claude-sonnet-4-6 stays in the Claude band.
        assert_eq!(
            third_party_band_for_model(&json!({
                "id": "claude-sonnet-4-6",
                "owned_by": "anthropic",
                "type": "claude"
            })),
            Some(("Claude", 600))
        );
        assert_eq!(
            third_party_band_for_model(&json!({
                "id": "claude-sonnet-4-6",
                "owned_by": "antigravity",
                "type": "antigravity"
            })),
            Some(("Antigravity", 700))
        );
        // Without ownership the registry allowlist is the fallback.
        assert_eq!(
            third_party_band_for_model(&json!({"id": "gemini-3-flash"})),
            Some(("Antigravity", 700))
        );

        // The existing bands stay untouched.
        assert_eq!(
            third_party_band("opencode/glm-5.3"),
            Some(("opencode", 100))
        );
        assert_eq!(
            third_party_band("openrouter/x-ai/grok-4.7"),
            Some(("openrouter", 200))
        );
        assert_eq!(third_party_band("gpt-6.1-sol"), None);
    }

    #[test]
    fn deepinfra_and_vercel_get_their_own_bands() {
        assert_eq!(
            third_party_band("deepinfra/deepseek-ai/DeepSeek-V4"),
            Some(("deepinfra", 300))
        );
        assert_eq!(
            third_party_band("vercel/anthropic/claude-sonnet-4.6"),
            Some(("vercel", 400))
        );
        assert_eq!(third_party_band("zai/glm-5.3"), Some(("zai", 500)));
        assert_eq!(
            third_party_band("commandcode/claude-sonnet-5-5"),
            Some(("commandcode", 550))
        );
        assert_eq!(provider_tag("deepinfra/x"), "deepinfra");
        assert_eq!(provider_tag("vercel/y"), "vercel");
        assert_eq!(provider_tag("zai/glm-5.3"), "zai");
        assert_eq!(provider_tag("commandcode/gpt-6-astra"), "commandcode");
        assert_eq!(
            third_party_band_for_model(&json!({"id": "deepinfra/x", "owned_by": "deepinfra"})),
            Some(("deepinfra", 300))
        );
        assert_eq!(
            third_party_band_for_model(&json!({"id": "vercel/y", "owned_by": "vercel"})),
            Some(("vercel", 400))
        );
        assert_eq!(provider_display_name("deepinfra"), "DeepInfra");
        assert_eq!(provider_display_name("vercel"), "Vercel");
        assert_eq!(provider_display_name("zai"), "Z.ai");
    }

    #[test]
    fn catalog_priority_index_is_capped_at_99() {
        let template = json!({"slug": "template"});
        let entry = custom_catalog_entry(&template, "deepinfra/x", Some("deepinfra"), 300, 150);
        assert_eq!(entry["priority"], 399);
    }

    #[test]
    fn claude_display_names_keep_dotted_versions() {
        assert_eq!(prettify("claude-opus-5-5"), "Claude Opus 5.5");
        assert_eq!(prettify("claude-sonnet-4-6"), "Claude Sonnet 4.6");
        assert_eq!(prettify("opencode/claude-haiku-5-5"), "Claude Haiku 5.5");
        assert_eq!(prettify("deepseek-v4.1-flash"), "Deepseek V4.1 Flash");
        assert_eq!(prettify("glm-5.3"), "Glm 5.3");
    }

    #[test]
    fn shared_model_names_keep_both_provider_rows() {
        let mut models = vec![json!({
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol"
        })];
        let pending = vec![
            (
                json!({
                    "slug": "opencode/gemini-3.5-flash-lite",
                    "display_name": "Gemini 3.5 Flash Lite"
                }),
                provider_display_name("opencode").to_string(),
            ),
            (
                json!({
                    "slug": "gemini-3.5-flash-lite",
                    "display_name": "Gemini 3.5 Flash Lite"
                }),
                provider_display_name("Antigravity").to_string(),
            ),
        ];
        assert_eq!(append_unique_catalog_entries(&mut models, pending), 2);
        let names: Vec<&str> = models
            .iter()
            .filter_map(|entry| entry.get("display_name").and_then(Value::as_str))
            .collect();
        assert_eq!(
            names,
            vec![
                "GPT-6.1 Sol",
                "Gemini 3.5 Flash Lite (OpenCode)",
                "Gemini 3.5 Flash Lite (Antigravity)"
            ]
        );
    }

    #[test]
    fn unique_model_names_are_not_suffixed() {
        let mut models = vec![json!({"display_name": "GPT-6.1 Sol"})];
        let pending = vec![(
            json!({
                "slug": "opencode/unique",
                "display_name": "Unique Model"
            }),
            provider_display_name("opencode").to_string(),
        )];
        append_unique_catalog_entries(&mut models, pending);
        assert_eq!(models[1]["display_name"], "Unique Model");
    }

    #[test]
    fn private_catalog_metadata_is_removed_recursively() {
        let mut value = json!({
            "slug": "sample-model",
            "base_instructions": "private fixture",
            "nested": {
                "policy": "private fixture",
                "safe": true,
                "items": [{"timeout_instructions": "private fixture", "enabled": true}]
            }
        });

        strip_private_catalog_metadata(&mut value);

        assert_eq!(value["slug"], "sample-model");
        assert!(value.get("base_instructions").is_none());
        assert!(value["nested"].get("policy").is_none());
        assert_eq!(value["nested"]["safe"], true);
        assert!(value["nested"]["items"][0]
            .get("timeout_instructions")
            .is_none());
    }

    #[test]
    fn vision_heuristic_accepts_known_vision_models() {
        assert!(vision_capable("claude-sonnet-4-6", Some("anthropic")));
        assert!(vision_capable(
            "openrouter/anthropic/claude-sonnet-4.6",
            Some("openrouter")
        ));
        assert!(vision_capable("gemini-3-flash", Some("antigravity")));
        assert!(vision_capable("gemini-2.5-flash-image", None));
        assert!(vision_capable("qwen2.5-vl-72b-instruct", None));
        assert!(vision_capable("gpt-4o-mini", None));
        assert!(vision_capable("gpt-5.1", None));
        assert!(vision_capable(
            "openrouter/meta-llama/llama-3.2-11b-vision",
            None
        ));
        assert!(vision_capable("mistralai/pixtral-large", None));
        assert!(vision_capable("glm-4.5v", None));
    }

    #[test]
    fn vision_heuristic_rejects_text_and_generation_models() {
        assert!(!vision_capable("gpt-oss-120b-medium", Some("openai")));
        assert!(!vision_capable("dall-e-3", Some("openai")));
        assert!(!vision_capable("flux-1.1-pro", None));
        assert!(!vision_capable("stable-diffusion-3.5", None));
        assert!(!vision_capable("imagen-3.0", None));
        assert!(!vision_capable("gpt-image-1", Some("openai")));
        assert!(!vision_capable("text-embedding-3-large", Some("openai")));
        assert!(!vision_capable("glm-5.3", None));
        assert!(vision_capable("glm-5.3-flash", Some("zai")));
        assert!(vision_capable("glm-5.3-flash-high", Some("zai")));
        assert!(!vision_capable("unknown-model", None));
    }

    #[test]
    fn catalog_entry_writes_input_modalities_from_the_heuristic() {
        let template = json!({
            "slug": "gpt-6.1-sol",
            "display_name": "GPT-6.1 Sol",
            "context_window": 272000,
            "input_modalities": ["text"],
            "supports_image_detail_original": true
        });

        let vision = custom_catalog_entry(
            &template,
            "openrouter/qwen2.5-vl-72b",
            Some("openrouter"),
            200,
            3,
        );
        assert_eq!(vision["input_modalities"], json!(["text", "image"]));
        assert_eq!(vision["supports_image_detail_original"], json!(false));
        assert_eq!(vision["slug"], json!("openrouter/qwen2.5-vl-72b"));
        assert_eq!(vision["priority"], json!(203));

        let text = custom_catalog_entry(&template, "gpt-oss-120b-medium", Some("openai"), 200, 4);
        assert_eq!(text["input_modalities"], json!(["text"]));
        assert_eq!(text["supports_image_detail_original"], json!(false));
        assert_eq!(text["priority"], json!(204));
    }

    #[test]
    fn catalog_metadata_strip_keeps_experimental_tools() {
        let mut value = json!({
            "slug": "x",
            "base_instructions": "secret",
            "experimental_supported_tools": ["clock"]
        });
        strip_private_catalog_metadata(&mut value);
        assert_eq!(value["experimental_supported_tools"], json!(["clock"]));
        assert!(value.get("base_instructions").is_none());
    }

    #[test]
    fn catalog_entry_adds_experimental_tools_when_template_lacks_them() {
        let template = json!({"slug": "template"});
        let entry = custom_catalog_entry(&template, "claude-sonnet-4-6", Some("anthropic"), 300, 1);
        assert_eq!(
            entry["experimental_supported_tools"],
            json!(["send_user_message_async", "clock"])
        );
    }

    fn fixture_cache() -> serde_json::Value {
        json!({
            "fetched_at": "2026-10-17T05:43:48Z",
            "models": [
                {
                    "slug": "gpt-6.1-sol",
                    "model_messages": {"instructions_template": "template instructions"},
                    "experimental_supported_tools": ["clock"]
                },
                {
                    "slug": "claude-sonnet-4-6",
                    "base_instructions": "claude instructions",
                    "experimental_supported_tools": ["alpha"]
                }
            ]
        })
    }

    #[test]
    fn catalog_injection_uses_the_cache_by_slug_and_the_template() {
        let cache = models_cache_from_value(&fixture_cache()).expect("fixture cache");
        let mut models = vec![
            json!({"slug": "claude-sonnet-4-6"}),
            json!({"slug": "openrouter/unknown-model"}),
        ];

        inject_catalog_schema(&mut models, Some(&cache));

        assert_eq!(models[0]["base_instructions"], json!("claude instructions"));
        assert_eq!(models[0]["experimental_supported_tools"], json!(["alpha"]));
        assert!(models[0].get("model_messages").is_none());
        assert_eq!(
            models[1]["model_messages"]["instructions_template"],
            json!("template instructions")
        );
        assert_eq!(models[1]["experimental_supported_tools"], json!(["clock"]));
    }

    #[test]
    fn catalog_injection_preserves_existing_tools_and_instructions() {
        let cache = models_cache_from_value(&fixture_cache()).expect("fixture cache");
        let mut models = vec![json!({
            "slug": "claude-sonnet-4-6",
            "base_instructions": "own instructions",
            "experimental_supported_tools": ["own-tool"]
        })];

        inject_catalog_schema(&mut models, Some(&cache));

        assert_eq!(models[0]["base_instructions"], json!("own instructions"));
        assert_eq!(
            models[0]["experimental_supported_tools"],
            json!(["own-tool"])
        );
    }

    #[test]
    fn catalog_injection_prefers_model_messages_over_base_instructions() {
        let cache = models_cache_from_value(&json!({
            "models": [{
                "slug": "gpt-6.1-sol",
                "model_messages": {"instructions_template": "preferred"},
                "base_instructions": "not used",
                "experimental_supported_tools": ["clock"]
            }]
        }))
        .expect("fixture cache");
        let mut models = vec![json!({"slug": "gpt-6.1-sol"})];

        inject_catalog_schema(&mut models, Some(&cache));

        assert_eq!(
            models[0]["model_messages"]["instructions_template"],
            json!("preferred")
        );
        assert!(models[0].get("base_instructions").is_none());
    }

    #[test]
    fn catalog_injection_falls_back_without_a_cache() {
        let mut models = vec![json!({"slug": "gpt-6.1-sol"})];

        inject_catalog_schema(&mut models, None);

        let instructions = models[0]["base_instructions"]
            .as_str()
            .expect("fallback instructions");
        assert!(!instructions.trim().is_empty());
        assert_eq!(
            models[0]["experimental_supported_tools"],
            json!(["send_user_message_async", "clock"])
        );
    }

    fn pool_account(selection: Option<Vec<&str>>) -> Account {
        Account {
            id: "pool-account".to_string(),
            selected_models: selection.map(|slugs| slugs.into_iter().map(String::from).collect()),
            ..Default::default()
        }
    }

    fn slugs_of(entries: &[Value]) -> Vec<&str> {
        entries.iter().filter_map(entry_slug).collect()
    }

    /// Fixture base catalog: two visible routes plus one hidden internal route.
    fn fixture_pool_base() -> Vec<Value> {
        vec![
            json!({
                "slug": "gpt-6.1-sol",
                "display_name": "GPT-6.1 Sol",
                "context_window": 272_000,
                "priority": 0
            }),
            json!({
                "slug": "claude-haiku-4-5-20251001",
                "display_name": "Claude Haiku 4.5",
                "context_window": 200_000,
                "priority": 8
            }),
            json!({
                "slug": "claude-opus-5-5",
                "display_name": "Claude Opus 5.5",
                "visibility": "hide",
                "context_window": 200_000
            }),
        ]
    }

    /// Fixture cache: a duplicate slug, a cache-only visible row, a hidden row.
    fn fixture_pool_cache() -> Vec<Value> {
        vec![
            json!({"slug": "gpt-6.1-sol", "display_name": "Cache Sol"}),
            json!({
                "slug": "gpt-6.1-cache-only",
                "display_name": "Cache Only",
                "priority": 9
            }),
            json!({
                "slug": "gpt-image-2.5",
                "display_name": "Cache Hidden",
                "visibility": "hide"
            }),
        ]
    }

    #[test]
    fn merged_pool_prefers_bundled_entries_and_keeps_cache_only_models() {
        let base = fixture_pool_base();
        let cache = fixture_pool_cache();

        let merged = merge_pool_entries(&base, &cache);

        // The bundled row wins the duplicate slug; the cache-only row is added.
        assert_eq!(
            slugs_of(&merged),
            vec![
                "gpt-6.1-sol",
                "claude-haiku-4-5-20251001",
                "gpt-6.1-cache-only"
            ]
        );
        assert_eq!(merged[0]["display_name"], json!("GPT-6.1 Sol"));

        // Hidden base and hidden cache rows are never offered as choices.
        let visible = visible_pool_slugs_in(&base, &cache);
        let expected: HashSet<String> = [
            "gpt-6.1-sol",
            "claude-haiku-4-5-20251001",
            "gpt-6.1-cache-only",
        ]
        .iter()
        .map(|slug| slug.to_string())
        .collect();
        assert_eq!(visible, expected);

        let ordered: Vec<String> = pool_models_in(&base, &cache)
            .into_iter()
            .map(|model| model.slug)
            .collect();
        assert_eq!(
            ordered,
            vec![
                "gpt-6.1-sol",
                "claude-haiku-4-5-20251001",
                "gpt-6.1-cache-only"
            ]
        );
    }

    #[test]
    fn account_selection_helpers_follow_the_visible_pool() {
        let visible: HashSet<String> = [
            "gpt-6.1-sol",
            "claude-haiku-4-5-20251001",
            "gpt-6.1-cache-only",
        ]
        .iter()
        .map(|slug| slug.to_string())
        .collect();
        let legacy = pool_account(None);
        let restricted = pool_account(Some(vec![
            " gpt-6.1-sol ",
            "claude-haiku-4-5-20251001",
            "unknown-model",
        ]));
        let restricted_effective: HashSet<String> = ["gpt-6.1-sol", "claude-haiku-4-5-20251001"]
            .iter()
            .map(|slug| slug.to_string())
            .collect();

        assert_eq!(effective_selected_models(&legacy, &visible), visible);
        assert_eq!(
            effective_selected_models(&restricted, &visible),
            restricted_effective
        );

        // No accounts means the whole pool; an explicit list is an allowlist.
        assert_eq!(selected_pool_slugs_in(&[], &visible), visible);
        assert_eq!(selected_pool_slugs_in(&[legacy], &visible), visible);
        assert_eq!(
            selected_pool_slugs_in(std::slice::from_ref(&restricted), &visible),
            restricted_effective
        );

        // Exclusions are the visible pool minus the selection, sorted.
        assert_eq!(
            excluded_models_for(&restricted, &visible),
            vec!["gpt-6.1-cache-only"]
        );
        assert!(excluded_models_for(&pool_account(None), &visible).is_empty());
    }

    #[test]
    fn catalog_build_filters_visible_entries_and_keeps_hidden_routes() {
        let base = fixture_pool_base();
        let selected: HashSet<String> = ["gpt-6.1-sol".to_string()].into_iter().collect();

        let (models, custom) =
            build_catalog_models(&base, &[], Vec::new(), Some(&selected)).expect("catalog");

        // The unselected visible row is dropped; the hidden route always stays.
        assert_eq!(slugs_of(&models), vec!["gpt-6.1-sol", "claude-opus-5-5"]);
        assert_eq!(custom, 0);
    }

    #[test]
    fn catalog_build_keeps_hidden_cache_only_entries_once() {
        let base = fixture_pool_base();
        let cache = vec![
            json!({
                "slug": "gpt-image-2.5",
                "display_name": "Cache Hidden",
                "visibility": "hide"
            }),
            json!({
                "slug": "gpt-image-2.5",
                "display_name": "Cache Hidden Duplicate",
                "visibility": "hide"
            }),
            json!({
                "slug": "claude-opus-5-5",
                "display_name": "Cache Hidden Base Duplicate",
                "visibility": "hide"
            }),
            json!({"slug": "gpt-6.1-cache-only", "display_name": "Cache Only"}),
        ];
        let selected: HashSet<String> =
            ["gpt-6.1-sol".to_string(), "gpt-6.1-cache-only".to_string()]
                .into_iter()
                .collect();

        let (models, custom) =
            build_catalog_models(&base, &cache, Vec::new(), Some(&selected)).expect("catalog");

        // The hidden cache-only row survives next to the hidden base route.
        assert_eq!(
            slugs_of(&models),
            vec![
                "gpt-6.1-sol",
                "gpt-6.1-cache-only",
                "claude-opus-5-5",
                "gpt-image-2.5"
            ]
        );
        assert_eq!(custom, 0);
        // The duplicate hidden cache slug is not repeated.
        assert_eq!(
            models
                .iter()
                .filter(|entry| entry_slug(entry) == Some("gpt-image-2.5"))
                .count(),
            1
        );
        // The bundled hidden base row stays authoritative over the cache copy.
        let opus: Vec<&Value> = models
            .iter()
            .filter(|entry| entry_slug(entry) == Some("claude-opus-5-5"))
            .collect();
        assert_eq!(opus.len(), 1);
        assert_eq!(opus[0]["display_name"], json!("Claude Opus 5.5"));
    }

    #[test]
    fn pool_models_skip_unsafe_slugs() {
        let base = vec![
            json!({"slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol"}),
            json!({"slug": "evil');alert(1)//", "display_name": "Injected"}),
            json!({"slug": "evil slug", "display_name": "Spaced"}),
        ];
        let cache = vec![
            json!({"slug": "opencode/glm-5.3", "display_name": "GLM"}),
            json!({"slug": "gpt-6.1-sol", "display_name": "Cache Duplicate"}),
        ];

        let mut slugs: Vec<String> = pool_models_in(&base, &cache)
            .into_iter()
            .map(|model| model.slug)
            .collect();
        slugs.sort();

        // Only the ids made of the safe ASCII set survive.
        assert_eq!(slugs, vec!["gpt-6.1-sol", "opencode/glm-5.3"]);
    }

    #[test]
    fn route_preserves_third_party_providers_and_adds_legacy_alias() {
        let input = "model_provider = \"openai\"\n\n\
[model_providers.cockpit]\n\
name = \"Cockpit\"\n\
base_url = \"http://127.0.0.1:4000/v1\"\n\n\
[model_providers.other]\n\
name = \"Other\"\n\
base_url = \"http://127.0.0.1:4001/v1\"\n";
        let base_url = "http://127.0.0.1:18317/v1";
        let output = upsert_route(input, base_url, "test-key");

        assert!(output.contains("[model_providers.cockpit]"));
        assert!(output.contains("[model_providers.other]"));
        assert!(output.contains(&format!("[model_providers.{}]", PROVIDER_ID)));
        assert!(output.contains(&format!("[model_providers.{}]", LEGACY_PROVIDER_ID)));
        assert!(output.contains(&format!("base_url = \"{}\"", base_url)));
        assert!(output.contains("experimental_bearer_token = \"test-key\""));

        let again = upsert_route(&output, base_url, "test-key");
        assert_eq!(again, output, "upsert_route must be idempotent");
    }

    #[test]
    fn route_removal_keeps_third_party_providers_and_legacy_alias() {
        let input = "model_provider = \"openai\"\n\n\
[model_providers.cockpit]\n\
name = \"Cockpit\"\n\
base_url = \"http://127.0.0.1:4000/v1\"\n";
        let applied = upsert_route(input, "http://127.0.0.1:18317/v1", "test-key");
        let removed = remove_route(&applied);

        assert!(removed.contains("[model_providers.cockpit]"));
        assert!(!removed.contains(&format!("[model_providers.{}]", PROVIDER_ID)));
        assert!(removed.contains(&format!("[model_providers.{}]", LEGACY_PROVIDER_ID)));
        assert!(!removed.contains(&format!("model_provider = \"{}\"", PROVIDER_ID)));
    }

    #[test]
    fn legacy_alias_tracks_the_current_gateway() {
        let applied = upsert_route("", "http://127.0.0.1:18317/v1", "old-key");
        let moved = upsert_route(&applied, "http://127.0.0.1:19000/v1", "new-key");
        assert!(moved.contains("http://127.0.0.1:19000/v1"));
        assert!(!moved.contains("http://127.0.0.1:18317/v1"));
        assert_eq!(
            moved
                .matches(&format!("[model_providers.{}]", LEGACY_PROVIDER_ID))
                .count(),
            1
        );
    }

    #[test]
    fn catalog_build_reserves_hidden_and_unselected_pool_slugs() {
        let base = fixture_pool_base();
        let selected: HashSet<String> = ["gpt-6.1-sol".to_string()].into_iter().collect();
        // These ids carry a third-party band, so only the pool reservation keeps
        // them out of the generated third-party entries.
        let gateway_entries = vec![
            json!({"id": "opencode/glm-5.3", "owned_by": "opencode"}),
            json!({"id": "claude-haiku-4-5-20251001", "owned_by": "anthropic"}),
            json!({"id": "claude-opus-5-5", "owned_by": "anthropic"}),
        ];

        let (models, custom) =
            build_catalog_models(&base, &[], gateway_entries, Some(&selected)).expect("catalog");

        // Both the unselected visible slug and the hidden slug keep their rows.
        assert_eq!(
            slugs_of(&models),
            vec!["gpt-6.1-sol", "claude-opus-5-5", "opencode/glm-5.3"]
        );
        assert_eq!(custom, 1);
    }
}
