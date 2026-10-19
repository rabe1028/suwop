//! Retain every stopped VIDEO pending before I/O, including a worker without a quote.
use super::{ImmichLockedVideoPending, Model, ShellOperation, same_request};
use crate::{
    app::{Effect, Event, io},
    private_media_cleanup::{Attempt, Recovery},
};
use crux_core::Command;

pub(super) const CAPACITY: usize = 64;
#[derive(Debug)]
pub(super) struct Retired {
    pending: ImmichLockedVideoPending,
    lease_id: Option<String>,
    recovery: Recovery,
}
#[derive(Debug, Clone)]
pub struct CleanupCompletion {
    attempt: Attempt,
    result: Result<(), String>,
}
fn start(record: &mut Retired, retry_cleanup: bool) -> Command<Effect, Event> {
    let Some(attempt) = record.recovery.begin(retry_cleanup) else {
        return Command::done();
    };
    let pending = record.pending.clone();
    let lease = record.lease_id.clone();
    Command::new(move |ctx| async move {
        let operation = lease.map_or_else(
            || ShellOperation::RetireImmichLockedVideoPending {
                pending: pending.clone(),
                retry_cleanup,
            },
            |lease_id| ShellOperation::ReleaseImmichLockedVideo {
                pending: pending.clone(),
                lease_id,
                retry_cleanup,
            },
        );
        let result = io(&ctx, operation).await;
        ctx.send_event(Event::PrivateMediaVideoCleanupCompleted {
            completion: CleanupCompletion { attempt, result },
        });
    })
}
pub(super) fn retire(
    model: &mut Model,
    pending: ImmichLockedVideoPending,
    lease_id: Option<String>,
    retry: bool,
) -> Command<Effect, Event> {
    // Capture owns an immutable cleanup obligation already. Never manufacture another retry path.
    if crate::private_media_capture::owns_video(model, &pending) {
        return Command::done();
    }
    let records = &mut model.immich_locked.video.retired;
    if let Some(old) = records
        .iter_mut()
        .find(|r| same_request(&r.pending, &pending))
    {
        return start(old, retry);
    }
    // Admission reserves a slot before Inspect. Unresolved records are never evicted.
    records.push(Retired {
        pending,
        lease_id,
        recovery: Recovery::new(),
    });
    let Some(record) = records.last_mut() else {
        return Command::done();
    };
    start(record, retry)
}
pub(super) fn completed(
    model: &mut Model,
    completion: CleanupCompletion,
) -> Command<Effect, Event> {
    let CleanupCompletion { attempt, result } = completion;
    let records = &mut model.immich_locked.video.retired;
    let Some(index) = records.iter().position(|r| r.recovery.matches(&attempt)) else {
        return Command::done();
    };
    let success = result.map_or_else(|_| false, |()| true);
    records[index].recovery.finish(&attempt, success);
    if success {
        records.remove(index);
    }
    Command::done()
}
pub(crate) fn projection(
    model: &Model,
) -> Vec<crate::private_media_cleanup::PrivateMediaCleanupView> {
    model
        .immich_locked
        .video
        .retired
        .iter()
        .filter(|r| !crate::private_media_capture::owns_video(model, &r.pending))
        .filter_map(|r| r.recovery.view())
        .collect()
}
pub(crate) fn retry(model: &mut Model, id: &str, expected: u64) -> Option<Command<Effect, Event>> {
    let index = model
        .immich_locked
        .video
        .retired
        .iter()
        .position(|r| r.recovery.accepts_retry(id, expected))?;
    if crate::private_media_capture::owns_video(
        model,
        &model.immich_locked.video.retired[index].pending,
    ) {
        return None;
    }
    Some(start(&mut model.immich_locked.video.retired[index], true))
}
#[derive(Debug, Clone)]
pub(super) struct Captured {
    pending: ImmichLockedVideoPending,
    recovery: Recovery,
}
pub(super) fn capture(model: &Model, key: &crate::domain::AssetKey) -> Vec<Captured> {
    model
        .immich_locked
        .video
        .retired
        .iter()
        .filter(|r| &r.pending.key == key)
        .map(|r| Captured {
            pending: r.pending.clone(),
            recovery: r.recovery.clone(),
        })
        .collect()
}
pub(super) fn pending(captured: &[Captured]) -> Vec<ImmichLockedVideoPending> {
    captured.iter().map(|r| r.pending.clone()).collect()
}
pub(super) fn owns(captured: &[Captured], pending: &ImmichLockedVideoPending) -> bool {
    captured.iter().any(|r| same_request(&r.pending, pending))
}
pub(super) fn drained(model: &mut Model, captured: &[Captured]) {
    // Only same-capture native JOIN can discharge these private exact owner tokens.
    model.immich_locked.video.retired.retain(|r| {
        !captured
            .iter()
            .any(|old| old.recovery.same_owner(&r.recovery))
    });
}
