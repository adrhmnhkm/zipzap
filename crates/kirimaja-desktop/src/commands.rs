use std::path::PathBuf;
use std::sync::Arc;
use serde::{Deserialize, Serialize};
use tauri::State;
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

/// Detects the active Wi-Fi frequency band on Windows (FR-08).
pub fn detect_wifi_band() -> String {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let output = Command::new("netsh")
            .args(["wlan", "show", "interfaces"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();

        if let Ok(out) = output {
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("Band") {
                    if let Some((_, val)) = trimmed.split_once(':') {
                        let band = val.trim();
                        if band.contains("2.4") {
                            return "2.4GHz".to_string();
                        } else if band.contains("5") {
                            return "5GHz".to_string();
                        } else if band.contains("6") {
                            return "6GHz".to_string();
                        }
                    }
                } else if trimmed.starts_with("Radio type") {
                    if trimmed.contains("802.11b") || trimmed.contains("802.11g") || trimmed.contains("802.11n") {
                        return "2.4GHz".to_string();
                    } else if trimmed.contains("802.11ac") || trimmed.contains("802.11ax") || trimmed.contains("802.11be") {
                        return "5GHz".to_string();
                    }
                }
            }
        }
    }
    "Unknown".to_string()
}

#[tauri::command]
pub async fn get_server_status(state: State<'_, AppState>) -> Result<ServerStatusDto, String> {
    let save_dir = state.save_dir.read().await.to_string_lossy().to_string();
    let local_ip = localsend_rs::core::get_local_ip()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string());

    let wifi_band = detect_wifi_band();

    Ok(ServerStatusDto {
        alias: state.alias.clone(),
        ip: local_ip,
        port: state.port,
        save_dir,
        wifi_band,
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
pub async fn change_save_dir(state: State<'_, AppState>) -> Result<Option<String>, String> {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let script = r#"
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Pilih Folder Penyimpanan KirimAja"
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Write-Output $dialog.SelectedPath
        }
        "#;

        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", script])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| e.to_string())?;

        let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path_str.is_empty() {
            let new_dir = PathBuf::from(&path_str);
            if new_dir.exists() {
                let mut lock = state.save_dir.write().await;
                *lock = new_dir;
                return Ok(Some(path_str));
            }
        }
    }
    Ok(None)
}

#[tauri::command]
pub async fn connect_manual_ip(ip: String) -> Result<String, String> {
    tracing::info!("Attempting manual connection to IP: {}", ip);
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
