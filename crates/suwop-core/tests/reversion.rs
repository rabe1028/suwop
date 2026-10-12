use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    editing::AppleReversionFacts,
};

fn asset() -> StoredAsset {
    StoredAsset {
        key: AssetKey {
            provider: Provider::Apple,
            scope: "library".into(),
            asset_id: "photo".into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.125),
        modified_at: Some(20.0),
        revision: "edited".into(),
        is_favorite: true,
        latitude: Some(0.0),
        longitude: Some(1.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
        resources: vec![
            PhotoResource {
                id: "image".into(),
                name: "photo.jpg".into(),
                role: ResourceRole::Image,
                sha1: Some("a".repeat(40)),
                bytes: Some(12),
            },
            PhotoResource {
                id: "raw".into(),
                name: "photo.dng".into(),
                role: ResourceRole::RawImage,
                sha1: Some("d".repeat(40)),
                bytes: Some(12),
            },
            PhotoResource {
                id: "adjustment".into(),
                name: "foreign-edit.bin".into(),
                role: ResourceRole::Auxiliary,
                sha1: None,
                bytes: None,
            },
        ],
    }
}

fn state() -> SavedLibrary {
    let mut remote = asset();
    remote.key.provider = Provider::Immich;
    remote.key.scope = "remote".into();
    SavedLibrary {
        schema_version: 2,
        apple_scope: "library".into(),
        snapshots: vec![
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "library".into(),
                assets: vec![asset()],
                access: ScanAccess::Full,
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
fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            preview_preferences: vec![state.snapshots[1].assets[0].key.clone()],
            state,
            ..Model::default()
        },
    )
}
fn bundle(current: &StoredAsset, directory: &str) -> TransferBundle {
    TransferBundle {
        assets: vec![current.clone()],
        files: current
            .originals()
            .map(|r| TransferFile {
                resource: r.clone(),
                path: format!("{directory}/{}", r.name),
                signature: FileSignature {
                    sha256: (if r.role == ResourceRole::RawImage {
                        "e"
                    } else {
                        "b"
                    })
                    .repeat(64),
                    bytes: 12,
                },
            })
            .collect(),
    }
}
#[derive(Clone, Copy)]
enum Fault {
    None,
    Cancel,
    LostConfirmation,
    NoEdits,
    CannotEdit,
    StaleInspection,
    StaleExport,
    LostRevert,
    ResidualEdits,
    ChangedBytes,
    MissingOriginal,
    ChangedMetadata,
    WrongKey,
    Persist,
    Cleanup,
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
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleReversionInspect { asset } => {
                assert_eq!(asset.key, self.current.key);
                self.operations.push("inspect");
                let mut facts = self.facts();
                facts.has_adjustments = !matches!(self.fault, Fault::NoEdits);
                facts.can_edit = !matches!(self.fault, Fault::CannotEdit);
                if matches!(self.fault, Fault::StaleInspection) {
                    facts.asset.revision = "concurrent edit".into();
                }
                serde_json::to_value(facts).map_err(|e| e.to_string())
            }
            ShellOperation::ConfirmReversion { prompt } => {
                assert_eq!(prompt.key, self.current.key);
                assert_eq!(prompt.name, self.current.name);
                self.operations.push("confirm");
                if matches!(self.fault, Fault::LostConfirmation) {
                    return Err("confirmation cancelled while waiting".into());
                }
                Ok(json!(!matches!(self.fault, Fault::Cancel)))
            }
            ShellOperation::Workspace { .. } => {
                self.operations.push("workspace");
                Ok(json!("/tmp/reversion"))
            }
            ShellOperation::AppleExport { keys, directory } => {
                assert_eq!(keys, vec![asset().key]);
                self.export(&directory)
            }
            ShellOperation::AppleRevert { asset } => {
                assert_eq!(asset.key, self.current.key);
                assert_eq!(asset.revision, "edited");
                self.operations.push("revert");
                self.writes += 1;
                self.current.revision = "original again".into();
                self.current.modified_at = Some(30.0);
                self.current.resources.retain(|r| r.role.is_original());
                if matches!(self.fault, Fault::LostRevert) {
                    return Err("lost native response".into());
                }
                let mut facts = self.facts();
                facts.has_adjustments = matches!(self.fault, Fault::ResidualEdits);
                if matches!(self.fault, Fault::WrongKey) {
                    facts.asset.key.asset_id = "other".into();
                }
                serde_json::to_value(facts).map_err(|e| e.to_string())
            }
            ShellOperation::Persist(_) => {
                self.operations.push("persist");
                if matches!(self.fault, Fault::Persist) {
                    return Err("persistence failed".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::Cleanup { path } => {
                assert_eq!(path, "/tmp/reversion");
                self.operations.push("cleanup");
                if matches!(self.fault, Fault::Cleanup) {
                    return Err("cleanup failed".into());
                }
                Ok(Value::Null)
            }
            _ => Err("unexpected effect: reversion must not trash, retry or write Immich".into()),
        }
    }
    fn facts(&self) -> AppleReversionFacts {
        AppleReversionFacts {
            asset: self.current.clone(),
            can_edit: true,
            has_adjustments: self.writes == 0,
        }
    }
    fn export(&mut self, directory: &str) -> Result<Value, String> {
        self.operations.push("export");
        let mut result = bundle(&self.current, directory);
        if self.writes == 0 && matches!(self.fault, Fault::StaleExport) {
            result.assets[0].revision = "edit after consent".into();
        }
        if self.writes > 0 {
            match self.fault {
                Fault::ChangedBytes => result.files[0].signature.sha256 = "c".repeat(64),
                Fault::ChangedMetadata => result.assets[0].latitude = None,
                Fault::MissingOriginal => {
                    result.assets[0]
                        .resources
                        .retain(|r| r.role != ResourceRole::RawImage);
                    result
                        .files
                        .retain(|f| f.resource.role != ResourceRole::RawImage);
                }
                _ => {}
            }
        }
        serde_json::to_value(result).map_err(|e| e.to_string())
    }
    fn run(&mut self, core: &Core<Suwop>) -> Result<(), String> {
        let mut requests = core.process_event(Event::RevertImage {
            key: asset().key,
            id: "11111111-1111-4111-8111-111111111111".into(),
        });
        let mut steps = 0;
        while !requests.is_empty() {
            steps += 1;
            assert!(steps < 30);
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
fn explicit_reversion_discards_foreign_edits_but_preserves_raw_jpeg_and_metadata()
-> Result<(), String> {
    let initial = state();
    let remote = initial.snapshots[1].clone();
    let core = core(initial);
    let mut native = Native::new(Fault::None);
    native.run(&core)?;
    let view = core.view();
    assert!(view.error.is_none());
    assert_eq!(native.writes, 1);
    assert_eq!(
        native.operations,
        [
            "inspect",
            "confirm",
            "workspace",
            "export",
            "revert",
            "export",
            "persist",
            "cleanup"
        ]
    );
    let saved = &view.state.snapshots[0].assets[0];
    assert_eq!(saved.revision, "original again");
    assert_eq!(saved.originals().count(), 2);
    assert_eq!(
        (
            saved.captured_at,
            saved.is_favorite,
            saved.latitude,
            saved.longitude
        ),
        (Some(10.125), true, Some(0.0), Some(1.0))
    );
    assert!(saved.fingerprints_complete());
    assert_eq!(
        serde_json::to_value(&view.state.snapshots[1]).map_err(|e| e.to_string())?,
        serde_json::to_value(remote).map_err(|e| e.to_string())?
    );
    assert!(view.state.receipts.is_empty());
    assert_eq!(view.preview_sources.values().next(), Some(&asset().key));
    Ok(())
}

#[test]
fn declining_or_cancelling_confirmation_does_not_download_or_write() -> Result<(), String> {
    for fault in [Fault::Cancel, Fault::LostConfirmation] {
        let core = core(state());
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert_eq!(native.writes, 0);
        assert_eq!(native.operations, ["inspect", "confirm"]);
        assert_eq!(core.view().error.is_none(), matches!(fault, Fault::Cancel));
        assert_eq!(core.view().state.snapshots[0].access, ScanAccess::Full);
    }
    Ok(())
}

#[test]
fn unavailable_or_changed_native_edits_stop_before_consent_or_write() -> Result<(), String> {
    for fault in [
        Fault::NoEdits,
        Fault::CannotEdit,
        Fault::StaleInspection,
        Fault::StaleExport,
    ] {
        let core = core(state());
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 0);
        assert_eq!(core.view().state.snapshots[0].access, ScanAccess::Full);
        assert!(core.view().status.contains("写真は変更していません"));
        if matches!(fault, Fault::StaleExport) {
            assert_eq!(
                native.operations,
                ["inspect", "confirm", "workspace", "export", "cleanup"]
            );
        } else {
            assert_eq!(native.operations, ["inspect"]);
        }
    }
    Ok(())
}

#[test]
fn unknown_reversions_and_failed_integrity_checks_disable_writes_without_retrying()
-> Result<(), String> {
    for fault in [
        Fault::LostRevert,
        Fault::ResidualEdits,
        Fault::WrongKey,
        Fault::ChangedBytes,
        Fault::MissingOriginal,
        Fault::ChangedMetadata,
        Fault::Persist,
    ] {
        let core = core(state());
        let mut native = Native::new(fault);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert_eq!(
            core.view().state.snapshots[0].access,
            ScanAccess::Unavailable
        );
        assert_eq!(native.operations.last(), Some(&"cleanup"));
        native.run(&core)?;
        assert_eq!(native.writes, 1);
    }
    Ok(())
}

#[test]
fn cleanup_errors_remain_visible_after_a_verified_reversion() -> Result<(), String> {
    let core = core(state());
    let mut native = Native::new(Fault::Cleanup);
    native.run(&core)?;
    assert!(core.view().error.is_some());
    assert_eq!(
        core.view().state.snapshots[0].assets[0].revision,
        "original again"
    );
    assert_eq!(
        core.view().preview_sources.values().next(),
        Some(&asset().key)
    );
    Ok(())
}

#[test]
fn stale_scopes_limited_access_duplicate_inventories_and_video_never_request_native_writes()
-> Result<(), String> {
    let mut states = Vec::new();
    for access in [ScanAccess::Limited, ScanAccess::Unavailable] {
        let mut unavailable = state();
        unavailable.snapshots[0].access = access;
        states.push(unavailable);
    }
    let mut stale = state();
    stale.apple_scope = "other library".into();
    states.push(stale);
    let mut duplicate = state();
    duplicate.snapshots[0].assets.push(asset());
    states.push(duplicate);
    let mut duplicate = state();
    duplicate.snapshots.push(duplicate.snapshots[0].clone());
    states.push(duplicate);
    for role in [ResourceRole::Video, ResourceRole::LiveVideo] {
        let mut video = state();
        video.snapshots[0].assets[0].resources.push(PhotoResource {
            id: "video".into(),
            name: "paired.mov".into(),
            role,
            sha1: Some("f".repeat(40)),
            bytes: Some(12),
        });
        states.push(video);
    }
    for state in states {
        let core = core(state);
        let mut native = Native::new(Fault::None);
        native.run(&core)?;
        assert!(core.view().error.is_some());
        assert!(native.operations.is_empty());
    }
    Ok(())
}
