//! Synthetic issuers are confined to cfg(test); no HTTP/native acceptance claim.
use super::super::policy::{MemberSize, construct_budget};
use super::*;
use crate::immich_locked::video::{ImmichLockedVideoCapacityClass, ImmichLockedVideoStorageFacts};
use std::time::Duration;

type TestResult = Result<(), Error>;
const IDS: [&str; 7] = [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333",
    "44444444-4444-4444-8444-444444444444",
    "55555555-5555-4555-8555-555555555555",
    "66666666-6666-4666-8666-666666666666",
    "77777777-7777-4777-8777-777777777777",
];
fn at(start: Instant, seconds: u64) -> Instant {
    start + Duration::from_secs(seconds)
}
fn key(index: usize) -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "server#owner".into(),
        asset_id: IDS[index].into(),
    }
}
fn initial(start: Instant) -> Result<InitialProof, Error> {
    initial_with_sizes(start, [Some(3), Some(7)])
}
fn initial_with_sizes(start: Instant, sizes: [Option<u64>; 2]) -> Result<InitialProof, Error> {
    let members = [
        MemberSize {
            role: MemberRole::Parent,
            key: key(0),
            expected_bytes: sizes[0],
        },
        MemberSize {
            role: MemberRole::Motion,
            key: key(1),
            expected_bytes: sizes[1],
        },
    ];
    let facts = ImmichLockedVideoStorageFacts {
        lease_id: IDS[5].into(),
        measurement_nonce: IDS[6].into(),
        deadline_unix_milliseconds: 2000,
        available_bytes: super::super::PRIVATE_MEDIA_HEADROOM_BYTES + 8 * 4096,
        other_unallocated_bytes: 0,
        allocation_unit_bytes: 4096,
        capacity_class: ImmichLockedVideoCapacityClass::Available,
    };
    let budget = construct_budget(&facts, 1000, members, &[]).map_err(|_| Error::InvalidProof)?;
    let evidence = PairEvidence {
        members: [
            Fingerprint {
                key: key(0),
                kind: MediaKind::Image,
                revision: "p1".into(),
                sha1: "1".repeat(40),
                placement: crate::immich_live_resources::LiveObservedVisibility::Locked,
            },
            Fingerprint {
                key: key(1),
                kind: MediaKind::Video,
                revision: "m1".into(),
                sha1: "2".repeat(40),
                placement: crate::immich_live_resources::LiveObservedVisibility::Hidden,
            },
        ],
        forward_motion: key(1),
    };
    Ok(InitialProof {
        contract: Arc::new(FixedContract {
            identity: Identity {
                request_id: IDS[2].into(),
                plan_id: IDS[6].into(),
                scene_id: IDS[3].into(),
                grant_id: IDS[4].into(),
                generation: 1,
            },
            pair_lease_id: facts.lease_id,
            quote_nonce: facts.measurement_nonce,
            evidence,
            budget,
            initial_lease: Lease {
                id: 1,
                deadline: at(start, 10),
            },
            hardcap: at(start, 100),
        }),
        epoch: Arc::new(AtomicU64::new(1)),
        captured_epoch: 1,
        began_at: start,
        observed_at: start,
    })
}
fn fixture(start: Instant) -> Result<PairCoordinator, Error> {
    PairCoordinator::start(initial(start)?, start)
}
fn proof(capture: Capture, observed_at: Instant, deadline: Instant) -> PairProof {
    PairProof {
        evidence: capture.contract.evidence.clone(),
        capture,
        observed_at,
        status_deadline: deadline,
    }
}
fn original(ticket: StageTicket, lease: u64) -> Result<StageReceipt, Error> {
    let index = ticket.kind.index();
    let expected = ticket.contract.budget.members[index]
        .expected_bytes
        .ok_or(Error::InvalidProof)?;
    Ok(StageReceipt {
        pair_lease_id: ticket.contract.pair_lease_id.clone(),
        actual_completion_lease: lease,
        payload: Payload::Original {
            sha1: ticket.contract.evidence.members[index].sha1.clone(),
            signature: FileSignature {
                sha256: "a".repeat(64),
                bytes: expected,
            },
        },
        ticket,
    })
}
fn prepared(ticket: StageTicket, lease: u64) -> StageReceipt {
    StageReceipt {
        pair_lease_id: ticket.contract.pair_lease_id.clone(),
        actual_completion_lease: lease,
        payload: Payload::Prepared {
            prepared_id: IDS[6].into(),
        },
        ticket,
    }
}
fn begin(coordinator: &PairCoordinator, kind: Stage, now: Instant) -> Result<StageTicket, Error> {
    let capture = coordinator.capture_stage_start(kind, now)?;
    coordinator.begin_stage(proof(capture, now, coordinator.contract.hardcap), now)
}
fn finish(coordinator: &PairCoordinator, kind: Stage, now: Instant) -> TestResult {
    let ticket = begin(coordinator, kind, now)?;
    let lease = coordinator.lock()?.acknowledged;
    let receipt = if kind == Stage::Prepare {
        prepared(ticket, lease)
    } else {
        original(ticket, lease)?
    };
    coordinator.receive_stage(receipt, now)?;
    let capture = coordinator.capture_stage_check(kind, now)?;
    coordinator.accept_stage_check(proof(capture, now, coordinator.contract.hardcap), now)
}
fn ready(coordinator: &PairCoordinator, now: Instant) -> TestResult {
    finish(coordinator, Stage::Parent, now)?;
    finish(coordinator, Stage::Motion, now)?;
    finish(coordinator, Stage::Prepare, now)
}
fn renew(
    coordinator: &PairCoordinator,
    now: Instant,
    deadline: Instant,
    acknowledge_by: Instant,
) -> Result<RenewalCommand, Error> {
    let capture = coordinator.capture_heartbeat(now)?;
    coordinator.propose_successor(proof(capture, now, deadline), acknowledge_by, now)
}
fn provisional(
    coordinator: &PairCoordinator,
    now: Instant,
    acknowledge_by: Instant,
) -> Result<ProvisionalAccess, Error> {
    let capture = coordinator.capture_final_check(now)?;
    coordinator.provisional_access(
        proof(capture, now, coordinator.contract.hardcap),
        acknowledge_by,
        now,
    )
}

