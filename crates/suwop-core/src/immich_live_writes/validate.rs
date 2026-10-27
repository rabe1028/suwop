use super::{
    Alias, Batch, Direction, Fact, Forward, Intent, Media, Outcome, Placement, Resource,
    ResourceObservation, Role, Validation, define, digest, require,
};
use crate::{
    app::SavedLibrary,
    domain::{AssetKey, Provider},
};
use std::collections::{BTreeMap, BTreeSet};

pub fn validate_library(state: &SavedLibrary) -> Validation {
    crate::metadata::validate_records(&state.metadata_operations)?;
    let mut ids = BTreeSet::new();
    for record in &state.external_imports {
        record.validate()?;
        define(&mut ids, &record.id)?;
    }

    for record in &state.metadata_operations {
        define(&mut ids, &record.id)?;
    }

    for op in &state.apple_visibility_operations {
        crate::apple_visibility::validate_operation(op, &state.apple_scope)?;
    }
    for op in &state.immich_visibility_operations {
        crate::immich_visibility::validate_operation(op)?;
    }
    for id in state
        .apple_visibility_operations
        .iter()
        .map(|op| &op.id)
        .chain(state.immich_visibility_operations.iter().map(|op| &op.id))
    {
        define(&mut ids, id)?;
    }
    for batch in &state.immich_live_operations {
        batch_structure(batch, &mut ids)?;
        outcomes(batch, &mut ids)?;
    }
    super::references::validate(state, &mut ids)
}

pub(super) fn key(key: &AssetKey, scope: &str) -> Validation {
    require(key.provider == Provider::Immich && key.scope == scope && !scope.trim().is_empty())?;
    crate::immich::valid_id(&key.asset_id)
}
pub(super) fn fact(value: &Fact, owner: &str, scope: &str) -> Validation {
    key(&value.key, scope)?;
    crate::immich::valid_id(owner)?;
    require(
        value.owner_id == owner
            && value.unstacked
            && !value.offline
            && !value.trashed
            && !value.revision.trim().is_empty()
            && value.checksum.len() == 40
            && value
                .checksum
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
    )?;
    match (&value.media, &value.forward) {
        (Media::Image, Forward::Linked(child)) => {
            key(child, scope)?;
            require(*child != value.key)
        }
        (Media::Video, Forward::Unlinked) => Ok(()),
        _ => Err(super::INVALID.into()),
    }
}
pub(super) fn albums(values: &[String]) -> Validation {
    for value in values {
        crate::immich::valid_id(value)?;
    }
    require(values.windows(2).all(|pair| pair[0] < pair[1]))
}
pub(super) fn same_identity(a: &Fact, b: &Fact) -> bool {
    a.key == b.key
        && a.owner_id == b.owner_id
        && a.media == b.media
        && a.checksum == b.checksum
        && a.forward == b.forward
        && a.unstacked == b.unstacked
        && a.offline == b.offline
        && a.trashed == b.trashed
}
pub(super) fn resource<'a>(intent: &'a Intent, id: &str) -> Result<&'a Resource, String> {
    intent
        .resources
        .iter()
        .find(|r| r.id == id)
        .ok_or_else(|| super::INVALID.into())
}

fn batch_structure(batch: &Batch, ids: &mut BTreeSet<String>) -> Validation {
    define(ids, &batch.id)?;
    let intent = &batch.intent;
    require(
        batch.format_version == 1
            && intent.encoding_version == 1
            && intent.shared_reference_limitations_acknowledged
            && !intent.selections.is_empty()
            && !intent.resources.is_empty()
            && !batch.steps.is_empty()
            && intent.digest == digest::intent_digest(intent)?,
    )?;
    let mut physical = BTreeSet::new();
    let mut step_ids = BTreeSet::new();
    for r in &intent.resources {
        define(ids, &r.id)?;
        fact(&r.initial, &intent.owner_id, &intent.scope)?;
        albums(&r.initial_albums)?;
        require(
            physical.insert(&r.initial.key)
                && (r.initial.placement == r.destination) == r.step_id.is_none(),
        )?;
        if let Some(step) = &r.step_id {
            require(step_ids.insert(step))?;
        }
    }
    require(
        batch.steps.len() == step_ids.len() && intent.ordered_step_ids.len() == batch.steps.len(),
    )?;
    for (step, ordered) in batch.steps.iter().zip(&intent.ordered_step_ids) {
        define(ids, &step.id)?;
        let r = resource(intent, &step.resource_id)?;
        require(step.id == *ordered && r.step_id.as_ref() == Some(&step.id))?;
    }
    selections(intent, ids)?;
    relations(intent, ids)?;
    dependencies(intent)?;
    latest_observations(batch)
}

