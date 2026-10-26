//! Read-only paired playback. Private completions fence staged files and native JOINs.
use super::ordinary::{self, PairPresentation, VerifiedPair};
use crate::{
    app::{Context, Effect, Event, Model, ShellOperation, io},
    domain::{AssetKey, ResourceRole, StoredAsset},
    immich::{
        HttpResponse, OrdinaryContentAuthorization, OrdinaryContentPurpose, OrdinarySessionGuard,
        Session,
    },
    media::{PlaybackKind, PlaybackPlan},
    workflow::HashResult,
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
const ERROR: &str = "Live Photo を通常表示できません。状態を更新してください。";
/// Stable End failure code from the Apple shell (`OrdinaryLivePairEffects`): native
/// can never prove its own terminal callback (invalid request / callback contract).
pub(crate) const NATIVE_TERMINAL_UNAVAILABLE: &str = "nativeTerminalUnavailable";
const NATIVE_UNCERTAIN: &str =
    "端末の再生処理の終了を確認できません。原本はアプリを終了するまで保持され、再試行できません。";

#[derive(Debug, Default)]
pub struct State {
    epoch: Arc<AtomicU64>,
    proofs: BTreeMap<AssetKey, VerifiedPair>,
    work: Option<Work>,
    used: BTreeSet<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Refreshing,
    Acquiring,
    Playing,
    Cleaning,
    FailedCleanup,
    /// Native ownership can never be proven ended; the work stays to block reads,
    /// with no cleanup retry until the process exits.
    NativeUncertain,
}
#[derive(Debug)]
struct Work {
    owner: Arc<()>,
    parent_key: Option<AssetKey>,
    request_id: String,
    phase: Phase,
    proof: Option<VerifiedPair>,
    scope_id: Option<String>,
    workspace: Option<String>,
    begin_issued: bool,
    /// The user explicitly stopped this read; its terminal failure is not an error.
    stopped: bool,
}
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Arc<()>,
    stage: Stage,
}
#[derive(Debug, Clone)]
enum Stage {
    Refreshed(Result<Vec<VerifiedPair>, String>),
    Acquired(Acquired),
    Played(Result<(), String>),
    Cleaned(Result<(), String>),
}
#[derive(Debug, Clone)]
struct Acquired {
    workspace: Option<String>,
    begin_issued: bool,
    plan: Result<PlaybackPlan, String>,
}
#[derive(Deserialize)]
struct Original {
    response: HttpResponse,
    hash: HashResult,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinaryLivePairAction {
    pub parent_key: AssetKey,
    pub can_refresh: bool,
    pub can_play: bool,
    #[serde(rename = "cleanupRequestID")]
    pub cleanup_request_id: Option<String>,
}
/// Read/play/cleanup affordances only; none unlock operation admission.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinaryLiveReadProgress {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub phase: String,
    pub can_cancel: bool,
}
pub(crate) fn progress(model: &Model) -> Option<OrdinaryLiveReadProgress> {
    let work = model.ordinary_live.work.as_ref()?;
    let phase = match work.phase {
        Phase::Refreshing => "通常表示を確認中…",
        Phase::Acquiring => "再生用の原本を確認中…",
        Phase::Playing => "Live Photo を再生中",
        Phase::Cleaning => "作業データを片付け中…",
        Phase::FailedCleanup => "後片付けの再試行が必要です",
        Phase::NativeUncertain => NATIVE_UNCERTAIN,
    };
    Some(OrdinaryLiveReadProgress {
        request_id: work.request_id.clone(),
        phase: phase.into(),
        can_cancel: matches!(
            work.phase,
            Phase::Refreshing | Phase::Acquiring | Phase::Playing
        ),
    })
}

pub(crate) fn actions(model: &Model) -> Vec<OrdinaryLivePairAction> {
    let evaluation = ordinary::Evaluation::new(model);
    let mut rows = BTreeMap::new();
    let idle = model.ordinary_live.work.is_none();
    for proof in model.ordinary_live.proofs.values() {
        if let Some(presentation) = proof.presentation_with(&evaluation) {
            rows.insert(
                presentation.parent_key.clone(),
                OrdinaryLivePairAction {
                    parent_key: presentation.parent_key,
                    can_refresh: idle,
                    can_play: idle,
                    cleanup_request_id: None,
                },
            );
        }
    }
    if let Some(work) = model
        .ordinary_live
        .work
        .as_ref()
        .filter(|w| w.phase == Phase::FailedCleanup)
        && let Some(parent) = &work.parent_key
    {
        // This locator exposes only the exact local cleanup obligation. It is
        // never permission to read metadata or replay content in another account.
        rows.insert(
            parent.clone(),
            OrdinaryLivePairAction {
                parent_key: parent.clone(),
                can_refresh: false,
                can_play: false,
                cleanup_request_id: Some(work.request_id.clone()),
            },
        );
    }
    rows.into_values().collect()
}

