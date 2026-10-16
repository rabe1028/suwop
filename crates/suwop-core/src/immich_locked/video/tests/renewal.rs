//! Controlled reducer races. Renewal inputs represent an already successful exact heartbeat.
use super::super::renewal;
use super::*;
use std::time::{Duration, Instant};

fn acquiring_model() -> Result<Model, String> {
    let mut model = approved_model()?;
    model.immich_locked.video.access = None;
    let acquisition = model.immich_locked.video.binding.clone().ok_or("binding")?;
    let _ = acquisition::planned(
        &mut model,
        acquisition,
        Ok((Shell::new(raw()).storage, Some(123))),
    );
    Ok(model)
}
fn ticket(model: &Model) -> Result<ImmichLockedVideoTicket, String> {
    model
        .immich_locked
        .video
        .renewal
        .ticket
        .clone()
        .ok_or_else(|| "ticket".into())
}
fn candidate(model: &mut Model) -> Result<ImmichLockedVideoTicket, String> {
    let heartbeat = renewal::heartbeat(model).ok_or("heartbeat")?;
    let deadline = model
        .immich_locked
        .video
        .binding
        .as_ref()
        .ok_or("binding")?
        .current_capability()?
        .lease_deadline
        + Duration::from_secs(5);
    let _ = renewal::renew(model, Some(heartbeat), deadline);
    ticket(model)
}
fn acknowledge(model: &mut Model, ticket: &ImmichLockedVideoTicket) {
    let id = ticket.acquisition_lease.lease_id;
    let _ = update(
        Event::ImmichLockedVideoRenewalAcknowledged {
            pending: ticket.pending.clone(),
            staged_id: LEASE.into(),
            previous_lease_id: id - 1,
            lease_id: id,
            result: Ok(ImmichLockedVideoAcquisitionRenewed {
                request_id: REQUEST.into(),
                staged_id: LEASE.into(),
                previous_lease_id: id - 1,
                lease_id: id,
            }),
        },
        model,
    );
}
fn expire(model: &mut Model, id: u64) {
    let _ = update(
        Event::ExpireImmichLockedVideoAcquisition {
            scene_id: SCENE.into(),
            request_id: REQUEST.into(),
            generation: 0,
            lease_id: id,
        },
        model,
    );
}
#[test]
fn two_successors_keep_exact_storage_budget_and_acknowledge_only_the_issued_transition()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let first = ticket(&model)?;
    for id in 2..=3 {
        let next = candidate(&mut model)?;
        assert_eq!(next.acquisition_lease.lease_id, id);
        assert_eq!(next.acquisition_lease.extension_milliseconds, 5_000);
        assert_eq!(next.storage.lease_id, first.storage.lease_id);
        assert_eq!(next.max_received_bytes, first.max_received_bytes);
        assert_eq!(next.commitment_mode, first.commitment_mode);
        assert_eq!(next.storage, first.storage);
        assert_eq!(next.expected_sha1, first.expected_sha1);
        let projection = acquisition_projection(&model).ok_or("projection")?;
        assert_eq!(projection.acknowledged_lease_id, id - 1);
        assert!(!renewal::completion_current(&model, &first, 1));
        acknowledge(&mut model, &next);
        assert_eq!(
            acquisition_projection(&model)
                .ok_or("ack projection")?
                .acknowledged_lease_id,
            id
        );
        assert!(
            renewal::completion_current(&model, &first, 1),
            "prior completion has an explicit continuous live chain"
        );
    }
    Ok(())
}
#[test]
fn expiry_before_native_cas_terminalizes_candidate_and_late_ack_cannot_resurrect()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let next = candidate(&mut model)?;
    expire(&mut model, 1);
    acknowledge(&mut model, &next);
    assert!(model.immich_locked.video.pending.is_none());
    assert!(acquisition_projection(&model).is_none());
    Ok(())
}
#[test]
fn ack_before_old_expiry_preserves_successor_but_missing_ack_cannot_outlive_candidate()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let next = candidate(&mut model)?;
    acknowledge(&mut model, &next);
    expire(&mut model, 1);
    assert_eq!(
        acquisition_projection(&model)
            .ok_or("current successor")?
            .lease
            .lease_id,
        2
    );
    let next = candidate(&mut model)?;
    expire(&mut model, next.acquisition_lease.lease_id);
    acknowledge(&mut model, &next);
    assert!(model.immich_locked.video.pending.is_none());
    Ok(())
}
#[test]
fn heartbeat_captured_for_another_request_or_no_video_never_renews_current() -> Result<(), String> {
    let mut model = acquiring_model()?;
    let old = renewal::heartbeat(&model).ok_or("old heartbeat")?;
    let mut newer = acquiring_model()?;
    let _ = renewal::renew(
        &mut newer,
        Some(old),
        Instant::now() + Duration::from_mins(1),
    );
    assert_eq!(ticket(&newer)?.acquisition_lease.lease_id, 1);
    let _ = renewal::renew(&mut model, None, Instant::now() + Duration::from_mins(1));
    assert_eq!(ticket(&model)?.acquisition_lease.lease_id, 1);
    Ok(())
}
#[test]
fn candidate_is_capped_by_original_hard_deadline_and_stale_checks_do_not_stack()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let captured = renewal::heartbeat(&model).ok_or("heartbeat")?;
    let _ = candidate(&mut model)?;
    let _ = renewal::renew(
        &mut model,
        Some(captured),
        Instant::now() + Duration::from_hours(1),
    );
    assert_eq!(ticket(&model)?.acquisition_lease.lease_id, 2);
    let binding = model
        .immich_locked
        .video
        .binding
        .as_ref()
        .ok_or("binding")?;
    assert!(binding.current_capability()?.lease_deadline <= binding.capability.hard_deadline);
    let mut model = acquiring_model()?;
    let original = model
        .immich_locked
        .video
        .binding
        .as_ref()
        .ok_or("binding")?
        .capability
        .hard_deadline;
    let old = model
        .immich_locked
        .video
        .binding
        .as_ref()
        .ok_or("binding")?
        .current_capability()?
        .lease_deadline;
    let heartbeat = renewal::heartbeat(&model).ok_or("heartbeat")?;
    let _ = renewal::renew(
        &mut model,
        Some(heartbeat),
        original + Duration::from_hours(1),
    );
    let successor = ticket(&model)?;
    assert_eq!(successor.acquisition_lease.lease_id, 2);
    let actual = model
        .immich_locked
        .video
        .binding
        .as_ref()
        .ok_or("binding")?
        .current_capability()?
        .lease_deadline;
    assert!(actual <= original);
    assert!(original.duration_since(actual) < Duration::from_millis(1));
    assert_eq!(
        successor.acquisition_lease.extension_milliseconds,
        u64::try_from(actual.duration_since(old).as_millis()).map_err(|_| "extension")?
    );
    assert_eq!(
        model
            .immich_locked
            .video
            .binding
            .as_ref()
            .ok_or("binding")?
            .capability
            .hard_deadline,
        original
    );
    Ok(())
}
#[test]
fn foreign_completion_cannot_occupy_single_held_slot_and_current_completion_waits_for_ack()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let old = ticket(&model)?;
    let next = candidate(&mut model)?;
    let mut foreign = old.clone();
    foreign.pending.request_id = "77777777-7777-4777-8777-777777777777".into();
    assert!(!renewal::hold(
        &mut model,
        Event::ImmichLockedVideoPrepared {
            ticket: foreign,
            approved: true,
            acquisition_lease_id: 1
        }
    ));
    assert!(renewal::hold(
        &mut model,
        Event::ImmichLockedVideoPrepared {
            ticket: old,
            approved: true,
            acquisition_lease_id: 1
        }
    ));
    assert!(model.immich_locked.video.access.is_none());
    assert!(model.immich_locked.video.renewal.held.is_some());
    acknowledge(&mut model, &next);
    assert!(
        model.immich_locked.video.access.is_none(),
        "ack emits fresh verification, never direct publication"
    );
    assert!(model.immich_locked.video.renewal.held.is_none());
    Ok(())
}
#[test]
fn acquisition_expiry_never_stops_an_approved_display_lease() -> Result<(), String> {
    let mut model = approved_model()?;
    expire(&mut model, 1);
    assert!(model.immich_locked.video.access.is_some());
    let _ = reconcile(&mut model);
    assert!(model.immich_locked.video.access.is_some());
    assert!(renewal::heartbeat(&model).is_some());
    Ok(())
}

