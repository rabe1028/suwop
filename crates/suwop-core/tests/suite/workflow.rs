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
    ForgetJournal,
    IntentJournal,
    PostLost,
    IntentForgetJournal,
}
#[derive(Clone, Copy)]
enum ObserveWrite {
    Post,
    Put,
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
    http_requests: usize,
    uploaded_name: String,
    uploaded_marker: Value,
    observe_write: Option<ObserveWrite>,
    reconciliation: Option<Value>,
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
            immich_visibility: None,
            immich_stack: suwop_core::domain::ImmichStackState::Unknown,
            immich_stack_membership: None,
            apple_visibility: suwop_core::domain::AppleVisibility::Visible,
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
            http_requests: 0,
            uploaded_name: "test.jpg".into(),
            uploaded_marker: Value::Null,
            observe_write: None,
            reconciliation: None,
        }
    }
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::RandomId => Ok(json!(if self.writes == 0 {
                "33333333-3333-4333-8333-333333333333"
            } else {
                "44444444-4444-4444-8444-444444444444"
            })),
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
            ShellOperation::Persist(state) => self.persist(state),
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
            ShellOperation::ConfirmForgetUpload { .. } => {
                self.order.push("confirm-forget");
                self.confirm.map(Value::Bool).ok_or("cancelled".into())
            }
            ShellOperation::ConfirmForgetUploadIntent { .. } => {
                self.order.push("confirm-forget-intent");
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
    fn persist(&mut self, state: SavedLibrary) -> Result<Value, String> {
        self.order.push("persist");
        if matches!(self.upload_fault, UploadFault::IntentForgetJournal)
            && state.upload_intents.is_empty()
            && self
                .journal
                .as_ref()
                .is_some_and(|s| !s.upload_intents.is_empty())
        {
            return Err("intent retirement failed".into());
        }
        if matches!(self.upload_fault, UploadFault::IntentJournal)
            && !state.upload_intents.is_empty()
        {
            return Err("intent journal failed".into());
        }
        if matches!(self.upload_fault, UploadFault::ForgetJournal)
            && state.pending_uploads.is_empty()
            && self
                .journal
                .as_ref()
                .is_some_and(|s| !s.pending_uploads.is_empty())
        {
            return Err("forget journal failed".into());
        }
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
    fn upload_response(
        &mut self,
        request: &suwop_core::immich::HttpRequest,
    ) -> Result<Value, String> {
        let metadata: Value =
            serde_json::from_str(request.fields.get("metadata").ok_or("no upload marker")?)
                .map_err(|e| e.to_string())?;
        let token = metadata[0]["value"]["token"]
            .as_str()
            .ok_or("no origin token")?;
        if !self.journal.as_ref().is_some_and(|state| {
            state
                .upload_intents
                .iter()
                .any(|intent| intent.token == token)
        }) {
            return Err("POST must be preceded by durable matching intent".into());
        }
        self.writes += 1;
        self.uploaded_name
            .clone_from(&request.files.first().ok_or("no uploaded file")?.filename);
        if !matches!(self.upload_fault, UploadFault::Duplicate) {
            self.uploaded_marker = metadata[0]["value"].clone();
        }
        if matches!(self.upload_fault, UploadFault::PostLost) {
            return Err("lost POST".into());
        }
        Ok(
            json!({"id":ID,"status":if matches!(self.upload_fault, UploadFault::Duplicate) {"duplicate"} else {"created"}}),
        )
    }
    fn http(&mut self, request: suwop_core::immich::HttpRequest) -> Result<Value, String> {
        self.http_requests += 1;
        let body = if request.url.ends_with("/assets/bulk-upload-check") {
            let token =
                request.body.as_ref().ok_or("no bulk check body")?["assets"][0]["id"].clone();
            self.reconciliation.clone().unwrap_or_else(|| json!({"results":[{"id":token,"action":"reject","reason":"duplicate","assetId":ID,"isTrashed":false}]}))
        } else if request.url.contains("/metadata/suwop.upload-origin.v1") {
            json!({"key":"suwop.upload-origin.v1","value":self.uploaded_marker,"updatedAt":"1970-01-01T00:00:10Z"})
        } else if request.method == "POST" && request.url.ends_with("/assets") {
            self.upload_response(&request)?
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
            json!({"id":ID,"ownerId":OWNER,"type":"IMAGE","originalFileName":self.uploaded_name,"checksum":checksum,"fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,"exifInfo":{"dateTimeOriginal":date,"fileSizeInByte":12,"latitude":self.location.map(|p| p.0),"longitude":self.location.map(|p| p.1)}})
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
            let observed = match (&request.operation, self.observe_write) {
                (ShellOperation::Persist(saved), Some(ObserveWrite::Post)) => {
                    !saved.upload_intents.is_empty()
                }
                (ShellOperation::Persist(saved), Some(ObserveWrite::Put)) => saved
                    .pending_uploads
                    .iter()
                    .any(|p| p.phase == suwop_core::immich::UploadPhase::MetadataStarted),
                _ => false,
            };
            if observed {
                self.observe_write = None;
                assert!(core.process_event(Event::AppleChanged).is_empty());
            }
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
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: Shell::new().source.assets,
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        }],
        ..SavedLibrary::default()
    };
    core_from_state(state)
}
fn core_from_state(state: SavedLibrary) -> Core<Suwop> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
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
fn upload_intent_is_durable_before_post_and_can_reconcile_a_lost_created_id() -> Result<(), String>
{
    for fault in [UploadFault::CreatedJournal, UploadFault::PostLost] {
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
        let state = shell.journal.as_ref().ok_or("no durable intent")?;
        assert_eq!(state.upload_intents.len(), 1);
        assert!(state.pending_uploads.is_empty());
        assert_eq!(first.view().state.upload_intents.len(), 1);
        assert!(first.view().state.pending_uploads.is_empty());
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
        assert!(restored.view().state.upload_intents.is_empty());
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
fn failed_intent_save_never_issues_post_or_leaks_into_an_unrelated_save() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::IntentJournal;
    let first = core();
    shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
    assert!(first.view().error.is_some());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (0, 0, 0)
    );
    assert!(first.view().state.upload_intents.is_empty());
    shell.upload_fault = UploadFault::None;
    shell.run(
        &first,
        Event::Refresh {
            permission: false,
            now: 30.0,
        },
    )?;
    assert!(
        shell
            .journal
            .as_ref()
            .ok_or("no journal")?
            .upload_intents
            .is_empty()
    );
    Ok(())
}

#[test]
fn unknown_post_never_retries_and_unrelated_duplicate_never_grants_metadata_ownership()
-> Result<(), String> {
    for response in [
        json!({"results":[]}),
        json!({"results":[{"id":"33333333-3333-4333-8333-333333333333","action":"accept"}]}),
        json!({"results":[{"id":"wrong","action":"reject","reason":"duplicate","assetId":ID,"isTrashed":false}]}),
        json!({"results":[{"id":"33333333-3333-4333-8333-333333333333","action":"reject","reason":"duplicate","assetId":ID,"isTrashed":true}]}),
        Value::Null,
    ] {
        let mut shell = Shell::new();
        shell.upload_fault = UploadFault::PostLost;
        shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
        let restored = restored_upload(&shell)?;
        shell.upload_fault = UploadFault::None;
        shell.reconciliation = if response.is_null() {
            shell.uploaded_marker = json!({"version":1,"token":"another-operation"});
            None
        } else {
            Some(response)
        };
        shell.run(&restored, retry_copy_event(&shell))?;
        assert!(restored.view().error.is_some());
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
        assert!(!shell.order.contains(&"confirm-upload"));
        assert_eq!(restored.view().state.upload_intents.len(), 1);
    }
    Ok(())
}

#[test]
fn forgetting_unknown_upload_is_local_only_and_cancel_or_save_failure_retains_it()
-> Result<(), String> {
    for confirmation in [Some(true), Some(false), None] {
        let mut shell = Shell::new();
        shell.upload_fault = UploadFault::PostLost;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        let before = serde_json::to_value(first.view().state).map_err(|e| e.to_string())?;
        let intent = first.view().state.upload_intents[0].clone();
        shell.confirm = confirmation;
        let http = shell.http_requests;
        shell.order.clear();
        shell.run(
            &first,
            Event::ForgetUploadIntent {
                scope: intent.scope,
                token: intent.token,
            },
        )?;
        assert_eq!(shell.http_requests, http);
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
        let after = serde_json::to_value(first.view().state).map_err(|e| e.to_string())?;
        assert_eq!(before["receipts"], after["receipts"]);
        assert_eq!(before["snapshots"], after["snapshots"]);
        assert_eq!(
            after["uploadIntents"]
                .as_array()
                .ok_or("no intents")?
                .is_empty(),
            confirmation == Some(true)
        );
    }
    Ok(())
}

#[test]
fn failed_pre_put_save_keeps_pending_phase_through_refresh_and_explicit_retry() -> Result<(), String>
{
    for restart in [false, true] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = UploadFault::StartedJournal;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        assert!(first.view().error.is_some());
        assert_eq!(shell.metadata_writes, 0);
        assert_eq!(
            first.view().state.pending_uploads[0].phase,
            suwop_core::immich::UploadPhase::MetadataPending
        );
        shell.upload_fault = UploadFault::None;
        // An unrelated successful persistence must keep the unsent phase.
        shell.run(
            &first,
            Event::Refresh {
                permission: true,
                now: 25.0,
            },
        )?;
        assert!(first.view().error.is_none(), "{:?}", first.view().error);
        assert_eq!(
            shell.journal.as_ref().ok_or("no journal")?.pending_uploads[0].phase,
            suwop_core::immich::UploadPhase::MetadataPending
        );
        let current = if restart {
            restored_upload(&shell)?
        } else {
            first
        };
        shell.run(&current, retry_copy_event(&shell))?;
        assert!(current.view().error.is_none(), "{:?}", current.view().error);
        assert!(current.view().state.pending_uploads.is_empty());
        assert!(shell.order.contains(&"confirm-upload"));
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 1, 0)
        );
    }
    Ok(())
}

