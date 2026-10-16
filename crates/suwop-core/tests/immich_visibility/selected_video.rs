//! Exact selected VIDEO state changes. No reverse-parent independence or pair-wide grant.
use super::*;
use suwop_core::immich_visibility::ImmichVisibility;
fn video_opened() -> Result<(Core<Suwop>, Shell), String> {
    let (core, mut shell) = opened(false)?;
    shell.facts_patch = Some(json!({"type":"VIDEO","exifInfo":{"fileSizeInByte":123}}));
    Ok((core, shell))
}
fn lock_and_play() -> Result<(Core<Suwop>, Shell), String> {
    let (core, mut shell) = video_opened()?;
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    shell.run(
        &core,
        Event::RequestImmichLockedVideo {
            entry_id: ASSET.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
            request_id: NEXT.into(),
        },
    )?;
    assert!(core.view().immich_locked_view.video.is_some());
    Ok((core, shell))
}
#[test]
fn selected_video_lock_and_explicit_restore_use_one_selected_write_each() -> Result<(), String> {
    for destination in [ImmichVisibility::Timeline, ImmichVisibility::Archive] {
        let (core, mut shell) = video_opened()?;
        shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
        let view = core.view();
        let row = &view
            .immich_locked_view
            .entries
            .as_ref()
            .ok_or("locked row")?[0];
        assert!(row.can_play_video);
        assert!(row.visibility_action.can_show_timeline && row.visibility_action.can_show_archive);
        assert!(!view.ordinary_content_keys.contains(&key()));
        let witness =
            shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["witnessDigest"]
                .clone();
        shell.run(&core, prepare(NEXT, destination))?;
        assert_eq!(shell.writes, 2);
        assert_eq!(shell.confirmations, 2);
        assert_eq!(
            shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][1]["witnessDigest"],
            witness
        );
        assert!(
            core.view()
                .immich_locked_view
                .entries
                .as_ref()
                .ok_or("entries")?
                .is_empty()
        );
        assert_eq!(shell.ordinary_writes, 0);
    }
    Ok(())
}
#[test]
fn selected_video_lost_reply_restart_inspect_is_read_only_and_keeps_unknown_outcome()
-> Result<(), String> {
    let (core, mut shell) = video_opened()?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    let disk = shell.disk.clone().ok_or("durable unknown")?;
    assert_eq!(disk["immichVisibilityOperations"][0]["outcome"], "unknown");
    let operation = serde_json::from_value(disk["immichVisibilityOperations"][0].clone())
        .map_err(|_| "operation")?;
    let restarted = core_operations(false, vec![operation]);
    shell
        .versions
        .push_back(json!({"major":3,"minor":2,"patch":4,"prerelease":null}));
    shell.run(&restarted, open(GRANT))?;
    let before = shell.writes;
    shell.run(&restarted, inspect())?;
    assert_eq!(shell.writes, before);
    let history = restarted
        .view()
        .immich_visibility_view
        .history
        .ok_or("history")?;
    assert_eq!(
        history[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    assert_eq!(history[0].observation, Some(ImmichVisibility::Locked));
    assert!(history[0].selected_observation.is_none());
    assert!(
        restarted
            .view()
            .immich_locked_view
            .entries
            .as_ref()
            .ok_or("read row")?
            .iter()
            .any(|e| e.asset.key == key())
    );
    assert!(!restarted.view().ordinary_content_keys.contains(&key()));
    Ok(())
}
#[test]
fn confirmed_change_waits_for_exact_video_quiescence_before_any_new_intent() -> Result<(), String> {
    let (core, mut shell) = lock_and_play()?;
    let before = shell.persist_calls;
    let held = pause_before(
        &core,
        &mut shell,
        core.process_event(prepare(NEXT, ImmichVisibility::Timeline)),
        |op| matches!(op, ShellOperation::QuiesceImmichLockedVideo { .. }),
    )?;
    assert!(core.view().immich_locked_view.video.is_none());
    assert_eq!(shell.persist_calls, before);
    assert_eq!(shell.writes, 1);
    let Effect::Io(mut held) = held;
    let ShellOperation::QuiesceImmichLockedVideo {
        key: selected,
        pending,
    } = &held.operation
    else {
        return Err("barrier".into());
    };
    assert_eq!(selected, &key());
    assert!(
        pending.is_none(),
        "the existing begin epoch already retired this video; key barrier still applies"
    );
    let value = shell.respond(&held.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "barrier ack")?,
    )?;
    assert_eq!(shell.writes, 2);
    assert!(shell.persist_calls > before);
    Ok(())
}
#[test]
fn stopped_video_still_requires_barrier_and_failed_join_never_persists_or_writes()
-> Result<(), String> {
    let (core, mut shell) = lock_and_play()?;
    shell.run(
        &core,
        Event::StopImmichLockedVideo {
            scene_id: SCENE.into(),
            request_id: NEXT.into(),
        },
    )?;
    let before = shell.persist_calls;
    shell.quiescence_failure = Some("fixture quiescence failed".into());
    shell.run(&core, prepare(NEXT, ImmichVisibility::Timeline))?;
    assert_eq!(shell.persist_calls, before);
    assert_eq!(shell.writes, 1);
    assert!(shell.quiescence_pending.last().ok_or("barrier")?.is_none());
    assert!(!core.view().busy);
    Ok(())
}
#[test]
fn inspect_revokes_exact_video_before_failed_owner_or_checksum_read_and_keeps_row()
-> Result<(), String> {
    for field in ["ownerId", "checksum"] {
        let (core, mut shell) = lock_and_play()?;
        shell.facts_patch.as_mut().ok_or("patch")?[field] = json!("changed");
        let effects = core.process_event(inspect());
        assert!(core.view().immich_locked_view.video.is_none());
        assert_eq!(
            core.view()
                .immich_locked_view
                .entries
                .as_ref()
                .ok_or("retained row")?
                .len(),
            1
        );
        shell.drain(&core, effects)?;
        assert!(core.view().immich_locked_view.video.is_none());
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}

fn pause_before(
    core: &Core<Suwop>,
    shell: &mut Shell,
    mut effects: Vec<Effect>,
    target: fn(&ShellOperation) -> bool,
) -> Result<Effect, String> {
    while !effects.is_empty() {
        let Effect::Io(mut effect) = effects.remove(0);
        if target(&effect.operation) {
            return Ok(Effect::Io(effect));
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
            .map_err(|_| "pause resolution")?,
        );
    }
    Err("expected held effect".into())
}

#[test]
fn confirmed_video_change_captures_preinspect_pending_and_late_quote_cannot_start_read()
-> Result<(), String> {
    let (core, mut shell) = lock_and_play()?;
    let confirmation = pause_before(
        &core,
        &mut shell,
        core.process_event(prepare(NEXT, ImmichVisibility::Timeline)),
        |op| matches!(op, ShellOperation::ConfirmImmichVisibility { .. }),
    )?;
    let request_id = "77777777-7777-4777-8777-777777777777";
    let quote = pause_before(
        &core,
        &mut shell,
        core.process_event(Event::RequestImmichLockedVideo {
            entry_id: ASSET.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
            request_id: request_id.into(),
        }),
        |op| matches!(op, ShellOperation::InspectImmichLockedVideoStorage { .. }),
    )?;
    let Effect::Io(mut confirmation) = confirmation;
    let confirmed = shell.respond(&confirmation.operation)?;
    let effects = core
        .resolve(
            &mut confirmation,
            ShellResponse {
                value: Some(confirmed),
                error: None,
            },
        )
        .map_err(|_| "confirmation")?;
    let barrier = pause_before(&core, &mut shell, effects, |op| {
        matches!(op, ShellOperation::QuiesceImmichLockedVideo { .. })
    })?;
    let Effect::Io(mut barrier) = barrier;
    let ShellOperation::QuiesceImmichLockedVideo {
        pending: Some(pending),
        ..
    } = &barrier.operation
    else {
        return Err("pending barrier".into());
    };
    assert_eq!(pending.request_id, request_id);
    assert_eq!(
        pending.phase,
        suwop_core::immich_locked::video::ImmichLockedVideoPhase::Checking
    );
    assert!(core.view().immich_locked_view.video_pending.is_none());
    let value = shell.respond(&barrier.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut barrier,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "pending barrier ack")?,
    )?;
    assert_eq!(shell.writes, 2);
    let Effect::Io(mut quote) = quote;
    let value = shell.respond(&quote.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut quote,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "late quote")?,
    )?;
    assert!(core.view().immich_locked_view.video_pending.is_none());
    assert!(core.view().immich_locked_view.video.is_none());
    assert!(shell.releases.iter().any(|id| id == request_id));
    Ok(())
}