pub(super) fn pause(
    core: &Core<Suwop>,
    shell: &mut Shell,
    mut effects: Vec<Effect>,
    target: fn(&ShellOperation) -> bool,
) -> Result<Effect, String> {
    while !effects.is_empty() {
        let effect = effects.remove(0);
        let Effect::Io(mut request) = effect;
        if target(&request.operation) {
            return Ok(Effect::Io(request));
        }
        let response = match shell.respond(&request.operation) {
            Ok(value) => ShellResponse {
                value: Some(value),
                error: None,
            },
            Err(error) => ShellResponse {
                value: None,
                error: Some(error),
            },
        };
        effects.extend(
            core.resolve(&mut request, response)
                .map_err(|_| "resolve paused stage")?,
        );
    }
    Err("requested stage absent".into())
}
#[test]
fn real_heartbeat_metadata_failure_stops_held_read_without_any_successor_effect()
-> Result<(), String> {
    let core = core(&raw())?;
    let mut shell = Shell::new(raw());
    let read = pause(&core, &mut shell, core.process_event(request()), |op| {
        matches!(op, ShellOperation::ReadImmichLockedVideo { .. })
    })?;
    shell.raw["visibility"] = json!("timeline");
    let view = core.view().immich_locked_view;
    shell.run(
        &core,
        Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: view.generation,
            lease_id: view.lease_id,
        },
    )?;
    assert!(core.view().immich_locked_view.video_pending.is_none());
    assert!(core.view().immich_locked_view.video.is_none());
    let Effect::Io(mut effect) = read;
    let value = shell.respond(&effect.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut effect,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "late read")?,
    )?;
    assert!(core.view().immich_locked_view.video.is_none());
    assert_eq!(shell.prepares, 0);
    Ok(())
}
#[test]
fn read_completed_during_ack_wait_rechecks_fresh_metadata_after_ack_before_prepare()
-> Result<(), String> {
    let mut initial = model(&raw())?;
    // A controlled short original acquisition lease; the heartbeat uses the real reducer/effects.
    initial.immich_locked.lease_deadline = Some(Instant::now() + Duration::from_secs(20));
    let core = Core::new_with(Suwop, initial);
    let mut shell = Shell::new(raw());
    let read = pause(&core, &mut shell, core.process_event(request()), |op| {
        matches!(op, ShellOperation::ReadImmichLockedVideo { .. })
    })?;
    let view = core.view().immich_locked_view;
    let renew = pause(
        &core,
        &mut shell,
        core.process_event(Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: view.generation,
            lease_id: view.lease_id,
        }),
        |op| matches!(op, ShellOperation::RenewImmichLockedVideoAcquisition { .. }),
    )?;
    let Effect::Io(mut read) = read;
    let value = shell.respond(&read.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut read,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "held read completion")?,
    )?;
    assert_eq!(shell.prepares, 0);
    assert!(core.view().immich_locked_view.video.is_none());
    // Only the post-ack metadata can observe this newly introduced drift.
    shell.raw["checksum"] = json!("b".repeat(40));
    let Effect::Io(mut renew) = renew;
    let ShellOperation::RenewImmichLockedVideoAcquisition {
        ticket,
        previous_lease_id,
        lease,
    } = &renew.operation
    else {
        return Err("renewal effect".into());
    };
    let ack = json!({"requestID":ticket.pending.request_id,"stagedID":ticket.storage.lease_id,"previousLeaseID":previous_lease_id,"leaseID":lease.lease_id});
    shell.drain(
        &core,
        core.resolve(
            &mut renew,
            ShellResponse {
                value: Some(ack),
                error: None,
            },
        )
        .map_err(|_| "renew ack")?,
    )?;
    assert_eq!(shell.prepares, 0);
    assert!(core.view().immich_locked_view.video.is_none());
    assert!(shell.releases.iter().any(|id| id == LEASE));
    Ok(())
}