/// Display-only clone for paired raster admission; never operation authority.
pub(crate) fn image_proof(model: &Model, parent: &AssetKey) -> Option<VerifiedPair> {
    model
        .ordinary_live
        .proofs
        .get(parent)
        .filter(|p| p.current(model))
        .cloned()
}

pub(crate) fn has_image_proof(
    model: &Model,
    parent: &AssetKey,
    id: &str,
    evaluation: &ordinary::Evaluation<'_>,
) -> bool {
    model
        .ordinary_live
        .proofs
        .get(parent)
        .and_then(|p| p.presentation_with(evaluation))
        .is_some_and(|p| p.proof_id == id)
}

/// Capture exact overlapping display proof IDs so late failures cannot revoke replacements.
pub(crate) fn image_related_proofs(
    model: &Model,
    selected: &PairPresentation,
) -> Vec<(AssetKey, String)> {
    presentations(model)
        .into_iter()
        .filter(|p| {
            p.generation == selected.generation
                && [p.parent_key.clone(), p.motion_key.clone()]
                    .iter()
                    .any(|key| key == &selected.parent_key || key == &selected.motion_key)
        })
        .map(|p| (p.parent_key, p.proof_id))
        .collect()
}
/// A failed read-only witness revokes display proofs, never journal history or write authority.
pub(crate) fn invalidate_image_proofs(model: &mut Model, captured: &[(AssetKey, String)]) {
    for (key, id) in captured {
        if model
            .ordinary_live
            .proofs
            .get(key)
            .and_then(|p| p.presentation(model))
            .is_some_and(|p| p.proof_id == *id)
        {
            model.ordinary_live.proofs.remove(key);
        }
    }
}

