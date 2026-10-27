use chrono::Datelike;
use serde::{Deserialize, Serialize};

use crate::{
    domain::StoredAsset,
    editing::{ImageEncodingFacts, ImageTransform, PixelSize, read_immich_transform},
};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentImageMetadata {
    pub date_time_original: Option<String>,
    pub subsec_time_original: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentImageRenderPlan {
    pub dimensions: PixelSize,
    pub orientation: u8,
    pub transform: ImageTransform,
    pub metadata: CurrentImageMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentImageRenderResult {
    pub image: super::CurrentImageFacts,
    pub metadata: CurrentImageMetadata,
}

impl CurrentImageRenderPlan {
    /// Re-encode pixels into a fresh PNG with an explicit metadata allowlist.
    /// Do not copy EXIF/XMP/maker notes that may contain another location field.
    pub fn without_location(
        source: &StoredAsset,
        image: &ImageEncodingFacts,
    ) -> Result<Self, String> {
        let dimensions = image.oriented_size()?;
        if image.hdr || !image.has_color_space {
            return Err("このHDR画像・色空間の位置情報なし書き出しには未対応です。".into());
        }
        let mut metadata = metadata(source)?;
        metadata.latitude = None;
        metadata.longitude = None;
        Ok(Self {
            dimensions,
            orientation: image.orientation,
            transform: ImageTransform::original(dimensions)?,
            metadata,
        })
    }

    pub fn remote(
        source: &StoredAsset,
        image: &ImageEncodingFacts,
        edits: serde_json::Value,
    ) -> Result<Self, String> {
        let dimensions = image.oriented_size()?;
        if image.hdr || !image.has_color_space {
            return Err("このHDR画像・色空間の現在の書き出しには未対応です。".into());
        }
        if edits["edits"].as_array().is_none_or(Vec::is_empty) {
            return Err("現在の編集系列を確認できません。".into());
        }
        let transform = read_immich_transform(dimensions, &source.key.asset_id, edits)?;
        Ok(Self {
            dimensions,
            orientation: image.orientation,
            transform,
            metadata: metadata(source)?,
        })
    }

    pub fn verify(&self, result: &CurrentImageRenderResult) -> Result<(), String> {
        let size = self.transform.output_size(self.dimensions)?;
        if result.image.content_type != "public.png"
            || result.image.width != size.width
            || result.image.height != size.height
            || result.image.orientation != 1
            || result.image.frames != 1
            || self.metadata.date_time_original != result.metadata.date_time_original
            || self.metadata.subsec_time_original != result.metadata.subsec_time_original
            || !same_coordinate(self.metadata.latitude, result.metadata.latitude)
            || !same_coordinate(self.metadata.longitude, result.metadata.longitude)
        {
            return Err("現在の編集結果または撮影日時・位置の書き出しを確認できません。".into());
        }
        Ok(())
    }
}

fn same_coordinate(expected: Option<f64>, actual: Option<f64>) -> bool {
    match (expected, actual) {
        (None, None) => true,
        (Some(a), Some(b)) => a.is_finite() && b.is_finite() && (a - b).abs() <= 0.000_001,
        _ => false,
    }
}

fn metadata(source: &StoredAsset) -> Result<CurrentImageMetadata, String> {
    let date = source
        .captured_at
        .map(|seconds| {
            chrono::DateTime::parse_from_rfc3339(&crate::immich::date_string(seconds))
                .map_err(|_| "書き出す撮影日時を確認できません。".to_owned())
        })
        .transpose()?;
    if date
        .as_ref()
        .is_some_and(|d| !(1..=9999).contains(&d.year()))
    {
        return Err("書き出す撮影日時の範囲に対応していません。".into());
    }
    match (source.latitude, source.longitude) {
        (None, None) => {}
        (Some(lat), Some(lon))
            if lat.is_finite()
                && lon.is_finite()
                && (-90.0..=90.0).contains(&lat)
                && (-180.0..=180.0).contains(&lon) => {}
        _ => return Err("書き出す位置情報を確認できません。".into()),
    }
    Ok(CurrentImageMetadata {
        date_time_original: date
            .as_ref()
            .map(|d| d.format("%Y:%m:%d %H:%M:%S").to_string()),
        subsec_time_original: date.as_ref().and_then(|d| {
            let fraction = d.format("%f").to_string();
            let fraction = fraction.trim_end_matches('0');
            (!fraction.is_empty()).then(|| fraction.to_owned())
        }),
        latitude: source.latitude,
        longitude: source.longitude,
    })
}
