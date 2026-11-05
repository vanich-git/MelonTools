//! Local AI inference engine, GGUF model registry, hardware detection, and Hugging Face integration.

pub mod commands;
pub mod hardware;
pub mod huggingface;
pub mod local_models;
pub mod local_runtime;
pub mod migration;
pub mod model_downloads;
pub mod runtime_catalog;
pub mod secret_store;
pub mod system_prompt_proxy;

pub use commands::*;
pub use hardware::{
    detect_hardware, format_bytes, HardwareInfo, InferenceBackend, MemoryEstimation,
};
pub use huggingface::{HFGGUFFile, HFModelDetails, HFModelSearchResult, HuggingFaceService};
pub use local_models::{
    LocalModel, LocalModelSettings, LocalModelStore, ModelCapability, ModelConfigProfile,
    ModelRuntimeStatus,
};
pub use local_runtime::{
    get_or_create_internal_token, get_runtime_port, save_runtime_port, LocalRuntimeManager,
    LocalRuntimeState, RuntimeInstallStage, RuntimeInstallStatus, RuntimeMetrics,
    RuntimeStatusPayload,
};
pub use migration::MigrationReport;
pub use model_downloads::{DownloadProgress, DownloadStatus, ModelDownloadManager};

/// HTTP client for external services (Hugging Face, runtime catalogue and
/// downloads). It honours the explicit app proxy exactly like the gateway.
pub fn external_client() -> Result<reqwest::Client, String> {
    crate::proxy::apply(reqwest::Client::builder())
        .build()
        .map_err(|e| format!("Failed to build the HTTP client: {e}"))
}

/// HTTP client for loopback-only traffic (engine health, metrics, relay).
/// Proxy settings must never intercept this, even in a proxy-only network.
pub fn loopback_client() -> Result<reqwest::Client, String> {
    crate::proxy::local(reqwest::Client::builder())
        .build()
        .map_err(|e| format!("Failed to build the loopback client: {e}"))
}

/// Port the gateway must advertise for local models.
///
/// Requests go through the prompt relay, which forwards to the llama.cpp
/// router and merges each model's system prompt into the request body; when the
/// relay cannot bind, the router port is the honest fallback.
pub fn published_local_port() -> u16 {
    let router = get_runtime_port();
    system_prompt_proxy::published_port(router)
}

#[cfg(test)]
mod tests {
    use super::{external_client, loopback_client};
    use crate::settings::Settings;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::sync::{Mutex, OnceLock};

    fn proxy_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    /// Last-resort HTTP server that records the request line and answers 502,
    /// which is enough to prove the client went through the proxy.
    fn proxy_recorder() -> (u16, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            if let Ok((mut socket, _)) = listener.accept() {
                let mut buffer = [0u8; 4096];
                let read = socket.read(&mut buffer).unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..read])
                    .lines()
                    .next()
                    .unwrap_or("")
                    .to_string();
                let _ = sender.send(request);
                let _ = socket.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
            }
        });
        (port, receiver)
    }

    fn direct_server() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((mut socket, _)) = listener.accept() {
                let mut buffer = [0u8; 4096];
                let _ = socket.read(&mut buffer);
                let _ = socket.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                );
            }
        });
        port
    }

    #[tokio::test]
    async fn local_ai_external_clients_honour_the_proxy_and_loopback_bypasses_it() {
        let guard = proxy_lock();
        let (proxy_port, proxy_requests) = proxy_recorder();
        let settings = Settings {
            proxy_enabled: true,
            proxy_url: format!("http://127.0.0.1:{proxy_port}"),
            proxy_bypass: String::new(),
            ..Settings::default()
        };
        // Another test may legitimately reconfigure the process-wide proxy
        // while this one runs. Rebuild until the client captured our value;
        // once built, the client keeps its own proxy.
        let mut client = None;
        for _ in 0..20 {
            crate::proxy::configure(&settings);
            let candidate = external_client().unwrap();
            if crate::proxy::active_url().as_deref() == Some(settings.proxy_url.as_str()) {
                client = Some(candidate);
                break;
            }
        }
        let client = client.expect("the test proxy was never active");
        crate::proxy::configure(&Settings::default());
        let direct_port = direct_server();
        let loopback = loopback_client().unwrap();
        // Both clients captured their routing above; the lock only protects
        // the process-wide configuration while they are built.
        drop(guard);

        // The host never resolves locally; a response is irrelevant, reaching
        // the recorder is the assertion.
        let _ = client
            .get("http://melon-proxy.invalid/v1/models")
            .send()
            .await;
        let request = proxy_requests
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("the external client must use the configured proxy");
        assert!(
            request.contains("melon-proxy.invalid"),
            "proxy saw an unexpected request line: {request}"
        );

        let response = loopback
            .get(format!("http://127.0.0.1:{direct_port}/health"))
            .send()
            .await
            .expect("loopback must connect directly");
        assert!(response.status().is_success());
    }
}
