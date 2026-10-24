use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    editing::{
        AppleEditInput, AppleEditResult, EditCommand, EditCommandKind, ImageEncodingFacts,
        PixelSize, verify_edited_originals,
    },
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
fn changed_draft(
    draft: &suwop_core::editing::ImageEditDraft,
) -> Result<suwop_core::editing::ImageEditDraft, String> {
    draft
        .apply(EditCommand {
            kind: EditCommandKind::RotateClockwise,
            crop: None,
            color: None,
        })?
        .apply(EditCommand {
            kind: EditCommandKind::SetColor,
            crop: None,
            color: Some(suwop_core::editing::ColorAdjustments {
                brightness: 10,
                saturation: -25,
                filter: suwop_core::editing::ImageColorFilter::Sepia,
                ..suwop_core::editing::ColorAdjustments::default()
            }),
        })
}

fn asset() -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: ID.into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.0),
        modified_at: Some(10.0),
        revision: "before".into(),
        is_favorite: true,
        latitude: Some(1.0),
        longitude: Some(2.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
        resources: vec![PhotoResource {
            id: "0".into(),
            name: "photo.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some("a".repeat(40)),
            bytes: Some(12),
        }],
    }
}
fn bundle(asset: StoredAsset, directory: &str) -> TransferBundle {
    TransferBundle {
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
    }
}
fn fixture_state(access: ScanAccess, scope: &str) -> SavedLibrary {
    let mut remote = asset();
    remote.key.provider = Provider::Immich;
    remote.key.scope = "remote".into();
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: scope.into(),
        snapshots: vec![
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "apple".into(),
                assets: vec![asset()],
                access,
                scanned_at: None,
            },
            LibrarySnapshot {
                provider: Provider::Immich,
                scope: "remote".into(),
                assets: vec![remote],
                access: ScanAccess::Full,
                scanned_at: None,
            },
        ],
        ..SavedLibrary::default()
    }
}
fn core(access: ScanAccess, scope: &str) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: fixture_state(access, scope),
            ..Model::default()
        },
    )
}
#[derive(Clone, Copy)]
enum Fault {
    None,
    Cancel,
    BadDraft,
    BadInput,
    Stale,
    LostSave,
    WrongAdjustment,
    WrongSize,
    ChangedOriginal,
    Persist,
    Cleanup,
    Close,
}
struct Native {
    current: StoredAsset,
    fault: Fault,
    operations: Vec<&'static str>,
    writes: usize,
}
impl Native {
    fn new(fault: Fault) -> Self {
        Self {
            current: asset(),
            fault,
            operations: vec![],
            writes: 0,
        }
    }
    fn facts() -> ImageEncodingFacts {
        ImageEncodingFacts {
            raw_dimensions: PixelSize {
                width: 6,
                height: 4,
            },
            orientation: 1,
            has_color_space: true,
            has_alpha: false,
            hdr: false,
        }
    }
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Workspace { .. } => {
                self.operations.push("workspace");
                Ok(json!("/tmp/editor-workspace"))
            }
            ShellOperation::AppleExport { keys, directory } => {
                assert_eq!(keys, vec![asset().key]);
                self.export(&directory)
            }
            ShellOperation::AppleEditOpen { asset, directory } => {
                self.operations.push("open");
                let mut image = Self::facts();
                if matches!(self.fault, Fault::BadInput) {
                    image.orientation = 0;
                }
                serde_json::to_value(AppleEditInput {
                    asset,
                    token: ID.into(),
                    path: format!("{directory}/input.jpg"),
                    image,
                    can_edit: true,
                    has_adjustments: false,
                    adjustment: None,
                    supported_formats: vec!["public.jpeg".into()],
                    default_format: None,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::EditImage { key, presentation } => {
                assert_eq!(key, asset().key);
                self.operations.push("editor");
                if matches!(self.fault, Fault::Cancel) {
                    return Ok(Value::Null);
                }
                let mut draft = changed_draft(&presentation.draft)?;
                if matches!(self.fault, Fault::BadDraft) {
                    draft.dimensions.width += 1;
                }
                serde_json::to_value(draft).map_err(|e| e.to_string())
            }
            ShellOperation::AppleEditSave { token, asset, plan } => {
                self.operations.push("save");
                self.writes += 1;
                assert_eq!(token, ID);
                assert_eq!(asset.key, self.current.key);
                self.current.revision = "edited".into();
                self.current.modified_at = Some(20.0);
                let mut adjustment = plan.adjustment;
                if matches!(self.fault, Fault::LostSave) {
                    return Err("lost save response".into());
                }
                if matches!(self.fault, Fault::WrongAdjustment) {
                    adjustment.format_version = "3".into();
                }
                let mut image = Self::facts();
                image.raw_dimensions = plan.transform.output_size(plan.dimensions)?;
                if matches!(self.fault, Fault::WrongSize) {
                    image.raw_dimensions.width += 1;
                }
                serde_json::to_value(AppleEditResult {
                    asset: self.current.clone(),
                    adjustment,
                    image,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::AppleEditClose { token } => {
                assert_eq!(token, ID);
                self.operations.push("close");
                if matches!(self.fault, Fault::Close) {
                    return Err("close failed".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::Cleanup { path } => {
                assert_eq!(path, "/tmp/editor-workspace");
                self.operations.push("cleanup");
                if matches!(self.fault, Fault::Cleanup) {
                    return Err("cleanup failed".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::Persist(_) => {
                self.operations.push("persist");
                if matches!(self.fault, Fault::Persist) {
                    return Err("journal failed".into());
                }
                Ok(Value::Null)
            }
            _ => Err("unexpected editing effect".into()),
        }
    }
    fn export(&mut self, directory: &str) -> Result<Value, String> {
        self.operations.push("export");
        let mut result = bundle(self.current.clone(), directory);
        if self.writes > 0 && matches!(self.fault, Fault::ChangedOriginal) {
            result.files[0].signature.sha256 = "c".repeat(64);
        }
        if self.writes == 0 && matches!(self.fault, Fault::Stale) {
            result.assets[0].revision = "another".into();
        }
        serde_json::to_value(result).map_err(|e| e.to_string())
    }
    fn run(&mut self, core: &Core<Suwop>) -> Result<(), String> {
        let mut requests = core.process_event(Event::EditImage {
            key: asset().key,
            id: ID.into(),
        });
        let mut steps = 0;
        while !requests.is_empty() {
            steps += 1;
            assert!(steps < 50);
            let Effect::Io(mut request) = requests.remove(0);
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
            requests.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        Ok(())
    }
}

#[test]
fn verified_edit_keeps_unified_originals_metadata_and_fresh_revision() -> Result<(), String> {
    let core = core(ScanAccess::Full, "apple");
    let mut native = Native::new(Fault::None);
    native.run(&core)?;
    let view = core.view();
    assert!(view.error.is_none());
    assert_eq!(view.photos.len(), 1);
    assert_eq!(view.photos[0].assets.len(), 2);
    let fresh = &view.state.snapshots[0].assets[0];
    assert_eq!(fresh.revision, "edited");
    assert!(fresh.fingerprints_complete());
    assert_eq!((fresh.captured_at, fresh.is_favorite), (Some(10.0), true));
    assert_eq!((fresh.latitude, fresh.longitude), (Some(1.0), Some(2.0)));
    assert!(view.state.receipts.is_empty());
    assert_eq!(native.writes, 1);
    assert_eq!(
        native.operations,
        [
            "workspace",
            "export",
            "open",
            "editor",
            "save",
            "export",
            "persist",
            "close",
            "cleanup"
        ]
    );
    Ok(())
}
#[test]
fn successful_edit_switches_the_preview_from_an_independent_copy_to_the_saved_one()
-> Result<(), String> {
    let mut state = fixture_state(ScanAccess::Full, "apple");
    let mut other = asset();
    other.key.asset_id = "other-copy".into();
    state.snapshots[0].assets.push(other.clone());
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            preview_preferences: vec![other.key.clone()],
            ..Model::default()
        },
    );
    assert_eq!(
        core.view().preview_sources.values().next(),
        Some(&other.key)
    );
    Native::new(Fault::None).run(&core)?;
    assert!(core.view().error.is_none());
    assert_eq!(
        core.view().preview_sources.values().next(),
        Some(&asset().key)
    );
    Ok(())
}

#[test]
fn cancellation_and_invalid_drafts_never_write_and_close_before_cleanup() -> Result<(), String> {
    for fault in [Fault::Cancel, Fault::BadDraft, Fault::BadInput] {
        let core = core(ScanAccess::Full, "apple");
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert_eq!(native.writes, 0);
        assert_eq!(
            &native.operations[native.operations.len() - 2..],
            ["close", "cleanup"]
        );
        assert_eq!(core.view().state.snapshots[0].access, ScanAccess::Full);
        assert_eq!(core.view().error.is_none(), matches!(fault, Fault::Cancel));
    }
    Ok(())
}
#[test]
fn stale_scope_access_or_revision_prevents_editing() -> Result<(), String> {
    for (access, scope) in [
        (ScanAccess::Limited, "apple"),
        (ScanAccess::Unavailable, "apple"),
        (ScanAccess::Full, "stale"),
    ] {
        let core = core(access, scope);
        let mut native = Native::new(Fault::None);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert!(native.operations.is_empty());
    }
    let core = core(ScanAccess::Full, "apple");
    let mut native = Native::new(Fault::Stale);
    native.run(&core)?;
    assert!(core.view().error.is_some());
    assert_eq!(native.operations, ["workspace", "export", "cleanup"]);
    Ok(())
}
#[test]
fn unknown_or_failed_edits_disable_writes_and_never_retry() -> Result<(), String> {
    for fault in [
        Fault::LostSave,
        Fault::WrongAdjustment,
        Fault::WrongSize,
        Fault::ChangedOriginal,
        Fault::Persist,
    ] {
        let core = core(ScanAccess::Full, "apple");
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert_eq!(
            core.view().state.snapshots[0].access,
            ScanAccess::Unavailable
        );
        assert!(core.view().state.receipts.is_empty());
        assert_eq!(
            &native.operations[native.operations.len() - 2..],
            ["close", "cleanup"]
        );
        native.run(&core)?;
        assert_eq!(native.writes, 1);
    }
    Ok(())
}
#[test]
fn editor_release_or_cleanup_failure_remains_visible() -> Result<(), String> {
    for fault in [Fault::Close, Fault::Cleanup] {
        let core = core(ScanAccess::Full, "apple");
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 1);
        assert_eq!(
            native.operations.contains(&"cleanup"),
            !matches!(fault, Fault::Close)
        );
    }
    Ok(())
}

#[test]
fn raw_jpeg_original_set_must_keep_each_role_name_hash_and_length() -> Result<(), String> {
    let mut source = asset();
    source.resources.push(PhotoResource {
        id: "1".into(),
        name: "photo.dng".into(),
        role: ResourceRole::RawImage,
        sha1: Some("d".repeat(40)),
        bytes: Some(12),
    });
    let before = bundle(source, "/before");
    let mut after = before.clone();
    after.assets[0].revision = "new".into();
    after.assets[0].resources.push(PhotoResource {
        id: "2".into(),
        name: "adjustment".into(),
        role: ResourceRole::Auxiliary,
        sha1: None,
        bytes: None,
    });
    verify_edited_originals(&before, &after)?;
    for index in 0..6 {
        let mut bad = after.clone();
        match index {
            0 => bad.files[1].signature.sha256 = "e".repeat(64),
            1 => bad.files[1].signature.bytes += 1,
            2 => bad.files[1].resource.name = "different.dng".into(),
            3 => bad.files[1].resource.role = ResourceRole::Image,
            4 => {
                bad.assets[0].resources.remove(1);
                bad.files.remove(1);
            }
            _ => bad.assets[0].latitude = Some(3.0),
        }
        assert!(verify_edited_originals(&before, &bad).is_err());
    }
    Ok(())
}
