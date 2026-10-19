//! Capture before projection fences; exact captured-owner retirement survives all preflight outcomes.
//! Native drain receipts prove cleanup only and never authorize a write.
use crate::{
    app::{Effect, Event, Model, ShellOperation, io},
    domain::AssetKey,
    immich_archive::VisibilityAuthority,
    immich_locked::{self, live, video},
    protection::ProtectionScenePhase,
};
use crux_core::Command;
use std::sync::Arc;

type InterceptResult = Result<(Event, Command<Effect, Event>), Box<Command<Effect, Event>>>;

const ERROR: &str = "選択した項目の停止を確認できません。変更は開始されませんでした。";
#[derive(Debug, Clone)]
struct Owner(Arc<()>);
impl Owner {
    fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
#[derive(Debug, Clone)]
struct CapturedOwners {
    live: live::CapturedOwners,
    video: video::CapturedOwner,
}
impl CapturedOwners {
    fn matches_stop(&self, event: &Event) -> Option<bool> {
        match event {
            Event::StopImmichLockedLive {
                scene_id,
                request_id,
                retry_cleanup,
            } if self
                .live
                .pending()
                .iter()
                .any(|p| &p.scene_id == scene_id && &p.request_id == request_id) =>
            {
                Some(*retry_cleanup)
            }
            Event::StopImmichLockedVideo {
                scene_id,
                request_id,
                retry_cleanup,
            } if self
                .video
                .pending()
                .iter()
                .any(|p| &p.scene_id == scene_id && &p.request_id == request_id) =>
            {
                Some(*retry_cleanup)
            }
            _ => None,
        }
    }
    fn retire(&self, model: &mut Model) -> Command<Effect, Event> {
        live::retire_captured(model, &self.live).and(video::retire_captured(model, &self.video))
    }
}
#[derive(Debug)]
struct Reservation {
    owner: Owner,
    event: Option<Box<Event>>,
    key: AssetKey,
    id: String,
    scene: String,
    authority: VisibilityAuthority,
    capture_id: String,
    captured: CapturedOwners,
    capture_done: bool,
    capture_ok: bool,
    draining: bool,
    recovery: crate::private_media_cleanup::Recovery,
}
#[derive(Debug, Default)]
pub struct State {
    // Retain incomplete cleanup across cancellation/configuration. Never evict unresolved owners.
    records: Vec<Reservation>,
    nonce: Option<String>,
    sequence: u32,
    resumed: Option<(String, AssetKey)>,
}
impl State {
    fn next_id(&mut self) -> Result<String, String> {
        if self.nonce.is_none() {
            let mut bytes = [0_u8; 16];
            getrandom::getrandom(&mut bytes).map_err(|_| ERROR)?;
            self.nonce = Some(crate::domain::hex(&bytes));
        }
        self.sequence = self.sequence.checked_add(1).ok_or(ERROR)?;
        Ok(format!(
            "{}:{}",
            self.nonce.as_deref().ok_or(ERROR)?,
            self.sequence
        ))
    }
}
#[derive(Debug, Clone)]
enum Stage {
    Captured,
    Drained {
        after_capture: bool,
        attempt: crate::private_media_cleanup::Attempt,
    },
}
/// Only the issued callback constructs this completion; it is never deserializable authority.
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Owner,
    stage: Stage,
    result: Result<Option<DrainReceipt>, String>,
}
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DrainReceipt {
    #[serde(rename = "captureID")]
    capture_id: String,
    cancelled_before_capture: bool,
}
fn cancellation(event: &Event, scene: &str, model: &Model) -> bool {
    match event {
        Event::Disconnect
        | Event::Configure { .. }
        | Event::CloseImmichLocked
        | Event::Finished { .. }
        | Event::ProtectedPersisted { .. }
        | Event::ProtectedReconciled { .. }
        | Event::OrdinarySelectedRefreshFinished { .. }
        | Event::ImmichVisibilityPrepared { .. }
        | Event::ImmichVisibilityFinished { .. } => true,
        Event::ImmichLockedRefreshed {
            generation,
            refresh_id,
            ..
        } => immich_locked::refresh_completion_is_current(model, *generation, *refresh_id),
        Event::CloseImmichArchive { scene_id } => scene_id == scene,
        Event::ImmichLockedSceneChanged { scene_id, phase }
        | Event::ImmichArchiveSceneChanged { scene_id, phase } => {
            scene_id == scene && *phase != ProtectionScenePhase::Active
        }
        _ => false,
    }
}