#[test]
fn either_status_failure_and_each_exact_identity_drift_prevent_successor_authorization()
-> Result<(), String> {
    for failure in [
        "first-status",
        "second-status",
        "ownerId",
        "checksum",
        "updatedAt",
        "visibility",
        "isTrashed",
    ] {
        let core = core(&raw())?;
        let mut shell = Shell::new(raw());
        let _read = pause(&core, &mut shell, core.process_event(request()), |op| {
            matches!(op, ShellOperation::ReadImmichLockedVideo { .. })
        })?;
        match failure {
            "first-status" => shell.fail_status = Some(shell.status_calls + 1),
            "second-status" => shell.fail_status = Some(shell.status_calls + 2),
            "isTrashed" => shell.raw[failure] = json!(true),
            "visibility" => shell.raw[failure] = json!("timeline"),
            _ => shell.raw[failure] = json!("changed"),
        }
        let view = core.view().immich_locked_view;
        shell.run(
            &core,
            Event::CheckImmichLockedSession {
                grant_id: GRANT.into(),
                generation: view.generation,
                lease_id: view.lease_id,
            },
        )?;
        assert_eq!(shell.renewals, 0, "{failure}");
        assert!(
            core.view().immich_locked_view.video_pending.is_none(),
            "{failure}"
        );
        assert!(core.view().immich_locked_view.video.is_none(), "{failure}");
    }
    Ok(())
}
#[test]
fn mismatched_ack_is_terminal_but_duplicate_old_ack_cannot_touch_new_request() -> Result<(), String>
{
    let mut model = acquiring_model()?;
    let next = candidate(&mut model)?;
    let wrong = Event::ImmichLockedVideoRenewalAcknowledged {
        pending: next.pending.clone(),
        staged_id: LEASE.into(),
        previous_lease_id: 1,
        lease_id: 2,
        result: Ok(ImmichLockedVideoAcquisitionRenewed {
            request_id: REQUEST.into(),
            staged_id: LEASE.into(),
            previous_lease_id: 1,
            lease_id: 3,
        }),
    };
    let _ = update(wrong, &mut model);
    assert!(model.immich_locked.video.pending.is_none());
    let mut newer = acquiring_model()?;
    let current = newer
        .immich_locked
        .video
        .pending
        .as_mut()
        .ok_or("pending")?;
    current.request_id = "77777777-7777-4777-8777-777777777777".into();
    acknowledge(&mut newer, &next);
    assert_eq!(
        newer
            .immich_locked
            .video
            .pending
            .as_ref()
            .ok_or("new pending")?
            .request_id,
        "77777777-7777-4777-8777-777777777777"
    );
    Ok(())
}

