use super::*;
use crate::{
    app::{ConnectionSettings, SavedLibrary, ShellResponse, Suwop, ViewModel},
    immich::{Session, Version},
};
use crux_core::{App, Core};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
fn id(n: u32) -> String {
    format!("{n:08x}-0000-4000-8000-000000000000")
}
fn remap_scope(value: &mut Value) {
    match value {
        Value::String(scope) if scope == "wire-owner-scope" => {
            *scope = format!("https://fixture.invalid/api#{}", id(9000));
        }
        Value::Array(values) => {
            for value in values {
                remap_scope(value);
            }
        }
        Value::Object(values) => {
            for value in values.values_mut() {
                remap_scope(value);
            }
        }
        _ => {}
    }
}
fn model(shared: bool) -> Result<Model, String> {
    let corpus: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/live-journal-wire.json"
    ))
    .map_err(|e| e.to_string())?;
    let mut encoded = corpus["validStates"][0]["library"].clone();
    remap_scope(&mut encoded);
    let mut state: SavedLibrary = serde_json::from_value(encoded).map_err(|e| e.to_string())?;
    if shared {
        add_alias(&mut state)?;
    }
    for batch in &mut state.immich_live_operations {
        batch.intent.digest = crate::immich_live_writes::intent_digest(&batch.intent)?;
    }
    crate::immich_live_writes::validate_library(&state)?;
    let intent = &state.immich_live_operations[0].intent;
    let session = Session {
        endpoint: "https://fixture.invalid/api".into(),
        key: "synthetic-only".into(),
        scope: intent.scope.clone(),
        user_id: intent.owner_id.clone(),
        version: Version {
            major: 3,
            minor: 3,
            patch: 3,
        },
        ordinary_content_guard: None,
        ordinary_content_context: None,
    };
    state.connection = Some(ConnectionSettings {
        address: session.endpoint.clone(),
        allow_http: false,
        credential_id: "synthetic-only".into(),
    });
    Ok(Model {
        state,
        session: Some(session),
        ready: true,
        ..Model::default()
    })
}
fn add_alias(state: &mut SavedLibrary) -> Result<(), String> {
    use crate::immich_live_writes::{Alias, Dependency, Edge, Outcome, Role, Selection, Step};
    let batch = &mut state.immich_live_operations[0];
    batch.latest_observations.clear();
    let mut resource = batch.intent.resources[0].clone();
    resource.id = id(10000);
    resource.initial.key.asset_id = id(3);
    resource.step_id = Some(id(10001));
    batch.intent.resources.push(resource);
    batch.intent.selections.push(Selection {
        id: id(10002),
        parent: crate::domain::AssetKey {
            asset_id: id(3),
            ..batch.intent.selections[0].parent.clone()
        },
    });
    batch.intent.edges.push(Edge {
        id: id(10003),
        selection_id: id(10002),
        parent_resource: id(10000),
        motion_resource: batch.intent.resources[1].id.clone(),
    });
    batch.intent.aliases.push(Alias {
        id: id(10004),
        edge_id: id(10003),
        role: Role::Parent,
        resource_id: id(10000),
        destination: batch.intent.resources[0].destination,
    });
    batch.intent.aliases.push(Alias {
        id: id(10005),
        edge_id: id(10003),
        role: Role::Motion,
        resource_id: batch.intent.resources[1].id.clone(),
        destination: batch.intent.resources[1].destination,
    });
    let motion_step = batch.steps[1].id.clone();
    batch.steps.insert(
        1,
        Step {
            id: id(10001),
            resource_id: id(10000),
            outcome: Outcome::NotStarted,
        },
    );
    batch.intent.dependencies.push(Dependency {
        before: id(10001),
        after: motion_step,
    });
    batch.intent.ordered_step_ids = batch.steps.iter().map(|s| s.id.clone()).collect();
    batch.intent.digest = crate::immich_live_writes::intent_digest(&batch.intent)?;
    Ok(())
}
#[derive(Default)]
struct Shell {
    reads: usize,
    publishes: usize,
    releases: Vec<String>,
    drift: bool,
    raster_error: bool,
    hold_publish: bool,
}
impl Shell {
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(request) => {
                assert_eq!(request.method, "GET");
                assert!(request.download_path.is_none());
                assert!(!request.url.contains("thumbnail"));
                let asset = request.url.rsplit('/').next().ok_or("assetID")?;
                let motion = asset == id(2);
                Ok(
                    json!({"status":200,"path":null,"body":{"id":asset,"ownerId":id(9000),"type":if motion{"VIDEO"}else{"IMAGE"},"checksum":if self.drift && motion {"b".repeat(40)}else{"a".repeat(40)},"updatedAt":"fresh-raster-witness","visibility":if motion{"hidden"}else{"timeline"},"stack":null,"isOffline":false,"isTrashed":false,"livePhotoVideoId":if motion{Value::Null}else{json!(id(2))},"originalFileName":if motion{"motion.mov"}else{"parent.heic"},"fileCreatedAt":"2026-10-24T00:00:00Z","fileModifiedAt":"2026-10-24T00:00:00Z","isFavorite":false,"isEdited":false,"isExternal":false,"libraryId":null,"exifInfo":null}}),
                )
            }
            ShellOperation::ReadOrdinaryLivePairImage { ticket } => {
                self.reads += 1;
                assert!(ticket.request.url.contains(&format!(
                    "/assets/{}/thumbnail?size=",
                    ticket.presentation.parent_key.asset_id
                )));
                assert!(!ticket.request.url.contains("original"));
                assert!(ticket.request.download_path.is_none());
                assert!(ticket.request.ordinary_content_authorization.is_none());
                if self.raster_error {
                    return Err("synthetic raster404/decodefailure".into());
                }
                Ok(json!({"requestID":ticket.request_id,"stagedID":ticket.owner_id}))
            }
            ShellOperation::PublishOrdinaryLivePairImage { ticket, staged_id } => {
                self.publishes += 1;
                Ok(json!({"requestID":ticket.request_id,"stagedID":staged_id}))
            }
            ShellOperation::ReleaseOrdinaryLivePairImage { owner_id } => {
                self.releases.push(owner_id.clone());
                Ok(Value::Null)
            }
            other => Err(format!("forbidden paired raster effect: {other:?}")),
        }
    }
    fn drain<A: App<Event = Event, Effect = Effect, ViewModel = ViewModel>>(
        &mut self,
        core: &Core<A>,
        effects: Vec<Effect>,
        pause: bool,
    ) -> Result<Vec<Effect>, String> {
        let mut queue: VecDeque<_> = effects.into();
        let mut paused = Vec::new();
        while let Some(Effect::Io(mut request)) = queue.pop_front() {
            if (pause
                && matches!(
                    &request.operation,
                    ShellOperation::ReadOrdinaryLivePairImage { .. }
                ))
                || (self.hold_publish
                    && matches!(
                        &request.operation,
                        ShellOperation::PublishOrdinaryLivePairImage { .. }
                    ))
            {
                paused.push(Effect::Io(request));
                continue;
            }
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
            queue.extend(
                core.resolve(&mut request, response)
                    .map_err(|_| "resolve")?,
            );
        }
        Ok(paused)
    }
    fn run<A: App<Event = Event, Effect = Effect, ViewModel = ViewModel>>(
        &mut self,
        core: &Core<A>,
        event: Event,
    ) -> Result<(), String> {
        self.drain(core, core.process_event(event), false)?;
        Ok(())
    }
}
fn parent<A: App<Event = Event, Effect = Effect, ViewModel = ViewModel>>(
    core: &Core<A>,
    n: u32,
) -> Result<AssetKey, String> {
    core.view()
        .ordinary_live_pairs
        .into_iter()
        .find(|p| p.parent_key.asset_id == id(n))
        .map(|p| p.parent_key)
        .ok_or_else(|| "parent proof".into())
}
fn request(key: &AssetKey, n: u32, kind: OrdinarySelectedImageKind) -> Event {
    Event::RequestOrdinaryLivePairImage {
        parent_key: key.clone(),
        scene_id: SCENE.into(),
        request_id: id(n),
        kind,
    }
}
fn ready(shared: bool) -> Result<(Core<Suwop>, Shell), String> {
    let core = Core::new_with(Suwop, model(shared)?);
    let mut shell = Shell::default();
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: id(1000),
        },
    )?;
    assert_eq!(
        core.view().ordinary_live_pairs.len(),
        if shared { 2 } else { 1 }
    );
    Ok((core, shell))
}
#[test]
fn thumbnail_and_preview_use_only_parent_raster_and_remain_display_only() -> Result<(), String> {
    let (core, mut shell) = ready(false)?;
    let key = parent(&core, 1)?;
    for (n, kind) in [
        (2000, OrdinarySelectedImageKind::Thumbnail),
        (2001, OrdinarySelectedImageKind::Preview),
    ] {
        shell.run(&core, request(&key, n, kind))?;
    }
    assert_eq!(core.view().ordinary_live_images.len(), 2);
    assert_eq!(shell.reads, 2);
    assert_eq!(shell.publishes, 2);
    assert!(!core.view().ordinary_content_keys.contains(&key));
    Ok(())
}
#[test]
fn cancel_before_read_ack_rejects_late_bytes_and_reused_public_id_uses_new_owner()
-> Result<(), String> {
    let (core, mut shell) = ready(false)?;
    let key = parent(&core, 1)?;
    let paused = shell.drain(
        &core,
        core.process_event(request(&key, 2000, OrdinarySelectedImageKind::Thumbnail)),
        true,
    )?;
    let old = core.view().ordinary_live_image_pending[0].owner_id.clone();
    shell.run(
        &core,
        Event::CancelOrdinaryLivePairImage {
            scene_id: SCENE.into(),
            request_id: Some(id(2000)),
        },
    )?;
    shell.drain(&core, paused, false)?;
    assert!(core.view().ordinary_live_images.is_empty());
    assert_eq!(shell.publishes, 0);
    shell.run(
        &core,
        request(&key, 2000, OrdinarySelectedImageKind::Thumbnail),
    )?;
    assert_ne!(core.view().ordinary_live_images[0].owner_id, old);
    assert!(shell.releases.contains(&old));
    Ok(())
}
#[test]
fn raster_failure_keeps_proof_and_existing_image_but_motion_drift_revokes_shared_displays()
-> Result<(), String> {
    let (core, mut shell) = ready(true)?;
    let first = parent(&core, 1)?;
    let alias = parent(&core, 3)?;
    shell.run(
        &core,
        request(&first, 2000, OrdinarySelectedImageKind::Thumbnail),
    )?;
    shell.run(
        &core,
        request(&alias, 2001, OrdinarySelectedImageKind::Thumbnail),
    )?;
    shell.raster_error = true;
    shell.run(
        &core,
        request(&first, 2002, OrdinarySelectedImageKind::Preview),
    )?;
    assert_eq!(core.view().ordinary_live_pairs.len(), 2);
    assert_eq!(core.view().ordinary_live_images.len(), 2);
    shell.raster_error = false;
    shell.drift = true;
    shell.run(
        &core,
        request(&first, 2003, OrdinarySelectedImageKind::Preview),
    )?;
    assert!(core.view().ordinary_live_pairs.is_empty());
    assert!(core.view().ordinary_live_images.is_empty());
    assert!(shell.releases.len() >= 3);
    Ok(())
}
#[test]
fn old_failure_after_refresh_cannot_revoke_replacement_proof() -> Result<(), String> {
    let (core, mut shell) = ready(false)?;
    let key = parent(&core, 1)?;
    let paused = shell.drain(
        &core,
        core.process_event(request(&key, 2000, OrdinarySelectedImageKind::Thumbnail)),
        true,
    )?;
    let old = core.view().ordinary_live_pairs[0].proof_id.clone();
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: id(2001),
        },
    )?;
    let replacement = core.view().ordinary_live_pairs[0].proof_id.clone();
    assert_ne!(old, replacement);
    shell.drift = true;
    // Successful old raster ACK reaches its post-read freshness check. The old
    // source epoch is stale; that failure cannot revoke the replacement ID.
    shell.drain(&core, paused, false)?;
    assert_eq!(core.view().ordinary_live_pairs[0].proof_id, replacement);
    assert!(core.view().ordinary_live_images.is_empty());
    assert_eq!(shell.publishes, 0);
    Ok(())
}
#[test]
fn account_switch_during_read_removes_access_and_late_publication() -> Result<(), String> {
    let (core, mut shell) = ready(false)?;
    let key = parent(&core, 1)?;
    let paused = shell.drain(
        &core,
        core.process_event(request(&key, 2000, OrdinarySelectedImageKind::Thumbnail)),
        true,
    )?;
    let mut foreign = model(false)?;
    if let Some(session) = foreign.session.as_mut() {
        session.scope = "different-account-scope".into();
        session.user_id = id(9999);
    }
    shell.run(
        &core,
        Event::Finished {
            state: foreign.state,
            session: foreign.session,
            status: String::new(),
            error: None,
            preview_to_select: None,
        },
    )?;
    shell.drain(&core, paused, false)?;
    assert!(core.view().ordinary_live_images.is_empty());
    Ok(())
}
/// Same shape as the FFI projection: a private query answered from the live Model.
type TicketQuery = Arc<Mutex<Option<(PairImageTicket, PairImagePhase)>>>;
struct Probe {
    query: TicketQuery,
    answer: Arc<Mutex<Option<bool>>>,
}
impl App for Probe {
    type Event = Event;
    type Model = Model;
    type Effect = Effect;
    type ViewModel = ViewModel;
    fn update(&self, event: Event, model: &mut Model) -> Command<Effect, Event> {
        Suwop.update(event, model)
    }
    fn view(&self, model: &Model) -> ViewModel {
        if let Ok(mut query) = self.query.lock()
            && let Some((ticket, phase)) = query.take()
            && let Ok(mut answer) = self.answer.lock()
        {
            *answer = Some(ticket_issued(model, &ticket, phase));
        }
        Suwop.view(model)
    }
}
fn ask(
    core: &Core<Probe>,
    query: &TicketQuery,
    answer: &Arc<Mutex<Option<bool>>>,
    ticket: &PairImageTicket,
    phase: PairImagePhase,
) -> Result<bool, String> {
    *query.lock().map_err(|e| e.to_string())? = Some((ticket.clone(), phase));
    let _ = core.view();
    answer
        .lock()
        .map_err(|e| e.to_string())?
        .take()
        .ok_or_else(|| "query was not answered".into())
}
fn paused_ticket(effects: &[Effect]) -> Result<PairImageTicket, String> {
    effects
        .iter()
        .find_map(|Effect::Io(request)| match &request.operation {
            ShellOperation::ReadOrdinaryLivePairImage { ticket }
            | ShellOperation::PublishOrdinaryLivePairImage { ticket, .. } => Some(ticket.clone()),
            _ => None,
        })
        .ok_or_else(|| "paused raster ticket".into())
}
#[test]
fn only_the_exact_current_core_issued_ticket_and_phase_are_executable() -> Result<(), String> {
    let query: TicketQuery = Arc::default();
    let answer = Arc::new(Mutex::new(None));
    let core = Core::new_with(
        Probe {
            query: query.clone(),
            answer: answer.clone(),
        },
        model(false)?,
    );
    let mut shell = Shell {
        hold_publish: true,
        ..Shell::default()
    };
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: id(1000),
        },
    )?;
    let key = parent(&core, 1)?;
    let paused = shell.drain(
        &core,
        core.process_event(request(&key, 2000, OrdinarySelectedImageKind::Thumbnail)),
        true,
    )?;
    let ticket = paused_ticket(&paused)?;
    let issued = |t: &PairImageTicket, p| ask(&core, &query, &answer, t, p);
    assert!(issued(&ticket, PairImagePhase::Read)?);
    assert!(!issued(&ticket, PairImagePhase::Publish)?);
    let mut forged = Vec::new();
    let mut origin = ticket.clone();
    origin.request.url = origin
        .request
        .url
        .replace("fixture.invalid", "attacker.invalid");
    forged.push(origin);
    let mut header = ticket.clone();
    header
        .request
        .headers
        .insert("x-api-key".into(), "forged".into());
    forged.push(header);
    let mut revision = ticket.clone();
    revision.expected_revision = "forged-revision".into();
    forged.push(revision);
    let mut body = ticket.clone();
    body.request.body = Some(json!({}));
    forged.push(body);
    let mut download = ticket.clone();
    download.request.download_path = Some("/tmp/forged".into());
    forged.push(download);
    let mut owner = ticket.clone();
    owner.owner_id = format!("{}:0", ticket.request_id);
    forged.push(owner);
    let mut kind = ticket.clone();
    kind.kind = OrdinarySelectedImageKind::Preview;
    forged.push(kind);
    for forged in &forged {
        assert!(!issued(forged, PairImagePhase::Read)?);
    }
    let held = shell.drain(&core, paused, false)?;
    assert_eq!(paused_ticket(&held)?.owner_id, ticket.owner_id);
    assert!(!issued(&ticket, PairImagePhase::Read)?);
    assert!(issued(&ticket, PairImagePhase::Publish)?);
    let mut origin = ticket.clone();
    origin.request.url = origin
        .request
        .url
        .replace("fixture.invalid", "attacker.invalid");
    assert!(!issued(&origin, PairImagePhase::Publish)?);
    // A replacement for the same public request retires the old private owner.
    let replacement = shell.drain(
        &core,
        core.process_event(request(&key, 2000, OrdinarySelectedImageKind::Thumbnail)),
        true,
    )?;
    let fresh = paused_ticket(&replacement)?;
    assert_ne!(fresh.owner_id, ticket.owner_id);
    assert!(!issued(&ticket, PairImagePhase::Publish)?);
    assert!(issued(&fresh, PairImagePhase::Read)?);
    shell.hold_publish = false;
    shell.drain(&core, held, false)?;
    shell.drain(&core, replacement, false)?;
    assert_eq!(core.view().ordinary_live_images.len(), 1);
    assert!(!issued(&fresh, PairImagePhase::Read)?);
    assert!(!issued(&fresh, PairImagePhase::Publish)?);
    Ok(())
}
#[test]
fn displayed_paired_parent_can_be_chosen_as_preview_without_operation_authority()
-> Result<(), String> {
    let mut state = model(false)?;
    let scope = state.state.immich_live_operations[0].intent.scope.clone();
    state.state.snapshots.push(crate::domain::LibrarySnapshot {
        provider: crate::domain::Provider::Immich,
        scope,
        assets: vec![],
        access: crate::domain::ScanAccess::Full,
        scanned_at: None,
    });
    let core = Core::new_with(Suwop, state);
    let mut shell = Shell::default();
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: id(1000),
        },
    )?;
    let key = parent(&core, 1)?;
    // The fresh pair proof is the only reason this parent is displayed.
    assert_eq!(core.view().preview_sources.values().next(), Some(&key));
    shell.run(
        &core,
        Event::ChoosePreview {
            anchor: key.clone(),
            key: key.clone(),
        },
    )?;
    let view = core.view();
    assert_eq!(view.error, None);
    // Display preference only: the historical fence still withholds operations.
    assert!(!view.ordinary_content_keys.contains(&key));
    Ok(())
}
