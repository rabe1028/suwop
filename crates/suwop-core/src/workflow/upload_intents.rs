use super::{JournalChange, Runtime};
use crate::{
    app::{ShellOperation, io},
    immich::UploadIntentForgetPrompt,
};

impl Runtime<'_> {
    pub(super) async fn forget_upload_intent(
        &mut self,
        scope: &str,
        token: &str,
    ) -> Result<String, String> {
        let record = self
            .state
            .upload_intents
            .iter()
            .find(|p| p.scope == scope && p.token == token)
            .ok_or("解除するアップロード開始記録がありません。")?;
        let prompt = UploadIntentForgetPrompt {
            scope: scope.into(),
            token: token.into(),
            name: crate::privacy::public_asset_name(&self.state, &record.source),
        };
        let confirmed: bool = io(
            self.ctx,
            ShellOperation::ConfirmForgetUploadIntent { prompt },
        )
        .await?;
        if !confirmed {
            return Ok("開始記録の解除をキャンセルしました。".into());
        }
        self.persist_stage(JournalChange::ImmichIntentRemoved {
            scope: scope.into(),
            token: token.into(),
        })
        .await?;
        Ok("アップロード開始記録を解除しました。写真と転送履歴は変更していません。".into())
    }
}