#[test]
fn initial_and_awaited_proof_require_captured_epoch_not_current_rebinding() -> TestResult {
    let start = Instant::now();
    let initial = initial(start)?;
    initial.epoch.store(2, Ordering::SeqCst);
    assert!(matches!(
        PairCoordinator::start(initial, start),
        Err(Error::Revoked)
    ));
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_heartbeat(start)?;
    coordinator.epoch.store(2, Ordering::SeqCst);
    assert!(matches!(
        coordinator.propose_successor(proof(capture, start, at(start, 20)), at(start, 8), start),
        Err(Error::Revoked)
    ));
    coordinator.epoch.store(1, Ordering::SeqCst);
    assert!(matches!(
        coordinator.capture_heartbeat(start),
        Err(Error::Terminal)
    ));
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn successor_completion_is_held_until_one_pair_ack_and_fresh_proof() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.receive_stage(original(ticket, command.successor.id)?, start)?;
    assert!(matches!(
        coordinator.capture_stage_check(Stage::Parent, start),
        Err(Error::Busy)
    ));
    assert!(matches!(
        begin(&coordinator, Stage::Motion, start),
        Err(Error::Busy)
    ));
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    assert!(matches!(coordinator.lock()?.slots[0], Slot::Held(_)));
    let capture = coordinator.capture_stage_check(Stage::Parent, start)?;
    coordinator.accept_stage_check(proof(capture, start, at(start, 20)), start)?;
    let machine = coordinator.lock()?;
    let Slot::Verified(receipt) = &machine.slots[0] else {
        return Err(Error::OutOfOrder);
    };
    assert_eq!(receipt.actual_completion_lease, 2);
    Ok(())
}

#[test]
fn predecessor_completion_keeps_actual_lease_and_pre_ack_proof_is_stale() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    coordinator.receive_stage(original(ticket, 1)?, start)?;
    let before_ack = coordinator.capture_stage_check(Stage::Parent, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    assert_eq!(
        coordinator.accept_stage_check(proof(before_ack, start, at(start, 20)), start),
        Err(Error::Stale)
    );
    let after_ack = coordinator.capture_stage_check(Stage::Parent, start)?;
    coordinator.accept_stage_check(proof(after_ack, start, at(start, 20)), start)?;
    let machine = coordinator.lock()?;
    let Slot::Verified(receipt) = &machine.slots[0] else {
        return Err(Error::OutOfOrder);
    };
    assert_eq!(receipt.actual_completion_lease, 1);
    Ok(())
}

