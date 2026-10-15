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

/// Analysis uses the same privacy boundary as ordinary browsing.
pub fn visible_assets(
    state: &crate::app::SavedLibrary,
) -> impl Iterator<Item = &crate::domain::StoredAsset> {
    let access = crate::privacy::ContentAccess::new(state);
    state
        .snapshots
        .iter()
        .filter(|snapshot| snapshot.access != crate::domain::ScanAccess::Unavailable)
        .flat_map(|snapshot| &snapshot.assets)
        .filter(move |asset| access.visible(&asset.key))
}
