use crux_core::Core;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    editing::{
        AdjustmentBase, AppleAdjustment, AppleEditInput, AppleEditResult, ColorAdjustments,
        EditClipboard, EditCopyOptions, GeometryAdjustment, ImageEncodingFacts, ImageTransform,
        PixelSize,
    },
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
fn key(index: u32) -> AssetKey {
    AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: format!("photo-{index}"),
    }
}
fn asset(index: u32) -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: key(index),
        name: format!("photo-{index}.jpg"),
        captured_at: Some(10.0),
        modified_at: Some(10.0),
        revision: "before".into(),
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
        resources: vec![PhotoResource {
            id: "0".into(),
            name: format!("photo-{index}.jpg"),
            role: ResourceRole::Image,
            sha1: Some(format!("{index:040x}")),
            bytes: Some(12),
        }],
    }
}
fn dimensions() -> PixelSize {
    PixelSize {
        width: 60,
        height: 40,
    }
}
fn clipboard() -> Result<EditClipboard, String> {
    let mut transform = ImageTransform::original(dimensions())?;
    transform.color = ColorAdjustments {
        exposure: 120,
        ..ColorAdjustments::default()
    };
    Ok(EditClipboard {
        source_key: None,
        source_name: "edited.jpg".into(),
        dimensions: dimensions(),
        transform,
        options: EditCopyOptions {
            adjustments: true,
            filter: true,
            geometry: false,
        },
    })
}
fn core(mut state: SavedLibrary) -> Core<Suwop> {
    for snapshot in &mut state.snapshots {
        snapshot.access = ScanAccess::Full;
    }
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            ..Model::default()
        },
    )
}
fn state() -> Result<SavedLibrary, String> {
    Ok(SavedLibrary {
        schema_version: 8,
        apple_scope: "apple".into(),
        edit_clipboard: Some(clipboard()?),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: (0..3).map(asset).collect(),
            access: ScanAccess::Full,
            scanned_at: None,
        }],
        ..SavedLibrary::default()
    })
}
#[derive(Clone, Copy, Default)]
enum Fault {
    #[default]
    None,
    Cancel,
    ForeignPreflight,
    StaleAfterConfirmation,
    Journal,
    SecondSaveLost,
    WrongResult,
    OriginalChanged,
    CompletionPersist,
    Close,
}
#[derive(Default)]
struct Native {
    current: BTreeMap<AssetKey, StoredAsset>,
    adjustments: BTreeMap<AssetKey, AppleAdjustment>,
    operations: Vec<&'static str>,
    persisted: Vec<SavedLibrary>,
    writes: Vec<AssetKey>,
    fault: Fault,
    confirmed: bool,
    observe_changes: bool,
}
impl Native {
    fn refreshed_core(&self, _old: &Core<Suwop>) -> Result<Core<Suwop>, String> {
        let mut saved = self.persisted.last().cloned().ok_or("no durable journal")?;
        saved.snapshots[0].assets = self.current.values().cloned().collect();
        Ok(core(saved))
    }
    fn new(fault: Fault) -> Self {
        Self {
            current: (0..3).map(|i| (key(i), asset(i))).collect(),
            fault,
            ..Self::default()
        }
    }
    fn facts(size: PixelSize) -> ImageEncodingFacts {
        ImageEncodingFacts {
            raw_dimensions: size,
            orientation: 1,
            has_color_space: true,
            has_alpha: false,
            hdr: false,
        }
    }
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope,
                assets: self.current.values().cloned().collect(),
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            })
            .map_err(|e| e.to_string()),
            ShellOperation::Workspace { .. } => Ok(json!("/tmp/paste-workspace")),
            ShellOperation::Cleanup { .. } => {
                self.operations.push("cleanup");
                Ok(Value::Null)
            }
            ShellOperation::AppleEditClose { .. } => {
                self.operations.push("close");
                if matches!(self.fault, Fault::Close) {
                    return Err("lease close failed".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::AppleExport { keys, directory } => self.export(&keys, &directory),
            ShellOperation::AppleEditOpen { asset, directory } => self.open(&asset, &directory),
            ShellOperation::ConfirmPasteEdits { prompt } => {
                self.operations.push("confirm");
                assert_eq!(prompt.names.len(), 3);
                assert_eq!(prompt.source_name, "非公開の写真");
                self.confirmed = true;
                Ok(json!(!matches!(self.fault, Fault::Cancel)))
            }
            ShellOperation::AppleEditSave { asset, plan, .. } => {
                // The native write must be preceded by a durable intent for this exact key.
                assert!(
                    self.persisted
                        .last()
                        .is_some_and(|s| s.pending_edit_pastes.iter().any(|p| p.key == asset.key))
                );
                self.operations.push("save");
                self.writes.push(asset.key.clone());
                let fresh = self
                    .current
                    .get_mut(&asset.key)
                    .ok_or("missing save asset")?;
                fresh.revision = "edited".into();
                fresh.modified_at = Some(20.0);
                self.adjustments
                    .insert(asset.key.clone(), plan.adjustment.clone());
                if matches!(self.fault, Fault::SecondSaveLost) && self.writes.len() == 2 {
                    return Err("lost native response".into());
                }
                let mut image = Self::facts(plan.transform.output_size(plan.dimensions)?);
                if matches!(self.fault, Fault::WrongResult) {
                    image.hdr = true;
                }
                serde_json::to_value(AppleEditResult {
                    asset: fresh.clone(),
                    adjustment: plan.adjustment,
                    image,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::AppleEditInspect { asset } => {
                self.operations.push("inspect");
                serde_json::to_value(AppleEditResult {
                    asset,
                    adjustment: self
                        .adjustments
                        .get(&key(1))
                        .cloned()
                        .ok_or("missing adjustment")?,
                    image: Self::facts(dimensions()),
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::Persist(state) => {
                self.operations.push("persist");
                if matches!(self.fault, Fault::Journal) && !state.pending_edit_pastes.is_empty()
                    || matches!(self.fault, Fault::CompletionPersist)
                        && !self.writes.is_empty()
                        && state.pending_edit_pastes.is_empty()
                {
                    return Err("disk response lost".into());
                }
                self.persisted.push(state);
                Ok(Value::Null)
            }
            _ => Err("unexpected paste effect".into()),
        }
    }
    fn export(&mut self, keys: &[AssetKey], directory: &str) -> Result<Value, String> {
        self.operations.push("export");
        let [key] = keys else {
            return Err("expected one asset".into());
        };
        let asset = self.current.get(key).cloned().ok_or("missing asset")?;
        let mut result = TransferBundle {
            files: asset
                .originals()
                .map(|r| TransferFile {
                    resource: r.clone(),
                    path: format!("{directory}/{}", r.name),
                    signature: FileSignature {
                        sha256: "b".repeat(64),
                        bytes: 12,
                    },
                })
                .collect(),
            assets: vec![asset],
        };
        if matches!(self.fault, Fault::OriginalChanged) && !self.writes.is_empty() {
            result.files[0].signature.sha256 = "c".repeat(64);
        }
        serde_json::to_value(result).map_err(|e| e.to_string())
    }
    fn open(&mut self, expected: &StoredAsset, directory: &str) -> Result<Value, String> {
        self.operations.push("open");
        let mut asset = self
            .current
            .get(&expected.key)
            .cloned()
            .ok_or("missing asset")?;
        if matches!(self.fault, Fault::StaleAfterConfirmation) && self.confirmed {
            asset.revision = "concurrent edit".into();
        }
        let adjustment = self.adjustments.get(&expected.key).cloned();
        let has_adjustments = adjustment.is_some()
            || matches!(self.fault, Fault::ForeignPreflight) && expected.key == key(2);
        serde_json::to_value(AppleEditInput {
            asset,
            token: ID.into(),
            path: format!("{directory}/input.jpg"),
            image: Self::facts(dimensions()),
            can_edit: true,
            has_adjustments,
            adjustment,
            supported_formats: vec!["public.jpeg".into()],
            default_format: None,
        })
        .map_err(|e| e.to_string())
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut requests = core.process_event(event);
        let mut steps = 0;
        while !requests.is_empty() {
            steps += 1;
            assert!(steps < 120);
            let Effect::Io(mut request) = requests.remove(0);
            let native_write = matches!(request.operation, ShellOperation::AppleEditSave { .. });
            let response = match self.handle(request.operation.clone()) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            if native_write && self.observe_changes {
                assert!(core.process_event(Event::AppleChanged).is_empty());
            }
            requests.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        Ok(())
    }
    fn paste(&mut self, core: &Core<Suwop>) -> Result<(), String> {
        self.run(
            core,
            Event::PastePhotoEdits {
                keys: (0..3).map(key).collect(),
                id: ID.into(),
            },
        )
    }
}

#[test]
fn batch_preflight_confirm_journal_save_and_verify_every_original() -> Result<(), String> {
    let core = core(state()?);
    let mut native = Native::new(Fault::None);
    native.paste(&core)?;
    let view = core.view();
    assert!(view.error.is_none(), "{:?}", view.error);
    assert!(view.state.pending_edit_pastes.is_empty());
    assert_eq!(native.writes, (0..3).map(key).collect::<Vec<_>>());
    let confirmed = native
        .operations
        .iter()
        .position(|op| *op == "confirm")
        .ok_or("no confirmation")?;
    assert_eq!(
        native.operations[..confirmed]
            .iter()
            .filter(|op| **op == "open")
            .count(),
        3
    );
    assert!(native.operations.last() == Some(&"cleanup"));
    assert!(
        view.state.snapshots[0]
            .assets
            .iter()
            .all(|a| a.revision == "edited" && a.captured_at == Some(10.0))
    );
    assert!(view.state.receipts.is_empty());
    Ok(())
}

#[test]
fn cancelled_unsupported_or_changed_selection_never_writes() -> Result<(), String> {
    for fault in [
        Fault::Cancel,
        Fault::ForeignPreflight,
        Fault::StaleAfterConfirmation,
        Fault::Close,
    ] {
        let core = core(state()?);
        let mut native = Native::new(fault);
        native.paste(&core)?;
        assert!(native.writes.is_empty());
        assert!(core.view().state.pending_edit_pastes.is_empty());
        if matches!(fault, Fault::Close) {
            assert!(!native.operations.contains(&"cleanup"));
        }
    }
    Ok(())
}

#[test]
fn failed_journal_or_readback_keeps_fence_and_stops_remaining_targets() -> Result<(), String> {
    for fault in [
        Fault::Journal,
        Fault::WrongResult,
        Fault::OriginalChanged,
        Fault::CompletionPersist,
    ] {
        let core = core(state()?);
        let mut native = Native::new(fault);
        native.paste(&core)?;
        assert!(core.view().error.is_some());
        assert_eq!(core.view().state.pending_edit_pastes.len(), 1);
        assert_eq!(
            native.writes.len(),
            usize::from(!matches!(fault, Fault::Journal))
        );
        let restarted = if matches!(fault, Fault::Journal) {
            let initial = self::core(state()?);
            assert!(initial.view().state.pending_edit_pastes.is_empty());
            initial
        } else {
            core::clone_core(&native)?
        };
        let count = native.writes.len();
        native.paste(&restarted)?;
        assert_eq!(native.writes.len(), count);
        assert!(!native.operations.contains(&"inspect"));
    }
    Ok(())
}

mod core {
    pub(super) fn clone_core(
        native: &super::Native,
    ) -> Result<crux_core::Core<suwop_core::app::Suwop>, String> {
        let canonical = match native.persisted.last() {
            Some(saved) => saved.clone(),
            None => super::state()?,
        };
        Ok(super::core(canonical))
    }
}

#[test]
fn partial_success_survives_restart_and_read_only_reconciliation_never_resends()
-> Result<(), String> {
    let core = core(state()?);
    let mut native = Native::new(Fault::SecondSaveLost);
    native.paste(&core)?;
    let view = core.view();
    assert_eq!(native.writes, vec![key(0), key(1)]);
    assert_eq!(view.state.pending_edit_pastes.len(), 1);
    assert_eq!(view.state.pending_edit_pastes[0].key, key(1));
    assert!(
        view.error
            .as_ref()
            .is_some_and(|e| e.contains("1枚の保存を確認"))
    );
    assert!(
        view.state.pending_edit_pastes[0]
            .before
            .files
            .iter()
            .all(|f| f.path.is_empty())
    );
    let restarted = native.refreshed_core(&core)?;
    native.fault = Fault::None;
    native.run(
        &restarted,
        Event::ResolveEditPaste {
            key: key(1),
            id: ID.into(),
        },
    )?;
    assert!(
        restarted.view().error.is_none(),
        "{:?}",
        restarted.view().error
    );
    assert!(restarted.view().state.pending_edit_pastes.is_empty());
    assert_eq!(native.writes.len(), 2);
    assert!(native.operations.contains(&"inspect"));
    Ok(())
}

#[test]
fn failed_pre_submit_save_can_be_resolved_in_memory_after_a_fresh_scan() -> Result<(), String> {
    let core = core(state()?);
    let mut native = Native::new(Fault::Journal);
    native.paste(&core)?;
    assert!(
        native.persisted.is_empty(),
        "A failed pre-submit save is not a durable journal"
    );
    assert_eq!(core.view().state.pending_edit_pastes.len(), 1);
    native.fault = Fault::None;
    native.run(
        &core,
        Event::Refresh {
            permission: false,
            now: 1.0,
        },
    )?;
    assert_eq!(core.view().state.snapshots[0].access, ScanAccess::Full);
    native.run(
        &core,
        Event::ResolveEditPaste {
            key: key(0),
            id: ID.into(),
        },
    )?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(core.view().state.pending_edit_pastes.is_empty());
    assert!(native.writes.is_empty());
    assert!(!native.operations.contains(&"inspect"));
    Ok(())
}

#[test]
fn copy_saved_edit_is_read_only_and_persisted_across_restart() -> Result<(), String> {
    let core = core(state()?);
    let mut native = Native::new(Fault::None);
    let copied = clipboard()?;
    native.adjustments.insert(
        key(0),
        GeometryAdjustment {
            dimensions: copied.dimensions,
            base: AdjustmentBase::Original,
            transform: copied.transform,
        }
        .encode()?,
    );
    native.run(
        &core,
        Event::CopyPhotoEdits {
            key: key(0),
            options: copied.options,
            id: ID.into(),
        },
    )?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert_eq!(
        core.view()
            .state
            .edit_clipboard
            .as_ref()
            .ok_or("missing clipboard")?
            .transform
            .color
            .exposure,
        120
    );
    assert_eq!(core.view().state.snapshots[0].assets[0].revision, "before");
    assert!(native.writes.is_empty());
    let reloaded: SavedLibrary =
        serde_json::from_value(serde_json::to_value(core.view().state).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    assert_eq!(
        reloaded.edit_clipboard.ok_or("clipboard lost")?.source_name,
        "photo-0.jpg"
    );
    Ok(())
}

#[test]
fn reconciliation_rejects_changed_originals_and_other_edit_without_resending() -> Result<(), String>
{
    let core = core(state()?);
    let mut native = Native::new(Fault::SecondSaveLost);
    native.paste(&core)?;
    for changed_original in [true, false] {
        let restarted = native.refreshed_core(&core)?;
        if changed_original {
            native.fault = Fault::OriginalChanged;
        } else {
            native.fault = Fault::None;
            let other = GeometryAdjustment {
                dimensions: dimensions(),
                base: AdjustmentBase::Original,
                transform: ImageTransform::original(dimensions())?,
            }
            .encode()?;
            native.adjustments.insert(key(1), other);
        }
        native.run(
            &restarted,
            Event::ResolveEditPaste {
                key: key(1),
                id: ID.into(),
            },
        )?;
        assert!(restarted.view().error.is_some());
        assert_eq!(restarted.view().state.pending_edit_pastes.len(), 1);
        assert_eq!(native.writes.len(), 2);
    }
    Ok(())
}

#[test]
fn selection_never_ignores_remote_only_photos_and_noop_batch_never_confirms() -> Result<(), String>
{
    let mut saved = state()?;
    let mut remote = asset(4);
    remote.key.provider = Provider::Immich;
    remote.key.scope = "other".into();
    let remote_key = remote.key.clone();
    saved.snapshots.push(LibrarySnapshot {
        provider: Provider::Immich,
        scope: "other".into(),
        assets: vec![remote],
        access: ScanAccess::Full,
        scanned_at: None,
    });
    let core = core(saved);
    let mut native = Native::new(Fault::None);
    native.run(
        &core,
        Event::PasteSelectedPhotoEdits {
            anchors: vec![key(0), remote_key],
            id: ID.into(),
        },
    )?;
    assert!(core.view().error.is_some());
    assert!(native.operations.is_empty());
    let copied = clipboard()?;
    for index in 0..3 {
        native.adjustments.insert(
            key(index),
            GeometryAdjustment {
                dimensions: copied.dimensions,
                base: AdjustmentBase::Original,
                transform: copied.transform,
            }
            .encode()?,
        );
    }
    native.paste(&core)?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(native.writes.is_empty());
    assert!(!native.operations.contains(&"confirm"));
    assert!(core.view().state.pending_edit_pastes.is_empty());
    Ok(())
}

#[test]
fn native_change_observations_do_not_stop_the_remaining_visible_paste_targets() -> Result<(), String>
{
    let core = core(state()?);
    let mut native = Native::new(Fault::None);
    native.observe_changes = true;
    native.paste(&core)?;
    assert_eq!(native.writes, vec![key(0), key(1), key(2)]);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(core.view().state.pending_edit_pastes.is_empty());
    Ok(())
}

#[test]
fn hidden_or_legacy_clipboard_keeps_the_recipe_but_redacts_confirmation_source_name()
-> Result<(), String> {
    for source_key in [
        None,
        Some(AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "hidden-source".into(),
        }),
    ] {
        let mut saved = state()?;
        let mut copied = clipboard()?;
        copied.source_name = "PRIVATE-clipboard.jpg".into();
        copied.source_key = source_key;
        saved.edit_clipboard = Some(copied);
        let core = core(saved);
        let mut native = Native::new(Fault::Cancel);
        native.paste(&core)?;
        assert!(
            native.confirmed,
            "Recipe must still reach the visible targets' confirmation"
        );
        assert!(native.writes.is_empty());
        assert_eq!(
            core.view()
                .state
                .edit_clipboard
                .ok_or("recipe lost")?
                .source_name,
            "非公開の写真"
        );
    }
    Ok(())
}
