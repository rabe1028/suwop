use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AppleFacts, AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider,
        ResourceRole, ScanAccess, StoredAsset, TransferBundle, TransferFile, TransferIntent,
        TransferPhase, TransferReceipt,
    },
    trash::{
        AppleTrashInspection, AppleTrashOutcome, AppleTrashResult, validate_ordinary_apple_trash,
    },
};
const OP: &str = "33333333-3333-4333-8333-333333333333";
fn photo(id: &str) -> StoredAsset {
    StoredAsset {
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: id.into(),
        },
        name: format!("{id}.jpg"),
        captured_at: Some(1.0),
        modified_at: Some(1.0),
        revision: "revision".into(),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: format!("{id}.jpg"),
            role: ResourceRole::Image,
            sha1: Some("1".repeat(40)),
            bytes: Some(12),
        }],
        is_favorite: true,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec!["編集・補助データがあるためコピーのみ".into()],
    }
}
fn facts(asset: StoredAsset) -> AppleFacts {
    AppleFacts {
        asset,
        full_access: true,
        can_delete: true,
        burst: false,
        shared: false,
        live: false,
    }
}
fn state() -> SavedLibrary {
    let mut counterpart = photo("counterpart");
    counterpart.key.provider = Provider::Immich;
    counterpart.key.scope = "remote".into();
    SavedLibrary {
        schema_version: 6,
        apple_scope: "apple".into(),
        snapshots: vec![
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "apple".into(),
                assets: vec![photo("one"), photo("two")],
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            },
            LibrarySnapshot {
                provider: Provider::Immich,
                scope: "remote".into(),
                assets: vec![counterpart],
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            },
        ],
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
#[derive(Clone, Copy, Default)]
enum Fault {
    #[default]
    None,
    Cancel,
    Limited,
    Denied,
    Changed,
    StartSave,
    OutcomeSave,
    FinishSave,
    NativeRejected,
    LostCallback,
    ExportCancelled,
}
#[derive(Default)]
struct Native {
    fault: Fault,
    writes: usize,
    inspections: usize,
    persists: usize,
    saved: Option<SavedLibrary>,
    absent: bool,
    effects: Vec<String>,
}
impl Native {
    fn persist(&mut self, s: &SavedLibrary) -> Result<Value, String> {
        self.persists += 1;
        if (matches!(self.fault, Fault::StartSave) && self.persists == 1)
            || (matches!(self.fault, Fault::OutcomeSave) && self.persists == 2)
            || (matches!(self.fault, Fault::FinishSave) && self.persists == 3)
        {
            Err("save failure".into())
        } else {
            self.saved = Some(s.clone());
            Ok(Value::Null)
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut requests = core.process_event(event);
        while !requests.is_empty() {
            let Effect::Io(mut r) = requests.remove(0);
            let value = match &r.operation {
                ShellOperation::ReadState => {
                    serde_json::to_value(&self.saved).map_err(|e| e.to_string())
                }
                ShellOperation::AppleTrashInspect { scope, keys } => {
                    self.effects.push("inspect".into());
                    self.inspections += 1;
                    if matches!(self.fault, Fault::Denied) {
                        Err("permission unavailable".into())
                    } else {
                        let mut assets: Vec<_> = if self.absent {
                            vec![]
                        } else {
                            keys.iter().map(|k| facts(photo(&k.asset_id))).collect()
                        };
                        if matches!(self.fault, Fault::Changed) && self.inspections == 2 {
                            assets[0].asset.revision = "changed".into();
                        }
                        serde_json::to_value(AppleTrashInspection {
                            scope: scope.clone(),
                            full_access: !matches!(self.fault, Fault::Limited),
                            assets,
                        })
                        .map_err(|e| e.to_string())
                    }
                }
                ShellOperation::ConfirmAppleTrash { prompt } => {
                    assert_eq!(prompt.scope, "apple");
                    assert!(!prompt.names.is_empty());
                    Ok(json!(!matches!(self.fault, Fault::Cancel)))
                }
                ShellOperation::Workspace { .. } => Ok(json!("/tmp/trash-test")),
                ShellOperation::AppleExport { keys, directory } => {
                    if matches!(self.fault, Fault::ExportCancelled) {
                        Err("cancelled".into())
                    } else {
                        let assets: Vec<_> = keys.iter().map(|k| photo(&k.asset_id)).collect();
                        let files = assets
                            .iter()
                            .map(|a| TransferFile {
                                resource: a.resources[0].clone(),
                                path: format!("{directory}/{}", a.key.asset_id),
                                signature: FileSignature {
                                    sha256: "2".repeat(64),
                                    bytes: 12,
                                },
                            })
                            .collect();
                        serde_json::to_value(TransferBundle { assets, files })
                            .map_err(|e| e.to_string())
                    }
                }
                ShellOperation::Cleanup { .. } => Ok(Value::Null),
                ShellOperation::Persist(s) => self.persist(s),
                ShellOperation::AppleTrashApply { assets } => {
                    self.effects.push("delete".into());
                    self.writes += 1;
                    let saved = self.saved.as_ref().ok_or("mutation before journal")?;
                    assert_eq!(
                        saved.pending_apple_trash[0].outcome,
                        AppleTrashOutcome::Unknown
                    );
                    assert_eq!(saved.pending_apple_trash[0].assets.len(), assets.len());
                    self.absent = !matches!(self.fault, Fault::NativeRejected);
                    if matches!(self.fault, Fault::LostCallback) {
                        Err("lost callback".into())
                    } else {
                        serde_json::to_value(AppleTrashResult {
                            applied: self.absent,
                            error: if self.absent {
                                None
                            } else {
                                Some("native cancelled/rejected".into())
                            },
                        })
                        .map_err(|e| e.to_string())
                    }
                }
                unexpected => return Err(format!("unexpected {unexpected:?}")),
            };
            let (value, error) = match value {
                Ok(v) => (Some(v), None),
                Err(e) => (None, Some(e)),
            };
            requests.extend(
                core.resolve(&mut r, ShellResponse { value, error })
                    .map_err(|e| e.to_string())?,
            );
        }
        Ok(())
    }
}
fn delete(keys: Vec<AssetKey>) -> Event {
    Event::TrashApple {
        keys,
        id: OP.into(),
    }
}
#[test]
fn normal_delete_is_independent_of_move_preserves_counterpart_and_other_records()
-> Result<(), String> {
    let mut state = state();
    let mut untouched = photo("unrelated");
    untouched.resources[0].sha1 = Some("3".repeat(40));
    state.snapshots[0].assets.push(untouched.clone());
    for (id, intent) in [
        ("old-copy", TransferIntent::Copy),
        ("old-move", TransferIntent::Move),
    ] {
        state.receipts.push(TransferReceipt {
            id: id.into(),
            created_at: 1.0,
            phase: TransferPhase::Copied,
            intent,
            source: vec![untouched.clone()],
            destination: state.snapshots[1].assets.clone(),
            destination_provider: Provider::Immich,
            destination_scope: "remote".into(),
            signatures: std::collections::BTreeSet::new(),
        });
    }
    let original = serde_json::to_value(&state).map_err(|e| e.to_string())?;
    let core = core(state);
    let mut native = Native::default();
    native.run(&core, delete(vec![photo("one").key, photo("two").key]))?;
    let view = core.view();
    assert!(view.error.is_none(), "{:?}", view.error);
    assert_eq!(native.writes, 1);
    assert_eq!(native.persists, 3);
    assert!(view.state.pending_apple_trash.is_empty());
    let canonical = native.saved.as_ref().ok_or("no canonical journal")?;
    assert!(view.state.snapshots[0].assets.is_empty());
    assert_eq!(
        serde_json::to_value(&canonical.receipts).map_err(|e| e.to_string())?,
        original["receipts"]
    );
    assert_eq!(
        serde_json::to_value(&canonical.snapshots[1]).map_err(|e| e.to_string())?,
        original["snapshots"][1]
    );
    assert_eq!(
        serde_json::to_value(&canonical.snapshots[0].assets).map_err(|e| e.to_string())?,
        json!([untouched])
    );
    Ok(())
}
#[test]
fn preflight_failures_and_native_rejection_do_not_leave_unknown_record() -> Result<(), String> {
    for fault in [
        Fault::Cancel,
        Fault::Limited,
        Fault::Denied,
        Fault::Changed,
        Fault::StartSave,
        Fault::ExportCancelled,
        Fault::NativeRejected,
    ] {
        let core = core(state());
        let mut native = Native {
            fault,
            ..Native::default()
        };
        native.run(&core, delete(vec![photo("one").key]))?;
        assert!(core.view().state.pending_apple_trash.is_empty());
        assert_eq!(
            native.writes,
            usize::from(matches!(fault, Fault::NativeRejected))
        );
        let canonical = native.saved.clone().unwrap_or_else(state);
        assert_eq!(canonical.snapshots[0].assets.len(), 2);
        if canonical.snapshots[0].access == ScanAccess::Unavailable {
            assert!(core.view().state.snapshots[0].assets.is_empty());
        }
    }
    Ok(())
}
#[test]
fn callback_loss_and_outcome_persist_failure_survive_restart_without_replay_or_absence_based_clear()
-> Result<(), String> {
    for fault in [Fault::LostCallback, Fault::OutcomeSave] {
        let first = core(state());
        let mut native = Native {
            fault,
            ..Native::default()
        };
        native.run(&first, delete(vec![photo("one").key]))?;
        assert_eq!(native.writes, 1);
        assert_eq!(
            first.view().state.pending_apple_trash[0].outcome,
            AppleTrashOutcome::Unknown
        );
        let restarted = core(native.saved.clone().ok_or("no journal")?);
        native.fault = Fault::None;
        native.run(&restarted, Event::ResolveAppleTrash { id: OP.into() })?;
        assert_eq!(native.writes, 1);
        assert_eq!(restarted.view().state.pending_apple_trash.len(), 1);
        assert!(
            restarted
                .view()
                .status
                .contains("復元可能性は確認できません")
        );
        native.run(
            &restarted,
            Event::SetFavorite {
                keys: vec![photo("one").key],
                value: false,
            },
        )?;
        assert!(restarted.view().error.is_some());
        native.run(
            &restarted,
            Event::Copy {
                keys: vec![photo("one").key],
                intent: TransferIntent::Copy,
                id: OP.into(),
                now: 1.0,
            },
        )?;
        assert!(restarted.view().error.is_some());
        assert_eq!(native.writes, 1);
    }
    Ok(())
}
#[test]
fn durably_applied_outcome_finalizes_after_restart_without_native_replay() -> Result<(), String> {
    let first = core(state());
    let mut native = Native {
        fault: Fault::FinishSave,
        ..Native::default()
    };
    native.run(&first, delete(vec![photo("one").key]))?;
    let saved = native.saved.clone().ok_or("no journal")?;
    assert_eq!(
        saved.pending_apple_trash[0].outcome,
        AppleTrashOutcome::Applied
    );
    let restarted = core(saved);
    native.fault = Fault::None;
    native.run(&restarted, Event::ResolveAppleTrash { id: OP.into() })?;
    assert!(restarted.view().state.pending_apple_trash.is_empty());
    assert_eq!(native.writes, 1);
    assert_eq!(
        native
            .saved
            .as_ref()
            .ok_or("no canonical journal")?
            .snapshots[0]
            .assets[0]
            .key,
        photo("two").key
    );
    Ok(())
}
#[test]
fn ordinary_policy_accepts_native_edit_live_burst_but_rejects_permissions_changed_ids_and_duplicates()
 {
    let original = photo("one");
    let mut native = facts(original.clone());
    native.burst = true;
    native.live = true;
    assert!(
        validate_ordinary_apple_trash(
            std::slice::from_ref(&original),
            std::slice::from_ref(&native)
        )
        .is_ok()
    );
    assert!(validate_ordinary_apple_trash(&[], &[]).is_err());
    assert!(
        validate_ordinary_apple_trash(
            &[original.clone(), original.clone()],
            &[native.clone(), native.clone()]
        )
        .is_err()
    );
    native.can_delete = false;
    assert!(
        validate_ordinary_apple_trash(std::slice::from_ref(&original), &[native.clone()]).is_err()
    );
    native.can_delete = true;
    native.asset.key.scope = "other".into();
    assert!(validate_ordinary_apple_trash(&[original], &[native]).is_err());
}

#[test]
fn pending_journal_fences_counterparts_but_allows_unrelated_keys_and_rejects_corruption()
-> Result<(), String> {
    let first = core(state());
    let mut native = Native {
        fault: Fault::LostCallback,
        ..Native::default()
    };
    native.run(&first, delete(vec![photo("one").key]))?;
    let mut saved = native.saved.clone().ok_or("no journal")?;
    // Refresh can make unrelated Apple records writable; unknown selected record stays fenced.
    saved.snapshots[0].access = ScanAccess::Full;
    saved.snapshots[0].assets[1].resources[0].sha1 = Some("3".repeat(40));
    let remote = saved.snapshots[1].assets[0].key.clone();
    let restarted = core(saved.clone());
    native.fault = Fault::None;
    native.run(
        &restarted,
        Event::SetFavorite {
            keys: vec![remote],
            value: false,
        },
    )?;
    assert!(
        restarted
            .view()
            .error
            .as_deref()
            .is_some_and(|e| e.contains("削除結果が不明"))
    );
    let unrelated = core(saved.clone());
    let effects = unrelated.process_event(Event::SetFavorite {
        keys: vec![photo("two").key],
        value: false,
    });
    assert!(effects.iter().any(|e| matches!(e, Effect::Io(r) if matches!(r.operation, ShellOperation::AppleFavorite { .. }))));
    for mode in 0..4 {
        let mut corrupt = saved.clone();
        corrupt.pending_apple_trash[0].outcome = AppleTrashOutcome::Applied;
        match mode {
            0 => corrupt.pending_apple_trash[0].assets.clear(),
            1 => {
                let duplicate = corrupt.pending_apple_trash[0].clone();
                corrupt.pending_apple_trash.push(duplicate);
            }
            2 => corrupt.pending_apple_trash[0].assets[0].key.scope = "other".into(),
            _ => corrupt.pending_apple_trash[0].assets[0].resources[0].sha1 = None,
        }
        let damaged = core(corrupt.clone());
        native.run(&damaged, Event::ResolveAppleTrash { id: OP.into() })?;
        assert!(damaged.view().error.is_some());
        assert_eq!(
            damaged.view().state.pending_apple_trash.len(),
            corrupt.pending_apple_trash.len()
        );
        assert_eq!(damaged.view().state.snapshots[0].assets.len(), 2);
    }
    assert_eq!(native.writes, 1);
    Ok(())
}
