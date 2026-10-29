//! KirimAja Core - High performance, resilient local LAN file transfer engine.
//!
//! Built on top of the LocalSend v2 protocol with extensions for:
//! - Offset-based resume support
//! - Resumable storage sinks with state journal
//! - Background task coordination for iOS & Tauri

pub use localsend_rs;

pub mod ffi;
pub mod resume;

pub use ffi::{DiscoveredDevice, KirimAjaClientEngine, TransferObserver, TransferProgressEvent};
pub use resume::{
    KIRIMAJA_RESUME_OFFSET_HEADER, ResumableFileSink, ResumablePendingFile, ResumeEntry,
    ResumeInfoResponse, ResumeJournal,
};
