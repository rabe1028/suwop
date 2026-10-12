use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

use crate::{
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, UnifiedPhoto, hex},
    immich::Session,
};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PreviewChoice {
    pub key: AssetKey,
    pub name: String,
    pub captured_at: Option<f64>,
    pub modified_at: Option<f64>,
    pub cache_id: String,
    pub selected: bool,
    pub disabled_reason: Option<String>,
}

/// A preview is a read, so limited access and cached previews of incomplete or
/// offline originals are allowed. Scope and current snapshot membership still
/// have to match; an explicit unavailable choice never silently falls back.
#[derive(Debug)]
pub struct PreviewAccess<'a> {
    assets: BTreeMap<&'a AssetKey, &'a StoredAsset>,
    remote_version: Option<String>,
}
impl<'a> PreviewAccess<'a> {
    /// Build membership once per catalog view, avoiding a full library scan for
    /// every tile. Ambiguous snapshots/IDs cannot authorize a preview source.
    #[must_use]
    pub fn new(
        snapshots: &'a [LibrarySnapshot],
        apple_scope: &str,
        session: Option<&Session>,
    ) -> Self {
        let mut assets = BTreeMap::new();
        let mut duplicates = BTreeSet::new();
        for snapshot in snapshots {
            let current = match snapshot.provider {
                Provider::Apple => snapshot.scope == apple_scope,
                Provider::Immich => session.is_some_and(|s| s.scope == snapshot.scope),
            };
            if !current
                || snapshot.access == ScanAccess::Unavailable
                || snapshots
                    .iter()
                    .filter(|s| s.provider == snapshot.provider && s.scope == snapshot.scope)
                    .count()
                    != 1
            {
                continue;
            }
            for asset in &snapshot.assets {
                if asset.key.provider == snapshot.provider
                    && asset.key.scope == snapshot.scope
                    && assets.insert(&asset.key, asset).is_some()
                {
                    duplicates.insert(&asset.key);
                }
            }
        }
        assets.retain(|key, _| !duplicates.contains(key));
        Self {
            assets,
            remote_version: session.map(|s| s.version.description()),
        }
    }

    fn available(&self, asset: &StoredAsset) -> bool {
        self.assets.get(&asset.key).is_some_and(|a| **a == *asset)
    }

    #[must_use]
    pub fn choices(&self, photo: &UnifiedPhoto, preferences: &[AssetKey]) -> Vec<PreviewChoice> {
        let selected = preferences
            .iter()
            .rev()
            .find(|key| photo.assets.iter().any(|a| a.key == **key))
            .cloned()
            .or_else(|| {
                photo
                    .assets
                    .iter()
                    .filter(|a| self.available(a))
                    .min_by_key(|a| {
                        (
                            std::cmp::Reverse(a.originals().count()),
                            a.key.provider != Provider::Apple,
                        )
                    })
                    .map(|a| a.key.clone())
            });
        photo
        .assets
        .iter()
        .map(|a| {
            let available = self.available(a);
            let version = if a.key.provider == Provider::Immich { self.remote_version.as_deref() } else { None };
            let identity = serde_json::json!([a.key, a.revision, a.resources, version, available]).to_string();
            PreviewChoice {
                key: a.key.clone(),
                name: a.name.clone(),
                captured_at: a.captured_at,
                modified_at: a.modified_at,
                cache_id: hex(&Sha256::digest(identity.as_bytes())),
                selected: selected.as_ref() == Some(&a.key),
                disabled_reason: (!available).then(|| {
                    "この保存先へアクセスできません。接続と権限を確認して一覧を更新してください。".into()
                }),
            }
        })
        .collect()
    }
}

#[must_use]
pub fn selected_preview(choices: &[PreviewChoice]) -> Option<AssetKey> {
    choices
        .iter()
        .find(|choice| choice.selected && choice.disabled_reason.is_none())
        .map(|choice| choice.key.clone())
}

/// Preferences follow the physical stored photo through catalog regrouping.
/// A later merge of two groups uses the most recently selected member.
pub(crate) fn remember_preview(
    preferences: &mut Vec<AssetKey>,
    photo: &UnifiedPhoto,
    key: AssetKey,
) {
    preferences.retain(|old| !photo.assets.iter().any(|a| a.key == *old));
    preferences.push(key);
}
