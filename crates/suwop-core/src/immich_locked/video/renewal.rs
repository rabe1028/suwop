//! VIDEO-only continuous acquisition authority; never changes ordinary or mutation grants.
use super::{
    Command, Context, Deserialize, ERROR, Event, ImmichLockedVideoPending, ImmichLockedVideoTicket,
    Model, Serialize, ShellOperation, VideoAcquisition, VisibilitySession, io, pending_current,
    same_request, stop,
};
use std::sync::{Arc, Mutex};
use std::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoAcquisitionLease {
    #[serde(rename = "leaseID")]
    pub lease_id: u64,
    pub deadline_unix_milliseconds: u64,
    pub remaining_milliseconds: u64,
    pub extension_milliseconds: u64,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoAcquisitionState {
    pub pending: ImmichLockedVideoPending,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
    pub lease: ImmichLockedVideoAcquisitionLease,
    pub initial_lease: ImmichLockedVideoAcquisitionLease,
    #[serde(rename = "acknowledgedLeaseID")]
    pub acknowledged_lease_id: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoAcquisitionRenewed {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
    #[serde(rename = "previousLeaseID")]
    pub previous_lease_id: u64,
    #[serde(rename = "leaseID")]
    pub lease_id: u64,
}
#[derive(Clone, Debug)]
pub(super) struct SharedLease(Arc<Mutex<Authority>>);
#[derive(Debug)]
struct Authority {
    deadline: Instant,
    lease_id: u64,
    acknowledged: u64,
    terminal: bool,
}
impl SharedLease {
    pub(super) fn new(deadline: Instant) -> Self {
        Self(Arc::new(Mutex::new(Authority {
            deadline,
            lease_id: 1,
            acknowledged: 1,
            terminal: false,
        })))
    }
    pub(super) fn terminalize(&self) {
        if let Ok(mut state) = self.0.lock() {
            state.terminal = true;
        }
    }
    fn current(&self) -> Result<(Instant, u64, u64), String> {
        let state = self.0.lock().map_err(|_| ERROR)?;
        if state.terminal || Instant::now() >= state.deadline {
            return Err(ERROR.into());
        }
        Ok((state.deadline, state.lease_id, state.acknowledged))
    }
}
impl VideoAcquisition {
    pub(super) fn current_capability(&self) -> Result<VisibilitySession, String> {
        let (deadline, _, _) = self.lease.current()?;
        let mut capability = self.capability.clone();
        capability.lease_deadline = deadline.min(capability.hard_deadline);
        capability.valid()?;
        Ok(capability)
    }
}
#[derive(Clone, Debug)]
pub struct VideoHeartbeat {
    acquisition: VideoAcquisition,
    measured: Option<u64>,
    previous_lease_id: u64,
}
#[derive(Default)]
pub(super) struct RenewalModel {
    pub(super) ticket: Option<ImmichLockedVideoTicket>,
    candidate: Option<(u64, u64)>,
    pub(super) held: Option<Box<Event>>,
}
pub(super) fn projection(model: &Model) -> Option<ImmichLockedVideoAcquisitionState> {
    let video = &model.immich_locked.video;
    let pending = video.pending.as_ref()?;
    if video.access.is_some() || !pending_current(model, pending) {
        return None;
    }
    let ticket = video.renewal.ticket.as_ref()?;
    let (_, lease_id, acknowledged) = video.binding.as_ref()?.lease.current().ok()?;
    if ticket.acquisition_lease.lease_id != lease_id {
        return None;
    }
    Some(ImmichLockedVideoAcquisitionState {
        pending: pending.clone(),
        staged_id: ticket.storage.lease_id.clone(),
        lease: ticket.acquisition_lease.clone(),
        initial_lease: ticket.initial_acquisition_lease.clone(),
        acknowledged_lease_id: acknowledged,
    })
}
pub(super) fn heartbeat(model: &Model) -> Option<VideoHeartbeat> {
    let mut acquisition = model.immich_locked.video.binding.clone()?;
    if model.immich_locked.video.access.is_some() {
        acquisition.capability = super::visibility_session(
            model,
            &acquisition.pending.grant_id,
            &acquisition.pending.scene_id,
        )?;
        acquisition.lease = SharedLease::new(acquisition.capability.lease_deadline);
    }
    let (_, previous_lease_id, _) = acquisition.lease.current().ok()?;
    Some(VideoHeartbeat {
        acquisition,
        measured: model.immich_locked.video.measured_bytes,
        previous_lease_id,
    })
}
pub(super) async fn check_heartbeat(ctx: &Context, binding: &VideoHeartbeat) -> Result<(), String> {
    super::acquisition::metadata(ctx, &binding.acquisition, binding.measured).await
}
pub(super) fn renew(
    model: &mut Model,
    heartbeat: Option<VideoHeartbeat>,
    deadline: Instant,
) -> Command<crate::app::Effect, Event> {
    let Some(heartbeat) = heartbeat else {
        return Command::done();
    };
    let Some(current) = model.immich_locked.video.binding.as_ref() else {
        return Command::done();
    };
    if !Arc::ptr_eq(&current.lease.0, &heartbeat.acquisition.lease.0)
        || !same_request(&current.pending, &heartbeat.acquisition.pending)
        || !pending_current(model, &current.pending)
        || model.immich_locked.video.access.is_some()
        || model.immich_locked.video.renewal.candidate.is_some()
    {
        return Command::done();
    }
    let Ok((old_deadline, previous, acknowledged)) = current.lease.current() else {
        return stop(model);
    };
    if previous != heartbeat.previous_lease_id || previous != acknowledged {
        return Command::done();
    }
    let Some(mut ticket) = model.immich_locked.video.renewal.ticket.clone() else {
        return Command::done();
    };
    let deadline = deadline.min(current.capability.hard_deadline);
    let Some(extension) = deadline.checked_duration_since(old_deadline) else {
        return Command::done();
    };
    let Ok(extension_milliseconds) = u64::try_from(extension.as_millis()) else {
        return stop(model);
    };
    // Round down the successor extension, never round authority up across the native boundary.
    if extension_milliseconds == 0 {
        return Command::done();
    }
    let deadline = old_deadline + std::time::Duration::from_millis(extension_milliseconds);
    let Some(next) = previous.checked_add(1) else {
        return stop(model);
    };
    let Ok(mut state) = current.lease.0.lock() else {
        return Command::done();
    };
    if state.terminal || state.lease_id != previous || Instant::now() >= state.deadline {
        return Command::done();
    }
    state.deadline = deadline;
    state.lease_id = next;
    drop(state);
    let mut cap = current.capability.clone();
    cap.lease_deadline = deadline;
    let Ok(unix) = cap.visibility_deadline() else {
        return stop(model);
    };
    let lease = ImmichLockedVideoAcquisitionLease {
        lease_id: next,
        deadline_unix_milliseconds: unix,
        remaining_milliseconds: u64::try_from(
            deadline
                .saturating_duration_since(Instant::now())
                .as_millis(),
        )
        .unwrap_or(0),
        extension_milliseconds,
    };
    ticket.acquisition_lease = lease.clone();
    ticket.deadline_unix_milliseconds = unix;
    if let Some(pending) = &model.immich_locked.video.pending {
        ticket.pending = pending.clone();
    }
    model.immich_locked.video.renewal.ticket = Some(ticket.clone());
    model.immich_locked.video.renewal.candidate = Some((previous, next));
    let expiry = schedule(ticket.pending.clone(), lease.clone());
    expiry.and(Command::new(move |ctx| async move {
        let result = io(
            &ctx,
            ShellOperation::RenewImmichLockedVideoAcquisition {
                ticket: ticket.clone(),
                previous_lease_id: previous,
                lease,
            },
        )
        .await;
        ctx.send_event(Event::ImmichLockedVideoRenewalAcknowledged {
            pending: ticket.pending,
            staged_id: ticket.storage.lease_id,
            previous_lease_id: previous,
            lease_id: next,
            result,
        });
    }))
}
pub(super) fn schedule(
    pending: ImmichLockedVideoPending,
    lease: ImmichLockedVideoAcquisitionLease,
) -> Command<crate::app::Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<super::Value, _> = io(
            &ctx,
            ShellOperation::ScheduleImmichLockedVideoAcquisitionExpiry { pending, lease },
        )
        .await;
    })
}
pub(super) fn completion_current(
    model: &Model,
    ticket: &ImmichLockedVideoTicket,
    lease_id: u64,
) -> bool {
    ticket.deadline_unix_milliseconds == ticket.acquisition_lease.deadline_unix_milliseconds
        && pending_current(model, &ticket.pending)
        && model
            .immich_locked
            .video
            .renewal
            .ticket
            .as_ref()
            .is_some_and(|current| {
                current.initial_acquisition_lease == ticket.initial_acquisition_lease
                    && current.storage == ticket.storage
                    && current.expected_revision == ticket.expected_revision
                    && current.expected_sha1 == ticket.expected_sha1
                    && current.expected_bytes == ticket.expected_bytes
                    && current.commitment_mode == ticket.commitment_mode
                    && current.max_received_bytes == ticket.max_received_bytes
                    && current.minimum_remaining_bytes == ticket.minimum_remaining_bytes
            })
        && model
            .immich_locked
            .video
            .binding
            .as_ref()
            .and_then(|a| a.lease.current().ok())
            .is_some_and(|(_, current, ack)| lease_id > 0 && lease_id <= ack && current == ack)
}
fn completion_ticket(event: &Event) -> Option<&ImmichLockedVideoTicket> {
    match event {
        Event::ImmichLockedVideoRead { ticket, .. } => Some(ticket),
        Event::ImmichLockedVideoPrepared { ticket, .. } => Some(ticket),
        _ => None,
    }
}
pub(super) fn hold(model: &mut Model, event: Event) -> bool {
    if model.immich_locked.video.renewal.candidate.is_none() {
        return false;
    }
    let Some(ticket) = completion_ticket(&event) else {
        return false;
    };
    let matches = model
        .immich_locked
        .video
        .pending
        .as_ref()
        .is_some_and(|p| same_request(p, &ticket.pending))
        && model
            .immich_locked
            .video
            .lease
            .as_ref()
            .is_some_and(|(_, id)| *id == ticket.storage.lease_id);
    if !matches {
        return false;
    }
    if model.immich_locked.video.renewal.held.is_none() {
        model.immich_locked.video.renewal.held = Some(Box::new(event));
    }
    true
}
fn revalidate_held(model: &Model, event: Event) -> Command<crate::app::Effect, Event> {
    let Some(binding) = model.immich_locked.video.binding.clone() else {
        return Command::done();
    };
    let measured = model.immich_locked.video.measured_bytes;
    Command::new(move |ctx| async move {
        let valid = super::acquisition::metadata(&ctx, &binding, measured)
            .await
            .is_ok();
        let event = match event {
            Event::ImmichLockedVideoRead {
                acquisition,
                ticket,
                result,
            } => Event::ImmichLockedVideoRead {
                acquisition,
                ticket,
                result: if valid { result } else { Err(ERROR.into()) },
            },
            Event::ImmichLockedVideoPrepared {
                ticket,
                approved,
                acquisition_lease_id,
            } => Event::ImmichLockedVideoPrepared {
                ticket,
                approved: approved && valid,
                acquisition_lease_id,
            },
            other => other,
        };
        ctx.send_event(event);
    })
}
pub(super) fn update(
    event: Event,
    model: &mut Model,
) -> Option<Command<crate::app::Effect, Event>> {
    Some(match event {
        Event::ExpireImmichLockedVideoAcquisition {
            scene_id,
            request_id,
            generation,
            lease_id,
        } => {
            let matches = model.immich_locked.video.pending.as_ref().is_some_and(|p| {
                p.scene_id == scene_id && p.request_id == request_id && p.generation == generation
            }) && model
                .immich_locked
                .video
                .renewal
                .ticket
                .as_ref()
                .is_some_and(|t| {
                    t.acquisition_lease.lease_id == lease_id
                        || model
                            .immich_locked
                            .video
                            .renewal
                            .candidate
                            .is_some_and(|(previous, _)| previous == lease_id)
                });
            if matches {
                stop(model)
            } else {
                Command::done()
            }
        }
        Event::ImmichLockedVideoRenewalAcknowledged {
            pending,
            staged_id,
            previous_lease_id,
            lease_id,
            result,
        } => {
            let video = &model.immich_locked.video;
            let matches = video.renewal.candidate == Some((previous_lease_id, lease_id))
                && video
                    .pending
                    .as_ref()
                    .is_some_and(|p| same_request(p, &pending))
                && video.lease.as_ref().is_some_and(|(_, id)| *id == staged_id);
            if !matches {
                return Some(Command::done());
            }
            let valid = pending_current(model, &pending)
                && result.is_ok_and(|a: ImmichLockedVideoAcquisitionRenewed| {
                    a.request_id == pending.request_id
                        && a.staged_id == staged_id
                        && a.previous_lease_id == previous_lease_id
                        && a.lease_id == lease_id
                });
            if !valid {
                return Some(stop(model));
            }
            if let Some(binding) = &model.immich_locked.video.binding
                && let Ok(mut state) = binding.lease.0.lock()
            {
                state.acknowledged = lease_id;
            }
            model.immich_locked.video.renewal.candidate = None;
            if let Some(event) = model.immich_locked.video.renewal.held.take() {
                revalidate_held(model, *event)
            } else {
                Command::done()
            }
        }
        _ => return None,
    })
}
