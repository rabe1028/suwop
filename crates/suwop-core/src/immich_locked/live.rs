//! Private, paired C1 read. Neither a write capability nor ordinary/export authority.
mod coordinator;
mod discovery;
mod driver;
mod heartbeat;
mod lifecycle;
mod policy;
mod types;
use super::resource_policy::PRIVATE_MEDIA_HEADROOM_BYTES;
use super::{VisibilitySession, current, epoch};
use crate::{
    app::{Context, Event, Model, ShellOperation, io},
    domain::AssetKey,
    immich_live_resources::LiveResourceReadFact,
};
use crux_core::Command;
pub use discovery::ImmichLockedLiveDiscovery;
pub(super) use discovery::{discovery_hint, selected_discovery_hint};
pub use heartbeat::RenewalCompletion;
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};
pub use types::*;
const ERROR: &str = "Live Photo の原本を安全に開けません。";
use coordinator::{PairCoordinator, Stage};

#[derive(Debug, Clone)]
struct Authority {
    session: VisibilitySession,
    request_epoch: Arc<AtomicU64>,
    request_expected: u64,
    ordinary: Arc<AtomicU64>,
    ordinary_expected: u64,
    protection: Arc<AtomicU64>,
    protection_expected: u64,
}
impl Authority {
    fn valid(&self) -> Result<(), String> {
        self.session.valid()?;
        if self.request_epoch.load(Ordering::SeqCst) != self.request_expected
            || self.ordinary.load(Ordering::SeqCst) != self.ordinary_expected
            || self.protection.load(Ordering::SeqCst) != self.protection_expected
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
    async fn status(&self, ctx: &Context) -> Result<Instant, String> {
        self.valid()?;
        let deadline = super::status(
            ctx,
            &self.session.generation,
            self.session.expected,
            &self.session.session,
        )
        .await?;
        self.valid()?;
        Ok(deadline)
    }
    async fn json(&self, ctx: &Context, path: &str) -> Result<serde_json::Value, String> {
        self.valid()?;
        let value = self.session.json(ctx, path, "GET", None).await?;
        self.valid()?;
        Ok(value)
    }
}
#[derive(Debug, Clone)]
struct Owner(Arc<()>);
impl Owner {
    fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
#[derive(Debug, Clone)]
struct Binding {
    owner: Owner,
    pending: ImmichLockedLivePending,
    authority: Authority,
    expected: [LiveResourceReadFact; 2],
    sizes: [Option<u64>; 2],
    kernel: Option<PairCoordinator>,
    ticket: Option<ImmichLockedLiveTicket>,
    quote_id: Option<String>,
    display_lease_id: u64,
}
impl Binding {
    fn authority(&self) -> Result<Authority, String> {
        let mut a = self.authority.clone();
        if let Some(k) = &self.kernel {
            a.session.lease_deadline = k.current_deadline()?;
        }
        a.valid()?;
        Ok(a)
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Initial,
    Start(Stage),
    Check(Stage),
    Final,
    Publish,
    Done,
}
#[derive(Debug, Clone)]
struct Active {
    binding: Binding,
    step: Step,
    working: bool,
    originals: [Option<ImmichLockedLiveOriginal>; 2],
    provisional: Option<(coordinator::ProvisionalAccess, ImmichLockedLivePublication)>,
    access: Option<ImmichLockedLivePublication>,
}
#[derive(Debug, Clone)]
struct Retired {
    binding: Binding,
    lease_id: Option<String>,
    releasing: bool,
    recovery: crate::private_media_cleanup::Recovery,
}
impl Retired {
    fn new(binding: Binding, lease_id: Option<String>) -> Self {
        let recovery = crate::private_media_cleanup::Recovery::new();
        Self {
            binding,
            lease_id,
            releasing: false,
            recovery,
        }
    }
}
#[derive(Debug, Clone)]
struct Request {
    plan: String,
    id: String,
    scene: String,
    grant: String,
}
#[derive(Debug, Default)]
pub(super) struct LiveModel {
    request_epoch: Arc<AtomicU64>,
    active: Option<Active>,
    retired: Option<Retired>,
    queued: Option<Request>,
}
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Owner,
    binding: Binding,
    outcome: driver::Outcome,
}
#[derive(Debug, Clone)]
pub struct LiveHeartbeat {
    binding: Binding,
    capture: Option<coordinator::Capture>,
    display: bool,
}
#[derive(Debug, Clone)]
pub struct HeartbeatCompletion {
    heartbeat: LiveHeartbeat,
    result: Result<coordinator::PairProof, String>,
}

pub(super) use heartbeat::{check_heartbeat, checked, heartbeat};
pub(crate) use lifecycle::reconcile;
pub(super) use lifecycle::{acquisition_projection, projection, stop};
pub(super) fn update(
    event: &Event,
    model: &mut Model,
) -> Option<Command<crate::app::Effect, Event>> {
    match event {
        Event::RequestImmichLockedLive {
            plan_id,
            request_id,
            scene_id,
            grant_id,
        } => Some(lifecycle::request(
            model,
            Request {
                plan: plan_id.clone(),
                id: request_id.clone(),
                scene: scene_id.clone(),
                grant: grant_id.clone(),
            },
        )),
        Event::StopImmichLockedLive {
            scene_id,
            request_id,
            retry_cleanup: _,
        } => {
            let state = &model.immich_locked.live;
            let matches = state
                .active
                .as_ref()
                .map(|a| &a.binding.pending)
                .or_else(|| state.retired.as_ref().map(|r| &r.binding.pending))
                .is_some_and(|p| p.scene_id == *scene_id && p.request_id == *request_id);
            Some(if matches {
                if state.active.is_some() {
                    lifecycle::stop_with_retry(model, false)
                } else {
                    lifecycle::retry_retired(model, false)
                }
            } else {
                Command::done()
            })
        }
        Event::ExpireImmichLockedLiveAcquisition {
            scene_id,
            request_id,
            generation,
            ..
        } => Some(if let Some(active) = &model.immich_locked.live.active {
            if active.binding.pending.scene_id == *scene_id
                && active.binding.pending.request_id == *request_id
                && active.binding.pending.generation == *generation
                && active
                    .binding
                    .kernel
                    .as_ref()
                    .is_some_and(|k| k.poll_deadlines(Instant::now()).is_err())
            {
                stop(model)
            } else {
                Command::done()
            }
        } else {
            Command::done()
        }),
        Event::ImmichLockedLiveCompleted { completion } => {
            Some(driver::completed(model, completion.as_ref().clone()))
        }
        Event::ImmichLockedLiveRenewed { completion } => {
            Some(heartbeat::renewed(model, completion.as_ref().clone()))
        }
        Event::ImmichLockedLiveHeartbeat { completion } => {
            Some(heartbeat::completed(model, completion.as_ref().clone()))
        }
        _ => None,
    }
}
fn now_ms() -> Result<u64, String> {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| ERROR)?
            .as_millis(),
    )
    .map_err(|_| ERROR.into())
}
fn fresh_id() -> Result<String, String> {
    let mut bytes = [0_u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| ERROR)?;
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

/// Private pointer identity captured before native revocation; never a key-based late lookup.
#[derive(Debug, Clone)]
pub(crate) struct CapturedOwners(Vec<(Owner, ImmichLockedLivePending)>);
impl CapturedOwners {
    pub(crate) fn pending(&self) -> Vec<ImmichLockedLivePending> {
        self.0.iter().map(|(_, p)| p.clone()).collect()
    }
}
pub(crate) fn capture_owners(model: &Model, key: &AssetKey) -> CapturedOwners {
    let s = &model.immich_locked.live;
    CapturedOwners(
        s.active
            .iter()
            .map(|a| &a.binding)
            .chain(s.retired.iter().map(|r| &r.binding))
            .filter(|b| b.pending.parent_key == *key || b.pending.motion_key == *key)
            .map(|b| (b.owner.clone(), b.pending.clone()))
            .collect(),
    )
}
/// Capture retirement never issues a retry-capable normal Release. Its exact
/// retained native drain completion, not a key lookup, discharges this obligation.
pub(crate) fn retire_captured(
    model: &mut Model,
    captured: &CapturedOwners,
) -> Command<crate::app::Effect, Event> {
    let state = &mut model.immich_locked.live;
    if state
        .active
        .as_ref()
        .is_some_and(|a| captured.0.iter().any(|(o, _)| o.same(&a.binding.owner)))
    {
        let Some(active) = state.active.take() else {
            return Command::done();
        };
        next_request_epoch(state);
        if let Some(k) = &active.binding.kernel {
            let _ = k.stop();
        }
        state.retired = Some(Retired::new(
            active.binding.clone(),
            active.binding.quote_id.clone(),
        ));
    }
    Command::done()
}
pub(crate) fn captured_drained(
    model: &mut Model,
    captured: &CapturedOwners,
) -> Command<crate::app::Effect, Event> {
    let Some(retired) = model
        .immich_locked
        .live
        .retired
        .as_ref()
        .filter(|r| captured.0.iter().any(|(o, _)| o.same(&r.binding.owner)))
        .cloned()
    else {
        return Command::done();
    };
    lifecycle::joined(
        model,
        &retired.binding.owner,
        None,
        Ok(ImmichLockedLiveReleased {
            pending: retired.binding.pending,
            pair_lease_id: retired.lease_id,
        }),
    )
}

pub(crate) fn quiesce_visibility(
    model: &mut Model,
    key: &AssetKey,
) -> (
    Option<ImmichLockedLivePending>,
    Command<crate::app::Effect, Event>,
) {
    let pending = model
        .immich_locked
        .live
        .active
        .as_ref()
        .filter(|a| a.binding.pending.parent_key == *key || a.binding.pending.motion_key == *key)
        .map(|a| a.binding.pending.clone());
    let retired = model.immich_locked.live.retired.as_ref().is_some_and(|r| {
        r.binding.pending.parent_key == *key || r.binding.pending.motion_key == *key
    });
    let cleanup = if pending.is_some() || retired {
        stop(model)
    } else {
        Command::done()
    };
    // The release command must be retained: a native quiesce ACK authorizes no
    // Rust cleanup state transition. Only its exact private JOIN callback does.
    (pending, cleanup)
}

pub(super) fn has_work(model: &Model) -> bool {
    let s = &model.immich_locked.live;
    s.active.is_some() || s.retired.is_some()
}

fn next_request_epoch(state: &mut LiveModel) -> u64 {
    if let Ok(previous) =
        state
            .request_epoch
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
    {
        previous + 1
    } else {
        // Revoke captured old Arcs before replacing an exhausted counter.
        // Owner identity and Arc identity remain distinct across this reset.
        state.request_epoch.store(0, Ordering::SeqCst);
        state.request_epoch = Arc::new(AtomicU64::new(1));
        1
    }
}

fn phase(step: Step) -> ImmichLockedLivePhase {
    match step {
        Step::Initial => ImmichLockedLivePhase::Checking,
        Step::Start(Stage::Prepare) | Step::Check(Stage::Prepare) => {
            ImmichLockedLivePhase::Preparing
        }
        Step::Final | Step::Publish | Step::Done => ImmichLockedLivePhase::Publishing,
        _ => ImmichLockedLivePhase::Acquiring,
    }
}

pub(crate) fn cleanup_projection(
    model: &Model,
) -> Vec<crate::private_media_cleanup::PrivateMediaCleanupView> {
    model
        .immich_locked
        .live
        .retired
        .iter()
        .filter(|r| !crate::private_media_capture::owns_live(model, &r.binding.pending))
        .filter_map(|r| r.recovery.view())
        .collect()
}
pub(crate) fn retry_cleanup(
    model: &mut Model,
    id: &str,
    expected: u64,
) -> Option<Command<crate::app::Effect, Event>> {
    let r = model.immich_locked.live.retired.as_ref()?;
    if !r.recovery.accepts_retry(id, expected)
        || crate::private_media_capture::owns_live(model, &r.binding.pending)
    {
        return None;
    }
    model.immich_locked.live.queued = None;
    Some(lifecycle::retry_retired(model, true))
}
