#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use commands::{
    AppState, change_save_dir, connect_manual_ip, get_best_local_ip, get_peers,
    get_server_status, open_save_dir, scan_network,
};
use kirimaja_core::{ResumableFileSink, ResumeJournal};
use localsend_rs::{
    DeviceInfo, DeviceType, Discovery, MulticastDiscovery, PROTOCOL_VERSION, Protocol,
    generate_fingerprint,
};
use localsend_rs::server::{LocalSendServer, ServerEvent};
use tauri::Emitter;
use tokio::sync::RwLock;

fn main() {
    localsend_rs::crypto::ensure_crypto_provider();
    let _ = tracing_subscriber::fmt::try_init();

    // Default download directory: Downloads/KirimAja
    let default_dir = dirs_or_fallback();
    let _ = std::fs::create_dir_all(&default_dir);

    let save_dir = Arc::new(RwLock::new(default_dir.clone()));
    let server_alias = format!("KirimAja Laptop ({})", whoami());
    let best_ip = get_best_local_ip();

    let local_device = DeviceInfo {
        alias: server_alias.clone(),
        version: PROTOCOL_VERSION.to_string(),
        device_model: Some("Windows PC".to_string()),
        device_type: Some(DeviceType::Desktop),
        fingerprint: generate_fingerprint(),
        port: 53317,
        protocol: Protocol::Http,
        download: false,
        ip: Some(best_ip),
    };

    let peers: Arc<RwLock<HashMap<String, DeviceInfo>>> = Arc::new(RwLock::new(HashMap::new()));

    let server_save_dir = default_dir.clone();
    let server_alias_clone = server_alias.clone();
    let local_device_clone = local_device.clone();
    let peers_clone = peers.clone();

    // Launch Tauri desktop GUI with synchronous OS event loop on the main thread
    tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();

            // 1. Spawn asynchronous background receiver server
            let srv_save = server_save_dir.clone();
            let srv_alias = server_alias_clone.clone();
            let srv_peers = peers_clone.clone();
            let srv_handle = handle.clone();

            tauri::async_runtime::spawn(async move {
                let journal = match ResumeJournal::open(&srv_save) {
                    Ok(j) => j,
                    Err(e) => {
                        tracing::error!("Failed to initialize resume journal: {}", e);
                        return;
                    }
                };
                let sink = Arc::new(ResumableFileSink::new(journal));

                let (server, mut events) = match LocalSendServer::builder()
                    .alias(srv_alias)
                    .port(53317)
                    .save_dir(&srv_save)
                    .protocol(Protocol::Http)
                    .auto_accept(true)
                    .sink(sink)
                    .build()
                    .await
                {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::error!("Failed to bind KirimAja server on port 53317: {}", e);
                        return;
                    }
                };

                let port = server.port();
                tracing::info!("KirimAja receiver listening on port {}", port);

                let mut last_progress_time = std::time::Instant::now();
                let mut last_bytes = 0_u64;
                let mut current_speed_mbs = 0.0_f64;

                while let Some(event) = events.recv().await {
                    match event {
                        ServerEvent::PeerRegistered(peer) => {
                            let key = peer.ip.clone().unwrap_or_else(|| peer.fingerprint.clone());
                            let mut lock = srv_peers.write().await;
                            lock.insert(key, peer);
                            let list: Vec<DeviceInfo> = lock.values().cloned().collect();
                            let _ = srv_handle.emit("peers-updated", list);
                        }
                        ServerEvent::FileReceiveProgress {
                            file_name,
                            bytes_received,
                            total_bytes,
                            ..
                        } => {
                            let now = std::time::Instant::now();
                            let elapsed = now.duration_since(last_progress_time).as_secs_f64();
                            if elapsed >= 0.4 {
                                let delta = bytes_received.saturating_sub(last_bytes);
                                current_speed_mbs = (delta as f64 / elapsed) / (1024.0 * 1024.0);
                                last_progress_time = now;
                                last_bytes = bytes_received;
                            }

                            let remaining = total_bytes.saturating_sub(bytes_received);
                            let eta_secs = if current_speed_mbs > 0.05 {
                                let bytes_per_sec = current_speed_mbs * 1024.0 * 1024.0;
                                (remaining as f64 / bytes_per_sec).round() as u64
                            } else {
                                0
                            };
                            let eta_str = if eta_secs > 0 {
                                if eta_secs < 60 {
                                    format!("{eta_secs} dtk")
                                } else {
                                    format!("{}m {}d", eta_secs / 60, eta_secs % 60)
                                }
                            } else {
                                "--".to_string()
                            };

                            let _ = srv_handle.emit(
                                "transfer-progress",
                                serde_json::json!({
                                    "filename": file_name,
                                    "bytesReceived": bytes_received,
                                    "totalBytes": total_bytes,
                                    "speedMBs": current_speed_mbs,
                                    "eta": eta_str,
                                    "isResume": false
                                }),
                            );
                        }
                        ServerEvent::FileReceived { file_name, .. } => {
                            last_bytes = 0;
                            current_speed_mbs = 0.0;
                            last_progress_time = std::time::Instant::now();
                            let _ = srv_handle.emit(
                                "transfer-complete",
                                serde_json::json!({ "filename": file_name }),
                            );
                        }
                        _ => {}
                    }
                }
            });

            // 2. Spawn UDP Multicast Discovery & Periodic Broadcaster
            let mc_device = local_device_clone.clone();
            let mc_peers = peers_clone.clone();
            let mc_handle = handle.clone();

            tauri::async_runtime::spawn(async move {
                let mut discovery = MulticastDiscovery::new_with_device(mc_device.clone());
                let peers_for_cb = mc_peers.clone();
                let handle_for_cb = mc_handle.clone();
                let my_dev = mc_device.clone();

                discovery.on_discovered(move |peer: DeviceInfo| {
                    let peers_inner = peers_for_cb.clone();
                    let handle_inner = handle_for_cb.clone();
                    let my_dev_clone = my_dev.clone();

                    tokio::spawn(async move {
                        // Register back so iPhone knows about our PC immediately
                        if let Ok(client) = localsend_rs::LocalSendClient::with_trust_policy(
                            my_dev_clone,
                            localsend_rs::TlsTrustPolicy::InsecureForTests,
                        ) {
                            let _ = client.register(&peer).await;
                        }

                        let key = peer.ip.clone().unwrap_or_else(|| peer.fingerprint.clone());
                        let mut lock = peers_inner.write().await;
                        lock.insert(key, peer);
                        let list: Vec<DeviceInfo> = lock.values().cloned().collect();
                        let _ = handle_inner.emit("peers-updated", list);
                    });
                });

                if let Err(e) = discovery.start().await {
                    tracing::warn!("Failed to start multicast discovery: {}", e);
                } else {
                    let _ = discovery.announce_presence().await;
                    let disc_arc = Arc::new(discovery);
                    let mut interval = tokio::time::interval(std::time::Duration::from_secs(3));
                    loop {
                        interval.tick().await;
                        let _ = disc_arc.announce_presence().await;
                    }
                }
            });

            // 3. Spawn Subnet HTTP Scanner (Sweeps 192.168.x.1..=254)
            let scan_dev = local_device_clone.clone();
            let scan_peers = peers_clone.clone();
            let scan_handle = handle.clone();

            tauri::async_runtime::spawn(async move {
                // Short grace delay at startup
                tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                loop {
                    let cur_ip = get_best_local_ip();
                    if cur_ip != "127.0.0.1" {
                        if let Ok(scanner) = localsend_rs::HttpDiscovery::for_device(scan_dev.clone()) {
                            if let Ok(outcome) = scanner
                                .scan_subnet_within(&cur_ip, std::time::Duration::from_secs(3))
                                .await
                            {
                                if !outcome.devices.is_empty() {
                                    let mut lock = scan_peers.write().await;
                                    let mut updated = false;
                                    for dev in outcome.devices {
                                        let dev_clone = dev.clone();
                                        let my_dev = scan_dev.clone();
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
                                            updated = true;
                                        }
                                    }
                                    if updated {
                                        let list: Vec<DeviceInfo> = lock.values().cloned().collect();
                                        let _ = scan_handle.emit("peers-updated", list);
                                    }
                                }
                            }
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(6)).await;
                }
            });

            Ok(())
        })
        .manage(AppState {
            alias: server_alias,
            port: 53317,
            save_dir,
            peers,
            local_device,
        })
        .invoke_handler(tauri::generate_handler![
            get_server_status,
            open_save_dir,
            change_save_dir,
            connect_manual_ip,
            get_peers,
            scan_network
        ])
        .run(tauri::generate_context!())
        .expect("error while running KirimAja application");
}

fn dirs_or_fallback() -> PathBuf {
    if let Some(user_dirs) = std::env::var_os("USERPROFILE") {
        PathBuf::from(user_dirs).join("Downloads").join("KirimAja")
    } else {
        PathBuf::from("./Downloads")
    }
}

fn whoami() -> String {
    std::env::var("USERNAME").unwrap_or_else(|_| "Windows".to_string())
}
