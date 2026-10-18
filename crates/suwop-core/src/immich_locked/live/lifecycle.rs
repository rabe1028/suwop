use super::{
    Active, Arc, Authority, Binding, Command, ERROR, Event, ImmichLockedLiveAcquisitionState,
    ImmichLockedLivePending, ImmichLockedLivePhase, ImmichLockedLivePublication,
    ImmichLockedLiveReleased, LiveResourceReadFact, Model, Ordering, Owner, PairCoordinator,
    Request, Retired, Step, current, driver, epoch, next_request_epoch, phase,
};
use crate::immich_live_resources::{LiveObservedVisibility, LiveResourceRole};
fn binding_current(model: &Model, b: &Binding) -> bool {
    current(model)
        && epoch(&model.immich_locked) == b.pending.generation
        && model.immich_locked.grant_id.as_ref() == Some(&b.pending.grant_id)
        && model.immich_locked.scene_id.as_ref() == Some(&b.pending.scene_id)
        && !model.immich_visibility.persistence_uncertain
        && !crate::immich_locked::live_metadata_denied(model, &b.pending.parent_key)
        && !crate::immich_locked::live_metadata_denied(model, &b.pending.motion_key)
        && if b.kernel.as_ref().is_some_and(PairCoordinator::is_published) {
            super::super::visibility_session(model, &b.pending.grant_id, &b.pending.scene_id)
                .is_some_and(|session| {
                    let mut a = b.authority.clone();
                    a.session = session;
                    a.valid().is_ok()
                })
        } else {
            b.authority().is_ok()
        }
}
pub(super) fn active_current(model: &Model) -> bool {
    model
        .immich_locked
        .live
        .active
        .as_ref()
        .is_some_and(|a| binding_current(model, &a.binding))
}
pub(in crate::immich_locked) fn projection(
    model: &Model,
) -> (
    Option<ImmichLockedLivePending>,
    Option<ImmichLockedLivePublication>,
) {
    let Some(a) = model
        .immich_locked
        .live
        .active
        .as_ref()
        .filter(|a| binding_current(model, &a.binding))
    else {
        return (None, None);
    };
    let mut pending = a.binding.pending.clone();
    pending.phase = phase(a.step);
    (
        Some(pending),
        a.access.clone().filter(|access| {
            a.binding
                .kernel
                .as_ref()
                .is_some_and(|k| k.publication_matches(access))
        }),
    )
}
pub(in crate::immich_locked) fn acquisition_projection(
    model: &Model,
) -> Option<ImmichLockedLiveAcquisitionState> {
    let a = model
        .immich_locked
        .live
        .active
        .as_ref()
        .filter(|a| binding_current(model, &a.binding))?;
    if a.access.is_some() {
        return None;
    }
    let k = a.binding.kernel.as_ref()?;
    let (lease, ack) = k.leases().ok()?;
    let t = a.binding.ticket.as_ref()?;
    Some(ImmichLockedLiveAcquisitionState {
        pending: a.binding.pending.clone(),
        pair_lease_id: t.storage.lease_id.clone(),
        lease,
        initial_lease: t.initial_acquisition_lease.clone(),
        acknowledged_lease_id: ack,
    })
}
fn begin(model: &mut Model, r: Request) -> Command<crate::app::Effect, Event> {
    if model.busy || !current(model) || crate::immich::valid_id(&r.id).is_err() {
        return Command::done();
    }
    let Some(plan) = crate::immich_live_resources::view(model)
        .and_then(|v| v.plan)
        .filter(|p| p.plan_id == r.plan)
    else {
        return Command::done();
    };
    let Ok(expected): Result<[LiveResourceReadFact; 2], _> = plan.read_targets.try_into() else {
        return Command::done();
    };
    if expected[0].role != LiveResourceRole::Parent
        || expected[1].role != LiveResourceRole::Motion
        || expected[0].key == expected[1].key
        || expected[0].visibility != LiveObservedVisibility::Locked
        || expected
            .iter()
            .any(|f| super::super::live_metadata_denied(model, &f.key))
    {
        return Command::done();
    }
    let Some(session) = super::super::visibility_session(model, &r.grant, &r.scene) else {
        return Command::done();
    };
    if expected.iter().any(|f| f.key.scope != session.scope()) {
        return Command::done();
    }
    if !model.immich_locked.used_ids.insert(r.id.clone()) {
        return Command::done();
    }
    let generation = epoch(&model.immich_locked);
    let display_lease_id = model.immich_locked.lease_id;
    let state = &mut model.immich_locked.live;
    let request_expected = next_request_epoch(state);
    let pending = ImmichLockedLivePending {
        request_id: r.id,
        plan_id: r.plan,
        scene_id: r.scene,
        grant_id: r.grant,
        generation,
        parent_key: expected[0].key.clone(),
        motion_key: expected[1].key.clone(),
        phase: ImmichLockedLivePhase::Checking,
    };
    let authority = Authority {
        session,
        request_epoch: state.request_epoch.clone(),
        request_expected,
        ordinary: model.ordinary_generation.clone(),
        ordinary_expected: model.ordinary_generation.load(Ordering::SeqCst),
        protection: model.protection.generation.clone(),
        protection_expected: model.protection.generation.load(Ordering::SeqCst),
    };
    let binding = Binding {
        owner: Owner(Arc::new(())),
        pending,
        authority,
        expected,
        sizes: [None, None],
        kernel: None,
        ticket: None,
        quote_id: None,
        display_lease_id,
    };
    model.immich_locked.live.active = Some(Active {
        binding: binding.clone(),
        step: Step::Initial,
        working: true,
        originals: [None, None],
        provisional: None,
        access: None,
    });
    driver::initial(binding)
}
pub(super) fn request(model: &mut Model, r: Request) -> Command<crate::app::Effect, Event> {
    let video_cleanup = super::super::video::stop(model);
    model.immich_locked.pending = None;
    model.immich_locked.image = None;
    let cleanup = stop(model);
    if model.immich_locked.live.retired.is_some() {
        model.immich_locked.live.queued = Some(r);
        video_cleanup.and(cleanup)
    } else {
        video_cleanup.and(cleanup).and(begin(model, r))
    }
}
/// Terminalize BEFORE awaiting native exact-owner JOIN. Quote absence is not ACK.
pub(in crate::immich_locked) fn stop(model: &mut Model) -> Command<crate::app::Effect, Event> {
    model.immich_locked.live.queued = None;
    let state = &mut model.immich_locked.live;
    if let Some(active) = state.active.take() {
        next_request_epoch(state);
        if let Some(k) = &active.binding.kernel {
            let _ = k.stop();
        }
        let lease_id = active.binding.quote_id.clone();
        state.retired = Some(Retired {
            binding: active.binding,
            lease_id,
            releasing: false,
        });
    }
    retry_retired(model)
}
pub(super) fn retry_retired(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if let Some(retired) = model.immich_locked.live.retired.as_mut()
        && !retired.releasing
    {
        retired.releasing = true;
        return driver::release(retired.clone());
    }
    Command::done()
}
pub(crate) fn reconcile(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if model.immich_locked.live.active.is_some() && !active_current(model) {
        stop(model)
    } else {
        Command::done()
    }
}
pub(super) fn joined(
    model: &mut Model,
    owner: &Owner,
    result: Result<ImmichLockedLiveReleased, String>,
) -> Command<crate::app::Effect, Event> {
    let state = &mut model.immich_locked.live;
    let Some(retired) = state
        .retired
        .as_mut()
        .filter(|r| r.binding.owner.same(owner))
    else {
        return Command::done();
    };
    // Full exact identity includes the two physical keys and original phase.
    let matches = match result {
        Ok(released) => {
            released.pending == retired.binding.pending
                && released.pair_lease_id == retired.lease_id
        }
        Err(_) => false,
    };
    if !matches {
        retired.releasing = false;
        model.immich_locked.error = Some(ERROR.into());
        return Command::done();
    }
    if retired
        .binding
        .kernel
        .as_ref()
        .is_some_and(|k| k.joined().is_err())
    {
        retired.releasing = false;
        return Command::done();
    }
    state.retired = None;
    let next = state.queued.take();
    next.map_or_else(Command::done, |r| begin(model, r))
}
pub(super) fn late_quote(
    model: &mut Model,
    binding: Binding,
    lease_id: String,
) -> Command<crate::app::Effect, Event> {
    // A JOIN response can be processed before an already queued quote-completion
    // event. Keep that old owner isolated; its idempotent release cannot touch B.
    if let Some(retired) = model
        .immich_locked
        .live
        .retired
        .as_mut()
        .filter(|r| r.binding.owner.same(&binding.owner))
        && retired.lease_id.as_ref() != Some(&lease_id)
    {
        retired.lease_id = Some(lease_id);
        retired.releasing = true;
        return driver::release(retired.clone());
    }
    driver::release(Retired {
        binding,
        lease_id: Some(lease_id),
        releasing: true,
    })
}
