use super::*;
use crate::{domain::Provider, immich_locked::video::ImmichLockedVideoCapacityClass};
use serde_json::json;

const UNIT: u64 = 4096;
const NOW: u64 = 1000;
type TestResult = Result<(), PolicyError>;

fn signed_maximum() -> Result<u64, PolicyError> {
    u64::try_from(i64::MAX).map_err(|_| PolicyError::NativeCounterOverflow)
}
fn quote(units: u64) -> ImmichLockedVideoStorageFacts {
    ImmichLockedVideoStorageFacts {
        lease_id: "11111111-1111-4111-8111-111111111111".into(),
        measurement_nonce: "22222222-2222-4222-8222-222222222222".into(),
        deadline_unix_milliseconds: NOW + 1,
        available_bytes: PRIVATE_MEDIA_HEADROOM_BYTES + units * UNIT,
        other_unallocated_bytes: 0,
        allocation_unit_bytes: UNIT,
        capacity_class: ImmichLockedVideoCapacityClass::ImportantUsage,
    }
}
fn members(parent: Option<u64>, motion: Option<u64>) -> [MemberSize; 2] {
    [
        MemberSize {
            role: MemberRole::Parent,
            key: AssetKey {
                provider: Provider::Immich,
                scope: "server#owner".into(),
                asset_id: "parent".into(),
            },
            expected_bytes: parent,
        },
        MemberSize {
            role: MemberRole::Motion,
            key: AssetKey {
                provider: Provider::Immich,
                scope: "server#owner".into(),
                asset_id: "motion".into(),
            },
            expected_bytes: motion,
        },
    ]
}
fn representation(name: &str, bytes: u64) -> Representation {
    Representation {
        name: name.into(),
        maximum_bytes: bytes,
    }
}

#[test]
fn checked_subtractions_and_floor_preserve_headroom_and_other_consumers() -> TestResult {
    let mut facts = quote(8);
    facts.available_bytes += UNIT - 1;
    facts.other_unallocated_bytes = UNIT + 1;
    let budget = construct_budget(&facts, NOW, members(None, None), &[])?;
    assert_eq!(budget.pair_disk_ceiling_bytes, 7 * UNIT);
    assert_eq!(budget.total_max_received_bytes, 7 * UNIT);
    assert_eq!(budget.initial_claim_bytes, 2 * UNIT);
    assert_eq!(budget.minimum_remaining_bytes, PRIVATE_MEDIA_HEADROOM_BYTES);
    facts.available_bytes = PRIVATE_MEDIA_HEADROOM_BYTES - 1;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InsufficientCapacity)
    );
    facts.available_bytes = PRIVATE_MEDIA_HEADROOM_BYTES;
    facts.other_unallocated_bytes = 1;
    assert!(construct_budget(&facts, NOW, members(None, None), &[]).is_err());
    Ok(())
}

#[test]
fn known_maxima_are_exact_and_reservations_round_each_file_separately() -> TestResult {
    let budget = construct_budget(&quote(3), NOW, members(Some(1), Some(UNIT + 1)), &[])?;
    assert_eq!(budget.members[0].max_received_bytes, 1);
    assert_eq!(budget.members[1].max_received_bytes, UNIT + 1);
    assert_eq!(budget.members[0].initial_claim_bytes, UNIT);
    assert_eq!(budget.members[1].initial_claim_bytes, 2 * UNIT);
    assert!(
        budget
            .members
            .iter()
            .all(|member| member.commitment_mode == ImmichLockedVideoCommitmentMode::FullUpfront)
    );
    // Raw 2 bytes fit T=UNIT, but two physical files need two units.
    assert_eq!(
        construct_budget(&quote(1), NOW, members(Some(1), Some(1)), &[]),
        Err(PolicyError::InsufficientCapacity)
    );
    Ok(())
}

#[test]
fn unknown_maxima_overlap_but_do_not_reserve_full_maximum_twice() -> TestResult {
    let budget = construct_budget(
        &quote(4),
        NOW,
        members(None, None),
        &[representation("prepared-file", 1)],
    )?;
    assert_eq!(budget.pair_disk_ceiling_bytes, 4 * UNIT);
    assert_eq!(budget.representation_reservation_bytes, UNIT);
    assert_eq!(budget.total_max_received_bytes, 3 * UNIT);
    for member in &budget.members {
        assert_eq!(member.max_received_bytes, 3 * UNIT);
        assert_eq!(member.initial_claim_bytes, UNIT);
        assert_eq!(
            member.commitment_mode,
            ImmichLockedVideoCommitmentMode::Incremental
        );
    }
    assert_eq!(budget.initial_claim_bytes, 3 * UNIT);
    // A valid motion can exceed half T. These are contract arithmetic witnesses,
    // not native ledger approval: native must still enforce T/D/start credits.
    assert!(2 * UNIT > budget.total_max_received_bytes / 2);
    assert!(2 * UNIT < budget.total_max_received_bytes);
    assert_eq!(
        round_up(1, UNIT)? + round_up(2 * UNIT, UNIT)? + budget.representation_reservation_bytes,
        budget.pair_disk_ceiling_bytes
    );
    // Parent claiming 3u before motion starts would consume its sibling credit.
    assert!(
        3 * UNIT + budget.members[1].initial_claim_bytes + budget.representation_reservation_bytes
            > budget.pair_disk_ceiling_bytes
    );
    Ok(())
}

