use super::*;
use crate::{
    app::{Effect, ShellResponse, Suwop},
    immich::Session,
    immich_locked::{DedicatedSession, ImmichLockedEntry, ImmichLockedState, Secret},
    protection::ProtectionScenePhase,
};
use crux_core::Core;
use serde_json::json;
use std::sync::atomic::Ordering;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const ID: &str = "33333333-3333-4333-8333-333333333333";
const REQUEST: &str = "44444444-4444-4444-8444-444444444444";
const LEASE: &str = "55555555-5555-4555-8555-555555555555";
fn raw() -> Value {
    json!({"id":ID,"ownerId":"owner","type":"VIDEO","originalFileName":"private.mov","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"locked","livePhotoVideoId":null,"stack":null,"exifInfo":{"fileSizeInByte":123}})
}
fn model(raw: &Value) -> Result<Model, String> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "ordinary-secret".into(),
        user_id: "owner".into(),
        scope: "scope".into(),
        version: crate::immich::Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let asset: Asset = serde_json::from_value(raw.clone()).map_err(|_| "fixture")?;
    let asset = asset.record("scope", None, None);
    let mut model = Model::default();
    model.state.schema_version = 8;
    model.state.connection = Some(crate::app::ConnectionSettings {
        address: session.endpoint.clone(),
        allow_http: false,
        credential_id: "fixture".into(),
    });
    model.ready = true;
    model.session = Some(session.clone());
    model.immich_locked.session = Some(DedicatedSession {
        ordinary: session,
        token: Secret("dedicated-secret".into()),
        write_contract: None,
    });
    model.immich_locked.state = ImmichLockedState::Open;
    model.immich_locked.phase = ProtectionScenePhase::Active;
    model.immich_locked.active_scene = Some(SCENE.into());
    model.immich_locked.scene_id = Some(SCENE.into());
    model.immich_locked.grant_id = Some(GRANT.into());
    model.immich_locked.hard_deadline =
        Some(std::time::Instant::now() + std::time::Duration::from_mins(15));
    model.immich_locked.lease_deadline =
        Some(std::time::Instant::now() + std::time::Duration::from_secs(30));
    model.immich_locked.entries.push(ImmichLockedEntry {
        can_play_video: false,
        id: ID.into(),
        visibility_action: crate::immich_visibility::locked_action(asset.key.clone()),
        asset,
    });
    Ok(model)
}
fn core(raw: &Value) -> Result<Core<Suwop>, String> {
    Ok(Core::new_with(Suwop, model(raw)?))
}
fn request() -> Event {
    Event::RequestImmichLockedVideo {
        entry_id: ID.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
        request_id: REQUEST.into(),
    }
}
struct Shell {
    raw: Value,
    storage: ImmichLockedVideoStorageFacts,
    reads: usize,
    prepares: usize,
    releases: Vec<String>,
    fail_prepare: bool,
    bad_hash: bool,
    post_read_drift: bool,
    paths: Vec<String>,
    last_ticket: Option<ImmichLockedVideoTicket>,
    status_calls: usize,
    fail_status: Option<usize>,
    renewals: usize,
}
impl Shell {
    fn new(raw: Value) -> Self {
        Self {
            raw,
            storage: ImmichLockedVideoStorageFacts {
                lease_id: LEASE.into(),
                measurement_nonce: "66666666-6666-4666-8666-666666666666".into(),
                deadline_unix_milliseconds: u64::MAX,
                available_bytes: policy::PRIVATE_VIDEO_HEADROOM_BYTES + 1024 * 1024,
                other_unallocated_bytes: 0,
                allocation_unit_bytes: 4096,
                capacity_class: ImmichLockedVideoCapacityClass::Available,
            },
            reads: 0,
            prepares: 0,
            releases: vec![],
            fail_prepare: false,
            bad_hash: false,
            post_read_drift: false,
            paths: vec![],
            last_ticket: None,
            status_calls: 0,
            fail_status: None,
            renewals: 0,
        }
    }
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(request) => {
                assert!(request.headers.contains_key("Authorization"));
                assert!(!request.headers.contains_key("x-api-key"));
                self.paths.push(request.url.clone());
                let body = if request.url.ends_with("/auth/status") {
                    self.status_calls += 1;
                    if self.fail_status == Some(self.status_calls) {
                        return Err("controlled status failure".into());
                    }
                    json!({"isElevated":true,"pinCode":true})
                } else if request.url.ends_with(&format!("/assets/{ID}")) {
                    self.raw.clone()
                } else if request.url.ends_with("/auth/session/lock")
                    || request.url.ends_with("/auth/logout")
                {
                    Value::Null
                } else {
                    return Err("unexpected route".into());
                };
                Ok(json!({"status":200,"body":body}))
            }
            ShellOperation::InspectImmichLockedVideoStorage { .. } => {
                serde_json::to_value(&self.storage).map_err(|_| "storage".into())
            }
            ShellOperation::ReadImmichLockedVideo { ticket } => {
                assert_eq!(
                    ticket.request.url,
                    format!("https://fixture.example/api/assets/{ID}/original?edited=false")
                );
                assert_eq!(
                    ticket
                        .request
                        .headers
                        .get("Accept-Encoding")
                        .map(String::as_str),
                    Some("identity")
                );
                assert_eq!(ticket.storage.lease_id, LEASE);
                self.reads += 1;
                if self.post_read_drift {
                    self.raw["visibility"] = json!("timeline");
                }
                Ok(
                    json!({"acquisitionLeaseID":ticket.acquisition_lease.lease_id,"requestID":REQUEST,"stagedID":LEASE,"sha1":if self.bad_hash {"b".repeat(40)} else {"a".repeat(40)},"signature":{"sha256":"c".repeat(64),"bytes":123}}),
                )
            }
            ShellOperation::PrepareImmichLockedVideo { ticket, staged_id } => {
                self.last_ticket = Some(ticket.clone());
                self.prepares += 1;
                assert_eq!(staged_id, &ticket.storage.lease_id);
                if self.fail_prepare {
                    return Err("fixture prepare failure".into());
                }
                Ok(
                    json!({"acquisitionLeaseID":ticket.acquisition_lease.lease_id,"requestID":REQUEST,"stagedID":LEASE}),
                )
            }
            ShellOperation::ReleaseImmichLockedVideo { pending, lease_id } => {
                assert_eq!(pending.request_id, REQUEST);
                self.releases.push(lease_id.clone());
                Ok(Value::Null)
            }
            ShellOperation::RenewImmichLockedVideoAcquisition {
                ticket,
                previous_lease_id,
                lease,
            } => {
                self.renewals += 1;
                Ok(
                    json!({"requestID":ticket.pending.request_id,"stagedID":ticket.storage.lease_id,"previousLeaseID":previous_lease_id,"leaseID":lease.lease_id}),
                )
            }
            ShellOperation::ScheduleImmichLockedVideoAcquisitionExpiry { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ReleaseImmichLockedVideos { .. } => Ok(Value::Null),
            _ => Err("unexpected privileged effect".into()),
        }
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut req) = effects.remove(0);
            let response = match self.respond(&req.operation) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(c.resolve(&mut req, response).map_err(|_| "resolve")?);
        }
        Ok(())
    }
    fn run(&mut self, c: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.drain(c, c.process_event(event))
    }
}
#[test]
fn complete_known_and_absent_size_video_requires_hidden_prepare_and_final_rust_approval()
-> Result<(), String> {
    for absent in [false, true] {
        let mut raw = raw();
        if absent {
            raw["exifInfo"]
                .as_object_mut()
                .ok_or("exif")?
                .remove("fileSizeInByte");
        }
        let c = core(&raw)?;
        let mut shell = Shell::new(raw);
        assert!(
            c.view()
                .immich_locked_view
                .entries
                .as_ref()
                .ok_or("entries")?[0]
                .can_play_video
        );
        shell.run(&c, request())?;
        let ticket = shell.last_ticket.as_ref().ok_or("read ticket")?;
        assert_eq!(
            ticket.commitment_mode,
            if absent {
                ImmichLockedVideoCommitmentMode::Incremental
            } else {
                ImmichLockedVideoCommitmentMode::FullUpfront
            }
        );
        assert_eq!(ticket.expected_bytes.is_none(), absent);
        let view = c.view();
        let approved = view.immich_locked_view.video.ok_or("approval")?;
        assert_eq!(approved.staged_id, LEASE);
        assert_eq!(shell.reads, 1);
        assert_eq!(shell.prepares, 1);
        assert!(shell.releases.is_empty());
        assert!(view.ordinary_content_keys.is_empty());
        assert!(view.immich_locked_view.video_pending.is_some());
        shell.run(
            &c,
            Event::StopImmichLockedVideo {
                scene_id: SCENE.into(),
                request_id: REQUEST.into(),
            },
        )?;
        assert!(c.view().immich_locked_view.video.is_none());
        assert_eq!(shell.releases, vec![LEASE]);
    }
    Ok(())
}
#[test]
fn failed_hash_preparation_or_post_read_identity_always_releases_exact_lease() -> Result<(), String>
{
    for fault in [0, 1, 2] {
        let raw = raw();
        let c = core(&raw)?;
        let mut shell = Shell::new(raw);
        shell.bad_hash = fault == 0;
        shell.fail_prepare = fault == 1;
        shell.post_read_drift = fault == 2;
        shell.run(&c, request())?;
        assert!(c.view().immich_locked_view.video.is_none());
        assert!(!shell.releases.is_empty());
        assert!(shell.releases.iter().all(|id| id == LEASE));
    }
    Ok(())
}
#[test]
fn invalid_size_and_insufficient_space_never_read_and_quote_is_released() -> Result<(), String> {
    let mut malformed = raw();
    let c = core(&malformed)?;
    malformed["exifInfo"]["fileSizeInByte"] = json!(-1);
    let mut shell = Shell::new(malformed);
    shell.run(&c, request())?;
    assert_eq!(shell.reads, 0);
    assert!(shell.releases.is_empty());
    let raw = raw();
    let c = core(&raw)?;
    let mut shell = Shell::new(raw);
    shell.storage.available_bytes = policy::PRIVATE_VIDEO_HEADROOM_BYTES;
    shell.run(&c, request())?;
    assert_eq!(shell.reads, 0);
    assert_eq!(shell.releases, vec![LEASE]);
    Ok(())
}

