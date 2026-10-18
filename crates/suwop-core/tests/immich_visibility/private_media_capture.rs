//! Public Core event entrypoints must capture before any fence, snapshot revocation or I/O.
use super::*;
use suwop_core::immich_visibility::ImmichVisibility;

fn resolve_capture(
    c: &Core<Suwop>,
    effects: Vec<Effect>,
    response: ShellResponse,
) -> Result<Vec<Effect>, String> {
    assert_eq!(
        effects.len(),
        1,
        "Capture must be the first and only effect before ACK"
    );
    let Effect::Io(mut request) = effects.into_iter().next().ok_or("capture missing")?;
    assert!(matches!(
        request.operation,
        ShellOperation::CapturePrivateMediaKey { .. }
    ));
    c.resolve(&mut request, response)
        .map_err(|_| "capture resolve".into())
}
fn setup() -> Result<(Core<Suwop>, Shell), String> {
    let c = core(false);
    let mut s = Shell {
        confirmed: true,
        ..Shell::default()
    };
    s.run(&c, open(GRANT))?;
    Ok((c, s))
}
#[test]
fn pin_capture_is_first_and_does_not_advance_projection_or_content_revision() -> Result<(), String>
{
    let (c, mut s) = setup()?;
    let before = c.view();
    let effects = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let after = c.view();
    assert!(after.busy);
    assert_eq!(
        before.private_content_revision,
        after.private_content_revision
    );
    assert_eq!(
        serde_json::to_value(before.immich_visibility_view).map_err(|_| "view")?,
        serde_json::to_value(after.immich_visibility_view).map_err(|_| "view")?
    );
    let paths = s.paths.len();
    let next = resolve_capture(
        &c,
        effects,
        ShellResponse {
            value: Some(Value::Null),
            error: None,
        },
    )?;
    assert_eq!(s.paths.len(), paths, "no HTTP before capture ACK");
    s.drain(&c, next)?;
    assert_eq!(s.writes, 1);
    assert_eq!(s.quiescences, vec![key()]);
    assert_eq!(s.live_quiescences, vec![key()]);
    Ok(())
}
#[test]
fn failed_or_nonunit_capture_never_prepares_confirms_persists_or_writes() -> Result<(), String> {
    for response in [
        ShellResponse {
            value: None,
            error: Some("capture rejected".into()),
        },
        ShellResponse {
            value: Some(json!({"not":"unit"})),
            error: None,
        },
    ] {
        let (c, mut s) = setup()?;
        let paths = s.paths.len();
        let next = resolve_capture(
            &c,
            c.process_event(prepare(OP, ImmichVisibility::Locked)),
            response,
        )?;
        assert_eq!(
            next.len(),
            1,
            "even a failed capture must drain its retained snapshot"
        );
        s.drain(&c, next)?;
        assert!(!c.view().busy);
        assert_eq!(s.paths.len(), paths);
        assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
        assert!(
            c.process_event(prepare(OP, ImmichVisibility::Locked))
                .is_empty(),
            "failed ID stays burned"
        );
    }
    Ok(())
}
#[test]
fn missing_capture_ack_keeps_busy_and_duplicate_action_cannot_start_io() -> Result<(), String> {
    let (c, s) = setup()?;
    let held = c.process_event(prepare(OP, ImmichVisibility::Locked));
    assert_eq!(held.len(), 1);
    assert!(
        c.process_event(prepare(NEXT, ImmichVisibility::Locked))
            .is_empty()
    );
    assert!(c.view().busy);
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    Ok(())
}
#[test]
fn late_capture_after_close_cannot_start_io_or_clear_a_new_workflow_busy() -> Result<(), String> {
    let (c, mut s) = setup()?;
    let held = c.process_event(prepare(OP, ImmichVisibility::Locked));
    s.run(&c, Event::CloseImmichLocked)?;
    let workflow = c.process_event(Event::Initialize {
        scope: "new-workflow".into(),
    });
    assert!(c.view().busy);
    let late = resolve_capture(
        &c,
        held,
        ShellResponse {
            value: Some(Value::Null),
            error: None,
        },
    )?;
    s.drain(&c, late)?;
    assert!(
        c.view().busy,
        "old capture must not clear the new workflow's busy ownership"
    );
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    drop(workflow);
    Ok(())
}

