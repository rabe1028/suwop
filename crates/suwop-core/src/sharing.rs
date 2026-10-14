use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferReceipt, catalog,
    normalize_sha1,
};
mod current;
mod rendering;
pub use current::{
    CurrentImageExport, CurrentImageFacts, current_image_asset, current_image_name,
    verify_current_asset, verify_current_image,
};
pub use rendering::{CurrentImageMetadata, CurrentImageRenderPlan, CurrentImageRenderResult};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum OriginalIdentity {
    Digest(String),
    Resource(AssetKey, String),
}

fn identities(asset: &StoredAsset) -> BTreeSet<OriginalIdentity> {
    asset
        .originals()
        .map(|r| {
            normalize_sha1(r.sha1.as_deref()).map_or_else(
                || OriginalIdentity::Resource(asset.key.clone(), r.id.clone()),
                OriginalIdentity::Digest,
            )
        })
        .collect()
}

fn source_group(assets: &[&StoredAsset]) -> (Vec<AssetKey>, usize) {
    let mut assets = assets.to_vec();
    assets.sort_by_key(|a| (std::cmp::Reverse(a.originals().count()), &a.key));
    let mut covered = BTreeSet::new();
    let mut keys = Vec::new();
    for asset in assets {
        let originals = identities(asset);
        if !originals.is_subset(&covered) {
            covered.extend(originals);
            keys.push(asset.key.clone());
        }
    }
    (keys, covered.len())
}

fn complete_sources(
    assets: &[StoredAsset],
    available: &BTreeSet<&AssetKey>,
) -> Result<Vec<AssetKey>, String> {
    let mut groups: BTreeMap<_, Vec<_>> = BTreeMap::new();
    for asset in assets.iter().filter(|a| a.inventory_complete) {
        groups
            .entry((asset.key.provider, &asset.key.scope))
            .or_default()
            .push(asset);
    }
    // Preserve a complete provider's originals, including RAW/JPEG spread over
    // separate Immich assets. A Live companion must not replace its parent.
    let required = groups
        .values()
        .map(|g| source_group(g).1)
        .chain(assets.iter().map(|a| a.originals().count()))
        .max()
        .unwrap_or(0);
    groups
        .into_iter()
        .filter_map(|((provider, _), group)| {
            let accessible: Vec<_> = group
                .into_iter()
                .filter(|a| available.contains(&a.key) && !a.is_offline)
                .collect();
            let (keys, count) = source_group(&accessible);
            (count >= required && !keys.is_empty()).then_some((provider, keys, count))
        })
        .min_by_key(|(provider, _, count)| {
            (std::cmp::Reverse(*count), *provider != Provider::Apple)
        })
        .map(|(_, keys, _)| keys)
        .ok_or_else(|| "共有する写真の全原本にアクセスできません。一覧を更新してください。".into())
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ShareFile {
    pub path: String,
    pub name: String,
}

/// Native presentation identity contains only the physical sources actually read.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SharePresentation {
    pub files: Vec<ShareFile>,
    /// Missing identity in a legacy request is handled conservatively by the shell.
    #[serde(default)]
    pub source_keys: Option<Vec<AssetKey>>,
}

/// Select a complete source group for each catalog photo. Prefer Apple when it
/// provides the same complete originals, without duplicating related resources.
pub fn sources(
    snapshots: &[LibrarySnapshot],
    receipts: &[TransferReceipt],
    keys: &[AssetKey],
) -> Result<Vec<AssetKey>, String> {
    let requested: BTreeSet<_> = keys.iter().collect();
    if requested.is_empty() {
        return Err("共有する写真を選択してください。".into());
    }
    let photos = catalog(snapshots, receipts);
    let known: BTreeSet<_> = photos
        .iter()
        .flat_map(|p| p.assets.iter().map(|a| &a.key))
        .collect();
    if !requested.is_subset(&known) {
        return Err("選択した写真を確認できません。一覧を更新してください。".into());
    }
    let available: BTreeSet<_> = snapshots
        .iter()
        .filter(|s| s.access != ScanAccess::Unavailable)
        .flat_map(|s| s.assets.iter().map(|a| &a.key))
        .collect();
    photos
        .iter()
        .filter(|p| p.assets.iter().any(|a| requested.contains(&a.key)))
        .map(|photo| complete_sources(&photo.assets, &available))
        .collect::<Result<Vec<_>, _>>()
        .map(|groups| groups.into_iter().flatten().collect())
}

pub fn filename(name: &str) -> Result<String, String> {
    let name = crate::immich::safe_name(name);
    if name == "." || name == ".." || name.len() > 240 || name.chars().any(char::is_control) {
        return Err("原本のファイル名を共有に使用できません。".into());
    }
    Ok(name)
}

#[must_use]
pub fn contains_file(directory: &str, path: &str) -> bool {
    path.strip_prefix(&format!("{directory}/"))
        .is_some_and(|relative| {
            !relative.is_empty() && relative.split('/').all(|p| !matches!(p, "" | "." | ".."))
        })
}