#[test]
fn mixed_sizes_require_known_round_plus_unknown_positive_start_and_extra() -> TestResult {
    let extra = [representation("observable-copy", 1)];
    let budget = construct_budget(&quote(4), NOW, members(Some(UNIT + 1), None), &extra)?;
    assert_eq!(budget.initial_claim_bytes, 4 * UNIT);
    assert_eq!(budget.members[0].max_received_bytes, UNIT + 1);
    assert_eq!(budget.members[1].max_received_bytes, 3 * UNIT);
    assert_eq!(
        construct_budget(&quote(3), NOW, members(Some(UNIT + 1), None), &extra),
        Err(PolicyError::InsufficientCapacity)
    );
    assert_eq!(
        construct_budget(&quote(1), NOW, members(None, None), &[]),
        Err(PolicyError::InsufficientCapacity)
    );
    assert_eq!(
        construct_budget(&quote(2), NOW, members(None, Some(1)), &[])?.initial_claim_bytes,
        2 * UNIT
    );
    Ok(())
}

#[test]
fn named_representation_sum_rounds_individually_and_is_subtracted_only_once() -> TestResult {
    let extras = [representation("first", 1), representation("second", 1)];
    let budget = construct_budget(&quote(5), NOW, members(None, None), &extras)?;
    assert_eq!(budget.representation_reservation_bytes, 2 * UNIT);
    assert_eq!(budget.total_max_received_bytes, 3 * UNIT);
    assert_eq!(budget.initial_claim_bytes, 4 * UNIT);
    assert_eq!(budget.representations.len(), 2);
    assert_eq!(budget.representations[0].maximum_bytes, 1);
    assert_eq!(budget.representations[0].rounded_reservation_bytes, UNIT);
    assert_eq!(
        budget.total_max_received_bytes + budget.representation_reservation_bytes,
        budget.pair_disk_ceiling_bytes
    );
    assert_eq!(
        construct_budget(&quote(2), NOW, members(None, None), &extras),
        Err(PolicyError::InsufficientCapacity)
    );
    Ok(())
}

#[test]
fn representation_identity_zero_and_checked_overflow_fail_closed() -> TestResult {
    for extras in [
        vec![representation("", 1)],
        vec![representation("same", 1), representation("same", 2)],
        vec![representation("zero", 0)],
    ] {
        assert_eq!(
            construct_budget(&quote(8), NOW, members(None, None), &extras),
            Err(PolicyError::InvalidRepresentation)
        );
    }
    assert_eq!(round_up(u64::MAX, 2), Err(PolicyError::ArithmeticOverflow));
    assert_eq!(round_up(u64::MAX, 1), Ok(u64::MAX));
    assert_eq!(
        checked_sum([u64::MAX, 1]),
        Err(PolicyError::ArithmeticOverflow)
    );
    let mut facts = quote(8);
    facts.allocation_unit_bytes = 1;
    facts.available_bytes = signed_maximum()?;
    let extras = [
        representation("first", signed_maximum()?),
        representation("second", signed_maximum()?),
        representation("third", 2),
    ];
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &extras),
        Err(PolicyError::ArithmeticOverflow)
    );
    Ok(())
}

#[test]
fn valid_huge_unknown_budget_has_no_arbitrary_movie_cap() -> TestResult {
    let mut facts = quote(8);
    facts.available_bytes = signed_maximum()?;
    let budget = construct_budget(&facts, NOW, members(None, None), &[])?;
    let expected = (signed_maximum()? - PRIVATE_MEDIA_HEADROOM_BYTES) / UNIT * UNIT;
    assert_eq!(budget.total_max_received_bytes, expected);
    assert!(expected > 100 * 1024 * 1024 * 1024);
    assert_eq!(budget.members[1].max_received_bytes, expected);
    Ok(())
}

#[test]
fn malformed_quote_and_expired_deadline_reject_including_exact_now() -> TestResult {
    let mut facts = quote(4);
    facts.deadline_unix_milliseconds = NOW;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InvalidQuote)
    );
    facts = quote(4);
    facts.allocation_unit_bytes = 0;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InvalidQuote)
    );
    facts = quote(4);
    facts.measurement_nonce = "bad".into();
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InvalidQuote)
    );
    facts = quote(4);
    facts.lease_id = "bad".into();
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InvalidQuote)
    );
    facts = quote(4);
    facts.other_unallocated_bytes = signed_maximum()?;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::InsufficientCapacity)
    );
    Ok(())
}

