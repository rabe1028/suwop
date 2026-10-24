use super::{Intent, LegacyReconciliation, PostFacts, UnstartedClosure};
use serde::Serialize;
use sha2::{Digest, Sha256};

pub fn retired_outcomes_digest(batch: &super::Batch) -> Result<String, String> {
    hash(&(
        "suwop/liveRetiredOutcomes/v1",
        &batch.id,
        &batch.intent.digest,
        &batch.steps,
    ))
}

// Explicit, version-tagged ordered tuples. No raw JSON maps, platform numbers,
// observations, or mutable outcomes enter an immutable intent digest.
pub(super) fn hash(value: &impl Serialize) -> Result<String, String> {
    let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    Ok(crate::domain::hex(&Sha256::digest(bytes)))
}
pub fn intent_digest(intent: &Intent) -> Result<String, String> {
    hash(&(
        "suwop/liveBatchIntent/v1",
        intent.encoding_version,
        &intent.owner_id,
        &intent.scope,
        intent.direction,
        &intent.selections,
        &intent.resources,
        &intent.edges,
        &intent.aliases,
        &intent.observed_additional_parents,
        intent.shared_reference_limitations_acknowledged,
        &intent.dependencies,
        &intent.ordered_step_ids,
        &intent.supersedes,
    ))
}
pub fn post_digest(post: &PostFacts) -> Result<String, String> {
    hash(&(
        "suwop/liveBatchPost/v1",
        post.encoding_version,
        &post.batch_id,
        &post.step_id,
        &post.attempt_id,
        &post.intent_digest,
        &post.resources,
    ))
}
pub fn closure_digest(closure: &UnstartedClosure) -> Result<String, String> {
    hash(&(
        "suwop/liveKeepCurrent/v1",
        closure.format_version,
        &closure.id,
        &closure.references,
        &closure.current_graph,
    ))
}
pub fn reconciliation_digest(record: &LegacyReconciliation) -> Result<String, String> {
    hash(&(
        "suwop/liveLegacyReconciliation/v1",
        record.format_version,
        &record.id,
        &record.parent,
        &record.legacy,
        &record.confirmed_graph,
    ))
}
/// Safe historical fingerprint, not a proof that a legacy operation may be bypassed.
pub fn legacy_record_digest(
    record: &crate::immich_visibility::ImmichVisibilityOperation,
) -> Result<String, String> {
    hash(&("suwop/legacyVisibilityRecord/v1", record))
}
