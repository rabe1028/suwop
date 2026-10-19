use super::{
    Command, Context, ERROR, Event, HeartbeatCompletion, ImmichLockedLiveRenewed, Instant,
    LiveHeartbeat, Model, ShellOperation, coordinator, driver, io, lifecycle, stop,
};
use coordinator::RenewalCommand;
#[derive(Debug, Clone)]
pub struct RenewalCompletion {
    heartbeat: LiveHeartbeat,
    command: RenewalCommand,
    result: Result<ImmichLockedLiveRenewed, String>,
}
pub(in crate::immich_locked) fn heartbeat(model: &Model) -> Option<LiveHeartbeat> {
    let active = model.immich_locked.live.active.as_ref()?;
    if !lifecycle::active_current(model) {
        return None;
    }
    let mut binding = active.binding.clone();
    let k = binding.kernel.as_ref()?;
    let display = k.is_published();
    if display {
        binding.authority.session = super::super::visibility_session(
            model,
            &binding.pending.grant_id,
            &binding.pending.scene_id,
        )?;
    }
    let capture = if display {
        k.capture_display_check(Instant::now())
    } else {
        k.capture_heartbeat(Instant::now())
    }
    .ok()?;
    Some(LiveHeartbeat {
        binding,
        capture: Some(capture),
        display,
    })
}
pub(in crate::immich_locked) async fn check_heartbeat(
    ctx: &Context,
    h: LiveHeartbeat,
) -> HeartbeatCompletion {
    let result = async {
        let a = if h.display {
            h.binding.authority.clone()
        } else {
            h.binding.authority()?
        };
        a.valid()?;
        coordinator::proof(
            ctx,
            &a,
            &h.binding.expected,
            h.binding.sizes,
            h.capture.clone().ok_or(ERROR)?,
        )
        .await
    }
    .await;
    HeartbeatCompletion {
        heartbeat: h,
        result,
    }
}
pub(in crate::immich_locked) fn checked(
    model: &mut Model,
    result: Option<HeartbeatCompletion>,
) -> Command<crate::app::Effect, Event> {
    result.map_or_else(Command::done, |c| completed(model, c))
}
pub(super) fn completed(
    model: &mut Model,
    completion: HeartbeatCompletion,
) -> Command<crate::app::Effect, Event> {
    let h = completion.heartbeat;
    let Some(active) = model
        .immich_locked
        .live
        .active
        .as_ref()
        .filter(|a| a.binding.owner.same(&h.binding.owner))
    else {
        return Command::done();
    };
    if !lifecycle::active_current(model) {
        return stop(model);
    }
    let Some(k) = &active.binding.kernel else {
        return Command::done();
    };
    if h.display != k.is_published() {
        return Command::done();
    }
    let Ok(proof) = completion.result else {
        return stop(model);
    };
    if h.display {
        return if k.accept_display_check(proof, Instant::now()).is_ok() {
            Command::done()
        } else {
            stop(model)
        };
    }
    let Ok(deadline) = k.renewal_acknowledgement_deadline(&proof) else {
        return stop(model);
    };
    let Ok(previous_deadline) = k.current_deadline() else {
        return stop(model);
    };
    if deadline < previous_deadline {
        return stop(model);
    }
    if deadline
        .saturating_duration_since(previous_deadline)
        .as_millis()
        == 0
    {
        return Command::done();
    }
    let command = match k.propose_successor(proof, deadline, Instant::now()) {
        Ok(c) => c,
        Err(coordinator::Error::Busy | coordinator::Error::Stale) => return Command::done(),
        Err(_) => return stop(model),
    };
    let (previous, lease) = coordinator::PairCoordinator::renewal_wire(&command);
    let Some(mut ticket) = active.binding.ticket.clone() else {
        return stop(model);
    };
    ticket.pending = active.binding.pending.clone();
    ticket.acquisition_lease = lease.clone();
    let heartbeat = h.clone();
    let scheduled = driver::schedule(&active.binding);
    scheduled.and(Command::new(move |ctx| async move {
        let result = io(
            &ctx,
            ShellOperation::RenewImmichLockedLiveAcquisition {
                ticket,
                previous_lease_id: previous,
                lease,
            },
        )
        .await;
        ctx.send_event(Event::ImmichLockedLiveRenewed {
            completion: Box::new(RenewalCompletion {
                heartbeat,
                command,
                result,
            }),
        });
    }))
}
pub(super) fn renewed(
    model: &mut Model,
    c: RenewalCompletion,
) -> Command<crate::app::Effect, Event> {
    let Some(a) = model
        .immich_locked
        .live
        .active
        .as_ref()
        .filter(|a| a.binding.owner.same(&c.heartbeat.binding.owner))
    else {
        return Command::done();
    };
    if !lifecycle::active_current(model) {
        return stop(model);
    }
    let Some(k) = &a.binding.kernel else {
        return stop(model);
    };
    let result = c
        .result
        .and_then(|r| k.renewal_receipt(c.command, &r))
        .and_then(|r| {
            k.acknowledge_successor(r, Instant::now())
                .map_err(|_| ERROR.into())
        });
    if result.is_err() {
        return stop(model);
    }
    driver::schedule(&a.binding).and(driver::advance(model))
}
