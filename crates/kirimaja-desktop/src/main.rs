#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

use std::path::PathBuf;
use std::sync::Arc;
use commands::{AppState, change_save_dir, connect_manual_ip, get_server_status, open_save_dir};
use kirimaja_core::{ResumableFileSink, ResumeJournal};
use localsend_rs::Protocol;
use localsend_rs::server::{LocalSendServer, ServerEvent};
use tauri::Emitter;
use tokio::sync::RwLock;

fn main() {
    let _ = tracing_subscriber::fmt::try_init();

    // Default download directory: Downloads/KirimAja
    let default_dir = dirs_or_fallback();
    let _ = std::fs::create_dir_all(&default_dir);

    let save_dir = Arc::new(RwLock::new(default_dir.clone()));
    let server_alias = format!("KirimAja Laptop ({})", whoami());

    let server_save_dir = default_dir.clone();
    let server_alias_clone = server_alias.clone();

    // Launch Tauri desktop GUI with synchronous OS event loop on the main thread
    tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();

            // Spawn asynchronous background receiver server in Tauri runtime
            tauri::async_runtime::spawn(async move {
                let journal = match ResumeJournal::open(&server_save_dir) {
                    Ok(j) => j,
                    Err(e) => {
                        tracing::error!("Failed to initialize resume journal: {}", e);
                        return;
                    }
                };
                let sink = Arc::new(ResumableFileSink::new(journal));

                let (server, mut events) = match LocalSendServer::builder()
                    .alias(server_alias_clone)
                    .port(53317)
                    .save_dir(&server_save_dir)
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

                while let Some(event) = events.recv().await {
                    match event {
                        ServerEvent::FileReceiveProgress {
                            file_name,
                            bytes_received,
                            total_bytes,
                            ..
                        } => {
                            let _ = handle.emit(
                                "transfer-progress",
                                serde_json::json!({
                                    "filename": file_name,
                                    "bytesReceived": bytes_received,
                                    "totalBytes": total_bytes,
                                    "speedMBs": 0.0,
                                    "isResume": false
                                }),
                            );
                        }
                        ServerEvent::FileReceived { file_name, .. } => {
                            let _ = handle.emit(
                                "transfer-complete",
                                serde_json::json!({ "filename": file_name }),
                            );
                        }
                        _ => {}
                    }
                }
            });

            Ok(())
        })
        .manage(AppState {
            alias: server_alias,
            port: 53317,
            save_dir,
        })
        .invoke_handler(tauri::generate_handler![
            get_server_status,
            open_save_dir,
            change_save_dir,
            connect_manual_ip
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
