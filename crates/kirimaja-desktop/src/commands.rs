use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use localsend_rs::DeviceInfo;
use serde::{Deserialize, Serialize};
use tauri::{Emitter, State};
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
    pub peers: Arc<RwLock<HashMap<String, DeviceInfo>>>,
    pub local_device: DeviceInfo,
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

pub fn get_best_local_ip() -> String {
    if let Ok(addresses) = localsend_rs::local_ipv4_addresses() {
        // Priority 1: standard home router IP (192.168.x.x)
        for addr in &addresses {
            let s = addr.to_string();
            if s.starts_with("192.168.") {
                return s;
            }
        }

        // Priority 2: 10.x.x.x
        for addr in &addresses {
            let s = addr.to_string();
            if s.starts_with("10.") {
                return s;
            }
        }

        // Priority 3: any non-loopback, non-link-local (not 169.254.)
        for addr in &addresses {
            let s = addr.to_string();
            if !s.starts_with("127.") && !s.starts_with("169.254.") {
                return s;
            }
        }
    }

    localsend_rs::core::get_local_ip()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string())
}

#[tauri::command]
pub async fn get_server_status(state: State<'_, AppState>) -> Result<ServerStatusDto, String> {
    let save_dir = state.save_dir.read().await.to_string_lossy().to_string();
    let local_ip = get_best_local_ip();

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
pub async fn connect_manual_ip(
    ip: String,
    state: State<'_, AppState>,
    handle: tauri::AppHandle,
) -> Result<String, String> {
    localsend_rs::crypto::ensure_crypto_provider();
    tracing::info!("Attempting manual connection to IP: {}", ip);
    let client = reqwest::Client::builder()
        .no_proxy()
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;

    let mut target_device: Option<DeviceInfo> = None;

    // Try HTTPS first (LocalSend iOS/Android default), then HTTP fallback
    let https_url = format!("https://{}:53317/api/localsend/v2/info", ip);
    if let Ok(resp) = client.get(&https_url).send().await {
        if resp.status().is_success() {
            if let Ok(mut dev) = resp.json::<DeviceInfo>().await {
                dev.ip = Some(ip.clone());
                dev.protocol = localsend_rs::Protocol::Https;
                target_device = Some(dev);
            }
        }
    }

    if target_device.is_none() {
        let http_url = format!("http://{}:53317/api/localsend/v2/info", ip);
        match client.get(&http_url).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(mut dev) = resp.json::<DeviceInfo>().await {
                    dev.ip = Some(ip.clone());
                    dev.protocol = localsend_rs::Protocol::Http;
                    target_device = Some(dev);
                }
            }
            Ok(resp) => return Err(format!("Perangkat merespons status: {}", resp.status())),
            Err(err) => return Err(format!("Tidak dapat menjangkau {ip}:53317: {err}")),
        }
    }

    if let Some(dev) = target_device {
        let name = dev.alias.clone();
        let my_dev = state.local_device.clone();
        let dev_clone = dev.clone();

        tokio::spawn(async move {
            if let Ok(c) = localsend_rs::LocalSendClient::with_trust_policy(
                my_dev,
                localsend_rs::TlsTrustPolicy::InsecureForTests,
            ) {
                let _ = c.register(&dev_clone).await;
            }
        });

        let mut lock = state.peers.write().await;
        lock.insert(ip.clone(), dev);
        let list: Vec<DeviceInfo> = lock.values().cloned().collect();
        let _ = handle.emit("peers-updated", list);

        return Ok(format!("Terhubung ke {name} ({ip})"));
    }

    Err(format!("Tidak dapat membaca info perangkat di {ip}"))
}

#[tauri::command]
pub async fn get_peers(state: State<'_, AppState>) -> Result<Vec<DeviceInfo>, String> {
    let peers = state.peers.read().await;
    Ok(peers.values().cloned().collect())
}

#[tauri::command]
pub async fn scan_network(
    state: State<'_, AppState>,
    handle: tauri::AppHandle,
) -> Result<Vec<DeviceInfo>, String> {
    let local_ip = get_best_local_ip();
    if local_ip == "127.0.0.1" {
        return Err("Tidak ada koneksi jaringan lokal aktif".to_string());
    }

    let local_dev = state.local_device.clone();
    if let Ok(scanner) = localsend_rs::HttpDiscovery::for_device(local_dev.clone()) {
        if let Ok(outcome) = scanner
            .scan_subnet_within(&local_ip, std::time::Duration::from_secs(3))
            .await
        {
            let mut lock = state.peers.write().await;
            let mut changed = false;
            for dev in outcome.devices {
                let dev_clone = dev.clone();
                let my_dev = local_dev.clone();
                tokio::spawn(async move {
                    if let Ok(c) = localsend_rs::LocalSendClient::with_trust_policy(
                        my_dev,
                        localsend_rs::TlsTrustPolicy::InsecureForTests,
                    ) {
                        let _ = c.register(&dev_clone).await;
                    }
                });

                let key = dev.ip.clone().unwrap_or_else(|| dev.fingerprint.clone());
                if !lock.contains_key(&key) {
                    lock.insert(key, dev);
                    changed = true;
                }
            }
            let list: Vec<DeviceInfo> = lock.values().cloned().collect();
            if changed {
                let _ = handle.emit("peers-updated", list.clone());
            }
            return Ok(list);
        }
    }

    let peers = state.peers.read().await;
    Ok(peers.values().cloned().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_best_local_ip() {
        let ip = get_best_local_ip();
        println!("Detected IP: {}", ip);
        assert!(!ip.is_empty());
    }

    #[test]
    fn test_detect_wifi_band() {
        let band = detect_wifi_band();
        println!("Detected Wi-Fi band: {}", band);
        assert!(!band.is_empty());
    }
}

