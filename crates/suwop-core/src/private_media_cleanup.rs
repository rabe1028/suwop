//! In-memory cleanup obligations. A recovery locator grants neither media nor write access.
use crate::app::{Effect, Event, Model};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use std::sync::{
    Arc, OnceLock,
    atomic::{AtomicU64, Ordering},
};

// JSONValue carries numbers as IEEE-754; every accepted counter must roundtrip exactly.
const MAX_ATTEMPT: u64 = 9_007_199_254_740_991;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum PrivateMediaCleanupState {
    Joining,
    NeedsAttention,
    Quarantined,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PrivateMediaCleanupView {
    #[serde(rename = "recoveryID")]
    pub recovery_id: Option<String>,
    pub expected_attempt: u64,
    pub state: PrivateMediaCleanupState,
}
/// Only issued work receives this token. Public IDs/attempts cannot fabricate completions.
#[derive(Debug, Clone)]
pub(crate) struct Attempt {
    owner: Arc<()>,
    number: u64,
}
#[derive(Debug, Clone)]
pub(crate) struct Recovery {
    id: Option<String>,
    owner: Arc<()>,
    attempt: u64,
    joining: bool,
    failed: bool,
}
impl Recovery {
    pub(crate) fn new() -> Self {
        // Process nonce + checked monotonic locator never repeats across Core instances.
        // Entropy/counter failure retains an unaddressable quarantine, never reuses an ID.
        static NONCE: OnceLock<Option<String>> = OnceLock::new();
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let nonce = NONCE.get_or_init(|| {
            let mut bytes = [0_u8; 16];
            getrandom::getrandom(&mut bytes)
                .ok()
                .map(|()| crate::domain::hex(&bytes))
        });
        let sequence = NEXT
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
            .ok();
        let id = nonce
            .as_ref()
            .zip(sequence)
            .map(|(nonce, n)| format!("{nonce}:{n}"));
        Self {
            id,
            owner: Arc::new(()),
            attempt: 0,
            joining: false,
            failed: false,
        }
    }
    pub(crate) fn begin(&mut self, explicit_retry: bool) -> Option<Attempt> {
        if self.joining || (self.failed && (!explicit_retry || self.id.is_none())) {
            return None;
        }
        let Some(next) = self.attempt.checked_add(1).filter(|n| *n <= MAX_ATTEMPT) else {
            self.failed = true;
            return None;
        };
        self.attempt = next;
        self.joining = true;
        self.failed = false;
        Some(Attempt {
            owner: self.owner.clone(),
            number: next,
        })
    }
    pub(crate) fn same_owner(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.owner, &other.owner)
    }
    pub(crate) fn matches(&self, attempt: &Attempt) -> bool {
        self.joining && Arc::ptr_eq(&self.owner, &attempt.owner) && self.attempt == attempt.number
    }
    pub(crate) fn finish(&mut self, attempt: &Attempt, success: bool) -> bool {
        if !self.matches(attempt) {
            return false;
        }
        self.joining = false;
        self.failed = !success;
        true
    }
    pub(crate) fn accepts_retry(&self, id: &str, expected: u64) -> bool {
        self.id.as_deref() == Some(id) && self.attempt == expected && self.failed && !self.joining
    }
    pub(crate) fn view(&self) -> Option<PrivateMediaCleanupView> {
        (self.joining || self.failed).then(|| PrivateMediaCleanupView {
            recovery_id: self.id.clone(),
            expected_attempt: self.attempt,
            state: if self.joining {
                PrivateMediaCleanupState::Joining
            } else if self.id.is_none() || self.attempt == MAX_ATTEMPT {
                PrivateMediaCleanupState::Quarantined
            } else {
                PrivateMediaCleanupState::NeedsAttention
            },
        })
    }
}
pub(crate) fn projection(model: &Model) -> Vec<PrivateMediaCleanupView> {
    let mut rows = crate::private_media_capture::cleanup_projection(model);
    rows.extend(crate::immich_locked::live::cleanup_projection(model));
    rows.extend(crate::immich_locked::video::cleanup_projection(model));
    rows
}
pub(crate) fn retry(model: &mut Model, id: &str, expected: u64) -> Command<Effect, Event> {
    if let Some(command) = crate::private_media_capture::retry_cleanup(model, id, expected) {
        return command;
    }
    if let Some(command) = crate::immich_locked::live::retry_cleanup(model, id, expected) {
        return command;
    }
    crate::immich_locked::video::retry_cleanup(model, id, expected).unwrap_or_else(Command::done)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_obligation_rejects_automatic_attempt_and_stale_completion() -> Result<(), String> {
        let mut recovery = Recovery::new();
        let first = recovery.begin(false).ok_or("initial attempt")?;
        assert!(recovery.finish(&first, false));
        let failed = recovery.view().ok_or("failed row")?;
        assert!(recovery.begin(false).is_none());
        assert!(recovery.accepts_retry(
            failed.recovery_id.as_deref().ok_or("locator")?,
            failed.expected_attempt
        ));
        let second = recovery.begin(true).ok_or("explicit retry")?;
        assert!(!recovery.finish(&first, true));
        assert_eq!(
            recovery.view().ok_or("joining row")?.state,
            PrivateMediaCleanupState::Joining
        );
        assert!(recovery.finish(&second, true));
        assert!(recovery.view().is_none());
        Ok(())
    }
    #[test]
    fn removed_record_recreation_never_accepts_previous_locator() -> Result<(), String> {
        let mut old = Recovery::new();
        let attempt = old.begin(false).ok_or("old attempt")?;
        old.finish(&attempt, false);
        let row = old.view().ok_or("old row")?;
        let mut replacement = Recovery::new();
        let next = replacement.begin(false).ok_or("new attempt")?;
        replacement.finish(&next, false);
        assert!(!replacement.accepts_retry(
            row.recovery_id.as_deref().ok_or("old locator")?,
            row.expected_attempt
        ));
        assert!(!replacement.finish(&attempt, true));
        Ok(())
    }
    #[test]
    fn exhausted_counter_never_wraps_or_drops_quarantine() -> Result<(), String> {
        let mut recovery = Recovery::new();
        recovery.attempt = MAX_ATTEMPT;
        assert!(recovery.begin(true).is_none());
        let row = recovery.view().ok_or("quarantine")?;
        assert_eq!(row.state, PrivateMediaCleanupState::Quarantined);
        assert_eq!(row.expected_attempt, MAX_ATTEMPT);
        Ok(())
    }
    #[test]
    fn published_row_has_no_resource_name_key_scene_or_authority() -> Result<(), String> {
        let mut recovery = Recovery::new();
        recovery.begin(false).ok_or("attempt")?;
        let raw = serde_json::to_value(recovery.view()).map_err(|e| e.to_string())?;
        let fields = raw.as_object().ok_or("row")?;
        assert_eq!(fields.len(), 3);
        assert!(fields.contains_key("recoveryID"));
        assert!(fields.contains_key("expectedAttempt"));
        assert!(fields.contains_key("state"));
        Ok(())
    }
}
