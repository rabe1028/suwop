//! Real provider HTTP/bytes; native capacity, preparation and publication are synthetic.
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{ConnectionSettings, Model, Suwop},
    immich_locked::{Secret, live::*},
    protection::ProtectionScenePhase,
};
#[path = "private_live_controls.rs"]
mod controls;
#[path = "private_live_shell.rs"]
mod shell;
#[path = "private_live_transport.rs"]
mod transport;
use selected_recovery::Fixture;
use shell::Shell;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const REQUEST: &str = "33333333-3333-4333-8333-333333333333";
const QUOTE: &str = "44444444-4444-4444-8444-444444444444";
#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_private_live_pair_originals_are_pin_bound_read_only_and_reject_drift() -> Result<(), String>
{
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("pair evidence root")?,
    )
    .join("private-live-read");
    std::fs::create_dir(&root).map_err(|_| "pair evidence root exists")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup_private_live(&agent, &root)?;
    for placement in ["timeline", "archive", "hidden", "locked"] {
        controls::place_motion(&agent, &fixture, placement)?;
        let directory = root.join(placement);
        std::fs::create_dir(&directory).map_err(|_| "pair placement directory")?;
        std::fs::write(directory.join("external-setup.json"), serde_json::to_vec_pretty(&json!({"externalFixtureWrite":"motion placement before product trace","motionID":fixture.motion,"placement":placement})).map_err(|_|"setup evidence encode")?).map_err(|_|"setup evidence write")?;
        let before = fixture.observe(&agent, &directory)?;
        controls::save_observation(&directory, "observer-before.json", &before)?;
        let (core, mut host) = start(&agent, &fixture, &directory)?;
        let effects = host.request(&core)?;
        assert_eq!(host.expected[1]["visibility"], placement);
        host.drain(&core, effects)?;
        assert!(
            core.view().immich_locked_view.live.is_some(),
            "real pair must reach approved projection"
        );
        assert_eq!(
            host.roles,
            [ImmichLockedLiveRole::Parent, ImmichLockedLiveRole::Motion]
        );
        assert_eq!((host.prepares, host.publications), (1, 1));
        host.run(
            &core,
            Event::StopImmichLockedLive {
                request_id: REQUEST.into(),
                scene_id: SCENE.into(),
                retry_cleanup: true,
            },
        )?;
        assert!(core.view().immich_locked_view.live.is_none());
        host.assert_released();
        let roles_before_replay = host.roles.len();
        let plan_id = core
            .view()
            .immich_live_resources
            .and_then(|v| v.plan)
            .ok_or("retained read plan")?
            .plan_id;
        let replay = core.process_event(Event::RequestImmichLockedLive {
            plan_id,
            request_id: REQUEST.into(),
            scene_id: SCENE.into(),
            grant_id: GRANT.into(),
        });
        assert!(
            replay.is_empty(),
            "completed request must not replay original GETs"
        );
        assert_eq!(host.roles.len(), roles_before_replay);
        let after = fixture.observe(&agent, &directory)?;
        controls::save_observation(&directory, "observer-after.json", &after)?;
        assert_eq!(after, before);
        host.save("positive")?;
        host.run(&core, Event::CloseImmichLocked)?;
    }
    controls::drift_and_close(&agent, &fixture, &root)?;
    fixture.close(&agent)
}
fn start<'a>(
    agent: &'a ureq::Agent,
    fixture: &'a Fixture,
    directory: &'a Path,
) -> Result<(Core<Suwop>, Shell<'a>), String> {
    let state = SavedLibrary {
        schema_version: 8,
        connection: Some(ConnectionSettings {
            address: fixture.elevated.ordinary.endpoint.clone(),
            allow_http: true,
            credential_id: "private-live-fixture".into(),
        }),
        ..SavedLibrary::default()
    };
    let core = Core::new_with(
        Suwop,
        Model {
            state: state.clone(),
            session: Some(fixture.elevated.ordinary.clone()),
            ready: true,
            ..Model::default()
        },
    );
    let mut host = Shell::new(
        agent,
        fixture,
        directory,
        serde_json::to_value(state).map_err(|_| "pair state")?,
    );
    host.run(
        &core,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    host.run(
        &core,
        Event::OpenImmichLocked {
            scene_id: SCENE.into(),
            request_id: GRANT.into(),
            email: Secret(fixture.email.clone()),
            password: Secret("GraphFixtureOnly123!".into()),
            pin_code: Secret(PIN.into()),
        },
    )?;
    let view = core.view().immich_locked_view;
    controls::save_observation(
        directory,
        "authentication.json",
        &json!({
            "stage":"actual OpenImmichLocked completion",
            "trace":host.trace,
            "state":view.state,
            "error":view.error,
            "grantMatches":view.grant_id.as_deref()==Some(GRANT),
            "nativeMocks":"cleanup/timer receipts only; auth HTTP remains actual"
        }),
    )?;
    assert_eq!(
        core.view().immich_locked_view.grant_id.as_deref(),
        Some(GRANT)
    );
    host.authenticated = true;
    host.trace.clear();
    Ok((core, host))
}