#[test]
fn queued_prepared_completion_checks_captured_deadline_even_with_current_grant()
-> Result<(), String> {
    let raw = raw();
    let c = core(&raw)?;
    let mut shell = Shell::new(raw);
    let effect = renewal_cases::pause(&c, &mut shell, c.process_event(request()), |op| {
        matches!(op, ShellOperation::PrepareImmichLockedVideo { .. })
    })?;
    let Effect::Io(effect) = effect;
    let ShellOperation::PrepareImmichLockedVideo { mut ticket, .. } = effect.operation else {
        return Err("prepare effect".into());
    };
    assert!(c.view().immich_locked_view.video.is_none());
    // Controlled expired queued completion, before any player has been approved.
    ticket.deadline_unix_milliseconds = 0;
    shell.run(
        &c,
        Event::ImmichLockedVideoPrepared {
            acquisition_lease_id: 1,
            ticket,
            approved: true,
        },
    )?;
    assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Open);
    assert!(c.view().immich_locked_view.video.is_none());
    assert!(shell.releases.iter().any(|id| id == LEASE));
    Ok(())
}

fn approved_model() -> Result<Model, String> {
    let mut model = model(&raw())?;
    let entry = model.immich_locked.entries[0].clone();
    let pending = ImmichLockedVideoPending {
        request_id: REQUEST.into(),
        entry_id: ID.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
        generation: 0,
        key: entry.asset.key.clone(),
        phase: ImmichLockedVideoPhase::Preparing,
    };
    let capability = visibility_session(&model, GRANT, SCENE).ok_or("capability")?;
    model.immich_locked.video.binding = Some(VideoAcquisition {
        pending: pending.clone(),
        capability: capability.clone(),
        revision: entry.asset.revision,
        sha1: "a".repeat(40),
        lease: super::renewal::SharedLease::new(capability.lease_deadline),
        bytes: Some(123),
    });
    model.immich_locked.video.pending = Some(pending.clone());
    model.immich_locked.video.lease = Some((pending.clone(), LEASE.into()));
    model.immich_locked.video.access = Some(ImmichLockedVideoAccess {
        pending,
        staged_id: LEASE.into(),
    });
    Ok(model)
}
#[test]
fn approved_video_uses_renewed_live_lease_but_never_escapes_hard_identity_or_epoch_revocation()
-> Result<(), String> {
    let mut model = approved_model()?;
    model
        .immich_locked
        .video
        .binding
        .as_mut()
        .ok_or("binding")?
        .capability
        .lease_deadline = std::time::Instant::now();
    assert!(
        projection(&model).1.is_some(),
        "Current renewed model lease remains authoritative after approval"
    );
    model.immich_locked.lease_deadline = Some(std::time::Instant::now());
    assert!(projection(&model).1.is_none());
    for reason in 0..5 {
        let mut model = approved_model()?;
        match reason {
            0 => model.immich_locked.hard_deadline = Some(std::time::Instant::now()),
            1 => {
                model
                    .immich_locked
                    .generation
                    .fetch_add(1, Ordering::SeqCst);
            }
            2 => model.session.as_mut().ok_or("ordinary")?.user_id = "other".into(),
            3 => model.immich_locked.entries[0].asset.revision = "changed".into(),
            _ => {
                model
                    .protection
                    .denied
                    .insert(model.immich_locked.entries[0].asset.key.clone());
            }
        }
        assert!(projection(&model).1.is_none());
        let mut cleanup = reconcile(&mut model);
        assert!(cleanup.effects().any(|effect|matches!(effect,Effect::Io(req) if matches!(&req.operation,ShellOperation::ReleaseImmichLockedVideo{lease_id,..} if lease_id==LEASE))));
    }
    Ok(())
}
#[test]
fn rejected_issued_refresh_reconciles_private_video_lease_on_early_return() -> Result<(), String> {
    let mut model = approved_model()?;
    model.ordinary_selected.active_refresh = Some(1);
    let origin = crate::ordinary_selected::RefreshOrigin::capture(&model);
    let old = model.state.clone();
    model
        .state
        .protected_entries
        .push(crate::protection::PersistentProtectedEntry {
            id: "77777777-7777-4777-8777-777777777777".into(),
            key: model.immich_locked.entries[0].asset.key.clone(),
        });
    model.ordinary_generation.fetch_add(1, Ordering::SeqCst);
    let result = crate::workflow::Outcome {
        refresh_persist_issued: true,
        ordinary_selected: vec![],
        preview_to_select: None,
        state: old,
        session: model.session.clone(),
        status: "stale".into(),
        error: None,
    };
    let mut command = crux_core::App::update(
        &Suwop,
        Event::OrdinarySelectedRefreshFinished {
            result: Box::new(result),
            expected_generation: 0,
            refresh_id: 1,
            origin,
        },
        &mut model,
    );
    assert!(model.immich_visibility.persistence_uncertain);
    assert!(model.immich_locked.video.pending.is_none());
    assert!(command.effects().any(|effect|matches!(effect,Effect::Io(req) if matches!(&req.operation,ShellOperation::ReleaseImmichLockedVideo{lease_id,..} if lease_id==LEASE))));
    Ok(())
}

