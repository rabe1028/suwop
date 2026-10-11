use std::collections::BTreeSet;

use serde::Deserialize;
use serde_json::Value;

use super::{ImageTransform, PixelCrop, PixelSize};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemoteEdits {
    asset_id: String,
    edits: Vec<RemoteEdit>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoteEdit {
    id: String,
    action: String,
    parameters: Value,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Rotation {
    angle: u16,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Mirror {
    axis: String,
}

/// Validate the entire saved edit series before replacing it. Preserve its
/// visual orientation even when rotation and mirror appear in another order.
pub fn read_immich_transform(
    size: PixelSize,
    asset_id: &str,
    response: Value,
) -> Result<ImageTransform, String> {
    crate::immich::valid_id(asset_id)?;
    let response: RemoteEdits = parameters(response)?;
    if response.asset_id != asset_id || response.edits.len() > 4 {
        return Err("編集の写真IDまたは構成を確認できません。".into());
    }
    let mut ids = BTreeSet::new();
    let mut seen = BTreeSet::new();
    let mut transform = ImageTransform::original(size)?;
    for (index, edit) in response.edits.into_iter().enumerate() {
        crate::immich::valid_id(&edit.id)?;
        if !ids.insert(edit.id) {
            return Err("編集IDが重複しています。".into());
        }
        let unique = match edit.action.as_str() {
            "crop" => {
                if index != 0 {
                    return Err("既存の切り抜きの順序を確認できません。".into());
                }
                let crop: PixelCrop = parameters(edit.parameters)?;
                transform = transform.crop_output(size, crop)?;
                "crop".into()
            }
            "rotate" => {
                let rotation: Rotation = parameters(edit.parameters)?;
                if ![0, 90, 180, 270].contains(&rotation.angle) {
                    return Err("既存の回転を確認できません。".into());
                }
                for _ in 0..rotation.angle / 90 {
                    transform = transform.rotate_clockwise(size)?;
                }
                "rotate".into()
            }
            "mirror" => {
                let mirror: Mirror = parameters(edit.parameters)?;
                transform = match mirror.axis.as_str() {
                    "horizontal" => transform.mirror_horizontal(size)?,
                    "vertical" => transform.mirror_vertical(size)?,
                    _ => return Err("既存の反転を確認できません。".into()),
                };
                format!("mirror-{}", mirror.axis)
            }
            _ => return Err("この既存の編集には対応していません。".into()),
        };
        if !seen.insert(unique) {
            return Err("既存の編集が重複しています。".into());
        }
    }
    transform.validate(size)?;
    Ok(transform)
}

fn parameters<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|_| "既存の編集データを確認できません。".into())
}
