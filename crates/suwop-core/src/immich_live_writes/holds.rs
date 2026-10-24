use super::{Outcome, references};
use crate::{app::SavedLibrary, domain::AssetKey};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LiveHoldReason {
    InvalidHistory,
    UncertainSubmission,
    UnstartedRemainder,
    /// Historical completion is not current read/write authority. A future
    /// private fresh contextual discharge must also evaluate every other record.
    FreshContextRequired,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveHold {
    pub batch_id: String,
    pub keys: BTreeSet<AssetKey>,
    pub reason: LiveHoldReason,
}
#[must_use]
pub fn holds(state: &SavedLibrary) -> Vec<LiveHold> {
    let invalid = super::validate_library(state).is_err();
    state
        .immich_live_operations
        .iter()
        .map(|batch| {
            let reason = if invalid {
                LiveHoldReason::InvalidHistory
            } else if batch
                .steps
                .iter()
                .any(|s| matches!(s.outcome, Outcome::Unknown { .. }))
            {
                LiveHoldReason::UncertainSubmission
            } else if batch.steps.iter().any(|s| {
                matches!(s.outcome, Outcome::NotStarted) && !references::closed(state, batch, s)
            }) {
                LiveHoldReason::UnstartedRemainder
            } else {
                LiveHoldReason::FreshContextRequired
            };
            LiveHold {
                batch_id: batch.id.clone(),
                keys: batch
                    .intent
                    .resources
                    .iter()
                    .map(|r| r.initial.key.clone())
                    .collect(),
                reason,
            }
        })
        .collect()
}
#[must_use]
pub fn fences(state: &SavedLibrary, key: &AssetKey) -> bool {
    // No implicit fresh context exists in this schema-only unit. Neither
    // latest observations nor a different successful batch releases this hold.
    state
        .immich_live_operations
        .iter()
        .any(|b| b.intent.resources.iter().any(|r| r.initial.key == *key))
}
pub(crate) fn held_keys(state: &SavedLibrary) -> BTreeSet<AssetKey> {
    state
        .immich_live_operations
        .iter()
        .flat_map(|b| &b.intent.resources)
        .map(|r| r.initial.key.clone())
        .collect()
}
pub(crate) fn security_differs(before: &SavedLibrary, after: &SavedLibrary) -> bool {
    before.immich_live_operations != after.immich_live_operations
        || before.immich_live_unstarted_closures != after.immich_live_unstarted_closures
        || before.immich_live_legacy_reconciliations != after.immich_live_legacy_reconciliations
}
