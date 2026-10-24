use super::*;
use suwop_core::immich_visibility::{ImmichVisibility, SelectedConfiguration};
const CHILD: &str = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
fn locked() -> Result<(Core<Suwop>, Shell), String> {
    let (core, mut shell) = opened(false)?;
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    Ok((core, shell))
}
fn disk_operation(shell: &Shell) -> Result<Value, String> {
    Ok(shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0].clone())
}
fn legacy_fields(mut operation: Value) -> Value {
    operation
        .as_object_mut()
        .map(|v| v.remove("selectedObservation"));
    operation
}
fn preview(core: &Core<Suwop>, shell: &mut Shell) -> Result<(), String> {
    shell.run(
        core,
        Event::RequestImmichLockedImage {
            entry_id: ASSET.into(),
            grant_id: GRANT.into(),
            request_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc".into(),
        },
    )
}
#[test]
fn relinked_inspection_records_selected_state_without_rewriting_operation_or_authority()
-> Result<(), String> {
    let (core, mut shell) = locked()?;
    let before = disk_operation(&shell)?;
    preview(&core, &mut shell)?;
    assert!(core.view().immich_locked_view.image.is_some());
    shell.relationship = Some(json!(CHILD));
    let writes = shell.writes;
    shell.run(&core, inspect())?;
    let after = disk_operation(&shell)?;
    assert_eq!(legacy_fields(before), legacy_fields(after.clone()));
    assert_eq!(after["selectedObservation"]["visibility"], "locked");
    assert_eq!(after["selectedObservation"]["configuration"], "linked");
    assert_eq!(shell.writes, writes);
    let view = core.view();
    assert!(view.immich_locked_view.image.is_none());
    let entry = &view.immich_locked_view.entries.ok_or("row")?[0];
    assert!(!entry.visibility_action.can_show_timeline);
    assert!(!entry.visibility_action.can_show_archive);
    assert_eq!(
        entry.visibility_action.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Live)
    );
    let summary = &view.immich_visibility_view.history.ok_or("history")?[0];
    assert_eq!(
        summary
            .selected_observation
            .as_ref()
            .ok_or("selected summary")?
            .configuration,
        SelectedConfiguration::Linked
    );
    let summary = serde_json::to_string(summary).map_err(|_| "summary encode")?;
    for private in ["Digest", CHILD, "PRIVATE", ASSET] {
        assert!(!summary.contains(private));
    }
    let durable = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
    assert!(suwop_core::immich_visibility::fences(&durable, &key()));
    assert!(!view.ordinary_content_keys.contains(&key()));
    Ok(())
}
#[test]
fn identity_failure_keeps_row_and_journal_but_revokes_only_selected_preview() -> Result<(), String>
{
    for patch in [
        json!({"ownerId":"other"}),
        json!({"checksum":"b".repeat(40)}),
        json!({"type":"VIDEO"}),
        json!({"id":CHILD}),
        json!({"updatedAt":""}),
        json!({"isTrashed":true}),
    ] {
        let (core, mut shell) = locked()?;
        preview(&core, &mut shell)?;
        let before = shell.disk.clone();
        let persists = shell.persist_calls;
        shell.facts_patch = Some(patch);
        shell.run(&core, inspect())?;
        assert_eq!(shell.disk, before);
        assert_eq!(shell.persist_calls, persists);
        assert_eq!(
            core.view().immich_locked_view.entries.ok_or("row")?.len(),
            1
        );
        assert!(core.view().immich_locked_view.image.is_none());
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
#[test]
fn unlocked_changed_configuration_never_releases_content_or_new_mutation() -> Result<(), String> {
    let (core, mut shell) = locked()?;
    let before = disk_operation(&shell)?;
    shell.relationship = Some(json!(CHILD));
    shell.visibility = Some("timeline".into());
    shell.run(&core, inspect())?;
    let after = disk_operation(&shell)?;
    assert_eq!(legacy_fields(before), legacy_fields(after.clone()));
    assert_eq!(after["selectedObservation"]["visibility"], "timeline");
    let state = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    assert!(!core.view().ordinary_content_keys.contains(&key()));
    shell.run(&core, prepare(NEXT, ImmichVisibility::Archive))?;
    assert_eq!(shell.writes, 1);
    let restart = core_operations(false, state.immich_visibility_operations);
    assert!(restart.view().immich_visibility_view.history.is_none());
    assert!(!restart.view().ordinary_content_keys.contains(&key()));
    Ok(())
}
#[test]
fn observation_save_failure_cannot_publish_new_proof_and_ambiguous_save_remains_fenced()
-> Result<(), String> {
    for ambiguous in [false, true] {
        let (core, mut shell) = locked()?;
        let before = disk_operation(&shell)?;
        shell.relationship = Some(json!(CHILD));
        shell.fail_persist = Some(shell.persist_calls + 1);
        shell.read_fail = ambiguous;
        shell.run(&core, inspect())?;
        assert_eq!(disk_operation(&shell)?, before);
        assert!(
            core.view()
                .immich_visibility_view
                .history
                .ok_or("history")?[0]
                .selected_observation
                .is_none()
        );
        assert_eq!(
            core.view().immich_visibility_view.persistence_uncertain,
            ambiguous
        );
        assert_eq!(
            core.view().immich_locked_view.entries.ok_or("row")?.len(),
            1
        );
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
#[test]
fn schema_seven_and_older_migrate_without_inventing_observation_or_changing_old_journals()
-> Result<(), String> {
    let (_, shell) = locked()?;
    for version in 1..=7 {
        let mut raw = shell.disk.clone().ok_or("disk")?;
        raw["schemaVersion"] = json!(version);
        for field in [
            "immichLiveOperations",
            "immichLiveUnstartedClosures",
            "immichLiveLegacyReconciliations",
        ] {
            raw.as_object_mut().ok_or("object")?.remove(field);
        }
        let expected = raw["immichVisibilityOperations"].clone();
        let mut expected_state = raw.clone();
        expected_state["schemaVersion"] = json!(9);
        expected_state["immichLiveOperations"] = json!([]);
        expected_state["immichLiveUnstartedClosures"] = json!([]);
        expected_state["immichLiveLegacyReconciliations"] = json!([]);
        let state = suwop_core::workflow::migrate(raw)?;
        assert_eq!(
            state.schema_version,
            suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION
        );
        assert!(
            state.immich_visibility_operations[0]
                .selected_observation
                .is_none()
        );
        assert_eq!(
            serde_json::to_value(&state.immich_visibility_operations).map_err(|_| "operations")?,
            expected
        );
        assert!(suwop_core::immich_visibility::fences(&state, &key()));
    }
    Ok(())
}
#[test]
fn selected_observation_requires_schema_eight_provenance() -> Result<(), String> {
    let (core, mut shell) = locked()?;
    shell.relationship = Some(json!(CHILD));
    shell.run(&core, inspect())?;
    let raw = shell.disk.clone().ok_or("disk")?;
    assert!(!raw["immichVisibilityOperations"][0]["selectedObservation"].is_null());
    assert!(suwop_core::workflow::migrate(raw.clone()).is_ok());
    let mut legacy = raw.clone();
    legacy["schemaVersion"] = json!(7);
    for field in [
        "immichLiveOperations",
        "immichLiveUnstartedClosures",
        "immichLiveLegacyReconciliations",
    ] {
        legacy.as_object_mut().ok_or("object")?.remove(field);
    }
    assert!(suwop_core::workflow::migrate(legacy.clone()).is_err());
    assert_eq!(
        legacy["immichVisibilityOperations"],
        raw["immichVisibilityOperations"]
    );
    Ok(())
}
#[test]
fn stale_inspection_never_revives_a_closed_pin_grant() -> Result<(), String> {
    let (core, mut shell) = locked()?;
    shell.relationship = Some(json!(CHILD));
    let effects = core.process_event(inspect());
    shell.run(&core, Event::CloseImmichLocked)?;
    shell.drain(&core, effects)?;
    assert!(core.view().immich_locked_view.entries.is_none());
    assert!(core.view().immich_visibility_view.history.is_none());
    assert_eq!(shell.writes, 1);
    Ok(())
}

#[test]
fn failed_inspection_keeps_row_without_reusing_pending_or_preview_authority() -> Result<(), String>
{
    for status in [Some(403), None] {
        let (core, mut shell) = locked()?;
        preview(&core, &mut shell)?;
        let pending = core.process_event(Event::RequestImmichLockedImage {
            entry_id: ASSET.into(),
            grant_id: GRANT.into(),
            request_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd".into(),
        });
        let before = shell.disk.clone();
        shell.asset_failure = status;
        shell.asset_transport_failure = status.is_none().then_some(());
        shell.run(&core, inspect())?;
        assert_eq!(
            core.view().immich_locked_view.entries.ok_or("row")?.len(),
            1
        );
        assert!(core.view().immich_locked_view.image.is_none());
        assert_eq!(shell.disk, before);
        shell.asset_failure = None;
        shell.asset_transport_failure = None;
        shell.drain(&core, pending)?;
        assert!(core.view().immich_locked_view.image.is_none());
        assert!(
            core.view()
                .immich_visibility_view
                .history
                .ok_or("history")?[0]
                .selected_observation
                .is_none()
        );
    }
    Ok(())
}

#[test]
fn newer_full_matching_inspection_retires_fallback_without_changing_original_outcome()
-> Result<(), String> {
    let (core, mut shell) = locked()?;
    let before = disk_operation(&shell)?;
    shell.relationship = Some(json!(CHILD));
    shell.run(&core, inspect())?;
    assert!(
        core.view()
            .immich_visibility_view
            .history
            .ok_or("history")?[0]
            .selected_observation
            .is_some()
    );
    let paths = shell.paths.len();
    shell.run(&core, prepare(NEXT, ImmichVisibility::Timeline))?;
    assert_eq!(
        shell.paths.len(),
        paths,
        "fallback cannot confer a direct-event write capability"
    );
    shell.relationship = Some(Value::Null);
    shell.visibility = Some("timeline".into());
    shell.run(&core, inspect())?;
    let after = disk_operation(&shell)?;
    assert_eq!(after["outcome"], before["outcome"]);
    assert_eq!(after["witnessDigest"], before["witnessDigest"]);
    assert!(after.get("selectedObservation").is_none());
    assert_eq!(after["observation"], "timeline");
    let summary = &core
        .view()
        .immich_visibility_view
        .history
        .ok_or("history")?[0];
    assert!(summary.selected_observation.is_none());
    assert_eq!(summary.observation, Some(ImmichVisibility::Timeline));
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn recovered_ambiguous_observation_disables_cached_hints_and_direct_prepare() -> Result<(), String>
{
    let (core, mut shell) = locked()?;
    shell.relationship = Some(json!(CHILD));
    shell.fail_persist = Some(shell.persist_calls + 1);
    shell.persist_after_failure = true;
    shell.read_fail = true;
    shell.run(&core, inspect())?;
    assert!(core.view().immich_visibility_view.persistence_uncertain);
    shell.read_fail = false;
    shell.run(
        &core,
        Event::RecoverImmichVisibilityState {
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(!core.view().immich_visibility_view.persistence_uncertain);
    let row = &core.view().immich_locked_view.entries.ok_or("row")?[0];
    assert!(!row.visibility_action.can_show_timeline);
    assert!(!row.visibility_action.can_show_archive);
    let paths = shell.paths.len();
    shell.run(&core, prepare(NEXT, ImmichVisibility::Timeline))?;
    assert_eq!(shell.paths.len(), paths);
    assert_eq!(shell.writes, 1);
    Ok(())
}

#[test]
fn selected_observation_installs_a_fence_even_for_an_old_not_applied_record() -> Result<(), String>
{
    let (_, shell) = locked()?;
    let mut state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
    state.immich_visibility_operations[0].outcome =
        suwop_core::apple_visibility::VisibilityOutcome::NotApplied;
    state.immich_visibility_operations[0].observation = None;
    assert!(!suwop_core::immich_visibility::fences(&state, &key()));
    let core = core_operations(false, state.immich_visibility_operations);
    let mut shell = Shell {
        visibility: Some("locked".into()),
        relationship: Some(json!(CHILD)),
        ..Shell::default()
    };
    shell.run(&core, open(GRANT))?;
    shell.run(&core, inspect())?;
    let state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    assert_eq!(
        state.immich_visibility_operations[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::NotApplied
    );
    assert!(state.immich_visibility_operations[0].observation.is_none());
    assert_eq!(shell.writes, 0);
    Ok(())
}

fn unknown_lock() -> Result<(Core<Suwop>, Shell), String> {
    let (core, mut shell) = opened(false)?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&core, prepare(OP, ImmichVisibility::Locked))?;
    shell.relationship = Some(json!(CHILD));
    Ok((core, shell))
}
#[test]
fn fresh_same_grant_unknown_locked_observation_allows_c1_read_only_but_durable_only_does_not()
-> Result<(), String> {
    let (core, mut shell) = unknown_lock()?;
    shell.run(&core, inspect())?;
    assert_eq!(
        core.view()
            .immich_locked_view
            .entries
            .ok_or("fresh row")?
            .len(),
        1
    );
    preview(&core, &mut shell)?;
    assert!(core.view().immich_locked_view.image.is_some());
    let state = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
    assert_eq!(
        state.immich_visibility_operations[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    assert!(state.immich_visibility_operations[0].observation.is_none());
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    let restart = core_operations(false, state.immich_visibility_operations);
    let mut row = asset();
    row["visibility"] = json!("locked");
    row["livePhotoVideoId"] = json!(CHILD);
    let mut reauth = Shell {
        visibility: Some("locked".into()),
        relationship: Some(json!(CHILD)),
        pages: Some(std::collections::VecDeque::from([
            json!({"assets":{"items":[row],"nextCursor":null}}),
        ])),
        ..Shell::default()
    };
    reauth.run(&restart, open(GRANT))?;
    assert!(
        restart
            .view()
            .immich_locked_view
            .entries
            .ok_or("open entries")?
            .is_empty()
    );
    preview(&restart, &mut reauth)?;
    assert_eq!(reauth.stages, 0);
    shell.run(
        &core,
        Event::RecoverImmichVisibilityState {
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(
        core.view()
            .immich_locked_view
            .entries
            .ok_or("recovered entries")?
            .is_empty()
    );
    assert!(core.view().immich_locked_view.image.is_none());
    Ok(())
}
#[test]
fn unknown_unlocked_observation_is_history_only() -> Result<(), String> {
    let (core, mut shell) = unknown_lock()?;
    shell.visibility = Some("timeline".into());
    shell.run(&core, inspect())?;
    assert!(
        core.view()
            .immich_locked_view
            .entries
            .ok_or("entries")?
            .is_empty()
    );
    let summary = &core
        .view()
        .immich_visibility_view
        .history
        .ok_or("history")?[0];
    assert_eq!(
        summary.outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    assert_eq!(
        summary
            .selected_observation
            .as_ref()
            .ok_or("selected state")?
            .visibility,
        ImmichVisibility::Timeline
    );
    assert!(!core.view().ordinary_content_keys.contains(&key()));
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn selected_preview_rechecks_stack_and_link_after_native_read() -> Result<(), String> {
    for drift in [
        json!({"livePhotoVideoId":"ffffffff-ffff-4fff-8fff-ffffffffffff"}),
        json!({"stack":{"id":"11111111-1111-4111-8111-111111111111","primaryAssetId":ASSET,"assetCount":2}}),
    ] {
        let (core, mut shell) = unknown_lock()?;
        shell.run(&core, inspect())?;
        shell.patch_after_stage = Some(drift);
        preview(&core, &mut shell)?;
        assert_eq!(shell.stages, 1);
        assert!(core.view().immich_locked_view.image.is_none());
        assert!(shell.releases.iter().any(|id| id == "stage1"));
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
#[test]
fn inspecting_another_key_preserves_current_selected_read_proof_and_preview() -> Result<(), String>
{
    let (_, shell) = unknown_lock()?;
    let state = suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?;
    let mut operations = state.immich_visibility_operations;
    let mut other = operations[0].clone();
    other.id = NEXT.into();
    other.key.asset_id = CHILD.into();
    operations.push(other);
    let core = core_operations(false, operations);
    let mut shell = Shell {
        visibility: Some("locked".into()),
        relationship: Some(json!(CHILD)),
        ..Shell::default()
    };
    shell.run(&core, open(GRANT))?;
    shell.run(&core, inspect())?;
    preview(&core, &mut shell)?;
    let image = core.view().immich_locked_view.image.ok_or("image")?;
    shell.run(
        &core,
        Event::InspectImmichVisibility {
            record_id: NEXT.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(core.view().immich_locked_view.image, Some(image));
    assert_eq!(
        core.view().immich_locked_view.entries.ok_or("row")?.len(),
        1
    );
    Ok(())
}
