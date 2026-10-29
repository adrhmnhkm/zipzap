use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

/// Represents a single tracked partial file transfer in the journal.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeEntry {
    pub file_id: String,
    pub file_name: String,
    pub expected_size: u64,
    pub bytes_received: u64,
    pub part_path: PathBuf,
    pub final_path: PathBuf,
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub sha256_prefix: Option<String>,
}

/// Journal that manages pending transfers to support offset-based resuming.
#[derive(Debug, Clone)]
pub struct ResumeJournal {
    journal_path: PathBuf,
    entries: Arc<RwLock<HashMap<String, ResumeEntry>>>,
}

impl ResumeJournal {
    /// Opens or creates a new resume journal file at the specified directory.
    pub fn open(storage_dir: impl AsRef<Path>) -> Result<Self> {
        let dir = storage_dir.as_ref();
        fs::create_dir_all(dir)
            .with_context(|| format!("Failed to create journal directory: {}", dir.display()))?;

        let journal_path = dir.join(".kirimaja_journal.json");
        let entries = if journal_path.exists() {
            let data = fs::read_to_string(&journal_path)
                .with_context(|| format!("Failed to read journal at: {}", journal_path.display()))?;
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            HashMap::new()
        };

        Ok(Self {
            journal_path,
            entries: Arc::new(RwLock::new(entries)),
        })
    }

    /// Retrieves an entry by its file ID.
    pub async fn get(&self, file_id: &str) -> Option<ResumeEntry> {
        let lock = self.entries.read().await;
        lock.get(file_id).cloned()
    }

    /// Adds or updates an entry and persists changes to disk.
    pub async fn record(&self, entry: ResumeEntry) -> Result<()> {
        {
            let mut lock = self.entries.write().await;
            lock.insert(entry.file_id.clone(), entry);
        }
        self.persist().await
    }

    /// Updates received bytes and timestamp for an active transfer.
    pub async fn update_progress(&self, file_id: &str, bytes_received: u64) -> Result<()> {
        {
            let mut lock = self.entries.write().await;
            if let Some(entry) = lock.get_mut(file_id) {
                entry.bytes_received = bytes_received;
                entry.updated_at = Utc::now();
            }
        }
        self.persist().await
    }

    /// Removes an entry once transfer is finalized or cancelled.
    pub async fn remove(&self, file_id: &str) -> Result<Option<ResumeEntry>> {
        let removed = {
            let mut lock = self.entries.write().await;
            lock.remove(file_id)
        };
        if removed.is_some() {
            self.persist().await?;
        }
        Ok(removed)
    }

    /// Persists all in-memory entries to the journal JSON file safely.
    async fn persist(&self) -> Result<()> {
        let lock = self.entries.read().await;
        let serialized = serde_json::to_string_pretty(&*lock)
            .context("Failed to serialize resume journal entries")?;
        
        let tmp_path = self.journal_path.with_extension("tmp");
        tokio::fs::write(&tmp_path, serialized.as_bytes())
            .await
            .context("Failed to write temporary journal file")?;
        tokio::fs::rename(&tmp_path, &self.journal_path)
            .await
            .context("Failed to atomically replace journal file")?;

        Ok(())
    }
}