#[test]
fn created_and_resumed_uploads_verify_the_filename_actually_sent() -> Result<(), String> {
    for (name, sent) in [
        ("folder/photo.jpg", "photo.jpg"),
        ("photo\\name.jpg", "photo_name.jpg"),
        ("photo\"name.jpg", "photo_name.jpg"),
        ("photo\r\nname.jpg", "photo__name.jpg"),
        ("", "original"),
        ("folder/", "original"),
    ] {
        for resume in [false, true] {
            let mut shell = Shell::new();
            shell.source.assets[0].name = name.into();
            shell.source.assets[0].resources[0].name = name.into();
            shell.source.files[0].resource.name = name.into();
            shell.source.assets[0].captured_at = Some(20.0);
            if resume {
                shell.upload_fault = UploadFault::Read;
            }
            let first = core();
            shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
            let current = if resume {
                assert!(first.view().error.is_some());
                shell.upload_fault = UploadFault::None;
                let restored = restored_upload(&shell)?;
                shell.run(&restored, retry_copy_event(&shell))?;
                restored
            } else {
                first
            };
            assert!(current.view().error.is_none(), "{:?}", current.view().error);
            assert_eq!(shell.uploaded_name, sent);
            assert_eq!(shell.source.files[0].resource.name, name);
            assert!(current.view().state.pending_uploads.is_empty());
            assert_eq!(
                (shell.writes, shell.metadata_writes, shell.deleted),
                (1, 1, 0)
            );
        }
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
    assert_eq!(
        state.schema_version,
        suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION
    );
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
fn unresolved_trash_fences_metadata_resume_on_an_existing_copy() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::Read;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let mut state = shell.journal.clone().ok_or("no journal")?;
    let upload = state
        .pending_uploads
        .first()
        .ok_or("no upload record")?
        .clone();
    state.pending_trash.push(suwop_core::trash::TrashOperation {
        id: "33333333-3333-4333-8333-333333333333".into(),
        scope: upload.key.scope.clone(),
        action: suwop_core::trash::TrashAction::Trash,
        assets: vec![suwop_core::trash::TrashIdentity {
            key: upload.key.clone(),
            name: upload.source.name.clone(),
            checksum: SHA1.into(),
            media_type: "IMAGE".into(),
            created_at: "1970-01-01T00:00:10Z".into(),
            modified_at: "1970-01-01T00:00:10Z".into(),
            live_photo_video_id: None,
        }],
    });
    let restored = core_from_state(state);
    shell.upload_fault = UploadFault::None;
    shell.run(&restored, retry_copy_event(&shell))?;
    assert!(restored.view().error.is_some());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    assert_eq!(restored.view().state.pending_uploads.len(), 1);
    assert_eq!(restored.view().state.pending_trash.len(), 1);
    Ok(())
}

fn pending_same_original(scope: &str, checksum: &str) -> suwop_core::trash::TrashOperation {
    suwop_core::trash::TrashOperation {
        id: "33333333-3333-4333-8333-333333333333".into(),
        scope: scope.into(),
        action: suwop_core::trash::TrashAction::Trash,
        assets: vec![suwop_core::trash::TrashIdentity {
            key: AssetKey {
                provider: Provider::Immich,
                scope: scope.into(),
                asset_id: "55555555-5555-4555-8555-555555555555".into(),
            },
            name: "other-copy.jpg".into(),
            checksum: checksum.into(),
            media_type: "IMAGE".into(),
            created_at: "1970-01-01T00:00:10Z".into(),
            modified_at: "1970-01-01T00:00:10Z".into(),
            live_photo_video_id: None,
        }],
    }
}

#[test]
fn pending_same_original_fences_new_apple_copy_and_move_before_any_journal_or_upload()
-> Result<(), String> {
    for intent in [TransferIntent::Copy, TransferIntent::Move] {
        for action in [
            suwop_core::trash::TrashAction::Trash,
            suwop_core::trash::TrashAction::Restore,
        ] {
            let mut shell = Shell::new();
            let mut operation = pending_same_original("immich", SHA1);
            operation.action = action;
            let state = SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                pending_trash: vec![operation],
                ..SavedLibrary::default()
            };
            // No cached Apple fingerprints: the fence uses the fresh export.
            let restored = core_from_state(state);
            shell.run(&restored, copy_event(&shell, intent))?;
            let view = restored.view();
            assert!(view.error.is_some());
            assert_eq!(
                (
                    shell.writes,
                    shell.metadata_writes,
                    shell.deleted,
                    shell.http_requests
                ),
                (0, 0, 0, 0)
            );
            assert!(shell.journal.is_none());
            assert!(view.state.receipts.is_empty());
            assert!(view.state.upload_intents.is_empty());
            assert!(view.state.pending_uploads.is_empty());
            assert_eq!(view.state.pending_trash.len(), 1);
        }
    }
    Ok(())
}

