//! Integer geometry in the EXIF-oriented original image, shared by native and
//! remote renderers. Cropping always precedes the canonical orientation.

use serde::{Deserialize, Serialize};

mod apple;
mod draft;
mod remote;
mod targets;
mod verification;
pub use apple::{
    AdjustmentBase, AppleAdjustment, AppleEditInput, GeometryAdjustment, ImageEditPresentation,
    ImageEncodingFacts, ImageRenderPlan, RenderFormat, decode_original_adjustment,
    prepare_apple_edit, verify_edit_source,
};
pub use draft::{EditCommand, EditCommandKind, ImageEditDraft, ImageEditState};
pub use remote::read_immich_transform;
pub use targets::{EditingTarget, targets};
pub use verification::verify_edited_originals;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditDraftRequest {
    pub draft: ImageEditDraft,
    pub command: Option<EditCommand>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditingSourceCheck {
    pub expected: crate::domain::StoredAsset,
    pub fresh: crate::domain::StoredAsset,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppleEditResult {
    pub asset: crate::domain::StoredAsset,
    pub adjustment: AppleAdjustment,
    pub image: ImageEncodingFacts,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PixelSize {
    pub width: u32,
    pub height: u32,
}
impl PixelSize {
    pub fn validate(self) -> Result<(), String> {
        if !(1..=131_072).contains(&self.width)
            || !(1..=131_072).contains(&self.height)
            // The initial native encoder materializes an RGBA8 bitmap. Bound
            // input as well as output before decoding, not merely after crop.
            || u64::from(self.width) * u64::from(self.height) > 16_000_000
        {
            return Err("写真編集は現在1,600万画素以内に対応しています。".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PixelCrop {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}
impl PixelCrop {
    #[must_use]
    pub fn full(size: PixelSize) -> Self {
        Self {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height,
        }
    }
    pub fn validate(self, size: PixelSize) -> Result<(), String> {
        size.validate()?;
        if self.width == 0
            || self.height == 0
            || self
                .x
                .checked_add(self.width)
                .is_none_or(|v| v > size.width)
            || self
                .y
                .checked_add(self.height)
                .is_none_or(|v| v > size.height)
        {
            return Err("切り抜く範囲が画像の外にあります。".into());
        }
        Ok(())
    }
}

/// Apply `crop`, then clockwise quarter turns, then a horizontal mirror.
/// These eight orientations also represent arbitrary ordered quarter turns
/// and horizontal/vertical mirrors without repeated remote edit actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageTransform {
    pub crop: PixelCrop,
    pub clockwise_quarter_turns: u8,
    pub flip_horizontal: bool,
}
impl ImageTransform {
    pub fn original(size: PixelSize) -> Result<Self, String> {
        size.validate()?;
        Ok(Self {
            crop: PixelCrop::full(size),
            clockwise_quarter_turns: 0,
            flip_horizontal: false,
        })
    }
    pub fn validate(self, size: PixelSize) -> Result<(), String> {
        self.crop.validate(size)?;
        if self.clockwise_quarter_turns > 3 {
            return Err("回転は90度単位で指定してください。".into());
        }
        Ok(())
    }
    pub fn output_size(self, size: PixelSize) -> Result<PixelSize, String> {
        self.validate(size)?;
        let PixelCrop { width, height, .. } = self.crop;
        Ok(if self.clockwise_quarter_turns.is_multiple_of(2) {
            PixelSize { width, height }
        } else {
            PixelSize {
                width: height,
                height: width,
            }
        })
    }
    pub fn rotate_clockwise(mut self, size: PixelSize) -> Result<Self, String> {
        self.validate(size)?;
        // Rotation and reflection do not commute. R * H = H * inverse(R).
        self.clockwise_quarter_turns =
            (self.clockwise_quarter_turns + if self.flip_horizontal { 3 } else { 1 }) % 4;
        Ok(self)
    }
    pub fn mirror_horizontal(mut self, size: PixelSize) -> Result<Self, String> {
        self.validate(size)?;
        self.flip_horizontal = !self.flip_horizontal;
        Ok(self)
    }
    pub fn mirror_vertical(mut self, size: PixelSize) -> Result<Self, String> {
        self.validate(size)?;
        self.clockwise_quarter_turns = (self.clockwise_quarter_turns + 2) % 4;
        self.flip_horizontal = !self.flip_horizontal;
        Ok(self)
    }
    /// Map a top-left rectangle in the current rendered image back to the
    /// oriented original, retaining the exact pixel edges without rounding.
    pub fn crop_output(mut self, size: PixelSize, window: PixelCrop) -> Result<Self, String> {
        let output = self.output_size(size)?;
        window.validate(output)?;
        let right = window.x + window.width;
        let bottom = window.y + window.height;
        let mut bounds = (u32::MAX, u32::MAX, 0, 0);
        for (x, y) in [
            (window.x, window.y),
            (right, window.y),
            (window.x, bottom),
            (right, bottom),
        ] {
            let x = if self.flip_horizontal {
                output.width - x
            } else {
                x
            };
            let (x, y) = match self.clockwise_quarter_turns {
                0 => (x, y),
                1 => (y, self.crop.height - x),
                2 => (self.crop.width - x, self.crop.height - y),
                3 => (self.crop.width - y, x),
                _ => return Err("回転を確認できません。".into()),
            };
            bounds = (
                bounds.0.min(x),
                bounds.1.min(y),
                bounds.2.max(x),
                bounds.3.max(y),
            );
        }
        self.crop = PixelCrop {
            x: self.crop.x + bounds.0,
            y: self.crop.y + bounds.1,
            width: bounds.2 - bounds.0,
            height: bounds.3 - bounds.1,
        };
        self.validate(size)?;
        Ok(self)
    }
    /// Produce the canonical actions in Immich's crop-first contract. An empty
    /// result means original geometry; removal uses a separate explicit flow.
    pub fn immich_actions(self, size: PixelSize) -> Result<Vec<serde_json::Value>, String> {
        self.validate(size)?;
        let mut actions = Vec::new();
        if self.crop != PixelCrop::full(size) {
            actions.push(serde_json::json!({"action":"crop","parameters":self.crop}));
        }
        if self.clockwise_quarter_turns != 0 {
            actions.push(serde_json::json!({"action":"rotate","parameters":{
                "angle":u32::from(self.clockwise_quarter_turns) * 90
            }}));
        }
        if self.flip_horizontal {
            actions.push(serde_json::json!({"action":"mirror","parameters":{"axis":"horizontal"}}));
        }
        Ok(actions)
    }
}
