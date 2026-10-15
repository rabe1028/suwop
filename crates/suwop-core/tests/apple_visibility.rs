use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    apple_visibility::{
        AppleVisibilityApply, AppleVisibilityFacts, AppleVisibilityInspection,
        AppleVisibilityOperation, VisibilityAction, VisibilityApplyTarget, VisibilityIdentity,
        VisibilityObservation, VisibilityOutcome, VisibilityResource, VisibilityTarget,
        valid_operation_id, validate_apply, witness,
    },
    domain::{
        AppleVisibility, AssetKey, LibrarySnapshot, Provider, ResourceRole, ScanAccess, StoredAsset,
    },
};
const ID: &str = "33333333-3333-4333-8333-333333333333";
fn facts(id: &str) -> AppleVisibilityFacts {
    AppleVisibilityFacts {
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: id.into(),
        },
        full_access: true,
        can_edit_properties: true,
        visibility: AppleVisibility::Visible,
        fresh_revision: "fresh".into(),
        identity: VisibilityIdentity {
            creation_date: Some(1.0),
            pixel_width: 100,
            pixel_height: 200,
            media_type: 1,
            media_subtypes: 0,
            resources: vec![VisibilityResource {
                id: "0:1".into(),
                role: ResourceRole::Image,
                original_filename: "secret.jpg".into(),
            }],
        },
    }
}
fn asset(id: &str) -> StoredAsset {
    StoredAsset {
        key: facts(id).key,
        apple_visibility: AppleVisibility::Visible,
        name: "secret.jpg".into(),
        captured_at: Some(1.0),
        modified_at: None,
        revision: "old".into(),
        resources: vec![],
        is_favorite: false,
        latitude: Some(35.0),
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn state() -> SavedLibrary {
    SavedLibrary {
        schema_version: 6,
        apple_scope: "apple".into(),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: vec![asset("one"), asset("two")],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        }],
        ..SavedLibrary::default()
    }
}
fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            state,
            ready: true,
            ..Model::default()
        },
    )
}
// Independent fault switches let contract tests inject each native failure.
#[allow(clippy::struct_excessive_bools)]
#[derive(Default)]
struct Shell {
    inspections: usize,
    writes: usize,
    persists: usize,
    fail_persist: usize,
    lost: bool,
    cancel: bool,
    race: bool,
    hidden: bool,
    partial: bool,
    unavailable: bool,
    malformed_second: bool,
    rejected: bool,
    saved: Option<SavedLibrary>,
}
impl Shell {
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut requests = core.process_event(event);
        while !requests.is_empty() {
            let Effect::Io(mut r) = requests.remove(0);
            let value = match &r.operation {
                ShellOperation::AppleVisibilityInspect { scope, keys } => {
                    self.inspections += 1;
                    let mut assets = keys.iter().map(|k| facts(&k.asset_id)).collect::<Vec<_>>();
                    if self.hidden {
                        for a in &mut assets {
                            a.visibility = AppleVisibility::Hidden;
                        }
                    }
                    if self.race && self.inspections == 3 {
                        assets[0].identity.pixel_width += 1;
                    }
                    if self.malformed_second && assets.len() > 1 {
                        assets[1].identity.resources.clear();
                    }
                    if self.partial {
                        assets.truncate(1);
                    }
                    if self.unavailable {
                        assets.clear();
                    }
                    serde_json::to_value(AppleVisibilityInspection {
                        scope: scope.clone(),
                        full_access: !self.unavailable,
                        assets,
                    })
                    .map_err(|e| e.to_string())
                }
                ShellOperation::ConfirmAppleVisibility { prompt } => {
                    valid_operation_id(&prompt.id)?;
                    Ok(json!(!self.cancel))
                }
                ShellOperation::Persist(s) => {
                    self.persists += 1;
                    if self.persists == self.fail_persist {
                        Err("persist failure".into())
                    } else {
                        self.saved = Some(s.clone());
                        Ok(Value::Null)
                    }
                }
                ShellOperation::AppleVisibilityApply { request } => {
                    assert!(self.saved.as_ref().is_some_and(|s| {
                        s.apple_visibility_operations
                            .last()
                            .is_some_and(|o| o.outcome == VisibilityOutcome::Unknown)
                    }));
                    self.writes += 1;
                    assert_eq!(request.targets.len(), 2);
                    if self.lost {
                        Err("callback lost".into())
                    } else {
                        Ok(json!({"outcome":if self.rejected {"notApplied"} else {"applied"}}))
                    }
                }
                other => return Err(format!("unexpected {other:?}")),
            };
            requests.extend(
                core.resolve(
                    &mut r,
                    ShellResponse {
                        value: value.as_ref().ok().cloned(),
                        error: value.err(),
                    },
                )
                .map_err(|e| e.to_string())?,
            );
        }
        Ok(())
    }
}
fn hide() -> Event {
    Event::HideApple {
        keys: vec![facts("one").key, facts("two").key],
        id: ID.into(),
    }
}
#[test]
fn witness_excludes_visibility_and_revision_but_detects_replacement() -> Result<(), String> {
    let a = facts("one");
    let mut b = a.clone();
    b.visibility = AppleVisibility::Hidden;
    b.fresh_revision = "modified".into();
    assert_eq!(witness(&a)?, witness(&b)?);
    b.identity.resources[0].original_filename = "replacement.jpg".into();
    assert_ne!(witness(&a)?, witness(&b)?);
    Ok(())
}
#[test]
fn fresh_native_gate_rejects_permissions_duplicates_revision_scope_and_identity()
-> Result<(), String> {
    let f = facts("one");
    let request = AppleVisibilityApply {
        id: ID.into(),
        scope: "apple".into(),
        action: VisibilityAction::Hide,
        targets: vec![VisibilityApplyTarget {
            key: f.key.clone(),
            expected_witness: witness(&f)?,
            fresh_revision: f.fresh_revision.clone(),
        }],
    };
    let snapshot = AppleVisibilityInspection {
        scope: "apple".into(),
        full_access: true,
        assets: vec![f],
    };
    validate_apply(&request, &snapshot)?;
    for mode in 0..6 {
        let mut bad = snapshot.clone();
        match mode {
            0 => bad.full_access = false,
            1 => bad.assets[0].can_edit_properties = false,
            2 => bad.assets.push(bad.assets[0].clone()),
            3 => bad.assets[0].fresh_revision = "race".into(),
            4 => bad.scope = "other".into(),
            _ => bad.assets[0].identity.pixel_width += 1,
        }
        assert!(validate_apply(&request, &bad).is_err());
    }
    Ok(())
}
#[test]
fn confirmation_cancel_race_and_initial_persist_failure_never_write() -> Result<(), String> {
    for mode in 0..3 {
        let c = core(state());
        let mut s = Shell::default();
        match mode {
            0 => s.cancel = true,
            1 => s.race = true,
            _ => s.fail_persist = 1,
        }
        s.run(&c, hide())?;
        assert_eq!(s.writes, 0);
    }
    Ok(())
}
#[test]
fn lost_response_and_final_persist_failure_keep_restart_fence_without_replay() -> Result<(), String>
{
    for mode in 0..2 {
        let c = core(state());
        let mut s = Shell::default();
        if mode == 0 {
            s.lost = true;
        } else {
            s.fail_persist = 2;
        }
        s.run(&c, hide())?;
        assert_eq!(s.writes, 1);
        let saved = s.saved.clone().ok_or("saved")?;
        assert_eq!(
            saved.apple_visibility_operations[0].outcome,
            VisibilityOutcome::Unknown
        );
        let restarted = core(saved);
        s.run(&restarted, hide())?;
        assert_eq!(s.writes, 1);
        assert!(restarted.view().state.snapshots[0].assets.is_empty());
    }
    Ok(())
}
#[test]
fn explicit_partial_observation_settles_only_matched_targets_and_never_outcome()
-> Result<(), String> {
    let c = core(state());
    let mut s = Shell {
        lost: true,
        ..Shell::default()
    };
    s.run(&c, hide())?;
    s.partial = true;
    s.hidden = true;
    s.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let saved = s.saved.as_ref().ok_or("saved")?;
    let op = &saved.apple_visibility_operations[0];
    assert_eq!(op.outcome, VisibilityOutcome::Unknown);
    assert!(!op.fences(&facts("one").key));
    assert!(op.fences(&facts("two").key));
    s.unavailable = true;
    s.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    assert!(
        s.saved.as_ref().ok_or("saved")?.apple_visibility_operations[0].fences(&facts("two").key)
    );
    Ok(())
}
#[test]
fn schema_three_migrates_without_swallowing_journal_and_summary_hides_inventory()
-> Result<(), String> {
    let f = facts("one");
    let mut state = state();
    state
        .apple_visibility_operations
        .push(AppleVisibilityOperation {
            id: ID.into(),
            scope: "apple".into(),
            action: VisibilityAction::Hide,
            outcome: VisibilityOutcome::Unknown,
            targets: vec![VisibilityTarget {
                key: f.key,
                witness_digest: witness(&facts("one"))?,
                observation: None,
            }],
        });
    let mut raw = serde_json::to_value(&state).map_err(|e| e.to_string())?;
    raw["schemaVersion"] = json!(3);
    let migrated = suwop_core::workflow::migrate(raw)?;
    assert_eq!(migrated.schema_version, 6);
    assert_eq!(migrated.apple_visibility_operations.len(), 1);
    let view = core(migrated).view();
    let public = serde_json::to_string(&view.state.apple_visibility_operations)
        .map_err(|e| e.to_string())?;
    assert!(!public.contains("one"));
    assert!(!public.contains("secret"));
    assert!(!public.contains("witness"));
    Ok(())
}

