//! Official llama.cpp Windows builds published on GitHub.
//!
//! The catalog is read-only: it lists release assets and their published
//! SHA-256 digests so the UI can hand a verified URL to `RuntimeInstaller`
//! without asking the user to copy a hash by hand.

use serde::{Deserialize, Serialize};
use std::time::Duration;

const RELEASES_URL: &str = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30";
const USER_AGENT: &str = "MelonTools/6.0.0";
/// GitHub returns releases newest first; the UI keeps that order.
const MAX_RELEASES: usize = 20;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(25);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeCatalogRelease {
    pub tag: String,
    pub title: String,
    pub published_at: String,
    pub variants: Vec<RuntimeCatalogVariant>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeCatalogVariant {
    /// Stable within the release: `cpu` or `vulkan`.
    pub id: String,
    pub label: String,
    pub size_bytes: u64,
    /// Lowercase hex without the `sha256:` prefix.
    pub sha256: String,
    pub url: String,
}

#[derive(Deserialize)]
struct GitHubRelease {
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    published_at: Option<String>,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    #[serde(default)]
    name: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    digest: Option<String>,
    #[serde(default)]
    browser_download_url: String,
}

struct WindowsVariant {
    id: &'static str,
    label: &'static str,
    slug: &'static str,
}

/// CUDA/ROCm/SYCL need the separate cudart package, so only the
/// self-contained x64 builds are offered for now.
const WINDOWS_VARIANTS: [WindowsVariant; 2] = [
    WindowsVariant {
        id: "cpu",
        label: "CPU (x64)",
        slug: "cpu",
    },
    WindowsVariant {
        id: "vulkan",
        label: "Vulkan (x64)",
        slug: "vulkan",
    },
];

fn variant_asset_name(tag: &str, slug: &str) -> String {
    format!("llama-{tag}-bin-win-{slug}-x64.zip")
}

fn parse_asset_sha256(digest: Option<&str>) -> Option<String> {
    let hex = digest?.trim().strip_prefix("sha256:")?;
    if hex.len() != 64 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    Some(hex.to_ascii_lowercase())
}

fn is_https_url(raw: &str) -> bool {
    url::Url::parse(raw)
        .map(|parsed| parsed.scheme() == "https" && parsed.host_str().is_some())
        .unwrap_or(false)
}

fn build_catalog(releases: Vec<GitHubRelease>) -> Vec<RuntimeCatalogRelease> {
    let mut catalog = Vec::new();

    for release in releases {
        // Nightly builds are published as prereleases, so only drafts are
        // filtered out.
        if release.draft {
            continue;
        }
        let tag = release.tag_name.trim();
        if tag.is_empty() {
            continue;
        }

        let mut variants = Vec::new();
        for variant in &WINDOWS_VARIANTS {
            let expected_name = variant_asset_name(tag, variant.slug);
            let Some(asset) = release
                .assets
                .iter()
                .find(|asset| asset.name == expected_name)
            else {
                continue;
            };
            let Some(sha256) = parse_asset_sha256(asset.digest.as_deref()) else {
                continue;
            };
            if asset.size == 0 || !is_https_url(&asset.browser_download_url) {
                continue;
            }
            variants.push(RuntimeCatalogVariant {
                id: variant.id.to_string(),
                label: variant.label.to_string(),
                size_bytes: asset.size,
                sha256,
                url: asset.browser_download_url.clone(),
            });
        }

        if variants.is_empty() {
            continue;
        }

        let title = release
            .name
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(tag)
            .to_string();

        catalog.push(RuntimeCatalogRelease {
            tag: tag.to_string(),
            title,
            published_at: release.published_at.unwrap_or_default(),
            variants,
        });

        if catalog.len() == MAX_RELEASES {
            break;
        }
    }

    catalog
}

/// Parses the GitHub releases response. Kept pure so the filtering rules are
/// tested without touching the network.
pub fn parse_catalog(body: &[u8]) -> Result<Vec<RuntimeCatalogRelease>, String> {
    let releases: Vec<GitHubRelease> = serde_json::from_slice(body)
        .map_err(|error| format!("GitHub releases response could not be parsed: {error}"))?;
    Ok(build_catalog(releases))
}

fn request_error(status: reqwest::StatusCode) -> String {
    if status == reqwest::StatusCode::FORBIDDEN || status == reqwest::StatusCode::TOO_MANY_REQUESTS
    {
        return format!(
            "GitHub API rate limit reached while loading runtime builds (HTTP {}). Try again later.",
            status.as_u16()
        );
    }
    format!("GitHub releases request failed: HTTP {}", status.as_u16())
}

pub async fn fetch_catalog() -> Result<Vec<RuntimeCatalogRelease>, String> {
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|error| format!("GitHub releases client failed: {error}"))?;

    let response = client
        .get(RELEASES_URL)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .header(reqwest::header::USER_AGENT, USER_AGENT)
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send()
        .await
        .map_err(|error| format!("GitHub releases request failed: {error}"))?;

    let status = response.status();
    if !status.is_success() {
        return Err(request_error(status));
    }

    let body = response
        .bytes()
        .await
        .map_err(|error| format!("GitHub releases response could not be read: {error}"))?;
    parse_catalog(&body)
}

