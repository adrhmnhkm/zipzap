use serde::{Deserialize, Serialize};

/// Header used by KirimAja client to indicate resuming an upload from a specific byte offset.
pub const KIRIMAJA_RESUME_OFFSET_HEADER: &str = "X-KirimAja-Resume-Offset";

/// Endpoint path for querying resume offset before resuming transfer.
pub const KIRIMAJA_RESUME_ENDPOINT: &str = "/api/kirimaja/v1/resume-info";

/// Response returned when client queries current progress of a partially received file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeInfoResponse {
    /// File identifier as defined in prepare-upload
    pub file_id: String,
    /// Number of bytes already received and saved on disk
    pub offset: u64,
    /// Total expected size of the file in bytes
    pub expected_size: u64,
    /// Optional prefix of SHA256 of first chunk for verification
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256_prefix: Option<String>,
}
