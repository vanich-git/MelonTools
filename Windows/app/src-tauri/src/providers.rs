//! Provider metrics: OpenRouter balance, key limits and the Claude
//! (Anthropic) subscription status.

use serde_json::{json, Value};

use crate::antigravity;
use crate::claude;
use crate::settings::{ProviderModel, Settings};

fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

async fn http_json(client: &reqwest::Client, url: &str, key: &str) -> Result<Value, String> {
    let resp = client
        .get(url)
        .header("Authorization", format!("Bearer {}", key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "{}: {}",
            status.as_u16(),
            text.chars().take(200).collect::<String>()
        ));
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub async fn openrouter(key: &str) -> Result<Value, String> {
    if key.trim().is_empty() {
        return Err("ключ OpenRouter не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?;

    let credits = http_json(&client, "https://openrouter.ai/api/v1/credits", key).await?;
    let key_info = http_json(&client, "https://openrouter.ai/api/v1/key", key)
        .await
        .ok();

    let total = credits
        .pointer("/data/total_credits")
        .and_then(|v| v.as_f64());
    let usage = credits
        .pointer("/data/total_usage")
        .and_then(|v| v.as_f64());
    let remaining = match (total, usage) {
        (Some(t), Some(u)) => Some((t - u).max(0.0)),
        _ => None,
    };

    // OpenRouter reports money, not window percentages. Store the remaining
    // share of the purchased credit so the same sparkline scale works; skip
    // the sample when there is nothing to normalize against.
    if let Some(percent) = match (total, remaining) {
        (Some(total), Some(remaining)) if total > 0.0 => {
            Some((remaining / total * 100.0).clamp(0.0, 100.0))
        }
        _ => None,
    } {
        crate::history::record("openrouter", "openrouter", Some(percent), None);
    }

    Ok(json!({
        "totalCredits": total,
        "totalUsage": usage,
        "remaining": remaining,
        "label": key_info.as_ref().and_then(|k| k.pointer("/data/label")).and_then(|v| v.as_str()),
        "usage": key_info.as_ref().and_then(|k| k.pointer("/data/usage")).and_then(|v| v.as_f64()),
        "limit": key_info.as_ref().and_then(|k| k.pointer("/data/limit")).and_then(|v| v.as_f64()),
        "limitRemaining": key_info.as_ref().and_then(|k| k.pointer("/data/limit_remaining")).and_then(|v| v.as_f64()),
        "isFreeTier": key_info.as_ref().and_then(|k| k.pointer("/data/is_free_tier")).and_then(|v| v.as_bool()),
        "status": "ok",
    }))
}

/// DeepInfra has no balance endpoint for API keys. The key is validated
/// against `/v1/me`, then the public model list is filtered to chat models.
pub async fn deepinfra_models(key: &str) -> Result<Vec<ProviderModel>, String> {
    if key.trim().is_empty() {
        return Err("ключ DeepInfra не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let _ = http_json(&client, "https://api.deepinfra.com/v1/me", key).await?;
    let list = http_json(&client, "https://api.deepinfra.com/v1/openai/models", key).await?;
    Ok(parse_deepinfra_models(&list))
}

fn parse_deepinfra_models(value: &Value) -> Vec<ProviderModel> {
    let Some(entries) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut models: Vec<ProviderModel> = entries
        .iter()
        .filter(|entry| {
            entry
                .pointer("/metadata/tags")
                .and_then(Value::as_array)
                .map(|tags| {
                    tags.iter()
                        .filter_map(Value::as_str)
                        .any(|tag| tag.eq_ignore_ascii_case("chat"))
                })
                .unwrap_or(false)
        })
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?.to_string();
            let tags = entry.pointer("/metadata/tags").and_then(Value::as_array);
            let supports_images = tags.map(|tags| {
                tags.iter().filter_map(Value::as_str).any(|tag| {
                    tag.eq_ignore_ascii_case("vision") || tag.eq_ignore_ascii_case("vlm")
                })
            });
            let pricing = entry.pointer("/metadata/pricing");
            Some(ProviderModel {
                display: deepinfra_display(&id, entry.get("name").and_then(Value::as_str)),
                context_window: entry
                    .pointer("/metadata/context_length")
                    .and_then(Value::as_u64),
                prompt_per_token: number(pricing.and_then(|p| p.get("input_tokens")))
                    .map(|value| value / 1_000_000.0),
                completion_per_token: number(pricing.and_then(|p| p.get("output_tokens")))
                    .map(|value| value / 1_000_000.0),
                cache_read_per_token: number(pricing.and_then(|p| p.get("cache_read_tokens")))
                    .map(|value| value / 1_000_000.0),
                supports_images,
                anthropic_only: None,
                id,
            })
        })
        .collect();
    models.sort_by_key(|a| a.id.to_lowercase());
    models
}

fn deepinfra_display(id: &str, fallback: Option<&str>) -> String {
    if let Some(name) = fallback.map(str::trim).filter(|name| !name.is_empty()) {
        return name.to_string();
    }
    let tail = id.rsplit('/').next().unwrap_or(id);
    crate::codex_route::prettify(tail)
}

/// Vercel AI Gateway team-level credits. The key is an AI Gateway key, not a
/// personal Vercel token. `balance` and `total_used` are account-wide.
pub async fn vercel(key: &str) -> Result<Value, String> {
    if key.trim().is_empty() {
        return Err("ключ Vercel AI Gateway не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let credits = http_json(&client, "https://ai-gateway.vercel.sh/v1/credits", key).await?;
    Ok(vercel_metrics(&credits))
}

fn vercel_metrics(credits: &Value) -> Value {
    json!({
        "balance": number(credits.get("balance")),
        "totalUsed": number(credits.get("total_used")),
        "status": "ok",
    })
}

/// Fetches the public Vercel model list, validates the gateway key through the
/// credits endpoint and keeps language models only.
pub async fn vercel_models(key: &str) -> Result<Vec<ProviderModel>, String> {
    let _ = vercel(key).await?;
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let list = http_json(&client, "https://ai-gateway.vercel.sh/v1/models", key).await?;
    Ok(parse_vercel_models(&list))
}

fn parse_vercel_models(value: &Value) -> Vec<ProviderModel> {
    let Some(entries) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut models: Vec<ProviderModel> = entries
        .iter()
        .filter(|entry| {
            entry
                .get("type")
                .and_then(Value::as_str)
                .map(|kind| kind.eq_ignore_ascii_case("language"))
                .unwrap_or(false)
        })
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?.to_string();
            let display = entry
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| {
                    crate::codex_route::prettify(id.rsplit('/').next().unwrap_or(&id))
                });
            let supports_images = entry
                .pointer("/modalities/input")
                .or_else(|| entry.pointer("/architecture/input"))
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .any(|value| value.eq_ignore_ascii_case("image"))
                });
            let pricing = entry.get("pricing");
            Some(ProviderModel {
                id,
                display,
                context_window: entry
                    .get("context_window")
                    .and_then(Value::as_u64)
                    .or_else(|| entry.get("context_length").and_then(Value::as_u64)),
                prompt_per_token: number(pricing.and_then(|p| p.get("input"))),
                completion_per_token: number(pricing.and_then(|p| p.get("output"))),
                cache_read_per_token: number(pricing.and_then(|p| p.get("input_cache_read"))),
                supports_images,
                anthropic_only: None,
            })
        })
        .collect();
    models.sort_by_key(|a| a.id.to_lowercase());
    models
}

