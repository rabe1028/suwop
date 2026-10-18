//! Wire facts are effect receipts, never standalone authority.
use super::super::video::{
    ImmichLockedVideoAcquisitionLease, ImmichLockedVideoCommitmentMode,
    ImmichLockedVideoStorageFacts,
};
use crate::{
    domain::{AssetKey, FileSignature},
    immich::HttpRequest,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedLivePhase {
    Checking,
    Acquiring,
    Preparing,
    Publishing,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
/// Authority identity is the FULL tuple request/plan/scene/grant/generation/P/M.
/// `phase` is presentation only: it can change after an effect was dispatched.
/// Native matching against the current projection must compare every identity
/// field, excluding only phase; effect receipts echo their EXACT issued value.
pub struct ImmichLockedLivePending {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "planID")]
    pub plan_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    pub generation: u64,
    pub parent_key: AssetKey,
    pub motion_key: AssetKey,
    pub phase: ImmichLockedLivePhase,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedLiveRole {
    Parent,
    Motion,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveRepresentation {
    pub name: String,
    pub maximum_bytes: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveStorageFacts {
    pub storage: ImmichLockedVideoStorageFacts,
    pub representations: Vec<ImmichLockedLiveRepresentation>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveMember {
    pub role: ImmichLockedLiveRole,
    pub key: AssetKey,
    pub expected_revision: String,
    pub expected_sha1: String,
    pub expected_bytes: Option<u64>,
    pub commitment_mode: ImmichLockedVideoCommitmentMode,
    pub max_received_bytes: u64,
    pub initial_claim_bytes: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveTicket {
    pub pending: ImmichLockedLivePending,
    pub storage: ImmichLockedVideoStorageFacts,
    pub members: [ImmichLockedLiveMember; 2],
    pub representations: Vec<ImmichLockedLiveRepresentation>,
    pub acquisition_lease: ImmichLockedVideoAcquisitionLease,
    pub initial_acquisition_lease: ImmichLockedVideoAcquisitionLease,
    #[serde(rename = "displayLeaseID")]
    pub display_lease_id: u64,
    pub pair_disk_ceiling_bytes: u64,
    pub representation_reservation_bytes: u64,
    pub total_max_received_bytes: u64,
    pub minimum_remaining_bytes: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveOriginal {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: String,
    pub role: ImmichLockedLiveRole,
    #[serde(rename = "acquisitionLeaseID")]
    pub acquisition_lease_id: u64,
    pub sha1: String,
    pub signature: FileSignature,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLivePrepared {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: String,
    #[serde(rename = "acquisitionLeaseID")]
    pub acquisition_lease_id: u64,
    #[serde(rename = "preparedID")]
    pub prepared_id: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
/// Request/receipt for native atomic object handoff. This authorizes no pixels
/// until it appears in the current C1 view after the post-publication pair proof.
pub struct ImmichLockedLivePublication {
    pub pending: ImmichLockedLivePending,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: String,
    #[serde(rename = "preparedID")]
    pub prepared_id: String,
    #[serde(rename = "publicationID")]
    pub publication_id: String,
    #[serde(rename = "expectedAcquisitionLeaseID")]
    pub expected_acquisition_lease_id: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveRenewed {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: String,
    #[serde(rename = "previousLeaseID")]
    pub previous_lease_id: u64,
    #[serde(rename = "leaseID")]
    pub lease_id: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveReleased {
    pub pending: ImmichLockedLivePending,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveAcquisitionState {
    pub pending: ImmichLockedLivePending,
    #[serde(rename = "pairLeaseID")]
    pub pair_lease_id: String,
    pub lease: ImmichLockedVideoAcquisitionLease,
    pub initial_lease: ImmichLockedVideoAcquisitionLease,
    #[serde(rename = "acknowledgedLeaseID")]
    pub acknowledged_lease_id: u64,
}
// The HTTP route is only an effect input, never a view field.
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedLiveRead {
    pub ticket: ImmichLockedLiveTicket,
    pub role: ImmichLockedLiveRole,
    pub request: HttpRequest,
}
impl std::fmt::Debug for ImmichLockedLiveRead {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ImmichLockedLiveRead([redacted])")
    }
}
