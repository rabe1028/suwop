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
        let (c, s) = setup()?;
        let paths = s.paths.len();
        let next = resolve_capture(
            &c,
            c.process_event(prepare(OP, ImmichVisibility::Locked)),
            response,
        )?;
        assert!(next.is_empty());
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
    assert!(late.is_empty());
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
    let (c, s) = setup()?;
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
    assert!(late.is_empty());
    assert!(c.view().busy);
    assert_eq!((s.confirmations, s.persist_calls, s.writes), (0, 0, 0));
    drop((reset, fresh));
    Ok(())
}