fn drain(record: &mut Reservation, retry_cleanup: bool) -> Command<Effect, Event> {
    if record.draining {
        return Command::done();
    }
    let Some(attempt) = record.recovery.begin(retry_cleanup) else {
        return Command::done();
    };
    record.draining = true;
    let owner = record.owner.clone();
    let capture_id = record.capture_id.clone();
    let key = record.key.clone();
    let live_pending = record.captured.live.pending();
    let video_pending = record.captured.video.pending();
    let after_capture = record.capture_done;
    let cancel_before_capture = record.event.is_none();
    Command::new(move |ctx| async move {
        let result: Result<DrainReceipt, String> = io(
            &ctx,
            ShellOperation::DrainCapturedPrivateMedia {
                capture_id,
                cancel_before_capture,
                retry_cleanup,
                key,
                live_pending,
                video_pending,
            },
        )
        .await;
        let result = result.map(Some);
        ctx.send_event(Event::PrivateMediaKeyCaptured {
            completion: Completion {
                owner,
                stage: Stage::Drained {
                    after_capture,
                    attempt,
                },
                result,
            },
        });
    })
}
fn finish(completion: Completion, model: &mut Model) -> InterceptResult {
    let Some(index) = model
        .private_media_capture
        .records
        .iter()
        .position(|r| r.owner.same(&completion.owner))
    else {
        return Err(Box::new(Command::done()));
    };
    match completion.stage {
        Stage::Captured => {
            let record = &mut model.private_media_capture.records[index];
            record.capture_done = true;
            record.capture_ok = completion.result.is_ok();
            let captured = record.captured.clone();
            let cleanup = captured.retire(model);
            let drain = drain(&mut model.private_media_capture.records[index], false);
            Err(Box::new(cleanup.and(drain)))
        }
        Stage::Drained {
            after_capture,
            attempt,
        } => {
            let record = &mut model.private_media_capture.records[index];
            if !record.recovery.matches(&attempt) {
                return Err(Box::new(Command::done()));
            }
            record.draining = false;
            let result = completion
                .result
                .and_then(|r| r.ok_or_else(|| ERROR.into()))
                .and_then(|r| {
                    if r.capture_id != record.capture_id
                        || (r.cancelled_before_capture && record.event.is_some())
                    {
                        Err(ERROR.to_owned())
                    } else {
                        Ok(r)
                    }
                });
            record.recovery.finish(&attempt, result.is_ok());
            if result.is_err() {
                if record.event.take().is_some() {
                    model.busy = false;
                    model.immich_visibility.message = Some(ERROR.into());
                }
                return Err(Box::new(Command::done())); // Quarantine obligation/admission retained.
            }
            if !after_capture && !result.as_ref().is_ok_and(|r| r.cancelled_before_capture) {
                // Captured snapshot drained before its delayed ACK: preserve the owner
                // until that callback arrives, then observe the SAME capture once more.
                return Err(Box::new(if record.capture_done {
                    drain(record, false)
                } else {
                    Command::done()
                }));
            }
            // cancelledBeforeCapture additionally proves exact supplied pending workers
            // JOINed (or sealed before registration), not merely that the ID was sealed.
            let record = model.private_media_capture.records.remove(index);
            let cleanup = live::captured_drained(model, &record.captured.live);
            video::captured_drained(model, &record.captured.video);
            let Some(event) = record.event else {
                return Err(Box::new(cleanup));
            };
            model.busy = false; // Only the still-current reservation owns busy.
            if !record.capture_ok || record.authority.valid().is_err() {
                model.immich_visibility.message = Some(ERROR.into());
                return Err(Box::new(cleanup));
            }
            model.private_media_capture.resumed = Some((record.id, record.key));
            Ok((*event, cleanup))
        }
    }
}
fn cancel(model: &mut Model, index: usize) -> Command<Effect, Event> {
    let record = &mut model.private_media_capture.records[index];
    record.event = None;
    let captured = record.captured.clone();
    model.busy = false;
    let cleanup = captured.retire(model);
    cleanup.and(drain(
        &mut model.private_media_capture.records[index],
        false,
    ))
}
/// Runs before reconciliation/fences. Preflight resumes only AFTER capture and exact native drain.
pub(crate) fn intercept(event: Event, model: &mut Model) -> InterceptResult {
    if let Event::PrivateMediaKeyCaptured { completion } = event {
        return finish(completion, model);
    }
    if let Some(index) = model
        .private_media_capture
        .records
        .iter()
        .position(|r| r.event.is_some() && cancellation(&event, &r.scene, model))
    {
        let cleanup = cancel(model, index);
        return Ok((event, cleanup));
    }
    if let Some((index, _retry)) = model
        .private_media_capture
        .records
        .iter()
        .enumerate()
        .find_map(|(i, r)| r.captured.matches_stop(&event).map(|retry| (i, retry)))
    {
        let record = &mut model.private_media_capture.records[index];
        if record.event.take().is_some() {
            model.busy = false;
        }
        let captured = record.captured.clone();
        let cleanup = captured.retire(model);
        let cleanup = cleanup.and(drain(
            &mut model.private_media_capture.records[index],
            false,
        ));
        // One intent owns one captured cleanup. Do not also issue normal Release,
        // which could acquire a token for a failure occurring during this same drain.
        return Err(Box::new(cleanup));
    }
    capture(event, model)
}