#[test]
fn prepared_completion_held_for_ack_requires_new_post_ack_identity_proof() -> Result<(), String> {
    let mut initial = model(&raw())?;
    initial.immich_locked.lease_deadline = Some(Instant::now() + Duration::from_secs(20));
    let core = Core::new_with(Suwop, initial);
    let mut shell = Shell::new(raw());
    let prepared = pause(&core, &mut shell, core.process_event(request()), |op| {
        matches!(op, ShellOperation::PrepareImmichLockedVideo { .. })
    })?;
    let view = core.view().immich_locked_view;
    let renew = pause(
        &core,
        &mut shell,
        core.process_event(Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: view.generation,
            lease_id: view.lease_id,
        }),
        |op| matches!(op, ShellOperation::RenewImmichLockedVideoAcquisition { .. }),
    )?;
    let Effect::Io(mut prepared) = prepared;
    let value = shell.respond(&prepared.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut prepared,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "held preparation")?,
    )?;
    assert!(core.view().immich_locked_view.video.is_none());
    shell.raw["updatedAt"] = json!("changed-after-preparation");
    let Effect::Io(mut renew) = renew;
    let value = shell.respond(&renew.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut renew,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "preparation renewal ack")?,
    )?;
    assert!(core.view().immich_locked_view.video.is_none());
    assert!(shell.releases.iter().any(|id| id == LEASE));
    Ok(())
}