#[test]
fn foreign_scene_notification_does_not_cancel_the_current_capture_reservation() -> Result<(), String>
{
    let (c, mut s) = setup()?;
    let held = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let other = c.process_event(Event::ImmichLockedSceneChanged {
        scene_id: NEXT.into(),
        phase: suwop_core::protection::ProtectionScenePhase::Inactive,
    });
    s.drain(&c, other)?;
    assert!(c.view().busy);
    let next = resolve_capture(
        &c,
        held,
        ShellResponse {
            value: Some(Value::Null),
            error: None,
        },
    )?;
    s.drain(&c, next)?;
    assert_eq!(s.writes, 1);
    Ok(())
}

#[test]
fn trusted_finished_reset_then_new_workflow_owns_busy_against_late_capture_ack()
-> Result<(), String> {
    let (c, mut s) = setup()?;
    let held = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let reset = c.process_event(Event::Finished {
        state: SavedLibrary {
            schema_version: 8,
            ..SavedLibrary::default()
        },
        session: None,
        status: "completed prior workflow".into(),
        error: None,
        preview_to_select: None,
    });
    assert!(!c.view().busy);
    let fresh = c.process_event(Event::Initialize {
        scope: "fresh-workflow".into(),
    });
    assert!(c.view().busy);
    let late = resolve_capture(
        &c,
        held,
        ShellResponse {
            value: Some(Value::Null),
            error: None,
        },
    )?;
    s.drain(&c, late)?;
    assert!(c.view().busy);
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    drop((reset, fresh));
    Ok(())
}

#[test]
fn held_native_drain_prevents_preflight_confirmation_and_intent() -> Result<(), String> {
    let (c, mut s) = setup()?;
    let paths = s.paths.len();
    let effects = resolve_capture(
        &c,
        c.process_event(prepare(OP, ImmichVisibility::Locked)),
        ShellResponse {
            value: Some(Value::Null),
            error: None,
        },
    )?;
    assert_eq!(effects.len(), 1);
    let Effect::Io(mut held) = effects.into_iter().next().ok_or("drain")?;
    let ShellOperation::DrainCapturedPrivateMedia {
        capture_id,
        cancel_before_capture,
        ..
    } = &held.operation
    else {
        return Err("exact drain".into());
    };
    assert!(!cancel_before_capture);
    let id = capture_id.clone();
    assert_eq!(s.paths.len(), paths);
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    let next = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!({"captureID":id,"cancelledBeforeCapture":false})),
                error: None,
            },
        )
        .map_err(|_| "drain resolve")?;
    s.drain(&c, next)?;
    assert_eq!(s.writes, 1);
    Ok(())
}

fn assert_explicit_cleanup_retry(
    c: &Core<Suwop>,
    s: &mut Shell,
    original_capture: &str,
    locator: &str,
    failed_attempt: u64,
) -> Result<(), String> {
    let next_attempt = failed_attempt.checked_add(1).ok_or("attempt overflow")?;
    assert!(
        c.process_event(Event::RetryPrivateMediaCleanup {
            recovery_id: locator.into(),
            expected_attempt: next_attempt
        })
        .is_empty()
    );
    let retry = Event::RetryPrivateMediaCleanup {
        recovery_id: locator.into(),
        expected_attempt: failed_attempt,
    };
    let effects = c.process_event(retry.clone());
    assert_eq!(effects.len(), 1);
    let Effect::Io(effect) = effects.first().ok_or("explicit retry drain")?;
    assert!(
        matches!(&effect.operation, ShellOperation::DrainCapturedPrivateMedia {capture_id,retry_cleanup:true,..} if capture_id==original_capture)
    );
    let joining =
        serde_json::to_value(c.view().private_media_cleanup).map_err(|_| "joining row")?;
    assert_eq!(joining[0]["state"], "joining");
    assert_eq!(joining[0]["expectedAttempt"], next_attempt);
    assert!(
        c.process_event(retry.clone()).is_empty(),
        "An in-flight attempt accepts no duplicate click"
    );
    s.drain(c, effects)?;
    assert_eq!(s.capture_drains, vec![original_capture.to_owned()]);
    assert!(c.view().private_media_cleanup.is_empty());
    assert!(
        c.process_event(retry).is_empty(),
        "The completed locator cannot resurrect cleanup or the old write"
    );
    Ok(())
}