#[test]
fn unrelated_originals_and_other_accounts_do_not_fence_transfers() -> Result<(), String> {
    for (scope, checksum) in [("immich", "2".repeat(40)), ("other-account", SHA1.into())] {
        let mut shell = Shell::new();
        let restored = core_from_state(SavedLibrary {
            schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
            apple_scope: "apple".into(),
            snapshots: vec![LibrarySnapshot {
                provider: Provider::Apple,
                scope: "apple".into(),
                assets: shell.source.assets.clone(),
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            }],
            pending_trash: vec![pending_same_original(scope, &checksum)],
            ..SavedLibrary::default()
        });
        shell.run(&restored, copy_event(&shell, TransferIntent::Copy))?;
        assert_eq!(restored.view().error, None);
        assert_eq!(shell.writes, 1);
        assert_eq!(shell.deleted, 0);
        assert_eq!(restored.view().state.pending_trash.len(), 1);
    }
    Ok(())
}

#[test]
fn pending_same_original_fences_completion_of_an_existing_move() -> Result<(), String> {
    let mut shell = Shell::new();
    let first = core();
    shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
    let mut state = shell.journal.clone().ok_or("no canonical journal")?;
    state
        .pending_trash
        .push(pending_same_original("immich", SHA1));
    let restored = core_from_state(state);
    let original_writes = (shell.writes, shell.metadata_writes, shell.http_requests);
    shell.run(&restored, move_event())?;
    assert!(restored.view().error.is_some());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.http_requests),
        original_writes
    );
    assert_eq!(shell.deleted, 0);
    assert_eq!(
        restored.view().state.receipts[0].phase,
        TransferPhase::Copied
    );
    assert_eq!(restored.view().state.pending_trash.len(), 1);
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