#[test]
fn nonnull_quiescence_ack_is_not_a_unit_proof_and_never_persists_or_writes() -> Result<(), String> {
    let (core, mut shell) = video_opened()?;
    shell.quiescence_ack = Some(json!({"success":true}));
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.writes, 0);
    assert!(!core.view().busy);
    assert!(shell.disk.is_none());
    Ok(())
}

#[test]
fn video_configuration_or_identity_change_after_confirmation_never_creates_intent()
-> Result<(), String> {
    for (field, value) in [
        ("type", json!("IMAGE")),
        ("livePhotoVideoId", json!(NEXT)),
        ("stack", json!({"id":NEXT})),
        ("checksum", json!("b".repeat(40))),
        ("updatedAt", json!("changed")),
        ("ownerId", json!(NEXT)),
        ("isOffline", json!(true)),
        ("isTrashed", json!(true)),
    ] {
        let (core, mut shell) = video_opened()?;
        let held = pause_before(
            &core,
            &mut shell,
            core.process_event(prepare(OP, ImmichVisibility::Locked)),
            |op| matches!(op, ShellOperation::ConfirmImmichVisibility { .. }),
        )?;
        shell.facts_patch.as_mut().ok_or("patch")?[field] = value;
        let Effect::Io(mut held) = held;
        let value = shell.respond(&held.operation)?;
        shell.drain(
            &core,
            core.resolve(
                &mut held,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "changed confirmation")?,
        )?;
        assert_eq!(shell.persist_calls, 0, "{field}");
        assert_eq!(shell.writes, 0, "{field}");
        assert!(shell.quiescences.is_empty(), "{field}");
    }
    Ok(())
}
#[test]
fn closing_during_quiescence_never_turns_teardown_ack_into_write_authority() -> Result<(), String> {
    let (core, mut shell) = lock_and_play()?;
    let before = shell.persist_calls;
    let held = pause_before(
        &core,
        &mut shell,
        core.process_event(prepare(NEXT, ImmichVisibility::Timeline)),
        |op| matches!(op, ShellOperation::QuiesceImmichLockedVideo { .. }),
    )?;
    shell.run(&core, Event::CloseImmichLocked)?;
    let Effect::Io(mut held) = held;
    shell.drain(
        &core,
        core.resolve(
            &mut held,
            ShellResponse {
                value: Some(Value::Null),
                error: None,
            },
        )
        .map_err(|_| "closed barrier ack")?,
    )?;
    assert_eq!(shell.persist_calls, before);
    assert_eq!(shell.writes, 1);
    assert!(!core.view().busy);
    assert!(core.view().immich_locked_view.video.is_none());
    Ok(())
}
#[test]
fn externally_unlocked_video_unknown_is_observed_without_settling_outcome_or_granting_ordinary_content()
-> Result<(), String> {
    let (core, mut shell) = video_opened()?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    shell.visibility = Some("timeline".into());
    let before = shell.writes;
    shell.run(&core, inspect())?;
    assert_eq!(shell.writes, before);
    let history = core
        .view()
        .immich_visibility_view
        .history
        .ok_or("history")?;
    assert_eq!(history[0].observation, Some(ImmichVisibility::Timeline));
    assert_eq!(
        history[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    assert!(history[0].selected_observation.is_none());
    assert!(
        !core.view().ordinary_content_keys.contains(&key()),
        "explicit observation alone never restores stale ordinary inventory"
    );
    assert!(
        core.view()
            .immich_locked_view
            .entries
            .as_ref()
            .ok_or("rows")?
            .is_empty()
    );
    Ok(())
}
