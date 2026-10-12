use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ImageColorFilter {
    #[default]
    Original,
    Mono,
    Noir,
    Sepia,
}

/// Integer controls keep saved edits and undo history exact. Exposure is in
/// hundredths of a stop; the other controls use -100..100 with zero neutral.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ColorAdjustments {
    pub exposure: i16,
    pub brightness: i16,
    pub contrast: i16,
    pub saturation: i16,
    pub filter: ImageColorFilter,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeColorPlan {
    pub exposure_ev: f64,
    pub brightness: f64,
    pub contrast: f64,
    pub saturation: f64,
    pub filter: ImageColorFilter,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ColorControlKind {
    Exposure,
    Brightness,
    Contrast,
    Saturation,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ColorControlSpec {
    pub kind: ColorControlKind,
    pub minimum: i16,
    pub maximum: i16,
}

#[must_use]
pub fn controls() -> Vec<ColorControlSpec> {
    [
        (ColorControlKind::Exposure, 200),
        (ColorControlKind::Brightness, 100),
        (ColorControlKind::Contrast, 100),
        (ColorControlKind::Saturation, 100),
    ]
    .into_iter()
    .map(|(kind, maximum)| ColorControlSpec {
        kind,
        minimum: -maximum,
        maximum,
    })
    .collect()
}

impl ColorAdjustments {
    pub fn validate(self) -> Result<(), String> {
        if !(-200..=200).contains(&self.exposure)
            || [self.brightness, self.contrast, self.saturation]
                .iter()
                .any(|value| !(-100..=100).contains(value))
        {
            return Err("明るさ・色の調整値が範囲外です。".into());
        }
        Ok(())
    }

    pub fn native_plan(self) -> Result<NativeColorPlan, String> {
        self.validate()?;
        Ok(NativeColorPlan {
            exposure_ev: f64::from(self.exposure) / 100.0,
            brightness: f64::from(self.brightness) / 100.0,
            contrast: 1.0 + f64::from(self.contrast) / 100.0,
            saturation: 1.0 + f64::from(self.saturation) / 100.0,
            filter: self.filter,
        })
    }
}
