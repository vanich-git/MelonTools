//! Hardware capability detection and memory estimation for Local AI inference.

use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InferenceBackend {
    #[serde(rename = "Metal")]
    Metal,
    #[serde(rename = "CUDA")]
    Cuda,
    #[serde(rename = "Vulkan")]
    Vulkan,
    #[serde(rename = "CPU")]
    Cpu,
}

impl InferenceBackend {
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Metal => "Apple Metal",
            Self::Cuda => "NVIDIA CUDA",
            Self::Vulkan => "Vulkan",
            Self::Cpu => "CPU Fallback",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CompatibilityRecommendation {
    #[serde(rename = "Recommended")]
    Recommended,
    #[serde(rename = "Fits with limitations")]
    FitsWithLimitations,
    #[serde(rename = "High memory usage")]
    HighMemoryUsage,
    #[serde(rename = "Insufficient memory")]
    InsufficientMemory,
    #[serde(rename = "Unsupported architecture")]
    UnsupportedArchitecture,
    #[serde(rename = "Unknown compatibility")]
    Unknown,
}

/// How the KV-cache figure was derived. `metadata` means the GGUF header
/// supplied the real layer and head geometry; `heuristic` means a typical
/// transformer shape was assumed, so the number is an order-of-magnitude
/// estimate and the UI is expected to say so.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EstimationConfidence {
    Metadata,
    Heuristic,
}

/// The transformer geometry the KV-cache formula needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct KvGeometry {
    /// `*.block_count` — transformer depth.
    pub layers: usize,
    /// `*.attention.head_count_kv` — K/V heads, not query heads. A GQA model
    /// has fewer of these than `head_count`; treating them as equal inflates
    /// the estimate for every modern model.
    pub kv_heads: usize,
    /// `*.embedding_length / *.attention.head_count`.
    pub head_dim: usize,
}

impl KvGeometry {
    pub fn is_complete(&self) -> bool {
        self.layers > 0 && self.kv_heads > 0 && self.head_dim > 0
    }
}

/// One shared estimation DTO. The UI reads exactly these keys, and
/// `total_bytes` is unambiguously the sum the machine must have free — it is
/// not the weights file size and not the KV cache alone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEstimation {
    /// Weights file size on disk.
    pub weights_bytes: u64,
    /// KV cache for the requested context length.
    pub kv_cache_bytes: u64,
    /// Compute/scratch buffers for the requested batch size.
    pub compute_buffers_bytes: u64,
    /// Memory kept free for the OS and other applications.
    pub os_reserve_bytes: u64,
    /// `weightsBytes + kvCacheBytes + computeBuffersBytes + osReserveBytes`.
    pub total_bytes: u64,
    /// Total physical RAM the estimate was compared against.
    pub available_bytes: u64,
    /// True when `totalBytes` fits into physical RAM at all.
    pub fits_in_memory: bool,
    pub confidence: EstimationConfidence,
    pub recommendation: CompatibilityRecommendation,
    pub warning: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HardwareInfo {
    pub os_version: String,
    pub architecture: String,
    /// Absolute models directory the app actually reads. The Settings tab shows
    /// it verbatim; an empty string means no directory could be resolved.
    pub models_dir: String,
    pub cpu_model: String,
    pub cpu_cores: usize,
    pub total_ram: u64,
    pub free_ram: u64,
    pub gpu_name: Option<String>,
    /// Vendor driver version. On Windows this is the real one from the
    /// vendor tool; macOS reports the Metal stack instead.
    pub gpu_driver: Option<String>,
    pub gpu_has_unified_memory: bool,
    pub gpu_recommended_max_working_set_size: Option<u64>,
    pub supported_backends: Vec<InferenceBackend>,
    pub recommended_backend: InferenceBackend,
    pub models_disk_free_space: u64,
    pub models_disk_total_space: u64,
}

pub fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    const TB: u64 = 1024 * GB;

    if bytes >= TB {
        format!("{:.2} TB", bytes as f64 / TB as f64)
    } else if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.1} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.0} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

