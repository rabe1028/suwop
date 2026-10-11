use crate::domain::{AssetKey, LibrarySnapshot, Provider, ResourceRole, ScanAccess, UnifiedPhoto};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EditingTarget {
    pub key: AssetKey,
    pub name: String,
    pub disabled_reason: Option<String>,
}

/// Select an actual stored photo in the chosen library. A native Apple photo's
/// related originals stay together; other stored copies are never overwritten.
#[must_use]
pub fn targets(
    photo: &UnifiedPhoto,
    snapshots: &[LibrarySnapshot],
    apple_scope: &str,
) -> Vec<EditingTarget> {
    photo
        .assets
        .iter()
        .map(|asset| {
            let disabled = if asset.key.provider == Provider::Immich {
                Some("この保存先の写真編集は準備中です。")
            } else if asset.key.scope != apple_scope
                || !snapshots.iter().any(|s| {
                    s.provider == Provider::Apple
                        && s.scope == asset.key.scope
                        && s.access == ScanAccess::Full
                        && s.assets.iter().any(|a| a.key == asset.key)
                })
            {
                Some("編集には写真ライブラリへのフルアクセスと一覧の更新が必要です。")
            } else if asset.is_offline || !asset.inventory_complete {
                Some("この写真の原本を確認できません。一覧を更新してください。")
            } else if asset.originals().next().is_none()
                || asset
                    .originals()
                    .any(|r| matches!(r.role, ResourceRole::Video | ResourceRole::LiveVideo))
            {
                Some("動画とLive Photoの編集は準備中です。")
            } else {
                None
            };
            EditingTarget {
                key: asset.key.clone(),
                name: asset.name.clone(),
                disabled_reason: disabled.map(str::to_owned),
            }
        })
        .collect()
}