fn latest_observations(batch: &Batch) -> Validation {
    let values = &batch.latest_observations;
    // Empty means never inspected; a completed/partial inspection explicitly
    // records every confirmed member, including NotObserved and safe failures.
    require(values.is_empty() || values.len() == batch.intent.resources.len())?;
    for (value, expected) in values.iter().zip(&batch.intent.resources) {
        require(value.key == expected.initial.key)?;
        if let super::ObservedState::Own(observed) = &value.state {
            key(&observed.key, &batch.intent.scope)?;
            require(
                observed.key == value.key
                    && observed.owner_id == batch.intent.owner_id
                    && !observed.revision.trim().is_empty()
                    && observed.checksum.len() == 40
                    && observed
                        .checksum
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            )?;
            if let Forward::Linked(child) = &observed.forward {
                key(child, &batch.intent.scope)?;
                require(*child != observed.key)?;
            }
        }
    }
    Ok(())
}

fn selections(intent: &Intent, ids: &mut BTreeSet<String>) -> Validation {
    for selected in &intent.selections {
        define(ids, &selected.id)?;
        key(&selected.parent, &intent.scope)?;
        require(
            intent
                .edges
                .iter()
                .filter(|e| e.selection_id == selected.id)
                .count()
                == 1,
        )?;
    }
    let mut extra = BTreeSet::new();
    for parent in &intent.observed_additional_parents {
        key(parent, &intent.scope)?;
        require(
            extra.insert(parent) && !intent.resources.iter().any(|r| &r.initial.key == parent),
        )?;
    }
    Ok(())
}
fn alias(intent: &Intent, alias: &Alias) -> Validation {
    let edge = intent
        .edges
        .iter()
        .find(|e| e.id == alias.edge_id)
        .ok_or(super::INVALID)?;
    let expected = match alias.role {
        Role::Parent => &edge.parent_resource,
        Role::Motion => &edge.motion_resource,
    };
    require(
        alias.resource_id == *expected
            && alias.destination == resource(intent, expected)?.destination,
    )
}
fn relations(intent: &Intent, ids: &mut BTreeSet<String>) -> Validation {
    for edge in &intent.edges {
        define(ids, &edge.id)?;
        let p = resource(intent, &edge.parent_resource)?;
        let m = resource(intent, &edge.motion_resource)?;
        require(
            p.initial.media == Media::Image
                && m.initial.media == Media::Video
                && p.initial.forward == Forward::Linked(m.initial.key.clone())
                && intent
                    .selections
                    .iter()
                    .any(|s| s.id == edge.selection_id && s.parent == p.initial.key),
        )?;
        for role in [Role::Parent, Role::Motion] {
            require(
                intent
                    .aliases
                    .iter()
                    .filter(|a| a.edge_id == edge.id && a.role == role)
                    .count()
                    == 1,
            )?;
        }
    }
    for a in &intent.aliases {
        define(ids, &a.id)?;
        alias(intent, a)?;
    }
    for r in &intent.resources {
        require(intent.aliases.iter().any(|a| a.resource_id == r.id))?;
        transition(intent.direction, r)?;
    }
    Ok(())
}
fn transition(direction: Direction, r: &Resource) -> Validation {
    require(transition_allowed(
        r.initial.media,
        direction,
        r.initial.placement,
        r.destination,
    ))
}
/// IMAGE Hidden is not enabled: Immich hidden is the companion-video placement
/// in this product contract. IMAGE destinations are Timeline/Archive/Locked;
/// enabling IMAGE Hidden requires separate provider evidence and UI policy.
/// Historical Lock/Restore semantics remain unchanged; explicit Reposition
/// supports individually confirmed destinations without inferring a pair grant.
#[must_use]
pub fn transition_allowed(
    media: Media,
    direction: Direction,
    from: Placement,
    to: Placement,
) -> bool {
    (media != Media::Image || ![from, to].contains(&Placement::Hidden))
        && (from == to
            || match direction {
                Direction::Lock => from != Placement::Locked && to == Placement::Locked,
                Direction::Restore => from == Placement::Locked && to != Placement::Locked,
                Direction::Reposition => true,
            })
}
fn dependencies(intent: &Intent) -> Validation {
    let mut expected = BTreeSet::new();
    for edge in &intent.edges {
        let p = resource(intent, &edge.parent_resource)?;
        let m = resource(intent, &edge.motion_resource)?;
        if let (Some(p), Some(m)) = (&p.step_id, &m.step_id) {
            let dependency = match intent.direction {
                Direction::Lock => (p.clone(), m.clone()),
                Direction::Reposition
                    if resource(intent, &edge.parent_resource)?.destination
                        == Placement::Locked =>
                {
                    (p.clone(), m.clone())
                }
                Direction::Restore | Direction::Reposition => (m.clone(), p.clone()),
            };
            expected.insert(dependency);
        }
    }
    let actual: BTreeSet<_> = intent
        .dependencies
        .iter()
        .map(|d| (d.before.clone(), d.after.clone()))
        .collect();
    require(expected == actual && actual.len() == intent.dependencies.len())?;
    let order: BTreeMap<_, _> = intent
        .ordered_step_ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id, i))
        .collect();
    require(
        order.len() == intent.ordered_step_ids.len()
            && intent.dependencies.iter().all(|d| {
                order
                    .get(&d.before)
                    .zip(order.get(&d.after))
                    .is_some_and(|(a, b)| a < b)
            }),
    )
}
pub(super) fn observations(
    intent: &Intent,
    values: &[ResourceObservation],
    full: bool,
) -> Validation {
    if full {
        require(values.len() == intent.resources.len())?;
    }
    let mut seen = BTreeSet::new();
    for observation in values {
        let value = &observation.fact;
        fact(value, &intent.owner_id, &intent.scope)?;
        albums(&observation.albums)?;
        require(
            seen.insert(&value.key)
                && intent
                    .resources
                    .iter()
                    .any(|r| same_identity(&r.initial, value)),
        )?;
    }
    if full {
        require(
            values
                .iter()
                .zip(&intent.resources)
                .all(|(v, r)| v.fact.key == r.initial.key),
        )?;
    }
    Ok(())
}
fn accepted(
    receipt: &super::Accepted204,
    batch: &Batch,
    step: &super::Step,
    attempt: &str,
) -> Validation {
    require(
        receipt.batch_id == batch.id
            && receipt.step_id == step.id
            && receipt.attempt_id == attempt
            && receipt.intent_digest == batch.intent.digest
            && receipt.key == resource(&batch.intent, &step.resource_id)?.initial.key,
    )
}
fn outcomes(batch: &Batch, ids: &mut BTreeSet<String>) -> Validation {
    let mut stopped = false;
    let mut baseline: Vec<_> = batch
        .intent
        .resources
        .iter()
        .map(|r| ResourceObservation {
            fact: r.initial.clone(),
            albums: r.initial_albums.clone(),
        })
        .collect();
    for step in &batch.steps {
        if matches!(step.outcome, Outcome::NotStarted) {
            stopped = true;
            continue;
        }
        require(!stopped)?;
        match &step.outcome {
            Outcome::NotStarted => {}
            Outcome::Unknown {
                attempt_id,
                accepted: receipt,
            } => {
                define(ids, attempt_id)?;
                if let Some(receipt) = receipt {
                    accepted(receipt, batch, step, attempt_id)?;
                }
                stopped = true;
            }
            Outcome::NotApplied {
                attempt_id,
                no_submission,
            } => {
                define(ids, attempt_id)?;
                require(
                    no_submission.batch_id == batch.id
                        && no_submission.step_id == step.id
                        && no_submission.attempt_id == *attempt_id
                        && no_submission.intent_digest == batch.intent.digest
                        && no_submission.key
                            == resource(&batch.intent, &step.resource_id)?.initial.key,
                )?;
                stopped = true;
            }
            Outcome::Applied {
                attempt_id,
                accepted: receipt,
                verified_post,
            } => {
                define(ids, attempt_id)?;
                accepted(receipt, batch, step, attempt_id)?;
                post(batch, step, attempt_id, verified_post, &baseline)?;
                baseline.clone_from(&verified_post.resources);
            }
        }
    }
    Ok(())
}
fn post(
    batch: &Batch,
    step: &super::Step,
    attempt: &str,
    post: &super::PostFacts,
    baseline: &[ResourceObservation],
) -> Validation {
    require(
        post.encoding_version == 1
            && post.batch_id == batch.id
            && post.step_id == step.id
            && post.attempt_id == attempt
            && post.intent_digest == batch.intent.digest
            && post.digest == digest::post_digest(post)?,
    )?;
    observations(&batch.intent, &post.resources, true)?;
    let selected = resource(&batch.intent, &step.resource_id)?;
    for (value, before) in post.resources.iter().zip(baseline) {
        if value.fact.key == selected.initial.key {
            require(
                value.fact.placement == selected.destination
                    && if selected.destination == Placement::Locked {
                        value.albums.is_empty()
                    } else {
                        value.albums == before.albums
                    },
            )?;
        } else {
            require(value == before)?;
        }
    }
    Ok(())
}