#[cfg(test)]
mod tests {
    use super::{parse_catalog, request_error, variant_asset_name, RuntimeCatalogRelease};
    use serde_json::json;

    const TAG: &str = "b12102";
    const SHA_CPU: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const SHA_VULKAN: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

    fn asset(name: &str, size: u64, digest: &str, url: &str) -> serde_json::Value {
        json!({
            "name": name,
            "size": size,
            "digest": digest,
            "browser_download_url": url,
        })
    }

    fn windows_asset(tag: &str, slug: &str, sha: &str) -> serde_json::Value {
        let name = variant_asset_name(tag, slug);
        let url = format!("https://github.com/ggml-org/llama.cpp/releases/download/{tag}/{name}");
        asset(&name, 123_456_789, &format!("sha256:{sha}"), &url)
    }

    fn release(
        tag: &str,
        draft: bool,
        prerelease: bool,
        assets: Vec<serde_json::Value>,
    ) -> serde_json::Value {
        json!({
            "tag_name": tag,
            "name": tag,
            "published_at": "2026-11-04T09:12:53Z",
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets,
        })
    }

    fn parse_one(release: serde_json::Value) -> Vec<RuntimeCatalogRelease> {
        parse_catalog(&serde_json::to_vec(&json!([release])).unwrap()).unwrap()
    }

    #[test]
    fn catalog_keeps_x64_cpu_and_vulkan_and_ignores_cuda() {
        let body = json!([release(
            TAG,
            false,
            // llama.cpp publishes nightly builds as prereleases.
            true,
            vec![
                windows_asset(TAG, "cpu", SHA_CPU),
                windows_asset(TAG, "vulkan", SHA_VULKAN),
                windows_asset(TAG, "cuda-12.4", SHA_CPU),
                windows_asset(TAG, "cuda-13.4", SHA_VULKAN),
            ],
        )]);

        let releases = parse_catalog(&serde_json::to_vec(&body).unwrap()).unwrap();
        assert_eq!(releases.len(), 1);
        let release = &releases[0];
        assert_eq!(release.tag, TAG);
        assert_eq!(release.title, TAG);
        assert_eq!(release.published_at, "2026-11-04T09:12:53Z");
        let ids: Vec<&str> = release
            .variants
            .iter()
            .map(|variant| variant.id.as_str())
            .collect();
        assert_eq!(ids, ["cpu", "vulkan"]);
        assert_eq!(release.variants[0].sha256, SHA_CPU);
        assert_eq!(release.variants[1].sha256, SHA_VULKAN);
        assert_eq!(release.variants[0].size_bytes, 123_456_789);
        assert!(release.variants[0]
            .url
            .ends_with(&format!("/{TAG}/llama-{TAG}-bin-win-cpu-x64.zip")));
        assert!(release.variants[1]
            .url
            .ends_with(&format!("/{TAG}/llama-{TAG}-bin-win-vulkan-x64.zip")));
    }

    #[test]
    fn draft_release_is_dropped() {
        let releases = parse_one(release(
            TAG,
            true,
            false,
            vec![windows_asset(TAG, "cpu", SHA_CPU)],
        ));
        assert!(releases.is_empty());
    }