fn forget_event(core: &Core<Suwop>) -> Result<Event, String> {
    let key = core
        .view()
        .state
        .pending_uploads
        .first()
        .ok_or("no pending upload")?
        .key
        .clone();
    Ok(Event::ForgetUploadRecord { key })
}

#[test]
fn explicit_forget_retains_photos_receipts_and_never_sends_http() -> Result<(), String> {
    for fault in [UploadFault::Read, UploadFault::PutLostUnapplied] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = fault;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        let before = first.view().state;
        let requests = shell.http_requests;
        shell.run(&first, forget_event(&first)?)?;
        let after = first.view().state;
        assert!(first.view().error.is_none());
        assert!(after.pending_uploads.is_empty());
        assert_eq!(shell.http_requests, requests);
        assert_eq!(
            serde_json::to_value(before.receipts).map_err(|e| e.to_string())?,
            serde_json::to_value(after.receipts).map_err(|e| e.to_string())?
        );
        assert_eq!(
            serde_json::to_value(before.snapshots).map_err(|e| e.to_string())?,
            serde_json::to_value(after.snapshots).map_err(|e| e.to_string())?
        );
        assert_eq!(shell.deleted, 0);
        // Only the next explicit Copy may POST again. A duplicate still cannot
        // authorize metadata writes, even after a metadataStarted record is gone.
        let writes = shell.metadata_writes;
        shell.upload_fault = UploadFault::Duplicate;
        shell.run(&first, retry_copy_event(&shell))?;
        assert_eq!(shell.writes, 2);
        assert_eq!(shell.metadata_writes, writes);
        assert_eq!(shell.deleted, 0);
    }
    Ok(())
}

