//! Hugging Face Hub API integration for discovering and inspecting GGUF models.

use super::hardware::{calculate_memory_estimation, detect_hardware, MemoryEstimation};
use super::local_models::LocalModelStore;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HFModelSearchResult {
    pub id: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub downloads: Option<i64>,
    pub likes: Option<i64>,
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
}

pub struct HuggingFaceService;

impl HuggingFaceService {
    const BASE_URL: &'static str = "https://huggingface.co/api";

    pub async fn search_models(
        query: &str,
        limit: usize,
        token: Option<&str>,
    ) -> Result<Vec<HFModelSearchResult>, String> {
        let client = super::external_client()?;
        let mut url = format!(
            "{}/models?filter=gguf&sort=downloads&direction=-1&limit={}",
            Self::BASE_URL,
            limit
        );
        let trimmed = query.trim();
        if !trimmed.is_empty() {
            let encoded: String = trimmed
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' || c == '~' {
                        c.to_string()
                    } else {
                        format!("%{:02X}", c as u32)
                    }
                })
                .collect();
            url.push_str(&format!("&search={}", encoded));
        }

        let mut req = client.get(&url).header("Accept", "application/json");
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

    pub async fn get_model_details(
        repo_id: &str,
        token: Option<&str>,
    ) -> Result<HFModelDetails, String> {
        let client = super::external_client()?;
        // `blobs=true` is what makes the API include per-file `size`/`lfs`
        // metadata; without it every GGUF sibling reports no size at all.
        let url = format!("{}/models/{}?blobs=true", Self::BASE_URL, repo_id);

        let mut req = client.get(&url).header("Accept", "application/json");
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

        Ok(HFModelDetails {
            id: repo.id,
            author,
            description: repo.description.unwrap_or_default(),
            downloads: repo.downloads.unwrap_or(0),
            likes: repo.likes.unwrap_or(0),
            license: None,
            gguf_files,
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
}
