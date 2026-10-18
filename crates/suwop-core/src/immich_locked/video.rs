//! Private selected VIDEO acquisition. Never an export, ordinary read or write grant.
mod acquisition;
mod cleanup;
pub use cleanup::CleanupCompletion;
pub(crate) use cleanup::{projection as cleanup_projection, retry as retry_cleanup};
mod policy;
mod renewal;
use super::{
    Asset, AssetKey, Command, Context, Deserialize, ERROR, Event, HttpRequest, Model, Serialize,
    ShellOperation, StoredAsset, Value, VisibilitySession, check, current, denied, epoch, io,
    visibility_session,
};
use crate::domain::FileSignature;
pub use policy::{
    ImmichLockedVideoCapacityClass, ImmichLockedVideoCommitmentMode, ImmichLockedVideoStorageFacts,
};
pub use renewal::{
    ImmichLockedVideoAcquisitionLease, ImmichLockedVideoAcquisitionRenewed,
    ImmichLockedVideoAcquisitionState,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedVideoPhase {
    Checking,
    Acquiring,
    Preparing,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoPending {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "entryID")]
    pub entry_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub key: AssetKey,
    pub phase: ImmichLockedVideoPhase,
}
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoTicket {
    pub pending: ImmichLockedVideoPending,
    pub acquisition_lease: ImmichLockedVideoAcquisitionLease,
    pub initial_acquisition_lease: ImmichLockedVideoAcquisitionLease,
    #[serde(rename = "displayLeaseID")]
    pub display_lease_id: u64,
    pub deadline_unix_milliseconds: u64,
    pub expected_revision: String,
    pub expected_sha1: String,
    pub expected_bytes: Option<u64>,
    pub commitment_mode: ImmichLockedVideoCommitmentMode,
    pub storage: ImmichLockedVideoStorageFacts,
    pub max_received_bytes: u64,
    pub minimum_remaining_bytes: u64,
    pub request: HttpRequest,
}
impl std::fmt::Debug for ImmichLockedVideoTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ImmichLockedVideoTicket([redacted])")
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoResult {
    #[serde(rename = "acquisitionLeaseID")]
    pub acquisition_lease_id: u64,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
    pub sha1: String,
    pub signature: FileSignature,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoPrepared {
    #[serde(rename = "acquisitionLeaseID")]
    pub acquisition_lease_id: u64,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoAccess {
    pub pending: ImmichLockedVideoPending,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Default)]
pub(super) struct VideoModel {
    binding: Option<VideoAcquisition>,
    pending: Option<ImmichLockedVideoPending>,
    access: Option<ImmichLockedVideoAccess>,
    lease: Option<(ImmichLockedVideoPending, String)>,
    measured_bytes: Option<u64>,
    renewal: renewal::RenewalModel,
    retired: Vec<cleanup::Retired>,
}
impl VideoModel {
    pub(super) fn has_work(&self) -> bool {
        self.pending.is_some()
            || self.lease.is_some()
            || self.access.is_some()
            || !self.retired.is_empty()
    }
}
#[derive(Clone, Debug)]
pub struct VideoAcquisition {
    pending: ImmichLockedVideoPending,
    capability: VisibilitySession,
    revision: String,
    sha1: String,
    bytes: Option<u64>,
    lease: renewal::SharedLease,
}
fn same_request(a: &ImmichLockedVideoPending, b: &ImmichLockedVideoPending) -> bool {
    a.request_id == b.request_id
        && a.entry_id == b.entry_id
        && a.grant_id == b.grant_id
        && a.scene_id == b.scene_id
        && a.generation == b.generation
        && a.key == b.key
}
fn pending_current(model: &Model, pending: &ImmichLockedVideoPending) -> bool {
    model.immich_locked.video.binding.as_ref().is_some_and(|a| {
        (if model
            .immich_locked
            .video
            .access
            .as_ref()
            .is_some_and(|access| same_request(&access.pending, pending))
        {
            check(&a.capability.generation, a.capability.expected).is_ok()
                && check(
                    &a.capability.projection_generation,
                    a.capability.expected_projection,
                )
                .is_ok()
                && std::time::Instant::now() < a.capability.hard_deadline
        } else {
            a.current_capability().is_ok()
        }) && model
            .immich_locked
            .entries
            .iter()
            .any(|e| e.asset.key == pending.key && e.asset.revision == a.revision)
    }) && !model.immich_visibility.persistence_uncertain
        && current(model)
        && epoch(&model.immich_locked) == pending.generation
        && model.immich_locked.grant_id.as_ref() == Some(&pending.grant_id)
        && model.immich_locked.scene_id.as_ref() == Some(&pending.scene_id)
        && !denied(model, &pending.key)
        && model
            .immich_locked
            .entries
            .iter()
            .any(|e| e.id == pending.entry_id && e.asset.key == pending.key)
        && model
            .immich_locked
            .video
            .pending
            .as_ref()
            .is_some_and(|p| same_request(p, pending))
}
pub(super) fn eligible(asset: &StoredAsset) -> bool {
    asset.originals().any(|r| {
        r.id == asset.key.asset_id
            && r.role == crate::domain::ResourceRole::Video
            && crate::domain::normalize_sha1(r.sha1.as_deref()).is_some()
    })
}
pub(super) fn projection(
    model: &Model,
) -> (
    Option<ImmichLockedVideoPending>,
    Option<ImmichLockedVideoAccess>,
) {
    let video = &model.immich_locked.video;
    let pending = video.pending.clone().filter(|p| pending_current(model, p));
    let access = video
        .access
        .clone()
        .filter(|a| pending_current(model, &a.pending));
    (pending, access)
}
/// Delayed acquisition replies cannot restart cleanup or pick up a new failure token.
fn release(
    model: &mut Model,
    pending: &ImmichLockedVideoPending,
) -> Command<crate::app::Effect, Event> {
    if model
        .immich_locked
        .video
        .pending
        .as_ref()
        .is_some_and(|p| same_request(p, pending))
    {
        stop(model)
    } else {
        // Stop captured/sealed the entire original worker before the first await. Once
        // its successful JOIN is observed, a queued reply cannot own additional files.
        Command::done()
    }
}
pub(crate) fn stop(model: &mut Model) -> Command<crate::app::Effect, Event> {
    stop_with_retry(model, false)
}
fn stop_with_retry(model: &mut Model, retry_cleanup: bool) -> Command<crate::app::Effect, Event> {
    let video = &mut model.immich_locked.video;
    if let Some(binding) = &video.binding {
        binding.lease.terminalize();
    }
    video.renewal = renewal::RenewalModel::default();
    video.measured_bytes = None;
    video.binding = None;
    let pending = video.pending.take();
    video.access = None;
    let lease = video.lease.take().map(|(_, id)| id);
    pending.map_or_else(Command::done, |pending| {
        cleanup::retire(model, pending, lease, retry_cleanup)
    })
}
/// Retire only the selected request synchronously. Native quiescence owns its JOIN/cleanup.
pub(crate) fn stop_for_key(
    model: &mut Model,
    key: &AssetKey,
) -> Command<crate::app::Effect, Event> {
    if model
        .immich_locked
        .video
        .pending
        .as_ref()
        .is_some_and(|p| &p.key == key)
    {
        stop(model)
    } else {
        Command::done()
    }
}
/// Full request identity is immutable and request IDs are never reused in this grant lifetime.
#[derive(Debug, Clone)]
pub(crate) struct CapturedOwner {
    pending: Option<ImmichLockedVideoPending>,
    retired: Vec<cleanup::Captured>,
}
impl CapturedOwner {
    pub(crate) fn pending(&self) -> Vec<ImmichLockedVideoPending> {
        let mut result: Vec<_> = self.pending.iter().cloned().collect();
        for pending in cleanup::pending(&self.retired) {
            if !result.iter().any(|p| same_request(p, &pending)) {
                result.push(pending);
            }
        }
        result
    }
    pub(crate) fn owns_pending(&self, pending: &ImmichLockedVideoPending) -> bool {
        self.pending
            .as_ref()
            .is_some_and(|p| same_request(p, pending))
            || cleanup::owns(&self.retired, pending)
    }
}
pub(crate) fn capture_owner(model: &Model, key: &AssetKey) -> CapturedOwner {
    CapturedOwner {
        pending: model
            .immich_locked
            .video
            .pending
            .clone()
            .filter(|p| p.key == *key),
        retired: cleanup::capture(model, key),
    }
}
pub(crate) fn captured_drained(model: &mut Model, captured: &CapturedOwner) {
    cleanup::drained(model, &captured.retired);
}
pub(crate) fn retire_captured(
    model: &mut Model,
    captured: &CapturedOwner,
) -> Command<crate::app::Effect, Event> {
    if captured.pending.as_ref().is_some_and(|old| {
        model
            .immich_locked
            .video
            .pending
            .as_ref()
            .is_some_and(|current| same_request(old, current))
    }) {
        // Native same-capture Drain retains the actual pending worker/quote until JOIN.
        // No normal Release may race it and acquire an automatic unlink retry token.
        let video = &mut model.immich_locked.video;
        if let Some(binding) = &video.binding {
            binding.lease.terminalize();
        }
        video.renewal = renewal::RenewalModel::default();
        video.measured_bytes = None;
        video.binding = None;
        video.pending = None;
        video.access = None;
        video.lease = None;
        Command::done()
    } else {
        Command::done()
    }
}

pub(crate) fn quiesce_visibility(
    model: &mut Model,
    key: &AssetKey,
) -> (
    Option<ImmichLockedVideoPending>,
    Command<crate::app::Effect, Event>,
) {
    let pending = model
        .immich_locked
        .video
        .pending
        .clone()
        .filter(|p| &p.key == key);
    let cleanup = if pending.is_some() {
        stop(model)
    } else {
        Command::done()
    };
    (pending, cleanup)
}
pub(crate) fn reconcile(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if model
        .immich_locked
        .video
        .pending
        .as_ref()
        .is_some_and(|p| !pending_current(model, p))
    {
        stop(model)
    } else {
        Command::done()
    }
}
pub(crate) fn update(
    event: Event,
    model: &mut Model,
) -> Option<Command<crate::app::Effect, Event>> {
    if let Some(command) = renewal::update(event.clone(), model) {
        return Some(command);
    }
    Some(match event {
        Event::PrivateMediaVideoCleanupCompleted { completion } => {
            cleanup::completed(model, completion)
        }
        Event::RequestImmichLockedVideo {
            entry_id,
            grant_id,
            scene_id,
            request_id,
        } => acquisition::request(model, entry_id, grant_id, scene_id, request_id),
        Event::StopImmichLockedVideo {
            scene_id,
            request_id,
            retry_cleanup: _,
        } => {
            if model
                .immich_locked
                .video
                .pending
                .as_ref()
                .is_some_and(|p| p.scene_id == scene_id && p.request_id == request_id)
            {
                stop_with_retry(model, false)
            } else {
                Command::done()
            }
        }
        Event::ImmichLockedVideoPlanned {
            acquisition,
            storage,
        } => acquisition::planned(model, acquisition, storage),
        Event::ImmichLockedVideoRead {
            acquisition,
            ticket,
            result,
        } => {
            if model.immich_locked.video.pending.as_ref().is_some_and(|p| {
                same_request(p, &ticket.pending) && p.phase != ImmichLockedVideoPhase::Acquiring
            }) {
                return Some(Command::done());
            }
            let event = Event::ImmichLockedVideoRead {
                acquisition: acquisition.clone(),
                ticket: ticket.clone(),
                result: result.clone(),
            };
            if renewal::hold(model, event) {
                Command::done()
            } else {
                acquisition::read(model, acquisition, *ticket, result)
            }
        }
        Event::ImmichLockedVideoPrepared {
            ticket,
            approved,
            acquisition_lease_id,
        } => prepared(model, ticket, approved, acquisition_lease_id),
        _ => return None,
    })
}

fn prepared(
    model: &mut Model,
    ticket: ImmichLockedVideoTicket,
    approved: bool,
    acquisition_lease_id: u64,
) -> Command<crate::app::Effect, Event> {
    if model
        .immich_locked
        .video
        .access
        .as_ref()
        .is_some_and(|access| same_request(&access.pending, &ticket.pending))
    {
        return Command::done();
    }
    if renewal::hold(
        model,
        Event::ImmichLockedVideoPrepared {
            ticket: ticket.clone(),
            approved,
            acquisition_lease_id,
        },
    ) {
        return Command::done();
    }
    if approved
        && pending_current(model, &ticket.pending)
        && renewal::completion_current(model, &ticket, acquisition_lease_id)
    {
        model.immich_locked.video.renewal = renewal::RenewalModel::default();
        model.immich_locked.video.access = Some(ImmichLockedVideoAccess {
            pending: ticket.pending,
            staged_id: ticket.storage.lease_id,
        });
        Command::done()
    } else {
        if pending_current(model, &ticket.pending) {
            model.immich_locked.error =
                Some("動画を確認できません。もう一度選んでください。".into());
        }
        let cleanup = if pending_current(model, &ticket.pending) {
            stop(model)
        } else {
            Command::done()
        };
        cleanup.and(release(model, &ticket.pending))
    }
}

#[cfg(test)]
mod tests;

pub use renewal::VideoHeartbeat;
pub(super) fn heartbeat(model: &Model) -> Option<VideoHeartbeat> {
    renewal::heartbeat(model)
}
pub(super) async fn check_heartbeat(ctx: &Context, binding: &VideoHeartbeat) -> Result<(), String> {
    renewal::check_heartbeat(ctx, binding).await
}
pub(super) fn renew(
    model: &mut Model,
    heartbeat: Option<VideoHeartbeat>,
    deadline: std::time::Instant,
) -> Command<crate::app::Effect, Event> {
    renewal::renew(model, heartbeat, deadline)
}
pub(super) fn acquisition_projection(model: &Model) -> Option<ImmichLockedVideoAcquisitionState> {
    renewal::projection(model)
}
