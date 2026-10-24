//! Actual-server ordinary still redisplay; Swift native rendering has separate acceptance.
use super::selected_recovery::Fixture;
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{Model, Suwop},
    domain::{AssetKey, Provider},
    immich_locked::Secret,
    ordinary_selected::OrdinarySelectedImageKind as Kind,
};
#[path = "ordinary_selected_shell.rs"]
mod shell;
use shell::{Phase, Shell};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const OP: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_ordinary_selected_stills_preserve_locked_journal_without_related_reads_or_writes()
-> Result<(), String> {
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR")
            .ok_or("ordinary selected evidence root")?,
    )
    .join("ordinary-selected-read");
    std::fs::create_dir_all(&root).map_err(|_| "ordinary selected directory")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup_ordinary(&agent, &root)?;
    for (outcome, visibility) in [("applied", "timeline"), ("unknown", "archive")] {
        fixture.set_visibility(&agent, "locked")?;
        let branch = root.join(outcome);
        std::fs::create_dir(&branch).map_err(|_| "ordinary branch exists")?;
        exercise(&agent, &fixture, &branch, outcome, visibility)?;
    }
    fixture.close(&agent)
}
fn exercise(
    agent: &ureq::Agent,
    fixture: &Fixture,
    directory: &Path,
    outcome: &str,
    visibility: &str,
) -> Result<(), String> {
    let session = &fixture.elevated.ordinary;
    let core = Core::new_with(
        Suwop,
        Model {
            session: Some(session.clone()),
            ..Model::default()
        },
    );
    let raw = super::selected_recovery::legacy(&fixture.key(), session, outcome)?;
    let mut host = Shell::new(agent, directory, fixture, &raw)?;
    acquire_locked_observation(&mut host, &core, fixture)?;
    let locked = host.raw()?;
    assert_eq!(locked["schemaVersion"], 9);
    assert_eq!(locked["immichVisibilityOperations"][0]["outcome"], outcome);
    let mut old_fields = locked["immichVisibilityOperations"][0].clone();
    old_fields
        .as_object_mut()
        .ok_or("operation object")?
        .remove("selectedObservation");
    assert_eq!(old_fields, raw["immichVisibilityOperations"][0]);
    write(directory, "locked-journal-before", &locked)?;
    let baseline = fixture.observe(agent, directory)?;
    fixture.set_visibility(agent, visibility)?;
    let before = fixture.observe_visibility(agent, directory, visibility)?;
    assert_controls(&baseline, &before);
    fixture.ready_stills(agent, directory)?;
    host.phase = Phase::Ordinary;
    host.trace.clear();
    refresh(&mut host, &core)?;
    assert_readonly(&core, &fixture.key(), visibility)?;
    assert_journals(&locked, &host.raw()?);
    write(directory, "ordinary-refresh-effects", &json!(host.trace))?;
    for (kind, id) in [
        (Kind::Thumbnail, "33333333-3333-4333-8333-333333333333"),
        (Kind::Preview, "44444444-4444-4444-8444-444444444444"),
    ] {
        host.trace.clear();
        host.run(&core, image(&fixture.key(), kind, id))?;
        assert!(
            core.view()
                .ordinary_selected_images
                .iter()
                .any(|a| a.request_id == id && a.key == fixture.key() && a.kind == kind)
        );
        host.assert_approved(&core, id)?;
        assert!(host.trace.iter().any(|s| s == "publish-staged"));
        assert!(!host.trace.iter().any(|s| s == "persist"));
        assert_journals(&locked, &host.raw()?);
        write(
            directory,
            if kind == Kind::Preview {
                "preview-effects"
            } else {
                "thumbnail-effects"
            },
            &json!(host.trace),
        )?;
    }
    host.run(
        &core,
        Event::CloseOrdinarySelectedScene {
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(host.stage_count(), 0);
    reject_privileged(&mut host, &core, fixture, directory, &locked, visibility)?;
    if outcome == "unknown" {
        drift::exercise(
            &mut host, &core, agent, fixture, directory, &locked, visibility,
        )?;
    }
    let current = fixture_visibility(agent, fixture)?;
    let after = fixture.observe_visibility(agent, directory, &current)?;
    assert_controls(&before, &after);
    assert_journals(&locked, &host.raw()?);
    write(directory, "journal-after", &host.raw()?)?;
    write(directory, "observer-before", &before)?;
    write(directory, "observer-after", &after)?;
    reload(&mut host, session, &locked)
}
fn acquire_locked_observation(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    fixture: &Fixture,
) -> Result<(), String> {
    host.run(
        core,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    host.phase = Phase::Authenticate;
    host.run(
        core,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
    )?;
    host.run(
        core,
        Event::OpenImmichLocked {
            scene_id: SCENE.into(),
            request_id: GRANT.into(),
            email: Secret(fixture.email.clone()),
            password: Secret("GraphFixtureOnly123!".into()),
            pin_code: Secret(PIN.into()),
        },
    )?;
    host.phase = Phase::Inspect;
    host.trace.clear();
    host.run(
        core,
        Event::InspectImmichVisibility {
            record_id: OP.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    let measured = host
        .trace
        .iter()
        .filter(|s| !s.starts_with("release-") && *s != "cleanup-or-timer")
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(
        measured,
        [
            "GET auth/status",
            "GET selected-detail",
            "GET auth/status",
            "persist"
        ]
    );
    let raw = host.raw()?;
    assert_eq!(
        raw["immichVisibilityOperations"][0]["selectedObservation"]["visibility"],
        "locked"
    );
    assert_eq!(
        raw["immichVisibilityOperations"][0]["selectedObservation"]["configuration"],
        "linked"
    );
    host.phase = Phase::Authenticate;
    host.run(core, Event::CloseImmichLocked)?;
    assert!(core.view().immich_locked_view.grant_id.is_none());
    Ok(())
}
fn reject_privileged(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    fixture: &Fixture,
    directory: &Path,
    locked: &Value,
    visibility: &str,
) -> Result<(), String> {
    for (label, event) in [
        (
            "denied-share",
            Event::Share {
                keys: vec![fixture.key()],
                id: "88888888-8888-4888-8888-888888888888".into(),
            },
        ),
        (
            "denied-favorite",
            Event::SetFavorite {
                keys: vec![fixture.key()],
                value: true,
            },
        ),
    ] {
        refresh(host, core)?;
        assert_readonly(core, &fixture.key(), visibility)?;
        host.trace.clear();
        host.run(core, event)?;
        assert!(
            host.trace
                .iter()
                .all(|s| s.starts_with("release-") || s == "cleanup-or-timer")
        );
        assert_journals(locked, &host.raw()?);
        write(directory, label, &json!(host.trace))?;
    }
    Ok(())
}
fn refresh(host: &mut Shell<'_>, core: &Core<Suwop>) -> Result<(), String> {
    host.run(
        core,
        Event::Refresh {
            permission: false,
            now: crate::visibility::scan_now()?,
        },
    )
}
fn image(key: &AssetKey, kind: Kind, id: &str) -> Event {
    Event::RequestOrdinarySelectedImage {
        key: key.clone(),
        scene_id: SCENE.into(),
        request_id: id.into(),
        kind,
    }
}
fn assert_readonly(core: &Core<Suwop>, key: &AssetKey, visibility: &str) -> Result<(), String> {
    let view = core.view();
    let proof = view
        .ordinary_selected_presentation
        .iter()
        .find(|p| p.key == *key)
        .ok_or("ordinary read-only proof")?;
    assert_eq!(
        serde_json::to_value(proof.current_visibility).map_err(|_| "visibility encode")?,
        visibility
    );
    assert!(!view.ordinary_content_keys.contains(key));
    let own = view
        .state
        .snapshots
        .iter()
        .flat_map(|s| &s.assets)
        .find(|a| a.key == *key)
        .ok_or("public own still")?;
    assert!(own.resources.iter().all(|r| r.role == ResourceRole::Image));
    assert!(view.immich_visibility_actions.iter().filter(|a|a.key==*key).all(|a|!a.can_lock && !a.can_show_timeline && !a.can_show_archive && a.write_availability!=suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::VerificationRequired));
    assert!(
        view.immich_archive_actions
            .iter()
            .filter(|a| a.key == *key)
            .all(|a| a.to.is_none())
    );
    assert!(view.immich_locked_view.grant_id.is_none());
    Ok(())
}
fn assert_journals(before: &Value, after: &Value) {
    for field in [
        "immichVisibilityOperations",
        "appleVisibilityOperations",
        "protectedEntries",
        "receipts",
        "pendingUploads",
        "uploadIntents",
        "pendingTrash",
        "pendingAppleTrash",
        "pendingEditPastes",
        "editClipboard",
    ] {
        assert_eq!(
            after[field], before[field],
            "immutable journal changed: {field}"
        );
    }
    for field in [
        "ordinarySelectedPresentation",
        "ordinarySelectedImages",
        "ordinarySelectedPending",
        "ordinarySelectedGeneration",
    ] {
        assert!(after.get(field).is_none());
    }
}
fn assert_controls(before: &Value, after: &Value) {
    for i in [1, 2] {
        assert_eq!(before[i], after[i], "unselected resource changed");
    }
    for field in ["id", "ownerId", "type", "checksum", "livePhotoVideoId"] {
        assert_eq!(before[0]["identity"][field], after[0]["identity"][field]);
    }
    assert_eq!(before[0]["albumIDs"], after[0]["albumIDs"]);
    assert_eq!(before[0]["originalSHA256"], after[0]["originalSHA256"]);
}
fn fixture_visibility(agent: &ureq::Agent, fixture: &Fixture) -> Result<String, String> {
    let response: HttpResponse = serde_json::from_value(execute(
        agent,
        &fixture
            .elevated
            .request(&format!("assets/{}", fixture.parent), "GET", None),
    )?)
    .map_err(|_| "external current visibility")?;
    immich::check_status(response.status)?;
    response.body["visibility"]
        .as_str()
        .map(str::to_owned)
        .ok_or("external visibility missing".into())
}
fn reload(host: &mut Shell<'_>, session: &Session, locked: &Value) -> Result<(), String> {
    let core = Core::new_with(
        Suwop,
        Model {
            session: Some(session.clone()),
            ..Model::default()
        },
    );
    host.phase = Phase::Initialize;
    host.run(
        &core,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    assert_journals(locked, &host.raw()?);
    assert!(core.view().ordinary_selected_presentation.is_empty());
    assert!(core.view().ordinary_selected_images.is_empty());
    assert!(core.view().ordinary_selected_pending.is_empty());
    Ok(())
}
fn write(directory: &Path, label: &str, value: &Value) -> Result<(), String> {
    std::fs::write(
        directory.join(format!("{label}.json")),
        serde_json::to_vec_pretty(value).map_err(|_| "evidence encode")?,
    )
    .map_err(|_| "evidence write".into())
}
#[path = "ordinary_selected_drift.rs"]
mod drift;