/// Fallback shape for a GGUF whose header was never parsed (for example a
/// remote file we have not downloaded yet). 32 layers with a 4096-wide K/V
/// projection. It over-estimates the cache for GQA models, whose K/V heads are
/// narrower than the hidden state, which is why the payload carries
/// `confidence`.
const HEURISTIC_LAYERS: usize = 32;
const HEURISTIC_KV_WIDTH: usize = 4096;

/// Bytes per element for one KV-cache entry, matching llama.cpp's
/// `--cache-type-{k,v}` options.
pub fn kv_bytes_per_element(kv_cache_type: &str) -> f64 {
    match kv_cache_type.to_lowercase().as_str() {
        "f32" => 4.0,
        "bf16" => 2.0,
        "q8_0" => 1.0625,
        "q5_1" => 0.75,
        "q5_0" => 0.6875,
        "q4_1" => 0.625,
        "q4_0" | "iq4_nl" => 0.5625,
        _ => 2.0, // default f16
    }
}

/// `2 (K and V) × layers × kv_heads × head_dim × context × bytes per element`.
///
/// The old formula multiplied by `context / 2048` instead of by the context
/// itself, so an 8k context was reported 2048 times smaller than llama.cpp
/// actually allocates.
pub fn estimate_kv_cache_bytes(
    context_length: usize,
    kv_cache_type: &str,
    geometry: Option<KvGeometry>,
) -> (u64, EstimationConfidence) {
    let bytes_per_element = kv_bytes_per_element(kv_cache_type);
    let (width, confidence) = match geometry.filter(KvGeometry::is_complete) {
        Some(geometry) => (
            geometry.layers as f64 * geometry.kv_heads as f64 * geometry.head_dim as f64,
            EstimationConfidence::Metadata,
        ),
        None => (
            HEURISTIC_LAYERS as f64 * HEURISTIC_KV_WIDTH as f64,
            EstimationConfidence::Heuristic,
        ),
    };
    let bytes = 2.0 * width * context_length as f64 * bytes_per_element;
    (bytes.round() as u64, confidence)
}

pub fn calculate_memory_estimation(
    info: &HardwareInfo,
    weights_size: u64,
    context_length: usize,
    kv_cache_type: &str,
    batch_size: usize,
    geometry: Option<KvGeometry>,
) -> MemoryEstimation {
    let (kv_cache_bytes, confidence) =
        estimate_kv_cache_bytes(context_length, kv_cache_type, geometry);
    let compute_buffers = (batch_size as u64) * 1024 * 1024; // ~512 MB for 512 batch
    let os_reserve: u64 = 2 * 1024 * 1024 * 1024; // 2 GB

    let total_required = weights_size + kv_cache_bytes + compute_buffers + os_reserve;
    let available_memory = if info.total_ram > 0 {
        info.total_ram
    } else {
        16 * 1024 * 1024 * 1024
    };

    let (recommendation, warning) = if total_required <= (available_memory * 70 / 100) {
        (CompatibilityRecommendation::Recommended, None)
    } else if total_required <= (available_memory * 85 / 100) {
        (
            CompatibilityRecommendation::FitsWithLimitations,
            Some("Model will consume most of available system memory.".to_string()),
        )
    } else if total_required <= available_memory {
        (
            CompatibilityRecommendation::HighMemoryUsage,
            Some("High risk of system slowdown or swapping.".to_string()),
        )
    } else {
        (
            CompatibilityRecommendation::InsufficientMemory,
            Some("Required memory exceeds total physical RAM.".to_string()),
        )
    };

    MemoryEstimation {
        weights_bytes: weights_size,
        kv_cache_bytes,
        compute_buffers_bytes: compute_buffers,
        os_reserve_bytes: os_reserve,
        total_bytes: total_required,
        available_bytes: available_memory,
        fits_in_memory: total_required <= available_memory,
        confidence,
        recommendation,
        warning,
    }
}

