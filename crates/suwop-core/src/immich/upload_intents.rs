use super::{PendingUpload, Session, UploadPhase, valid_id};
use crate::{
    app::Context,
    domain::{AssetKey, FileSignature, PhotoResource, Provider, StoredAsset, TransferFile},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const ORIGIN_KEY: &str = "suwop.upload-origin.v1";

/// Durable before POST. The remote marker is attached only by asset creation,
/// never by a later metadata write or a duplicate upload.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadIntent {
    pub scope: String,
    pub token: String,
    pub source: StoredAsset,
    pub resource: PhotoResource,
    pub signature: FileSignature,
    pub live_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadIntentForgetPrompt {
    pub scope: String,
    pub token: String,
    pub name: String,
}

impl UploadIntent {
    #[must_use]
    pub fn matches(
        &self,
        session: &Session,
        file: &TransferFile,
        source: &StoredAsset,
        live_id: Option<&str>,
    ) -> bool {
        self.scope == session.scope
            && self.source.same_content_evidence(source)
            && self.resource == file.resource
            && self.signature == file.signature
            && self.live_id.as_deref() == live_id
    }

    #[must_use]
    pub fn pending(&self, id: String) -> PendingUpload {
        PendingUpload {
            key: AssetKey {
                provider: Provider::Immich,
                scope: self.scope.clone(),
                asset_id: id,
            },
            source: self.source.clone(),
            resource: self.resource.clone(),
            signature: self.signature.clone(),
            live_id: self.live_id.clone(),
            phase: UploadPhase::MetadataPending,
        }
    }

    #[must_use]
    pub fn marker(&self) -> Value {
        json!({"version":1, "token":self.token})
    }
}

impl Session {
    pub async fn create_intended_upload(
        &self,
        ctx: &Context,
        file: &TransferFile,
        intent: &UploadIntent,
        now: f64,
    ) -> Result<(String, bool), String> {
        valid_id(&intent.token)?;
        if !intent.matches(self, file, &intent.source, intent.live_id.as_deref()) {
            return Err("アップロードの開始記録が一致しません。".into());
        }
        let mut request =
            self.upload_request(file, &intent.source, now, intent.live_id.as_deref())?;
        request.fields.insert(
            "metadata".into(),
            json!([{ "key":ORIGIN_KEY, "value":intent.marker() }]).to_string(),
        );
        self.submit_upload(ctx, request).await
    }

    /// Both POST bulk-check and GET metadata are read-only. An unknown POST is
    /// never repeated, including when bulk-check says a fresh upload is allowed.
    pub async fn reconcile_upload_intent(
        &self,
        ctx: &Context,
        intent: &UploadIntent,
    ) -> Result<String, String> {
        valid_id(&intent.token)?;
        if intent.scope != self.scope {
            return Err("再開するアカウントが一致しません。".into());
        }
        let checksum = intent.resource.sha1.as_ref().ok_or("原本未照合です。")?;
        let response: Value = self
            .json(
                ctx,
                "assets/bulk-upload-check",
                "POST",
                Some(json!({"assets":[{"id":intent.token,"checksum":checksum}]})),
            )
            .await?;
        let rows = response["results"]
            .as_array()
            .ok_or("アップロードの照合結果が不明です。")?;
        let [row] = rows.as_slice() else {
            return Err("アップロードの照合結果が重複・欠落しています。".into());
        };
        if row["id"] != intent.token
            || row["action"] != "reject"
            || row["reason"] != "duplicate"
            || row["isTrashed"] != false
        {
            return Err("作成したコピーを確認できません。転送履歴から開始記録を解除して確認し直してください。".into());
        }
        let id = row["assetId"]
            .as_str()
            .ok_or("照合したコピーの ID がありません。")?;
        valid_id(id)?;
        let marker: Value = self
            .json(
                ctx,
                &format!("assets/{id}/metadata/{ORIGIN_KEY}"),
                "GET",
                None,
            )
            .await?;
        if marker["key"] != ORIGIN_KEY || marker["value"] != intent.marker() {
            return Err("同じ原本はありますが、この操作で作成したコピーと確認できません。写真の情報を変更していません。".into());
        }
        Ok(id.into())
    }
}