/// Z.ai GLM Coding Plan. The Coding-only endpoint is required for plan
/// quota; the general `/api/paas/v4` endpoint is billed per token.
pub const ZAI_BASE_URL: &str = "https://api.z.ai/api/coding/paas/v4";
pub const ZAI_MODELS_URL: &str = "https://api.z.ai/api/coding/paas/v4/models";

/// Current Coding Plan models, used when `/models` is missing or returns an
/// unexpected shape. Older ids are routed server-side to these two.
pub fn zai_models_fallback() -> Vec<ProviderModel> {
    [
        ("glm-5.3", "GLM-5.3", 1_000_000u64, false),
        ("glm-5.3-flash", "GLM-5.3 Flash", 1_000_000u64, true),
    ]
    .into_iter()
    .map(|(id, display, context, images)| ProviderModel {
        id: id.to_string(),
        display: display.to_string(),
        context_window: Some(context),
        supports_images: Some(images),
        ..Default::default()
    })
    .collect()
}

fn zai_supports_images(id: &str) -> Option<bool> {
    let lower = id.to_lowercase();
    if lower == "glm-5.3-flash" || lower.starts_with("glm-5.3-flash-") {
        return Some(true);
    }
    if lower.contains("vision") || lower.ends_with('v') || lower.contains("-v") {
        return Some(true);
    }
    if lower.starts_with("glm-5.3") {
        return Some(false);
    }
    None
}

