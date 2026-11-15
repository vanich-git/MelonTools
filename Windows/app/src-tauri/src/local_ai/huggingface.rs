//! Hugging Face Hub API integration for discovering and inspecting GGUF models.

use super::hardware::{calculate_memory_estimation, detect_hardware, MemoryEstimation};
use super::local_models::LocalModelStore;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, OnceLock};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HFModelSearchResult {
    pub id: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub downloads: Option<i64>,
    pub likes: Option<i64>,
    #[serde(alias = "lastModified")]
    pub last_modified: Option<String>,
    pub tags: Option<Vec<String>>,
    pub private: Option<bool>,
}

/// One downloadable GGUF file. `name` is what the UI reads for the row title
/// and sends back as `filename`; the raw Hugging Face spelling (`rfilename`)
/// never leaves the backend, so the two sides cannot drift apart again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HFGGUFFile {
    /// `<repo path>/<file>` exactly as Hugging Face reports it (may contain a
    /// subdirectory), which is also the `filename` the download command takes.
    pub name: String,
    pub size: u64,
    /// Fully encoded resolve URL. The UI must pass this value through instead
    /// of rebuilding it from the name.
    pub download_url: String,
    pub quantization: String,
    pub estimation: MemoryEstimation,
    pub formatted_size: String,
    /// Authoritative LFS digest, when Hugging Face publishes one.
    pub sha256: Option<String>,
}

impl HFGGUFFile {
    /// Percent-encoded `resolve/main` URL. `#`/`?` in a repo file name would
    /// otherwise truncate the URL at the fragment or query.
    pub fn resolve_url(repo_id: &str, filename: &str) -> String {
        let mut url =
            url::Url::parse("https://huggingface.co/").expect("the Hugging Face base URL is valid");
        if let Ok(mut segments) = url.path_segments_mut() {
            for part in repo_id.split('/').filter(|part| !part.is_empty()) {
                segments.push(part);
            }
            segments.push("resolve").push("main");
            for part in filename.split('/').filter(|part| !part.is_empty()) {
                segments.push(part);
            }
        }
        url.to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HFModelDetails {
    pub id: String,
    pub author: String,
    pub description: String,
    pub downloads: i64,
    pub likes: i64,
    pub license: Option<String>,
    pub gguf_files: Vec<HFGGUFFile>,
    pub last_modified: Option<String>,
    pub tags: Vec<String>,
    pub architecture: Option<String>,
    pub parameters: Option<u64>,
    pub readme: Option<String>,
}

#[derive(Deserialize)]
struct HFRepoSibling {
    rfilename: String,
    size: Option<u64>,
    /// Large files report their size only here, next to the git LFS sha256.
    lfs: Option<HFRepoSiblingLfs>,
}

#[derive(Deserialize)]
struct HFRepoSiblingLfs {
    size: Option<u64>,
    sha256: Option<String>,
}

impl HFRepoSibling {
    /// Total byte size, preferring the LFS record over the top-level one.
    fn total_size(&self) -> u64 {
        self.lfs
            .as_ref()
            .and_then(|lfs| lfs.size)
            .or(self.size)
            .unwrap_or(0)
    }
}

#[derive(Deserialize)]
struct HFRepoResponse {
    id: String,
    author: Option<String>,
    description: Option<String>,
    downloads: Option<i64>,
    likes: Option<i64>,
    siblings: Option<Vec<HFRepoSibling>>,
    #[serde(rename = "lastModified")]
    last_modified: Option<String>,
    tags: Option<Vec<String>>,
    #[serde(rename = "cardData")]
    card_data: Option<serde_json::Value>,
    config: Option<serde_json::Value>,
    safetensors: Option<serde_json::Value>,
    gguf: Option<serde_json::Value>,
}

/// Upper bound on cached publishers. The catalogue can surface thousands of
/// owners over a long session; an unbounded map would grow with every page.
const AVATAR_CACHE_LIMIT: usize = 512;

/// Publisher → avatar URL plus insertion order, so the oldest entries can be
/// evicted once the cache reaches its limit.
struct AvatarCache {
    entries: HashMap<String, Option<String>>,
    order: VecDeque<String>,
}

impl AvatarCache {
    fn get(&self, owner: &str) -> Option<&Option<String>> {
        self.entries.get(owner)
    }

    fn insert(&mut self, owner: String, url: Option<String>) {
        if self.entries.insert(owner.clone(), url).is_none() {
            self.order.push_back(owner);
        }
        while self.entries.len() > AVATAR_CACHE_LIMIT {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            self.entries.remove(&oldest);
        }
    }
}

/// Outcome of resolving one publisher's avatar.
enum AvatarLookup {
    Found(String),
    /// Both endpoints answered successfully (2xx or 404) and the Hub has no
    /// avatar for this publisher. Cacheable: it is the real answer.
    Absent,
    /// Network error, 429/5xx or a malformed body. Never cached, so a retry
    /// after the rate limit or an outage can still succeed.
    Failed,
}

impl AvatarLookup {
    /// `Some(entry)` goes into the cache; `None` must be resolved again later.
    fn cache_entry(&self) -> Option<Option<String>> {
        match self {
            AvatarLookup::Found(url) => Some(Some(url.clone())),
            AvatarLookup::Absent => Some(None),
            AvatarLookup::Failed => None,
        }
    }

    fn into_url(self) -> Option<String> {
        match self {
            AvatarLookup::Found(url) => Some(url),
            AvatarLookup::Absent | AvatarLookup::Failed => None,
        }
    }
}

/// Publisher → avatar URL (`None` = Hub has no avatar for them). Shared across
/// every page render, so switching models or sorting the catalogue costs no
/// extra Hub requests.
fn avatar_cache() -> &'static Mutex<AvatarCache> {
    static CACHE: OnceLock<Mutex<AvatarCache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(AvatarCache {
            entries: HashMap::new(),
            order: VecDeque::new(),
        })
    })
}

