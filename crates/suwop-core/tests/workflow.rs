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
#[derive(Clone, Copy, Default)]
enum UploadFault {
    #[default]
    None,
    Read,
    Wait,
    Expired,
    PutLostApplied,
    PutLostUnapplied,
    CreatedJournal,
    StartedJournal,
    ConfirmChanged,
    Duplicate,
    WrongIdentity,
}
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
    upload_fault: UploadFault,
    metadata_writes: usize,
    confirm: Option<bool>,
    journal: Option<SavedLibrary>,
    capture_date: String,
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
            upload_fault: UploadFault::None,
            metadata_writes: 0,
            confirm: Some(true),
            journal: None,
            capture_date: "1970-01-01T00:00:10Z".into(),
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
                if state
                    .pending_uploads
                    .iter()
                    .any(|p| match self.upload_fault {
                        UploadFault::CreatedJournal => {
                            p.phase == suwop_core::immich::UploadPhase::MetadataPending
                        }
                        UploadFault::StartedJournal => {
                            p.phase == suwop_core::immich::UploadPhase::MetadataStarted
                        }
                        _ => false,
                    })
                {
                    return Err("upload journal failed".into());
                }
                self.journal = Some(state);
                Ok(Value::Null)
            }
            ShellOperation::Wait { .. } => {
                if matches!(self.upload_fault, UploadFault::Wait) {
                    Err("cancelled".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::ConfirmUploadResume { .. } => {
                self.order.push("confirm-upload");
                if matches!(self.upload_fault, UploadFault::ConfirmChanged) {
                    self.capture_date = "1970-01-01T00:00:11Z".into();
                }
                self.confirm.map(Value::Bool).ok_or("cancelled".into())
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
            ShellOperation::Http(request) => self.http(request),
            _ => Err("unexpected effect".into()),
        }
    }
    fn http(&mut self, request: suwop_core::immich::HttpRequest) -> Result<Value, String> {
        let body = if request.method == "POST" && request.url.ends_with("/assets") {
            self.writes += 1;
            json!({"id":ID,"status":if matches!(self.upload_fault, UploadFault::Duplicate) {"duplicate"} else {"created"}})
        } else if request.method == "PUT" {
            self.metadata_writes += 1;
            if matches!(self.upload_fault, UploadFault::PutLostUnapplied) {
                return Err("lost PUT".into());
            }
            if let Some(body) = request.body {
                self.location = body["latitude"].as_f64().zip(body["longitude"].as_f64());
                if let Some(date) = body["dateTimeOriginal"].as_str() {
                    self.capture_date = date.into();
                }
            }
            if matches!(self.upload_fault, UploadFault::PutLostApplied) {
                return Err("lost PUT".into());
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
            if matches!(self.upload_fault, UploadFault::Read) {
                return Err("read failed".into());
            }
            let date = if matches!(self.upload_fault, UploadFault::Wait | UploadFault::Expired) {
                None
            } else {
                Some(&self.capture_date)
            };
            let checksum = if matches!(self.upload_fault, UploadFault::WrongIdentity) {
                "b".repeat(40)
            } else {
                SHA1.into()
            };
            json!({"id":ID,"ownerId":OWNER,"type":"IMAGE","originalFileName":"test.jpg","checksum":checksum,"fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,"exifInfo":{"dateTimeOriginal":date,"fileSizeInByte":12,"latitude":self.location.map(|p| p.0),"longitude":self.location.map(|p| p.1)}})
        };
        serde_json::to_value(HttpResponse {
            status: 200,
            body,
            path: request.download_path,
        })
        .map_err(|e| e.to_string())
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        let mut n = 0;
        while !effects.is_empty() {
            n += 1;
            if n > 500 {
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
    core_from_state(state)
}
fn core_from_state(state: SavedLibrary) -> Core<Suwop> {
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

fn restored_upload(shell: &Shell) -> Result<Core<Suwop>, String> {
    let state = shell.journal.as_ref().ok_or("no saved upload journal")?;
    let raw = serde_json::to_value(state).map_err(|e| e.to_string())?;
    let restored = suwop_core::workflow::migrate(raw)?;
    Ok(core_from_state(restored))
}

fn retry_copy_event(shell: &Shell) -> Event {
    Event::Copy {
        keys: shell.source.assets.iter().map(|a| a.key.clone()).collect(),
        intent: TransferIntent::Move,
        id: "retry-receipt".into(),
        now: 30.0,
    }
}

#[test]
fn created_ids_survive_failed_cancelled_and_expired_reads_and_resume_after_restart()
-> Result<(), String> {
    for fault in [UploadFault::Read, UploadFault::Wait, UploadFault::Expired] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = fault;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        assert!(first.view().error.is_some());
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
        let pending = first.view().state.pending_uploads;
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].key.asset_id, ID);
        assert_eq!(
            pending[0].phase,
            suwop_core::immich::UploadPhase::MetadataPending
        );
        assert!(!first.view().state.receipts[0].move_blockers().is_empty());
        let restored = restored_upload(&shell)?;
        shell.upload_fault = UploadFault::None;
        shell.run(&restored, retry_copy_event(&shell))?;
        assert!(
            restored.view().error.is_none(),
            "{:?}",
            restored.view().error
        );
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 1, 0)
        );
        assert!(shell.order.contains(&"confirm-upload"));
        assert!(restored.view().state.pending_uploads.is_empty());
        assert_eq!(
            restored
                .view()
                .state
                .receipts
                .last()
                .ok_or("no receipt")?
                .phase,
            TransferPhase::Copied
        );
    }
    Ok(())
}

#[test]
fn resume_confirmation_cancel_or_loss_never_reuploads_or_updates_metadata() -> Result<(), String> {
    for confirmation in [Some(false), None] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = UploadFault::Read;
        shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
        let restored = restored_upload(&shell)?;
        shell.upload_fault = UploadFault::None;
        shell.confirm = confirmation;
        shell.run(&restored, retry_copy_event(&shell))?;
        assert!(restored.view().error.is_some());
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
        assert_eq!(
            restored.view().state.pending_uploads[0].phase,
            suwop_core::immich::UploadPhase::MetadataPending
        );
    }
    Ok(())
}

#[test]
fn a_lost_put_response_is_recovered_by_reads_only_if_values_already_match() -> Result<(), String> {
    for fault in [UploadFault::PutLostApplied, UploadFault::PutLostUnapplied] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = fault;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        assert_eq!(
            first.view().state.pending_uploads[0].phase,
            suwop_core::immich::UploadPhase::MetadataStarted
        );
        let restored = restored_upload(&shell)?;
        shell.upload_fault = UploadFault::None;
        shell.run(&restored, retry_copy_event(&shell))?;
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 1, 0)
        );
        assert!(!shell.order.contains(&"confirm-upload"));
        if matches!(fault, UploadFault::PutLostApplied) {
            assert!(restored.view().error.is_none());
            assert!(restored.view().state.pending_uploads.is_empty());
        } else {
            assert!(restored.view().error.is_some());
            assert_eq!(
                restored.view().state.pending_uploads[0].phase,
                suwop_core::immich::UploadPhase::MetadataStarted
            );
        }
    }
    Ok(())
}

