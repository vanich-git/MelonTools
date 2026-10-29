//! Bulk account import for Cockpit/CPA and sub2api JSON exports.
//!
//! OpenAI entries become Codex vault accounts; Claude and Antigravity entries
//! are written as engine auth files. One export may carry all three platforms.

use serde_json::{json, Map, Value};

use crate::paths;
use crate::provider_import::{self, ProviderCredential};
use crate::vault::{self, Account, Tokens};

pub struct Parsed {
    pub accounts: Vec<Account>,
    pub providers: Vec<ProviderCredential>,
    pub skipped: usize,
}

pub fn import_json(content: &str) -> Result<Value, String> {
    let parsed = parse(content)?;
    let count = parsed.accounts.len();
    let (added, updated) = vault::import_accounts(parsed.accounts)?;
    let (claude, antigravity) = provider_import::write_all(&parsed.providers, &paths::auths_dir())?;
    Ok(json!({
        "imported": count,
        "added": added,
        "updated": updated,
        "skipped": parsed.skipped,
        "claude": claude,
        "antigravity": antigravity,
    }))
}

/// Parse either a flat Cockpit/CPA array, a `sub2api-data` object, or one
/// legacy `auth.json` object. OpenAI, Claude and Antigravity entries are
/// accepted; unknown platforms are counted as skipped.
pub fn parse(content: &str) -> Result<Parsed, String> {
    let root: Value = serde_json::from_str(content)
        .map_err(|_| "файл не является корректным JSON".to_string())?;
    let entries: Vec<&Map<String, Value>> = if let Some(array) = root.as_array() {
        array.iter().filter_map(Value::as_object).collect()
    } else if let Some(object) = root.as_object() {
        if let Some(accounts) = object.get("accounts").and_then(Value::as_array) {
            accounts.iter().filter_map(Value::as_object).collect()
        } else if object.contains_key("access_token") || object.contains_key("tokens") {
            vec![object]
        } else {
            return Err("поддерживается массив Cockpit/CPA или sub2api-data".to_string());
        }
    } else {
        return Err("файл не является корректным JSON".to_string());
    };

    let mut accounts = Vec::new();
    let mut providers = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut seen_providers = std::collections::HashSet::new();
    let mut skipped = 0;
    for entry in entries {
        let platform = entry
            .get("platform")
            .and_then(Value::as_str)
            .or_else(|| entry.get("provider").and_then(Value::as_str))
            .unwrap_or("");
        let declared_type = entry.get("type").and_then(Value::as_str).unwrap_or("");
        let provider_kind = provider_import::kind_for_platform(platform).or_else(|| {
            if platform.is_empty() {
                provider_import::kind_for_platform(declared_type)
            } else {
                None
            }
        });
        if let Some(kind) = provider_kind {
            let Some(credential) = provider_import::parse(entry, kind) else {
                skipped += 1;
                continue;
            };
            if !seen_providers.insert(credential.dedupe_key()) {
                skipped += 1;
                continue;
            }
            providers.push(credential);
            continue;
        }
        if !platform.is_empty()
            && !platform.eq_ignore_ascii_case("openai")
            && !platform.eq_ignore_ascii_case("codex")
        {
            skipped += 1;
            continue;
        }
        let Some(account) = parse_account(entry) else {
            skipped += 1;
            continue;
        };
        let key = account
            .account_id
            .clone()
            .or_else(|| account.email.clone())
            .unwrap_or_else(|| account.id.clone())
            .to_lowercase();
        if !key.is_empty() && !seen.insert(key) {
            skipped += 1;
            continue;
        }
        accounts.push(account);
    }
    if accounts.is_empty() && providers.is_empty() {
        return Err("не найдено ни одного аккаунта с токенами".to_string());
    }
    Ok(Parsed {
        accounts,
        providers,
        skipped,
    })
}

