use serde::{Deserialize, Serialize};

use super::{ImageTransform, PixelCrop, PixelSize};

const HISTORY_LIMIT: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum EditCommandKind {
    RotateClockwise,
    MirrorHorizontal,
    MirrorVertical,
    Crop,
    Undo,
    Redo,
    ResetDraft,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditCommand {
    pub kind: EditCommandKind,
    pub crop: Option<PixelCrop>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageEditDraft {
    pub dimensions: PixelSize,
    pub initial: ImageTransform,
    pub history: Vec<ImageTransform>,
    pub cursor: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageEditState {
    pub draft: ImageEditDraft,
    pub transform: ImageTransform,
    pub output_size: PixelSize,
    pub can_undo: bool,
    pub can_redo: bool,
    pub can_save: bool,
}
impl ImageEditDraft {
    pub fn view(&self) -> Result<ImageEditState, String> {
        let transform = self.current()?;
        Ok(ImageEditState {
            draft: self.clone(),
            transform,
            output_size: transform.output_size(self.dimensions)?,
            can_undo: self.cursor > 0,
            can_redo: self.cursor + 1 < self.history.len(),
            can_save: transform != self.initial,
        })
    }
    pub fn new(dimensions: PixelSize, initial: ImageTransform) -> Result<Self, String> {
        initial.validate(dimensions)?;
        Ok(Self {
            dimensions,
            initial,
            history: vec![initial],
            cursor: 0,
        })
    }
    pub fn validate(&self) -> Result<(), String> {
        self.initial.validate(self.dimensions)?;
        if self.history.is_empty()
            || self.history.len() > HISTORY_LIMIT
            || self.cursor >= self.history.len()
            || self.history[0] != self.initial
        {
            return Err("編集の履歴を確認できません。".into());
        }
        for step in &self.history {
            step.validate(self.dimensions)?;
        }
        Ok(())
    }
    pub fn current(&self) -> Result<ImageTransform, String> {
        self.validate()?;
        self.history
            .get(self.cursor)
            .copied()
            .ok_or("編集の履歴を確認できません。".into())
    }
    pub fn can_save(&self) -> Result<bool, String> {
        Ok(self.current()? != self.initial)
    }
    pub fn apply(&self, command: EditCommand) -> Result<Self, String> {
        self.validate()?;
        if (command.kind == EditCommandKind::Crop) != command.crop.is_some() {
            return Err("切り抜きの指定を確認できません。".into());
        }
        let mut next = self.clone();
        match command.kind {
            EditCommandKind::Undo => {
                next.cursor = next
                    .cursor
                    .checked_sub(1)
                    .ok_or("取り消せる編集がありません。")?;
            }
            EditCommandKind::Redo => {
                if next.cursor + 1 >= next.history.len() {
                    return Err("やり直せる編集がありません。".into());
                }
                next.cursor += 1;
            }
            _ => {
                let current = self.current()?;
                let changed = match command.kind {
                    EditCommandKind::RotateClockwise => {
                        current.rotate_clockwise(self.dimensions)?
                    }
                    EditCommandKind::MirrorHorizontal => {
                        current.mirror_horizontal(self.dimensions)?
                    }
                    EditCommandKind::MirrorVertical => current.mirror_vertical(self.dimensions)?,
                    EditCommandKind::Crop => current.crop_output(
                        self.dimensions,
                        command.crop.ok_or("切り抜く範囲を指定してください。")?,
                    )?,
                    EditCommandKind::ResetDraft => self.initial,
                    EditCommandKind::Undo | EditCommandKind::Redo => {
                        return Err("不正な編集です。".into());
                    }
                };
                next.history.truncate(next.cursor + 1);
                if next.history.len() >= HISTORY_LIMIT {
                    return Err("編集回数の上限です。一度保存してください。".into());
                }
                next.history.push(changed);
                next.cursor += 1;
            }
        }
        next.validate()?;
        Ok(next)
    }
}