/// Windows has no portable API for the installed driver version, so the
/// vendor tools are asked in order. A missing tool is normal (an AMD/Intel-only
/// machine has no `nvidia-smi`), which is why a failed probe falls through to
/// the next one instead of returning `None` for the whole detection.
#[cfg(target_os = "windows")]
const NVIDIA_SMI_TIMEOUT: Duration = Duration::from_secs(3);
#[cfg(target_os = "windows")]
const POWERSHELL_TIMEOUT: Duration = Duration::from_secs(8);

/// `DriverVersion` is exposed by Win32_VideoController for every vendor, so
/// this covers AMD and Intel when `nvidia-smi` is absent or fails.
#[cfg(target_os = "windows")]
const CIM_DRIVER_QUERY: &str = "Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.DriverVersion } | Select-Object -First 1 -ExpandProperty DriverVersion";

/// Runs a console tool with a hard deadline and without a console window.
/// `None` means it was missing, failed to start or timed out; callers decide
/// whether to try the next probe.
#[allow(dead_code)]
fn run_output_with_timeout(mut command: Command, timeout: Duration) -> Option<Output> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn().ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

/// Accepts only a bare version (`555.99`, `31.0.15.3623`). `nvidia-smi`
/// prints a prose error to stdout when the driver is broken; that must not be
/// shown as a version.
///
/// Only the Windows driver probe and the tests call it, so a non-Windows build
/// does not carry it at all (and does not warn that it is unused).
#[cfg(any(target_os = "windows", test))]
fn parse_driver_version_output(stdout: &str) -> Option<String> {
    stdout.lines().find_map(|line| {
        // PowerShell can prepend a UTF-8 BOM when its stdout is redirected.
        let value = line.trim().trim_start_matches('\u{feff}').trim_matches('"');
        if value.is_empty() || value.len() > 40 {
            return None;
        }
        let mut has_digit = false;
        for ch in value.chars() {
            if ch.is_ascii_digit() {
                has_digit = true;
            } else if ch != '.' {
                return None;
            }
        }
        has_digit.then(|| value.to_string())
    })
}

#[cfg(target_os = "windows")]
fn detect_windows_gpu_driver() -> Option<String> {
    let mut nvidia = Command::new("nvidia-smi");
    nvidia.args(["--query-gpu=driver_version", "--format=csv,noheader"]);
    if let Some(output) = run_output_with_timeout(nvidia, NVIDIA_SMI_TIMEOUT) {
        if output.status.success() {
            if let Some(version) =
                parse_driver_version_output(&String::from_utf8_lossy(&output.stdout))
            {
                return Some(version);
            }
        }
    }

    let mut powershell = Command::new("powershell.exe");
    powershell.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        CIM_DRIVER_QUERY,
    ]);
    let output = run_output_with_timeout(powershell, POWERSHELL_TIMEOUT)?;
    if !output.status.success() {
        return None;
    }
    parse_driver_version_output(&String::from_utf8_lossy(&output.stdout))
}

/// Reads the installed GPU driver version.
///
/// Windows has no portable API for this, so the vendor utilities are asked in
/// order. A missing utility is normal (Intel/AMD-only machines), hence `None`
/// rather than an error.
pub fn detect_gpu_driver() -> Option<String> {
    #[cfg(target_os = "windows")]
    {
        detect_windows_gpu_driver()
    }
    #[cfg(not(target_os = "windows"))]
    {
        // The driver ships with the OS here; report the graphics stack instead.
        Some(format!("Metal · macOS {}", std::env::consts::OS))
    }
}

#[cfg(windows)]
fn windows_memory() -> (u64, u64) {
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};

    let mut memory = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        dwMemoryLoad: 0,
        ullTotalPhys: 0,
        ullAvailPhys: 0,
        ullTotalPageFile: 0,
        ullAvailPageFile: 0,
        ullTotalVirtual: 0,
        ullAvailVirtual: 0,
        ullAvailExtendedVirtual: 0,
    };
    if unsafe { GlobalMemoryStatusEx(&mut memory) } != 0 {
        (memory.ullTotalPhys, memory.ullAvailPhys)
    } else {
        (16 * 1024 * 1024 * 1024, 8 * 1024 * 1024 * 1024)
    }
}