pub(crate) fn presentations(model: &Model) -> Vec<PairPresentation> {
    let evaluation = ordinary::Evaluation::new(model);
    model
        .ordinary_live
        .proofs
        .values()
        .filter_map(|p| p.presentation_with(&evaluation))
        .collect()
}
pub(crate) fn assets(model: &Model) -> Vec<StoredAsset> {
    let evaluation = ordinary::Evaluation::new(model);
    model
        .ordinary_live
        .proofs
        .values()
        .filter_map(|p| p.assets_with(&evaluation))
        .flatten()
        .collect()
}
/// Native read membership only. Never feed this to mutation/transfer/delete admission.
#[allow(dead_code)] // Read-only integration accessor; generic operation membership stays fenced.
pub(crate) fn membership(model: &Model) -> Vec<AssetKey> {
    presentations(model)
        .into_iter()
        .flat_map(|p| [p.parent_key, p.motion_key])
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}
fn uuid() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| ERROR)?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let h = crate::domain::hex(&bytes);
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    ))
}
fn publish(ctx: &Context, owner: Arc<()>, stage: Stage) {
    ctx.send_event(Event::OrdinaryLivePairCompleted {
        completion: Completion { owner, stage },
    });
}
fn fail(model: &mut Model) -> Command<Effect, Event> {
    model.error = Some(ERROR.into());
    Command::done()
}
fn admit_request(state: &mut State, id: &str) -> bool {
    !id.trim().is_empty()
        && id.len() <= 128
        && state.used.len() < 4096
        && state.used.insert(id.into())
}
pub(crate) fn update(event: &Event, model: &mut Model) -> Option<Command<Effect, Event>> {
    match event {
        Event::RefreshOrdinaryLivePairs { request_id } => Some(refresh_all(model, request_id)),
        Event::RefreshOrdinaryLivePair {
            parent_key,
            request_id,
        } => Some(refresh(model, parent_key, request_id)),
        Event::PlayOrdinaryLivePair {
            parent_key,
            request_id,
        } => Some(play(model, parent_key, request_id)),
        Event::CancelOrdinaryLivePair { request_id } => {
            if model
                .ordinary_live
                .work
                .as_ref()
                .is_some_and(|w| w.request_id == *request_id)
            {
                model.ordinary_live.epoch.fetch_add(1, Ordering::SeqCst);
                model.ordinary_live.proofs.clear();
                if let Some(work) = model.ordinary_live.work.as_mut() {
                    work.stopped = true;
                }
                if let Some(scope_id) = model
                    .ordinary_live
                    .work
                    .as_ref()
                    .and_then(|w| w.scope_id.clone())
                {
                    // Seal/cancel the native scope now, while retaining the work
                    // until its private callback and final cleanup JOIN settle.
                    return Some(Command::new(move |ctx| async move {
                        let _: Result<Value, _> = io(
                            &ctx,
                            ShellOperation::EndOrdinaryLivePairRead {
                                scope_id,
                                retry_cleanup: false,
                            },
                        )
                        .await;
                    }));
                }
            }
            Some(Command::done())
        }
        Event::RetryOrdinaryLivePairCleanup { request_id } => {
            let matches =
                model.ordinary_live.work.as_ref().is_some_and(|w| {
                    w.request_id == *request_id && w.phase == Phase::FailedCleanup
                });
            Some(if matches {
                cleanup(model, true)
            } else {
                Command::done()
            })
        }
        Event::OrdinaryLivePairCompleted { completion } => {
            Some(complete(model, completion.clone()))
        }
        _ => None,
    }
}
fn refresh(model: &mut Model, parent: &AssetKey, request: &str) -> Command<Effect, Event> {
    if model.ordinary_live.work.is_some() || !admit_request(&mut model.ordinary_live, request) {
        return fail(model);
    }
    let epoch = model
        .ordinary_live
        .epoch
        .fetch_add(1, Ordering::SeqCst)
        .wrapping_add(1);
    model.ordinary_live.proofs.clear();
    let Ok(request_data) =
        ordinary::Request::capture(model, parent, model.ordinary_live.epoch.clone(), epoch)
    else {
        return fail(model);
    };
    let owner = Arc::new(());
    model.ordinary_live.work = Some(Work {
        owner: owner.clone(),
        parent_key: Some(parent.clone()),
        request_id: request.into(),
        phase: Phase::Refreshing,
        proof: None,
        scope_id: None,
        workspace: None,
        begin_issued: false,
        stopped: false,
    });
    Command::new(move |ctx| async move {
        let result = ordinary::fetch(&ctx, request_data).await;
        publish(
            &ctx,
            owner,
            Stage::Refreshed(result.map(|proof| vec![proof])),
        );
    })
}
fn refresh_all(model: &mut Model, request: &str) -> Command<Effect, Event> {
    if model.ordinary_live.work.is_some() || !admit_request(&mut model.ordinary_live, request) {
        return fail(model);
    }
    let Some(session) = model.session.as_ref() else {
        return fail(model);
    };
    let parents: Vec<_> = model
        .state
        .immich_live_operations
        .iter()
        .filter(|batch| {
            batch.intent.scope == session.scope && batch.intent.owner_id == session.user_id
        })
        .flat_map(|batch| batch.intent.selections.iter().map(|s| s.parent.clone()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let epoch = model
        .ordinary_live
        .epoch
        .fetch_add(1, Ordering::SeqCst)
        .wrapping_add(1);
    model.ordinary_live.proofs.clear();
    let Ok(source) = ordinary::Source::capture(model, model.ordinary_live.epoch.clone(), epoch)
    else {
        return fail(model);
    };
    let owner = Arc::new(());
    model.ordinary_live.work = Some(Work {
        owner: owner.clone(),
        parent_key: None,
        request_id: request.into(),
        phase: Phase::Refreshing,
        proof: None,
        scope_id: None,
        workspace: None,
        begin_issued: false,
        stopped: false,
    });
    Command::new(move |ctx| async move {
        let mut proofs = Vec::new();
        // All current-account candidates are visited, with one request in flight
        // and one shared immutable catalog origin. A cancelled cursor stops here.
        for parent in parents {
            if source.valid().is_err() {
                break;
            }
            if let Ok(request) = source.request(&parent)
                && let Ok(proof) = ordinary::fetch(&ctx, request).await
            {
                proofs.push(proof);
            }
        }
        publish(&ctx, owner, Stage::Refreshed(Ok(proofs)));
    })
}

fn play(model: &mut Model, parent: &AssetKey, request: &str) -> Command<Effect, Event> {
    if model.ordinary_live.work.is_some() || !admit_request(&mut model.ordinary_live, request) {
        return fail(model);
    }
    let Some(proof) = model
        .ordinary_live
        .proofs
        .get(parent)
        .filter(|p| p.current(model))
        .cloned()
    else {
        return fail(model);
    };
    let Some(presentation) = proof.presentation(model) else {
        return fail(model);
    };
    let Some(records) = proof.assets(model) else {
        return fail(model);
    };
    let [asset] = records.as_slice() else {
        return fail(model);
    };
    let Some(mut session) = model.session.clone() else {
        return fail(model);
    };
    let Ok(scope_id) = uuid() else {
        return fail(model);
    };
    let expected = crate::ordinary_selected::generation(model);
    session.ordinary_content_guard = Some(OrdinarySessionGuard {
        generation: model.ordinary_generation.clone(),
        expected,
    });
    session.ordinary_content_context = Some(OrdinaryContentAuthorization {
        source_keys: vec![
            presentation.parent_key.clone(),
            presentation.motion_key.clone(),
        ],
        expected_revision: crate::app::ordinary_revision(Some(&session.scope), expected),
        purpose: OrdinaryContentPurpose::Read,
    });
    let owner = Arc::new(());
    let asset = asset.clone();
    model.ordinary_live.work = Some(Work {
        owner: owner.clone(),
        parent_key: Some(parent.clone()),
        request_id: request.into(),
        phase: Phase::Acquiring,
        proof: Some(proof.clone()),
        scope_id: Some(scope_id.clone()),
        workspace: None,
        begin_issued: false,
        stopped: false,
    });
    Command::new(move |ctx| async move {
        let result = acquire(&ctx, &proof, &session, &presentation, &asset, &scope_id).await;
        publish(&ctx, owner, Stage::Acquired(result));
    })
}
async fn acquire(
    ctx: &Context,
    proof: &VerifiedPair,
    session: &Session,
    presentation: &PairPresentation,
    asset: &StoredAsset,
    scope_id: &str,
) -> Acquired {
    let mut acquired = Acquired {
        workspace: None,
        begin_issued: false,
        plan: Err(ERROR.into()),
    };
    acquired.plan = async {
        // Revalidation is read-only; native ownership precedes original bytes.
        proof.revalidate(ctx).await?;
        let workspace: String = io(
            ctx,
            ShellOperation::Workspace {
                id: scope_id.into(),
            },
        )
        .await?;
        let expected_name = format!("suwop-{scope_id}");
        if !workspace.starts_with('/')
            || workspace.split('/').any(|s| matches!(s, "." | ".."))
            || workspace.rsplit('/').next() != Some(expected_name.as_str())
        {
            return Err(ERROR.into());
        }
        acquired.workspace = Some(workspace.clone());
        acquired.begin_issued = true;
        let began: bool = io(
            ctx,
            ShellOperation::BeginOrdinaryLivePairRead {
                scope_id: scope_id.into(),
                keys: vec![
                    presentation.parent_key.clone(),
                    presentation.motion_key.clone(),
                ],
                workspace: workspace.clone(),
                presentation: presentation.clone(),
            },
        )
        .await?;
        if !began {
            // End must recheck this sealed, never-registered scope's canonical
            // workspace: creation may have completed after cancellation's End.
            return Err(ERROR.into());
        }
        proof.revalidate(ctx).await?;
        let paths = originals(ctx, session, presentation, asset, scope_id, &workspace).await?;
        proof.revalidate(ctx).await?;
        Ok(PlaybackPlan {
            source_keys: vec![
                presentation.parent_key.clone(),
                presentation.motion_key.clone(),
            ],
            kind: PlaybackKind::Live,
            name: asset.name.clone(),
            files: paths,
        })
    }
    .await;
    acquired
}
async fn originals(
    ctx: &Context,
    session: &Session,
    presentation: &PairPresentation,
    asset: &StoredAsset,
    scope_id: &str,
    workspace: &str,
) -> Result<Vec<String>, String> {
    let mut paths = Vec::new();
    for (index, (key, roles)) in [
        (
            &presentation.parent_key,
            &[ResourceRole::Image, ResourceRole::RawImage][..],
        ),
        (&presentation.motion_key, &[ResourceRole::LiveVideo][..]),
    ]
    .into_iter()
    .enumerate()
    {
        let candidates: Vec<_> = asset
            .resources
            .iter()
            .filter(|r| r.id == key.asset_id && roles.contains(&r.role))
            .collect();
        let [resource] = candidates.as_slice() else {
            return Err(ERROR.into());
        };
        let checksum = crate::domain::normalize_sha1(resource.sha1.as_deref()).ok_or(ERROR)?;
        let path = format!(
            "{workspace}/{index}/{}",
            crate::sharing::filename(&resource.name)?
        );
        if !crate::sharing::contains_file(workspace, &path) {
            return Err(ERROR.into());
        }
        let mut request = session.request(
            &format!("assets/{}/original?edited=false", key.asset_id),
            "GET",
            None,
        );
        request.download_path = Some(path.clone());
        // Bind each original read to its own physical key, not a grouping hint.
        request.ordinary_content_authorization = Some(OrdinaryContentAuthorization {
            source_keys: vec![key.clone()],
            expected_revision: crate::app::ordinary_revision(
                Some(&session.scope),
                presentation.generation,
            ),
            purpose: OrdinaryContentPurpose::Read,
        });
        let original: Original = io(
            ctx,
            ShellOperation::OrdinaryLivePairReadHttp {
                scope_id: scope_id.into(),
                request,
            },
        )
        .await?;
        session.check_content_guard()?;
        crate::immich::check_status(original.response.status)?;
        if crate::domain::normalize_sha1(Some(&original.hash.sha1)).as_deref() != Some(&checksum)
            || !original.hash.signature.valid()
        {
            return Err(ERROR.into());
        }
        paths.push(path);
    }
    Ok(paths)
}

fn complete(model: &mut Model, completion: Completion) -> Command<Effect, Event> {
    let Some(work) = model.ordinary_live.work.as_ref() else {
        return Command::done();
    };
    if !Arc::ptr_eq(&work.owner, &completion.owner) {
        return Command::done();
    }
    match completion.stage {
        Stage::Refreshed(result) if work.phase == Phase::Refreshing => {
            model.ordinary_live.work = None;
            match result {
                Ok(proofs) => {
                    let evaluation = ordinary::Evaluation::new(model);
                    let admitted: Vec<_> = proofs
                        .into_iter()
                        .filter_map(|proof| {
                            proof
                                .presentation_with(&evaluation)
                                .map(|p| (p.parent_key, proof))
                        })
                        .collect();
                    for (parent, proof) in admitted {
                        model.ordinary_live.proofs.insert(parent, proof);
                    }
                    model.error = None;
                }
                _ => {
                    model.error = Some(ERROR.into());
                }
            }
            Command::done()
        }
        Stage::Acquired(acquired) if work.phase == Phase::Acquiring => {
            let admitted = work.proof.as_ref().is_some_and(|p| p.current(model));
            let Some(work) = model.ordinary_live.work.as_mut() else {
                return Command::done();
            };
            work.workspace = acquired.workspace;
            work.begin_issued = acquired.begin_issued;
            if let Ok(plan) = acquired.plan
                && admitted
            {
                let owner = work.owner.clone();
                let Some(scope_id) = work.scope_id.clone() else {
                    return cleanup(model, false);
                };
                work.phase = Phase::Playing;
                return Command::new(move |ctx| async move {
                    let result = io::<Value>(
                        &ctx,
                        ShellOperation::PlayOrdinaryLivePairRead { scope_id, plan },
                    )
                    .await
                    .map(|_| ());
                    publish(&ctx, owner, Stage::Played(result));
                });
            }
            if !work.stopped {
                model.error = Some(ERROR.into());
            }
            cleanup(model, false)
        }
        Stage::Played(result) if work.phase == Phase::Playing => {
            if result.is_err() && !work.stopped {
                model.error = Some(ERROR.into());
            }
            cleanup(model, false)
        }
        Stage::Cleaned(result) if work.phase == Phase::Cleaning => {
            match result {
                Ok(()) => model.ordinary_live.work = None,
                Err(code) if code == NATIVE_TERMINAL_UNAVAILABLE => {
                    if let Some(work) = model.ordinary_live.work.as_mut() {
                        work.phase = Phase::NativeUncertain;
                    }
                    model.error = Some(NATIVE_UNCERTAIN.into());
                }
                Err(_) => {
                    if let Some(work) = model.ordinary_live.work.as_mut() {
                        work.phase = Phase::FailedCleanup;
                    }
                    model.error = Some(
                        "再生用データの後片付けを確認できません。明示的に再試行してください。"
                            .into(),
                    );
                }
            }
            Command::done()
        }
        _ => Command::done(),
    }
}
fn cleanup(model: &mut Model, retry: bool) -> Command<Effect, Event> {
    let Some(work) = model.ordinary_live.work.as_mut() else {
        return Command::done();
    };
    let Some(workspace) = work.workspace.clone() else {
        model.ordinary_live.work = None;
        return Command::done();
    };
    let owner = work.owner.clone();
    let scope = work.scope_id.clone();
    let began = work.begin_issued;
    work.phase = Phase::Cleaning;
    Command::new(move |ctx| async move {
        let result = if began {
            if let Some(scope_id) = scope {
                io::<Value>(
                    &ctx,
                    ShellOperation::EndOrdinaryLivePairRead {
                        scope_id,
                        retry_cleanup: retry,
                    },
                )
                .await
            } else {
                Err(ERROR.into())
            }
        } else {
            io::<Value>(&ctx, ShellOperation::Cleanup { path: workspace }).await
        };
        publish(&ctx, owner, Stage::Cleaned(result.map(|_| ())));
    })
}

#[cfg(test)]
mod tests;