#[test]
fn failed_or_wrong_capture_drain_receipt_keeps_admission_fenced() -> Result<(), String> {
    for response in [
        ShellResponse {
            value: None,
            error: Some("JOIN failed".into()),
        },
        ShellResponse {
            value: Some(json!({"captureID":"foreign","cancelledBeforeCapture":false})),
            error: None,
        },
    ] {
        let (c, mut s) = setup()?;
        let next = resolve_capture(
            &c,
            c.process_event(prepare(OP, ImmichVisibility::Locked)),
            ShellResponse {
                value: Some(Value::Null),
                error: None,
            },
        )?;
        let Effect::Io(mut held) = next.into_iter().next().ok_or("drain")?;
        let ShellOperation::DrainCapturedPrivateMedia { capture_id, .. } = &held.operation else {
            return Err("drain operation".into());
        };
        let original_capture = capture_id.clone();
        assert!(
            c.resolve(&mut held, response)
                .map_err(|_| "resolve")?
                .is_empty()
        );
        assert!(!c.view().busy);
        let rows = c.view().private_media_cleanup;
        assert_eq!(
            rows.len(),
            1,
            "Failed or foreign receipt retains the exact obligation"
        );
        let row = rows.into_iter().next().ok_or("failed cleanup row")?;
        assert_eq!(
            serde_json::to_value(&row).map_err(|_| "row")?["state"],
            "needsAttention"
        );
        let locator = row.recovery_id.clone().ok_or("recovery locator")?;
        let failed_row = serde_json::to_value(&row).map_err(|_| "row")?;
        let paths = s.paths.len();
        assert!(
            c.process_event(prepare(NEXT, ImmichVisibility::Locked))
                .is_empty(),
            "A later write action cannot automatically retry cleanup"
        );
        assert_eq!(
            serde_json::to_value(c.view().private_media_cleanup).map_err(|_| "rows")?,
            json!([failed_row])
        );
        assert_eq!(s.paths.len(), paths);
        assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
        assert_explicit_cleanup_retry(
            &c,
            &mut s,
            &original_capture,
            &locator,
            row.expected_attempt,
        )?;
        assert_eq!(s.paths.len(), paths);
        assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    }
    Ok(())
}

#[test]
fn cancelled_before_capture_cleanup_recovers_and_late_capture_cannot_clear_new_busy()
-> Result<(), String> {
    let (c, mut s) = setup()?;
    let held = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let cancelled = c.process_event(Event::CloseImmichLocked);
    assert!(
        !c.view().busy,
        "Close is reduced synchronously, not requeued behind a new workflow"
    );
    let mut queue: std::collections::VecDeque<_> = cancelled.into();
    while let Some(effect) = queue.pop_front() {
        let Effect::Io(mut r) = effect;
        let value = if let ShellOperation::DrainCapturedPrivateMedia {
            capture_id,
            cancel_before_capture,
            ..
        } = &r.operation
        {
            assert!(cancel_before_capture);
            Ok(json!({"captureID":capture_id,"cancelledBeforeCapture":true}))
        } else {
            s.respond(&r.operation)
        };
        queue.extend(
            c.resolve(
                &mut r,
                ShellResponse {
                    value: value.as_ref().ok().cloned(),
                    error: value.err(),
                },
            )
            .map_err(|_| "resolve cancel")?,
        );
    }
    s.run(&c, open(NEXT))?;
    let fresh = c.process_event(Event::PrepareImmichVisibility {
        key: key(),
        to: ImmichVisibility::Locked,
        operation_id: OWNER.into(),
        grant_id: NEXT.into(),
        scene_id: SCENE.into(),
    });
    assert_eq!(
        fresh.len(),
        1,
        "Successful exact cancellation cleanup admits a fresh action"
    );
    assert!(c.view().busy);
    let late = resolve_capture(
        &c,
        held,
        ShellResponse {
            value: None,
            error: Some("sealed before capture".into()),
        },
    )?;
    assert!(late.is_empty());
    assert!(
        c.view().busy,
        "Old capture callback cannot clear the new reservation"
    );
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    drop(fresh);
    Ok(())
}

