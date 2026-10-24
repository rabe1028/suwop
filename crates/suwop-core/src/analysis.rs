//! Rebuildable model-specific analysis policy. Never authorizes original deletion.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisModel {
    pub name: String,
    pub version: String,
    pub preprocessing: String,
    pub rendition: String,
    pub dimensions: u32,
}
impl AnalysisModel {
    pub fn validate(&self) -> Result<(), String> {
        for value in [
            &self.name,
            &self.version,
            &self.preprocessing,
            &self.rendition,
        ] {
            if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
                return Err("Invalid analysis model identity".into());
            }
        }
        if !(1..=4096).contains(&self.dimensions) {
            return Err("Embedding dimensions must be 1..4096".into());
        }
        Ok(())
    }
}

/// Managed working-set admission budget, not an OS/process RSS guarantee.
/// Includes caches, bounded vectors and a conservative native-engine reserve.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisBudget {
    pub working_bytes: u64,
    pub cache_bytes: u64,
    pub max_batch_rows: u32,
}
impl Default for AnalysisBudget {
    fn default() -> Self {
        Self {
            working_bytes: 128 << 20,
            cache_bytes: 8 << 20,
            max_batch_rows: 512,
        }
    }
}
impl AnalysisBudget {
    pub fn rows(&self, dimensions: u32) -> Result<usize, String> {
        if !(1..=4096).contains(&dimensions)
            || !(1..=512).contains(&self.max_batch_rows)
            || !(64 << 20..=512 << 20).contains(&self.working_bytes)
            || !(1 << 20..=16 << 20).contains(&self.cache_bytes)
        {
            return Err("Invalid analysis memory budget".into());
        }
        // Two caches, 32 MiB engine reserve, 16 copies/temporaries per row.
        let available = self
            .working_bytes
            .checked_sub(2 * self.cache_bytes + (32 << 20))
            .ok_or("Budget cannot admit the engine and caches")?;
        let rows = available / (u64::from(dimensions) * 4 * 16 + 4096);
        usize::try_from(rows.min(u64::from(self.max_batch_rows)))
            .map_err(|e| e.to_string())
            .and_then(|rows| {
                if rows == 0 {
                    Err("Budget cannot admit one vector".into())
                } else {
                    Ok(rows)
                }
            })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EmbeddingInput {
    pub job_id: String,
    pub vector: Vec<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EmbeddingJob {
    pub id: String,
    pub model_key: String,
    pub generation: i64,
    pub model: AnalysisModel,
    pub asset: crate::domain::StoredAsset,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisStatus {
    pub model_key: String,
    pub model: AnalysisModel,
    pub generation: i64,
    pub active_generation: Option<i64>,
    pub state: String,
    pub awaiting_embeddings: u64,
    pub queued_vectors: u64,
    pub indexed: u64,
    pub skipped: u64,
    pub budget: AnalysisBudget,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SimilarityHit {
    pub asset: crate::domain::AssetKey,
    pub revision: String,
    pub distance: f32,
}

/// Analysis uses the same privacy boundary as ordinary browsing. Amazon Photos
/// has no native embedding image source yet; its assets are never queued, so
/// they cannot pause an analysis run.
pub fn visible_assets(
    state: &crate::app::SavedLibrary,
) -> impl Iterator<Item = &crate::domain::StoredAsset> {
    let access = crate::privacy::ContentAccess::new(state);
    state
        .snapshots
        .iter()
        .filter(|snapshot| snapshot.provider != crate::domain::Provider::Amazon)
        .filter(|snapshot| snapshot.access != crate::domain::ScanAccess::Unavailable)
        .flat_map(|snapshot| &snapshot.assets)
        .filter(move |asset| access.visible(&asset.key))
}

/// Complete, fresh inventories can retire derived revisions. Missing/limited
/// sources cannot. This policy never authorizes deletion of original media.
#[derive(Debug)]
pub struct AnalysisPresence<'a> {
    scopes: std::collections::BTreeSet<(crate::domain::Provider, &'a str)>,
    revisions: std::collections::BTreeMap<&'a crate::domain::AssetKey, &'a str>,
}
impl<'a> AnalysisPresence<'a> {
    #[must_use]
    pub fn new(state: &'a crate::app::SavedLibrary) -> Self {
        use std::collections::{BTreeMap, BTreeSet};
        let mut snapshots = BTreeMap::new();
        for snapshot in &state.snapshots {
            snapshots
                .entry((snapshot.provider, snapshot.scope.as_str()))
                .and_modify(|value| *value = None)
                .or_insert(Some(snapshot));
        }
        let mut result = Self {
            scopes: BTreeSet::new(),
            revisions: BTreeMap::new(),
        };
        for (scope, snapshot) in snapshots {
            let Some(snapshot) = snapshot else { continue };
            let mut keys = BTreeSet::new();
            if snapshot.access != crate::domain::ScanAccess::Full
                || snapshot.scanned_at.is_none()
                || snapshot.assets.iter().any(|asset| {
                    (asset.key.provider, asset.key.scope.as_str()) != scope
                        || !keys.insert(&asset.key)
                })
            {
                continue;
            }
            result.scopes.insert(scope);
            result.revisions.extend(
                snapshot
                    .assets
                    .iter()
                    .map(|asset| (&asset.key, asset.revision.as_str())),
            );
        }
        result
    }

    #[must_use]
    pub fn confirms_removed_revision(&self, key: &crate::domain::AssetKey, revision: &str) -> bool {
        self.scopes.contains(&(key.provider, key.scope.as_str()))
            && self.revisions.get(key).copied() != Some(revision)
    }
}
