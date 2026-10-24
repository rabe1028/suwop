//! Local inference admission, model identity, tokenization and bounded query projection.
use crate::analysis::AnalysisModel;
use serde::{Deserialize, Serialize};

/// Identity of the bundled Core ML models produced by `make coreml-models`
/// (`scripts/coreml/convert.py` verifies its output against this value).
pub const COREML_MODEL_SHA256: &str =
    "333a3a9037bc45895820324b4593f66aff2060e3f2f160d7c1f6ed8ca8a6f7e9";
/// App bundle folder holding the compiled `.mlmodelc` directories.
pub const COREML_MODEL_DIRECTORY: &str = "EmbeddingGemma2";
const BOS: u32 = 2;
const EOS: u32 = 1;
const IMAGE_START: u32 = 255_999;
const IMAGE_SOFT_TOKEN: u32 = 258_880;
const IMAGE_END: u32 = 258_882;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InferenceSelection {
    pub model: AnalysisModel,
    pub analysis: Option<crate::analysis::AnalysisStatus>,
    pub inference: Option<InferenceStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InferenceStatus {
    pub model_key: String,
    pub failed_job: Option<String>,
    pub state: String,
    pub budget_bytes: u64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InferenceSpec {
    pub model: AnalysisModel,
    pub model_directory: String,
    /// Preview edge requested from photo sources before patch preparation.
    pub image_edge: u32,
    pub max_patches: u32,
    pub patch_size: u32,
    pub pooling_kernel: u32,
    pub image_tokens: u32,
    pub text_tokens: u32,
}

pub fn specification(dimensions: u32) -> Result<InferenceSpec, String> {
    if ![256, 512].contains(&dimensions) {
        return Err("Choose 256 or 512 dimensions".into());
    }
    Ok(InferenceSpec {
        model: AnalysisModel {
            name: "embeddinggemma-2-text-vision-440m".into(),
            version: COREML_MODEL_SHA256.into(),
            preprocessing:
                "coreml-int8-ane/vision70-patch16-pool3-bicubic/text128/current-preview-fit448/mrl-l2-v1"
                    .into(),
            rendition: "current-preview".into(),
            dimensions,
        },
        model_directory: COREML_MODEL_DIRECTORY.into(),
        image_edge: 448,
        max_patches: 630,
        patch_size: 16,
        pooling_kernel: 3,
        image_tokens: 70,
        text_tokens: 128,
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

/// Token IDs for a search query, including `<bos>`/`<eos>`; never truncated.
pub fn query_tokens(text: &str) -> Result<Vec<u32>, String> {
    let tokens = crate::tokenizer::encode(&query(text)?)?;
    if tokens.len() > 128 {
        return Err("検索語が長すぎます。短くしてください。".into());
    }
    Ok(tokens)
}

/// Token IDs for one image with `soft_tokens` vision embeddings in place of placeholders.
pub fn image_tokens(soft_tokens: u32) -> Result<Vec<u32>, String> {
    if !(1..=70).contains(&soft_tokens) {
        return Err("Unexpected image token count".into());
    }
    let mut tokens = vec![BOS, IMAGE_START];
    tokens.extend(std::iter::repeat_n(IMAGE_SOFT_TOKEN, soft_tokens as usize));
    tokens.extend([IMAGE_END, EOS]);
    Ok(tokens)
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
    #[test]
    fn token_sequences_match_the_converted_encoder_inputs() -> Result<(), String> {
        // Captured from transformers' EmbeddingGemma2Processor for the same inputs.
        assert_eq!(
            query_tokens("a dog")?,
            [
                2, 8071, 236_787, 3927, 7609, 1109, 1816, 236_787, 496, 4799, 1
            ]
        );
        let image = image_tokens(56)?;
        assert_eq!(image.len(), 60);
        assert_eq!(image[..2], [2, 255_999]);
        assert_eq!(image[58..], [258_882, 1]);
        assert!(image[2..58].iter().all(|id| *id == 258_880));
        assert!(image_tokens(0).is_err() && image_tokens(71).is_err());
        assert!(query_tokens(&"写".repeat(128)).is_err());
        Ok(())
    }
}