    #[test]
    fn assets_without_a_valid_digest_size_or_https_url_are_dropped() {
        let cpu_name = variant_asset_name(TAG, "cpu");
        let cases = [
            asset(
                &cpu_name,
                123,
                "",
                &format!("https://github.com/download/{cpu_name}"),
            ),
            asset(
                &cpu_name,
                123,
                "md5:0123456789abcdef0123456789abcdef",
                &format!("https://github.com/download/{cpu_name}"),
            ),
            asset(
                &cpu_name,
                123,
                &format!("sha256:{}", "a".repeat(63)),
                &format!("https://github.com/download/{cpu_name}"),
            ),
            asset(
                &cpu_name,
                0,
                &format!("sha256:{SHA_CPU}"),
                &format!("https://github.com/download/{cpu_name}"),
            ),
            asset(
                &cpu_name,
                123,
                &format!("sha256:{SHA_CPU}"),
                &format!("http://github.com/download/{cpu_name}"),
            ),
        ];

        for asset in cases {
            let releases = parse_one(release(TAG, false, false, vec![asset]));
            assert!(releases.is_empty(), "invalid asset must be dropped");
        }
    }

    #[test]
    fn release_without_a_supported_variant_is_dropped() {
        let unsupported = parse_one(release(
            TAG,
            false,
            false,
            vec![windows_asset(TAG, "cuda-12.4", SHA_CPU)],
        ));
        assert!(unsupported.is_empty());

        // The asset must match the release tag, not just the variant suffix.
        let mismatched_tag = parse_one(release(
            TAG,
            false,
            false,
            vec![windows_asset("b99999", "cpu", SHA_CPU)],
        ));
        assert!(mismatched_tag.is_empty());
    }

    #[test]
    fn catalog_is_limited_to_twenty_releases() {
        let releases: Vec<serde_json::Value> = (0..25)
            .map(|index| {
                let tag = format!("b{}", 12_000 + index);
                release(
                    &tag,
                    false,
                    false,
                    vec![windows_asset(&tag, "cpu", SHA_CPU)],
                )
            })
            .collect();
        let parsed = parse_catalog(&serde_json::to_vec(&releases).unwrap()).unwrap();

        assert_eq!(parsed.len(), 20);
        assert_eq!(parsed[0].tag, "b12000");
        assert_eq!(parsed[19].tag, "b12019");
    }

    #[test]
    fn catalog_rejects_malformed_json() {
        let error = parse_catalog(b"not json").unwrap_err();
        assert!(error.contains("could not be parsed"), "{error}");

        let error = parse_catalog(br#"{"message":"Not Found"}"#).unwrap_err();
        assert!(error.contains("could not be parsed"), "{error}");

        assert!(parse_catalog(b"[]").unwrap().is_empty());
    }

    #[test]
    fn catalog_serializes_with_camel_case_fields() {
        let releases = parse_one(release(
            TAG,
            false,
            false,
            vec![windows_asset(TAG, "cpu", SHA_CPU)],
        ));
        let value = serde_json::to_value(&releases[0]).unwrap();
        assert!(value.get("publishedAt").is_some());
        assert!(value["variants"][0].get("sizeBytes").is_some());
        assert_eq!(value["variants"][0]["sha256"].as_str().unwrap(), SHA_CPU);
    }

    #[test]
    fn rate_limit_statuses_produce_a_clear_message() {
        for status in [403, 429] {
            let message = request_error(reqwest::StatusCode::from_u16(status).unwrap());
            assert!(message.contains("rate limit"), "{message}");
            assert!(message.contains(&status.to_string()), "{message}");
        }
        let message = request_error(reqwest::StatusCode::from_u16(500).unwrap());
        assert!(message.contains("HTTP 500"), "{message}");
    }

    #[test]
    fn variant_asset_name_is_built_from_the_tag() {
        assert_eq!(
            variant_asset_name("b12102", "cpu"),
            "llama-b12102-bin-win-cpu-x64.zip"
        );
        assert_eq!(
            variant_asset_name("b12102", "vulkan"),
            "llama-b12102-bin-win-vulkan-x64.zip"
        );
    }
}
