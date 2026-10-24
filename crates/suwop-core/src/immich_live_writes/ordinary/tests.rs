mod fixture {
    use crate::domain::{AssetKey, Provider};
    use crate::immich_live_writes::{
        Alias, Batch, Dependency, Direction, Edge, Fact, Forward, Intent, Media, Outcome,
        Placement, Resource, Role, Selection, Step,
    };

    pub(super) fn id(n: u32) -> String {
        format!("{n:08x}-0000-4000-8000-000000000000")
    }
    pub(super) fn key(n: u32) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: super::scope(),
            asset_id: id(n),
        }
    }
    fn fact(n: u32, placement: Placement) -> Fact {
        Fact {
            key: key(n),
            owner_id: id(9_000),
            media: if n == 3 { Media::Video } else { Media::Image },
            checksum: "a".repeat(40),
            revision: format!("revision-{n}-initial"),
            placement,
            forward: if n == 3 {
                Forward::Unlinked
            } else {
                Forward::Linked(key(3))
            },
            unstacked: true,
            offline: false,
            trashed: false,
        }
    }
    pub(super) fn batch(shared: bool, offset: u32) -> Result<Batch, String> {
        let mut resources = Vec::new();
        let mut selections = Vec::new();
        let mut edges = Vec::new();
        let mut aliases = Vec::new();
        let mut dependencies = Vec::new();
        let parents: &[u32] = if shared { &[1, 2] } else { &[1] };
        for &n in parents {
            resources.push(Resource {
                id: id(offset + 10 + n),
                initial: fact(
                    n,
                    if n == 1 {
                        Placement::Timeline
                    } else {
                        Placement::Archive
                    },
                ),
                initial_albums: vec![id(7_999 + n)],
                destination: Placement::Locked,
                step_id: Some(id(offset + 20 + n)),
            });
            selections.push(Selection {
                id: id(offset + 30 + n),
                parent: key(n),
            });
            edges.push(Edge {
                id: id(offset + 40 + n),
                selection_id: id(offset + 30 + n),
                parent_resource: id(offset + 10 + n),
                motion_resource: id(offset + 13),
            });
            for (role, resource_id, alias_id) in [
                (Role::Parent, id(offset + 10 + n), id(offset + 49 + 2 * n)),
                (Role::Motion, id(offset + 13), id(offset + 50 + 2 * n)),
            ] {
                aliases.push(Alias {
                    id: alias_id,
                    edge_id: id(offset + 40 + n),
                    role,
                    resource_id,
                    destination: Placement::Locked,
                });
            }
            dependencies.push(Dependency {
                before: id(offset + 20 + n),
                after: id(offset + 23),
            });
        }
        resources.push(Resource {
            id: id(offset + 13),
            initial: fact(3, Placement::Hidden),
            initial_albums: vec![id(8_002)],
            destination: Placement::Locked,
            step_id: Some(id(offset + 23)),
        });
        let mut steps: Vec<_> = resources
            .iter()
            .map(|r| {
                Ok(Step {
                    id: r.step_id.clone().ok_or("step")?,
                    resource_id: r.id.clone(),
                    outcome: Outcome::NotStarted,
                })
            })
            .collect::<Result<_, String>>()?;
        steps[0].outcome = Outcome::Unknown {
            attempt_id: id(offset + 201),
            accepted: None,
        };
        let mut intent = Intent {
            encoding_version: 1,
            owner_id: id(9_000),
            scope: super::scope(),
            direction: Direction::Lock,
            selections,
            resources,
            edges,
            aliases,
            observed_additional_parents: vec![key(4)],
            shared_reference_limitations_acknowledged: true,
            dependencies,
            ordered_step_ids: steps.iter().map(|s| s.id.clone()).collect(),
            supersedes: vec![],
            digest: String::new(),
        };
        intent.digest = crate::immich_live_writes::intent_digest(&intent)?;
        Ok(Batch {
            format_version: 1,
            id: id(offset + 101),
            intent,
            steps,
            latest_observations: vec![],
        })
    }
}
use super::*;
use crate::app::{ConnectionSettings, Effect, Event, ShellResponse};
use crux_core::Command;
use serde_json::json;
use std::sync::Mutex;
fn scope() -> String {
    format!("https://fixture.invalid/api#{}", fixture::id(9000))
}
fn model(shared: bool) -> Result<Model, String> {
    let state = SavedLibrary {
        schema_version: 9,
        connection: Some(ConnectionSettings {
            address: "https://fixture.invalid".into(),
            allow_http: false,
            credential_id: "synthetic-only".into(),
        }),
        immich_live_operations: vec![fixture::batch(shared, 0)?],
        ..SavedLibrary::default()
    };
    Ok(Model {
        state,
        session: Some(Session {
            ordinary_content_guard: None,
            ordinary_content_context: None,
            endpoint: "https://fixture.invalid/api".into(),
            key: "synthetic-only".into(),
            user_id: fixture::id(9000),
            scope: scope(),
            version: crate::immich::Version {
                major: 3,
                minor: 2,
                patch: 4,
            },
        }),
        ready: true,
        ..Model::default()
    })
}
fn raw(id: &str, parent_visibility: &str) -> Value {
    let motion = id == fixture::id(3);
    json!({"id":id,"ownerId":fixture::id(9000),"type":if motion {"VIDEO"}else{"IMAGE"},
        "checksum":"a".repeat(40),"updatedAt":"fresh-revision","visibility":if motion {"hidden"}else{parent_visibility},
        "stack":null,"isOffline":false,"isTrashed":false,"livePhotoVideoId":if motion {Value::Null}else{json!(fixture::id(3))},
        "originalFileName":if motion {"motion.mov"}else{"parent.heic"},
        "fileCreatedAt":"2026-10-23T00:00:00Z","fileModifiedAt":"2026-10-23T00:00:00Z","isFavorite":false,
        "isEdited":false,"isExternal":false,"libraryId":null,"exifInfo":null})
}
fn response(value: Value) -> ShellResponse {
    ShellResponse {
        value: Some(Value::Object(serde_json::Map::from_iter([
            ("status".into(), json!(200)),
            ("body".into(), value),
            ("path".into(), Value::Null),
        ]))),
        error: None,
    }
}
fn drive(
    request: Request,
    mut respond: impl FnMut(usize, &crate::immich::HttpRequest) -> ShellResponse,
) -> Result<(Result<VerifiedPair, String>, usize), String> {
    let result = Arc::new(Mutex::new(None));
    let output = result.clone();
    let mut command: Command<Effect, Event> = Command::new(move |ctx| async move {
        let value = fetch(&ctx, request).await;
        if let Ok(mut result) = output.lock() {
            *result = Some(value);
        }
    });
    let mut count = 0;
    for _ in 0..32 {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut request) in effects {
            let ShellOperation::Http(http) = &request.operation else {
                return Err("non-HTTP effect".into());
            };
            count += 1;
            assert_eq!(http.method, "GET");
            assert!(!http.url.contains("server/") && !http.url.contains("auth/"));
            assert!(http.immich_visibility_authorization.is_none());
            let auth = http
                .ordinary_content_authorization
                .as_ref()
                .ok_or("ordinary metadata auth")?;
            assert!(matches!(
                auth.purpose,
                OrdinaryContentPurpose::SelectedPresentationMetadata
            ));
            assert_eq!(auth.source_keys.len(), 1);
            let reply = respond(count, http);
            request.resolve(reply).map_err(|_| "resolve")?;
        }
    }
    let value = result
        .lock()
        .map_err(|_| "mutex")?
        .take()
        .ok_or("no result")?;
    Ok((value, count))
}
fn capture(model: &Model, epoch: Arc<AtomicU64>) -> Result<Request, String> {
    Request::capture(model, &fixture::key(1), epoch, 0)
}
#[test]
fn ordinary_324_unknown_history_returns_timeline_or_archive_with_hidden_motion()
-> Result<(), String> {
    for placement in ["timeline", "archive"] {
        let model = model(false)?;
        let journal =
            serde_json::to_value(&model.state.immich_live_operations).map_err(|e| e.to_string())?;
        let (proof, count) = drive(capture(&model, Arc::default())?, |_, http| {
            response(raw(
                http.url.rsplit('/').next().unwrap_or_default(),
                placement,
            ))
        })?;
        let proof = proof?;
        assert_eq!(count, 4);
        assert!(proof.current(&model));
        let display = proof.presentation(&model).ok_or("presentation")?;
        assert_eq!(display.motion_visibility, Placement::Hidden);
        assert_eq!(
            display.parent_visibility,
            if placement == "timeline" {
                Placement::Timeline
            } else {
                Placement::Archive
            }
        );
        let assets = proof.assets(&model).ok_or("assets")?;
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].resources.len(), 2);
        assert!(!assets[0].inventory_complete);
        assert_eq!(
            journal,
            serde_json::to_value(&model.state.immich_live_operations).map_err(|e| e.to_string())?
        );
        assert!(super::super::fences(&model.state, &fixture::key(1)));
    }
    Ok(())
}
#[test]
fn fresh_response_rejects_identity_relationship_visibility_and_second_pass_drift()
-> Result<(), String> {
    for field in [
        "checksum",
        "ownerId",
        "id",
        "type",
        "livePhotoVideoId",
        "visibility",
        "updatedAt",
        "stack",
        "isTrashed",
        "isOffline",
    ] {
        let model = model(false)?;
        let (result, _) = drive(capture(&model, Arc::default())?, |index, http| {
            let mut value = raw(http.url.rsplit('/').next().unwrap_or_default(), "timeline");
            if index == 3 {
                value[field] = match field {
                    "checksum" => json!("b".repeat(40)),
                    "ownerId" | "id" | "livePhotoVideoId" => json!(fixture::id(99)),
                    "type" => json!("VIDEO"),
                    "visibility" => json!("locked"),
                    "updatedAt" => json!("changed-revision"),
                    "stack" => json!({}),
                    _ => json!(true),
                };
            }
            response(value)
        })?;
        assert!(result.is_err(), "{field}");
    }
    Ok(())
}
#[test]
fn shared_motion_does_not_read_or_publish_other_parent_even_when_locked() -> Result<(), String> {
    let model = model(true)?;
    let (result, count) = drive(capture(&model, Arc::default())?, |_, http| {
        let id = http.url.rsplit('/').next().unwrap_or_default();
        assert!(
            id == fixture::id(1) || id == fixture::id(3),
            "must not read other alias parent"
        );
        response(raw(id, "archive"))
    })?;
    let proof = result?;
    assert_eq!(count, 4);
    assert!(proof.current(&model));
    assert_eq!(
        proof.assets(&model).ok_or("assets")?[0].key,
        fixture::key(1)
    );
    Ok(())
}
#[test]
fn cancellation_and_both_security_epochs_stop_after_pending_response() -> Result<(), String> {
    for mode in 0..3 {
        let model = model(false)?;
        let cancel = Arc::<AtomicU64>::default();
        let request = capture(&model, cancel.clone())?;
        let (result, count) = drive(request, |_, http| {
            match mode {
                0 => {
                    cancel.fetch_add(1, Ordering::SeqCst);
                }
                1 => {
                    model.ordinary_generation.fetch_add(1, Ordering::SeqCst);
                }
                _ => {
                    model.protection.generation.fetch_add(1, Ordering::SeqCst);
                }
            }
            response(raw(
                http.url.rsplit('/').next().unwrap_or_default(),
                "timeline",
            ))
        })?;
        assert_eq!(count, 1);
        assert!(result.is_err());
    }
    Ok(())
}
#[test]
fn completed_proof_is_invalidated_by_connection_session_history_or_active_work()
-> Result<(), String> {
    for mode in 0..8 {
        let mut model = model(false)?;
        let (proof, _) = drive(capture(&model, Arc::default())?, |_, http| {
            response(raw(
                http.url.rsplit('/').next().unwrap_or_default(),
                "timeline",
            ))
        })?;
        let proof = proof?;
        match mode {
            0 => {
                model
                    .state
                    .connection
                    .as_mut()
                    .ok_or("connection")?
                    .credential_id = "replacement".into();
            }
            1 => model.session.as_mut().ok_or("session")?.key = "replacement".into(),
            2 => {
                model.state.immich_live_operations[0].steps[0].outcome =
                    super::super::Outcome::Unknown {
                        attempt_id: fixture::id(999),
                        accepted: None,
                    };
            }
            3 => model.busy = true,
            4 => {
                model.live_placement.held.insert(fixture::key(3));
            }
            5 => model.live_placement.persistence_uncertain = true,
            6 => model.immich_visibility.persistence_uncertain = true,
            _ => model.protection.membership_uncertain = true,
        }
        assert!(!proof.current(&model));
        assert!(proof.assets(&model).is_none());
        assert!(proof.presentation(&model).is_none());
    }
    Ok(())
}