pub async fn zai_models(key: &str) -> Result<Vec<ProviderModel>, String> {
    if key.trim().is_empty() {
        return Err("ключ Z.ai не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .get(ZAI_MODELS_URL)
        .bearer_auth(key)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Err(format!(
            "Z.ai: HTTP {} — {}",
            status.as_u16(),
            text.chars().take(200).collect::<String>()
        ));
    }
    if status.is_success() {
        if let Ok(value) = serde_json::from_str::<Value>(&text) {
            let models = parse_zai_models(&value);
            if !models.is_empty() {
                return Ok(models);
            }
        }
    }
    Ok(zai_models_fallback())
}

fn parse_zai_models(value: &Value) -> Vec<ProviderModel> {
    let entries = value
        .get("data")
        .and_then(Value::as_array)
        .or_else(|| value.get("models").and_then(Value::as_array));
    let Some(entries) = entries else {
        return Vec::new();
    };
    let mut models: Vec<ProviderModel> = entries
        .iter()
        .filter_map(|entry| {
            let id = entry
                .get("id")
                .and_then(Value::as_str)
                .or_else(|| entry.get("slug").and_then(Value::as_str))?
                .to_string();
            if id.is_empty() {
                return None;
            }
            let display = entry
                .get("name")
                .and_then(Value::as_str)
                .or_else(|| entry.get("display_name").and_then(Value::as_str))
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| {
                    crate::codex_route::prettify(id.rsplit('/').next().unwrap_or(&id))
                });
            let context_window = entry
                .get("context_length")
                .and_then(Value::as_u64)
                .or_else(|| entry.get("context_window").and_then(Value::as_u64))
                .or_else(|| {
                    entry
                        .pointer("/metadata/context_length")
                        .and_then(Value::as_u64)
                });
            let supports_images = entry
                .pointer("/architecture/input_modalities")
                .or_else(|| entry.pointer("/modalities/input"))
                .or_else(|| entry.get("input_modalities"))
                .or_else(|| entry.get("input"))
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .any(|value| value.eq_ignore_ascii_case("image"))
                })
                .or_else(|| zai_supports_images(&id));
            Some(ProviderModel {
                id,
                display,
                context_window,
                supports_images,
                ..Default::default()
            })
        })
        .collect();
    models.sort_by_key(|model| model.id.to_lowercase());
    models
}

/// OpenCode. `*‑free` ids are restricted to the OpenCode app itself, so the
/// catalogue drops them instead of routing requests that always fail.
pub const OPENCODE_MODELS_URL: &str = "https://opencode.ai/inference/v1/models";

pub async fn opencode_models(key: &str) -> Result<Vec<ProviderModel>, String> {
    if key.trim().is_empty() {
        return Err("ключ OpenCode не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let value = http_json(&client, OPENCODE_MODELS_URL, key).await?;
    let models = parse_opencode_models(&value);
    if models.is_empty() {
        return Err("OpenCode: пустой список моделей".to_string());
    }
    Ok(models)
}

fn parse_opencode_models(value: &Value) -> Vec<ProviderModel> {
    let Some(entries) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut models: Vec<ProviderModel> = entries
        .iter()
        .filter(|entry| {
            entry
                .get("type")
                .and_then(Value::as_str)
                .map(|kind| kind.eq_ignore_ascii_case("chat"))
                .unwrap_or(true)
        })
        .filter_map(|entry| {
            let id = entry.get("id").and_then(Value::as_str)?.to_string();
            if id.is_empty() || id.ends_with("-free") {
                return None;
            }
            let display = entry
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| crate::codex_route::prettify(&id));
            let context_window = entry.pointer("/limit/context").and_then(Value::as_u64);
            // `cost.*.price` is USD per million tokens.
            let per_million = |pointer: &str| {
                entry
                    .pointer(pointer)
                    .and_then(Value::as_f64)
                    .filter(|price| *price > 0.0)
                    .map(|price| price / 1_000_000.0)
            };
            let supports_images = entry
                .pointer("/modalities/input")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .any(|value| value.eq_ignore_ascii_case("image"))
                });
            Some(ProviderModel {
                id,
                display,
                context_window,
                prompt_per_token: per_million("/cost/text/input/price"),
                completion_per_token: per_million("/cost/text/output/price"),
                cache_read_per_token: per_million("/cost/text/input/cache/read"),
                supports_images,
                anthropic_only: None,
            })
        })
        .collect();
    models.sort_by_key(|model| model.id.to_lowercase());
    models
}

