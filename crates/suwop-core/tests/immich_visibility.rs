use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{
        ConnectionSettings, Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse,
        Suwop,
    },
    domain::{AssetKey, Provider},
    immich::{Session, Version},
    immich_locked::Secret,
    protection::PersistentProtectedEntry,
};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const ASSET: &str = "33333333-3333-4333-8333-333333333333";
const OWNER: &str = "44444444-4444-4444-8444-444444444444";
fn asset() -> Value {
    json!({"id":ASSET,"ownerId":OWNER,"type":"IMAGE","originalFileName":"PRIVATE-LOCKED.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision1","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"timeline","isExternal":false,"livePhotoVideoId":null,"stack":null})
}
fn core(protected: bool) -> Core<Suwop> {
    core_operations(protected, vec![])
}
fn core_operations(
    protected: bool,
    operations: Vec<suwop_core::immich_visibility::ImmichVisibilityOperation>,
) -> Core<Suwop> {
    core_denials(protected, operations, std::collections::BTreeSet::new())
}
fn core_denials(
    protected: bool,
    operations: Vec<suwop_core::immich_visibility::ImmichVisibilityOperation>,
    denied: std::collections::BTreeSet<AssetKey>,
) -> Core<Suwop> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "ordinary-api-secret".into(),
        user_id: OWNER.into(),
        scope: format!("https://fixture.example/api#{OWNER}"),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let state = SavedLibrary {
        immich_visibility_operations: operations,
        schema_version: 8,
        apple_scope: "apple".into(),
        connection: Some(ConnectionSettings {
            address: session.endpoint.clone(),
            allow_http: false,
            credential_id: "ordinary-credential".into(),
        }),
        protected_entries: if protected {
            vec![PersistentProtectedEntry {
                id: "55555555-5555-4555-8555-555555555555".into(),
                key: AssetKey {
                    provider: Provider::Immich,
                    scope: session.scope.clone(),
                    asset_id: ASSET.into(),
                },
            }]
        } else {
            vec![]
        },
        ..SavedLibrary::default()
    };
    Core::new_with(
        Suwop,
        Model {
            protection: suwop_core::protection::ProtectionModel {
                denied,
                ..suwop_core::protection::ProtectionModel::default()
            },
            state,
            session: Some(session),
            ready: true,
            ..Model::default()
        },
    )
}
fn open(id: &str) -> Event {
    Event::OpenImmichLocked {
        scene_id: SCENE.into(),
        request_id: id.into(),
        email: Secret("private@example.invalid".into()),
        password: Secret("private-password".into()),
        pin_code: Secret("123456".into()),
    }
}
#[derive(Default)]
enum WriteFault {
    #[default]
    None,
    LostApplied,
    LostNotApplied,
    Contradictory,
}
#[derive(Default)]
struct Shell {
    versions: std::collections::VecDeque<Value>,
    version_reads: usize,
    fail_version: Option<usize>,
    confirmations: usize,
    pages: Option<std::collections::VecDeque<Value>>,
    paths: Vec<String>,
    status_reads: usize,
    fail_status: Option<usize>,
    stages: usize,
    releases: Vec<String>,
    visibility: Option<String>,
    confirmed: bool,
    writes: usize,
    ordinary_writes: usize,
    ordinary_reads: usize,
    write_fault: WriteFault,
    persist_calls: usize,
    fail_persist: Option<usize>,
    disk: Option<Value>,
    read_fail: bool,
    persist_after_failure: bool,
    relationship: Option<Value>,
    facts_patch: Option<Value>,
    ordinary_asset: Option<Value>,
    omit_field: Option<String>,
    asset_failure: Option<u16>,
    asset_transport_failure: Option<()>,
    patch_after_stage: Option<Value>,
    quiescence_failure: Option<String>,
    quiescence_ack: Option<Value>,
    quiescences: Vec<AssetKey>,
    quiescence_pending: Vec<Option<suwop_core::immich_locked::video::ImmichLockedVideoPending>>,
}
impl Shell {
    fn quiesce_response(
        &mut self,
        key: &AssetKey,
        pending: Option<&suwop_core::immich_locked::video::ImmichLockedVideoPending>,
    ) -> Result<Value, String> {
        self.quiescences.push(key.clone());
        self.quiescence_pending.push(pending.cloned());
        if let Some(message) = &self.quiescence_failure {
            Err(message.clone())
        } else {
            Ok(self.quiescence_ack.clone().unwrap_or(Value::Null))
        }
    }
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::ConfirmImmichArchive { .. } => Ok(json!(true)),
            ShellOperation::QuiesceImmichLockedVideo { key, pending } => {
                self.quiesce_response(key, pending.as_ref())
            }

            ShellOperation::Http(request)
                if request.headers.contains_key("x-api-key")
                    && self
                        .ordinary_asset
                        .as_ref()
                        .and_then(|a| a["id"].as_str())
                        .is_some_and(|id| {
                            request.url == format!("https://fixture.example/api/assets/{id}")
                        }) =>
            {
                assert_eq!(request.method, "GET");
                assert!(!request.headers.contains_key("Authorization"));
                Ok(json!({"status":200,"body":self.ordinary_asset}))
            }
            ShellOperation::Http(request)
                if request.headers.contains_key("x-api-key")
                    && request.method == "GET"
                    && request.url == format!("https://fixture.example/api/assets/{ASSET}") =>
            {
                assert!(!request.headers.contains_key("Authorization"));
                self.paths.push(format!("assets/{ASSET}"));
                self.ordinary_reads += 1;
                Ok(json!({"status":403,"body":null}))
            }
            ShellOperation::Http(request) => self.http(request),
            ShellOperation::ConfirmImmichVisibility { prompt } => {
                self.confirmations += 1;
                assert!([GRANT, NEXT].contains(&prompt.grant_id.as_str()));
                assert_eq!(prompt.scene_id, SCENE);
                Ok(json!(self.confirmed))
            }
            ShellOperation::Persist(state) => {
                self.persist_calls += 1;
                let raw = serde_json::to_value(state).map_err(|_| "encode")?;
                if self.fail_persist == Some(self.persist_calls) {
                    if self.persist_after_failure {
                        self.disk = Some(raw);
                    }
                    return Err("persistence unavailable".into());
                }
                self.disk = Some(raw);
                Ok(Value::Null)
            }
            ShellOperation::ReadState => {
                if self.read_fail {
                    Err("unavailable".into())
                } else {
                    self.disk.clone().ok_or_else(|| "missing".into())
                }
            }
            ShellOperation::InspectImmichLockedVideoStorage { pending } => Ok(
                json!({"leaseID":pending.request_id,"measurementNonce":OP,"deadlineUnixMilliseconds":u64::MAX,"availableBytes":1_073_741_824_u64,"otherUnallocatedBytes":0,"allocationUnitBytes":4096,"capacityClass":"available"}),
            ),
            ShellOperation::ReadImmichLockedVideo { ticket } => Ok(
                json!({"requestID":ticket.pending.request_id,"stagedID":ticket.storage.lease_id,"acquisitionLeaseID":ticket.acquisition_lease.lease_id,"sha1":"a".repeat(40),"signature":{"sha256":"c".repeat(64),"bytes":123}}),
            ),
            ShellOperation::PrepareImmichLockedVideo { ticket, staged_id } => Ok(
                json!({"requestID":ticket.pending.request_id,"stagedID":staged_id,"acquisitionLeaseID":ticket.acquisition_lease.lease_id}),
            ),
            ShellOperation::RenewImmichLockedVideoAcquisition {
                ticket,
                previous_lease_id,
                lease,
            } => Ok(json!({
                "requestID":ticket.pending.request_id,"stagedID":ticket.storage.lease_id,
                "previousLeaseID":previous_lease_id,"leaseID":lease.lease_id
            })),
            ShellOperation::ReleaseImmichLockedVideo { pending, .. } => {
                self.releases.push(pending.request_id.clone());
                Ok(Value::Null)
            }
            ShellOperation::ReadImmichLockedImage { ticket } => {
                self.stages += 1;
                if let Some(patch) = self.patch_after_stage.take() {
                    self.facts_patch = Some(patch);
                }
                Ok(json!({"requestID":ticket.request_id,"stagedID":format!("stage{}",self.stages)}))
            }
            ShellOperation::PublishImmichLockedImage { ticket, staged_id } => {
                Ok(json!({"requestID":ticket.request_id,"stagedID":staged_id}))
            }
            ShellOperation::ReleaseImmichLockedImage { staged_id } => {
                self.releases.push(staged_id.clone());
                Ok(Value::Null)
            }
            ShellOperation::ScheduleImmichLockedVideoAcquisitionExpiry { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. } => Ok(Value::Null),
            _ => Err("unexpected ordinary/native mutation".into()),
        }
    }
    fn asset_read_failure(&self, path: &str, method: &str) -> Option<Result<Value, String>> {
        if path != format!("assets/{ASSET}") || method != "GET" {
            return None;
        }
        if self.asset_transport_failure.is_some() {
            return Some(Err("fixture transport unavailable".into()));
        }
        self.asset_failure
            .map(|status| Ok(json!({"status":status,"body":null})))
    }
    fn version_response(&mut self) -> Result<Value, String> {
        self.version_reads += 1;
        if self.fail_version == Some(self.version_reads) {
            return Err("fixture version transport unavailable".into());
        }
        Ok(self
            .versions
            .pop_front()
            .unwrap_or_else(|| json!({"major":3,"minor":3,"patch":3,"prerelease":null})))
    }
    fn http(&mut self, request: &suwop_core::immich::HttpRequest) -> Result<Value, String> {
        let path = request
            .url
            .strip_prefix("https://fixture.example/api/")
            .ok_or("unexpected endpoint")?;
        self.paths.push(path.into());
        if let Some(failure) = self.asset_read_failure(path, &request.method) {
            return failure;
        }
        if request.headers.contains_key("x-api-key") && request.method != "GET" {
            self.ordinary_writes += 1;
        }
        assert!(!request.headers.contains_key("Cookie"));

        if path == "server/features" {
            return Ok(json!({"status":200,"body":{"passwordLogin":true}}));
        }
        if path == "auth/login" {
            assert!(!request.headers.contains_key("x-api-key"));
            assert!(!request.headers.contains_key("Authorization"));
            return Ok(
                json!({"status":200,"body":{"accessToken":"dedicated-token-secret","userId":OWNER}}),
            );
        }
        assert_eq!(
            request.headers.get("Authorization").map(String::as_str),
            Some("Bearer dedicated-token-secret")
        );
        assert!(!request.headers.contains_key("x-api-key"));
        let body = match path {
            "server/version" => self.version_response()?,
            "users/me" => json!({"id":OWNER}),
            "auth/status" => {
                self.status_reads += 1;
                if self.fail_status == Some(self.status_reads) {
                    json!({"pinCode":true,"password":true,"isElevated":false})
                } else {
                    json!({"pinCode":true,"password":true,"isElevated":true})
                }
            }
            "auth/session/unlock" => {
                assert_eq!(
                    request.body.as_ref().ok_or("no PIN body")?["pinCode"],
                    "123456"
                );
                Value::Null
            }
            "assets" if request.method == "PUT" => {
                let permit = request
                    .immich_visibility_authorization
                    .as_ref()
                    .ok_or("visibility permit")?;
                assert!([GRANT, NEXT].contains(&permit.grant_id.as_str()));
                assert_eq!(permit.scene_id, SCENE);
                assert!([OP, NEXT].contains(&permit.operation_id.as_str()));
                self.writes += 1;
                assert!(self.disk.as_ref().is_some_and(|d| {
                    d["immichVisibilityOperations"]
                        .as_array()
                        .and_then(|ops| ops.last())
                        .is_some_and(|o| o["outcome"] == "unknown")
                }));
                if !matches!(
                    self.write_fault,
                    WriteFault::LostNotApplied | WriteFault::Contradictory
                ) {
                    self.visibility = Some(
                        request.body.as_ref().ok_or("missing write")?["visibility"]
                            .as_str()
                            .ok_or("visibility")?
                            .into(),
                    );
                }
                if matches!(
                    self.write_fault,
                    WriteFault::LostApplied | WriteFault::LostNotApplied
                ) {
                    return Err("lost response secret".into());
                }
                Value::Null
            }
            _ if path == format!("albums?assetId={ASSET}") => json!([]),
            "search/metadata" => {
                assert_eq!(
                    request.body.as_ref().ok_or("no search body")?["filter"]["visibility"]["in"],
                    json!(["locked"])
                );
                if let Some(pages) = &mut self.pages {
                    pages.pop_front().ok_or("missing pagefixture")?
                } else {
                    json!({"assets":{"items":[],"nextCursor":null}})
                }
            }
            "auth/session/lock" => Value::Null,
            "auth/logout" => {
                json!({"successful":true})
            }
            _ if path == format!("assets/{ASSET}") => self.fresh_asset()?,
            _ => return Err("unexpected route".into()),
        };
        Ok(json!({"status":200,"body":body}))
    }
    fn fresh_asset(&self) -> Result<Value, String> {
        let mut a = asset();
        if let Some(v) = &self.visibility {
            a["visibility"] = json!(v);
        }
        if let Some(v) = &self.relationship {
            a["livePhotoVideoId"] = v.clone();
        }
        if let Some(Value::Object(patch)) = &self.facts_patch {
            for (k, v) in patch {
                a[k] = v.clone();
            }
        }
        if let Some(field) = &self.omit_field {
            a.as_object_mut().ok_or("asset object")?.remove(field);
        }
        Ok(a)
    }
    fn run(&mut self, c: &Core<Suwop>, event: Event) -> Result<(), String> {
        if matches!(event, Event::OpenImmichLocked { .. }) {
            self.drain(
                c,
                c.process_event(Event::ImmichLockedSceneChanged {
                    scene_id: SCENE.into(),
                    phase: suwop_core::protection::ProtectionScenePhase::Active,
                }),
            )?;
        }
        self.drain(c, c.process_event(event))
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.respond(&request.operation) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(
                c.resolve(&mut request, response)
                    .map_err(|_| "resolve failed")?,
            );
        }
        Ok(())
    }
}
const OP: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const NEXT: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
fn key() -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: format!("https://fixture.example/api#{OWNER}"),
        asset_id: ASSET.into(),
    }
}
fn prepare(id: &str, to: suwop_core::immich_visibility::ImmichVisibility) -> Event {
    Event::PrepareImmichVisibility {
        key: key(),
        to,
        operation_id: id.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
fn inspect() -> Event {
    Event::InspectImmichVisibility {
        record_id: OP.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
fn opened(protected: bool) -> Result<(Core<Suwop>, Shell), String> {
    let c = core(protected);
    let mut shell = Shell {
        confirmed: true,
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    Ok((c, shell))
}
#[test]
fn durable_unknown_precedes_one_write_and_anonymous_history() -> Result<(), String> {
    use suwop_core::immich_visibility::{AlbumMembershipObservation, ImmichVisibility};
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.writes, 1);
    let view = c.view();
    let summary = &view.immich_visibility_view.history.ok_or("history")?[0];
    assert_eq!(
        summary.outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Applied
    );
    assert_eq!(
        summary.album_membership_observation,
        AlbumMembershipObservation::NoAccessibleMemberships
    );
    let journal = &shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"];
    assert!(!journal.to_string().contains("PRIVATE"));
    assert!(!journal.to_string().contains("secret"));
    shell.run(&c, Event::CloseImmichLocked)?;
    assert!(c.view().immich_visibility_view.history.is_none());
    assert!(
        !serde_json::to_string(&c.view())
            .map_err(|_| "encode")?
            .contains(ASSET)
    );
    Ok(())
}
#[test]
fn lost_response_blocks_new_uuid_until_explicit_inspection() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.write_fault = WriteFault::LostNotApplied;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let disk = shell.disk.as_ref().ok_or("disk")?;
    assert_eq!(disk["immichVisibilityOperations"][0]["outcome"], "unknown");
    assert!(disk["immichVisibilityOperations"][0]["observation"].is_null());
    let state: suwop_core::app::SavedLibrary =
        serde_json::from_value(disk.clone()).map_err(|_| "decode")?;
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    shell.run(&c, prepare(NEXT, ImmichVisibility::Locked))?;
    assert_eq!(shell.writes, 1);
    shell.run(&c, inspect())?;
    assert_eq!(
        shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["observation"],
        "timeline"
    );
    let state: suwop_core::app::SavedLibrary =
        serde_json::from_value(shell.disk.as_ref().ok_or("disk")?.clone()).map_err(|_| "decode")?;
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    shell.write_fault = WriteFault::None;
    shell.run(&c, prepare(NEXT, ImmichVisibility::Locked))?;
    assert_eq!(shell.writes, 2);
    Ok(())
}
#[test]
fn cancelled_protected_or_linked_source_never_writes() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    for mode in 0..3 {
        let (c, mut shell) = opened(mode == 1)?;
        if mode == 0 {
            shell.confirmed = false;
        }
        if mode == 2 {
            shell.relationship = Some(json!("99999999-9999-4999-8999-999999999999"));
        }
        shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
        assert_eq!(shell.writes, 0);
        assert_eq!(shell.persist_calls, 0);
    }
    Ok(())
}
#[test]
fn ambiguous_initial_persist_fences_every_ordinary_mutation_until_recovery() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.fail_persist = Some(1);
    shell.read_fail = true;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.writes, 0);
    assert!(c.view().immich_visibility_view.persistence_uncertain);
    assert!(!c.view().can_transfer);
    shell.run(
        &c,
        Event::SetFavorite {
            keys: vec![key()],
            value: true,
        },
    )?;
    assert_eq!(shell.ordinary_writes, 0);
    assert_eq!(shell.persist_calls, 1);
    shell.run(
        &c,
        Event::RecoverImmichVisibilityState {
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(c.view().immich_visibility_view.persistence_uncertain);
    Ok(())
}
#[test]
fn lock_unlock_cycle_updates_all_history_without_releasing_stale_scan() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    shell.run(&c, prepare(NEXT, ImmichVisibility::Archive))?;
    assert_eq!(shell.writes, 2);
    let disk = shell.disk.as_ref().ok_or("disk")?;
    for record in disk["immichVisibilityOperations"]
        .as_array()
        .ok_or("records")?
    {
        assert_eq!(record["observation"], "archive");
    }
    let state: SavedLibrary = serde_json::from_value(disk.clone()).map_err(|_| "decode")?;
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    Ok(())
}
#[test]
fn explicit_unlocked_observation_requires_matching_fresh_full_scan() -> Result<(), String> {
    use suwop_core::immich_visibility::{
        AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
    };
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    shell.visibility = Some("timeline".into());
    shell.run(&c, inspect())?;
    let mut state: SavedLibrary =
        serde_json::from_value(shell.disk.ok_or("disk")?).map_err(|_| "decode")?;
    let native: suwop_core::immich::Asset = serde_json::from_value(asset()).map_err(|_| "asset")?;
    let mut record = native.record(&key().scope, None, None);
    record.inventory_complete = true;
    state.snapshots = vec![suwop_core::domain::LibrarySnapshot {
        provider: Provider::Immich,
        scope: key().scope,
        assets: vec![record.clone()],
        access: suwop_core::domain::ScanAccess::Full,
        scanned_at: Some(1.0),
    }];
    assert!(!suwop_core::immich_visibility::fences(&state, &key()));
    state.albums = vec![suwop_core::albums::AlbumSnapshot {
        provider: Provider::Immich,
        scope: key().scope,
        access: suwop_core::domain::ScanAccess::Unavailable,
        albums: vec![suwop_core::albums::StoredAlbum {
            key: suwop_core::albums::AlbumKey {
                provider: Provider::Immich,
                scope: key().scope,
                album_id: NEXT.into(),
            },
            title: "Previously joined".into(),
            members: vec![key()],
            permissions: suwop_core::albums::AlbumPermissions::default(),
        }],
    }];
    let projection = Core::new_with(
        Suwop,
        Model {
            state: state.clone(),
            ready: true,
            ..Model::default()
        },
    );
    assert!(
        projection.view().state.albums[0].albums[0]
            .members
            .is_empty()
    );
    state.snapshots[0].assets[0].resources[0].sha1 = Some("b".repeat(40));
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    state.snapshots[0].assets[0] = record;
    state
        .immich_visibility_operations
        .push(ImmichVisibilityOperation {
            kind: suwop_core::immich_visibility::ImmichVisibilityOperationKind::LockedTransition,
            id: NEXT.into(),
            scope: key().scope,
            key: key(),
            witness_digest: "c".repeat(64),
            from: ImmichVisibility::Timeline,
            to: ImmichVisibility::Locked,
            outcome: suwop_core::apple_visibility::VisibilityOutcome::Unknown,
            observation: None,
            album_membership_observation: AlbumMembershipObservation::NotChecked,
            selected_observation: None,
        });
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    Ok(())
}
#[test]
fn ordinary_http_proofs_are_origin_bound_and_never_hide_mutation_outcomes() -> Result<(), String> {
    use suwop_core::immich::{OrdinaryContentAuthorization, OrdinaryContentPurpose};
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: Some(OrdinaryContentAuthorization {
            source_keys: vec![key()],
            expected_revision: "captured-before-fence".into(),
            purpose: OrdinaryContentPurpose::Read,
        }),
        endpoint: "https://fixture.example/api".into(),
        key: "key".into(),
        user_id: OWNER.into(),
        scope: key().scope,
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let read = session.preview_request(ASSET, true)?;
    assert_eq!(
        read.ordinary_content_authorization
            .ok_or("proof")?
            .expected_revision,
        "captured-before-fence"
    );
    assert!(
        session
            .request(
                &format!("assets/{ASSET}"),
                "PUT",
                Some(json!({"isFavorite":true}))
            )
            .ordinary_content_authorization
            .is_none()
    );
    assert!(
        session
            .request(&format!("asset-files?assetId={ASSET}"), "GET", None)
            .ordinary_content_authorization
            .is_none()
    );
    Ok(())
}
#[test]
fn schema_five_migration_preserves_fences_and_rejects_duplicate_ids() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let mut raw = shell.disk.ok_or("disk")?;
    raw["schemaVersion"] = json!(5);
    let state = suwop_core::workflow::migrate(raw.clone())?;
    assert_eq!(state.schema_version, 8);
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    let record = raw["immichVisibilityOperations"][0].clone();
    raw["immichVisibilityOperations"]
        .as_array_mut()
        .ok_or("records")?
        .push(record);
    assert!(suwop_core::workflow::migrate(raw).is_err());
    Ok(())
}
#[test]
fn lost_applied_and_contradictory_responses_require_explicit_inspection() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    for fault in [WriteFault::LostApplied, WriteFault::Contradictory] {
        let (c, mut shell) = opened(false)?;
        shell.write_fault = fault;
        shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
        let operation = &shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0];
        assert_eq!(operation["outcome"], "unknown");
        assert!(operation["observation"].is_null());
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
#[test]
fn failed_final_save_keeps_durable_unknown_and_reports_not_saved() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.fail_persist = Some(2);
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(
        shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["outcome"],
        "unknown"
    );
    assert!(
        c.view()
            .immich_visibility_view
            .status
            .as_deref()
            .is_some_and(|s| s.contains("保存できません"))
    );
    assert_eq!(shell.writes, 1);
    shell.run(&c, inspect())?;
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn atomic_write_lost_ack_can_be_recovered_without_replay_or_old_state_overwrite()
-> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.fail_persist = Some(1);
    shell.persist_after_failure = true;
    shell.read_fail = true;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert!(c.view().immich_visibility_view.persistence_uncertain);
    assert_eq!(shell.writes, 0);
    assert_eq!(
        shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["outcome"],
        "unknown"
    );
    shell.read_fail = false;
    shell.run(
        &c,
        Event::RecoverImmichVisibilityState {
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(!c.view().immich_visibility_view.persistence_uncertain);
    assert_eq!(shell.persist_calls, 1);
    assert_eq!(shell.writes, 0);
    assert_eq!(
        c.view().immich_visibility_view.history.ok_or("history")?[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    Ok(())
}
#[test]
fn private_receipts_and_exact_remote_content_disappear_but_same_hash_apple_remains()
-> Result<(), String> {
    use suwop_core::domain::{
        AppleVisibility, LibrarySnapshot, ScanAccess, TransferIntent, TransferPhase,
        TransferReceipt,
    };
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let mut state: SavedLibrary =
        serde_json::from_value(shell.disk.ok_or("disk")?).map_err(|_| "state")?;
    let native: suwop_core::immich::Asset = serde_json::from_value(asset()).map_err(|_| "asset")?;
    let remote = native.record(&key().scope, None, None);
    let mut apple = remote.clone();
    apple.key = AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: "independent-apple".into(),
    };
    apple.apple_visibility = AppleVisibility::Visible;
    apple.name = "public-apple.jpg".into();
    apple.resources[0].id = "apple-original".into();
    apple.resources[0].name = "public-apple.jpg".into();
    apple.inventory_complete = true;
    state.snapshots = vec![
        LibrarySnapshot {
            provider: Provider::Immich,
            scope: key().scope,
            assets: vec![remote.clone()],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        },
        LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: vec![apple.clone()],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        },
    ];
    let mixed = TransferReceipt {
        id: "private-receipt".into(),
        created_at: 1.0,
        intent: TransferIntent::Copy,
        phase: TransferPhase::Copied,
        source: vec![remote],
        destination: vec![apple.clone()],
        destination_provider: Provider::Apple,
        destination_scope: "apple".into(),
        signatures: std::collections::BTreeSet::new(),
    };
    let mut independent = mixed.clone();
    independent.id = "public-receipt".into();
    independent.source = vec![apple];
    state.receipts = vec![mixed, independent];
    let c = Core::new_with(
        Suwop,
        Model {
            state,
            ready: true,
            ..Model::default()
        },
    );
    let view = c.view();
    assert_eq!(view.state.receipts.len(), 1);
    assert_eq!(view.state.receipts[0].id, "public-receipt");
    assert!(
        view.ordinary_content_keys
            .iter()
            .any(|k| k.provider == Provider::Apple)
    );
    assert!(!view.ordinary_content_keys.contains(&key()));
    let json = serde_json::to_string(&view).map_err(|_| "json")?;
    assert!(!json.contains("PRIVATE-LOCKED"));
    assert!(!json.contains("private-receipt"));
    assert!(!json.contains(ASSET));
    Ok(())
}
#[test]
fn later_app_protection_hides_pin_history_and_blocks_inspection() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let state: SavedLibrary =
        serde_json::from_value(shell.disk.ok_or("disk")?).map_err(|_| "state")?;
    let c = core_operations(true, state.immich_visibility_operations);
    let mut shell = Shell::default();
    shell.run(&c, open(GRANT))?;
    assert!(
        c.view()
            .immich_visibility_view
            .history
            .ok_or("history")?
            .is_empty()
    );
    let reads = shell.paths.len();
    shell.run(&c, inspect())?;
    assert_eq!(reads, shell.paths.len());
    assert_eq!(shell.persist_calls, 0);
    Ok(())
}
#[test]
fn queued_read_cannot_renew_origin_generation_or_start_a_following_write() -> Result<(), String> {
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    let generation = Arc::new(AtomicU64::new(4));
    let session = Session {
        ordinary_content_guard: Some(suwop_core::immich::OrdinarySessionGuard {
            generation: generation.clone(),
            expected: 4,
        }),
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "key".into(),
        user_id: OWNER.into(),
        scope: key().scope,
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
        let result = session.favorite(&ctx, ASSET, true).await;
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
            preview_to_select: None,
        });
    });
    let effects = command.effects().collect::<Vec<_>>();
    assert_eq!(effects.len(), 1);
    generation.fetch_add(1, Ordering::SeqCst);
    for Effect::Io(mut request) in effects {
        let ShellOperation::Http(http) = &request.operation else {
            return Err("HTTP expected".into());
        };
        assert_eq!(http.method, "GET");
        request
            .resolve(ShellResponse {
                value: Some(json!({"status":200,"body":asset()})),
                error: None,
            })
            .map_err(|_| "resolve")?;
    }
    assert_eq!(command.effects().count(), 0);
    assert!(
        command
            .events()
            .any(|e| matches!(e, Event::Finished { error: Some(_), .. }))
    );
    Ok(())
}
#[test]
fn acknowledged_mutation_response_survives_generation_change_for_cleanup() -> Result<(), String> {
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    let generation = Arc::new(AtomicU64::new(4));
    let session = Session {
        ordinary_content_guard: Some(suwop_core::immich::OrdinarySessionGuard {
            generation: generation.clone(),
            expected: 4,
        }),
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "key".into(),
        user_id: OWNER.into(),
        scope: key().scope,
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
        let result = session
            .json::<Value>(
                &ctx,
                &format!("assets/{ASSET}"),
                "PUT",
                Some(json!({"isFavorite":true})),
            )
            .await;
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
            preview_to_select: None,
        });
    });
    let effects = command.effects().collect::<Vec<_>>();
    assert_eq!(effects.len(), 1);
    generation.fetch_add(1, Ordering::SeqCst);
    for Effect::Io(mut request) in effects {
        let ShellOperation::Http(http) = &request.operation else {
            return Err("HTTP expected".into());
        };
        assert_eq!(http.method, "PUT");
        assert!(http.ordinary_content_authorization.is_none());
        request
            .resolve(ShellResponse {
                value: Some(json!({"status":200,"body":{}})),
                error: None,
            })
            .map_err(|_| "resolve")?;
    }
    assert!(
        command
            .events()
            .any(|e| matches!(e, Event::Finished { error: None, .. }))
    );
    Ok(())
}
#[test]
fn closing_during_confirmation_cannot_create_intent_or_write() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    let mut effects = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let mut held = None;
    while !effects.is_empty() {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(
            request.operation,
            ShellOperation::ConfirmImmichVisibility { .. }
        ) {
            held = Some(request);
            break;
        }
        let value = shell.respond(&request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    let mut held = held.ok_or("confirmation")?;
    shell.run(&c, Event::CloseImmichLocked)?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!(true)),
                error: None,
            },
        )
        .map_err(|_| "resolve")?;
    shell.drain(&c, effects)?;
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.writes, 0);
    assert!(c.view().immich_visibility_view.history.is_none());
    Ok(())
}
#[test]
fn unknown_relationship_stack_and_identity_facts_fail_before_intent() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    for patch in [
        json!({"stack":{"id":NEXT}}),
        json!({"checksum":"invalid"}),
        json!({"ownerId":NEXT}),
        json!({"isOffline":true}),
    ] {
        let (c, mut shell) = opened(false)?;
        shell.facts_patch = Some(patch);
        shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
        assert_eq!(shell.persist_calls, 0);
        assert_eq!(shell.writes, 0);
    }
    let (c, mut shell) = opened(false)?;
    shell.omit_field = Some("livePhotoVideoId".into());
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.writes, 0);
    Ok(())
}
#[test]
fn wrong_scope_scene_uuid_and_reused_operation_do_not_fetch_or_write() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    for mode in 0..3 {
        let mut event = prepare(OP, ImmichVisibility::Locked);
        if let Event::PrepareImmichVisibility {
            key,
            scene_id,
            operation_id,
            ..
        } = &mut event
        {
            match mode {
                0 => key.scope = "other-account".into(),
                1 => *scene_id = NEXT.into(),
                _ => *operation_id = "invalid".into(),
            }
        }
        let reads = shell.paths.len();
        shell.run(&c, event)?;
        assert_eq!(reads, shell.paths.len());
    }
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.writes, 1);
    let reads = shell.paths.len();
    shell.run(&c, prepare(OP, ImmichVisibility::Archive))?;
    assert_eq!(reads, shell.paths.len());
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn transient_app_denial_blocks_prepare_even_without_uncertainty_flag() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let c = core_denials(false, vec![], [key()].into());
    let mut shell = Shell {
        confirmed: true,
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    let reads = shell.paths.len();
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert_eq!(shell.paths.len(), reads);
    assert_eq!(shell.writes, 0);
    assert_eq!(shell.persist_calls, 0);
    Ok(())
}
#[test]
fn public_content_revision_has_no_same_key_set_aba() {
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    let generation = Arc::new(AtomicU64::new(0));
    let c = Core::new_with(
        Suwop,
        Model {
            ordinary_generation: generation.clone(),
            ..Model::default()
        },
    );
    let first = c.view();
    generation.fetch_add(1, Ordering::SeqCst);
    let fenced = c.view();
    generation.fetch_add(1, Ordering::SeqCst);
    let recovered = c.view();
    assert_eq!(first.ordinary_content_keys, recovered.ordinary_content_keys);
    assert_ne!(
        first.private_content_revision,
        fenced.private_content_revision
    );
    assert_ne!(
        first.private_content_revision,
        recovered.private_content_revision
    );
}
#[test]
fn submitted_put_close_and_late_success_preserve_unknown_without_replay() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    let mut effects = c.process_event(prepare(OP, ImmichVisibility::Locked));
    let mut submitted = None;
    while !effects.is_empty() {
        let Effect::Io(mut request) = effects.remove(0);
        let value = shell.respond(&request.operation)?;
        if matches!(&request.operation,ShellOperation::Http(http) if http.method=="PUT" && http.url.ends_with("/assets"))
        {
            submitted = Some((request, value));
            break;
        }
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    assert_eq!(shell.writes, 1);
    let (mut submitted, value) = submitted.ok_or("submitted PUT")?;
    shell.run(&c, Event::CloseImmichLocked)?;
    let effects = c
        .resolve(
            &mut submitted,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "resolve")?;
    shell.drain(&c, effects)?;
    let operation = &shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0];
    assert_eq!(operation["outcome"], "unknown");
    assert!(operation["observation"].is_null());
    assert_eq!(shell.writes, 1);
    assert!(c.view().immich_visibility_view.history.is_none());
    Ok(())
}

