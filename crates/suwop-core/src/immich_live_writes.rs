//! Schema11 evidence for explicitly confirmed physical-resource batches.
//! Persisted records are historical claims, never session/write/read authority.
//! Runtime children execute fresh, explicitly confirmed operations and native JOIN.
//! The serialized evidence alone grants none of that authority; matching Inspect
//! observations never turn an Unknown outcome into Applied.
use crate::domain::AssetKey;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

mod digest;
mod holds;
mod interaction;
pub(crate) mod ordinary;
pub use ordinary::PairPresentation;
pub use runtime::history::{
    LivePlacementHistory, LivePlacementHistoryBatch, LivePlacementHistoryResource,
};
pub(crate) mod ordinary_images;
pub(crate) mod ordinary_runtime;
pub use ordinary_images::{
    PairImageAccess, PairImagePending, PairImagePhase, PairImageResult, PairImageTicket,
    ticket_issued as ordinary_live_image_ticket_issued,
};
pub(crate) mod runtime;
pub use interaction::{
    LiveKeepPrompt, LiveKeepTarget, LivePlacementDestination, LivePlacementPrompt,
    LivePlacementPromptAlias, LivePlacementPromptResource, LiveResourceDestination,
};
pub use runtime::LivePlacementCleanup;
pub mod readback;
mod references;
#[cfg(test)]
mod tests;
mod transitions;
mod validate;

pub use digest::{
    closure_digest, intent_digest, legacy_record_digest, post_digest, reconciliation_digest,
    retired_outcomes_digest,
};
pub use holds::{LiveHold, LiveHoldReason, fences, holds};
pub(crate) use holds::{held_keys, security_differs};
pub use references::original_continuation_open;
pub use transitions::validate_transition;
pub use validate::{transition_allowed, validate_library};

