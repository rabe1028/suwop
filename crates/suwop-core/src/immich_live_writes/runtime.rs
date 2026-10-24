//! Runtime capabilities are private, nonserializable and owned by one reducer cursor.
use super::{
    Batch, LivePlacementDestination, LivePlacementPrompt, LiveResourceDestination, Media, Outcome,
    ResourceObservation, Role, validate_transition,
};
use crate::{
    app::{Context, Effect, Event, Model, SavedLibrary, ShellOperation, io},
    domain::{AssetKey, Provider},
    immich_locked::{VisibilitySession, live, video},
};
use crux_core::Command;
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
mod durable;
pub(crate) mod executor;
pub(crate) mod history;
mod prepare;
pub(crate) mod recovery;
const ERROR: &str = "Live Photo の変更条件を確認できません。原本の書込みは再送しません。";

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementCleanup {
    #[serde(rename = "captureID")]
    pub capture_id: String,
    pub status: String,
    pub can_retry: bool,
}
pub(crate) fn cleanup(model: &Model) -> Option<LivePlacementCleanup> {
    let work = model.live_placement.work.as_ref()?;
    if work.capture == CaptureState::NotCaptured || work.running {
        return None;
    }
    Some(LivePlacementCleanup {
        capture_id: work.capture_id.clone()?,
        status: if model.busy {
            "プレビューと再生の終了処理を確認しています。"
        } else {
            "プレビューと再生の終了処理を確認できませんでした。一時ファイルの処理を再試行できます。"
        }
        .into(),
        can_retry: !model.busy,
    })
}
#[derive(Debug, Default)]
pub struct State {
    epoch: Arc<AtomicU64>,
    recovery: Option<recovery::Work>,
    work: Option<Work>,
    pub(crate) held: BTreeSet<AssetKey>,
    pub(crate) persistence_uncertain: bool,
    nonce: Option<String>,
    sequence: u32,
}
#[derive(Debug, Clone)]
struct Authority {
    owner: Arc<()>,
    session: VisibilitySession,
    baseline: Arc<SavedLibrary>,
    epoch: Arc<AtomicU64>,
    expected: u64,
    ordinary: Arc<AtomicU64>,
    expected_ordinary: u64,
    protection: Arc<AtomicU64>,
    expected_protection: u64,
}
impl Authority {
    fn valid(&self) -> Result<(), String> {
        self.session.valid()?;
        if self.epoch.load(Ordering::SeqCst) != self.expected
            || self.ordinary.load(Ordering::SeqCst) != self.expected_ordinary
            || self.protection.load(Ordering::SeqCst) != self.expected_protection
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
}
#[derive(Debug, Clone)]
struct Explicit {
    destinations: Vec<LiveResourceDestination>,
    predecessor: Option<String>,
    step_ids: Vec<String>,
}
#[derive(Debug, Clone)]
struct Prepared {
    authority: Authority,
    batch: Batch,
    prompt: LivePlacementPrompt,
}
#[derive(Debug)]
struct Work {
    owner: Arc<()>,
    prepared: Option<Prepared>,
    capture_id: Option<String>,
    live: Vec<live::CapturedOwners>,
    video: Vec<video::CapturedOwner>,
    capture: CaptureState,
    cancelled: bool,
    running: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureState {
    NotCaptured,
    Captured,
    Accepted,
}
#[derive(Debug, Clone)]
enum Stage {
    Prepared(Result<Prepared, String>),
    Confirmed(Result<Prepared, String>),
    Captured(Result<(), String>),
    Drained(Result<DrainReceipt, String>),
    Durable { state: Box<SavedLibrary> },
    Finished(executor::Finished),
}
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Arc<()>,
    stage: Stage,
}
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DrainReceipt {
    #[serde(rename = "captureID")]
    capture_id: String,
    cancelled_before_capture: bool,
}
fn issued_id(batch: &str, label: &str) -> String {
    use sha2::Digest;
    let mut bytes =
        sha2::Sha256::digest(format!("suwop/live-issued-id/v1:{batch}:{label}").as_bytes());
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let h = crate::domain::hex(&bytes[..16]);
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}
impl State {
    fn next_capture(&mut self) -> Result<String, String> {
        if self.nonce.is_none() {
            let mut value = [0_u8; 16];
            getrandom::getrandom(&mut value).map_err(|_| ERROR)?;
            self.nonce = Some(crate::domain::hex(&value));
        }
        self.sequence = self.sequence.checked_add(1).ok_or(ERROR)?;
        Ok(format!(
            "{}:{}",
            self.nonce.as_deref().ok_or(ERROR)?,
            self.sequence
        ))
    }
}

pub(crate) fn prompt(model: &Model) -> Option<LivePlacementPrompt> {
    let work = model.live_placement.work.as_ref()?;
    let prepared = work.prepared.as_ref()?;
    (!work.cancelled && prepared.authority.valid().is_ok()).then(|| prepared.prompt.clone())
}
pub(crate) fn update(event: &Event, model: &mut Model) -> Option<Command<Effect, Event>> {
    if matches!(
        event,
        Event::Disconnect | Event::Configure { .. } | Event::CloseImmichLocked
    ) {
        model.live_placement.epoch.fetch_add(1, Ordering::SeqCst);
        if let Some(work) = &mut model.live_placement.work {
            work.cancelled = true;
        }
    }
    if let Some(command) = recovery::update(event, model) {
        return Some(command);
    }
    match event {
        Event::PrepareImmichLivePlacement {
            parents,
            destination,
            batch_id,
            grant_id,
            scene_id,
        } => Some(begin(
            model,
            parents.clone(),
            *destination,
            batch_id.clone(),
            grant_id,
            scene_id,
            None,
        )),
        Event::PrepareImmichLiveResourcePlacements {
            parents,
            destinations,
            batch_id,
            predecessor_batch_id,
            supersedes_step_ids,
            grant_id,
            scene_id,
        } => Some(begin(
            model,
            parents.clone(),
            LivePlacementDestination::Timeline,
            batch_id.clone(),
            grant_id,
            scene_id,
            Some(Explicit {
                destinations: destinations.clone(),
                predecessor: predecessor_batch_id.clone(),
                step_ids: supersedes_step_ids.clone(),
            }),
        )),
        Event::RetryImmichLiveCleanup { capture_id } => {
            let matches = !model.busy
                && model.live_placement.work.as_ref().is_some_and(|work| {
                    work.capture_id.as_ref() == Some(capture_id)
                        && work.capture != CaptureState::NotCaptured
                        && !work.running
                });
            if !matches {
                return Some(Command::done());
            }
            model.live_placement.epoch.fetch_add(1, Ordering::SeqCst);
            if let Some(work) = model.live_placement.work.as_mut() {
                work.cancelled = true;
            }
            model.busy = true;
            Some(drain(model, true))
        }
        Event::ImmichLivePlacementCompleted { completion } => {
            Some(complete(model, completion.clone()))
        }
        _ => None,
    }
}
fn begin(
    model: &mut Model,
    mut parents: Vec<AssetKey>,
    destination: LivePlacementDestination,
    batch_id: String,
    grant: &str,
    scene: &str,
    explicit: Option<Explicit>,
) -> Command<Effect, Event> {
    parents.sort();
    if model.busy
        || !model.ready
        || parents.is_empty()
        || parents.len() > 16
        || parents.windows(2).any(|p| p[0] == p[1])
        || model.live_placement.work.is_some()
        || model.live_placement.recovery.is_some()
        || model.live_placement.persistence_uncertain
        || model.immich_visibility.persistence_uncertain
        || crate::immich::valid_id(&batch_id).is_err()
    {
        return Command::done();
    }
    let Some(session) = crate::immich_locked::visibility_session(model, grant, scene) else {
        return Command::done();
    };
    if parents.iter().any(|key| {
        key.provider != Provider::Immich
            || key.scope != session.scope()
            || crate::immich::valid_id(&key.asset_id).is_err()
    }) {
        return Command::done();
    }
    let epoch = model.live_placement.epoch.clone();
    let expected = epoch.fetch_add(1, Ordering::SeqCst) + 1;
    let owner = Arc::new(());
    let authority = Authority {
        owner: owner.clone(),
        session,
        baseline: Arc::new(model.state.clone()),
        epoch,
        expected,
        ordinary: model.ordinary_generation.clone(),
        expected_ordinary: model.ordinary_generation.load(Ordering::SeqCst),
        protection: model.protection.generation.clone(),
        expected_protection: model.protection.generation.load(Ordering::SeqCst),
    };
    model.live_placement.work = Some(Work {
        owner: owner.clone(),
        prepared: None,
        capture_id: None,
        live: vec![],
        video: vec![],
        capture: CaptureState::NotCaptured,
        cancelled: false,
        running: false,
    });
    model.busy = true;
    model.error = None;
    model.status = "Live Photo の関連原本と所属を確認しています。".into();
    Command::new(move |ctx| async move {
        let result =
            prepare::prepare(&ctx, authority, parents, destination, batch_id, explicit).await;
        ctx.send_event(Event::ImmichLivePlacementCompleted {
            completion: Completion {
                owner,
                stage: Stage::Prepared(result),
            },
        });
    })
}

fn complete(model: &mut Model, completion: Completion) -> Command<Effect, Event> {
    let Some(_work) = model
        .live_placement
        .work
        .as_ref()
        .filter(|w| Arc::ptr_eq(&w.owner, &completion.owner))
    else {
        return Command::done();
    };
    match completion.stage {
        Stage::Prepared(result) => prepared_complete(model, completion.owner, result),
        Stage::Confirmed(result) => confirmed_complete(model, completion.owner, result),
        Stage::Captured(result) => captured_complete(model, &result),
        Stage::Drained(result) => drained_complete(model, completion.owner, result),
        Stage::Durable { state } => durable_complete(model, state),
        Stage::Finished(result) => finished_complete(model, result),
    }
}
fn drain(model: &Model, retry_cleanup: bool) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.work.as_ref() else {
        return Command::done();
    };
    let Some(prepared) = work.prepared.as_ref() else {
        return Command::done();
    };
    let owner = work.owner.clone();
    let Some(capture_id) = work.capture_id.clone() else {
        return Command::done();
    };
    let keys = prepared
        .batch
        .intent
        .resources
        .iter()
        .map(|r| r.initial.key.clone())
        .collect();
    let intent_digest = prepared.batch.intent.digest.clone();
    let live_pending = pending_live(&work.live);
    let video_pending = pending_video(&work.video);
    let cancel_before_capture = work.cancelled || work.capture != CaptureState::Accepted;
    Command::new(move |ctx| async move {
        let result = io(
            &ctx,
            ShellOperation::DrainCapturedPrivateMediaBatch {
                keys,
                capture_id,
                intent_digest,
                live_pending,
                video_pending,
                cancel_before_capture,
                retry_cleanup,
            },
        )
        .await;
        ctx.send_event(Event::ImmichLivePlacementCompleted {
            completion: Completion {
                owner,
                stage: Stage::Drained(result),
            },
        });
    })
}