/// CommandCode. Claude ids are served only through the Anthropic `/messages`
/// endpoint, so they ride `api-keys.claude`; everything else is
/// OpenAI-compatible. The catalogue carries no prices.
pub const COMMANDCODE_BASE_URL: &str = "https://api.commandcode.ai/provider/v1";
pub const COMMANDCODE_MODELS_URL: &str = "https://api.commandcode.ai/provider/v1/models";

pub async fn commandcode_models(key: &str) -> Result<Vec<ProviderModel>, String> {
    if key.trim().is_empty() {
        return Err("ключ CommandCode не задан".to_string());
    }
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    // `/models` answers without auth, so a rejected key only shows up here
    // when the endpoint starts requiring it.
    let value = http_json(&client, COMMANDCODE_MODELS_URL, key).await?;
    let models = parse_commandcode_models(&value);
    if models.is_empty() {
        return Err("CommandCode: пустой список моделей".to_string());
    }
    Ok(models)
}

fn parse_commandcode_models(value: &Value) -> Vec<ProviderModel> {
    let Some(entries) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut models: Vec<ProviderModel> = entries
        .iter()
        .filter_map(|entry| {
            let id = entry.get("id").and_then(Value::as_str)?.to_string();
            if id.is_empty() {
                return None;
            }
            let display = entry
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| crate::codex_route::prettify(&id));
            let endpoints: Vec<&str> = entry
                .get("supported_endpoints")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let anthropic_only = endpoints
                .iter()
                .any(|endpoint| *endpoint == "/messages")
                && !endpoints
                    .iter()
                    .any(|endpoint| *endpoint == "/chat/completions");
            Some(ProviderModel {
                id,
                display,
                context_window: entry.get("context_length").and_then(Value::as_u64),
                anthropic_only: Some(anthropic_only),
                ..Default::default()
            })
        })
        .collect();
    models.sort_by_key(|model| model.id.to_lowercase());
    models
}

/// Claude (Anthropic) metrics for the Providers page: connection status, the
/// account email, the two quota windows and the model count the gateway
/// serves. Without an auth file the account is not connected; without a usage
/// answer every number stays `null` ("—") — nothing is fabricated.
pub async fn claude(settings: &Settings) -> Result<Value, String> {
    let model_count =
        antigravity::claude_models_without_antigravity(settings.port, &settings.api_key)
            .await
            .ok()
            .and_then(|value| value.get("count").and_then(|c| c.as_u64()))
            .unwrap_or(0) as usize;
    let Some(file) = claude::newest_auth_file() else {
        return Ok(claude_metrics(false, None, None, model_count, None));
    };
    let usage = claude::usage_snapshot(settings).await;
    if let Some(snapshot) = usage.as_ref() {
        crate::history::record(
            "claude",
            "claude",
            snapshot.five_hour_percent,
            snapshot.weekly_percent,
        );
    }
    Ok(claude_metrics(
        true,
        file.email.clone(),
        usage.as_ref(),
        model_count,
        None,
    ))
}

/// Assembles the Claude metrics object. Pure, so the nil-tolerance is
/// testable without a gateway.
pub fn claude_metrics(
    connected: bool,
    email: Option<String>,
    usage: Option<&claude::UsageSnapshot>,
    model_count: usize,
    error: Option<String>,
) -> Value {
    json!({
        "connected": connected,
        "email": email,
        "plan": usage.and_then(|u| u.plan.clone()),
        "fiveHourPercent": usage.and_then(|u| u.five_hour_percent),
        "fiveHourReset": usage.and_then(|u| u.five_hour_reset.clone()),
        "weeklyPercent": usage.and_then(|u| u.weekly_percent),
        "weeklyReset": usage.and_then(|u| u.weekly_reset.clone()),
        "modelCount": model_count,
        "updatedAt": usage.map(|_| chrono::Utc::now().to_rfc3339()),
        "error": error,
        "status": "ok",
    })
}

