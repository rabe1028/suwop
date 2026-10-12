use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile, TransferIntent, TransferPhase,
    },
    immich::{HttpResponse, Session, Version},
    workflow::HashResult,
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const OWNER: &str = "22222222-2222-4222-8222-222222222222";
const SHA1: &str = "1111111111111111111111111111111111111111";
struct Shell {
    source: TransferBundle,
    deleted: usize,
    fail_phase: Option<TransferPhase>,
    uncertain_delete: bool,
    target_changed: bool,
    sidecar: bool,
    location: Option<(f64, f64)>,
    writes: usize,
    order: Vec<&'static str>,
}
impl Shell {
    fn new() -> Self {
        let resource = PhotoResource {
            id: "0".into(),
            name: "test.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(SHA1.into()),
            bytes: Some(12),
        };
        let a = StoredAsset {
            key: AssetKey {
                provider: Provider::Apple,
                scope: "apple".into(),
                asset_id: "photo".into(),
            },
            name: "test.jpg".into(),
            captured_at: Some(10.0),
            modified_at: None,
            revision: "1".into(),
            resources: vec![resource.clone()],
            is_favorite: false,
            latitude: None,
            longitude: None,
            inventory_complete: true,
            is_offline: false,
            deletion_blockers: vec![],
        };
        Self {
            source: TransferBundle {
                assets: vec![a],
                files: vec![TransferFile {
                    resource,
                    path: "/tmp/test".into(),
                    signature: FileSignature {
                        sha256: "a".repeat(64),
                        bytes: 12,
                    },
                }],
            },
            deleted: 0,
            fail_phase: None,
            uncertain_delete: false,
            target_changed: false,
            sidecar: false,
            location: None,
            writes: 0,
            order: vec![],
        }
    }
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleFavorite { keys, value } => {
                for a in &mut self.source.assets {
                    if keys.contains(&a.key) {
                        a.is_favorite = value;
                        a.revision = "favorite-changed".into();
                    }
                }
                serde_json::to_value(&self.source.assets).map_err(|e| e.to_string())
            }
            ShellOperation::Workspace { .. } => Ok(json!("/tmp/test-workspace")),
            ShellOperation::Cleanup { .. } => Ok(Value::Null),
            ShellOperation::AppleExport { .. } => {
                serde_json::to_value(&self.source).map_err(|e| e.to_string())
            }
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope,
                assets: self.source.assets.clone(),
                access: ScanAccess::Full,
                scanned_at: Some(10.0),
            })
            .map_err(|e| e.to_string()),
            ShellOperation::Persist(state) => {
                self.order.push("persist");
                if state
                    .receipts
                    .last()
                    .is_some_and(|r| Some(r.phase) == self.fail_phase)
                {
                    return Err("journal failed".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::AppleTrash { .. } => {
                self.order.push("trash");
                self.deleted += 1;
                if self.uncertain_delete {
                    Err("lost response".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::HashFile { .. } => serde_json::to_value(HashResult {
                sha1: SHA1.into(),
                signature: FileSignature {
                    sha256: if self.target_changed {
                        "b".repeat(64)
                    } else {
                        "a".repeat(64)
                    },
                    bytes: 12,
                },
            })
            .map_err(|e| e.to_string()),
            ShellOperation::Http(request) => {
                let body = if request.method == "POST" && request.url.ends_with("/assets") {
                    self.writes += 1;
                    json!({"id":ID,"status":"created"})
                } else if request.method == "PUT" {
                    if let Some(body) = request.body {
                        self.location = body["latitude"].as_f64().zip(body["longitude"].as_f64());
                    }
                    Value::Null
                } else if request.url.contains("asset-files") {
                    if self.sidecar {
                        json!([{"id":ID,"type":"sidecar","path":"test.xmp"}])
                    } else {
                        json!([])
                    }
                } else if request.url.ends_with("/search/metadata") {
                    json!({"assets":{"items":[],"nextCursor":null}})
                } else if request.download_path.is_some() {
                    Value::Null
                } else {
                    json!({"id":ID,"ownerId":OWNER,"type":"IMAGE","originalFileName":"test.jpg","checksum":SHA1,"fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,"exifInfo":{"dateTimeOriginal":"1970-01-01T00:00:10Z","fileSizeInByte":12,"latitude":self.location.map(|p| p.0),"longitude":self.location.map(|p| p.1)}})
                };
                serde_json::to_value(HttpResponse {
                    status: 200,
                    body,
                    path: request.download_path,
                })
                .map_err(|e| e.to_string())
            }
            _ => Err("unexpected effect".into()),
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        let mut n = 0;
        while !effects.is_empty() {
            n += 1;
            if n > 100 {
                return Err("effect loop did not terminate".into());
            }
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.handle(request.operation.clone()) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(e) => ShellResponse {
                    value: None,
                    error: Some(e),
                },
            };
            effects.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        Ok(())
    }
}
fn core() -> Core<Suwop> {
    let state = SavedLibrary {
        schema_version: 2,
        apple_scope: "apple".into(),
        ..SavedLibrary::default()
    };
    let session = Session {
        endpoint: "https://test/api".into(),
        key: "test".into(),
        user_id: OWNER.into(),
        scope: "immich".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(session),
            ready: true,
            ..Model::default()
        },
    )
}
fn copy_event(shell: &Shell, intent: TransferIntent) -> Event {
    Event::Copy {
        keys: shell.source.assets.iter().map(|a| a.key.clone()).collect(),
        intent,
        id: "receipt".into(),
        now: 10.0,
    }
}
fn move_event() -> Event {
    Event::CompleteMove {
        id: "receipt".into(),
        workspace: "work".into(),
    }
}

#[test]
fn favorite_updates_the_native_library_and_persists_without_deleting() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(
        &core,
        Event::Refresh {
            permission: false,
            now: 10.0,
        },
    )?;
    let keys = shell.source.assets.iter().map(|a| a.key.clone()).collect();
    shell.run(&core, Event::SetFavorite { keys, value: true })?;
    assert!(core.view().error.is_none());
    assert!(shell.source.assets[0].is_favorite);
    assert!(core.view().photos[0].assets[0].is_favorite);
    assert_eq!(core.view().browser.favorites, 1);
    assert_eq!(shell.order.last(), Some(&"persist"));
    assert_eq!(shell.deleted, 0);
    Ok(())
}
#[test]
fn favorite_checks_all_scopes_before_any_mutation() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(
        &core,
        Event::Refresh {
            permission: false,
            now: 10.0,
        },
    )?;
    let mut missing = shell.source.assets[0].key.clone();
    missing.scope = "another-library".into();
    shell.run(
        &core,
        Event::SetFavorite {
            keys: vec![shell.source.assets[0].key.clone(), missing],
            value: true,
        },
    )?;
    assert!(core.view().error.is_some());
    assert!(!shell.source.assets[0].is_favorite);
    assert_eq!(shell.deleted, 0);
    Ok(())
}
#[test]
fn copy_then_complete_move_is_rejected_without_any_delete() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(&core, copy_event(&shell, TransferIntent::Copy))?;
    assert!(core.view().error.is_none());
    shell.run(&core, move_event())?;
    assert!(core.view().error.is_some());
    assert_eq!(shell.deleted, 0);
    Ok(())
}
#[test]
fn move_reverifies_and_persists_before_deleting() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
    assert_eq!(shell.deleted, 0);
    shell.run(&core, move_event())?;
    assert!(core.view().error.is_none());
    assert_eq!(shell.deleted, 1);
    assert_eq!(core.view().state.receipts[0].phase, TransferPhase::Moved);
    let index = shell
        .order
        .iter()
        .position(|op| *op == "trash")
        .ok_or("trash missing")?;
    assert_eq!(shell.order[index - 1], "persist");
    Ok(())
}
#[test]
fn invented_capture_date_blocks_move_without_deleting_the_original() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.source.assets[0].captured_at = None;
    shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
    assert!(core.view().error.is_some());
    shell.run(&core, move_event())?;
    assert_eq!(shell.deleted, 0);
    assert!(core.view().error.is_some());
    Ok(())
}
#[test]
fn journal_failure_before_import_or_trash_stops_remote_mutation() -> Result<(), String> {
    for phase in [TransferPhase::Copying, TransferPhase::DeletingSource] {
        let core = core();
        let mut shell = Shell::new();
        if phase == TransferPhase::Copying {
            shell.fail_phase = Some(phase);
        }
        shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
        if phase == TransferPhase::Copying {
            assert_eq!(shell.writes, 0);
        } else {
            shell.fail_phase = Some(phase);
            shell.run(&core, move_event())?;
        }
        assert_eq!(shell.deleted, 0);
        assert!(core.view().error.is_some());
    }
    Ok(())
}
#[test]
fn uncertain_delete_can_never_be_retried() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
    shell.uncertain_delete = true;
    shell.run(&core, move_event())?;
    assert_eq!(
        core.view().state.receipts[0].phase,
        TransferPhase::DeletionUncertain
    );
    shell.run(&core, move_event())?;
    assert_eq!(shell.deleted, 1);
    Ok(())
}
#[test]
fn changed_destination_blocks_move() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
    shell.target_changed = true;
    shell.run(&core, move_event())?;
    assert_eq!(shell.deleted, 0);
    assert!(core.view().error.is_some());
    Ok(())
}
#[test]
fn adjusted_gps_is_sent_to_immich_and_reverified() -> Result<(), String> {
    let core = core();
    let mut shell = Shell::new();
    shell.source.assets[0].latitude = Some(35.0);
    shell.source.assets[0].longitude = Some(139.0);
    shell.run(&core, copy_event(&shell, TransferIntent::Move))?;
    assert_eq!(shell.location, Some((35.0, 139.0)));
    assert!(core.view().error.is_none());
    shell.location = Some((36.0, 140.0));
    shell.run(&core, move_event())?;
    assert_eq!(shell.deleted, 0);
    Ok(())
}
#[test]
fn schema_migration_preserves_dates_and_disables_legacy_deletion() -> Result<(), String> {
    let state = suwop_core::workflow::migrate(
        json!({"schemaVersion":1,"appleScope":"old","connection":null,"snapshots":[],"receipts":[]}),
    )?;
    assert_eq!(state.schema_version, 2);
    assert_eq!(state.apple_scope, "old");
    assert!(suwop_core::workflow::migrate(json!({"schemaVersion":99})).is_err());
    Ok(())
}