#[test]
fn malformed_second_inspection_cannot_clear_first_fence() -> Result<(), String> {
    let c = core(state());
    let mut s = Shell {
        lost: true,
        ..Shell::default()
    };
    s.run(&c, hide())?;
    s.malformed_second = true;
    s.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let saved = s.saved.as_ref().ok_or("saved")?;
    assert!(
        saved.apple_visibility_operations[0]
            .targets
            .iter()
            .all(|t| t.observation.is_none())
    );
    assert!(c.view().error.is_some());
    Ok(())
}

#[test]
fn record_events_use_explicit_record_id_abi() -> Result<(), String> {
    for event in [
        Event::UnhideApple {
            record_id: ID.into(),
            id: ID.into(),
        },
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    ] {
        let value = serde_json::to_value(event).map_err(|e| e.to_string())?;
        assert_eq!(value["recordID"], json!(ID));
        assert!(value.get("record_id").is_none());
    }
    Ok(())
}

#[test]
fn normal_fresh_scan_does_not_clear_unknown_fence_or_hide_immich_copy() -> Result<(), String> {
    let c = core(state());
    let mut s = Shell {
        lost: true,
        ..Shell::default()
    };
    s.run(&c, hide())?;
    let mut restarted = s.saved.clone().ok_or("saved")?;
    restarted.snapshots[0].access = ScanAccess::Full;
    let mut counterpart = asset("samehash-copy");
    counterpart.key.provider = Provider::Immich;
    counterpart.key.scope = "remote".into();
    restarted.snapshots.push(LibrarySnapshot {
        provider: Provider::Immich,
        scope: "remote".into(),
        assets: vec![counterpart],
        access: ScanAccess::Full,
        scanned_at: Some(2.0),
    });
    let view = core(restarted).view();
    assert!(view.state.snapshots[0].assets.is_empty());
    assert_eq!(view.state.snapshots[1].assets.len(), 1);
    assert_eq!(
        view.state.apple_visibility_operations[0].outcome,
        VisibilityOutcome::Unknown
    );
    Ok(())
}
#[test]
fn known_hidden_record_unhides_with_new_uuid_but_missing_ids_never_write() -> Result<(), String> {
    for missing in [false, true] {
        let c = core(state());
        let mut s = Shell::default();
        s.run(&c, hide())?;
        s.hidden = true;
        s.unavailable = missing;
        s.run(
            &c,
            Event::UnhideApple {
                record_id: ID.into(),
                id: "44444444-4444-4444-8444-444444444444".into(),
            },
        )?;
        assert_eq!(s.writes, if missing { 1 } else { 2 });
    }
    Ok(())
}

