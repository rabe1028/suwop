use std::collections::BTreeSet;

use crate::domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, TransferReceipt, catalog};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ShareFile {
    pub path: String,
    pub name: String,
}

/// Select one available source for each selected catalog photo. Prefer the local
/// source so sharing an Apple photo never depends on an unrelated remote outage.
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
        .map(|photo| {
            photo
                .assets
                .iter()
                .filter(|a| available.contains(&a.key))
                .min_by_key(|a| a.key.provider != Provider::Apple)
                .map(|a| a.key.clone())
                .ok_or_else(|| "共有する写真にアクセスできません。一覧を更新してください。".into())
        })
        .collect()
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
