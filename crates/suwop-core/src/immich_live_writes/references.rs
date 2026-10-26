use super::{
    Batch, Fact, LegacyReconciliation, Outcome, Step, StepRef, UnstartedClosure, Validation,
    define, digest, require, validate,
};
use crate::app::SavedLibrary;
use std::collections::{BTreeMap, BTreeSet};

pub(super) fn resolve<'a>(
    state: &'a SavedLibrary,
    reference: &StepRef,
) -> Result<(&'a Batch, &'a Step), String> {
    let batch = state
        .immich_live_operations
        .iter()
        .find(|b| b.id == reference.batch_id)
        .ok_or(super::INVALID)?;
    let step = batch
        .steps
        .iter()
        .find(|s| s.id == reference.step_id)
        .ok_or(super::INVALID)?;
    require(
        batch.intent.digest == reference.intent_digest
            && digest::retired_outcomes_digest(batch)? == reference.retired_outcomes_digest
            && matches!(step.outcome, Outcome::NotStarted),
    )?;
    Ok((batch, step))
}
fn reference_identity(reference: &StepRef) -> (String, String) {
    (reference.batch_id.clone(), reference.step_id.clone())
}
fn no_unknown(batch: &Batch) -> Validation {
    require(
        !batch
            .steps
            .iter()
            .any(|s| matches!(s.outcome, Outcome::Unknown { .. })),
    )
}

/// A structural prerequisite only, never current write/session authority.
/// Every closure/successor permanently retires the entire original cursor;
/// further user changes need a NEW confirmed batch, not another old sibling.
#[must_use]
pub fn original_continuation_open(state: &SavedLibrary, batch_id: &str) -> bool {
    super::validate_library(state).is_ok()
        && state
            .immich_live_operations
            .iter()
            .any(|b| b.id == batch_id)
        && !state
            .immich_live_unstarted_closures
            .iter()
            .any(|c| c.references.iter().any(|r| r.batch_id == batch_id))
        && !state
            .immich_live_operations
            .iter()
            .any(|b| b.intent.supersedes.iter().any(|r| r.batch_id == batch_id))
}

pub(super) fn validate(state: &SavedLibrary, ids: &mut BTreeSet<String>) -> Validation {
    // One historical NotStarted physical step has at most one closure OR successor.
    // Alias references never create extra definitions or additional discharge slots.
    let mut discharged = BTreeSet::new();
    let mut outgoing: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for batch in &state.immich_live_operations {
        for reference in &batch.intent.supersedes {
            let (old, old_step) = resolve(state, reference)?;
            no_unknown(old)?;
            require(
                old.id != batch.id
                    && old.intent.owner_id == batch.intent.owner_id
                    && old.intent.scope == batch.intent.scope
                    && discharged.insert(reference_identity(reference)),
            )?;
            let before = validate::resource(&old.intent, &old_step.resource_id)?;
            // Full source witness remains reachable through the exact digest reference.
            // A successor may explicitly confirm a different destination; it cannot
            // silently substitute another physical identity or relationship.
            require(
                batch
                    .intent
                    .resources
                    .iter()
                    .any(|r| validate::same_identity(&r.initial, &before.initial)),
            )?;
            outgoing.entry(&batch.id).or_default().insert(&old.id);
        }
    }
    acyclic(&outgoing)?;
    for closure in &state.immich_live_unstarted_closures {
        define(ids, &closure.id)?;
        closure_record(state, closure, &mut discharged)?;
    }
    for record in &state.immich_live_legacy_reconciliations {
        define(ids, &record.id)?;
        reconciliation(state, record)?;
    }
    Ok(())
}
pub(super) fn acyclic(outgoing: &BTreeMap<&str, BTreeSet<&str>>) -> Validation {
    // Iterative traversal bounds stack use even for hostile serialized histories.
    for start in outgoing.keys() {
        let mut pending: Vec<_> = outgoing.get(start).into_iter().flatten().copied().collect();
        let mut seen = BTreeSet::new();
        while let Some(node) = pending.pop() {
            require(node != *start)?;
            if seen.insert(node) {
                pending.extend(outgoing.get(node).into_iter().flatten().copied());
            }
        }
    }
    Ok(())
}
fn closure_record(
    state: &SavedLibrary,
    closure: &UnstartedClosure,
    discharged: &mut BTreeSet<(String, String)>,
) -> Validation {
    require(
        closure.format_version == 1
            && !closure.references.is_empty()
            && closure.digest == digest::closure_digest(closure)?,
    )?;
    let mut expected = BTreeMap::new();
    let mut context = None;
    for reference in &closure.references {
        // Only the referenced NotStarted step is retired. Unknown siblings
        // remain immutable evidence and continue to forbid successor mutation.
        let (batch, _) = resolve(state, reference)?;
        let current_context = (&batch.intent.owner_id, &batch.intent.scope);
        if let Some(prior) = context {
            require(prior == current_context)?;
        }
        context = Some(current_context);
        require(discharged.insert(reference_identity(reference)))?;
        for r in &batch.intent.resources {
            if let Some(prior) = expected.insert(&r.initial.key, &r.initial) {
                require(validate::same_identity(prior, &r.initial))?;
            }
        }
        // KeepCurrent adopts the explicitly observed graph, INCLUDING a placement
        // different from the old destination. It never claims that old intent
        // was achieved; the original NotStarted outcome remains immutable.
    }
    require(closure.current_graph.len() == expected.len())?;
    let mut seen = BTreeSet::new();
    for observation in &closure.current_graph {
        let original = expected.get(&observation.fact.key).ok_or(super::INVALID)?;
        validate::fact(&observation.fact, &original.owner_id, &original.key.scope)?;
        validate::albums(&observation.albums)?;
        require(
            seen.insert(&observation.fact.key)
                && validate::same_identity(original, &observation.fact),
        )?;
    }
    // Structural history validation is NOT creation admission. Later unrelated
    // or same-key Unknown records cannot retroactively invalidate this closure.
    // A future private creation gate must snapshot/check ALL then-current holds;
    // current access always evaluates the new records independently.
    Ok(())
}

