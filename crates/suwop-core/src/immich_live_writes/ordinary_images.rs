//! Exact paired still-raster reads. No operation or original-download authority.
use super::ordinary::PairPresentation;
use super::{ordinary::VerifiedPair, ordinary_runtime};
use crate::{
    app::{Context, Effect, Event, Model, ShellOperation, io},
    domain::AssetKey,
    immich::HttpRequest,
    ordinary_selected::OrdinarySelectedImageKind,
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

static OWNERS: AtomicU64 = AtomicU64::new(1);
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairImageTicket {
    #[serde(rename = "ownerID")]
    pub owner_id: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub presentation: PairPresentation,
    pub kind: OrdinarySelectedImageKind,
    pub expected_revision: String,
    pub request: HttpRequest,
}
impl std::fmt::Debug for PairImageTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairImageTicket([redacted])")
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairImagePending {
    #[serde(rename = "ownerID")]
    pub owner_id: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub presentation: PairPresentation,
    pub kind: OrdinarySelectedImageKind,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairImageAccess {
    #[serde(rename = "ownerID")]
    pub owner_id: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub presentation: PairPresentation,
    pub kind: OrdinarySelectedImageKind,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairImageResult {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
/// The native adapter step that is about to execute or publish a ticket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PairImagePhase {
    Read,
    Publish,
}
#[derive(Debug, Default)]
pub struct State {
    active: BTreeMap<String, Work>,
}
#[derive(Debug)]
struct Work {
    owner: Arc<()>,
    ticket: PairImageTicket,
    proof: VerifiedPair,
    access: Option<PairImageAccess>,
    publishing: bool,
    related: Vec<(AssetKey, String)>,
}
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Arc<()>,
    ticket: PairImageTicket,
    stage: Stage,
}
#[derive(Debug, Clone)]
enum Stage {
    Read(Result<PairImageResult, ReadFailure>),
    Published(String, bool, bool),
}
#[derive(Debug, Clone)]
enum ReadFailure {
    Freshness,
    Raster,
}
fn current(model: &Model, work: &Work, evaluation: &super::ordinary::Evaluation<'_>) -> bool {
    work.proof.current_with(evaluation)
        && ordinary_runtime::has_image_proof(
            model,
            &work.ticket.presentation.parent_key,
            &work.ticket.presentation.proof_id,
            evaluation,
        )
}
fn same_ticket(lhs: &PairImageTicket, rhs: &PairImageTicket) -> bool {
    match (serde_json::to_value(lhs), serde_json::to_value(rhs)) {
        (Ok(lhs), Ok(rhs)) => lhs == rhs,
        _ => false,
    }
}
/// True only for the exact private ticket this Core issued to the current owner:
/// request URL/headers/body/fields/files/download path, expected parent revision,
/// owner/request/scene/kind/proof and the current Read or Publish phase. The public
/// pending view never carries request bytes, so native code must ask before and
/// after every awaited raster step instead of checking routes itself.
#[must_use]
pub fn ticket_issued(model: &Model, ticket: &PairImageTicket, phase: PairImagePhase) -> bool {
    let Some(work) = model.ordinary_live_images.active.get(&ticket.owner_id) else {
        return false;
    };
    let phase_current = work.access.is_none()
        && match phase {
            PairImagePhase::Read => !work.publishing,
            PairImagePhase::Publish => work.publishing,
        };
    // `expected_revision` is part of the issued ticket, so equality binds it too.
    phase_current
        && same_ticket(&work.ticket, ticket)
        && current(model, work, &super::ordinary::Evaluation::new(model))
}
pub(crate) fn pending(model: &Model) -> Vec<PairImagePending> {
    let evaluation = super::ordinary::Evaluation::new(model);
    model
        .ordinary_live_images
        .active
        .values()
        .filter(|w| w.access.is_none() && current(model, w, &evaluation))
        .map(|w| PairImagePending {
            owner_id: w.ticket.owner_id.clone(),
            request_id: w.ticket.request_id.clone(),
            scene_id: w.ticket.scene_id.clone(),
            presentation: w.ticket.presentation.clone(),
            kind: w.ticket.kind,
        })
        .collect()
}
pub(crate) fn images(model: &Model) -> Vec<PairImageAccess> {
    let evaluation = super::ordinary::Evaluation::new(model);
    model
        .ordinary_live_images
        .active
        .values()
        .filter(|w| current(model, w, &evaluation))
        .filter_map(|w| w.access.clone())
        .collect()
}
fn release(owner_id: String) -> Command<Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<serde_json::Value, _> = io(
            &ctx,
            ShellOperation::ReleaseOrdinaryLivePairImage { owner_id },
        )
        .await;
    })
}
fn cancel(model: &mut Model, scene: &str, id: Option<&str>) -> Command<Effect, Event> {
    let ids = model
        .ordinary_live_images
        .active
        .iter()
        .filter(|(_, w)| {
            w.ticket.scene_id == scene && id.is_none_or(|id| w.ticket.request_id == id)
        })
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    retire(model, ids)
}
fn retire(model: &mut Model, ids: Vec<String>) -> Command<Effect, Event> {
    let mut command = Command::done();
    for id in ids {
        model.ordinary_live_images.active.remove(&id);
        command = command.and(release(id));
    }
    command
}
pub(crate) fn reconcile(model: &mut Model) -> Command<Effect, Event> {
    let evaluation = super::ordinary::Evaluation::new(model);
    let ids = model
        .ordinary_live_images
        .active
        .iter()
        .filter(|(_, w)| !current(model, w, &evaluation))
        .map(|(id, _)| id.clone())
        .collect();
    retire(model, ids)
}
fn admit(
    model: &Model,
    key: &AssetKey,
    scene: &str,
    id: &str,
    kind: OrdinarySelectedImageKind,
) -> Option<(VerifiedPair, PairImageTicket)> {
    if crate::immich::valid_id(scene).is_err() || crate::immich::valid_id(id).is_err() {
        return None;
    }
    let proof = ordinary_runtime::image_proof(model, key)?;
    let presentation = proof.presentation(model)?;
    let parent = proof.assets(model)?.into_iter().find(|a| a.key == *key)?;
    let mut request = model
        .session
        .as_ref()?
        .preview_request(&key.asset_id, kind == OrdinarySelectedImageKind::Preview)
        .ok()?;
    // This request is executable only by the proof-owned native adapter.
    request.ordinary_content_authorization = None;
    let sequence = OWNERS.fetch_add(1, Ordering::Relaxed);
    if sequence == u64::MAX {
        return None;
    }
    Some((
        proof,
        PairImageTicket {
            owner_id: format!("{id}:{sequence}"),
            request_id: id.into(),
            scene_id: scene.into(),
            presentation,
            kind,
            expected_revision: parent.revision,
            request,
        },
    ))
}
fn request(
    model: &mut Model,
    key: &AssetKey,
    scene: &str,
    id: &str,
    kind: OrdinarySelectedImageKind,
) -> Command<Effect, Event> {
    let Some((proof, ticket)) = admit(model, key, scene, id, kind) else {
        return Command::done();
    };
    let superseded = model
        .ordinary_live_images
        .active
        .iter()
        .filter(|(_, w)| {
            w.ticket.scene_id == scene
                && (w.ticket.request_id == id
                    || (w.ticket.kind == kind
                        && (kind == OrdinarySelectedImageKind::Preview
                            || w.ticket.presentation.parent_key == *key)))
        })
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    if model
        .ordinary_live_images
        .active
        .values()
        .filter(|w| w.access.is_none() && !superseded.contains(&w.ticket.owner_id))
        .count()
        >= 64
    {
        return Command::done();
    }
    let cleanup = retire(model, superseded);
    let related = ordinary_runtime::image_related_proofs(model, &ticket.presentation);
    let owner = Arc::new(());
    model.ordinary_live_images.active.insert(
        ticket.owner_id.clone(),
        Work {
            owner: owner.clone(),
            ticket: ticket.clone(),
            proof: proof.clone(),
            access: None,
            publishing: false,
            related,
        },
    );
    cleanup.and(Command::new(move |ctx| async move {
        let result = read(&ctx, &proof, &ticket).await;
        ctx.send_event(Event::OrdinaryLivePairImageCompleted {
            completion: Completion {
                owner,
                ticket,
                stage: Stage::Read(result),
            },
        });
    }))
}
async fn read(
    ctx: &Context,
    proof: &VerifiedPair,
    ticket: &PairImageTicket,
) -> Result<PairImageResult, ReadFailure> {
    proof
        .revalidate(ctx)
        .await
        .map_err(|_| ReadFailure::Freshness)?;
    let result: PairImageResult = io(
        ctx,
        ShellOperation::ReadOrdinaryLivePairImage {
            ticket: ticket.clone(),
        },
    )
    .await
    .map_err(|_| ReadFailure::Raster)?;
    if result.request_id != ticket.request_id || result.staged_id.is_empty() {
        return Err(ReadFailure::Raster);
    }
    proof
        .revalidate(ctx)
        .await
        .map_err(|_| ReadFailure::Freshness)?;
    Ok(result)
}
fn completed(model: &mut Model, completion: Completion) -> Command<Effect, Event> {
    let Completion {
        owner,
        ticket,
        stage,
    } = completion;
    let live = model
        .ordinary_live_images
        .active
        .get(&ticket.owner_id)
        .filter(|w| {
            Arc::ptr_eq(&w.owner, &owner)
                && w.ticket.request_id == ticket.request_id
                && w.ticket.scene_id == ticket.scene_id
                && w.ticket.kind == ticket.kind
                && w.ticket.presentation.proof_id == ticket.presentation.proof_id
                && current(model, w, &super::ordinary::Evaluation::new(model))
        });
    let Some(work) = live else {
        return release(ticket.owner_id);
    };
    let expected_stage = match &stage {
        Stage::Read(_) => !work.publishing && work.access.is_none(),
        Stage::Published(_, _, _) => work.publishing && work.access.is_none(),
    };
    if !expected_stage {
        return Command::done();
    }
    let related = work.related.clone();
    match stage {
        Stage::Read(Ok(result)) => {
            let proof = work.proof.clone();
            if let Some(work) = model.ordinary_live_images.active.get_mut(&ticket.owner_id) {
                work.publishing = true;
            }
            Command::new(move |ctx| async move {
                let published: Result<PairImageResult, _> = io(
                    &ctx,
                    ShellOperation::PublishOrdinaryLivePairImage {
                        ticket: ticket.clone(),
                        staged_id: result.staged_id.clone(),
                    },
                )
                .await;
                let native = published.is_ok_and(|p| {
                    p.request_id == ticket.request_id && p.staged_id == result.staged_id
                });
                let stale = native && proof.revalidate(&ctx).await.is_err();
                let approved = native && !stale;
                ctx.send_event(Event::OrdinaryLivePairImageCompleted {
                    completion: Completion {
                        owner,
                        ticket,
                        stage: Stage::Published(result.staged_id, approved, stale),
                    },
                });
            })
        }
        Stage::Published(staged_id, true, _) => {
            if let Some(work) = model.ordinary_live_images.active.get_mut(&ticket.owner_id) {
                work.access = Some(PairImageAccess {
                    owner_id: ticket.owner_id,
                    request_id: ticket.request_id,
                    scene_id: ticket.scene_id,
                    presentation: ticket.presentation,
                    kind: ticket.kind,
                    staged_id,
                });
            }
            Command::done()
        }
        Stage::Read(Err(ReadFailure::Freshness)) | Stage::Published(_, false, true) => {
            ordinary_runtime::invalidate_image_proofs(model, &related);
            retire(model, vec![ticket.owner_id])
        }
        Stage::Read(Err(ReadFailure::Raster)) | Stage::Published(_, false, false) => {
            retire(model, vec![ticket.owner_id])
        }
    }
}
pub(crate) fn update(event: &Event, model: &mut Model) -> Option<Command<Effect, Event>> {
    Some(match event {
        Event::RequestOrdinaryLivePairImage {
            parent_key,
            scene_id,
            request_id,
            kind,
        } => request(model, parent_key, scene_id, request_id, *kind),
        Event::CancelOrdinaryLivePairImage {
            scene_id,
            request_id,
        } => cancel(model, scene_id, request_id.as_deref()),
        Event::OrdinaryLivePairImageCompleted { completion } => {
            completed(model, completion.clone())
        }
        _ => return None,
    })
}

#[cfg(test)]
mod tests;
