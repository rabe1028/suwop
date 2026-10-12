use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};

use crate::domain::{Provider, ResourceRole, StoredAsset};

use super::{ImageEditDraft, ImageTransform, PixelSize};

const IDENTIFIER: &str = "jp.rabe1028.suwop.image-geometry";
const VERSION: &str = "2";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum AdjustmentBase {
    Original,
    Rendered,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppleAdjustment {
    pub format_identifier: String,
    pub format_version: String,
    pub data: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GeometryAdjustment {
    pub dimensions: PixelSize,
    pub base: AdjustmentBase,
    pub transform: ImageTransform,
}
impl GeometryAdjustment {
    pub fn encode(&self) -> Result<AppleAdjustment, String> {
        self.transform.validate(self.dimensions)?;
        let bytes = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        Ok(AppleAdjustment {
            format_identifier: IDENTIFIER.into(),
            format_version: VERSION.into(),
            data: STANDARD.encode(bytes),
        })
    }
}
/// Only known original-based adjustments can be reconstructed from originals.
/// A rendered foreign base must follow the native cannot-handle path instead.
#[must_use]
pub fn decode_original_adjustment(payload: &AppleAdjustment) -> Option<GeometryAdjustment> {
    if payload.format_identifier != IDENTIFIER
        || !["1", VERSION].contains(&payload.format_version.as_str())
        || payload.data.len() > 32_768
    {
        return None;
    }
    let bytes = STANDARD.decode(&payload.data).ok()?;
    let adjustment: GeometryAdjustment = serde_json::from_slice(&bytes).ok()?;
    // Version 1 never supported color. A payload claiming v1 with color data
    // must not be silently accepted by an older geometry-only implementation.
    if payload.format_version == "1"
        && adjustment.transform.color != super::ColorAdjustments::default()
    {
        return None;
    }
    (adjustment.base == AdjustmentBase::Original
        && adjustment.transform.validate(adjustment.dimensions).is_ok())
    .then_some(adjustment)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum RenderFormat {
    Jpeg,
    Heic,
}
impl RenderFormat {
    #[must_use]
    pub fn identifier(self) -> &'static str {
        match self {
            Self::Jpeg => "public.jpeg",
            Self::Heic => "public.heic",
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageEncodingFacts {
    pub raw_dimensions: PixelSize,
    pub orientation: u8,
    pub has_color_space: bool,
    pub has_alpha: bool,
    pub hdr: bool,
}
impl ImageEncodingFacts {
    pub fn oriented_size(&self) -> Result<PixelSize, String> {
        self.raw_dimensions.validate()?;
        match self.orientation {
            1..=4 => Ok(self.raw_dimensions),
            5..=8 => Ok(PixelSize {
                width: self.raw_dimensions.height,
                height: self.raw_dimensions.width,
            }),
            _ => Err("写真の向きを確認できません。".into()),
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppleEditInput {
    pub asset: StoredAsset,
    pub token: String,
    pub path: String,
    pub image: ImageEncodingFacts,
    pub can_edit: bool,
    pub has_adjustments: bool,
    pub adjustment: Option<AppleAdjustment>,
    pub supported_formats: Vec<String>,
    pub default_format: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageEditPresentation {
    pub name: String,
    pub path: String,
    pub orientation: u8,
    pub draft: ImageEditDraft,
    pub base: AdjustmentBase,
    pub output_format: RenderFormat,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageRenderPlan {
    pub dimensions: PixelSize,
    pub orientation: u8,
    pub transform: ImageTransform,
    pub output_format: RenderFormat,
    pub adjustment: AppleAdjustment,
}
impl ImageEditPresentation {
    pub fn save_plan(&self, returned: &ImageEditDraft) -> Result<ImageRenderPlan, String> {
        if returned.dimensions != self.draft.dimensions || returned.initial != self.draft.initial {
            return Err("編集を開始した写真と一致しません。".into());
        }
        if !returned.can_save()? {
            return Err("編集内容を変更してから保存してください。".into());
        }
        let transform = returned.current()?;
        let adjustment = GeometryAdjustment {
            dimensions: returned.dimensions,
            base: self.base,
            transform,
        }
        .encode()?;
        Ok(ImageRenderPlan {
            dimensions: returned.dimensions,
            orientation: self.orientation,
            transform,
            output_format: self.output_format,
            adjustment,
        })
    }
}

pub fn verify_edit_source(expected: &StoredAsset, fresh: &StoredAsset) -> Result<(), String> {
    if expected.key != fresh.key
        || expected.revision != fresh.revision
        || expected.captured_at != fresh.captured_at
        || expected.is_favorite != fresh.is_favorite
        || expected.modified_at != fresh.modified_at
        || expected.latitude != fresh.latitude
        || expected.longitude != fresh.longitude
        || !fresh.inventory_complete
        || fresh.is_offline
        || !expected.inventory_complete
        || expected.is_offline
        || expected.originals().next().is_none()
        || original_manifest(expected) != original_manifest(fresh)
    {
        return Err("編集する写真が変わっています。一覧を更新してください。".into());
    }
    Ok(())
}

fn original_manifest(asset: &StoredAsset) -> Vec<(&str, &str, ResourceRole)> {
    asset
        .originals()
        .map(|r| (r.id.as_str(), r.name.as_str(), r.role))
        .collect()
}

pub fn prepare_apple_edit(
    expected: &StoredAsset,
    input: &AppleEditInput,
    directory: &str,
) -> Result<ImageEditPresentation, String> {
    if expected.key.provider != Provider::Apple {
        return Err("Apple Photos の写真を選択してください。".into());
    }
    if expected
        .originals()
        .any(|r| matches!(r.role, ResourceRole::Video | ResourceRole::LiveVideo))
    {
        return Err("動画とLive Photoの編集は準備中です。".into());
    }
    verify_edit_source(expected, &input.asset)?;
    crate::immich::valid_id(&input.token)?;
    if !crate::sharing::contains_file(directory, &input.path) || !input.can_edit {
        return Err("この写真の編集データを読み込めません。".into());
    }
    if input.image.hdr || input.image.has_alpha || !input.image.has_color_space {
        return Err("この写真の色・HDR・透過を保つ編集にはまだ対応していません。".into());
    }
    let dimensions = input.image.oriented_size()?;
    let (initial, base) = match &input.adjustment {
        Some(payload) => {
            let adjustment = decode_original_adjustment(payload)
                .ok_or("既存の編集を原本から再現できません。")?;
            if adjustment.dimensions != dimensions || !input.has_adjustments {
                return Err("既存の編集と写真の大きさが一致しません。".into());
            }
            (adjustment.transform, AdjustmentBase::Original)
        }
        None => (
            ImageTransform::original(dimensions)?,
            if input.has_adjustments {
                AdjustmentBase::Rendered
            } else {
                AdjustmentBase::Original
            },
        ),
    };
    let output_format = [RenderFormat::Jpeg, RenderFormat::Heic]
        .into_iter()
        .filter(|f| input.supported_formats.iter().any(|s| s == f.identifier()))
        .min_by_key(|f| input.default_format.as_deref() != Some(f.identifier()))
        .ok_or("この写真の保存形式には対応していません。")?;
    Ok(ImageEditPresentation {
        name: expected.name.clone(),
        path: input.path.clone(),
        orientation: input.image.orientation,
        draft: ImageEditDraft::new(dimensions, initial)?,
        base,
        output_format,
    })
}