#[test]
fn two_distinct_roles_and_keys_are_required_and_order_is_canonical() -> TestResult {
    let mut reversed = members(Some(1), None);
    reversed.swap(0, 1);
    let budget = construct_budget(&quote(4), NOW, reversed, &[])?;
    assert_eq!(budget.members[0].role, MemberRole::Parent);
    assert_eq!(budget.members[1].role, MemberRole::Motion);
    let mut same_role = members(None, None);
    same_role[1].role = MemberRole::Parent;
    assert_eq!(
        construct_budget(&quote(4), NOW, same_role, &[]),
        Err(PolicyError::InvalidMembers)
    );
    let mut same_key = members(None, None);
    same_key[1].key = same_key[0].key.clone();
    assert_eq!(
        construct_budget(&quote(4), NOW, same_key, &[]),
        Err(PolicyError::InvalidMembers)
    );
    Ok(())
}

#[test]
fn zero_known_size_or_size_above_t_is_not_reclassified_as_absent() {
    assert_eq!(
        construct_budget(&quote(4), NOW, members(Some(0), None), &[]),
        Err(PolicyError::MalformedSize)
    );
    let extras = [representation("extra", 1)];
    assert_eq!(
        construct_budget(&quote(4), NOW, members(Some(3 * UNIT + 1), None), &extras),
        Err(PolicyError::InsufficientCapacity)
    );
    assert_eq!(
        construct_budget(
            &quote(4),
            NOW,
            members(Some(2 * UNIT), Some(2 * UNIT)),
            &extras
        ),
        Err(PolicyError::InsufficientCapacity)
    );
}

#[test]
fn raw_receive_ceiling_does_not_promise_all_per_file_rounded_states_fit() -> TestResult {
    let budget = construct_budget(&quote(3), NOW, members(None, None), &[])?;
    let received = [UNIT + 1, UNIT + 1];
    assert!(received.into_iter().sum::<u64>() <= budget.total_max_received_bytes);
    assert!(
        received
            .into_iter()
            .all(|bytes| bytes <= budget.members[0].max_received_bytes)
    );
    assert!(
        round_up(received[0], UNIT)? + round_up(received[1], UNIT)?
            > budget.pair_disk_ceiling_bytes
    );
    // Native must reject that append, despite raw aggregate and both M passing.
    Ok(())
}

#[test]
fn absent_and_malformed_wire_metadata_remain_distinct() {
    for raw in [
        json!({}),
        json!({"exifInfo":null}),
        json!({"exifInfo":{}}),
        json!({"exifInfo":{"fileSizeInByte":null}}),
    ] {
        assert_eq!(expected_size(&raw), Ok(None));
    }
    assert_eq!(
        expected_size(&json!({"exifInfo":{"fileSizeInByte":u64::MAX}})),
        Ok(Some(u64::MAX))
    );
    for value in [
        json!(0),
        json!(-1),
        json!(1.0),
        json!(1.5),
        json!("1"),
        json!(true),
        json!([]),
        json!({}),
    ] {
        assert_eq!(
            expected_size(&json!({"exifInfo":{"fileSizeInByte":value}})),
            Err(PolicyError::MalformedSize)
        );
    }
    for raw in [json!(null), json!([]), json!(true), json!("asset")] {
        assert_eq!(expected_size(&raw), Err(PolicyError::MalformedSize));
    }
    assert_eq!(
        expected_size(&json!({"exifInfo":[]})),
        Err(PolicyError::MalformedSize)
    );
}

#[test]
fn native_signed_boundary_rejects_unrepresentable_values_without_clamping() -> TestResult {
    let largest = signed_maximum()?;
    assert_eq!(native_integer(largest), Ok(()));
    assert_eq!(
        native_integer(largest + 1),
        Err(PolicyError::NativeCounterOverflow)
    );
    let mut facts = quote(4);
    facts.available_bytes = largest + 1;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::NativeCounterOverflow)
    );
    facts = quote(4);
    facts.deadline_unix_milliseconds = largest + 1;
    assert_eq!(
        construct_budget(&facts, NOW, members(None, None), &[]),
        Err(PolicyError::NativeCounterOverflow)
    );
    assert_eq!(
        construct_budget(&quote(4), NOW, members(Some(largest + 1), None), &[]),
        Err(PolicyError::NativeCounterOverflow)
    );
    // A valid large known movie is not capped at a guessed media-size threshold.
    let mut facts = quote(4);
    facts.available_bytes = PRIVATE_MEDIA_HEADROOM_BYTES + 8 * 1024 * 1024 * 1024;
    let known = 5 * 1024 * 1024 * 1024;
    let budget = construct_budget(&facts, NOW, members(Some(1), Some(known)), &[])?;
    assert_eq!(budget.members[1].max_received_bytes, known);
    Ok(())
}

#[test]
fn live_effect_storage_does_not_exceed_preexisting_video_renewal_payload() {
    use crate::app::ShellOperation;
    use crate::immich_locked::video::{ImmichLockedVideoAcquisitionLease, ImmichLockedVideoTicket};
    use std::mem::{align_of, size_of};
    // VIDEO renewal already carries this full payload. Live wire expansion must not
    // enlarge every unrelated HTTP/Persist operation's by-value enum storage.
    type VideoRenewal = (
        ImmichLockedVideoTicket,
        u64,
        ImmichLockedVideoAcquisitionLease,
    );
    assert!(
        size_of::<ShellOperation>() <= size_of::<VideoRenewal>() + align_of::<ShellOperation>()
    );
}