#[test]
fn independent_locked_pair_in_same_batch_is_never_read_or_published() -> Result<(), String> {
    let mut model = model(false)?;
    let mut other = fixture::batch(false, 1000)?;
    // Shift only physical keys; operation/resource IDs are already independent.
    let mut encoded = serde_json::to_value(&other).map_err(|e| e.to_string())?;

    shift(&mut encoded);
    other = serde_json::from_value(encoded).map_err(|e| e.to_string())?;
    // This sibling's current server placement is locked; the response harness
    // below must never be asked for it. Historical pending intent stays intact.
    for step in &mut other.steps {
        step.outcome = super::super::Outcome::NotStarted;
    }
    let batch = &mut model.state.immich_live_operations[0];
    batch.intent.resources.extend(other.intent.resources);
    batch.intent.selections.extend(other.intent.selections);
    batch.intent.edges.extend(other.intent.edges);
    batch.intent.aliases.extend(other.intent.aliases);
    batch.intent.dependencies.extend(other.intent.dependencies);
    batch
        .intent
        .ordered_step_ids
        .extend(other.intent.ordered_step_ids);
    batch
        .intent
        .observed_additional_parents
        .extend(other.intent.observed_additional_parents);
    batch.steps.extend(other.steps);
    batch.intent.digest = super::super::intent_digest(&batch.intent)?;
    super::super::validate_library(&model.state)?;
    let (proof, count) = drive(capture(&model, Arc::default())?, |_, http| {
        let id = http.url.rsplit('/').next().unwrap_or_default();
        assert!(
            id == fixture::id(1) || id == fixture::id(3),
            "locked independent pair must not be requested"
        );
        response(raw(id, "timeline"))
    })?;
    let assets = proof?.assets(&model).ok_or("assets")?;
    assert_eq!(count, 4);
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].key, fixture::key(1));
    assert!(
        assets[0]
            .resources
            .iter()
            .all(|r| r.id == fixture::id(1) || r.id == fixture::id(3))
    );
    Ok(())
}

