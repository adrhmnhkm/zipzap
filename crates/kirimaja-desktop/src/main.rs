#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

use std::path::PathBuf;
use std::sync::Arc;
use commands::{AppState, connect_manual_ip, get_server_status, open_save_dir};
use kirimaja_core::{ResumableFileSink, ResumeJournal};
use localsend_rs::Protocol;
use localsend_rs::server::LocalSendServer;
use tokio::sync::RwLock;

#[tokio::main]
async fn main() {
    let _ = tracing_subscriber::fmt::try_init();

    // Default download directory: Downloads/KirimAja
    let default_dir = dirs_or_fallback();
    let _ = tokio::fs::create_dir_all(&default_dir).await;

    let save_dir = Arc::new(RwLock::new(default_dir.clone()));

    // Initialize resume journal and resumable file sink
    let journal = ResumeJournal::open(&default_dir).expect("Failed to initialize resume journal");
    let sink = Arc::new(ResumableFileSink::new(journal));

    let server_alias = format!("KirimAja Laptop ({})", whoami());

    // Spawn KirimAja receiver server in background
    let (server, _events) = LocalSendServer::builder()
        .alias(server_alias.clone())
        .port(53317)
        .save_dir(&default_dir)
        .protocol(Protocol::Http)
        .auto_accept(true)
        .sink(sink)
        .build()
        .await
        .expect("Failed to bind KirimAja server on port 53317");

    let port = server.port();
    tracing::info!("KirimAja receiver listening on port {}", port);

    // Launch Tauri desktop GUI
    tauri::Builder::default()
        .manage(AppState {
            alias: server_alias,
            port,
            save_dir,
        })
        .invoke_handler(tauri::generate_handler![
            get_server_status,
            open_save_dir,
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