pub fn detect_hardware(models_dir: Option<&Path>) -> HardwareInfo {
    let os_version = std::env::consts::OS.to_string();
    let architecture = std::env::consts::ARCH.to_string();
    let cpu_cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);

    let cpu_model = format!("{} ({} cores)", architecture, cpu_cores);
    #[cfg(windows)]
    let (total_ram, free_ram) = windows_memory();
    #[cfg(not(windows))]
    let (total_ram, free_ram) = (16 * 1024 * 1024 * 1024, 8 * 1024 * 1024 * 1024);
    #[allow(unused_assignments)]
    let mut gpu_name: Option<String> = None;
    #[allow(unused_mut)]
    let mut gpu_has_unified_memory = false;
    #[allow(unused_mut)]
    let mut gpu_max_vram: Option<u64> = None;
    let mut supported_backends = vec![InferenceBackend::Cpu];
    let recommended_backend;

    #[cfg(windows)]
    {
        // Check for CUDA / Vulkan environment or NVIDIA GPU via registry / environment
        if std::env::var("CUDA_PATH").is_ok()
            || Path::new("C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA").exists()
        {
            supported_backends.insert(0, InferenceBackend::Cuda);
            recommended_backend = InferenceBackend::Cuda;
            gpu_name = Some("NVIDIA GPU (CUDA)".to_string());
        } else {
            supported_backends.insert(0, InferenceBackend::Vulkan);
            recommended_backend = InferenceBackend::Vulkan;
            gpu_name = Some("DirectX / Vulkan GPU".to_string());
        }
    }

    #[cfg(not(windows))]
    {
        if cfg!(target_os = "macos") {
            supported_backends.insert(0, InferenceBackend::Metal);
            recommended_backend = InferenceBackend::Metal;
            gpu_name = Some("Apple Silicon GPU".to_string());
            gpu_has_unified_memory = true;
            gpu_max_vram = Some(total_ram * 3 / 4);
        } else {
            supported_backends.insert(0, InferenceBackend::Vulkan);
            recommended_backend = InferenceBackend::Vulkan;
        }
    }

    let (disk_free, disk_total) = if let Some(dir) = models_dir {
        get_disk_space(dir)
    } else {
        (100 * 1024 * 1024 * 1024, 500 * 1024 * 1024 * 1024)
    };

    HardwareInfo {
        gpu_driver: detect_gpu_driver(),
        os_version,
        architecture,
        models_dir: models_dir
            .map(|dir| dir.to_string_lossy().to_string())
            .unwrap_or_default(),
        cpu_model,
        cpu_cores,
        total_ram,
        free_ram,
        gpu_name,
        gpu_has_unified_memory,
        gpu_recommended_max_working_set_size: gpu_max_vram,
        supported_backends,
        recommended_backend,
        models_disk_free_space: disk_free,
        models_disk_total_space: disk_total,
    }
}

