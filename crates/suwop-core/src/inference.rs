//! Local inference admission, model identity and bounded query projection.
use crate::analysis::AnalysisModel;
use serde::{Deserialize, Serialize};

pub const MODEL_SHA256: &str = "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0";
pub const MODEL_BYTES: u64 = 387_710_976;
pub const MODEL_FILE: &str = "embeddinggemma-2-text-vision-440m.litertlm";
pub const MODEL_URL: &str = "https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m.litertlm";

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InferenceStatus {
    pub model_key: String,
    pub state: String,
    pub budget_bytes: u64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InferenceSpec {
    pub model: AnalysisModel,
    pub url: String,
    pub filename: String,
    pub sha256: String,
    pub bytes: u64,
    pub image_edge: u32,
    pub image_tokens: u32,
    pub text_tokens: u32,
    pub threads: u32,
}

pub fn specification(dimensions: u32) -> Result<InferenceSpec, String> {
    if ![256, 512].contains(&dimensions) {
        return Err("Choose 256 or 512 dimensions".into());
    }
    Ok(InferenceSpec {
        model: AnalysisModel {
            name: "embeddinggemma-2-text-vision-440m".into(),
            version: MODEL_SHA256.into(),
            preprocessing:
                "litert-lm-0.18.0/cpu2/vision70/text128/current-preview-fit448/jpeg90/mrl-l2-v1"
                    .into(),
            rendition: "current-preview".into(),
            dimensions,
        },
        url: MODEL_URL.into(),
        filename: MODEL_FILE.into(),
        sha256: MODEL_SHA256.into(),
        bytes: MODEL_BYTES,
        image_edge: 448,
        image_tokens: 70,
        text_tokens: 128,
        threads: 2,
    })
}

pub fn validate_budget(bytes: u64) -> Result<(), String> {
    if !(768 << 20..=2048 << 20).contains(&bytes) {
        return Err("Inference budget must be 768–2048 MiB".into());
    }
    Ok(())
}

/// Admission and checkpoint monitoring are not an allocator or OS hard RSS limit.
pub fn admit(
    budget: u64,
    resident: u64,
    available: u64,
    loaded: bool,
    pressure: bool,
) -> Result<(), String> {
    validate_budget(budget)?;
    let reserve = if loaded { 64 << 20 } else { 768 << 20 };
    if pressure
        || resident
            .checked_add(reserve)
            .is_none_or(|bytes| bytes > budget)
        || available < reserve
    {
        return Err(
            "Memory budget or system pressure stopped inference; completed photos are retained"
                .into(),
        );
    }
    Ok(())
}

pub fn query(text: &str) -> Result<String, String> {
    let text = text.trim();
    if text.is_empty() || text.len() > 384 || text.chars().any(char::is_control) {
        return Err("Use a nonempty search query of at most 384 UTF-8 bytes".into());
    }
    Ok(format!("task: search query | text: {text}"))
}

pub fn project(vector: &[f32], dimensions: u32) -> Result<Vec<f32>, String> {
    specification(dimensions)?;
    if vector.len() != 768 || vector.iter().any(|value| !value.is_finite()) {
        return Err("Expected a finite 768-dimensional embedding".into());
    }
    let selected = &vector[..dimensions as usize];
    let norm = selected
        .iter()
        .map(|value| f64::from(*value).powi(2))
        .sum::<f64>()
        .sqrt();
    if norm == 0.0 {
        return Err("Embedding has zero norm".into());
    }
    #[allow(clippy::cast_possible_truncation)] // Normalized finite components are in [-1, 1].
    Ok(selected
        .iter()
        .map(|value| (f64::from(*value) / norm) as f32)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn budget_covers_startup_pressure_and_loaded_checkpoints() {
        assert!(admit(1024 << 20, 200 << 20, 1024 << 20, false, false).is_ok());
        assert!(admit(1024 << 20, 300 << 20, 1024 << 20, false, false).is_err());
        assert!(admit(1024 << 20, 970 << 20, 1024 << 20, true, false).is_err());
        assert!(admit(1024 << 20, 200 << 20, 1024 << 20, true, true).is_err());
        assert!(admit(1024 << 20, 200 << 20, 32 << 20, true, false).is_err());
    }
    #[test]
    fn projection_renormalizes_each_dimension_space() -> Result<(), String> {
        let full = vec![1.0; 768];
        for dimensions in [256, 512] {
            let vector = project(&full, dimensions)?;
            assert_eq!(vector.len(), dimensions as usize);
            assert!((vector.iter().map(|v| v * v).sum::<f32>() - 1.0).abs() < 0.0001);
        }
        assert!(project(&[f32::NAN; 768], 256).is_err());
        assert!(project(&[0.0; 768], 256).is_err());
        assert_ne!(specification(256)?.model, specification(512)?.model);
        Ok(())
    }
}