#[test]
fn forget_cancel_or_lost_confirmation_preserves_the_pending_record() -> Result<(), String> {
    for confirm in [Some(false), None] {
        let mut shell = Shell::new();
        shell.upload_fault = UploadFault::Read;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
        let before = first.view().state.pending_uploads;
        let requests = shell.http_requests;
        shell.confirm = confirm;
        shell.run(&first, forget_event(&first)?)?;
        assert_eq!(shell.http_requests, requests);
        assert_eq!(
            serde_json::to_value(before).map_err(|e| e.to_string())?,
            serde_json::to_value(first.view().state.pending_uploads).map_err(|e| e.to_string())?
        );
        assert_eq!(
            (shell.writes, shell.metadata_writes, shell.deleted),
            (1, 0, 0)
        );
    }
    Ok(())
}

#[test]
fn forgetting_duplicate_local_ids_does_not_clear_other_scopes() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::Read;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let mut state = shell.journal.clone().ok_or("no journal")?;
    let mut foreign = state.pending_uploads[0].clone();
    foreign.key.scope = "another-account".into();
    state.pending_uploads.push(state.pending_uploads[0].clone());
    state.pending_uploads.push(foreign);
    let first = core_from_state(state);
    let requests = shell.http_requests;
    shell.run(&first, forget_event(&first)?)?;
    assert_eq!(shell.http_requests, requests);
    assert_eq!(first.view().state.pending_uploads.len(), 1);
    assert_eq!(
        first.view().state.pending_uploads[0].key.scope,
        "another-account"
    );
    Ok(())
}