async fn confirm(ctx: &Context, prepared: Prepared) -> Result<Prepared, String> {
    prepared.authority.valid()?;
    prepared
        .authority
        .session
        .verify_write_contract(ctx)
        .await?;
    fresh_graph(ctx, &prepared.authority, &prepared.batch).await?;
    let confirmed: bool = io(
        ctx,
        ShellOperation::ConfirmImmichLivePlacement {
            prompt: prepared.prompt.clone(),
        },
    )
    .await?;
    prepared.authority.valid()?;
    if !confirmed {
        return Err("変更をキャンセルしました。".into());
    }
    fresh_graph(ctx, &prepared.authority, &prepared.batch).await?;
    Ok(prepared)
}
async fn fresh_graph(
    ctx: &Context,
    authority: &Authority,
    batch: &Batch,
) -> Result<Vec<ResourceObservation>, String> {
    let expected = batch
        .steps
        .iter()
        .rev()
        .find_map(|step| match &step.outcome {
            Outcome::Applied { verified_post, .. } => Some(verified_post.resources.clone()),
            _ => None,
        })
        .unwrap_or_else(|| {
            batch
                .intent
                .resources
                .iter()
                .map(|r| ResourceObservation {
                    fact: r.initial.clone(),
                    albums: r.initial_albums.clone(),
                })
                .collect()
        });
    let mut observed = Vec::new();
    for resource in &batch.intent.resources {
        let role = if resource.initial.media == Media::Image {
            Role::Parent
        } else {
            Role::Motion
        };
        let (value, _) = prepare::observe(ctx, authority, &resource.initial.key, role).await?;
        observed.push(value);
    }
    if observed != expected {
        return Err(ERROR.into());
    }
    authority.valid()?;
    Ok(observed)
}