#[test]
fn successful_unhide_disables_original_record_and_repeated_event_before_native_inspection()
-> Result<(), String> {
    let c = core(state());
    let mut shell = Shell::default();
    shell.run(&c, hide())?;
    shell.hidden = true;
    shell.run(
        &c,
        Event::UnhideApple {
            record_id: ID.into(),
            id: "44444444-4444-4444-8444-444444444444".into(),
        },
    )?;
    let view = c.view();
    assert!(!view.state.apple_visibility_operations[0].can_unhide);
    assert_eq!(
        view.state.apple_visibility_operations[0].outcome,
        VisibilityOutcome::Applied
    );
    let inspections = shell.inspections;
    shell.run(
        &c,
        Event::UnhideApple {
            record_id: ID.into(),
            id: "55555555-5555-4555-8555-555555555555".into(),
        },
    )?;
    assert_eq!(shell.inspections, inspections);
    assert_eq!(shell.writes, 2);
    assert!(c.view().error.is_some());
    Ok(())
}

#[test]
fn explicit_visible_inspection_overrides_applied_hide_without_rewriting_native_outcome()
-> Result<(), String> {
    let c = core(state());
    let mut shell = Shell::default();
    shell.run(&c, hide())?;
    shell.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let view = c.view();
    assert!(!view.state.apple_visibility_operations[0].can_unhide);
    let original = &shell
        .saved
        .as_ref()
        .ok_or("saved")?
        .apple_visibility_operations[0];
    assert_eq!(original.outcome, VisibilityOutcome::Applied);
    assert!(
        original
            .targets
            .iter()
            .all(|target| target.observation == Some(VisibilityObservation::ObservedVisible))
    );
    let inspections = shell.inspections;
    shell.run(
        &c,
        Event::UnhideApple {
            record_id: ID.into(),
            id: "44444444-4444-4444-8444-444444444444".into(),
        },
    )?;
    assert_eq!(shell.inspections, inspections);
    assert_eq!(shell.writes, 1);
    Ok(())
}