/// Antigravity metrics for the Providers page: connection status, account
/// identity (email, Google project id) and the model count. There is no
/// Antigravity quota endpoint, so no percentages are reported.
pub async fn antigravity(settings: &Settings) -> Result<Value, String> {
    let pool = crate::antigravity::account_views(settings).await;
    let accounts = pool
        .get("accounts")
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();
    let first = accounts.first();
    let mut models = std::collections::HashSet::new();
    for account in &accounts {
        if let Some(ids) = account.get("models").and_then(|value| value.as_array()) {
            for id in ids.iter().filter_map(|value| value.as_str()) {
                models.insert(id.to_string());
            }
        }
    }
    let connected = !accounts.is_empty();
    let email = first
        .and_then(|account| account.get("email"))
        .cloned()
        .unwrap_or(Value::Null);
    let project = first
        .and_then(|account| account.get("projectId"))
        .cloned()
        .unwrap_or(Value::Null);
    Ok(json!({
        "connected": connected,
        "email": email,
        "projectId": project,
        "modelCount": models.len(),
        "updatedAt": if connected { json!(chrono::Utc::now().to_rfc3339()) } else { Value::Null },
        "error": Value::Null,
        "status": "ok",
        "accounts": accounts,
        "catalogOnly": pool.get("catalogOnly").cloned().unwrap_or_else(|| json!([])),
        "lastQos": crate::gateway::last_qos_event(),
    }))
}

/// Assembles the Antigravity metrics object. Pure, so the nil-tolerance is
/// testable without a gateway. Test-only: the Tauri command in `main.rs`
/// builds the shipped object from the live pool.
#[cfg(test)]
pub fn antigravity_metrics(
    connected: bool,
    email: Option<String>,
    project_id: Option<String>,
    model_count: usize,
    error: Option<String>,
) -> Value {
    json!({
        "connected": connected,
        "email": email,
        "projectId": project_id,
        "modelCount": model_count,
        "updatedAt": connected.then(|| chrono::Utc::now().to_rfc3339()),
        "error": error,
        "status": "ok",
    })
}

#[cfg(test)]
mod tests {
    use super::{
        antigravity_metrics, claude_metrics, parse_commandcode_models, parse_deepinfra_models,
        parse_opencode_models, parse_vercel_models, parse_zai_models, vercel_metrics,
        zai_models_fallback, zai_supports_images,
    };
    use crate::claude::UsageSnapshot;
    use serde_json::json;

    // Shapes below are copied from live answers, so the parsers are pinned to
    // what the upstreams actually return.
    #[test]
    fn opencode_catalogue_is_filtered_and_priced_per_token() {
        let value = json!({
            "data": [
                {
                    "id": "claude-fable-5",
                    "name": "Claude Fable 5",
                    "type": "chat",
                    "modalities": { "input": ["text", "image"] },
                    "limit": { "context": 200000 },
                    "cost": {
                        "text": {
                            "input": { "price": 10.0 },
                            "output": { "price": 50.0 },
                            "input": { "price": 10.0, "cache": { "read": 1.0 } }
                        }
                    }
                },
                { "id": "beam-free", "name": "Beam Free", "type": "chat" },
                { "id": "embed-3", "name": "Embed 3", "type": "embedding" },
                { "id": "no-pricing", "type": "chat" }
            ]
        });
        let models = parse_opencode_models(&value);
        let ids: Vec<&str> = models.iter().map(|m| m.id.as_str()).collect();
        // `-free` ids and non-chat entries never reach the gateway.
        assert_eq!(ids, vec!["claude-fable-5", "no-pricing"]);
        let fable = &models[0];
        assert_eq!(fable.display, "Claude Fable 5");
        assert_eq!(fable.context_window, Some(200_000));
        assert_eq!(fable.prompt_per_token, Some(0.00001));
        assert_eq!(fable.completion_per_token, Some(0.00005));
        assert_eq!(fable.cache_read_per_token, Some(0.000001));
        assert_eq!(fable.supports_images, Some(true));
        let bare = &models[1];
        assert_eq!(bare.prompt_per_token, None);
        assert_eq!(bare.completion_per_token, None);
        assert_eq!(bare.context_window, None);
    }