#[test]
fn a_failed_forget_save_restores_the_in_memory_pending_record() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::Read;
    let first = core();
    shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
    shell.upload_fault = UploadFault::ForgetJournal;
    let requests = shell.http_requests;
    shell.run(&first, forget_event(&first)?)?;
    assert!(first.view().error.is_some());
    assert_eq!(first.view().state.pending_uploads.len(), 1);
    assert_eq!(
        shell
            .journal
            .as_ref()
            .ok_or("no journal")?
            .pending_uploads
            .len(),
        1
    );
    assert_eq!(shell.http_requests, requests);
    Ok(())
}

#[test]
fn an_unknown_forget_key_never_prompts_or_touches_io() -> Result<(), String> {
    let mut shell = Shell::new();
    let first = core();
    shell.run(
        &first,
        Event::ForgetUploadRecord {
            key: AssetKey {
                provider: Provider::Immich,
                scope: "unknown".into(),
                asset_id: ID.into(),
            },
        },
    )?;
    assert!(first.view().error.is_some());
    assert_eq!(shell.http_requests, 0);
    assert!(!shell.order.contains(&"confirm-forget"));
    Ok(())
}

#[test]
fn intent_retirement_save_failure_restores_the_record() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.upload_fault = UploadFault::PostLost;
    let first = core();
    shell.run(&first, copy_event(&shell, TransferIntent::Move))?;
    let before = first.view().state.upload_intents;
    shell.upload_fault = UploadFault::IntentForgetJournal;
    shell.run(
        &first,
        Event::ForgetUploadIntent {
            scope: before[0].scope.clone(),
            token: before[0].token.clone(),
        },
    )?;
    assert!(first.view().error.is_some());
    assert_eq!(
        serde_json::to_value(first.view().state.upload_intents).map_err(|e| e.to_string())?,
        serde_json::to_value(before).map_err(|e| e.to_string())?
    );
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    Ok(())
}

#[test]
fn ambiguous_or_mismatched_intents_never_authorize_a_metadata_write() -> Result<(), String> {
    for variant in 0..5 {
        let mut shell = Shell::new();
        shell.upload_fault = UploadFault::PostLost;
        shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
        let mut state = shell.journal.clone().ok_or("no state")?;
        match variant {
            0 => state.upload_intents.push(state.upload_intents[0].clone()),
            1 => state.upload_intents[0].token = "malformed".into(),
            2 => state.upload_intents[0].scope = "another-server#another-owner".into(),
            3 => shell.source.assets[0].revision = "new-source-revision".into(),
            _ => shell.uploaded_marker = Value::Null,
        }
        let restored = core_from_state(state);
        shell.upload_fault = if matches!(variant, 2 | 3) {
            UploadFault::Duplicate
        } else {
            UploadFault::None
        };
        shell.run(&restored, retry_copy_event(&shell))?;
        assert_eq!((shell.metadata_writes, shell.deleted), (0, 0));
        assert!(!shell.order.contains(&"confirm-upload"));
        assert_eq!(shell.writes, if matches!(variant, 2 | 3) { 2 } else { 1 });
    }
    Ok(())
}

