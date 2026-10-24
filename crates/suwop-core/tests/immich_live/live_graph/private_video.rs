//! Real same-owner C1 VIDEO bytes/approval, not Swift decoding/motion or C2 writes.
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{Model, Suwop},
    domain::{AssetKey, Provider},
    immich_locked::Secret,
    protection::ProtectionScenePhase,
};
#[path = "private_video_controls.rs"]
mod controls;
#[path = "private_video_drift.rs"]
mod drift;
#[path = "private_video_fixture.rs"]
mod fixture;
#[path = "private_video_renewal.rs"]
mod renewal;
#[path = "private_video_shell.rs"]
mod shell;
#[path = "private_video_transport.rs"]
mod transport;
#[path = "private_video_transport_tests.rs"]
mod transport_tests;
use fixture::{Fixture, write_json};
use shell::{Phase, Shell};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
fn id(sequence: u32) -> String {
    format!("{sequence:08x}-5555-4555-8555-555555555555")
}
#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_private_video_originals_are_pin_bound_read_only_and_cleanup_drift() -> Result<(), String> {
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("private video evidence root")?,
    )
    .join("private-video");
    std::fs::create_dir(&root).map_err(|_| "private video root exists or unavailable")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup(&agent, &root)?;
    let baseline = fixture.observe(&agent, &root, "observer-before")?;
    controls::observe(&agent, &fixture, &root)?;
    for (index, selected) in [&fixture.video, &fixture.motion].into_iter().enumerate() {
        let directory = root.join(format!("selected-{index}"));
        std::fs::create_dir(&directory).map_err(|_| "video selected directory")?;
        let (core, mut host, journal) = start(&agent, &fixture, &directory)?;
        host.selected = selected.clone();
        let grant = id(10 + u32::try_from(index).map_err(|_| "video index")?);
        authenticate(&mut host, &core, &grant)?;
        let request = id(20 + u32::try_from(index).map_err(|_| "video index")?);
        positive(&mut host, &core, selected, &grant, &request)?;
        deny_ordinary(&mut host, &core, selected, &journal)?;
        assert_eq!(host.raw(), &journal);
        close(&mut host, &core)?;
        assert_eq!(host.stage_count(), 0);
        assert_eq!(host.raw(), &journal);
        write_json(&directory.join("journal-after.json"), host.raw())?;
    }
    let after = fixture.observe(&agent, &root, "observer-after-positive")?;
    assert_eq!(baseline, after);
    synthetic_absence(&agent, &fixture, &root)?;
    renewal::exercise(&agent, &fixture, &root)?;
    drift::exercise(&agent, &fixture, &root)?;
    let after = fixture.observe(&agent, &root, "observer-after-all")?;
    // Drift changes only V visibility/revision, and restores V locked before this observation.
    for (index, (before, after)) in baseline
        .as_array()
        .ok_or("before observer")?
        .iter()
        .zip(after.as_array().ok_or("after observer")?)
        .enumerate()
    {
        let mut before = before.clone();
        let mut after = after.clone();
        if index == 0 {
            before["identity"]
                .as_object_mut()
                .ok_or("before identity")?
                .remove("updatedAt");
            after["identity"]
                .as_object_mut()
                .ok_or("after identity")?
                .remove("updatedAt");
        }
        assert_eq!(before, after);
    }
    fixture.close(&agent)
}
fn start<'a>(
    agent: &'a ureq::Agent,
    fixture: &'a Fixture,
    directory: &'a Path,
) -> Result<(Core<Suwop>, Shell<'a>, Value), String> {
    let session = &fixture.elevated.ordinary;
    let raw = selected_recovery::legacy(&fixture.key(&fixture.parent), session, "applied")?;
    let core = Core::new_with(
        Suwop,
        Model {
            session: Some(session.clone()),
            ..Model::default()
        },
    );
    let mut host = Shell::new(agent, fixture, directory, raw);
    host.run(
        &core,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    let journal = host.raw().clone();
    assert_eq!(journal["schemaVersion"], 10);
    write_json(&directory.join("journal-before.json"), &journal)?;
    Ok((core, host, journal))
}
fn authenticate(host: &mut Shell<'_>, core: &Core<Suwop>, grant: &str) -> Result<(), String> {
    host.phase = Phase::Authenticate;
    host.run(
        core,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    host.run(
        core,
        Event::OpenImmichLocked {
            scene_id: SCENE.into(),
            request_id: grant.into(),
            email: Secret(host.fixture.email.clone()),
            password: Secret("GraphFixtureOnly123!".into()),
            pin_code: Secret(PIN.into()),
        },
    )?;
    assert_eq!(
        core.view().immich_locked_view.grant_id.as_deref(),
        Some(grant)
    );
    host.phase = Phase::Selected;
    host.trace.clear();
    Ok(())
}
fn request(
    core: &Core<Suwop>,
    selected: &str,
    grant: &str,
    request: &str,
) -> Result<Event, String> {
    let entry = core
        .view()
        .immich_locked_view
        .entries
        .ok_or("video locked entries")?
        .into_iter()
        .find(|e| e.asset.key.asset_id == selected)
        .ok_or("selected VIDEO entry missing")?;
    Ok(Event::RequestImmichLockedVideo {
        entry_id: entry.id,
        grant_id: grant.into(),
        scene_id: SCENE.into(),
        request_id: request.into(),
    })
}
fn positive(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    selected: &str,
    grant: &str,
    request_id: &str,
) -> Result<(), String> {
    host.run(core, request(core, selected, grant, request_id)?)?;
    host.assert_approved(core, request_id)?;
    assert!(
        core.view()
            .ordinary_content_keys
            .iter()
            .all(|key| key != &host.fixture.key(selected))
    );
    assert_eq!(
        host.trace
            .iter()
            .filter(|s| s.as_str() == "GET selected-original-stream")
            .count(),
        1
    );
    assert_eq!(
        host.trace
            .iter()
            .filter(|s| s.as_str() == "prepare-hidden-mock")
            .count(),
        1
    );
    write_json(
        &host
            .directory
            .join(format!("product-effects-{request_id}.json")),
        &json!({"effects":host.trace,"nativePrepare":"mock; no motion/codec claim","approved":true}),
    )?;
    host.run(
        core,
        Event::StopImmichLockedVideo {
            scene_id: SCENE.into(),
            request_id: request_id.into(),
            retry_cleanup: true,
        },
    )?;
    assert!(core.view().immich_locked_view.video.is_none());
    assert_eq!(host.stage_count(), 0);
    Ok(())
}
fn close(host: &mut Shell<'_>, core: &Core<Suwop>) -> Result<(), String> {
    host.run(core, Event::CloseImmichLocked)?;
    assert!(core.view().immich_locked_view.video.is_none());
    Ok(())
}
fn synthetic_absence(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<(), String> {
    let directory = root.join("synthetic-size-absence-real-original");
    std::fs::create_dir(&directory).map_err(|_| "absence directory")?;
    let (core, mut host, journal) = start(agent, fixture, &directory)?;
    host.absent_size = true;
    let grant = id(30);
    authenticate(&mut host, &core, &grant)?;
    positive(&mut host, &core, &fixture.video, &grant, &id(31))?;
    assert_eq!(host.raw(), &journal);
    close(&mut host, &core)?;
    write_json(
        &directory.join("scope.json"),
        &json!({"metadata":"fixture removes fileSizeInByte from actual responses","content":"actual selected original bytes/checksum","notClaimed":"actual server omits size or native volume capacity measured"}),
    )
}

fn deny_ordinary(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    selected: &str,
    journal: &Value,
) -> Result<(), String> {
    let key = host.fixture.key(selected);
    for (label, event) in [
        (
            "denied-ordinary-share",
            Event::Share {
                keys: vec![key.clone()],
                id: id(80),
            },
        ),
        (
            "denied-ordinary-play",
            Event::Play {
                keys: vec![key],
                id: id(81),
            },
        ),
    ] {
        host.trace.clear();
        host.run(core, event)?;
        assert!(host.trace.iter().all(|effect| matches!(
            effect.as_str(),
            "release-video" | "cleanup-or-timer" | "POST auth/session/lock" | "POST auth/logout"
        )));
        assert_eq!(host.raw(), journal);
        assert!(core.view().immich_locked_view.video.is_none());
        assert_eq!(host.stage_count(), 0);
        write_json(
            &host.directory.join(format!("{label}.json")),
            &json!({"effects":host.trace,"ordinaryExportOrProviderWrite":false}),
        )?;
    }
    Ok(())
}
