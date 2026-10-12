//! Explicit Immich trash/restore intent, separate from transfer receipts.
use crate::{
    domain::{AssetKey, StoredAsset},
    immich::Asset,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum TrashAction {
    Trash,
    Restore,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashIdentity {
    pub key: AssetKey,
    pub name: String,
    pub checksum: String,
    pub media_type: String,
    pub created_at: String,
    pub modified_at: String,
    pub live_photo_video_id: Option<String>,
}
impl TrashIdentity {
    pub fn from_asset(scope: &str, asset: &Asset) -> Result<Self, String> {
        let checksum = crate::domain::normalize_sha1(Some(&asset.checksum))
            .ok_or("原本の識別情報を確認できません。")?;
        Ok(Self {
            key: AssetKey {
                provider: crate::domain::Provider::Immich,
                scope: scope.into(),
                asset_id: asset.id.clone(),
            },
            name: asset.original_file_name.clone(),
            checksum,
            media_type: asset.media_type.clone(),
            created_at: asset.file_created_at.clone(),
            modified_at: asset.file_modified_at.clone(),
            live_photo_video_id: asset.live_photo_video_id.clone(),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashItem {
    pub asset: StoredAsset,
    pub identity: TrashIdentity,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashSnapshot {
    pub scope: String,
    pub items: Vec<TrashItem>,
    pub verified: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashOperation {
    pub id: String,
    pub scope: String,
    pub action: TrashAction,
    pub assets: Vec<TrashIdentity>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TrashPrompt {
    pub action: TrashAction,
    pub address: String,
    pub names: Vec<String>,
    pub retention_days: Option<u32>,
}