fn publish_durable(ctx: &Context, authority: &Authority, state: &SavedLibrary) {
    ctx.send_event(Event::ImmichLivePlacementCompleted {
        completion: Completion {
            owner: authority.owner.clone(),
            stage: Stage::Durable {
                state: Box::new(state.clone()),
            },
        },
    });
}

fn pending_live(captures: &[live::CapturedOwners]) -> Vec<live::ImmichLockedLivePending> {
    let mut pending = std::collections::BTreeMap::new();
    for item in captures.iter().flat_map(live::CapturedOwners::pending) {
        pending.insert((item.scene_id.clone(), item.request_id.clone()), item);
    }
    pending.into_values().collect()
}
fn pending_video(captures: &[video::CapturedOwner]) -> Vec<video::ImmichLockedVideoPending> {
    let mut pending = std::collections::BTreeMap::new();
    for item in captures.iter().flat_map(video::CapturedOwner::pending) {
        pending.insert((item.scene_id.clone(), item.request_id.clone()), item);
    }
    pending.into_values().collect()
}

fn prepared_complete(
    model: &mut Model,
    owner: Arc<()>,
    result: Result<Prepared, String>,
) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.work.as_ref() else {
        return Command::done();
    };

    let prepared = match result {
        Ok(prepared) if !work.cancelled && prepared.authority.valid().is_ok() => prepared,
        Ok(_) => {
            model.live_placement.work = None;
            model.busy = false;
            return Command::done();
        }
        Err(error) => {
            model.error = Some(error);
            model.live_placement.work = None;
            model.busy = false;
            return Command::done();
        }
    };
    if let Some(work) = model.live_placement.work.as_mut() {
        work.prepared = Some(prepared.clone());
    }
    Command::new(move |ctx| async move {
        let result = confirm(&ctx, prepared).await;
        ctx.send_event(Event::ImmichLivePlacementCompleted {
            completion: Completion {
                owner,
                stage: Stage::Confirmed(result),
            },
        });
    })
}