fn parse_account(entry: &Map<String, Value>) -> Option<Account> {
    let flat = entry
        .get("credentials")
        .and_then(Value::as_object)
        .or_else(|| entry.get("tokens").and_then(Value::as_object))
        .unwrap_or(entry);

    fn text(map: &Map<String, Value>, keys: &[&str]) -> Option<String> {
        keys.iter().find_map(|key| {
            map.get(*key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(String::from)
        })
    }

    let access = text(flat, &["access_token"]);
    let refresh = text(flat, &["refresh_token"]);
    if access.is_none() && refresh.is_none() {
        return None;
    }
    let id_token = text(flat, &["id_token"]);
    let account_id = text(flat, &["chatgpt_account_id", "account_id"])
        .or_else(|| text(entry, &["account_id", "chatgpt_account_id"]));
    let email = text(flat, &["email"])
        .or_else(|| text(entry, &["email"]))
        .or_else(|| text(entry, &["name"]).filter(|name| name.contains('@')));
    let claims = vault::jwt_claims(id_token.as_deref());
    let mut tokens = Tokens {
        id_token,
        access_token: access,
        refresh_token: refresh,
        account_id: account_id.clone(),
    };
    if claims.account_id.is_some() {
        tokens.account_id = claims.account_id.clone();
    }
    Some(Account {
        id: vault::new_account_id(),
        email: claims.email.or(email),
        plan_type: claims.plan_type.or_else(|| text(entry, &["plan_type"])),
        account_id: claims.account_id.or(account_id),
        user_id: claims.user_id,
        subscription_active_until: claims.subscription_until,
        tokens,
        last_refresh: text(entry, &["last_refresh"]),
        ..Account::default()
    })
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn cockpit_array_keeps_refresh_token_and_account_id() {
        let text = r#"[
          {"email":"user@example.com","account_id":"acct-1","access_token":"a","refresh_token":"r","id_token":"i"}
        ]"#;
        let parsed = parse(text).unwrap();
        assert_eq!(parsed.skipped, 0);
        assert_eq!(
            parsed.accounts[0].tokens.refresh_token.as_deref(),
            Some("r")
        );
        assert_eq!(
            parsed.accounts[0].tokens.account_id.as_deref(),
            Some("acct-1")
        );
        assert_eq!(
            parsed.accounts[0].email.as_deref(),
            Some("user@example.com")
        );
    }

    #[test]
    fn sub2api_imports_openai_claude_and_antigravity() {
        let text = r#"{
          "type":"sub2api-data","version":1,
          "accounts":[
            {"platform":"openai","credentials":{"email":"a@b.c","chatgpt_account_id":"acct-2","access_token":"a2","refresh_token":"r2"}},
            {"platform":"anthropic","credentials":{"email":"claude@example.com","access_token":"x","refresh_token":"y"}},
            {"platform":"antigravity","credentials":{"email":"google@example.com","access_token":"g","refresh_token":"gr","project_id":"p"}}
          ]
        }"#;
        let parsed = parse(text).unwrap();
        assert_eq!(parsed.accounts.len(), 1);
        assert_eq!(parsed.providers.len(), 2);
        assert_eq!(parsed.skipped, 0);
        assert_eq!(
            parsed.accounts[0].tokens.refresh_token.as_deref(),
            Some("r2")
        );
        assert_eq!(parsed.accounts[0].account_id.as_deref(), Some("acct-2"));
        assert_eq!(
            parsed.providers[0].email.as_deref(),
            Some("claude@example.com")
        );
        assert_eq!(parsed.providers[1].project_id.as_deref(), Some("p"));
    }

    #[test]
    fn provider_only_export_is_accepted() {
        let text = r#"[
          {"platform":"claude","access_token":"x","refresh_token":"y","email":"c@example.com"}
        ]"#;
        let parsed = parse(text).unwrap();
        assert!(parsed.accounts.is_empty());
        assert_eq!(parsed.providers.len(), 1);
    }

    #[test]
    fn unknown_platforms_are_skipped() {
        let text = r#"[
          {"platform":"openai","access_token":"a","refresh_token":"r"},
          {"platform":"gemini","access_token":"g","refresh_token":"gr"}
        ]"#;
        let parsed = parse(text).unwrap();
        assert_eq!(parsed.accounts.len(), 1);
        assert!(parsed.providers.is_empty());
        assert_eq!(parsed.skipped, 1);
    }

    #[test]
    fn missing_tokens_are_rejected() {
        assert!(parse(r#"[{"email":"a@b.c"}]"#).is_err());
        assert!(parse("[]").is_err());
    }
}