fn reconciliation(state: &SavedLibrary, record: &LegacyReconciliation) -> Validation {
    require(
        record.format_version == 1
            && !record.legacy.is_empty()
            && record.digest == digest::reconciliation_digest(record)?,
    )?;
    let parent = record
        .confirmed_graph
        .iter()
        .find(|v| v.fact.key == record.parent)
        .ok_or(super::INVALID)?;
    let super::Forward::Linked(motion_key) = &parent.fact.forward else {
        return Err(super::INVALID.into());
    };
    require(parent.fact.media == super::Media::Image && record.confirmed_graph.len() == 2)?;
    let motion = record
        .confirmed_graph
        .iter()
        .find(|v| &v.fact.key == motion_key)
        .ok_or(super::INVALID)?;
    require(motion.fact.media == super::Media::Video)?;
    for value in &record.confirmed_graph {
        validate::fact(&value.fact, &parent.fact.owner_id, &parent.fact.key.scope)?;
        validate::albums(&value.albums)?;
    }
    legacy_refs(state, record, &parent.fact)?;
    // This first schema unit stores/validates the immutable acknowledgment;
    // no fresh Ordinary/C1 contextual permission is issued from it.
    Ok(())
}
fn legacy_refs(state: &SavedLibrary, record: &LegacyReconciliation, parent: &Fact) -> Validation {
    let relevant: Vec<_> = state
        .immich_visibility_operations
        .iter()
        .filter(|o| o.key == record.parent)
        .collect();
    require(!relevant.is_empty())?;
    let mut seen = BTreeSet::new();
    for reference in &record.legacy {
        let op = relevant
            .iter()
            .find(|o| o.id == reference.operation_id)
            .ok_or(super::INVALID)?;
        let mut acknowledged = (**op).clone();
        acknowledged.observation = reference.acknowledged_observation;
        acknowledged.album_membership_observation = reference.acknowledged_albums;
        acknowledged
            .selected_observation
            .clone_from(&reference.acknowledged_selected);
        crate::immich_visibility::validate_operation(&acknowledged)?;
        require(
            seen.insert(&reference.operation_id)
                && op.kind
                    == crate::immich_visibility::ImmichVisibilityOperationKind::LockedTransition
                && op.outcome == crate::apple_visibility::VisibilityOutcome::Applied
                && reference.record_digest == digest::legacy_record_digest(&acknowledged)?
                && op.witness_digest
                    == crate::immich_visibility::original_image_identity_digest(
                        &parent.key,
                        &parent.checksum,
                    ),
        )?;
    }
    Ok(())
}

pub(super) fn closed(state: &SavedLibrary, batch: &Batch, step: &Step) -> bool {
    let matches = |reference: &StepRef| {
        reference.batch_id == batch.id
            && reference.step_id == step.id
            && reference.intent_digest == batch.intent.digest
    };
    state
        .immich_live_unstarted_closures
        .iter()
        .any(|c| c.references.iter().any(matches))
        || state
            .immich_live_operations
            .iter()
            .any(|successor| successor.intent.supersedes.iter().any(matches))
}