#[test]
fn queued_initial_read_survives_renewal_without_initial_schedule_delivery_or_ticket_relabel()
-> Result<(), String> {
    let mut initial = model(&raw())?;
    initial.immich_locked.lease_deadline = Some(Instant::now() + Duration::from_secs(20));
    let core = Core::new_with(Suwop, initial);
    let mut shell = Shell::new(raw());
    let mut effects = core.process_event(request());
    let mut read = None;
    while !effects.is_empty() {
        let Effect::Io(mut effect) = effects.remove(0);
        if matches!(
            effect.operation,
            ShellOperation::ScheduleImmichLockedVideoAcquisitionExpiry { .. }
        ) {
            continue;
        }
        if matches!(
            effect.operation,
            ShellOperation::ReadImmichLockedVideo { .. }
        ) {
            read = Some(effect);
            break;
        }
        let value = shell.respond(&effect.operation)?;
        effects.extend(
            core.resolve(
                &mut effect,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "initial dispatch")?,
        );
    }
    let mut read = read.ok_or("queued initial read")?;
    let first = core
        .view()
        .immich_locked_view
        .video_acquisition
        .ok_or("initial proof")?
        .initial_lease;
    let view = core.view().immich_locked_view;
    shell.run(
        &core,
        Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: view.generation,
            lease_id: view.lease_id,
        },
    )?;
    let current = core
        .view()
        .immich_locked_view
        .video_acquisition
        .ok_or("renewed proof")?;
    assert_eq!(current.initial_lease, first);
    assert_eq!(current.lease.lease_id, 2);
    assert_eq!(current.acknowledged_lease_id, 2);
    let ShellOperation::ReadImmichLockedVideo { ticket } = &read.operation else {
        return Err("read effect".into());
    };
    assert_eq!(
        ticket.acquisition_lease.lease_id, 1,
        "queued ticket is never rewritten"
    );
    assert_eq!(ticket.initial_acquisition_lease, first);
    let value = shell.respond(&read.operation)?;
    assert_eq!(
        value["acquisitionLeaseID"], 1,
        "old stage completion remains an old lease proof"
    );
    shell.drain(
        &core,
        core.resolve(
            &mut read,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "queued read resolve")?,
    )?;
    assert!(core.view().immich_locked_view.video.is_some());
    assert_eq!(shell.reads, 1);
    assert_eq!(shell.prepares, 1);
    Ok(())
}

#[test]
fn selected_quiescence_terminalizes_successor_and_discards_held_publication_before_ack()
-> Result<(), String> {
    let mut model = acquiring_model()?;
    let initial = ticket(&model)?;
    let binding = model.immich_locked.video.binding.clone().ok_or("binding")?;
    let next = candidate(&mut model)?;
    assert!(renewal::hold(
        &mut model,
        Event::ImmichLockedVideoPrepared {
            ticket: initial.clone(),
            approved: true,
            acquisition_lease_id: 1,
        }
    ));
    let captured = quiesce_visibility(&mut model, &initial.pending.key).ok_or("captured")?;
    assert_eq!(captured.request_id, initial.pending.request_id);
    assert!(
        binding.current_capability().is_err(),
        "shared authority is terminal before JOIN"
    );
    assert!(renewal::projection(&model).is_none());
    assert!(model.immich_locked.video.renewal.held.is_none());
    assert!(model.immich_locked.video.renewal.ticket.is_none());
    acknowledge(&mut model, &next);
    let mut late = update(
        Event::ImmichLockedVideoPrepared {
            ticket: initial,
            approved: true,
            acquisition_lease_id: 1,
        },
        &mut model,
    )
    .ok_or("late completion")?;
    assert!(model.immich_locked.video.access.is_none());
    assert!(model.immich_locked.video.pending.is_none());
    assert!(
        late.effects()
            .all(|effect| matches!(effect, Effect::Io(request)
        if matches!(request.operation, ShellOperation::ReleaseImmichLockedVideo { .. })))
    );
    Ok(())
}