fn visibility_record(
    id: &str,
    action: VisibilityAction,
    outcome: VisibilityOutcome,
    targets: &[&str],
) -> Result<AppleVisibilityOperation, String> {
    Ok(AppleVisibilityOperation {
        id: id.into(),
        scope: "apple".into(),
        action,
        outcome,
        targets: targets
            .iter()
            .map(|id| {
                let facts = facts(id);
                Ok(VisibilityTarget {
                    key: facts.key.clone(),
                    witness_digest: witness(&facts)?,
                    observation: None,
                })
            })
            .collect::<Result<_, String>>()?,
    })
}

#[test]
fn later_partial_restore_only_supersedes_matching_physical_identity_and_preserves_unknown_fences()
-> Result<(), String> {
    let original = visibility_record(
        ID,
        VisibilityAction::Hide,
        VisibilityOutcome::Applied,
        &["one", "two"],
    )?;
    let restore = visibility_record(
        "44444444-4444-4444-8444-444444444444",
        VisibilityAction::Unhide,
        VisibilityOutcome::Applied,
        &["one"],
    )?;
    assert!(
        !original
            .summary_with_history(&[original.clone(), restore.clone()])
            .can_unhide
    );
    let unaffected = visibility_record(
        "66666666-6666-4666-8666-666666666666",
        VisibilityAction::Hide,
        VisibilityOutcome::Applied,
        &["two"],
    )?;
    assert!(
        unaffected
            .summary_with_history(&[unaffected.clone(), restore.clone()])
            .can_unhide
    );
    let mut different = restore.clone();
    different.targets[0].witness_digest = "f".repeat(64);
    assert!(
        !original
            .summary_with_history(&[original.clone(), different])
            .can_unhide
    );
    let mut uncertain = restore.clone();
    uncertain.outcome = VisibilityOutcome::Unknown;
    assert!(uncertain.fences(&facts("one").key));
    assert!(
        !original
            .summary_with_history(&[original.clone(), uncertain])
            .can_unhide
    );
    let mut rejected = restore;
    rejected.outcome = VisibilityOutcome::NotApplied;
    assert!(
        original
            .summary_with_history(&[original.clone(), rejected])
            .can_unhide
    );
    Ok(())
}

#[test]
fn inspecting_older_record_propagates_only_fresh_matching_observations_atomically()
-> Result<(), String> {
    let mut saved = state();
    let mut original = visibility_record(
        ID,
        VisibilityAction::Hide,
        VisibilityOutcome::Applied,
        &["one", "two"],
    )?;
    for target in &mut original.targets {
        target.observation = Some(VisibilityObservation::ObservedHidden);
    }
    let restore = visibility_record(
        "44444444-4444-4444-8444-444444444444",
        VisibilityAction::Unhide,
        VisibilityOutcome::Unknown,
        &["one", "two"],
    )?;
    saved.apple_visibility_operations = vec![original, restore];
    let c = core(saved);
    let mut shell = Shell {
        hidden: true,
        partial: true,
        ..Shell::default()
    };
    shell.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let saved = shell.saved.as_ref().ok_or("saved")?;
    let restore = &saved.apple_visibility_operations[1];
    assert_eq!(restore.outcome, VisibilityOutcome::Unknown);
    assert_eq!(
        restore.targets[0].observation,
        Some(VisibilityObservation::ObservedHidden)
    );
    assert!(
        restore.targets[1].observation.is_none(),
        "Missing facts must not propagate an old stored observation"
    );
    assert!(restore.fences(&facts("two").key));
    assert!(!c.view().state.apple_visibility_operations[0].can_unhide);
    assert_eq!(shell.writes, 0);
    shell.partial = false;
    shell.fail_persist = shell.persists + 1;
    shell.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let retained = &shell
        .saved
        .as_ref()
        .ok_or("saved")?
        .apple_visibility_operations[1];
    assert!(retained.targets[1].observation.is_none());
    assert!(retained.fences(&facts("two").key));
    assert!(!c.view().state.apple_visibility_operations[0].can_unhide);
    assert!(c.view().error.is_some());
    Ok(())
}
#[test]
fn migration_rejects_duplicate_wrong_scope_and_invalid_uuid_journals() -> Result<(), String> {
    let f = facts("one");
    let op = AppleVisibilityOperation {
        id: ID.into(),
        scope: "apple".into(),
        action: VisibilityAction::Hide,
        outcome: VisibilityOutcome::Unknown,
        targets: vec![VisibilityTarget {
            key: f.key,
            witness_digest: witness(&facts("one"))?,
            observation: None,
        }],
    };
    for mode in 0..3 {
        let mut state = state();
        let mut op = op.clone();
        match mode {
            0 => state.apple_visibility_operations.push(op.clone()),
            1 => op.scope = "wrong".into(),
            _ => op.id = "not-uuid".into(),
        }
        state.apple_visibility_operations.push(op);
        let raw = serde_json::to_value(state).map_err(|e| e.to_string())?;
        assert!(suwop_core::workflow::migrate(raw).is_err());
    }
    Ok(())
}