pub const CURRENT_SCHEMA_VERSION: u32 = 11;
/// First catalog version that stores the Live journal arrays (9 is the Amazon catalog).
pub const LIVE_JOURNAL_SCHEMA_VERSION: u32 = 10;
const INVALID: &str = "Live Photo の変更記録が不正です。既存ファイルは変更しません。";
type Validation = Result<(), String>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Placement {
    Timeline,
    Archive,
    Hidden,
    Locked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Lock,
    Restore,
    Reposition,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    Parent,
    Motion,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Media {
    Image,
    Video,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Forward {
    Unlinked,
    Linked(AssetKey),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Fact {
    pub key: AssetKey,
    pub owner_id: String,
    pub media: Media,
    pub checksum: String,
    pub revision: String,
    pub placement: Placement,
    pub forward: Forward,
    pub unstacked: bool,
    pub offline: bool,
    pub trashed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Resource {
    pub id: String,
    pub initial: Fact,
    /// Sorted exact accessible album IDs measured before confirmation.
    pub initial_albums: Vec<String>,
    pub destination: Placement,
    /// None iff unchanged. An unchanged member remains confirmed and held.
    #[schemars(extend("x-suwop-explicit-null" = true))]
    pub step_id: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Selection {
    pub id: String,
    pub parent: AssetKey,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Edge {
    pub id: String,
    pub selection_id: String,
    pub parent_resource: String,
    pub motion_resource: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Alias {
    pub id: String,
    pub edge_id: String,
    pub role: Role,
    pub resource_id: String,
    pub destination: Placement,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Dependency {
    pub before: String,
    pub after: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StepRef {
    pub batch_id: String,
    pub step_id: String,
    pub intent_digest: String,
    /// Closing/superseding one step retires the WHOLE old execution cursor.
    /// Sibling outcomes cannot subsequently advance in that original batch.
    /// Mutable read-only observations are deliberately excluded.
    pub retired_outcomes_digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Intent {
    pub encoding_version: u32,
    pub owner_id: String,
    pub scope: String,
    pub direction: Direction,
    pub selections: Vec<Selection>,
    pub resources: Vec<Resource>,
    pub edges: Vec<Edge>,
    pub aliases: Vec<Alias>,
    /// Observed additional references are incomplete and are NOT write targets.
    pub observed_additional_parents: Vec<AssetKey>,
    pub shared_reference_limitations_acknowledged: bool,
    pub dependencies: Vec<Dependency>,
    pub ordered_step_ids: Vec<String>,
    pub supersedes: Vec<StepRef>,
    pub digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResourceObservation {
    pub fact: Fact,
    pub albums: Vec<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ObservationFailure {
    Denied,
    Unavailable,
    IdentityMismatch,
    Unsupported,
    Malformed,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum ObservedState {
    NotObserved,
    /// Exact owner/key facts observed now; may differ from immutable intent.
    /// This is not the strict fresh proof used for Applied or media admission.
    Own(Box<Fact>),
    Unavailable(ObservationFailure),
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemberObservation {
    pub key: AssetKey,
    pub state: ObservedState,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PostFacts {
    pub encoding_version: u32,
    pub batch_id: String,
    pub step_id: String,
    pub attempt_id: String,
    pub intent_digest: String,
    /// Full confirmed graph in the exact resource order, not just the last pair.
    pub resources: Vec<ResourceObservation>,
    pub digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Accepted204 {
    pub batch_id: String,
    pub step_id: String,
    pub attempt_id: String,
    pub key: AssetKey,
    pub intent_digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NoSubmissionRecord {
    pub batch_id: String,
    pub step_id: String,
    pub attempt_id: String,
    pub key: AssetKey,
    pub intent_digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Outcome {
    NotStarted,
    Unknown {
        attempt_id: String,
        #[schemars(extend("x-suwop-explicit-null" = true))]
        accepted: Option<Accepted204>,
    },
    Applied {
        attempt_id: String,
        accepted: Accepted204,
        verified_post: Box<PostFacts>,
    },
    NotApplied {
        attempt_id: String,
        no_submission: NoSubmissionRecord,
    },
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Step {
    pub id: String,
    pub resource_id: String,
    pub outcome: Outcome,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Batch {
    pub format_version: u32,
    pub id: String,
    pub intent: Intent,
    pub steps: Vec<Step>,
    /// Current read-only observations. Never a replacement for step outcomes.
    pub latest_observations: Vec<MemberObservation>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnstartedClosure {
    pub format_version: u32,
    pub id: String,
    pub references: Vec<StepRef>,
    /// Explicit `KeepCurrent`, not evidence of achieving the old destination.
    /// Current placements may differ. No provider write or authority is implied.
    pub current_graph: Vec<ResourceObservation>,
    pub digest: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LegacyRef {
    pub operation_id: String,
    /// Binds the entire legacy record as it was acknowledged. Mutable later
    /// Inspect results do not retroactively corrupt this historical evidence.
    pub record_digest: String,
    #[schemars(extend("x-suwop-explicit-null" = true))]
    pub acknowledged_observation: Option<crate::immich_visibility::ImmichVisibility>,
    pub acknowledged_albums: crate::immich_visibility::AlbumMembershipObservation,
    #[schemars(extend("x-suwop-explicit-null" = true))]
    pub acknowledged_selected: Option<crate::immich_visibility::SelectedVisibilityObservation>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LegacyReconciliation {
    pub format_version: u32,
    pub id: String,
    pub parent: AssetKey,
    pub legacy: Vec<LegacyRef>,
    pub confirmed_graph: Vec<ResourceObservation>,
    pub digest: String,
}

fn require(condition: bool) -> Validation {
    if condition {
        Ok(())
    } else {
        Err(INVALID.into())
    }
}
fn define(ids: &mut BTreeSet<String>, id: &str) -> Validation {
    crate::immich::valid_id(id)?;
    require(ids.insert(id.to_ascii_lowercase()))
}