fn capture(event: Event, model: &mut Model) -> InterceptResult {
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
        _ => return Ok((event, Command::done())),
    };
    if !model.private_media_capture.records.is_empty() {
        model.immich_visibility.message = Some(ERROR.into());
        let cleanup = drain(&mut model.private_media_capture.records[0], false);
        return Err(Box::new(cleanup));
    }
    let Ok(capture_id) = model.private_media_capture.next_id() else {
        return Err(Box::new(Command::done()));
    };
    let owner = Owner(Arc::new(()));
    let captured = CapturedOwners {
        live: live::capture_owners(model, &key),
        video: video::capture_owner(model, &key),
    };
    let live_pending = captured.live.pending();
    let video_pending = captured.video.pending();
    model.immich_visibility.used_ids.insert(id.clone());
    model.private_media_capture.records.push(Reservation {
        owner: owner.clone(),
        event: Some(Box::new(event)),
        key: key.clone(),
        id,
        scene,
        authority,
        capture_id: capture_id.clone(),
        recovery: crate::private_media_cleanup::Recovery::new(),
        captured,
        capture_done: false,
        capture_ok: false,
        draining: false,
    });
    model.busy = true;
    Err(Box::new(capture_command(
        owner,
        key,
        capture_id,
        live_pending,
        video_pending,
    )))
}

fn capture_command(
    owner: Owner,
    key: AssetKey,
    capture_id: String,
    live_pending: Vec<live::ImmichLockedLivePending>,
    video_pending: Vec<video::ImmichLockedVideoPending>,
) -> Command<Effect, Event> {
    Command::new(move |ctx| async move {
        let result: Result<(), String> = io(
            &ctx,
            ShellOperation::CapturePrivateMediaKey {
                key,
                capture_id,
                live_pending,
                video_pending,
            },
        )
        .await;
        let result = result.map(|()| None);
        ctx.send_event(Event::PrivateMediaKeyCaptured {
            completion: Completion {
                owner,
                stage: Stage::Captured,
                result,
            },
        });
    })
}

pub(crate) fn consume_resume(model: &mut Model, id: &str, key: &AssetKey) -> bool {
    model
        .private_media_capture
        .resumed
        .take()
        .is_some_and(|(issued_id, issued_key)| issued_id == id && issued_key == *key)
}

/// Projection contains no physical identities or the canceled write intent.
pub(crate) fn cleanup_projection(
    model: &Model,
) -> Vec<crate::private_media_cleanup::PrivateMediaCleanupView> {
    model
        .private_media_capture
        .records
        .iter()
        .filter_map(|r| r.recovery.view())
        .collect()
}
pub(crate) fn retry_cleanup(
    model: &mut Model,
    id: &str,
    expected: u64,
) -> Option<Command<Effect, Event>> {
    let record = model
        .private_media_capture
        .records
        .iter_mut()
        .find(|r| r.recovery.accepts_retry(id, expected))?;
    // A failed preflight is never revived by cleanup recovery.
    record.event = None;
    Some(drain(record, true))
}
pub(crate) fn owns_video(model: &Model, pending: &video::ImmichLockedVideoPending) -> bool {
    model
        .private_media_capture
        .records
        .iter()
        .any(|r| r.captured.video.owns_pending(pending))
}
pub(crate) fn owns_live(model: &Model, pending: &live::ImmichLockedLivePending) -> bool {
    model
        .private_media_capture
        .records
        .iter()
        .any(|r| r.captured.live.pending().iter().any(|p| p == pending))
}