#[test]
fn resume_rechecks_downloaded_bytes_and_confirmation_revision_before_put() -> Result<(), String> {
    for changed_during_confirmation in [false, true] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = UploadFault::Read;
        shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
        let restored = restored_upload(&shell)?;
        shell.upload_fault = if changed_during_confirmation {
            UploadFault::ConfirmChanged
        } else {
            UploadFault::None
        };
        shell.target_changed = !changed_during_confirmation;
        shell.run(&restored, retry_copy_event(&shell))?;
        assert!(restored.view().error.is_some());
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
        assert_eq!(
            shell.order.contains(&"confirm-upload"),
            changed_during_confirmation
        );
        assert_eq!(
            restored.view().state.pending_uploads[0].phase,
            suwop_core::immich::UploadPhase::MetadataPending
        );
    }
    Ok(())
}

#[test]
fn upload_journal_failure_prevents_metadata_writes() -> Result<(), String> {
    for fault in [UploadFault::CreatedJournal, UploadFault::StartedJournal] {
        let mut shell = Shell::new();
        shell.upload_fault = fault;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        assert!(first.view().error.is_some());
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
    }
    Ok(())
}

#[test]
fn source_changes_cannot_reuse_the_pending_upload_to_mutate_a_duplicate() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.source.assets[0].captured_at = Some(20.0);
    shell.upload_fault = UploadFault::Read;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let restored = restored_upload(&shell)?;
    shell.source.assets[0].revision = "another-edit".into();
    shell.upload_fault = UploadFault::Duplicate;
    shell.run(&restored, retry_copy_event(&shell))?;
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (2, 0, 0)
    );
    assert!(!shell.order.contains(&"confirm-upload"));
    assert_eq!(restored.view().state.pending_uploads.len(), 1);
    assert_eq!(
        restored.view().state.pending_uploads[0].source.revision,
        "1"
    );
    Ok(())
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

#[test]
fn a_created_response_with_wrong_original_identity_cannot_authorize_metadata() -> Result<(), String>
{
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::WrongIdentity;
    let first = core();
    shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
    assert!(first.view().error.is_some());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    assert_eq!(
        first.view().state.pending_uploads[0].phase,
        suwop_core::immich::UploadPhase::MetadataPending
    );
    Ok(())
}

#[test]
fn duplicate_pending_ids_cannot_authorize_resume() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::Read;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let mut state = shell.journal.clone().ok_or("no journal")?;
    state.pending_uploads.push(state.pending_uploads[0].clone());
    let restored = core_from_state(state);
    shell.upload_fault = UploadFault::None;
    shell.run(&restored, retry_copy_event(&shell))?;
    assert!(restored.view().error.is_some());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    assert!(!shell.order.contains(&"confirm-upload"));
    Ok(())
}

#[test]
fn a_different_destination_scope_cannot_resume_another_accounts_pending_copy() -> Result<(), String>
{
    let mut shell = Shell::new();
    shell.source.assets[0].captured_at = Some(20.0);
    shell.upload_fault = UploadFault::Read;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let mut state = shell.journal.clone().ok_or("no journal")?;
    state.pending_uploads[0].key.scope = "another-server#another-owner".into();
    let restored = core_from_state(state);
    shell.upload_fault = UploadFault::Duplicate;
    shell.run(&restored, retry_copy_event(&shell))?;
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (2, 0, 0)
    );
    assert!(!shell.order.contains(&"confirm-upload"));
    assert_eq!(
        restored.view().state.pending_uploads[0].key.scope,
        "another-server#another-owner"
    );
    Ok(())
}