#[test]
fn verified_roster_changes_are_immediate_and_unknown_waits_for_explicit_inspect()
-> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let (c, mut shell) = opened(false)?;
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("entries")?
            .is_empty()
    );
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    let entries = c
        .view()
        .immich_locked_view
        .entries
        .ok_or("locked entries")?;
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, ASSET);
    assert!(entries[0].visibility_action.can_show_timeline);
    shell.run(&c, prepare(NEXT, ImmichVisibility::Archive))?;
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("unlocked entries")?
            .is_empty()
    );
    assert_eq!(shell.writes, 2);
    let (c, mut shell) = opened(false)?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("unknown entries")?
            .is_empty()
    );
    shell.run(&c, inspect())?;
    assert_eq!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("observed entries")?
            .len(),
        1
    );
    let operation = &shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0];
    assert_eq!(operation["outcome"], "unknown");
    assert_eq!(operation["observation"], "locked");
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn cancelling_keeps_cached_locked_entry_but_failed_confirmed_change_removes_it()
-> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    for fail in [false, true] {
        let c = core(false);
        let mut locked = asset();
        locked["visibility"] = json!("locked");
        let mut shell = Shell {
            confirmed: false,
            visibility: Some("locked".into()),
            pages: Some(std::collections::VecDeque::from([
                json!({"assets":{"items":[locked],"nextCursor":null}}),
            ])),
            ..Shell::default()
        };
        shell.run(&c, open(GRANT))?;
        assert_eq!(
            c.view().immich_locked_view.entries.ok_or("initial")?.len(),
            1
        );
        shell.run(&c, prepare(OP, ImmichVisibility::Timeline))?;
        assert_eq!(
            c.view()
                .immich_locked_view
                .entries
                .ok_or("cancelled")?
                .len(),
            1
        );
        assert_eq!(shell.writes, 0);
        shell.confirmed = true;
        if fail {
            shell.fail_persist = Some(2);
        }
        shell.run(&c, prepare(NEXT, ImmichVisibility::Timeline))?;
        assert!(
            c.view()
                .immich_locked_view
                .entries
                .ok_or("confirmed")?
                .is_empty()
        );
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}

