use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset, catalog},
    editing::{
        AppleReversionFacts, targets, verify_edit_source, verify_edited_originals,
        verify_reversion_input,
    },
};

use super::Runtime;

impl Runtime<'_> {
    pub(super) async fn revert_image(
        &mut self,
        key: &AssetKey,
        id: &str,
    ) -> Result<String, String> {
        self.check_keys(std::slice::from_ref(key))?;
        let photos = catalog(&self.state.snapshots, &self.state.receipts);
        let photo = photos
            .iter()
            .find(|p| p.assets.iter().any(|a| a.key == *key))
            .ok_or("原本へ戻す写真を確認できません。一覧を更新してください。")?;
        let target = targets(photo, &self.state.snapshots, &self.state.apple_scope)
            .into_iter()
            .find(|t| t.key == *key)
            .ok_or("原本へ戻す保存先を確認できません。")?;
        if let Some(reason) = target.disabled_reason {
            return Err(reason);
        }
        let expected = photo
            .assets
            .iter()
            .find(|a| a.key == *key)
            .ok_or("原本へ戻す写真を確認できません。")?
            .clone();
        let facts: AppleReversionFacts = io(
            self.ctx,
            ShellOperation::AppleReversionInspect {
                asset: expected.clone(),
            },
        )
        .await?;
        let prompt = verify_reversion_input(&expected, &facts)?;
        let confirmed: bool = io(self.ctx, ShellOperation::ConfirmReversion { prompt }).await?;
        if !confirmed {
            return Ok("原本へ戻す操作をキャンセルしました。".into());
        }
        self.workspace(id).await?;
        let before = self
            .export(std::slice::from_ref(key), "revert-before")
            .await?;
        let [source] = before.assets.as_slice() else {
            return Err("原本へ戻す写真の内容を確認できません。".into());
        };
        // Consent covered this revision. A concurrent edit must not be discarded.
        verify_edit_source(&facts.asset, source)?;
        self.reversion_started = true;
        let result: Result<StoredAsset, String> = async {
            let saved: AppleReversionFacts = io(
                self.ctx,
                ShellOperation::AppleRevert {
                    asset: source.clone(),
                },
            )
            .await?;
            if saved.asset.key != *key || saved.has_adjustments || !saved.can_edit {
                return Err("原本への復元結果を確認できません。一覧を更新してください。".into());
            }
            let after = self
                .export(std::slice::from_ref(key), "revert-after")
                .await?;
            verify_edited_originals(&before, &after)?;
            let [fresh] = after.assets.as_slice() else {
                return Err("復元後の原本を確認できません。".into());
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
                Ok("この保存先の写真を原本へ戻しました。".into())
            }
            Err(error) => {
                self.invalidate(Provider::Apple);
                self.persist().await?;
                Err(error)
            }
        }
    }
}
