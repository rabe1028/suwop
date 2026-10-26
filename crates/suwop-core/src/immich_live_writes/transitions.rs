//! Structural durable evolution, not proof of a live request/session/submission.
//! The future executor must additionally own the exact runtime cursor, fresh
//! contract/pair authority and private response/no-submission/JOIN witnesses.
use super::{Batch, Outcome, Validation, require, validate_library};
use crate::app::SavedLibrary;

pub fn validate_transition(before: &SavedLibrary, after: &SavedLibrary) -> Validation {
    require(
        before.schema_version == super::CURRENT_SCHEMA_VERSION
            && after.schema_version == super::CURRENT_SCHEMA_VERSION,
    )?;
    validate_library(before)?;
    validate_library(after)?;
    require(
        after.immich_live_operations.len() >= before.immich_live_operations.len()
            && after
                .immich_live_unstarted_closures
                .starts_with(&before.immich_live_unstarted_closures)
            && after
                .immich_live_legacy_reconciliations
                .starts_with(&before.immich_live_legacy_reconciliations),
    )?;
    let mut outcome_changes = 0;
    for (old, new) in before
        .immich_live_operations
        .iter()
        .zip(&after.immich_live_operations)
    {
        require(
            old.id == new.id
                && old.format_version == new.format_version
                && old.intent == new.intent
                && old.steps.len() == new.steps.len(),
        )?;
        for (prior, next) in old.steps.iter().zip(&new.steps) {
            require(prior.id == next.id && prior.resource_id == next.resource_id)?;
            if prior.outcome != next.outcome {
                // Applied/readback must be durable in its OWN transition before
                // the next Unknown intent is even eligible to be persisted.
                // Adding an Accepted204 to Unknown counts as an outcome change.
                outcome_changes += 1;
                require(outcome_changes <= 1)?;
                require(super::original_continuation_open(before, &old.id))?;
                require(outcome(&prior.outcome, &next.outcome))?;
            }
        }
    }
    if outcome_changes != 0 {
        // Never combine a result update with retirement, supersession, or a
        // newly persisted batch. Those decisions need the separately proven
        // durable predecessor, not an in-memory result in the same write.
        require(
            before.immich_live_operations.len() == after.immich_live_operations.len()
                && before.immich_live_unstarted_closures.len()
                    == after.immich_live_unstarted_closures.len()
                && before.immich_live_legacy_reconciliations.len()
                    == after.immich_live_legacy_reconciliations.len(),
        )?;
    }
    for new in &after.immich_live_operations[before.immich_live_operations.len()..] {
        initial_intent(new)?;
    }
    Ok(())
}
fn initial_intent(batch: &Batch) -> Validation {
    let Some((first, remainder)) = batch.steps.split_first() else {
        return Err(super::INVALID.into());
    };
    require(
        matches!(&first.outcome, Outcome::Unknown { accepted: None, .. })
            && remainder
                .iter()
                .all(|s| matches!(s.outcome, Outcome::NotStarted)),
    )
}
fn outcome(prior: &Outcome, next: &Outcome) -> bool {
    match (prior, next) {
        (Outcome::NotStarted, Outcome::Unknown { accepted: None, .. }) => true,
        (
            Outcome::Unknown {
                attempt_id: old,
                accepted: None,
            },
            Outcome::Unknown {
                attempt_id: new,
                accepted: Some(_),
            }
            | Outcome::NotApplied {
                attempt_id: new, ..
            },
        ) => old == new,
        (
            Outcome::Unknown {
                attempt_id: old,
                accepted: prior_receipt,
            },
            Outcome::Applied {
                attempt_id: new,
                accepted,
                ..
            },
        ) => {
            old == new
                && prior_receipt
                    .as_ref()
                    .is_none_or(|receipt| receipt == accepted)
        }
        _ => false,
    }
}