#[test]
fn legacy_video_unknown_uses_video_identity_and_keeps_outcome_unknown() -> Result<(), String> {
    use crate::immich_visibility::{
        AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
        ImmichVisibilityOperationKind,
    };
    let mut model = model(false)?;
    model
        .state
        .immich_visibility_operations
        .push(ImmichVisibilityOperation {
            kind: ImmichVisibilityOperationKind::LockedTransition,
            id: fixture::id(20000),
            scope: scope(),
            key: fixture::key(3),
            witness_digest: crate::immich_visibility::original_video_identity_digest(
                &fixture::key(3),
                &"a".repeat(40),
            ),
            from: ImmichVisibility::Timeline,
            to: ImmichVisibility::Locked,
            outcome: crate::apple_visibility::VisibilityOutcome::Unknown,
            observation: None,
            album_membership_observation: AlbumMembershipObservation::NotChecked,
            selected_observation: None,
        });
    let (proof, count) = drive(capture(&model, Arc::default())?, |_, http| {
        response(raw(
            http.url.rsplit('/').next().unwrap_or_default(),
            "timeline",
        ))
    })?;
    assert_eq!(count, 4);
    assert!(proof?.current(&model));
    assert_eq!(
        model.state.immich_visibility_operations[0].outcome,
        crate::apple_visibility::VisibilityOutcome::Unknown
    );
    Ok(())
}

