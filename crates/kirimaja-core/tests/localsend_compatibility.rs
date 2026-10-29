use std::sync::Arc;
use kirimaja_core::{ResumableFileSink, ResumeJournal};
use localsend_rs::Protocol;
use localsend_rs::server::LocalSendServer;
use serde_json::json;

async fn wait_for_server(port: u16) {
    localsend_rs::crypto::ensure_crypto_provider();
    for _ in 0..50 {
        if let Ok(resp) = reqwest::Client::new()
            .get(format!("http://127.0.0.1:{port}/api/localsend/v2/info"))
            .send()
            .await
        {
            if resp.status().is_success() {
                return;
            }
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }
    panic!("Server did not start in time on port {port}");
}

#[tokio::test]
async fn test_standard_localsend_compatibility() {
    let save_dir = tempfile::tempdir().unwrap();
    let journal = ResumeJournal::open(save_dir.path()).unwrap();
    let sink = Arc::new(ResumableFileSink::new(journal));

    let (server, _events) = LocalSendServer::builder()
        .alias("KirimAja-Receiver")
        .port(0)
        .save_dir(save_dir.path())
        .protocol(Protocol::Http)
        .auto_accept(true)
        .sink(sink)
        .build()
        .await
        .unwrap();

    let port = server.port();
    wait_for_server(port).await;

    let total_size = 500_u64;
    let file_id = "f_standard_compat";
    let file_name = "photo.jpg";
    let full_payload: Vec<u8> = vec![0xAB; total_size as usize];

    let prepare_body = json!({
        "info": {
            "alias": "Official-LocalSend-App",
            "version": "2.1",
            "deviceType": "mobile",
            "fingerprint": "standard_fp",
            "port": 53317,
            "protocol": "http",
            "download": false
        },
        "files": {
            file_id: {
                "id": file_id,
                "fileName": file_name,
                "size": total_size,
                "fileType": "image/jpeg"
            }
        }
    });

    let client = reqwest::Client::new();
    let prep_resp: serde_json::Value = client
        .post(format!("http://127.0.0.1:{port}/api/localsend/v2/prepare-upload"))
        .json(&prepare_body)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let session_id = prep_resp["sessionId"].as_str().unwrap().to_string();
    let token = prep_resp["files"][file_id].as_str().unwrap().to_string();

    let upload_url = format!(
        "http://127.0.0.1:{port}/api/localsend/v2/upload?sessionId={session_id}&fileId={file_id}&token={token}"
    );

    // Standard LocalSend sends without any KirimAja headers in one shot
    let r = client
        .post(&upload_url)
        .body(full_payload.clone())
        .send()
        .await
        .unwrap();

    assert_eq!(r.status(), 200);

    let final_path = save_dir.path().join(file_name);
    assert!(final_path.exists());
    let saved_content = std::fs::read(&final_path).unwrap();
    assert_eq!(saved_content, full_payload);
}
