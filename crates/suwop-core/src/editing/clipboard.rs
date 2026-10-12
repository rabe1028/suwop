use serde::{Deserialize, Serialize};

use super::{
    AdjustmentBase, AppleAdjustment, ImageEditPresentation, ImageRenderPlan, ImageTransform,
    PixelCrop, PixelSize,
};
use crate::domain::{AssetKey, TransferBundle};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditCopyOptions {
    pub adjustments: bool,
    pub filter: bool,
    pub geometry: bool,
}
impl EditCopyOptions {
    pub fn validate(self) -> Result<(), String> {
        if !self.adjustments && !self.filter && !self.geometry {
            return Err("コピーする編集項目を選んでください。".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditClipboard {
    pub source_name: String,
    pub dimensions: PixelSize,
    pub transform: ImageTransform,
    pub options: EditCopyOptions,
}
impl EditClipboard {
    pub fn capture(
        source: &ImageEditPresentation,
        options: EditCopyOptions,
    ) -> Result<Self, String> {
        options.validate()?;
        if source.base != AdjustmentBase::Original
            || source.draft.initial == ImageTransform::original(source.draft.dimensions)?
        {
            return Err("Suwopで保存した編集がある写真を選んでください。".into());
        }
        Ok(Self {
            source_name: source.name.clone(),
            dimensions: source.draft.dimensions,
            transform: source.draft.current()?,
            options,
        })
    }

    pub fn plan(&self, target: &ImageEditPresentation) -> Result<Option<ImageRenderPlan>, String> {
        self.options.validate()?;
        self.transform.validate(self.dimensions)?;
        if target.base != AdjustmentBase::Original {
            return Err(
                "他のアプリの編集を保持して貼り付けることができません。対象から外してください。"
                    .into(),
            );
        }
        let size = target.draft.dimensions;
        let mut transform = target.draft.current()?;
        if self.options.adjustments {
            let filter = transform.color.filter;
            transform.color = self.transform.color;
            transform.color.filter = filter;
        }
        if self.options.filter {
            transform.color.filter = self.transform.color.filter;
        }
        if self.options.geometry {
            transform.crop = scaled_crop(self.transform.crop, self.dimensions, size)?;
            transform.clockwise_quarter_turns = self.transform.clockwise_quarter_turns;
            transform.flip_horizontal = self.transform.flip_horizontal;
        }
        transform.validate(size)?;
        if transform == target.draft.initial {
            return Ok(None);
        }
        let mut draft = target.draft.clone();
        draft.history.push(transform);
        draft.cursor = draft.history.len() - 1;
        target.save_plan(&draft).map(Some)
    }
}

fn scaled_crop(crop: PixelCrop, source: PixelSize, target: PixelSize) -> Result<PixelCrop, String> {
    crop.validate(source)?;
    target.validate()?;
    let scale = |value: u32, from: u32, to: u32, ceil: bool| {
        let numerator = u64::from(value) * u64::from(to);
        let denominator = u64::from(from);
        let value = if ceil {
            numerator.div_ceil(denominator)
        } else {
            numerator / denominator
        };
        u32::try_from(value).map_err(|_| "切り抜きの範囲を確認できません。".to_owned())
    };
    let x = scale(crop.x, source.width, target.width, false)?;
    let y = scale(crop.y, source.height, target.height, false)?;
    let right = scale(crop.x + crop.width, source.width, target.width, true)?;
    let bottom = scale(crop.y + crop.height, source.height, target.height, true)?;
    let result = PixelCrop {
        x,
        y,
        width: right - x,
        height: bottom - y,
    };
    result.validate(target)?;
    Ok(result)
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PasteEditsPrompt {
    pub source_name: String,
    pub names: Vec<String>,
    pub options: EditCopyOptions,
    pub unchanged_count: usize,
}

/// Persisted before each `PhotoKit` write. File paths are cleared; only immutable
/// original signatures and metadata are used for read-only reconciliation.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PendingEditPaste {
    pub key: AssetKey,
    pub name: String,
    pub before: TransferBundle,
    pub initial_adjustment: Option<AppleAdjustment>,
    pub plan: ImageRenderPlan,
}
