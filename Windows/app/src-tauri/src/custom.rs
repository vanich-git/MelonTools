//! User-defined provider identifiers, base URLs and protocol routing.
//!
//! The gateway appends its own path to the base URL, so the stored value must
//! be normalized exactly once: `/chat/completions` for OpenAI-compatible
//! endpoints, `/responses` for the Responses API, `/v1/messages` for Anthropic
//! and `/v1beta/models` for Gemini. Anthropic and Gemini reject a duplicated
//! version prefix, hence the trim below.

/// Identifiers owned by built-in providers. A custom provider would shadow
/// their model namespace and their settings card, so the form refuses them.
pub const RESERVED_IDENTIFIERS: [&str; 11] = [
    "openrouter",
    "opencode",
    "commandcode",
    "deepinfra",
    "nvidia",
    "vercel",
    "zai",
    "claude",
    "antigravity",
    "local",
    "melon-local-ai",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protocol {
    OpenAIChat,
    OpenAIResponses,
    Anthropic,
    Gemini,
}

impl Protocol {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value.trim() {
            "openai-chat" => Ok(Self::OpenAIChat),
            "openai-responses" => Ok(Self::OpenAIResponses),
            "anthropic" => Ok(Self::Anthropic),
            "gemini" => Ok(Self::Gemini),
            other => Err(format!("неизвестный протокол: {other}")),
        }
    }
}

pub fn valid_identifier(value: &str) -> Result<(), String> {
    let bytes = value.as_bytes();
    if !(2..=32).contains(&bytes.len()) {
        return Err("идентификатор должен содержать от 2 до 32 символов".to_string());
    }
    if !bytes[0].is_ascii_lowercase() {
        return Err("идентификатор должен начинаться со строчной латинской буквы".to_string());
    }
    if !bytes[1..]
        .iter()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
    {
        return Err(
            "идентификатор может содержать только строчные буквы, цифры и дефис".to_string(),
        );
    }
    if RESERVED_IDENTIFIERS.contains(&value) {
        return Err("этот идентификатор занят встроенным поставщиком".to_string());
    }
    Ok(())
}

/// Trims whitespace and the trailing slash, rejects non-http(s) URLs, userinfo,
/// queries and fragments, then removes the version prefix the gateway adds
/// itself for Anthropic and Gemini.
pub fn normalize_base_url(raw: &str, protocol: Protocol) -> Result<String, String> {
    let mut value = raw.trim().trim_end_matches('/').to_string();
    let parsed = reqwest::Url::parse(&value).map_err(|_| "некорректный базовый URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("базовый URL должен начинаться с http:// или https://".to_string());
    }
    if parsed.host_str().is_none() {
        return Err("в базовом URL нет хоста".to_string());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("базовый URL не должен содержать логин или пароль".to_string());
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err("базовый URL не должен содержать параметры или якорь".to_string());
    }
    match protocol {
        Protocol::Anthropic => {
            if let Some(stripped) = value.strip_suffix("/v1") {
                value = stripped.to_string();
            }
        }
        Protocol::Gemini => {
            if let Some(stripped) = value.strip_suffix("/v1beta") {
                value = stripped.to_string();
            } else if let Some(stripped) = value.strip_suffix("/v1") {
                value = stripped.to_string();
            }
        }
        Protocol::OpenAIChat | Protocol::OpenAIResponses => {}
    }
    Ok(value)
}

/// Model listing URL for the form's "get available models" action.
pub fn models_url(base: &str, protocol: Protocol) -> Result<String, String> {
    let base = normalize_base_url(base, protocol)?;
    let suffix = match protocol {
        Protocol::OpenAIChat | Protocol::OpenAIResponses => "/models",
        Protocol::Anthropic => "/v1/models",
        Protocol::Gemini => "/v1beta/models",
    };
    Ok(format!("{base}{suffix}"))
}

pub fn model_alias(identifier: &str, model_id: &str) -> String {
    format!("{identifier}/{model_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_match_the_form_contract() {
        assert!(valid_identifier("acme").is_ok());
        assert!(valid_identifier("acme-2").is_ok());
        assert!(valid_identifier("a").is_err());
        assert!(valid_identifier("Acme").is_err());
        assert!(valid_identifier("2acme").is_err());
        assert!(valid_identifier("acme_gateway").is_err());
        assert!(valid_identifier("claude").is_err());
        assert!(valid_identifier("openrouter").is_err());
    }

    #[test]
    fn base_urls_are_normalized_per_protocol() {
        assert_eq!(
            normalize_base_url(" https://relay.example/v1/ ", Protocol::OpenAIChat).unwrap(),
            "https://relay.example/v1"
        );
        assert_eq!(
            normalize_base_url("https://api.anthropic.com/v1", Protocol::Anthropic).unwrap(),
            "https://api.anthropic.com"
        );
        assert_eq!(
            normalize_base_url(
                "https://generativelanguage.googleapis.com/v1beta",
                Protocol::Gemini
            )
            .unwrap(),
            "https://generativelanguage.googleapis.com"
        );
        assert_eq!(
            normalize_base_url(
                "https://generativelanguage.googleapis.com/v1",
                Protocol::Gemini
            )
            .unwrap(),
            "https://generativelanguage.googleapis.com"
        );
        assert!(normalize_base_url("ftp://relay.example", Protocol::OpenAIChat).is_err());
        assert!(normalize_base_url("relay.example/v1", Protocol::OpenAIChat).is_err());
        assert!(normalize_base_url("https://relay.example/v1?x=1", Protocol::OpenAIChat).is_err());
        assert!(
            normalize_base_url("https://user:pass@relay.example", Protocol::OpenAIChat).is_err()
        );
    }

    #[test]
    fn model_listing_urls_do_not_duplicate_the_version() {
        assert_eq!(
            models_url("https://relay.example/v1", Protocol::OpenAIChat).unwrap(),
            "https://relay.example/v1/models"
        );
        assert_eq!(
            models_url("https://relay.example/v1", Protocol::OpenAIResponses).unwrap(),
            "https://relay.example/v1/models"
        );
        assert_eq!(
            models_url("https://api.anthropic.com/v1", Protocol::Anthropic).unwrap(),
            "https://api.anthropic.com/v1/models"
        );
        assert_eq!(
            models_url("https://gemini.example/v1beta", Protocol::Gemini).unwrap(),
            "https://gemini.example/v1beta/models"
        );
    }

    #[test]
    fn aliases_are_provider_scoped() {
        assert_eq!(model_alias("acme", "gpt-5"), "acme/gpt-5");
    }
}
