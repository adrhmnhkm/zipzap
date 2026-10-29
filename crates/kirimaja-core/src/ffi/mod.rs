use std::path::PathBuf;
use std::sync::Arc;
use serde::{Deserialize, Serialize};

/// High-level device representation exposed to mobile frontends (SwiftUI / Kotlin).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredDevice {
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub device_model: Option<String>,
    pub device_type: String,
}

/// Progress event emitted to iOS / Tauri during active upload or download.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferProgressEvent {
    pub file_id: String,
    pub file_name: String,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub speed_mb_per_sec: f64,
    pub is_resume: bool,
}

/// Callback trait implemented by Swift / UI to receive real-time streaming progress.
pub trait TransferObserver: Send + Sync {
    fn on_progress(&self, progress: TransferProgressEvent);
    fn on_completed(&self, file_id: String, success: bool, error_message: Option<String>);
}

/// KirimAja Client Engine helper for initiating and resuming transfers from iOS to Windows.
pub struct KirimAjaClientEngine {
    client: reqwest::Client,
}

impl KirimAjaClientEngine {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(5))
                .build()
                .unwrap_or_default(),
        }
    }

    /// Queries the target Windows machine to check if there is an existing partial file
    /// and what byte offset we should resume from.
    pub async fn query_resume_offset(&self, peer_ip: &str, peer_port: u16, file_id: &str) -> u64 {
        let url = format!(
            "http://{}:{}/api/kirimaja/v1/resume-info?file_id={}",
            peer_ip, peer_port, file_id
        );

        match self.client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(json) = resp.json::<serde_json::Value>().await {
                    return json["offset"].as_u64().unwrap_or(0);
                }
            }
            Ok(resp) => {
                tracing::warn!(status = %resp.status(), "Target does not support resume or returned error");
            }
            Err(err) => {
                tracing::warn!(%err, "Failed to query resume info; defaulting to offset 0");
            }
        }
        0
    }
}

impl Default for KirimAjaClientEngine {
    fn default() -> Self {
        Self::new()
    }
}
