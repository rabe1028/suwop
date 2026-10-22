use std::collections::BTreeSet;

mod preview;
pub(crate) use preview::remember_preview;
pub use preview::{PreviewAccess, PreviewChoice, selected_preview};

use crate::domain::{
    AssetKey, LibrarySnapshot, Provider, ResourceRole, ScanAccess, StoredAsset, TransferBundle,
    TransferFile, TransferReceipt, UnifiedPhoto,
};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum PlaybackKind {
    Video,
    Live,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackPlan {
    #[serde(default)]
    pub source_keys: Vec<AssetKey>,
    pub kind: PlaybackKind,
    pub name: String,
    pub files: Vec<String>,
}

fn asset_kind(asset: &StoredAsset) -> Option<PlaybackKind> {
    let count = |role| asset.resources.iter().filter(|r| r.role == role).count();
    match (count(ResourceRole::Video), count(ResourceRole::LiveVideo)) {
        (0, 1) if count(ResourceRole::Image) == 1 => Some(PlaybackKind::Live),
        (1, 0) => Some(PlaybackKind::Video),
        _ => None,
    }
}

#[must_use]
pub fn kind(photo: &UnifiedPhoto) -> Option<PlaybackKind> {
    // A standalone companion can sort before its parent by asset ID. Preserve
    // the catalog's Live Photo representation regardless of that ordering.
    photo
        .assets
        .iter()
        .filter_map(asset_kind)
        .min_by_key(|kind| *kind != PlaybackKind::Live)
}

/// Playback is a read of one catalog photo, including a limited Apple library.
/// Never select offline or incomplete originals, or an unrelated account.
pub fn source(
    snapshots: &[LibrarySnapshot],
    receipts: &[TransferReceipt],
    keys: &[AssetKey],
) -> Result<(AssetKey, PlaybackKind), String> {
    let requested: BTreeSet<_> = keys.iter().collect();
    let photos = crate::display_catalog::photos(snapshots, receipts);
    let known: BTreeSet<_> = photos
        .iter()
        .flat_map(|p| p.assets.iter().map(|a| &a.key))
        .collect();
    if requested.is_empty() || !requested.is_subset(&known) {
        return Err("再生する写真を確認できません。一覧を更新してください。".into());
    }
    let selected: Vec<_> = photos
        .iter()
        .filter(|p| p.assets.iter().any(|a| requested.contains(&a.key)))
        .collect();
    if selected.len() != 1 {
        return Err("再生する写真を1件選択してください。".into());
    }
    let expected = kind(selected[0]).ok_or("再生できるメディアではありません。")?;
    let available: BTreeSet<_> = snapshots
        .iter()
        .filter(|s| s.access != ScanAccess::Unavailable)
        .flat_map(|s| s.assets.iter().map(|a| &a.key))
        .collect();
    selected[0]
        .assets
        .iter()
        .filter(|a| available.contains(&a.key) && !a.is_offline && a.inventory_complete)
        .filter_map(|a| {
            asset_kind(a)
                .filter(|kind| *kind == expected)
                .map(|kind| (a, kind))
        })
        .min_by_key(|(a, _)| a.key.provider != Provider::Apple)
        .map(|(a, kind)| (a.key.clone(), kind))
        .ok_or_else(|| "再生できる動画・Live Photo の原本がありません。".into())
}

pub fn files(
    bundle: &TransferBundle,
    expected: PlaybackKind,
) -> Result<Vec<&TransferFile>, String> {
    let [asset] = bundle.assets.as_slice() else {
        return Err("再生する写真の原本を確認できません。".into());
    };
    if asset_kind(asset) != Some(expected) {
        return Err("取得中にメディアの構成が変わりました。一覧を更新してください。".into());
    }
    let roles: &[ResourceRole] = match expected {
        PlaybackKind::Video => &[ResourceRole::Video],
        PlaybackKind::Live => &[ResourceRole::Image, ResourceRole::LiveVideo],
    };
    roles
        .iter()
        .map(|role| {
            let mut candidates = bundle.files.iter().filter(|f| f.resource.role == *role);
            let file = candidates.next().ok_or("再生に必要な原本がありません。")?;
            if candidates.next().is_some() {
                return Err("再生する原本を一意に確認できません。".into());
            }
            Ok(file)
        })
        .collect()
}