fn locked_page() -> Value {
    let mut item = asset();
    item["visibility"] = json!("locked");
    json!({"assets":{"items":[item],"nextCursor":null}})
}
fn refresh() -> Event {
    Event::RefreshImmichLocked {
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn same_session_refresh_recovers_known_unsubmitted_failure_but_not_unknown() -> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    let c = core(false);
    let mut shell = Shell {
        confirmed: true,
        visibility: Some("locked".into()),
        pages: Some(std::collections::VecDeque::from([locked_page()])),
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    let before = SavedLibrary {
        schema_version: 8,
        apple_scope: "apple".into(),
        connection: Some(ConnectionSettings {
            address: "https://fixture.example/api".into(),
            allow_http: false,
            credential_id: "ordinary-credential".into(),
        }),
        ..SavedLibrary::default()
    };
    shell.disk = Some(serde_json::to_value(before).map_err(|_| "before")?);
    shell.fail_persist = Some(1);
    shell.run(&c, prepare(OP, ImmichVisibility::Timeline))?;
    assert_eq!(shell.writes, 0);
    assert!(!c.view().immich_visibility_view.persistence_uncertain);
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("before refresh")?
            .is_empty()
    );
    shell.pages = Some(std::collections::VecDeque::from([locked_page()]));
    shell.run(&c, refresh())?;
    assert_eq!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("refreshed")?
            .len(),
        1
    );
    assert_eq!(shell.writes, 0);
    let (c, mut shell) = opened(false)?;
    shell.write_fault = WriteFault::LostApplied;
    shell.run(&c, prepare(OP, ImmichVisibility::Locked))?;
    shell.pages = Some(std::collections::VecDeque::from([locked_page()]));
    shell.run(&c, refresh())?;
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("unknown refreshed")?
            .is_empty()
    );
    assert!(
        shell.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["observation"]
            .is_null()
    );
    shell.run(&c, inspect())?;
    assert_eq!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("inspected")?
            .len(),
        1
    );
    assert_eq!(shell.writes, 1);
    Ok(())
}
#[test]
fn refresh_failure_is_separate_retryable_and_late_response_cannot_publish() -> Result<(), String> {
    let (c, mut shell) = opened(false)?;
    shell.fail_status = Some(shell.status_reads + 1);
    shell.run(&c, refresh())?;
    assert!(c.view().immich_locked_view.error.is_some());
    assert!(c.view().immich_visibility_view.status.is_none());
    shell.pages = Some(std::collections::VecDeque::from([locked_page()]));
    shell.run(&c, refresh())?;
    assert_eq!(c.view().immich_locked_view.entries.ok_or("retry")?.len(), 1);
    shell.pages = Some(std::collections::VecDeque::from([locked_page()]));
    let mut effects = c.process_event(refresh());
    let mut held = None;
    while !effects.is_empty() {
        let Effect::Io(mut effect) = effects.remove(0);
        let value = shell.respond(&effect.operation)?;
        if matches!(&effect.operation,ShellOperation::Http(r) if r.url.ends_with("/search/metadata"))
        {
            held = Some((effect, value));
            break;
        }
        effects.extend(
            c.resolve(
                &mut effect,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .ok_or("pending")?
            .is_empty()
    );
    shell.run(&c, Event::CloseImmichLocked)?;
    let (mut held, value) = held.ok_or("held inventory")?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "late resolve")?;
    shell.drain(&c, effects)?;
    assert!(c.view().immich_locked_view.entries.is_none());
    assert!(!c.view().busy);
    assert_eq!(shell.writes, 0);
    Ok(())
}

#[test]
fn old_refresh_completion_never_releases_new_session_work_busy() -> Result<(), String> {
    let (c, mut shell) = opened(false)?;
    let mut effects = c.process_event(refresh());
    let mut old = None;
    while !effects.is_empty() {
        let Effect::Io(mut request) = effects.remove(0);
        let value = shell.respond(&request.operation)?;
        if matches!(&request.operation,ShellOperation::Http(r) if r.url.ends_with("/search/metadata"))
        {
            old = Some((request, value));
            break;
        }
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    shell.run(&c, Event::CloseImmichLocked)?;
    assert!(!c.view().busy);
    shell.run(&c, open(NEXT))?;
    assert_eq!(c.view().immich_locked_view.grant_id.as_deref(), Some(NEXT));
    let new_work = c.process_event(Event::RefreshImmichLocked {
        grant_id: NEXT.into(),
        scene_id: SCENE.into(),
    });
    assert!(c.view().busy);
    let (mut old, value) = old.ok_or("old refresh")?;
    let effects = c
        .resolve(
            &mut old,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "old resolve")?;
    shell.drain(&c, effects)?;
    assert!(c.view().busy);
    assert_eq!(c.view().immich_locked_view.grant_id.as_deref(), Some(NEXT));
    shell.drain(&c, new_work)?;
    assert!(!c.view().busy);
    Ok(())
}

#[test]
fn ordinary_inspect_preserves_authenticated_locked_roster_and_selected_image() -> Result<(), String>
{
    use suwop_core::immich_visibility::{
        AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
        ImmichVisibilityOperationKind,
    };
    let old = ImmichVisibilityOperation {
        kind: ImmichVisibilityOperationKind::OrdinaryArchive,
        id: OP.into(),
        scope: key().scope,
        key: key(),
        witness_digest: "a".repeat(64),
        from: ImmichVisibility::Timeline,
        to: ImmichVisibility::Archive,
        outcome: suwop_core::apple_visibility::VisibilityOutcome::Applied,
        observation: Some(ImmichVisibility::Archive),
        album_membership_observation: AlbumMembershipObservation::NotChecked,
        selected_observation: None,
    };
    let c = core_operations(false, vec![old]);
    let mut locked = asset();
    locked["visibility"] = json!("locked");
    let mut shell = Shell {
        visibility: Some("locked".into()),
        pages: Some(std::collections::VecDeque::from([
            json!({"assets":{"items":[locked],"nextCursor":null}}),
        ])),
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    shell.run(
        &c,
        Event::RequestImmichLockedImage {
            entry_id: ASSET.into(),
            grant_id: GRANT.into(),
            request_id: NEXT.into(),
        },
    )?;
    let before = c.view().immich_locked_view;
    assert_eq!(before.entries.as_ref().ok_or("entries")?.len(), 1);
    assert!(before.image.is_some());
    let before_json = serde_json::to_value(&before).map_err(|e| e.to_string())?;
    activate_archive(&mut shell, &c)?;
    let status_reads = shell.status_reads;
    let paths = shell.paths.len();
    shell.run(
        &c,
        Event::InspectImmichArchive {
            record_id: OP.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(
        serde_json::to_value(c.view().immich_locked_view).map_err(|e| e.to_string())?,
        before_json
    );
    assert_eq!(shell.ordinary_reads, 1);
    assert_eq!(shell.status_reads, status_reads);
    assert_eq!(&shell.paths[paths..], &[format!("assets/{ASSET}")]);
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.writes, 0);
    assert_eq!(shell.ordinary_writes, 0);
    assert_eq!(shell.stages, 1);
    assert!(shell.releases.is_empty());
    assert!(shell.disk.is_none());
    Ok(())
}

#[test]
fn ordinary_unknown_does_not_deny_pin_reads_but_keeps_mutation_fence_after_restart()
-> Result<(), String> {
    use suwop_core::immich_visibility::{
        AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
        ImmichVisibilityOperationKind,
    };
    for kind in [
        ImmichVisibilityOperationKind::OrdinaryArchive,
        ImmichVisibilityOperationKind::LockedTransition,
    ] {
        for restart in [false, true] {
            let ordinary = kind == ImmichVisibilityOperationKind::OrdinaryArchive;
            let operation = ImmichVisibilityOperation {
                kind,
                id: OP.into(),
                scope: key().scope,
                key: key(),
                witness_digest: "a".repeat(64),
                from: ImmichVisibility::Timeline,
                to: if ordinary {
                    ImmichVisibility::Archive
                } else {
                    ImmichVisibility::Locked
                },
                outcome: suwop_core::apple_visibility::VisibilityOutcome::Unknown,
                observation: None,
                album_membership_observation: AlbumMembershipObservation::NotChecked,
                selected_observation: None,
            };
            let mut operations = vec![operation];
            if restart {
                let persisted = SavedLibrary {
                    schema_version: 8,
                    immich_visibility_operations: operations,
                    ..SavedLibrary::default()
                };
                let raw = serde_json::to_value(persisted).map_err(|e| e.to_string())?;
                let loaded = suwop_core::workflow::migrate(raw)?;
                assert!(suwop_core::immich_visibility::fences(&loaded, &key()));
                operations = loaded.immich_visibility_operations;
            }
            let c = core_operations(false, operations);
            let mut locked = asset();
            locked["visibility"] = json!("locked");
            let mut shell = Shell {
                visibility: Some("locked".into()),
                pages: Some(std::collections::VecDeque::from([
                    json!({"assets":{"items":[locked],"nextCursor":null}}),
                ])),
                ..Shell::default()
            };
            activate_archive(&mut shell, &c)?;
            shell.run(&c, open(GRANT))?;
            let entries = c.view().immich_locked_view.entries.ok_or("PIN entries")?;
            assert_eq!(
                entries.len(),
                usize::from(ordinary),
                "kind={kind:?}, restart={restart}"
            );
            shell.run(
                &c,
                Event::RequestImmichLockedImage {
                    entry_id: ASSET.into(),
                    grant_id: GRANT.into(),
                    request_id: NEXT.into(),
                },
            )?;
            assert_eq!(c.view().immich_locked_view.image.is_some(), ordinary);
            assert_eq!(shell.stages, usize::from(ordinary));
            if ordinary {
                let action = &entries[0].visibility_action;
                assert!(!action.can_show_timeline && !action.can_show_archive && !action.can_lock);
                assert_eq!(
                    action.reason,
                    Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unknown)
                );
                let history = c
                    .view()
                    .immich_archive_view
                    .history
                    .ok_or("ordinary history")?;
                assert_eq!(
                    history[0].outcome,
                    suwop_core::apple_visibility::VisibilityOutcome::Unknown
                );
                assert_eq!(history[0].observation, None);
            }

            let paths = shell.paths.len();
            shell.run(&c, prepare(NEXT, ImmichVisibility::Timeline))?;
            assert_eq!(shell.paths.len(), paths, "unknown write fence must remain");
            assert_eq!(shell.persist_calls, 0);
            assert_eq!(shell.writes, 0);
            assert!(shell.disk.is_none());
        }
    }
    Ok(())
}

fn activate_archive(shell: &mut Shell, core: &Core<Suwop>) -> Result<(), String> {
    shell.run(
        core,
        Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
    )?;
    shell.run(
        core,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )
}

fn drain_until(
    core: &Core<Suwop>,
    shell: &mut Shell,
    mut effects: Vec<Effect>,
    stop: fn(&ShellOperation) -> bool,
) -> Result<Vec<Effect>, String> {
    while !effects.is_empty() {
        let Effect::Io(mut request) = effects.remove(0);
        if stop(&request.operation) {
            effects.insert(0, Effect::Io(request));
            return Ok(effects);
        }
        let result = shell.respond(&request.operation);
        effects.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: result.as_ref().ok().cloned(),
                    error: result.err(),
                },
            )
            .map_err(|e| e.to_string())?,
        );
    }
    Err("expected effect boundary".into())
}
fn check_ordinary_prepared_preserves_other_key(pending: bool) -> Result<(), String> {
    let c = core(false);
    let mut locked = asset();
    locked["visibility"] = json!("locked");
    let mut shell = Shell {
        visibility: Some("locked".into()),
        pages: Some(std::collections::VecDeque::from([
            json!({"assets":{"items":[locked],"nextCursor":null}}),
        ])),
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    activate_archive(&mut shell, &c)?;
    let image_event = Event::RequestImmichLockedImage {
        entry_id: ASSET.into(),
        grant_id: GRANT.into(),
        request_id: NEXT.into(),
    };
    let mut held = if pending {
        drain_until(&c, &mut shell, c.process_event(image_event), |op| {
            matches!(op, ShellOperation::ReadImmichLockedImage { .. })
        })?
    } else {
        shell.run(&c, image_event)?;
        vec![]
    };
    let before = c.view().immich_locked_view;
    assert_eq!(before.image.is_some(), !pending);
    let mut ordinary = asset();
    ordinary["id"] = json!("99999999-9999-4999-8999-999999999999");
    let target = AssetKey {
        asset_id: ordinary["id"].as_str().ok_or("ordinary id")?.into(),
        ..key()
    };
    shell.ordinary_asset = Some(ordinary);
    let _persist = drain_until(
        &c,
        &mut shell,
        c.process_event(Event::PrepareImmichArchive {
            key: target,
            to: suwop_core::immich_archive::ImmichArchiveDestination::Archive,
            operation_id: OP.into(),
            scene_id: SCENE.into(),
        }),
        |op| matches!(op, ShellOperation::Persist(_)),
    )?;
    let after = c.view().immich_locked_view;
    assert_eq!(after.image, before.image);
    assert_eq!(
        serde_json::to_value(after.entries).map_err(|e| e.to_string())?,
        serde_json::to_value(before.entries).map_err(|e| e.to_string())?
    );
    assert_eq!(after.grant_id, before.grant_id);
    if pending {
        let Effect::Io(mut read) = held.remove(0);
        assert!(matches!(
            read.operation,
            ShellOperation::ReadImmichLockedImage { .. }
        ));
        let value = shell.respond(&read.operation)?;
        let publication = c
            .resolve(
                &mut read,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|e| e.to_string())?;
        let publication = drain_until(&c, &mut shell, publication, |op| {
            matches!(
                op,
                ShellOperation::PublishImmichLockedImage { .. }
                    | ShellOperation::ReleaseImmichLockedImage { .. }
            )
        })?;
        assert!(publication.iter().any(|effect| matches!(effect, Effect::Io(io) if matches!(io.operation, ShellOperation::PublishImmichLockedImage { .. }))), "unrelated pending read must remain authorized for publication");
    }
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.ordinary_writes, 0);

    Ok(())
}