#[test]
fn failed_reconciliation_promotion_rolls_back_before_metadata_or_unrelated_save()
-> Result<(), String> {
    let mut shell = Shell::new();
    shell.source.assets[0].captured_at = Some(20.0);
    shell.upload_fault = UploadFault::PostLost;
    shell.run(&core(), copy_event(&shell, TransferIntent::Move))?;
    let restored = restored_upload(&shell)?;
    shell.upload_fault = UploadFault::CreatedJournal;
    shell.run(&restored, retry_copy_event(&shell))?;
    assert!(restored.view().error.is_some());
    assert_eq!(restored.view().state.upload_intents.len(), 1);
    assert!(restored.view().state.pending_uploads.is_empty());
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    shell.upload_fault = UploadFault::None;
    shell.run(
        &restored,
        Event::Refresh {
            permission: false,
            now: 40.0,
        },
    )?;
    let state = shell.journal.as_ref().ok_or("no journal")?;
    assert_eq!(state.upload_intents.len(), 1);
    assert!(state.pending_uploads.is_empty());
    let restarted = restored_upload(&shell)?;
    shell.run(&restarted, retry_copy_event(&shell))?;
    assert!(
        restarted.view().error.is_none(),
        "{:?}",
        restarted.view().error
    );
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 1, 0)
    );
    Ok(())
}

#[test]
fn schema2_upload_journals_resume_after_fresh_visible_scan_without_new_post() -> Result<(), String>
{
    for fault in [UploadFault::Read, UploadFault::PostLost] {
        let mut shell = Shell::new();
        shell.source.assets[0].captured_at = Some(20.0);
        shell.upload_fault = fault;
        let first = core();
        shell.run(&first, copy_event(&shell, TransferIntent::Copy))?;
        let mut old = serde_json::to_value(shell.journal.as_ref().ok_or("no journal")?)
            .map_err(|e| e.to_string())?;
        old["schemaVersion"] = json!(2);
        for field in [
            "immichLiveOperations",
            "immichLiveUnstartedClosures",
            "immichLiveLegacyReconciliations",
        ] {
            old.as_object_mut().ok_or("object")?.remove(field);
        }
        for field in ["pendingUploads", "uploadIntents"] {
            for entry in old[field].as_array_mut().ok_or("journal array")? {
                entry["source"]
                    .as_object_mut()
                    .ok_or("source")?
                    .remove("appleVisibility");
            }
        }
        let migrated = suwop_core::workflow::migrate(old)?;
        for source in migrated
            .pending_uploads
            .iter()
            .map(|p| &p.source)
            .chain(migrated.upload_intents.iter().map(|i| &i.source))
        {
            assert_eq!(
                source.apple_visibility,
                suwop_core::domain::AppleVisibility::Unknown
            );
        }
        let restored = core_from_state(migrated);
        shell.upload_fault = UploadFault::None;
        shell.run(&restored, retry_copy_event(&shell))?;
        assert!(
            restored.view().error.is_none(),
            "{:?}",
            restored.view().error
        );
        assert_eq!(shell.writes, 1);
        assert_eq!(shell.metadata_writes, 1);
        assert!(restored.view().state.pending_uploads.is_empty());
        assert!(restored.view().state.upload_intents.is_empty());
    }
    Ok(())
}

#[test]
fn apple_change_after_upload_intent_persist_prevents_the_post() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.observe_write = Some(ObserveWrite::Post);
    let core = core();
    shell.run(&core, copy_event(&shell, TransferIntent::Copy))?;
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (0, 0, 0)
    );
    assert!(core.view().error.is_some());
    assert_eq!(
        shell
            .journal
            .as_ref()
            .ok_or("no durable pre-post intent")?
            .upload_intents
            .len(),
        1
    );
    Ok(())
}

#[test]
fn apple_change_after_metadata_intent_persist_prevents_the_put() -> Result<(), String> {
    let mut shell = Shell::new();
    shell.source.assets[0].captured_at = Some(20.0);
    shell.observe_write = Some(ObserveWrite::Put);
    let core = core();
    shell.run(&core, copy_event(&shell, TransferIntent::Copy))?;
    assert_eq!(
        (shell.writes, shell.metadata_writes, shell.deleted),
        (1, 0, 0)
    );
    assert!(core.view().error.is_some());
    assert_eq!(
        shell
            .journal
            .as_ref()
            .ok_or("no durable pre-put intent")?
            .pending_uploads[0]
            .phase,
        suwop_core::immich::UploadPhase::MetadataStarted
    );
    Ok(())
}
