use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    domain::{StoredAsset, TransferFile},
    immich::{PendingUpload, Session, UploadIntent, UploadIntentForgetPrompt, valid_id},
};

impl Runtime<'_> {
    pub(super) async fn begin_upload(
        &mut self,
        session: &Session,
        file: &TransferFile,
        source: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<String, String> {
        let intents: Vec<_> = self
            .state
            .upload_intents
            .iter()
            .filter(|p| p.matches(session, file, source, live_id))
            .cloned()
            .collect();
        if let [intent] = intents.as_slice() {
            self.check_unique_intent(intent)?;
            let id = session.reconcile_upload_intent(self.ctx, intent).await?;
            let pending = self.promote_upload_intent(intent, id).await?;
            return self.resume_upload(session, file, &pending).await;
        }
        if !intents.is_empty() {
            return Err("アップロード開始記録が重複しています。書込みを停止しました。".into());
        }
        // Validate dates, checksums and Live linkage before journaling or POST.
        session.upload_request(file, source, now, live_id)?;
        let token: String = io(self.ctx, ShellOperation::RandomId).await?;
        valid_id(&token)?;
        let intent = UploadIntent {
            scope: session.scope.clone(),
            token,
            source: source.clone(),
            resource: file.resource.clone(),
            signature: file.signature.clone(),
            live_id: live_id.map(str::to_owned),
        };
        if self
            .state
            .upload_intents
            .iter()
            .any(|p| p.token == intent.token)
        {
            return Err("アップロードの固有 ID が重複しています。".into());
        }
        self.state.upload_intents.push(intent.clone());
        if let Err(error) = self.persist().await {
            self.state
                .upload_intents
                .retain(|p| p.token != intent.token);
            return Err(error);
        }
        self.check_content_generation(std::slice::from_ref(&source.key))?;
        let (id, created) = session
            .create_intended_upload(self.ctx, file, &intent, now)
            .await?;
        if !created {
            self.remove_upload_intent(&intent.scope, &intent.token)
                .await?;
            return Ok(id);
        }
        let pending = self.promote_upload_intent(&intent, id).await?;
        self.complete_created_upload(session, file, &pending).await
    }

    fn check_unique_intent(&self, intent: &UploadIntent) -> Result<(), String> {
        if self
            .state
            .upload_intents
            .iter()
            .filter(|p| p.token == intent.token)
            .count()
            != 1
        {
            return Err("アップロードの固有 ID が重複しています。書込みを停止しました。".into());
        }
        Ok(())
    }

    async fn promote_upload_intent(
        &mut self,
        intent: &UploadIntent,
        id: String,
    ) -> Result<PendingUpload, String> {
        self.check_unique_intent(intent)?;
        let pending = intent.pending(id);
        if self
            .state
            .pending_uploads
            .iter()
            .any(|p| p.key == pending.key)
        {
            return Err(
                "作成済みコピーの ID が既存の記録と重複しています。書込みを停止しました。".into(),
            );
        }
        let previous_intents = self.state.upload_intents.clone();
        let previous_pending = self.state.pending_uploads.clone();
        self.state
            .upload_intents
            .retain(|p| p.token != intent.token);
        self.state.pending_uploads.push(pending.clone());
        if let Err(error) = self.persist().await {
            self.state.upload_intents = previous_intents;
            self.state.pending_uploads = previous_pending;
            return Err(error);
        }
        Ok(pending)
    }

    async fn remove_upload_intent(&mut self, scope: &str, token: &str) -> Result<(), String> {
        let previous = self.state.upload_intents.clone();
        self.state
            .upload_intents
            .retain(|p| p.scope != scope || p.token != token);
        if let Err(error) = self.persist().await {
            self.state.upload_intents = previous;
            return Err(error);
        }
        Ok(())
    }

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
        self.remove_upload_intent(scope, token).await?;
        Ok("アップロード開始記録を解除しました。写真と転送履歴は変更していません。".into())
    }
}