#[test]
fn ordinary_prepared_preserves_other_key_locked_image() -> Result<(), String> {
    check_ordinary_prepared_preserves_other_key(false)
}
#[test]
fn ordinary_prepared_preserves_other_key_pending_read() -> Result<(), String> {
    check_ordinary_prepared_preserves_other_key(true)
}

#[test]
fn old_release_pin_direct_video_lock_and_unlock_never_confirm_persist_or_write()
-> Result<(), String> {
    use suwop_core::immich_visibility::ImmichVisibility;
    for to in [
        ImmichVisibility::Locked,
        ImmichVisibility::Timeline,
        ImmichVisibility::Archive,
    ] {
        let c = core(false);
        let mut shell = Shell {
            confirmed: true,
            versions: [json!({"major":3,"minor":2,"patch":4,"prerelease":null})].into(),
            ..Shell::default()
        };
        shell.facts_patch = Some(json!({"type":"VIDEO"}));
        shell.run(&c, open(GRANT))?;
        if to != ImmichVisibility::Locked {
            shell.visibility = Some("locked".into());
        }
        shell.run(&c, prepare(OP, to))?;
        assert_eq!(shell.confirmations, 0);
        assert_eq!(shell.writes, 0);
        assert_eq!(shell.persist_calls, 0);
    }
    Ok(())
}

#[path = "immich_visibility/selected_observation.rs"]
mod selected_observation;

#[path = "immich_visibility/write_contract.rs"]
mod write_contract;

#[path = "immich_visibility/ordinary_selected.rs"]
mod ordinary_selected;

#[path = "immich_visibility/selected_video.rs"]
mod selected_video;

#[path = "immich_visibility/live_resources.rs"]
mod live_resources;
