use std::path::{Path, PathBuf};
use std::sync::Arc;
use async_trait::async_trait;
use chrono::Utc;
use localsend_rs::core::{
    PendingReceive, ReceiveSink, SinkError, reserve_free_name, walk_or_create_directory,
};
use localsend_rs::path_safety::safe_join;
use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWrite, AsyncWriteExt, SeekFrom};

use super::journal::{ResumeEntry, ResumeJournal};

/// A custom ReceiveSink implementation that stores partially downloaded files
/// in `.kirimaja-{file_id}.part` and persists their progress in a `ResumeJournal`.
#[derive(Clone)]
pub struct ResumableFileSink {
    journal: ResumeJournal,
}

impl ResumableFileSink {
    pub fn new(journal: ResumeJournal) -> Self {
        Self { journal }
    }

    pub fn journal(&self) -> &ResumeJournal {
        &self.journal
    }
}

#[async_trait]
impl ReceiveSink for ResumableFileSink {
    async fn create(
        &self,
        save_dir: &Path,
        file_name: &str,
    ) -> Result<Box<dyn PendingReceive>, SinkError> {
        self.create_resumable(save_dir, file_name, "", 0).await
    }

    async fn create_resumable(
        &self,
        save_dir: &Path,
        file_name: &str,
        file_id: &str,
        offset: u64,
    ) -> Result<Box<dyn PendingReceive>, SinkError> {
        let joined = safe_join(save_dir, file_name)
            .map_err(|err| SinkError::Rejected(err.to_string()))?;
        let directory = joined
            .parent()
            .ok_or_else(|| SinkError::Rejected("file name has no parent directory".to_string()))?
            .to_path_buf();
        let leaf = joined
            .file_name()
            .and_then(|l| l.to_str())
            .ok_or_else(|| SinkError::Rejected("file name is not valid utf-8".to_string()))?
            .to_string();

        walk_or_create_directory(save_dir, &directory).await?;

        // 1. Resuming existing partial transfer
        if offset > 0 && !file_id.is_empty() {
            if let Some(entry) = self.journal.get(file_id).await {
                if tokio::fs::try_exists(&entry.part_path).await.unwrap_or(false) {
                    let mut file = OpenOptions::new()
                        .write(true)
                        .open(&entry.part_path)
                        .await
                        .map_err(|e| SinkError::Failed(format!("Failed to open partial file: {e}")))?;

                    file.seek(SeekFrom::Start(offset))
                        .await
                        .map_err(|e| SinkError::Failed(format!("Failed to seek to offset {offset}: {e}")))?;

                    return Ok(Box::new(ResumablePendingFile {
                        file: Some(file),
                        part_path: entry.part_path,
                        final_path: entry.final_path,
                        directory,
                        file_id: file_id.to_string(),
                        file_name: file_name.to_string(),
                        journal: self.journal.clone(),
                        completed: false,
                        preserved: false,
                    }));
                }
            }
            tracing::warn!(
                file_id,
                offset,
                "Requested resume but journal entry or partial file was missing. Starting fresh."
            );
        }

        // 2. Fresh transfer (offset == 0 or resume not found)
        let (final_path, _) = reserve_free_name(&directory, &leaf).await?;
        let part_filename = if !file_id.is_empty() {
            format!(".kirimaja-{file_id}.part")
        } else {
            format!(".kirimaja-{}.part", uuid::Uuid::new_v4())
        };
        let part_path = directory.join(part_filename);

        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&part_path)
            .await
            .map_err(|err| SinkError::Failed(format!("Failed to create part file: {err}")))?;

        if !file_id.is_empty() {
            let _ = self
                .journal
                .record(ResumeEntry {
                    file_id: file_id.to_string(),
                    file_name: file_name.to_string(),
                    expected_size: 0,
                    bytes_received: 0,
                    part_path: part_path.clone(),
                    final_path: final_path.clone(),
                    updated_at: Utc::now(),
                    sha256_prefix: None,
                })
                .await;
        }

        Ok(Box::new(ResumablePendingFile {
            file: Some(file),
            part_path,
            final_path,
            directory,
            file_id: file_id.to_string(),
            file_name: file_name.to_string(),
            journal: self.journal.clone(),
            completed: false,
            preserved: false,
        }))
    }
}

pub struct ResumablePendingFile {
    file: Option<File>,
    part_path: PathBuf,
    final_path: PathBuf,
    directory: PathBuf,
    file_id: String,
    file_name: String,
    journal: ResumeJournal,
    completed: bool,
    preserved: bool,
}

#[async_trait]
impl PendingReceive for ResumablePendingFile {
    fn writer(&mut self) -> &mut (dyn AsyncWrite + Unpin + Send) {
        self.file
            .as_mut()
            .expect("PendingReceive owns its active file until committed or discarded")
    }

    fn display_path(&self) -> &Path {
        &self.final_path
    }

    async fn commit(mut self: Box<Self>) -> Result<PathBuf, SinkError> {
        let mut file = self
            .file
            .take()
            .expect("PendingReceive owns its active file until consumed");

        file.flush()
            .await
            .map_err(|err| SinkError::Failed(format!("Flush error: {err}")))?;
        file.sync_all()
            .await
            .map_err(|err| SinkError::Failed(format!("fsync error: {err}")))?;
        drop(file);

        // Atomically rename .part file to final path
        tokio::fs::rename(&self.part_path, &self.final_path)
            .await
            .map_err(|err| SinkError::Failed(format!("Rename error: {err}")))?;

        self.completed = true;

        // Clean up journal entry
        if !self.file_id.is_empty() {
            let _ = self.journal.remove(&self.file_id).await;
        }

        Ok(self.final_path.clone())
    }

    async fn abort(mut self: Box<Self>) -> Result<(), SinkError> {
        drop(self.file.take());
        self.completed = true;

        let _ = tokio::fs::remove_file(&self.part_path).await;
        let _ = tokio::fs::remove_file(&self.final_path).await;

        if !self.file_id.is_empty() {
            let _ = self.journal.remove(&self.file_id).await;
        }

        Ok(())
    }

    async fn preserve_partial(mut self: Box<Self>, bytes_written: u64) -> Result<(), SinkError> {
        if let Some(mut file) = self.file.take() {
            let _ = file.flush().await;
            let _ = file.sync_all().await;
        }

        self.preserved = true;

        if !self.file_id.is_empty() {
            let _ = self.journal.update_progress(&self.file_id, bytes_written).await;
            tracing::info!(
                file_id = %self.file_id,
                bytes_written,
                part_path = %self.part_path.display(),
                "Preserved partial file transfer for future resume"
            );
        }

        Ok(())
    }
}

impl Drop for ResumablePendingFile {
    fn drop(&mut self) {
        if !self.completed && !self.preserved {
            // Keep partial file and journal intact if unexpectedly dropped
            tracing::warn!(
                file_id = %self.file_id,
                "Transfer dropped without explicit commit or abort; keeping .part file"
            );
        }
    }
}
