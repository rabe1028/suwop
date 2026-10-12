use crate::domain::{AssetKey, LibrarySnapshot, Provider, ResourceRole, ScanAccess, UnifiedPhoto};
use std::collections::{BTreeMap, BTreeSet};

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
    EditingAccess::new(snapshots, apple_scope).targets(photo)
}

/// Build current full-access membership once for all tiles. Duplicate scopes or
/// physical IDs cannot authorize a content write, even if one record matches.
#[derive(Debug)]
pub struct EditingAccess<'a> {
    assets: BTreeMap<&'a AssetKey, &'a crate::domain::StoredAsset>,
}
impl<'a> EditingAccess<'a> {
    #[must_use]
    pub fn new(snapshots: &'a [LibrarySnapshot], apple_scope: &str) -> Self {
        let mut assets = BTreeMap::new();
        let mut duplicates = BTreeSet::new();
        let mut matches = snapshots
            .iter()
            .filter(|s| s.provider == Provider::Apple && s.scope == apple_scope);
        if let Some(snapshot) = matches.next()
            && matches.next().is_none()
            && snapshot.access == ScanAccess::Full
        {
            for asset in &snapshot.assets {
                if asset.key.provider == Provider::Apple
                    && asset.key.scope == apple_scope
                    && assets.insert(&asset.key, asset).is_some()
                {
                    duplicates.insert(&asset.key);
                }
            }
        }
        assets.retain(|key, _| !duplicates.contains(key));
        Self { assets }
    }

    #[must_use]
    pub fn targets(&self, photo: &UnifiedPhoto) -> Vec<EditingTarget> {
        photo
            .assets
            .iter()
            .map(|asset| {
                let disabled = if asset.key.provider == Provider::Immich {
                    Some("この保存先の写真編集は準備中です。")
                } else if !self
                    .assets
                    .get(&asset.key)
                    .is_some_and(|record| **record == *asset)
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
}