#[path = "tests/renewal.rs"]
mod renewal_cases;
#[test]
fn visibility_quiescence_is_exact_key_and_captures_request_without_a_quote() -> Result<(), String> {
    let mut model = approved_model()?;
    let key = model
        .immich_locked
        .video
        .pending
        .as_ref()
        .ok_or("pending")?
        .key
        .clone();
    let mut other = key.clone();
    other.scope.push_str("/another-account");
    assert!(quiesce_visibility(&mut model, &other).is_none());
    assert!(model.immich_locked.video.access.is_some());
    assert!(model.immich_locked.video.lease.is_some());
    model.immich_locked.video.access = None;
    model.immich_locked.video.lease = None;
    let captured = quiesce_visibility(&mut model, &key).ok_or("captured request")?;
    assert_eq!(captured.request_id, REQUEST);
    assert!(model.immich_locked.video.pending.is_none());
    assert!(model.immich_locked.video.binding.is_none());
    Ok(())
}
#[test]
fn inspect_stop_for_key_revokes_only_selected_video_projection() -> Result<(), String> {
    let mut model = approved_model()?;
    let key = model
        .immich_locked
        .video
        .pending
        .as_ref()
        .ok_or("pending")?
        .key
        .clone();
    let mut other = key.clone();
    other.asset_id = "77777777-7777-4777-8777-777777777777".into();
    let _ = stop_for_key(&mut model, &other);
    assert!(model.immich_locked.video.access.is_some());
    let _ = stop_for_key(&mut model, &key);
    assert!(model.immich_locked.video.access.is_none());
    assert!(model.immich_locked.video.pending.is_none());
    Ok(())
}
