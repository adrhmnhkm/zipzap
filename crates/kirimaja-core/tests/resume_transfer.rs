use std::sync::Arc;
use kirimaja_core::{KIRIMAJA_RESUME_OFFSET_HEADER, ResumableFileSink, ResumeJournal};
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
async fn test_resumable_transfer_end_to_end() {
    let save_dir = tempfile::tempdir().unwrap();
    let journal = ResumeJournal::open(save_dir.path()).unwrap();
    let sink = Arc::new(ResumableFileSink::new(journal.clone()));

    let (server, _events) = LocalSendServer::builder()
        .alias("KirimAja-Test-Receiver")
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

    // 1. Prepare upload for a 1000-byte file
    let total_size = 1000_u64;
    let file_id = "f_resume_test";
    let file_name = "sample_video.mp4";

    // Generate deterministic test payload
    let full_payload: Vec<u8> = (0..total_size).map(|i| (i % 256) as u8).collect();

    let prepare_body = json!({
        "info": {
            "alias": "Sender-iPhone",
            "version": "2.1",
            "deviceType": "mobile",
            "fingerprint": "test_fp",
            "port": 53317,
            "protocol": "http",
            "download": false
        },
        "files": {
            file_id: {
                "id": file_id,
                "fileName": file_name,
                "size": total_size,
                "fileType": "video/mp4"
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

    // 2. Upload first 400 bytes, then cut off (short body)
    let part1_bytes = 400_usize;
    let upload_url = format!(
        "http://127.0.0.1:{port}/api/localsend/v2/upload?sessionId={session_id}&fileId={file_id}&token={token}"
    );

    let r1 = client
        .post(&upload_url)
        .body(full_payload[..part1_bytes].to_vec())
        .send()
        .await
        .unwrap();

    // Server should reject short body with 500, but preserve partial to .part
    assert_eq!(r1.status(), 500);

    // Final file must not yet exist in the directory while incomplete
    let final_path = save_dir.path().join(file_name);
    assert!(!final_path.exists());

    // The partial file must exist with exactly the 400 bytes received so far
    let part_path = save_dir.path().join(format!(".kirimaja-{file_id}.part"));
    assert!(part_path.exists());
    assert_eq!(std::fs::metadata(&part_path).unwrap().len(), part1_bytes as u64);

    // 3. Query KirimAja resume endpoint
    let resume_info_url =
        format!("http://127.0.0.1:{port}/api/kirimaja/v1/resume-info?file_id={file_id}");
    let r2: serde_json::Value = client
        .get(&resume_info_url)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(r2["file_id"], file_id);
    assert_eq!(r2["offset"], part1_bytes as u64);

    // 4. Resume transfer: send remaining 600 bytes with X-KirimAja-Resume-Offset
    let r3 = client
        .post(&upload_url)
        .header(KIRIMAJA_RESUME_OFFSET_HEADER, part1_bytes.to_string())
        .body(full_payload[part1_bytes..].to_vec())
        .send()
        .await
        .unwrap();

    assert_eq!(r3.status(), 200);

    // 5. Verify final file
    let final_path = save_dir.path().join(file_name);
    assert!(final_path.exists());
    let saved_content = std::fs::read(&final_path).unwrap();
    assert_eq!(saved_content.len(), total_size as usize);
    assert_eq!(saved_content, full_payload);

    // Journal should be cleaned up
    assert!(journal.get(file_id).await.is_none());
}