fn confirmed_complete(
    model: &mut Model,
    owner: Arc<()>,
    result: Result<Prepared, String>,
) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.work.as_ref() else {
        return Command::done();
    };

    let Ok(mut prepared) = result else {
        model.error = result.err();
        model.live_placement.work = None;
        model.busy = false;
        return Command::done();
    };
    if work.cancelled || prepared.authority.valid().is_err() {
        model.live_placement.work = None;
        model.busy = false;
        return Command::done();
    }
    let capture_id = match model.live_placement.next_capture() {
        Ok(id) => id,
        Err(error) => {
            model.error = Some(error);
            model.live_placement.work = None;
            model.busy = false;
            return Command::done();
        }
    };
    // Exact Rust owner sets and admission fences are captured synchronously.
    let keys: Vec<_> = prepared
        .batch
        .intent
        .resources
        .iter()
        .map(|r| r.initial.key.clone())
        .collect();
    let captured_live: Vec<_> = keys
        .iter()
        .map(|key| live::capture_owners(model, key))
        .collect();
    let captured_video: Vec<_> = keys
        .iter()
        .map(|key| video::capture_owner(model, key))
        .collect();
    model.live_placement.held.extend(keys.clone());
    let previous = model.ordinary_generation.fetch_add(1, Ordering::SeqCst);
    if prepared.authority.expected_ordinary != previous {
        model.live_placement.work = None;
        model.live_placement.held.clear();
        model.busy = false;
        return Command::done();
    }
    prepared.authority.expected_ordinary = previous + 1;
    let live_pending = pending_live(&captured_live);
    let video_pending = pending_video(&captured_video);
    let Some(work) = model.live_placement.work.as_mut() else {
        return Command::done();
    };
    work.prepared = Some(prepared.clone());
    work.capture_id = Some(capture_id.clone());
    work.live = captured_live;
    work.video = captured_video;
    Command::new(move |ctx| async move {
        let result = io(
            &ctx,
            ShellOperation::CapturePrivateMediaBatch {
                keys,
                capture_id,
                intent_digest: prepared.batch.intent.digest,
                live_pending,
                video_pending,
            },
        )
        .await;
        ctx.send_event(Event::ImmichLivePlacementCompleted {
            completion: Completion {
                owner,
                stage: Stage::Captured(result),
            },
        });
    })
}

