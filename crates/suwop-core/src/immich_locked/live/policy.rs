//! Contract construction only: no capacity I/O, allocation ledger or authorization.
use std::collections::BTreeSet;

use crate::{
    domain::AssetKey,
    immich_locked::video::{ImmichLockedVideoCommitmentMode, ImmichLockedVideoStorageFacts},
};

// Integration supplies the ONE shared constant extracted from VIDEO policy.
// No second definition or caller-selectable headroom is introduced here.
use super::PRIVATE_MEDIA_HEADROOM_BYTES;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum MemberRole {
    Parent,
    Motion,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MemberSize {
    pub role: MemberRole,
    pub key: AssetKey,
    /// None means absent, never malformed. Some(0) is invalid.
    pub expected_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Representation {
    /// A distinct, explicitly declared future physical file/envelope.
    pub name: String,
    pub maximum_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RepresentationBudget {
    pub name: String,
    pub maximum_bytes: u64,
    pub rounded_reservation_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MemberBudget {
    pub role: MemberRole,
    pub key: AssetKey,
    pub expected_bytes: Option<u64>,
    /// Raw receive ceiling M; never round a known exact size upward.
    pub max_received_bytes: u64,
    pub commitment_mode: ImmichLockedVideoCommitmentMode,
    /// Known: round(M,u). Unknown: one positive sibling-protected start unit.
    pub initial_claim_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PairedBudget {
    pub minimum_remaining_bytes: u64,
    pub allocation_unit_bytes: u64,
    /// D: physical per-file-rounded aggregate ceiling, INCLUDING E.
    pub pair_disk_ceiling_bytes: u64,
    /// E: checked sum of named, separately rounded representation reservations.
    pub representation_reservation_bytes: u64,
    /// T = D-E: shared ORIGINAL raw receive ceiling, not a per-member entitlement.
    pub total_max_received_bytes: u64,
    /// E + rounded known sizes + one start unit for each unknown member.
    pub initial_claim_bytes: u64,
    /// Canonical role order: parent, then motion. Exactly two distinct keys.
    pub members: [MemberBudget; 2],
    pub representations: Vec<RepresentationBudget>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PolicyError {
    InvalidQuote,
    InvalidMembers,
    MalformedSize,
    InvalidRepresentation,
    ArithmeticOverflow,
    NativeCounterOverflow,
    InsufficientCapacity,
}

/// Strictly parse the same absent-vs-malformed metadata distinction as VIDEO.
/// No integer coercion from strings, floats, booleans, negative or zero values.
pub(super) fn expected_size(raw: &serde_json::Value) -> Result<Option<u64>, PolicyError> {
    let object = raw.as_object().ok_or(PolicyError::MalformedSize)?;
    let exif = match object.get("exifInfo") {
        None | Some(serde_json::Value::Null) => return Ok(None),
        Some(serde_json::Value::Object(exif)) => exif,
        _ => return Err(PolicyError::MalformedSize),
    };
    match exif.get("fileSizeInByte") {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|bytes| *bytes > 0)
            .map(Some)
            .ok_or(PolicyError::MalformedSize),
    }
}

/// No n+u-1 intermediate: exact `u64::MAX` with u=1 remains representable.
fn round_up(bytes: u64, unit: u64) -> Result<u64, PolicyError> {
    if bytes == 0 || unit == 0 {
        return Err(PolicyError::InvalidRepresentation);
    }
    let units = (bytes / unit)
        .checked_add(u64::from(!bytes.is_multiple_of(unit)))
        .ok_or(PolicyError::ArithmeticOverflow)?;
    units
        .checked_mul(unit)
        .ok_or(PolicyError::ArithmeticOverflow)
}

/// Native privately binds volume, nonce, measurement and current physical claims.
/// This function consumes that quote; it does not authorize a resource or perform
/// fresh-capacity admission. The future coordinator must bind the returned policy
/// to the exact quote/pending/revisions/lease and must not enlarge it on renewal.
pub(super) fn construct_budget(
    facts: &ImmichLockedVideoStorageFacts,
    now_ms: u64,
    members: [MemberSize; 2],
    representations: &[Representation],
) -> Result<PairedBudget, PolicyError> {
    validate_quote(facts, now_ms)?;
    validate_native_inputs(facts, now_ms, &members, representations)?;
    let [parent, motion] = order_members(members)?;
    let unit = facts.allocation_unit_bytes;
    let usable = facts
        .available_bytes
        .checked_sub(PRIVATE_MEDIA_HEADROOM_BYTES)
        .and_then(|bytes| bytes.checked_sub(facts.other_unallocated_bytes))
        .ok_or(PolicyError::InsufficientCapacity)?;
    let disk = (usable / unit)
        .checked_mul(unit)
        .filter(|bytes| *bytes > 0)
        .ok_or(PolicyError::InsufficientCapacity)?;
    let envelopes = representation_budgets(representations, unit)?;
    let extra = checked_sum(envelopes.iter().map(|item| item.rounded_reservation_bytes))?;
    let total = disk
        .checked_sub(extra)
        .filter(|bytes| *bytes > 0)
        .ok_or(PolicyError::InsufficientCapacity)?;
    let members = [
        member_budget(parent, total, unit)?,
        member_budget(motion, total, unit)?,
    ];
    let initial = checked_sum(
        members
            .iter()
            .map(|member| member.initial_claim_bytes)
            .chain([extra]),
    )?;
    if initial > disk {
        return Err(PolicyError::InsufficientCapacity);
    }
    let budget = PairedBudget {
        minimum_remaining_bytes: PRIVATE_MEDIA_HEADROOM_BYTES,
        allocation_unit_bytes: unit,
        pair_disk_ceiling_bytes: disk,
        representation_reservation_bytes: extra,
        total_max_received_bytes: total,
        initial_claim_bytes: initial,
        members,
        representations: envelopes,
    };
    validate_native_output(&budget)?;
    Ok(budget)
}

// Swift ledger counters are Int64. This is representation validation, not a
// movie-size policy or truncating/clamping conversion. Reject before ticket issue.
fn native_integer(value: u64) -> Result<(), PolicyError> {
    i64::try_from(value)
        .map(|_| ())
        .map_err(|_| PolicyError::NativeCounterOverflow)
}

fn validate_native_inputs(
    facts: &ImmichLockedVideoStorageFacts,
    now_ms: u64,
    members: &[MemberSize; 2],
    representations: &[Representation],
) -> Result<(), PolicyError> {
    for value in [
        now_ms,
        facts.deadline_unix_milliseconds,
        facts.available_bytes,
        facts.other_unallocated_bytes,
        facts.allocation_unit_bytes,
        PRIVATE_MEDIA_HEADROOM_BYTES,
    ] {
        native_integer(value)?;
    }
    for member in members {
        if let Some(bytes) = member.expected_bytes {
            native_integer(bytes)?;
        }
    }
    for representation in representations {
        native_integer(representation.maximum_bytes)?;
    }
    Ok(())
}

fn validate_native_output(budget: &PairedBudget) -> Result<(), PolicyError> {
    for value in [
        budget.minimum_remaining_bytes,
        budget.allocation_unit_bytes,
        budget.pair_disk_ceiling_bytes,
        budget.representation_reservation_bytes,
        budget.total_max_received_bytes,
        budget.initial_claim_bytes,
    ] {
        native_integer(value)?;
    }
    for member in &budget.members {
        native_integer(member.max_received_bytes)?;
        native_integer(member.initial_claim_bytes)?;
    }
    for representation in &budget.representations {
        native_integer(representation.rounded_reservation_bytes)?;
    }
    Ok(())
}

fn validate_quote(facts: &ImmichLockedVideoStorageFacts, now_ms: u64) -> Result<(), PolicyError> {
    crate::immich::valid_id(&facts.lease_id).map_err(|_| PolicyError::InvalidQuote)?;
    crate::immich::valid_id(&facts.measurement_nonce).map_err(|_| PolicyError::InvalidQuote)?;
    if facts.deadline_unix_milliseconds <= now_ms || facts.allocation_unit_bytes == 0 {
        return Err(PolicyError::InvalidQuote);
    }
    Ok(())
}

fn order_members(members: [MemberSize; 2]) -> Result<[MemberSize; 2], PolicyError> {
    let [first, second] = members;
    if first.key == second.key {
        return Err(PolicyError::InvalidMembers);
    }
    match (first.role, second.role) {
        (MemberRole::Parent, MemberRole::Motion) => Ok([first, second]),
        (MemberRole::Motion, MemberRole::Parent) => Ok([second, first]),
        _ => Err(PolicyError::InvalidMembers),
    }
}

fn member_budget(member: MemberSize, total: u64, unit: u64) -> Result<MemberBudget, PolicyError> {
    let (maximum, mode, initial) = match member.expected_bytes {
        Some(0) => return Err(PolicyError::MalformedSize),
        Some(bytes) if bytes > total => return Err(PolicyError::InsufficientCapacity),
        Some(bytes) => (
            bytes,
            ImmichLockedVideoCommitmentMode::FullUpfront,
            round_up(bytes, unit)?,
        ),
        None => (total, ImmichLockedVideoCommitmentMode::Incremental, unit),
    };
    Ok(MemberBudget {
        role: member.role,
        key: member.key,
        expected_bytes: member.expected_bytes,
        max_received_bytes: maximum,
        commitment_mode: mode,
        initial_claim_bytes: initial,
    })
}

fn representation_budgets(
    representations: &[Representation],
    unit: u64,
) -> Result<Vec<RepresentationBudget>, PolicyError> {
    let mut names = BTreeSet::new();
    representations
        .iter()
        .map(|representation| {
            if representation.name.is_empty() || !names.insert(&representation.name) {
                return Err(PolicyError::InvalidRepresentation);
            }
            Ok(RepresentationBudget {
                name: representation.name.clone(),
                maximum_bytes: representation.maximum_bytes,
                rounded_reservation_bytes: round_up(representation.maximum_bytes, unit)?,
            })
        })
        .collect()
}

fn checked_sum(values: impl IntoIterator<Item = u64>) -> Result<u64, PolicyError> {
    values.into_iter().try_fold(0_u64, |sum, value| {
        sum.checked_add(value)
            .ok_or(PolicyError::ArithmeticOverflow)
    })
}

#[cfg(test)]
#[path = "policy_tests.rs"]
mod tests;