fn get_disk_space(path: &Path) -> (u64, u64) {
    #[cfg(not(windows))]
    let _ = path;

    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut free_bytes_available: u64 = 0;
        let mut total_number_of_bytes: u64 = 0;
        let mut total_number_of_free_bytes: u64 = 0;

        let success = unsafe {
            GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut free_bytes_available,
                &mut total_number_of_bytes,
                &mut total_number_of_free_bytes,
            )
        };

        if success != 0 {
            return (free_bytes_available, total_number_of_bytes);
        }
    }

    #[cfg(not(windows))]
    {
        (100 * 1024 * 1024 * 1024, 500 * 1024 * 1024 * 1024)
    }

    #[cfg(windows)]
    (100 * 1024 * 1024 * 1024, 500 * 1024 * 1024 * 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_bytes_works() {
        assert_eq!(format_bytes(500), "500 B");
        assert_eq!(format_bytes(2048), "2 KB");
        assert_eq!(format_bytes(5 * 1024 * 1024), "5.0 MB");
        assert_eq!(format_bytes(8 * 1024 * 1024 * 1024), "8.00 GB");
    }

    #[test]
    fn calculate_memory_estimation_recommends_small_model() {
        let info = HardwareInfo {
            gpu_driver: Some("test-driver".to_string()),
            os_version: "test".to_string(),
            architecture: "x86_64".to_string(),
            models_dir: String::new(),
            cpu_model: "test cpu".to_string(),
            cpu_cores: 8,
            total_ram: 32 * 1024 * 1024 * 1024,
            free_ram: 24 * 1024 * 1024 * 1024,
            gpu_name: None,
            gpu_has_unified_memory: false,
            gpu_recommended_max_working_set_size: None,
            supported_backends: vec![InferenceBackend::Cpu],
            recommended_backend: InferenceBackend::Cpu,
            models_disk_free_space: 100 * 1024 * 1024 * 1024,
            models_disk_total_space: 500 * 1024 * 1024 * 1024,
        };

        let est = calculate_memory_estimation(
            &info,
            2 * 1024 * 1024 * 1024, // 2 GB weights
            4096,
            "f16",
            512,
            None,
        );

        assert_eq!(est.recommendation, CompatibilityRecommendation::Recommended);
        assert_eq!(est.confidence, EstimationConfidence::Heuristic);
        assert!(est.total_bytes < info.total_ram);
        assert!(est.fits_in_memory);
        assert_eq!(
            est.total_bytes,
            est.weights_bytes
                + est.kv_cache_bytes
                + est.compute_buffers_bytes
                + est.os_reserve_bytes
        );
    }

    #[test]
    fn kv_cache_scales_with_context_tokens_not_with_2048_token_blocks() {
        // 2 × 28 layers × 8 kv heads × 128 head_dim × 8192 tokens × 2 bytes.
        let geometry = KvGeometry {
            layers: 28,
            kv_heads: 8,
            head_dim: 128,
        };
        let (bytes, confidence) = estimate_kv_cache_bytes(8192, "f16", Some(geometry));
        let expected = 2.0 * 28.0 * 8.0 * 128.0 * 8192.0 * 2.0;

        assert_eq!(confidence, EstimationConfidence::Metadata);
        assert_eq!(bytes, expected as u64);
        // ~896 MiB for 8k tokens. The old `context / 2048` scaling reported
        // 2048× less, i.e. ~448 KiB.
        assert!(bytes > 890 * 1024 * 1024 && bytes < 900 * 1024 * 1024);

        // Doubling the context doubles the cache.
        let (doubled, _) = estimate_kv_cache_bytes(16384, "f16", Some(geometry));
        assert_eq!(doubled, bytes * 2);
    }

    #[test]
    fn kv_cache_uses_kv_heads_and_quantised_element_size() {
        // GQA: 32 query heads but only 8 K/V heads. Using head_count would
        // report 4× the cache llama.cpp actually allocates.
        let gqa = KvGeometry {
            layers: 32,
            kv_heads: 8,
            head_dim: 128,
        };
        let mha = KvGeometry {
            layers: 32,
            kv_heads: 32,
            head_dim: 128,
        };
        let (gqa_bytes, _) = estimate_kv_cache_bytes(8192, "f16", Some(gqa));
        let (mha_bytes, _) = estimate_kv_cache_bytes(8192, "f16", Some(mha));
        assert_eq!(mha_bytes, gqa_bytes * 4);

        // q8_0 is 34 bytes per 32-element block, i.e. 1.0625 bytes/element,
        // so the cache is 1.0625/2 of the f16 size (both K and V).
        let (q8, _) = estimate_kv_cache_bytes(8192, "q8_0", Some(gqa));
        assert_eq!(q8 as f64, (gqa_bytes as f64) * 1.0625 / 2.0);
    }

    #[test]
    fn kv_cache_falls_back_to_a_labelled_heuristic_without_geometry() {
        let (bytes, confidence) = estimate_kv_cache_bytes(4096, "f16", None);
        assert_eq!(confidence, EstimationConfidence::Heuristic);
        // 2 × 32 layers × 4096 width × 4096 tokens × 2 bytes.
        assert_eq!(bytes, 2 * 32 * 4096 * 4096 * 2);

        // An incomplete geometry is not partially trusted.
        let partial = KvGeometry {
            layers: 40,
            kv_heads: 0,
            head_dim: 128,
        };
        let (_, confidence) = estimate_kv_cache_bytes(4096, "f16", Some(partial));
        assert_eq!(confidence, EstimationConfidence::Heuristic);
    }

    #[test]
    fn memory_estimation_wire_contract_matches_the_ui() {
        let info = HardwareInfo {
            os_version: "test".to_string(),
            architecture: "x86_64".to_string(),
            models_dir: String::new(),
            cpu_model: "test cpu".to_string(),
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
        let est = calculate_memory_estimation(&info, 1024, 2048, "f16", 128, None);
        let json = serde_json::to_value(&est).unwrap();

        for key in [
            "weightsBytes",
            "kvCacheBytes",
            "computeBuffersBytes",
            "osReserveBytes",
            "totalBytes",
            "availableBytes",
            "fitsInMemory",
            "confidence",
            "recommendation",
        ] {
            assert!(json.get(key).is_some(), "missing `{}` in {}", key, json);
        }
        // The ambiguous names the UI never read are gone.
        assert!(json.get("totalRequired").is_none());
        assert!(json.get("kvCacheSize").is_none());
        assert_eq!(json["confidence"], serde_json::json!("heuristic"));
        assert_eq!(
            json["totalBytes"].as_u64().unwrap(),
            json["weightsBytes"].as_u64().unwrap()
                + json["kvCacheBytes"].as_u64().unwrap()
                + json["computeBuffersBytes"].as_u64().unwrap()
                + json["osReserveBytes"].as_u64().unwrap()
        );
    }

    #[test]
    fn nvidia_smi_driver_line_is_accepted() {
        assert_eq!(
            parse_driver_version_output("555.99\n"),
            Some("555.99".to_string())
        );
        assert_eq!(
            parse_driver_version_output("\r\n31.0.15.3623\r\n"),
            Some("31.0.15.3623".to_string())
        );
    }

    #[test]
    fn nvidia_smi_error_banner_is_not_a_driver_version() {
        // nvidia-smi writes this to stdout when the driver is broken; a
        // naive first-line parse would show it as the driver.
        let output =
            "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.\n";
        assert_eq!(parse_driver_version_output(output), None);
        assert_eq!(parse_driver_version_output(""), None);
        assert_eq!(parse_driver_version_output("   \n\t"), None);
    }

    #[test]
    fn cim_output_uses_the_first_bare_version() {
        let output = "31.0.101.4502\r\n27.20.100.9030\r\n";
        assert_eq!(
            parse_driver_version_output(output),
            Some("31.0.101.4502".to_string())
        );
        assert_eq!(
            parse_driver_version_output("Get-CimInstance : Access denied\n"),
            None
        );
    }

    #[cfg(unix)]
    #[test]
    fn timed_command_returns_output_before_the_deadline() {
        let mut command = Command::new("sh");
        command.args(["-c", "printf '31.0.15.3623\\n'"]);
        let output = run_output_with_timeout(command, Duration::from_secs(2)).unwrap();
        assert!(output.status.success());
        assert_eq!(
            parse_driver_version_output(&String::from_utf8_lossy(&output.stdout)),
            Some("31.0.15.3623".to_string())
        );
    }

    #[cfg(unix)]
    #[test]
    fn timed_command_is_killed_at_the_deadline() {
        let mut command = Command::new("sh");
        command.args(["-c", "sleep 5"]);
        let started = Instant::now();
        let output = run_output_with_timeout(command, Duration::from_millis(150));
        assert!(output.is_none());
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "the helper waited past its deadline"
        );
    }
}