fn wire_live_pending() -> suwop_core::immich_locked::live::ImmichLockedLivePending {
    suwop_core::immich_locked::live::ImmichLockedLivePending {
        request_id: NEXT.into(),
        plan_id: OP.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
        generation: 3,
        parent_key: key(),
        motion_key: AssetKey {
            asset_id: OWNER.into(),
            ..key()
        },
        phase: suwop_core::immich_locked::live::ImmichLockedLivePhase::Checking,
    }
}
fn wire_video_pending() -> suwop_core::immich_locked::video::ImmichLockedVideoPending {
    suwop_core::immich_locked::video::ImmichLockedVideoPending {
        request_id: NEXT.into(),
        entry_id: ASSET.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
        generation: 3,
        key: key(),
        phase: suwop_core::immich_locked::video::ImmichLockedVideoPhase::Checking,
    }
}
fn roundtrip_operation(op: &ShellOperation) -> Result<Value, String> {
    let raw = serde_json::to_value(op).map_err(|e| e.to_string())?;
    let decoded: ShellOperation = serde_json::from_value(raw.clone()).map_err(|e| e.to_string())?;
    assert_eq!(
        serde_json::to_value(decoded).map_err(|e| e.to_string())?,
        raw
    );
    Ok(raw)
}
#[test]
fn capture_and_drain_wire_preserves_exact_camel_case_pending_context() -> Result<(), String> {
    for video_pending in [vec![], vec![wire_video_pending()]] {
        let capture = ShellOperation::CapturePrivateMediaKey {
            key: key(),
            capture_id: OP.into(),
            live_pending: vec![wire_live_pending()],
            video_pending: video_pending.clone(),
        };
        let raw = roundtrip_operation(&capture)?;
        assert_eq!(raw["type"], "capturePrivateMediaKey");
        let data = raw["data"].as_object().ok_or("capture data")?;
        assert_eq!(data.len(), 4);
        assert_eq!(data["captureID"], OP);
        assert_eq!(data["livePending"][0]["requestID"], NEXT);
        assert_eq!(
            data["videoPending"]
                .as_array()
                .ok_or("pending array")?
                .len(),
            video_pending.len()
        );
        for forbidden in ["capture_id", "live_pending", "video_pending"] {
            assert!(!data.contains_key(forbidden));
        }
        let drain = ShellOperation::DrainCapturedPrivateMedia {
            key: key(),
            capture_id: OP.into(),
            live_pending: vec![wire_live_pending()],
            video_pending,
            cancel_before_capture: true,
            retry_cleanup: false,
        };
        let raw = roundtrip_operation(&drain)?;
        assert_eq!(raw["type"], "drainCapturedPrivateMedia");
        let data = raw["data"].as_object().ok_or("drain data")?;
        assert_eq!(data.len(), 6);
        assert_eq!(data["cancelBeforeCapture"], true);
        assert_eq!(data["retryCleanup"], false);
        assert_eq!(data["captureID"], OP);
        assert_eq!(
            data["livePending"][0]["parentKey"],
            serde_json::to_value(key()).map_err(|e| e.to_string())?
        );
        assert!(data.contains_key("videoPending"));
        for forbidden in [
            "cancel_before_capture",
            "retry_cleanup",
            "live_pending",
            "video_pending",
        ] {
            assert!(!data.contains_key(forbidden));
        }
    }
    Ok(())
}
#[test]
fn release_effect_wire_requires_exact_retry_cleanup_bool_for_single_and_generation()
-> Result<(), String> {
    for retry_cleanup in [false, true] {
        for op in [
            ShellOperation::ReleaseImmichLockedLive {
                pending: wire_live_pending(),
                pair_lease_id: None,
                retry_cleanup,
            },
            ShellOperation::ReleaseImmichLockedLives {
                generation: 3,
                retry_cleanup,
            },
            ShellOperation::ReleaseImmichLockedVideo {
                pending: wire_video_pending(),
                lease_id: OP.into(),
                retry_cleanup,
            },
            ShellOperation::RetireImmichLockedVideoPending {
                pending: wire_video_pending(),
                retry_cleanup,
            },
            ShellOperation::ReleaseImmichLockedVideos {
                generation: 3,
                retry_cleanup,
            },
        ] {
            let raw = roundtrip_operation(&op)?;
            assert_eq!(raw["data"]["retryCleanup"], retry_cleanup);
            assert!(raw["data"].get("retry_cleanup").is_none());
            for invalid in [None, Some(Value::Null), Some(json!("true")), Some(json!(1))] {
                let mut changed = raw.clone();
                let fields = changed["data"].as_object_mut().ok_or("release data")?;
                if let Some(value) = invalid {
                    fields.insert("retryCleanup".into(), value);
                } else {
                    fields.remove("retryCleanup");
                    fields.insert("retry_cleanup".into(), json!(true));
                }
                assert!(
                    serde_json::from_value::<ShellOperation>(changed).is_err(),
                    "Missing/wrong-case/malformed effect retry cannot default to true"
                );
            }
        }
    }
    Ok(())
}
#[test]
fn stop_event_wire_roundtrips_user_retry_and_defaults_automatic_origin_to_false()
-> Result<(), String> {
    for kind in ["stopImmichLockedLive", "stopImmichLockedVideo"] {
        for retry in [false, true] {
            let raw = json!({"type":kind,"sceneID":SCENE,"requestID":NEXT,"retryCleanup":retry});
            let event: Event = serde_json::from_value(raw.clone()).map_err(|e| e.to_string())?;
            assert!(
                matches!(&event, Event::StopImmichLockedLive {retry_cleanup,..} | Event::StopImmichLockedVideo {retry_cleanup,..} if *retry_cleanup == retry)
            );
            assert_eq!(serde_json::to_value(event).map_err(|e| e.to_string())?, raw);
        }
        for raw in [
            json!({"type":kind,"sceneID":SCENE,"requestID":NEXT}),
            json!({"type":kind,"sceneID":SCENE,"requestID":NEXT,"retry_cleanup":true}),
        ] {
            let event: Event = serde_json::from_value(raw).map_err(|e| e.to_string())?;
            assert!(matches!(
                event,
                Event::StopImmichLockedLive {
                    retry_cleanup: false,
                    ..
                } | Event::StopImmichLockedVideo {
                    retry_cleanup: false,
                    ..
                }
            ));
        }
        for invalid in [Value::Null, json!("true"), json!(1)] {
            assert!(
                serde_json::from_value::<Event>(
                    json!({"type":kind,"sceneID":SCENE,"requestID":NEXT,"retryCleanup":invalid})
                )
                .is_err()
            );
        }
    }
    Ok(())
}

#[test]
fn cleanup_retry_wire_requires_camel_case_locator_and_exact_attempt() -> Result<(), String> {
    let raw = json!({"type":"retryPrivateMediaCleanup","recoveryID":"opaque-locator","expectedAttempt":7});
    let event: Event = serde_json::from_value(raw.clone()).map_err(|e| e.to_string())?;
    assert!(
        matches!(&event, Event::RetryPrivateMediaCleanup { recovery_id, expected_attempt:7 } if recovery_id=="opaque-locator")
    );
    assert_eq!(serde_json::to_value(event).map_err(|e| e.to_string())?, raw);
    for bad in [
        json!({"type":"retryPrivateMediaCleanup","recovery_id":"opaque-locator","expectedAttempt":7}),
        json!({"type":"retryPrivateMediaCleanup","recoveryID":"opaque-locator","expected_attempt":7}),
        json!({"type":"retryPrivateMediaCleanup","recoveryID":"opaque-locator","expectedAttempt":null}),
        json!({"type":"retryPrivateMediaCleanup","recoveryID":"opaque-locator","expectedAttempt":-1}),
    ] {
        assert!(serde_json::from_value::<Event>(bad).is_err());
    }
    Ok(())
}