pub struct HuggingFaceService;

impl HuggingFaceService {
    const BASE_URL: &'static str = "https://huggingface.co/api";

    fn search_url(
        query: &str,
        limit: usize,
        sort: &str,
        offset: usize,
    ) -> Result<url::Url, String> {
        let sort = match sort {
            "downloads" | "likes" | "lastModified" | "trendingScore" => sort,
            _ => return Err("Unsupported Hugging Face sort order".to_string()),
        };
        let mut url =
            url::Url::parse(&format!("{}/models", Self::BASE_URL)).map_err(|e| e.to_string())?;
        {
            let mut pairs = url.query_pairs_mut();
            pairs
                .append_pair("filter", "gguf")
                .append_pair("full", "true")
                .append_pair("sort", sort)
                .append_pair("direction", "-1")
                .append_pair("limit", &limit.clamp(1, 100).to_string());
            if offset > 0 {
                pairs.append_pair("offset", &offset.to_string());
            }
            if !query.trim().is_empty() {
                pairs.append_pair("search", query.trim());
            }
        }
        Ok(url)
    }

    pub async fn search_models(
        query: &str,
        limit: usize,
        token: Option<&str>,
        sort: &str,
        offset: usize,
    ) -> Result<Vec<HFModelSearchResult>, String> {
        let client = super::external_client()?;
        let url = Self::search_url(query, limit, sort, offset)?;

        let mut req = client.get(url).header("Accept", "application/json");
        if let Some(t) = token {
            if !t.trim().is_empty() {
                req = req.header("Authorization", format!("Bearer {}", t.trim()));
            }
        }

        let resp = req
            .send()
            .await
            .map_err(|e| format!("HF search request failed: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("HF search returned status {}", resp.status()));
        }

        let results: Vec<HFModelSearchResult> = resp
            .json()
            .await
            .map_err(|e| format!("Failed to parse HF search response: {}", e))?;

        Ok(results)
    }

    /// Avatars for every publisher on a rendered page, resolved in one call.
    ///
    /// The Hub answers on `/api/organizations/<owner>/avatar` or
    /// `/api/users/<owner>/avatar` with JSON, not image bytes, so each owner
    /// costs up to two requests. Results are cached for the process lifetime,
    /// including the "no avatar" answer: a catalogue re-render must not repeat
    /// the same lookups for the same handful of publishers.
    pub async fn avatars(owners: Vec<String>, token: Option<&str>) -> HashMap<String, String> {
        let cache = avatar_cache();
        let mut known: HashMap<String, String> = HashMap::new();
        let mut pending: Vec<String> = Vec::new();
        {
            let cache = cache
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            for owner in owners {
                let owner = owner.trim().to_string();
                if owner.is_empty() {
                    continue;
                }
                if let Some(hit) = cache.get(&owner) {
                    if let Some(url) = hit {
                        known.insert(owner, url.clone());
                    }
                    continue;
                }
                if !pending.contains(&owner) {
                    pending.push(owner);
                }
            }
        }
        if pending.is_empty() {
            return known;
        }

        let token = token.map(str::to_string);
        let resolved: Vec<(String, AvatarLookup)> =
            futures_util::stream::iter(pending.into_iter().map(|owner| {
                let token = token.clone();
                async move {
                    let lookup = Self::lookup_avatar(&owner, token.as_deref()).await;
                    (owner, lookup)
                }
            }))
            .buffer_unordered(4)
            .collect()
            .await;

        let mut cache = cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for (owner, lookup) in resolved {
            if let Some(entry) = lookup.cache_entry() {
                cache.insert(owner.clone(), entry);
            }
            if let Some(url) = lookup.into_url() {
                known.insert(owner, url);
            }
        }
        known
    }

    async fn lookup_avatar(owner: &str, token: Option<&str>) -> AvatarLookup {
        let Some(client) = super::external_client().ok() else {
            return AvatarLookup::Failed;
        };
        // A publisher without an avatar answers 404 on both endpoints; that is
        // the Hub's answer, so it may be cached. Anything else (network error,
        // throttling, 5xx, garbage body) must stay retryable.
        let mut cacheable = true;
        for kind in ["organizations", "users"] {
            let url = format!("{}/{}/{}", Self::BASE_URL, kind, owner);
            let mut request = client
                .get(format!("{url}/avatar"))
                .header("Accept", "application/json")
                .timeout(std::time::Duration::from_secs(8));
            if let Some(value) = token.filter(|value| !value.trim().is_empty()) {
                request = request.bearer_auth(value.trim());
            }
            let response = match request.send().await {
                Ok(response) => response,
                Err(_) => {
                    cacheable = false;
                    continue;
                }
            };
            if response.status() == reqwest::StatusCode::NOT_FOUND {
                continue;
            }
            if !response.status().is_success() {
                cacheable = false;
                continue;
            }
            let json = match response.json::<serde_json::Value>().await {
                Ok(json) => json,
                Err(_) => {
                    cacheable = false;
                    continue;
                }
            };
            if let Some(url) = json.get("avatarUrl").and_then(|value| value.as_str()) {
                // The renderer puts this straight into an `<img src>`; only
                // an absolute HTTPS URL is safe to hand over.
                if url.starts_with("https://") {
                    return AvatarLookup::Found(url.to_string());
                }
            }
        }
        if cacheable {
            AvatarLookup::Absent
        } else {
            AvatarLookup::Failed
        }
    }

    pub fn validate_repository_id(repo_id: &str) -> Result<(), String> {
        let parts: Vec<_> = repo_id.split('/').collect();
        if parts.len() != 2
            || parts.iter().any(|part| {
                part.is_empty()
                    || *part == "."
                    || *part == ".."
                    || !part
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            })
        {
            return Err("Invalid Hugging Face repository identifier".to_string());
        }
        Ok(())
    }

    pub async fn get_model_details(
        repo_id: &str,
        token: Option<&str>,
    ) -> Result<HFModelDetails, String> {
        Self::validate_repository_id(repo_id)?;
        let client = super::external_client()?;
        // `blobs=true` is what makes the API include per-file `size`/`lfs`
        // metadata; without it every GGUF sibling reports no size at all.
        let url = format!("{}/models/{}?blobs=true", Self::BASE_URL, repo_id);

        let mut req = client.get(url).header("Accept", "application/json");
        if let Some(t) = token {
            if !t.trim().is_empty() {
                req = req.header("Authorization", format!("Bearer {}", t.trim()));
            }
        }

        let resp = req
            .send()
            .await
            .map_err(|e| format!("HF model info failed: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("HF model info returned status {}", resp.status()));
        }

        let repo: HFRepoResponse = resp
            .json()
            .await
            .map_err(|e| format!("Failed to parse HF model info: {}", e))?;

        let models_dir = LocalModelStore::models_dir();
        let hw_info = detect_hardware(Some(&models_dir));

        let mut gguf_files = Vec::new();
        if let Some(siblings) = repo.siblings {
            for sibling in siblings {
                if !sibling.rfilename.to_lowercase().ends_with(".gguf") {
                    continue;
                }
                let size = sibling.total_size();
                let quant = extract_quantization(&sibling.rfilename);
                let download_url = HFGGUFFile::resolve_url(repo_id, &sibling.rfilename);
                // Remote files carry no GGUF header yet, so the estimate is
                // the labelled heuristic variant.
                let est = calculate_memory_estimation(&hw_info, size, 8192, "f16", 512, None);
                let formatted = super::hardware::format_bytes(size);

                gguf_files.push(HFGGUFFile {
                    name: sibling.rfilename,
                    size,
                    download_url,
                    quantization: quant,
                    estimation: est,
                    formatted_size: formatted,
                    sha256: sibling
                        .lfs
                        .as_ref()
                        .and_then(|lfs| lfs.sha256.clone())
                        .map(|s| s.to_lowercase()),
                });
            }
        }

        // Sort gguf files by size ascending
        gguf_files.sort_by_key(|f| f.size);

        let author = repo
            .author
            .unwrap_or_else(|| repo_id.split('/').next().unwrap_or("").to_string());

        let card = repo.card_data.as_ref();
        let description = repo
            .description
            .or_else(|| card.and_then(|c| c["description"].as_str().map(str::to_string)))
            .unwrap_or_default();
        let license = card
            .and_then(|c| c["license"].as_str().map(str::to_string))
            .or_else(|| {
                repo.tags.as_ref().and_then(|tags| {
                    tags.iter()
                        .find_map(|tag| tag.strip_prefix("license:").map(str::to_string))
                })
            });
        let architecture = repo
            .gguf
            .as_ref()
            .and_then(|c| c["architecture"].as_str().map(str::to_string))
            .or_else(|| {
                repo.config.as_ref().and_then(|c| {
                    c["model_type"]
                        .as_str()
                        .or_else(|| c["architectures"][0].as_str())
                        .map(str::to_string)
                })
            });
        let parameters = repo
            .gguf
            .as_ref()
            .and_then(|c| c["total"].as_u64())
            .or_else(|| repo.safetensors.as_ref().and_then(|c| c["total"].as_u64()));
        // A model card is optional; its absence must not hide downloadable files.
        // Stream with a hard bound instead of buffering arbitrary remote content.
        let readme_url = HFGGUFFile::resolve_url(repo_id, "README.md");
        let mut request = client
            .get(readme_url)
            .timeout(std::time::Duration::from_secs(12));
        if let Some(token) = token.filter(|t| !t.trim().is_empty()) {
            request = request.bearer_auth(token.trim());
        }
        let readme = match request.send().await {
            Ok(mut response) if response.status().is_success() => {
                let mut bytes = Vec::new();
                while let Ok(Some(chunk)) = response.chunk().await {
                    if bytes.len() + chunk.len() > 512 * 1024 {
                        break;
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Some(String::from_utf8_lossy(&bytes).into_owned())
            }
            _ => None,
        };
        Ok(HFModelDetails {
            id: repo.id,
            author,
            description,
            downloads: repo.downloads.unwrap_or(0),
            likes: repo.likes.unwrap_or(0),
            license,
            gguf_files,
            last_modified: repo.last_modified,
            tags: repo.tags.unwrap_or_default(),
            architecture,
            parameters,
            readme,
        })
    }
}

pub(crate) fn extract_quantization(filename: &str) -> String {
    let upper = filename.to_uppercase();
    // Longest match first: "F16" is a substring of "BF16", so declaration
    // order would mislabel every BF16 file as F16.
    let mut quants = [
        "Q4_K_M", "Q4_K_S", "Q4_0", "Q4_1", "Q5_K_M", "Q5_K_S", "Q5_0", "Q5_1", "Q6_K", "Q8_0",
        "F16", "F32", "BF16", "IQ4_XS", "IQ4_NL", "IQ3_M",
    ];
    quants.sort_by_key(|q| std::cmp::Reverse(q.len()));
    for q in quants {
        if upper.contains(q) {
            return q.to_string();
        }
    }
    "Unknown".to_string()
}

#[cfg(test)]
mod tests {
    use super::{extract_quantization, HFGGUFFile};
    use crate::local_ai::hardware::{calculate_memory_estimation, HardwareInfo, InferenceBackend};

    #[test]
    fn search_url_encodes_unicode_and_honors_sort_and_pagination() {
        let url = super::HuggingFaceService::search_url("модель & code", 200, "likes", 30).unwrap();
        let pairs: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(pairs["search"], "модель & code");
        assert_eq!(pairs["sort"], "likes");
        assert_eq!(pairs["offset"], "30");
        assert_eq!(pairs["limit"], "100");
        assert!(super::HuggingFaceService::search_url("", 30, "invalid", 0).is_err());
    }

    #[test]
    fn repository_ids_reject_traversal_and_urls() {
        assert!(super::HuggingFaceService::validate_repository_id("org/model-v1.5").is_ok());
        for id in [
            "../repo",
            "org/..",
            "https://example.com/repo",
            "org/repo/extra",
            "org/repo?x",
        ] {
            assert!(
                super::HuggingFaceService::validate_repository_id(id).is_err(),
                "{id}"
            );
        }
    }

    #[test]
    fn search_response_accepts_hugging_face_last_modified_key() {
        let row: super::HFModelSearchResult = serde_json::from_value(serde_json::json!({
            "id": "org/model", "lastModified": "2026-11-05T00:00:00Z"
        }))
        .unwrap();
        assert_eq!(row.last_modified.as_deref(), Some("2026-11-05T00:00:00Z"));
        assert_eq!(
            serde_json::to_value(row).unwrap()["lastModified"],
            "2026-11-05T00:00:00Z"
        );
    }

    /// "F16" is a substring of "BF16"; matching in declaration order labels
    /// every BF16 file as F16.
    #[test]
    fn quantization_detection_prefers_the_longest_match() {
        assert_eq!(extract_quantization("Qwen3.5-2B-BF16.gguf"), "BF16");
        assert_eq!(extract_quantization("Qwen3.5-2B-F16.gguf"), "F16");
        assert_eq!(extract_quantization("model-q4_k_m.gguf"), "Q4_K_M");
        assert_eq!(extract_quantization("model-iq4_xs.gguf"), "IQ4_XS");
        assert_eq!(extract_quantization("model-unknown.gguf"), "Unknown");
    }

    #[test]
    fn resolve_url_percent_encodes_the_repo_path() {
        assert_eq!(
            HFGGUFFile::resolve_url("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "model-q4_k_m.gguf"),
            "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/model-q4_k_m.gguf"
        );
        // `#` and `?` would truncate a hand-built URL; subdirectories stay
        // path segments instead of escaping the repo.
        assert_eq!(
            HFGGUFFile::resolve_url("org/repo", "sub/file#1?.gguf"),
            "https://huggingface.co/org/repo/resolve/main/sub/file%231%3F.gguf"
        );
    }

    /// The UI reads `file.name`, so the serialized DTO — not the demo mock —
    /// is the contract this test pins.
    #[test]
    fn gguf_file_dto_serializes_the_keys_the_ui_reads() {
        let info = HardwareInfo {
            os_version: "test".to_string(),
            architecture: "x86_64".to_string(),
            models_dir: String::new(),
            cpu_model: "cpu".to_string(),
            cpu_cores: 8,
            total_ram: 16 * 1024 * 1024 * 1024,
            free_ram: 8 * 1024 * 1024 * 1024,
            gpu_name: None,
            gpu_driver: None,
            gpu_has_unified_memory: false,
            gpu_recommended_max_working_set_size: None,
            supported_backends: vec![InferenceBackend::Cpu],
            recommended_backend: InferenceBackend::Cpu,
            models_disk_free_space: 0,
            models_disk_total_space: 0,
        };

        let file = HFGGUFFile {
            name: "Qwen3-4B-Q4_K_M.gguf".to_string(),
            size: 2_500_000_000,
            download_url: HFGGUFFile::resolve_url("Qwen/Qwen3-4B-GGUF", "Qwen3-4B-Q4_K_M.gguf"),
            quantization: "Q4_K_M".to_string(),
            estimation: calculate_memory_estimation(&info, 2_500_000_000, 8192, "f16", 512, None),
            formatted_size: "2.3 GB".to_string(),
            sha256: Some("a".repeat(64)),
        };
        let json = serde_json::to_value(&file).unwrap();

        for key in [
            "name",
            "size",
            "downloadUrl",
            "quantization",
            "sha256",
            "estimation",
        ] {
            assert!(json.get(key).is_some(), "missing `{}` in {}", key, json);
        }
        assert_eq!(json["name"], serde_json::json!("Qwen3-4B-Q4_K_M.gguf"));
        // The Hugging Face spelling must not leak into the wire contract.
        assert!(json.get("rfilename").is_none());
        assert!(json.get("id").is_none());
    }

    /// A throttled or failed avatar request must stay retryable: caching it as
    /// "this publisher has no avatar" would hide the picture for the rest of
    /// the process lifetime.
    #[test]
    fn failed_avatar_lookups_are_not_cached() {
        use super::AvatarLookup;

        assert_eq!(
            AvatarLookup::Found("https://cdn.example/a.png".to_string()).cache_entry(),
            Some(Some("https://cdn.example/a.png".to_string()))
        );
        assert_eq!(AvatarLookup::Absent.cache_entry(), Some(None));
        assert_eq!(AvatarLookup::Failed.cache_entry(), None);
    }
}