#[test]
fn observation_persist_failure_restores_all_unresolved_fences() -> Result<(), String> {
    let c = core(state());
    let mut s = Shell {
        lost: true,
        ..Shell::default()
    };
    s.run(&c, hide())?;
    s.fail_persist = s.persists + 1;
    s.run(
        &c,
        Event::InspectAppleVisibility {
            record_id: ID.into(),
        },
    )?;
    let saved = s.saved.clone().ok_or("saved")?;
    assert!(
        saved.apple_visibility_operations[0]
            .targets
            .iter()
            .all(|t| t.observation.is_none())
    );
    let restart = core(saved);
    assert!(restart.view().state.snapshots[0].assets.is_empty());
    assert!(c.view().error.is_some());
    Ok(())
}

#[test]
fn native_rejection_is_durable_and_does_not_authorize_unhide() -> Result<(), String> {
    let c = core(state());
    let mut shell = Shell {
        rejected: true,
        ..Shell::default()
    };
    shell.run(&c, hide())?;
    let saved = shell.saved.as_ref().ok_or("saved")?;
    assert_eq!(
        saved.apple_visibility_operations[0].outcome,
        VisibilityOutcome::NotApplied
    );
    assert!(!saved.apple_visibility_operations[0].summary().can_unhide);
    Ok(())
}

#[test]
fn unknown_deletion_same_original_blocks_visibility_changes() -> Result<(), String> {
    use suwop_core::{
        domain::PhotoResource,
        trash::{AppleTrashOperation, AppleTrashOutcome},
    };
    let mut state = state();
    let resource = PhotoResource {
        id: "original".into(),
        name: "secret.jpg".into(),
        role: ResourceRole::Image,
        sha1: Some("1".repeat(40)),
        bytes: Some(12),
    };
    state.snapshots[0].assets[0]
        .resources
        .push(resource.clone());
    let mut pending = asset("another-id");
    pending.resources.push(resource);
    state.pending_apple_trash.push(AppleTrashOperation {
        id: "55555555-5555-4555-8555-555555555555".into(),
        scope: "apple".into(),
        assets: vec![pending],
        outcome: AppleTrashOutcome::Unknown,
        visibility: None,
    });
    let c = core(state);
    let mut shell = Shell::default();
    shell.run(&c, hide())?;
    assert_eq!(shell.writes, 0);
    assert_eq!(shell.inspections, 0);
    assert!(c.view().error.is_some());
    Ok(())
}

#[test]
fn hide_eligibility_requires_current_full_snapshot_and_unknown_fences_block_exact_keys() {
    let mut state = state();
    assert_eq!(suwop_core::apple_visibility::hide_keys(&state).len(), 2);
    state.snapshots[0].access = ScanAccess::Limited;
    assert!(suwop_core::apple_visibility::hide_keys(&state).is_empty());
    state.snapshots[0].access = ScanAccess::Full;
    state
        .apple_visibility_operations
        .push(AppleVisibilityOperation {
            id: ID.into(),
            scope: "apple".into(),
            action: VisibilityAction::Hide,
            outcome: VisibilityOutcome::Unknown,
            targets: vec![VisibilityTarget {
                key: facts("one").key,
                witness_digest: "a".repeat(64),
                observation: None,
            }],
        });
    assert_eq!(
        suwop_core::apple_visibility::hide_keys(&state),
        vec![facts("two").key]
    );
}
