//! Value-only prompts. None of these serializable values is execution authority.
use super::{Placement, Role};
use crate::domain::AssetKey;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum LivePlacementDestination {
    Locked,
    Timeline,
    Archive,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementPromptResource {
    pub key: AssetKey,
    pub name: String,
    pub role: Role,
    pub from: Placement,
    pub to: Placement,
    pub album_count: u32,
    pub unchanged: bool,
    pub removes_all_album_membership: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementPromptAlias {
    pub parent_key: AssetKey,
    pub motion_key: AssetKey,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementPrompt {
    #[serde(rename = "batchID")]
    pub batch_id: String,
    pub intent_digest: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    pub generation: u64,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub resources: Vec<LivePlacementPromptResource>,
    pub aliases: Vec<LivePlacementPromptAlias>,
    pub shared_reference_limitations_acknowledged: bool,
    pub continuing_access_disclosure: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveKeepPrompt {
    pub targets: Vec<LiveKeepTarget>,
    #[serde(rename = "batchID")]
    pub batch_id: String,
    #[serde(rename = "closureID")]
    pub closure_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub resources: Vec<LivePlacementPromptResource>,
    pub aliases: Vec<LivePlacementPromptAlias>,
    pub explanation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveKeepTarget {
    #[serde(rename = "stepID")]
    pub step_id: String,
    pub key: AssetKey,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveResourceDestination {
    pub key: AssetKey,
    pub destination: Placement,
}
