//! Actual product selected VIDEO writes; standalone and native-CID-associated motion.
use super::*;
use crate::live_graph::selected_video_fixture::Fixture;
const OP: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
fn request(key: &AssetKey, id: &str, to: ImmichVisibility) -> Event {
    Event::PrepareImmichVisibility {
        key: key.clone(),
        to,
        operation_id: id.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_selected_video_pin_writes_preserve_nonselected_native_graph_and_originals()
-> Result<(), String> {
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("selected VIDEO evidence")?,
    )
    .join("selected-video-visibility");
    std::fs::create_dir(&root).map_err(|_| "selected VIDEO evidence exists")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup(&agent, &root)?;
    fixture.quiet(&root, "initial")?;
    let baseline = fixture.observe(&agent, &root, "initial", None)?;
    for row in baseline.as_array().ok_or("baseline rows")? {
        assert_eq!(row["albums"], json!(fixture.albums));
    }
    for index in [0, 2] {
        exercise_selected(&agent, &fixture, &root, index)?;
    }
    Ok(())
}
fn authorize_video(
    shell: &mut LiveVisibilityShell<'_>,
    core: &Core<Suwop>,
    fixture: &Fixture,
) -> Result<(), String> {
    shell.run(
        core,
        Event::Refresh {
            permission: false,
            now: scan_now()?,
        },
    )?;
    shell.run(
        core,
        Event::OpenImmichLocked {
            scene_id: SCENE.into(),
            request_id: GRANT.into(),
            email: Secret(fixture.email.clone()),
            password: Secret("GraphFixtureOnly123!".into()),
            pin_code: Secret("123456".into()),
        },
    )?;
    assert_eq!(
        core.view().immich_locked_view.state,
        suwop_core::immich_locked::ImmichLockedState::Open
    );
    Ok(())
}
fn exercise_selected(
    agent: &ureq::Agent,
    fixture: &Fixture,
    root: &Path,
    index: usize,
) -> Result<(), String> {
    let directory = root.join(format!("selected-{index}"));
    std::fs::create_dir(&directory).map_err(|_| "C2 selected directory")?;
    let core = crate::live_locked_core(fixture.session());
    let mut shell = LiveVisibilityShell {
        agent,
        directory: &directory,
        writes: 0,
        confirmations: 0,
        persists: 0,
        elevated_memberships: vec![],
        fresh_observations: vec![],
        fact_requests: BTreeMap::new(),
    };
    authorize_video(&mut shell, &core, fixture)?;
    let key = fixture.key(index);
    let before = fixture.observe(agent, &directory, "before", None)?;
    let supported = std::env::var("IMMICH_VERSION").map_err(|_| "release")? == "v3.3.3";
    let hint = core
        .view()
        .immich_visibility_actions
        .into_iter()
        .find(|hint| hint.key == key)
        .ok_or("selected VIDEO action hint")?;
    assert_eq!(hint.can_lock, supported);
    assert_eq!(
        hint.write_availability,
        if supported {
            suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Supported
        } else {
            suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Unsupported
        }
    );
    let initial_persists = shell.persists;
    if supported {
        assert_eq!(
            std::env::var("IMMICH_VERSION").map_err(|_| "release")?,
            "v3.3.3"
        );
        for (number, destination, label) in [
            (1, ImmichVisibility::Locked, "lock"),
            (2, ImmichVisibility::Timeline, "timeline"),
            (3, ImmichVisibility::Locked, "relock"),
            (4, ImmichVisibility::Archive, "archive"),
        ] {
            let id = format!("{number:08x}-6666-4666-8666-666666666666");
            shell.run(&core, request(&key, &id, destination))?;
            assert_eq!(
                shell.writes,
                usize::try_from(number).map_err(|_| "write count")?
            );
            let outcome = journal(&directory)?
                .immich_visibility_operations
                .last()
                .ok_or("C2 video journal")?
                .outcome;
            assert_eq!(
                outcome,
                suwop_core::apple_visibility::VisibilityOutcome::Applied
            );
            fixture.quiet(root, &format!("selected-{index}-{label}"))?;
            let expected = match destination {
                ImmichVisibility::Locked => "locked",
                ImmichVisibility::Timeline => "timeline",
                ImmichVisibility::Archive => "archive",
            };
            let after = fixture.observe(agent, &directory, label, Some((index, expected)))?;
            compare_nonselected(&before, &after, index)?;
            assert!(
                !core.view().ordinary_content_keys.contains(&key),
                "no ordinary grant from visibility completion alone"
            );
        }
        assert_eq!(shell.confirmations, 4);
        assert_eq!(shell.writes, 4);
    } else {
        assert_eq!(
            std::env::var("IMMICH_VERSION").map_err(|_| "release")?,
            "v3.2.4"
        );
        shell.drain(
            &core,
            core.process_event(request(&key, OP, ImmichVisibility::Locked)),
        )?;
        assert_eq!(shell.writes, 0);
        assert_eq!(shell.confirmations, 0);
        assert_eq!(shell.persists, initial_persists);
        let after = fixture.observe(agent, &directory, "unsupported-after", None)?;
        assert_eq!(before, after);
    }
    shell.run(&core, Event::CloseImmichLocked)?;
    Ok(())
}
fn compare_nonselected(before: &Value, after: &Value, selected: usize) -> Result<(), String> {
    let before = before.as_array().ok_or("before rows")?;
    let after = after.as_array().ok_or("after rows")?;
    assert_eq!(before.len(), 4);
    assert_eq!(after.len(), 4);
    for (index, (before, after)) in before.iter().zip(after).enumerate() {
        if index == selected {
            assert_eq!(before["id"], after["id"]);
            assert_eq!(before["sha1"], after["sha1"]);
            assert_eq!(before["bytes"], after["bytes"]);
            assert_eq!(
                before["detail"]["livePhotoVideoId"],
                after["detail"]["livePhotoVideoId"]
            );
        } else {
            assert_eq!(
                before, after,
                "nonselected resource, metadata, forward graph, membership and bytes"
            );
        }
    }
    Ok(())
}