    #[test]
    fn commandcode_catalogue_splits_the_anthropic_endpoint() {
        let value = json!({
            "object": "list",
            "data": [
                {
                    "id": "claude-sonnet-5-5",
                    "name": "Claude Sonnet 5.5",
                    "context_length": 1000000,
                    "supported_endpoints": ["/messages"]
                },
                {
                    "id": "gpt-6-astra",
                    "name": "GPT-6 Astra",
                    "context_length": 400000,
                    "supported_endpoints": ["/chat/completions", "/responses"]
                }
            ]
        });
        let models = parse_commandcode_models(&value);
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "claude-sonnet-5-5");
        assert_eq!(models[0].anthropic_only, Some(true));
        assert_eq!(models[0].context_window, Some(1_000_000));
        // No pricing exists on this endpoint, so none is invented.
        assert_eq!(models[0].prompt_per_token, None);
        assert_eq!(models[1].id, "gpt-6-astra");
        assert_eq!(models[1].anthropic_only, Some(false));
    }

    #[test]
    fn claude_metrics_without_account_stays_empty() {
        let value = claude_metrics(false, None, None, 0, None);
        assert_eq!(value["connected"], false);
        assert_eq!(value["email"], serde_json::Value::Null);
        assert_eq!(value["plan"], serde_json::Value::Null);
        assert_eq!(value["fiveHourPercent"], serde_json::Value::Null);
        assert_eq!(value["fiveHourReset"], serde_json::Value::Null);
        assert_eq!(value["weeklyPercent"], serde_json::Value::Null);
        assert_eq!(value["weeklyReset"], serde_json::Value::Null);
        assert_eq!(value["modelCount"], 0);
        assert_eq!(value["updatedAt"], serde_json::Value::Null);
    }

    #[test]
    fn claude_metrics_carry_the_snapshot_values() {
        let snapshot = UsageSnapshot {
            five_hour_percent: Some(87.5),
            five_hour_reset: Some("2026-10-19T20:00:00+00:00".to_string()),
            weekly_percent: None,
            weekly_reset: None,
            plan: Some("pro".to_string()),
        };
        let value = claude_metrics(
            true,
            Some("user@example.com".to_string()),
            Some(&snapshot),
            4,
            None,
        );
        assert_eq!(value["connected"], true);
        assert_eq!(value["email"], "user@example.com");
        assert_eq!(value["fiveHourPercent"], 87.5);
        assert_eq!(value["fiveHourReset"], "2026-10-19T20:00:00+00:00");
        assert_eq!(value["weeklyPercent"], serde_json::Value::Null);
        assert_eq!(value["plan"], "pro");
        assert_eq!(value["modelCount"], 4);
        assert!(value["updatedAt"].as_str().is_some());

        let failing = claude_metrics(true, None, None, 0, Some("нет связи".to_string()));
        assert_eq!(failing["error"], "нет связи");
        assert_eq!(failing["updatedAt"], serde_json::Value::Null);
    }

    #[test]
    fn antigravity_metrics_without_account_stays_empty() {
        let value = antigravity_metrics(false, None, None, 0, None);
        assert_eq!(value["connected"], false);
        assert_eq!(value["email"], serde_json::Value::Null);
        assert_eq!(value["projectId"], serde_json::Value::Null);
        assert_eq!(value["modelCount"], 0);
        assert_eq!(value["updatedAt"], serde_json::Value::Null);
        assert_eq!(value["error"], serde_json::Value::Null);
        assert_eq!(value["status"], "ok");
        // No quota keys: Antigravity exposes no quota endpoint.
        assert!(value.get("fiveHourPercent").is_none());
        assert!(value.get("weeklyPercent").is_none());
        assert!(value.get("plan").is_none());
    }

    #[test]
    fn antigravity_metrics_carry_identity_and_model_count() {
        let value = antigravity_metrics(
            true,
            Some("user@example.com".to_string()),
            Some("project-123".to_string()),
            11,
            None,
        );
        assert_eq!(value["connected"], true);
        assert_eq!(value["email"], "user@example.com");
        assert_eq!(value["projectId"], "project-123");
        assert_eq!(value["modelCount"], 11);
        assert!(value["updatedAt"].as_str().is_some());

        let failing = antigravity_metrics(true, None, None, 0, Some("нет связи".to_string()));
        assert_eq!(failing["error"], "нет связи");
        assert_eq!(failing["email"], serde_json::Value::Null);
        assert_eq!(failing["projectId"], serde_json::Value::Null);
    }

    #[test]
    fn deepinfra_keeps_chat_models_and_converts_per_million_prices() {
        let value = json!({"data":[
            {"id":"deepseek-ai/DeepSeek-V4","metadata":{
                "context_length":131072,
                "tags":["chat","vision"],
                "pricing":{"input_tokens":0.27,"output_tokens":1.1,"cache_read_tokens":0.027}
            }},
            {"id":"black-forest-labs/FLUX.1","metadata":{"tags":["image"]}},
            {"id":"text-only/model","metadata":{"tags":["chat"]}}
        ]});
        let models = parse_deepinfra_models(&value);
        assert_eq!(models.len(), 2);
        let chat = models
            .iter()
            .find(|m| m.id == "deepseek-ai/DeepSeek-V4")
            .unwrap();
        assert_eq!(chat.display, "DeepSeek V4");
        assert_eq!(chat.context_window, Some(131_072));
        assert!((chat.prompt_per_token.unwrap() - 0.00000027).abs() < 1e-12);
        assert_eq!(chat.supports_images, Some(true));
    }

    #[test]
    fn vercel_keeps_language_models_and_reads_per_token_prices() {
        let value = json!({"data":[
            {"id":"anthropic/claude-sonnet-4.6","name":"Claude Sonnet 4.6","type":"language",
             "context_window":200000,
             "pricing":{"input":"0.000003","output":"0.000015","input_cache_read":"0.0000003"},
             "modalities":{"input":["text","image"]}},
            {"id":"openai/gpt-image-1","type":"image"}
        ]});
        let models = parse_vercel_models(&value);
        assert_eq!(models.len(), 1);
        let model = &models[0];
        assert_eq!(model.display, "Claude Sonnet 4.6");
        assert_eq!(model.context_window, Some(200_000));
        assert_eq!(model.prompt_per_token, Some(0.000003));
        assert_eq!(model.completion_per_token, Some(0.000015));
        assert_eq!(model.cache_read_per_token, Some(0.0000003));
        assert_eq!(model.supports_images, Some(true));
    }

    #[test]
    fn vercel_metrics_reads_team_wallet_fields() {
        let value = vercel_metrics(&json!({"balance":"42.5","total_used":100}));
        assert_eq!(value["balance"], 42.5);
        assert_eq!(value["totalUsed"], 100.0);
        assert_eq!(value["status"], "ok");
    }

    #[test]
    fn zai_parses_openai_compatible_models_and_image_capability() {
        let value = json!({"data":[
            {"id":"glm-5.3","name":"GLM-5.3","context_length":1000000},
            {"id":"glm-5.3-flash","name":"GLM-5.3 Flash","context_window":1000000,
             "architecture":{"input_modalities":["text","image"]}}
        ]});
        let models = parse_zai_models(&value);
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "glm-5.3");
        assert_eq!(models[0].display, "GLM-5.3");
        assert_eq!(models[0].context_window, Some(1_000_000));
        assert_eq!(models[0].supports_images, Some(false));
        assert_eq!(models[1].id, "glm-5.3-flash");
        assert_eq!(models[1].supports_images, Some(true));
    }

    #[test]
    fn zai_fallback_catalog_matches_the_current_plan() {
        let models = zai_models_fallback();
        let ids: Vec<&str> = models.iter().map(|model| model.id.as_str()).collect();
        assert_eq!(ids, vec!["glm-5.3", "glm-5.3-flash"]);
        assert_eq!(models[0].supports_images, Some(false));
        assert_eq!(models[1].supports_images, Some(true));
    }

    #[test]
    fn zai_image_defaults_cover_flash_and_vision_ids() {
        assert_eq!(zai_supports_images("glm-5.3"), Some(false));
        assert_eq!(zai_supports_images("glm-5.3-flash"), Some(true));
        assert_eq!(zai_supports_images("glm-5.3-flash-high"), Some(true));
        assert_eq!(zai_supports_images("glm-4.6v"), Some(true));
        assert_eq!(zai_supports_images("some-other-model"), None);
    }
}