fn captured_complete(model: &mut Model, result: &Result<(), String>) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.work.as_mut() else {
        return Command::done();
    };
    work.capture = if result.is_ok() {
        CaptureState::Accepted
    } else {
        CaptureState::Captured
    };
    let captured_live = work.live.clone();
    let captured_video = work.video.clone();
    let mut command = Command::done();
    for captured in &captured_live {
        command = command.and(live::retire_captured(model, captured));
    }
    for captured in &captured_video {
        command = command.and(video::retire_captured(model, captured));
    }
    command.and(drain(model, false))
}

fn drained_complete(
    model: &mut Model,
    owner: Arc<()>,
    result: Result<DrainReceipt, String>,
) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.work.as_ref() else {
        return Command::done();
    };
    let matches = result
        .as_ref()
        .is_ok_and(|receipt| Some(&receipt.capture_id) == work.capture_id.as_ref());
    if !matches {
        model.error =
            Some("プレビューと再生の終了を確認できません。終了処理の記録を保持しています。".into());
        model.busy = false;
        return Command::done();
    }
    let captured_live = work.live.clone();
    let captured_video = work.video.clone();
    let mut cleanup = Command::done();
    for captured in &captured_live {
        cleanup = cleanup.and(live::captured_drained(model, captured));
    }
    for captured in &captured_video {
        video::captured_drained(model, captured);
    }
    let Some(work) = model.live_placement.work.as_mut() else {
        return Command::done();
    };
    let Some(prepared) = work.prepared.clone() else {
        return Command::done();
    };
    if work.cancelled
        || work.capture != CaptureState::Accepted
        || result.is_ok_and(|r| r.cancelled_before_capture)
        || prepared.authority.valid().is_err()
    {
        model.live_placement.work = None;
        model.live_placement.held.clear();
        model.busy = false;
        return cleanup;
    }
    work.running = true;
    cleanup.and(Command::new(move |ctx| async move {
        let result = executor::execute(&ctx, prepared).await;
        ctx.send_event(Event::ImmichLivePlacementCompleted {
            completion: Completion {
                owner,
                stage: Stage::Finished(result),
            },
        });
    }))
}

fn durable_complete(model: &mut Model, state: Box<SavedLibrary>) -> Command<Effect, Event> {
    if validate_transition(&model.state, &state).is_err() {
        model.live_placement.persistence_uncertain = true;
        model.live_placement.epoch.fetch_add(1, Ordering::SeqCst);
        model.error = Some("変更記録が新しい状態と競合しました。書込みを停止しています。".into());
    } else {
        model.state.immich_live_operations = state.immich_live_operations;
        model.state.immich_live_unstarted_closures = state.immich_live_unstarted_closures;
        model.state.immich_live_legacy_reconciliations = state.immich_live_legacy_reconciliations;
    }
    Command::done()
}

fn finished_complete(model: &mut Model, result: executor::Finished) -> Command<Effect, Event> {
    model.live_placement.persistence_uncertain |= result.uncertain;
    if let Some(state) = result.state {
        if validate_transition(&model.state, &state).is_err() {
            model.live_placement.persistence_uncertain = true;
            model.busy = false;
            model.error = Some("新しい変更記録と競合しました。書込みは再送しません。".into());
            model.live_placement.work = None;
            return Command::done();
        }
        model.state.immich_live_operations = state.immich_live_operations;
        model.state.immich_live_unstarted_closures = state.immich_live_unstarted_closures;
        model.state.immich_live_legacy_reconciliations = state.immich_live_legacy_reconciliations;
    }
    model.status = result.status;
    model.busy = false;
    model.live_placement.work = None;
    if !result.uncertain {
        model.live_placement.held.clear();
    }
    Command::done()
}