#[test]
fn cancelled_before_fetch_emits_no_metadata_request() -> Result<(), String> {
    let model = model(false)?;
    let epoch = Arc::<AtomicU64>::default();
    let request = capture(&model, epoch.clone())?;
    epoch.fetch_add(1, Ordering::SeqCst);
    let (result, count) = drive(request, |_, _| ShellResponse {
        value: None,
        error: Some("cancelled request reached shell".into()),
    })?;
    assert!(result.is_err());
    assert_eq!(count, 0);
    Ok(())
}

#[test]
fn acquired_proof_revalidation_checks_exact_revision_of_both_members() -> Result<(), String> {
    for drift in [false, true] {
        let model = model(false)?;
        let (proof, _) = drive(capture(&model, Arc::default())?, |_, http| {
            response(raw(
                http.url.rsplit('/').next().unwrap_or_default(),
                "timeline",
            ))
        })?;
        let proof = proof?;
        let result = Arc::new(Mutex::new(None));
        let output = result.clone();
        let mut command: Command<Effect, Event> = Command::new(move |ctx| async move {
            let value = proof.revalidate(&ctx).await;
            if let Ok(mut result) = output.lock() {
                *result = Some(value);
            }
        });
        let mut count = 0;
        loop {
            let effects: Vec<_> = command.effects().collect();
            if effects.is_empty() {
                break;
            }
            for Effect::Io(mut request) in effects {
                let ShellOperation::Http(http) = &request.operation else {
                    return Err("unexpected effect".into());
                };
                count += 1;
                assert_eq!(http.method, "GET");
                let mut value = raw(http.url.rsplit('/').next().unwrap_or_default(), "timeline");
                if drift && count == 2 {
                    value["updatedAt"] = json!("replacement-motion-revision");
                }
                request.resolve(response(value)).map_err(|_| "resolve")?;
            }
        }
        assert_eq!(count, 2);
        assert_eq!(
            result
                .lock()
                .map_err(|_| "mutex")?
                .take()
                .ok_or("result")?
                .is_ok(),
            !drift
        );
    }
    Ok(())
}

fn shift(value: &mut Value) {
    match value {
        Value::Object(object) => {
            if object.contains_key("provider") && object.contains_key("scope") {
                for n in [1, 3, 4] {
                    if object.get("assetID").and_then(Value::as_str) == Some(&fixture::id(n)) {
                        object.insert("assetID".into(), json!(fixture::id(n + 10)));
                    }
                }
            }
            for child in object.values_mut() {
                shift(child);
            }
        }
        Value::Array(values) => {
            for child in values {
                shift(child);
            }
        }
        _ => {}
    }
}
