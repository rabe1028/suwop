//! Selected-write native revocation precedes every projection/generation fence.
//! The unit response proves capture only. Existing key JOINs still authorize no write by themselves.
use crate::{
    app::{Effect, Event, Model, ShellOperation, io},
    domain::AssetKey,
    immich_archive::VisibilityAuthority,
    protection::ProtectionScenePhase,
};
use crux_core::Command;
use std::sync::Arc;

#[derive(Debug, Clone)]
struct Owner(Arc<()>);
impl Owner {
    fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

#[derive(Debug)]
struct Reservation {
    owner: Owner,
    event: Box<Event>,
    key: AssetKey,
    id: String,
    scene: String,
    authority: VisibilityAuthority,
}

#[derive(Debug, Default)]
pub struct State {
    pending: Option<Reservation>,
    resumed: Option<(String, AssetKey)>,
}

/// Only the issued callback can construct this completion; it is not a deserializable event.
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Owner,
    result: Result<(), String>,
}

fn cancellation(event: &Event, scene: &str) -> bool {
    match event {
        Event::Disconnect
        | Event::Configure { .. }
        | Event::CloseImmichLocked
        | Event::Finished { .. }
        | Event::ProtectedPersisted { .. }
        | Event::ProtectedReconciled { .. }
        | Event::OrdinarySelectedRefreshFinished { .. }
        | Event::ImmichVisibilityPrepared { .. }
        | Event::ImmichVisibilityFinished { .. }
        | Event::ImmichLockedRefreshed { .. } => true,
        Event::CloseImmichArchive { scene_id } => scene_id == scene,
        Event::ImmichLockedSceneChanged { scene_id, phase }
        | Event::ImmichArchiveSceneChanged { scene_id, phase } => {
            scene_id == scene && *phase != ProtectionScenePhase::Active
        }
        _ => false,
    }
}

fn finish_capture(
    completion: Completion,
    model: &mut Model,
) -> Result<Event, Box<Command<Effect, Event>>> {
    let Completion { owner, result } = completion;
    let state = &mut model.private_media_capture;
    if !state.pending.as_ref().is_some_and(|p| p.owner.same(&owner)) {
        return Err(Box::new(Command::done()));
    }
    let Some(pending) = state.pending.take() else {
        return Err(Box::new(Command::done()));
    };
    // Only this exact pending reservation owns busy. A stale callback cannot reach here.
    model.busy = false;
    if result.is_err() || pending.authority.valid().is_err() {
        model.immich_visibility.message =
            Some("選択した項目の停止を開始できませんでした。変更は開始されませんでした。".into());
        return Err(Box::new(Command::done()));
    }
    model.private_media_capture.resumed = Some((pending.id, pending.key));
    Ok(*pending.event)
}

/// Runs before ordinary-selected reconciliation and before publishing a changed Live projection.
/// Returning the original event after capture resumes the normal reconciliation/begin path exactly once.
pub(crate) fn intercept(
    event: Event,
    model: &mut Model,
) -> Result<Event, Box<Command<Effect, Event>>> {
    if let Event::PrivateMediaKeyCaptured { completion } = event {
        return finish_capture(completion, model);
    }
    if model
        .private_media_capture
        .pending
        .as_ref()
        .is_some_and(|p| cancellation(&event, &p.scene))
    {
        model.private_media_capture.pending = None;
        model.busy = false;
    }
    let (key, id, scene, authority) = match &event {
        Event::PrepareImmichVisibility {
            key,
            operation_id,
            grant_id,
            scene_id,
            ..
        } => {
            let Some(authority) = crate::immich_visibility::capture_authority(
                model,
                key,
                operation_id,
                grant_id,
                scene_id,
                false,
            ) else {
                return Err(Box::new(Command::done()));
            };
            (
                key.clone(),
                operation_id.clone(),
                scene_id.clone(),
                authority,
            )
        }
        Event::PrepareImmichArchive {
            key,
            to,
            operation_id,
            scene_id,
        } => {
            let Some(authority) = crate::immich_archive::capture_authority(
                model,
                key,
                *to,
                operation_id,
                scene_id,
                false,
            ) else {
                return Err(Box::new(Command::done()));
            };
            (
                key.clone(),
                operation_id.clone(),
                scene_id.clone(),
                authority,
            )
        }
        _ => return Ok(event),
    };
    let owner = Owner(Arc::new(()));
    model.immich_visibility.used_ids.insert(id.clone());
    model.private_media_capture.pending = Some(Reservation {
        owner: owner.clone(),
        event: Box::new(event),
        key: key.clone(),
        id,
        scene,
        authority,
    });
    model.busy = true;
    Err(Box::new(Command::new(move |ctx| async move {
        let result = io(&ctx, ShellOperation::CapturePrivateMediaKey { key }).await;
        ctx.send_event(Event::PrivateMediaKeyCaptured {
            completion: Completion { owner, result },
        });
    })))
}

pub(crate) fn consume_resume(model: &mut Model, id: &str, key: &AssetKey) -> bool {
    model
        .private_media_capture
        .resumed
        .take()
        .is_some_and(|(issued_id, issued_key)| issued_id == id && issued_key == *key)
}
