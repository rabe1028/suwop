use super::{
    OrdinarySelectedImageAccess, OrdinarySelectedImageKind, OrdinarySelectedImageResult,
    OrdinarySelectedImageTicket, VerifiedPresentation, proof_id,
};
use crate::{
    app::{Context, Effect, Event, Model, ShellOperation, io},
    domain::AssetKey,
    immich::{OrdinaryContentAuthorization, OrdinaryContentPurpose, Session},
};
use crux_core::Command;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
type Slot = (String, AssetKey, OrdinarySelectedImageKind);
fn slot(t: &OrdinarySelectedImageTicket) -> Slot {
    (t.scene_id.clone(), t.key.clone(), t.kind)
}
fn release(id: String) -> Command<Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<serde_json::Value, _> = io(
            &ctx,
            ShellOperation::ReleaseOrdinarySelectedImage { staged_id: id },
        )
        .await;
    })
}
fn current(model: &Model, t: &OrdinarySelectedImageTicket) -> bool {
    model.ordinary_selected.proofs.get(&t.key).is_some_and(|p| {
        p.current(model) && proof_id(p) == t.proof_id && p.asset.revision == t.expected_revision
    }) && model
        .ordinary_selected
        .pending
        .get(&slot(t))
        .is_some_and(|p| p.request_id == t.request_id)
}
async fn fresh(
    ctx: &Context,
    session: &Session,
    proof: &VerifiedPresentation,
    generation: &AtomicU64,
) -> Result<(), String> {
    let check = || {
        if generation.load(Ordering::SeqCst) == proof.generation {
            Ok(())
        } else {
            Err("写真へのアクセスが変わりました。".to_string())
        }
    };
    check()?;
    let mut request = session.request(&format!("assets/{}", proof.asset.key.asset_id), "GET", None);
    request.ordinary_content_authorization = Some(OrdinaryContentAuthorization {
        source_keys: vec![proof.asset.key.clone()],
        expected_revision: crate::app::ordinary_revision(Some(&session.scope), proof.generation),
        purpose: OrdinaryContentPurpose::SelectedPresentationMetadata,
    });
    let response: crate::immich::HttpResponse = io(ctx, ShellOperation::Http(request))
        .await
        .map_err(|_| "写真を確認できません。")?;
    check()?;
    crate::immich::check_status(response.status)?;
    proof.verify_raw(&response.body)
}
fn clear_key(model: &mut Model, key: &AssetKey) -> Command<Effect, Event> {
    model.ordinary_selected.proofs.remove(key);
    model
        .ordinary_selected
        .pending
        .retain(|(_, k, _), _| k != key);
    let old = std::mem::take(&mut model.ordinary_selected.images);
    let mut command = Command::done();
    for image in old {
        if image.key == *key {
            command = command.and(release(image.staged_id));
        } else {
            model.ordinary_selected.images.push(image);
        }
    }
    command
}
fn cancel(model: &mut Model, scene: &str, request: Option<&str>) -> Command<Effect, Event> {
    model
        .ordinary_selected
        .pending
        .retain(|(s, _, _), t| s != scene || request.is_some_and(|r| t.request_id != r));
    let old = std::mem::take(&mut model.ordinary_selected.images);
    let mut command = Command::done();
    for image in old {
        if image.scene_id == scene && request.is_none_or(|r| image.request_id == r) {
            command = command.and(release(image.staged_id));
        } else {
            model.ordinary_selected.images.push(image);
        }
    }
    command
}
fn admit(
    model: &Model,
    key: &AssetKey,
    scene: &str,
    id: &str,
    kind: OrdinarySelectedImageKind,
) -> Option<(VerifiedPresentation, Session, OrdinarySelectedImageTicket)> {
    let key = key.clone();
    let scene = scene.to_owned();
    let id = id.to_owned();
    if crate::immich::valid_id(&scene).is_err()
        || crate::immich::valid_id(&id).is_err()
        || model.ordinary_selected.used_requests.len() >= 4096
        || model.ordinary_selected.used_requests.contains(&id)
    {
        return None;
    }
    let superseded = |s: &str, k: &AssetKey, v: OrdinarySelectedImageKind| {
        s == scene && v == kind && (k == &key || kind == OrdinarySelectedImageKind::Preview)
    };
    let mut active = model
        .ordinary_selected
        .pending
        .keys()
        .cloned()
        .collect::<std::collections::BTreeSet<_>>();
    active.extend(
        model
            .ordinary_selected
            .images
            .iter()
            .map(|i| (i.scene_id.clone(), i.key.clone(), i.kind)),
    );
    active.retain(|(s, k, v)| !superseded(s, k, *v));
    active.insert((scene.clone(), key.clone(), kind));
    if active.len() > 256 {
        return None;
    }
    let proof = model
        .ordinary_selected
        .proofs
        .get(&key)
        .filter(|p| p.current(model))
        .cloned()?;
    let session = model.session.clone()?;
    let mut remote = session
        .preview_request(&key.asset_id, kind == OrdinarySelectedImageKind::Preview)
        .ok()?;
    remote.ordinary_content_authorization = None;
    let ticket = OrdinarySelectedImageTicket {
        request_id: id.clone(),
        scene_id: scene.clone(),
        key: key.clone(),
        kind,
        proof_id: proof_id(&proof),
        generation: proof.generation,
        expected_revision: proof.asset.revision.clone(),
        request: remote,
    };
    Some((proof, session, ticket))
}
fn request(
    model: &mut Model,
    key: &AssetKey,
    scene: &str,
    id: String,
    kind: OrdinarySelectedImageKind,
) -> Command<Effect, Event> {
    let Some((proof, session, ticket)) = admit(model, key, scene, &id, kind) else {
        return Command::done();
    };
    let mut cleanup = Command::done();
    let old = model
        .ordinary_selected
        .pending
        .values()
        .filter(|t| {
            t.scene_id == scene
                && t.kind == kind
                && (&t.key == key || kind == OrdinarySelectedImageKind::Preview)
        })
        .map(|t| t.request_id.clone())
        .collect::<Vec<_>>();
    for old in old {
        cleanup = cleanup.and(cancel(model, scene, Some(&old)));
    }
    let approved = model
        .ordinary_selected
        .images
        .iter()
        .filter(|t| {
            t.scene_id == scene
                && t.kind == kind
                && (&t.key == key || kind == OrdinarySelectedImageKind::Preview)
        })
        .map(|t| t.request_id.clone())
        .collect::<Vec<_>>();
    for old in approved {
        cleanup = cleanup.and(cancel(model, scene, Some(&old)));
    }
    model.ordinary_selected.used_requests.insert(id);
    model
        .ordinary_selected
        .pending
        .insert(slot(&ticket), ticket.clone());
    let generation = model.ordinary_generation.clone();
    cleanup.and(Command::new(move |ctx| async move {
        let result = async {
            fresh(&ctx, &session, &proof, &generation).await?;
            let result: OrdinarySelectedImageResult = io(
                &ctx,
                ShellOperation::ReadOrdinarySelectedImage {
                    ticket: ticket.clone(),
                },
            )
            .await?;
            if result.request_id != ticket.request_id || result.staged_id.is_empty() {
                if !result.staged_id.is_empty() {
                    let _: Result<serde_json::Value, _> = io(
                        &ctx,
                        ShellOperation::ReleaseOrdinarySelectedImage {
                            staged_id: result.staged_id,
                        },
                    )
                    .await;
                }
                return Err("画像を確認できません。".into());
            }
            if fresh(&ctx, &session, &proof, &generation).await.is_err() {
                let _: Result<serde_json::Value, _> = io(
                    &ctx,
                    ShellOperation::ReleaseOrdinarySelectedImage {
                        staged_id: result.staged_id,
                    },
                )
                .await;
                return Err("写真の状態が変わりました。".into());
            }
            Ok::<_, String>(result)
        }
        .await
        .ok();
        ctx.send_event(Event::OrdinarySelectedImageRead { ticket, result });
    }))
}
fn read(
    model: &mut Model,
    ticket: OrdinarySelectedImageTicket,
    result: Option<OrdinarySelectedImageResult>,
) -> Command<Effect, Event> {
    let Some(result) = result else {
        return if current(model, &ticket) {
            clear_key(model, &ticket.key)
        } else {
            Command::done()
        };
    };
    if !current(model, &ticket) || result.request_id != ticket.request_id {
        return release(result.staged_id);
    }
    let Some(session) = model.session.clone() else {
        return release(result.staged_id);
    };
    let Some(proof) = model.ordinary_selected.proofs.get(&ticket.key).cloned() else {
        return release(result.staged_id);
    };
    let generation: Arc<AtomicU64> = model.ordinary_generation.clone();
    Command::new(move |ctx| async move {
        let result_native: Result<OrdinarySelectedImageResult, _> = io(
            &ctx,
            ShellOperation::PublishOrdinarySelectedImage {
                ticket: ticket.clone(),
                staged_id: result.staged_id.clone(),
            },
        )
        .await;
        let approved = result_native
            .is_ok_and(|r| r.request_id == ticket.request_id && r.staged_id == result.staged_id)
            && fresh(&ctx, &session, &proof, &generation).await.is_ok();
        ctx.send_event(Event::OrdinarySelectedImagePublished {
            ticket,
            staged_id: result.staged_id,
            approved,
        });
    })
}
pub(crate) fn update(event: &Event, model: &mut Model) -> Option<Command<Effect, Event>> {
    Some(match event.clone() {
        Event::RequestOrdinarySelectedImage {
            key,
            scene_id,
            request_id,
            kind,
        } => request(model, &key, &scene_id, request_id, kind),
        Event::CancelOrdinarySelectedImage {
            scene_id,
            request_id,
        } => cancel(model, &scene_id, Some(&request_id)),
        Event::CloseOrdinarySelectedScene { scene_id } => cancel(model, &scene_id, None),
        Event::OrdinarySelectedImageRead { ticket, result } => read(model, ticket, result),
        Event::OrdinarySelectedImagePublished {
            ticket,
            staged_id,
            approved,
        } => {
            if approved && current(model, &ticket) {
                model.ordinary_selected.pending.remove(&slot(&ticket));
                model
                    .ordinary_selected
                    .images
                    .push(OrdinarySelectedImageAccess {
                        request_id: ticket.request_id,
                        scene_id: ticket.scene_id,
                        key: ticket.key,
                        kind: ticket.kind,
                        proof_id: ticket.proof_id,
                        generation: ticket.generation,
                        staged_id,
                    });
                Command::done()
            } else {
                let cleanup = if current(model, &ticket) {
                    clear_key(model, &ticket.key)
                } else {
                    Command::done()
                };
                cleanup.and(release(staged_id))
            }
        }
        _ => return None,
    })
}
pub(crate) fn reconcile(event: &Event, model: &mut Model) -> Command<Effect, Event> {
    let explicit = matches!(
        event,
        Event::Refresh { .. }
            | Event::Initialize { .. }
            | Event::RecoverImmichVisibilityState { .. }
            | Event::RecoverImmichArchiveState { .. }
            | Event::InspectImmichVisibility { .. }
            | Event::PrepareImmichVisibility { .. }
            | Event::ProtectPhotos { .. }
            | Event::UnprotectPhotos { .. }
    );
    reconcile_with(model, explicit)
}
pub(crate) fn reconcile_current(model: &mut Model) -> Command<Effect, Event> {
    reconcile_with(model, false)
}
fn reconcile_with(model: &mut Model, explicit: bool) -> Command<Effect, Event> {
    let keys = model
        .ordinary_selected
        .proofs
        .iter()
        .filter(|(_, p)| explicit || !p.current(model))
        .map(|(k, _)| k.clone())
        .collect::<Vec<_>>();
    let mut command = Command::done();
    for key in keys {
        command = command.and(clear_key(model, &key));
    }
    if model.ordinary_selected.proofs.is_empty() {
        model.ordinary_selected.used_requests.clear();
    }
    command
}
