use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset, catalog},
    editing::{
        AppleEditInput, AppleEditResult, ImageEditDraft, prepare_apple_edit, targets,
        verify_edit_source, verify_edited_originals,
    },
};

use super::Runtime;

impl Runtime<'_> {
    pub(super) async fn edit_image(&mut self, key: &AssetKey, id: &str) -> Result<String, String> {
        self.check_keys(std::slice::from_ref(key))?;
        let photos = catalog(&self.state.snapshots, &self.state.receipts);
        let photo = photos
            .iter()
            .find(|p| p.assets.iter().any(|a| a.key == *key))
            .ok_or("編集する写真を確認できません。一覧を更新してください。")?;
        let target = targets(photo, &self.state.snapshots, &self.state.apple_scope)
            .into_iter()
            .find(|t| t.key == *key)
            .ok_or("編集する保存先を確認できません。")?;
        if let Some(reason) = target.disabled_reason {
            return Err(reason);
        }
        let expected = photo
            .assets
            .iter()
            .find(|a| a.key == *key)
            .ok_or("編集する写真を確認できません。")?
            .clone();
        self.workspace(id).await?;
        let before = self
            .export(std::slice::from_ref(key), "edit-before")
            .await?;
        let [source] = before.assets.as_slice() else {
            return Err("編集する写真の原本を確認できません。".into());
        };
        verify_edit_source(&expected, source)?;
        let directory = self.directory("editor")?;
        let input: AppleEditInput = io(
            self.ctx,
            ShellOperation::AppleEditOpen {
                asset: source.clone(),
                directory: directory.clone(),
            },
        )
        .await?;
        self.editing_token = Some(input.token.clone());
        let presentation = prepare_apple_edit(source, &input, &directory)?;
        self.check_content_generation(std::slice::from_ref(key))?;
        let returned: Option<ImageEditDraft> = io(
            self.ctx,
            ShellOperation::EditImage {
                key: key.clone(),
                presentation: presentation.clone(),
            },
        )
        .await?;
        let Some(draft) = returned else {
            return Ok("写真の編集をキャンセルしました。".into());
        };
        let plan = presentation.save_plan(&draft)?;
        let result: Result<StoredAsset, String> = async {
            let saved: AppleEditResult = io(
                self.ctx,
                ShellOperation::AppleEditSave {
                    token: input.token,
                    asset: source.clone(),
                    plan: plan.clone(),
                },
            )
            .await?;
            if saved.asset.key != *key
                || saved.adjustment != plan.adjustment
                || saved.image.oriented_size()? != plan.transform.output_size(plan.dimensions)?
                || !saved.image.has_color_space
                || saved.image.hdr
                || saved.image.has_alpha
            {
                return Err(
                    "保存した写真の編集内容を確認できません。一覧を更新してください。".into(),
                );
            }
            let after = self.export(std::slice::from_ref(key), "edit-after").await?;
            verify_edited_originals(&before, &after)?;
            let [fresh] = after.assets.as_slice() else {
                return Err("編集した写真の原本を確認できません。".into());
            };
            verify_edit_source(&saved.asset, fresh)?;
            Ok(fresh.clone())
        }
        .await;
        match result {
            Ok(fresh) => {
                self.replace_records(vec![fresh]);
                if let Err(error) = self.persist().await {
                    self.invalidate(Provider::Apple);
                    return Err(error);
                }
                self.preferred_preview = Some(key.clone());
                Ok("写真の編集を保存しました。原本は残っています。".into())
            }
            Err(error) => {
                self.invalidate(Provider::Apple);
                self.persist().await?;
                Err(error)
            }
        }
    }
}