#[test]
fn three_stage_slots_are_bounded_and_duplicate_cannot_overwrite() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let parent = begin(&coordinator, Stage::Parent, start)?;
    let motion = begin(&coordinator, Stage::Motion, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    let receipt = original(parent, 1)?;
    coordinator.receive_stage(receipt.clone(), start)?;
    assert_eq!(
        coordinator.receive_stage(receipt, start),
        Err(Error::OutOfOrder)
    );
    coordinator.receive_stage(original(motion, 2)?, start)?;
    assert!(matches!(
        begin(&coordinator, Stage::Prepare, start),
        Err(Error::Busy)
    ));
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    for kind in [Stage::Parent, Stage::Motion] {
        let capture = coordinator.capture_stage_check(kind, start)?;
        coordinator.accept_stage_check(proof(capture, start, at(start, 20)), start)?;
    }
    let ticket = begin(&coordinator, Stage::Prepare, start)?;
    let command = renew(&coordinator, start, at(start, 30), at(start, 15))?;
    coordinator.receive_stage(prepared(ticket, 2), start)?;
    assert_eq!(coordinator.lock()?.slots.len(), 3);
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    let capture = coordinator.capture_stage_check(Stage::Prepare, start)?;
    coordinator.accept_stage_check(proof(capture, start, at(start, 30)), start)?;
    assert!(
        coordinator
            .lock()?
            .slots
            .iter()
            .all(|slot| matches!(slot, Slot::Verified(_)))
    );
    Ok(())
}

#[test]
fn second_candidate_and_wrong_pair_ack_do_not_authorize_progress() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    assert!(matches!(
        coordinator.capture_heartbeat(start),
        Err(Error::Busy)
    ));
    let mut wrong = command;
    wrong.successor.id += 1;
    assert_eq!(
        coordinator.acknowledge_successor(RenewalReceipt { command: wrong }, start),
        Err(Error::InvalidReceipt)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    assert!(matches!(
        coordinator.capture_heartbeat(start),
        Err(Error::Terminal)
    ));
    Ok(())
}

#[test]
fn delayed_positive_status_cannot_renew_expired_predecessor() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_heartbeat(start)?;
    assert!(matches!(
        coordinator.propose_successor(
            proof(capture, at(start, 1), at(start, 1000)),
            at(start, 15),
            at(start, 10)
        ),
        Err(Error::Expired)
    ));
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn hardcap_clamps_successor_without_changing_initial_contract() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let fixed = coordinator.contract.clone();
    let command = renew(&coordinator, start, at(start, 1000), at(start, 8))?;
    assert_eq!(command.successor.deadline, at(start, 100));
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    assert!(Arc::ptr_eq(&fixed, &coordinator.contract));
    assert_eq!(coordinator.contract.initial_lease.id, 1);
    assert_eq!(coordinator.contract.initial_lease.deadline, at(start, 10));
    assert_eq!(coordinator.contract.budget.members[1].max_received_bytes, 7);
    assert_eq!(
        coordinator.poll_deadlines(at(start, 100)),
        Err(Error::Expired)
    );
    Ok(())
}

