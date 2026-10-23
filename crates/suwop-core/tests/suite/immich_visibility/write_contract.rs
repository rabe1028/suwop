use super::*;
use suwop_core::{
    apple_visibility::VisibilityOutcome,
    immich_visibility::{ImmichVisibility, ImmichVisibilityWriteAvailability},
};
fn release(minor: u32, patch: u32) -> Value {
    json!({"major":3,"minor":minor,"patch":patch,"prerelease":null})
}
fn prepare_in(id: &str, to: ImmichVisibility, grant: &str) -> Event {
    Event::PrepareImmichVisibility {
        key: key(),
        to,
        operation_id: id.into(),
        grant_id: grant.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn unsupported_server_retains_read_grant_without_intent_or_confirmation() -> Result<(), String> {
    for raw in [
        release(2, 4),
        release(3, 2),
        json!({"major":3,"minor":3,"patch":3}),
        json!({"major":3,"minor":3,"patch":3,"prerelease":"rc.1"}),
    ] {
        let c = core(false);
        let mut shell = Shell {
            versions: std::collections::VecDeque::from([raw]),
            confirmed: true,
            ..Shell::default()
        };
        shell.run(&c, open(GRANT))?;
        assert!(c.view().immich_locked_view.grant_id.is_some());
        shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
        assert_eq!(
            (shell.confirmations, shell.persist_calls, shell.writes),
            (0, 0, 0)
        );
    }
    Ok(())
}
#[test]
fn downgrade_revokes_known_locked_hint_and_reauthentication_restores_authority()
-> Result<(), String> {
    let c = core(false);
    let mut row = asset();
    row["visibility"] = json!("locked");
    let mut shell = Shell {
        confirmed: true,
        visibility: Some("locked".into()),
        pages: Some(std::collections::VecDeque::from([
            json!({"assets":{"items":[row],"nextCursor":null}}),
        ])),
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    shell.versions.push_back(release(2, 4));
    shell.run(&c, prepare(OP, ImmichVisibility::Timeline))?;
    assert_eq!(
        (shell.confirmations, shell.persist_calls, shell.writes),
        (0, 0, 0)
    );
    let entries = c.view().immich_locked_view.entries.ok_or("entries")?;
    let hint = &entries
        .iter()
        .find(|entry| entry.asset.key == key())
        .ok_or("known key")?
        .visibility_action;
    assert!(
        !hint.can_show_timeline
            && hint.write_availability == ImmichVisibilityWriteAvailability::Unsupported
    );
    shell.run(&c, Event::CloseImmichLocked)?;
    shell.pages = None;
    shell.run(&c, open(NEXT))?;
    shell.run(&c, prepare_in(NEXT, ImmichVisibility::Timeline, NEXT))?;
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn preput_downgrade_is_durable_not_applied_without_submission() -> Result<(), String> {
    let (c, mut shell) = opened(false)?;
    shell.versions = std::collections::VecDeque::from([release(3, 3), release(2, 4)]);
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.confirmations, 1);
    assert_eq!(shell.writes, 0);
    let state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
    assert_eq!(
        state.immich_visibility_operations[0].outcome,
        VisibilityOutcome::NotApplied
    );
    assert!(state.immich_visibility_operations[0].observation.is_none());
    Ok(())
}
#[test]
fn transport_loss_after_submission_remains_unknown() -> Result<(), String> {
    let (c, mut shell) = opened(false)?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
    assert_eq!(shell.writes, 1);
    assert_eq!(
        state.immich_visibility_operations[0].outcome,
        VisibilityOutcome::Unknown
    );
    Ok(())
}
#[test]
fn version_transport_failures_keep_read_grant_and_classify_submission() -> Result<(), String> {
    for fail in [1, 2, 3] {
        let c = core(false);
        let mut shell = Shell {
            fail_version: Some(fail),
            confirmed: true,
            ..Shell::default()
        };
        shell.run(&c, open(GRANT))?;
        shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
        assert_eq!(c.view().immich_locked_view.grant_id.as_deref(), Some(GRANT));
        assert_eq!(shell.writes, 0);
        if fail == 3 {
            let state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
            assert_eq!(
                state.immich_visibility_operations[0].outcome,
                VisibilityOutcome::NotApplied
            );
        } else {
            assert_eq!((shell.confirmations, shell.persist_calls), (0, 0));
        }
    }
    Ok(())
}
fn held_version(
    c: &Core<Suwop>,
    shell: &mut Shell,
    mut effects: Vec<Effect>,
) -> Result<crux_core::Request<ShellOperation>, String> {
    loop {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(&request.operation,ShellOperation::Http(r) if r.url.ends_with("/server/version"))
        {
            return Ok(request);
        }
        let value = shell.respond(&request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
}
#[test]
fn late_version_after_close_never_restores_grant_and_new_auth_remains_usable() -> Result<(), String>
{
    for version in [release(2, 4), release(3, 3)] {
        let (c, mut shell) = opened(false)?;
        let mut held = held_version(
            &c,
            &mut shell,
            c.process_event(prepare(OP, ImmichVisibility::Locked)),
        )?;
        shell.run(&c, Event::CloseImmichLocked)?;
        shell.run(&c, open(NEXT))?;
        assert!(c.view().immich_locked_view.grant_id.is_none());
        let effects = c
            .resolve(
                &mut held,
                ShellResponse {
                    value: Some(json!({"status":200,"body":version})),
                    error: None,
                },
            )
            .map_err(|_| "late resolve")?;
        shell.drain(&c, effects)?;
        assert!(c.view().immich_locked_view.grant_id.is_none());
        assert_eq!(
            (shell.confirmations, shell.persist_calls, shell.writes),
            (0, 0, 0)
        );
        shell.run(&c, open(NEXT))?;
        shell.run(&c, prepare_in(NEXT, ImmichVisibility::Locked, NEXT))?;
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
