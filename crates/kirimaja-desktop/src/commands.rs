use std::path::PathBuf;
use std::sync::Arc;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerStatusDto {
    pub alias: String,
    pub ip: String,
    pub port: u16,
    pub save_dir: String,
    pub wifi_band: String,
}

pub struct AppState {
    pub alias: String,
    pub port: u16,
    pub save_dir: Arc<RwLock<PathBuf>>,
}

#[tauri::command]
pub async fn get_server_status(state: State<'_, AppState>) -> Result<ServerStatusDto, String> {
    let save_dir = state.save_dir.read().await.to_string_lossy().to_string();
    let local_ip = localsend_rs::core::get_local_ip()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|| "127.0.0.1".to_string());

    Ok(ServerStatusDto {
        alias: state.alias.clone(),
        ip: local_ip,
        port: state.port,
        save_dir,
        wifi_band: "5GHz".to_string(), // In Windows, can query wlanapi
    })
}

#[tauri::command]
pub async fn open_save_dir(state: State<'_, AppState>) -> Result<(), String> {
    let dir = state.save_dir.read().await.clone();
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("explorer").arg(dir).spawn();
    }
    Ok(())
}

#[tauri::command]
pub async fn connect_manual_ip(ip: String) -> Result<String, String> {
    tracing::info!("Attempting manual connection to IP: {}", ip);
    // Ping device via /api/localsend/v2/info
    let url = format!("http://{}:53317/api/localsend/v2/info", ip);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;

    match client.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => Ok(format!("Connected to {ip}")),
        Ok(resp) => Err(format!("Device answered with status: {}", resp.status())),
        Err(err) => Err(format!("Could not reach device at {ip}: {err}")),
    }
}