#[test]
fn native_old_expiry_winning_before_ack_terminalizes_both_members() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let parent = begin(&coordinator, Stage::Parent, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.native_expiry_won(NativeExpiryReceipt {
        owner: coordinator.owner.clone(),
        lease_id: 1,
    })?;
    assert_eq!(
        coordinator.acknowledge_successor(RenewalReceipt { command }, start),
        Err(Error::Terminal)
    );
    assert_eq!(
        coordinator.receive_stage(original(parent, 1)?, start),
        Err(Error::Terminal)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn acknowledged_successor_makes_old_expiry_stale_not_authority() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    assert_eq!(
        coordinator.native_expiry_won(NativeExpiryReceipt {
            owner: coordinator.owner.clone(),
            lease_id: 1
        }),
        Err(Error::Stale)
    );
    assert!(begin(&coordinator, Stage::Parent, at(start, 11)).is_ok());
    assert!(coordinator.cleanup_obligation()?.is_none());
    Ok(())
}

#[test]
fn missing_ack_times_out_and_never_reuses_held_completion() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.receive_stage(original(ticket, 2)?, start)?;
    assert_eq!(
        coordinator.poll_deadlines(at(start, 8)),
        Err(Error::Expired)
    );
    assert_eq!(
        coordinator.acknowledge_successor(RenewalReceipt { command }, at(start, 9)),
        Err(Error::Terminal)
    );
    assert!(
        coordinator
            .lock()?
            .slots
            .iter()
            .all(|slot| matches!(slot, Slot::Empty))
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn fresh_pair_drift_after_ack_terminates_instead_of_advancing() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    coordinator.receive_stage(original(ticket, 1)?, start)?;
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    let capture = coordinator.capture_stage_check(Stage::Parent, start)?;
    let mut drift = proof(capture, start, at(start, 20));
    drift.evidence.members[1].revision = "changed".into();
    assert_eq!(
        coordinator.accept_stage_check(drift, start),
        Err(Error::InvalidProof)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn provisional_access_is_not_publication_and_lost_receipt_retains_cleanup() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    ready(&coordinator, start)?;
    let access = provisional(&coordinator, start, at(start, 5))?;
    assert!(matches!(
        coordinator.lock()?.phase,
        Phase::AwaitingPublication { .. }
    ));
    assert_eq!(
        coordinator.poll_deadlines(at(start, 5)),
        Err(Error::Expired)
    );
    let obligation = coordinator.cleanup_obligation()?.ok_or(Error::OutOfOrder)?;
    assert_eq!(obligation.extent, CleanupExtent::PossiblyPublished);
    assert_eq!(
        obligation.contract.pair_lease_id,
        coordinator.contract.pair_lease_id
    );
    assert_eq!(
        coordinator.acknowledge_publication(
            NativePublicationReceipt {
                access,
                publication_id: IDS[6].into()
            },
            at(start, 6)
        ),
        Err(Error::Terminal)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn publication_then_old_acquisition_expiry_is_inert_but_hardcap_is_not() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    ready(&coordinator, start)?;
    let access = provisional(&coordinator, start, at(start, 5))?;
    coordinator.acknowledge_publication(
        NativePublicationReceipt {
            access,
            publication_id: IDS[6].into(),
        },
        start,
    )?;
    assert_eq!(
        coordinator.native_expiry_won(NativeExpiryReceipt {
            owner: coordinator.owner.clone(),
            lease_id: 1
        }),
        Err(Error::Stale)
    );
    coordinator.poll_deadlines(at(start, 11))?;
    let machine = coordinator.lock()?;
    let Phase::Published { publication_id } = &machine.phase else {
        return Err(Error::OutOfOrder);
    };
    assert_eq!(publication_id, IDS[6]);
    drop(machine);
    assert_eq!(
        coordinator.poll_deadlines(at(start, 100)),
        Err(Error::Expired)
    );
    assert_eq!(
        coordinator
            .cleanup_obligation()?
            .ok_or(Error::OutOfOrder)?
            .extent,
        CleanupExtent::PossiblyPublished
    );
    Ok(())
}

#[test]
fn expiry_before_publication_receipt_cannot_be_reversed() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    ready(&coordinator, start)?;
    let access = provisional(&coordinator, start, at(start, 5))?;
    coordinator.native_expiry_won(NativeExpiryReceipt {
        owner: coordinator.owner.clone(),
        lease_id: 1,
    })?;
    assert_eq!(
        coordinator.acknowledge_publication(
            NativePublicationReceipt {
                access,
                publication_id: IDS[6].into()
            },
            start
        ),
        Err(Error::Terminal)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn replacement_with_same_contract_rejects_old_heartbeat_completion_and_join() -> TestResult {
    let start = Instant::now();
    let previous = fixture(start)?;
    let old_capture = previous.capture_heartbeat(start)?;
    let old_ticket = begin(&previous, Stage::Parent, start)?;
    previous.stop()?;
    let replacement = PairCoordinator::start(
        InitialProof {
            contract: previous.contract.clone(),
            epoch: previous.epoch.clone(),
            captured_epoch: 1,
            began_at: start,
            observed_at: start,
        },
        start,
    )?;
    assert!(matches!(
        replacement.propose_successor(
            proof(old_capture, start, at(start, 20)),
            at(start, 8),
            start
        ),
        Err(Error::Stale)
    ));
    assert_eq!(
        replacement.receive_stage(original(old_ticket, 1)?, start),
        Err(Error::Stale)
    );
    assert_eq!(
        replacement.acknowledge_join(NativeJoinReceipt {
            owner: previous.owner.clone(),
            extent: CleanupExtent::Acquisition,
        }),
        Err(Error::Stale)
    );
    assert!(replacement.cleanup_obligation()?.is_none());
    assert!(begin(&replacement, Stage::Parent, start).is_ok());
    previous.acknowledge_join(NativeJoinReceipt {
        owner: previous.owner.clone(),
        extent: CleanupExtent::Acquisition,
    })?;
    assert!(previous.cleanup_obligation()?.is_none());
    assert!(matches!(replacement.lock()?.slots[0], Slot::InFlight(_)));
    Ok(())
}

#[test]
fn wrong_stage_lease_and_signature_fail_before_preparation() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    assert!(matches!(
        begin(&coordinator, Stage::Prepare, start),
        Err(Error::OutOfOrder)
    ));
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    let mut receipt = original(ticket, 1)?;
    receipt.pair_lease_id = IDS[0].into();
    assert_eq!(
        coordinator.receive_stage(receipt, start),
        Err(Error::InvalidReceipt)
    );
    let other = fixture(start)?;
    let ticket = begin(&other, Stage::Motion, start)?;
    let mut receipt = original(ticket, 1)?;
    if let Payload::Original { signature, .. } = &mut receipt.payload {
        signature.bytes += 1;
    }
    assert_eq!(
        other.receive_stage(receipt, start),
        Err(Error::InvalidReceipt)
    );
    assert!(other.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn successor_delta_is_floored_and_never_reanchored_at_receipt_time() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_heartbeat(start)?;
    let bound = at(start, 20) + Duration::from_nanos(999_999);
    let command =
        coordinator.propose_successor(proof(capture, start, bound), at(start, 15), start)?;
    assert_eq!(command.extension_milliseconds, 10_000);
    assert_eq!(command.successor.deadline, at(start, 20));
    // A native CAS may have won before old expiry while its ACK is delivered later.
    // This mocked opaque receipt does not prove an actual native CAS took place.
    coordinator.acknowledge_successor(RenewalReceipt { command }, at(start, 11))?;
    assert_eq!(coordinator.lock()?.current.deadline, at(start, 20));
    Ok(())
}

#[test]
fn expired_or_drifted_final_proof_cannot_emit_provisional_access() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    ready(&coordinator, start)?;
    let capture = coordinator.capture_final_check(start)?;
    let mut stale = proof(capture, start, at(start, 20));
    stale.evidence.forward_motion = key(0);
    assert!(matches!(
        coordinator.provisional_access(stale, at(start, 5), start),
        Err(Error::InvalidProof)
    ));
    assert!(coordinator.cleanup_obligation()?.is_some());
    let other = fixture(start)?;
    ready(&other, start)?;
    let capture = other.capture_final_check(start)?;
    assert!(matches!(
        other.provisional_access(proof(capture, start, start), at(start, 5), start),
        Err(Error::InvalidProof)
    ));
    assert!(other.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn original_receipts_must_fit_shared_t_not_just_each_m() -> TestResult {
    let start = Instant::now();
    let coordinator = PairCoordinator::start(initial_with_sizes(start, [None, None])?, start)?;
    let total = coordinator.contract.budget.total_max_received_bytes;
    for kind in [Stage::Parent, Stage::Motion] {
        let ticket = begin(&coordinator, kind, start)?;
        let receipt = StageReceipt {
            pair_lease_id: coordinator.contract.pair_lease_id.clone(),
            actual_completion_lease: 1,
            payload: Payload::Original {
                sha1: coordinator.contract.evidence.members[kind.index()]
                    .sha1
                    .clone(),
                signature: FileSignature {
                    sha256: "a".repeat(64),
                    bytes: total / 2 + 1,
                },
            },
            ticket,
        };
        let result = coordinator.receive_stage(receipt, start);
        if kind == Stage::Parent {
            result?;
        } else {
            assert_eq!(result, Err(Error::InvalidReceipt));
        }
    }
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn late_old_publication_cannot_consume_replacement_publication() -> TestResult {
    let start = Instant::now();
    let previous = fixture(start)?;
    ready(&previous, start)?;
    let old_access = provisional(&previous, start, at(start, 5))?;
    previous.stop()?;
    let replacement = fixture(start)?;
    ready(&replacement, start)?;
    let new_access = provisional(&replacement, start, at(start, 5))?;
    assert_eq!(
        replacement.acknowledge_publication(
            NativePublicationReceipt {
                access: old_access,
                publication_id: IDS[5].into()
            },
            start
        ),
        Err(Error::Stale)
    );
    assert!(matches!(
        replacement.lock()?.phase,
        Phase::AwaitingPublication { .. }
    ));
    replacement.acknowledge_publication(
        NativePublicationReceipt {
            access: new_access,
            publication_id: IDS[6].into(),
        },
        start,
    )?;
    assert!(matches!(replacement.lock()?.phase, Phase::Published { .. }));
    assert!(previous.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn native_stage_ticket_cannot_be_issued_without_fresh_typed_pair_evidence() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_stage_start(Stage::Parent, start)?;
    let mut changed = proof(capture, start, at(start, 20));
    changed.evidence.members[0].sha1 = "f".repeat(40);
    assert!(matches!(
        coordinator.begin_stage(changed, start),
        Err(Error::InvalidProof)
    ));
    assert!(
        coordinator
            .lock()?
            .slots
            .iter()
            .all(|slot| matches!(slot, Slot::Empty))
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn stage_started_after_ack_cannot_claim_older_completion_lease() -> TestResult {
    for kind in [Stage::Parent, Stage::Motion, Stage::Prepare] {
        let start = Instant::now();
        let coordinator = fixture(start)?;
        if kind == Stage::Prepare {
            finish(&coordinator, Stage::Parent, start)?;
            finish(&coordinator, Stage::Motion, start)?;
        }
        let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
        coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
        let ticket = begin(&coordinator, kind, start)?;
        assert_eq!(ticket.start_acknowledged_lease, 2);
        let receipt = if kind == Stage::Prepare {
            prepared(ticket, 1)
        } else {
            original(ticket, 1)?
        };
        assert_eq!(
            coordinator.receive_stage(receipt, start),
            Err(Error::InvalidReceipt)
        );
        assert!(coordinator.cleanup_obligation()?.is_some());
    }
    Ok(())
}

#[test]
fn stage_started_under_one_can_complete_under_one_after_ack_two() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let ticket = begin(&coordinator, Stage::Parent, start)?;
    assert_eq!(ticket.start_acknowledged_lease, 1);
    let command = renew(&coordinator, start, at(start, 20), at(start, 8))?;
    coordinator.acknowledge_successor(RenewalReceipt { command }, start)?;
    coordinator.receive_stage(original(ticket, 1)?, start)?;
    let capture = coordinator.capture_stage_check(Stage::Parent, start)?;
    coordinator.accept_stage_check(proof(capture, start, at(start, 20)), start)?;
    let machine = coordinator.lock()?;
    let Slot::Verified(receipt) = &machine.slots[0] else {
        return Err(Error::OutOfOrder);
    };
    assert_eq!(receipt.actual_completion_lease, 1);
    Ok(())
}

#[test]
fn shorter_authority_before_stage_start_terminalizes_instead_of_using_old_lease() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_stage_start(Stage::Parent, start)?;
    assert!(matches!(
        coordinator.begin_stage(proof(capture, start, at(start, 9)), start),
        Err(Error::InvalidProof)
    ));
    assert!(
        coordinator
            .lock()?
            .slots
            .iter()
            .all(|slot| matches!(slot, Slot::Empty))
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn shorter_final_authority_cannot_leave_native_old_deadline_publishable() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    ready(&coordinator, start)?;
    let capture = coordinator.capture_final_check(start)?;
    assert!(matches!(
        coordinator.provisional_access(proof(capture, start, at(start, 9)), at(start, 5), start),
        Err(Error::InvalidProof)
    ));
    assert!(matches!(coordinator.lock()?.phase, Phase::Terminal));
    assert_eq!(
        coordinator
            .cleanup_obligation()?
            .ok_or(Error::OutOfOrder)?
            .extent,
        CleanupExtent::Acquisition
    );
    Ok(())
}

#[test]
fn shorter_renewal_authority_terminalizes_instead_of_retaining_old_native_lease() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_heartbeat(start)?;
    assert!(matches!(
        coordinator.propose_successor(proof(capture, start, at(start, 9)), at(start, 5), start),
        Err(Error::InvalidProof)
    ));
    assert!(coordinator.lock()?.candidate.is_none());
    assert!(matches!(
        coordinator.capture_heartbeat(start),
        Err(Error::Terminal)
    ));
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn shorter_post_completion_authority_terminalizes_and_equal_bound_is_not_shorter() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let capture = coordinator.capture_stage_start(Stage::Parent, start)?;
    let ticket = coordinator.begin_stage(proof(capture, start, at(start, 10)), start)?;
    coordinator.receive_stage(original(ticket, 1)?, start)?;
    let capture = coordinator.capture_stage_check(Stage::Parent, start)?;
    assert_eq!(
        coordinator.accept_stage_check(proof(capture, start, at(start, 9)), start),
        Err(Error::InvalidProof)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}

#[test]
fn fractional_status_bound_uses_same_floored_successor_for_ack_without_extension() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let bound = at(start, 15) + Duration::from_nanos(123);
    let observed = proof(coordinator.capture_heartbeat(start)?, start, bound);
    let acknowledge_by = coordinator.renewal_acknowledgement_deadline(&observed)?;
    assert_eq!(acknowledge_by, at(start, 15));
    assert!(acknowledge_by < bound);
    let command = coordinator.propose_successor(observed, acknowledge_by, start)?;
    assert_eq!(command.successor.deadline, at(start, 15));
    assert_eq!(command.extension_milliseconds, 5_000);
    let other = fixture(start)?;
    let observed = proof(other.capture_heartbeat(start)?, start, bound);
    assert!(matches!(
        other.propose_successor(observed, bound, start),
        Err(Error::InvalidProof)
    ));
    Ok(())
}

#[test]
fn issued_initial_wire_is_stable_across_delayed_views_without_renewing_liveness() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let first = coordinator.leases().map_err(|_| Error::InvalidProof)?;
    std::thread::sleep(Duration::from_millis(2));
    assert_eq!(
        coordinator.leases().map_err(|_| Error::InvalidProof)?,
        first
    );
    assert_eq!(first.0.lease_id, 1);
    assert_eq!(first.0.extension_milliseconds, 0);
    assert!(first.0.remaining_milliseconds > 0);
    // Retained issuance observations are not fresh authority at the monotonic deadline.
    assert!(matches!(
        coordinator.capture_heartbeat(at(start, 10)),
        Err(Error::Expired)
    ));
    Ok(())
}

#[test]
fn issued_candidate_wire_matches_effect_and_views_and_survives_ack_unchanged() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let command = coordinator.propose_successor(
        proof(coordinator.capture_heartbeat(start)?, start, at(start, 20)),
        at(start, 15),
        start,
    )?;
    let effect = PairCoordinator::renewal_wire(&command);
    let projected = coordinator.leases().map_err(|_| Error::InvalidProof)?;
    assert_eq!(effect.0, 1);
    assert_eq!(projected.1, 1);
    assert_eq!(effect.1, projected.0);
    assert_eq!(effect.1.extension_milliseconds, 10_000);
    std::thread::sleep(Duration::from_millis(2));
    assert_eq!(
        coordinator.leases().map_err(|_| Error::InvalidProof)?,
        projected
    );
    assert_eq!(PairCoordinator::renewal_wire(&command), effect);
    coordinator.acknowledge_successor(RenewalReceipt { command }, at(start, 1))?;
    let acknowledged = coordinator.leases().map_err(|_| Error::InvalidProof)?;
    assert_eq!(acknowledged.0, effect.1);
    assert_eq!(acknowledged.1, 2);
    Ok(())
}

#[test]
fn stable_issued_wire_cannot_make_old_candidate_receipt_authorize_new_candidate() -> TestResult {
    let start = Instant::now();
    let coordinator = fixture(start)?;
    let old = coordinator.propose_successor(
        proof(coordinator.capture_heartbeat(start)?, start, at(start, 20)),
        at(start, 15),
        start,
    )?;
    coordinator.acknowledge_successor(
        RenewalReceipt {
            command: old.clone(),
        },
        at(start, 1),
    )?;
    let next = coordinator.propose_successor(
        proof(
            coordinator.capture_heartbeat(at(start, 2))?,
            at(start, 2),
            at(start, 30),
        ),
        at(start, 25),
        at(start, 2),
    )?;
    assert_eq!(
        coordinator.leases().map_err(|_| Error::InvalidProof)?.0,
        next.issued_wire
    );
    assert_eq!(
        coordinator.acknowledge_successor(RenewalReceipt { command: old }, at(start, 3)),
        Err(Error::InvalidReceipt)
    );
    assert!(coordinator.cleanup_obligation()?.is_some());
    Ok(())
}