#[test]
fn old_quiesced_ack_and_expiry_cannot_terminalize_a_replacement_acquisition() -> Result<(), String>
{
    let mut model = acquiring_model()?;
    let next = candidate(&mut model)?;
    let _ = quiesce_visibility(&mut model, &next.pending.key);
    let request_id = "77777777-7777-4777-8777-777777777777";
    let _ = update(
        Event::RequestImmichLockedVideo {
            entry_id: ID.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
            request_id: request_id.into(),
        },
        &mut model,
    )
    .ok_or("replacement request")?;
    let binding = model
        .immich_locked
        .video
        .binding
        .clone()
        .ok_or("replacement binding")?;
    let mut storage = Shell::new(raw()).storage;
    storage.lease_id = "88888888-8888-4888-8888-888888888888".into();
    let _ = acquisition::planned(&mut model, binding.clone(), Ok((storage, Some(123))));
    let replacement = candidate(&mut model)?;
    let pending = model
        .immich_locked
        .video
        .pending
        .clone()
        .ok_or("replacement pending")?;
    assert_eq!(pending.request_id, request_id);
    assert_eq!(replacement.pending, pending);
    assert_eq!(binding.pending.request_id, request_id);
    acknowledge(&mut model, &next);
    expire(&mut model, next.acquisition_lease.lease_id);
    assert_eq!(model.immich_locked.video.pending.as_ref(), Some(&pending));
    let retained = ticket(&model)?;
    assert_eq!(retained.pending, replacement.pending);
    assert_eq!(retained.storage.lease_id, replacement.storage.lease_id);
    let projected = renewal::projection(&model).ok_or("replacement projection")?;
    assert_eq!(projected.lease.lease_id, 2);
    assert_eq!(projected.acknowledged_lease_id, 1);
    assert!(binding.current_capability().is_ok());
    Ok(())
}

#[test]
fn completion_cannot_change_commitment_mode_ceiling_or_original_storage_measurement()
-> Result<(), String> {
    let model = acquiring_model()?;
    let original = ticket(&model)?;
    assert!(renewal::completion_current(&model, &original, 1));
    for field in 0..5 {
        let mut changed = original.clone();
        match field {
            0 => changed.commitment_mode = ImmichLockedVideoCommitmentMode::Incremental,
            1 => changed.max_received_bytes += 1,
            2 => changed.minimum_remaining_bytes -= 1,
            3 => changed.storage.measurement_nonce = "99999999-9999-4999-8999-999999999999".into(),
            _ => changed.storage.allocation_unit_bytes += 1,
        }
        assert!(!renewal::completion_current(&model, &changed, 1));
    }
    let mut value = serde_json::to_value(&original).map_err(|_| "ticket encode")?;
    value
        .as_object_mut()
        .ok_or("ticket object")?
        .remove("commitmentMode");
    assert!(serde_json::from_value::<ImmichLockedVideoTicket>(value.clone()).is_err());
    value["commitmentMode"] = json!("inferFromLength");
    assert!(serde_json::from_value::<ImmichLockedVideoTicket>(value).is_err());
    Ok(())
}

#[test]
fn incremental_plan_keeps_the_same_mode_and_ceiling_through_two_successors() -> Result<(), String> {
    let mut model = acquiring_model()?;
    let binding = model.immich_locked.video.binding.clone().ok_or("binding")?;
    let _ = acquisition::planned(&mut model, binding, Ok((Shell::new(raw()).storage, None)));
    let first = ticket(&model)?;
    assert_eq!(
        first.commitment_mode,
        ImmichLockedVideoCommitmentMode::Incremental
    );
    assert!(first.expected_bytes.is_none());
    for _ in 0..2 {
        let next = candidate(&mut model)?;
        assert_eq!(next.commitment_mode, first.commitment_mode);
        assert_eq!(next.max_received_bytes, first.max_received_bytes);
        assert_eq!(next.minimum_remaining_bytes, first.minimum_remaining_bytes);
        assert_eq!(next.storage, first.storage);
        acknowledge(&mut model, &next);
    }
    Ok(())
}
