use super::{
    Asset, HttpResponse, Session, UploadPart, check_status, parse_date, safe_name, upload_date,
    valid_id,
};
use crate::{
    app::{Context, ShellOperation, io},
    domain::{AssetKey, FileSignature, PhotoResource, StoredAsset, TransferFile},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum UploadPhase {
    MetadataPending,
    MetadataStarted,
}

/// A confirmed creation or a reconciled upload-time marker identifies this copy.
/// No temporary path or credential is persisted; every resume re-exports bytes.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PendingUpload {
    pub key: AssetKey,
    pub source: StoredAsset,
    pub resource: PhotoResource,
    pub signature: FileSignature,
    pub live_id: Option<String>,
    pub phase: UploadPhase,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadResumePrompt {
    pub key: AssetKey,
    pub name: String,
    pub source: StoredAsset,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadForgetPrompt {
    pub key: AssetKey,
    pub name: String,
}

#[derive(Debug)]
pub struct UploadMetadataPlan {
    pub asset: Asset,
    pub body: Value,
}

impl Session {
    /// Convenience for isolated API callers. App transfers persist the confirmed
    /// ID between `create_upload` and `prepare_upload_metadata` instead.
    pub async fn upload(
        &self,
        ctx: &Context,
        file: &TransferFile,
        metadata: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<String, String> {
        let (id, created) = self
            .create_upload(ctx, file, metadata, now, live_id)
            .await?;
        if created {
            let plan = self.prepare_upload_metadata(ctx, &id, metadata).await?;
            self.apply_upload_metadata(ctx, &id, plan.body).await?;
        }
        Ok(id)
    }

    pub async fn create_upload(
        &self,
        ctx: &Context,
        file: &TransferFile,
        metadata: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<(String, bool), String> {
        let request = self.upload_request(file, metadata, now, live_id)?;
        self.submit_upload(ctx, request).await
    }

    pub(crate) fn upload_request(
        &self,
        file: &TransferFile,
        metadata: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<super::HttpRequest, String> {
        let captured = upload_date(metadata.captured_at.unwrap_or(now))?;
        let modified = upload_date(metadata.modified_at.or(metadata.captured_at).unwrap_or(now))?;
        let mut request = self.request("assets", "POST", None);
        request.fields = BTreeMap::from([
            ("fileCreatedAt".into(), captured),
            ("fileModifiedAt".into(), modified),
            ("isFavorite".into(), metadata.is_favorite.to_string()),
        ]);
        if self.version.major < 3 {
            request.fields.insert("deviceId".into(), "suwop".into());
            request.fields.insert(
                "deviceAssetId".into(),
                file.resource.sha1.clone().ok_or("原本未照合です。")?,
            );
        }
        if let Some(id) = live_id {
            valid_id(id)?;
            request.fields.insert("livePhotoVideoId".into(), id.into());
        }
        request.files.push(UploadPart {
            field: "assetData".into(),
            path: file.path.clone(),
            filename: safe_name(&file.resource.name),
        });
        if let Some(checksum) = &file.resource.sha1 {
            request
                .headers
                .insert("x-immich-checksum".into(), checksum.clone());
        }
        Ok(request)
    }

    pub(super) async fn submit_upload(
        &self,
        ctx: &Context,
        request: super::HttpRequest,
    ) -> Result<(String, bool), String> {
        let response: HttpResponse = io(ctx, ShellOperation::Http(request)).await?;
        check_status(response.status)?;
        let status = response.body["status"]
            .as_str()
            .ok_or("アップロード結果が不明です。")?;
        if !["created", "duplicate"].contains(&status.to_ascii_lowercase().as_str()) {
            return Err("アップロードが確定しません。".into());
        }
        let id = response.body["id"]
            .as_str()
            .ok_or("写真 ID がありません。")?;
        valid_id(id)?;
        Ok((id.into(), status.eq_ignore_ascii_case("created")))
    }

    pub async fn prepare_upload_metadata(
        &self,
        ctx: &Context,
        id: &str,
        metadata: &StoredAsset,
    ) -> Result<UploadMetadataPlan, String> {
        let asset = if metadata.captured_at.is_some() {
            self.extracted_capture_asset(ctx, id).await?
        } else {
            self.asset(ctx, id).await?
        };
        let mut body = json!({"isFavorite": metadata.is_favorite});
        if let Some(expected) = metadata.captured_at {
            let extracted = asset
                .exif_info
                .as_ref()
                .and_then(|e| e.date_time_original.as_deref())
                .and_then(parse_date)
                .ok_or("撮影日時の抽出を確認できません。")?;
            if !crate::domain::same_capture_date(extracted, expected) {
                body["dateTimeOriginal"] = json!(upload_date(expected)?);
            }
        }
        if let (Some(lat), Some(lon)) = (metadata.latitude, metadata.longitude) {
            body["latitude"] = json!(lat);
            body["longitude"] = json!(lon);
        }
        Ok(UploadMetadataPlan { asset, body })
    }

    pub async fn apply_upload_metadata(
        &self,
        ctx: &Context,
        id: &str,
        body: Value,
    ) -> Result<(), String> {
        valid_id(id)?;
        let _: Value = self
            .json(ctx, &format!("assets/{id}"), "PUT", Some(body))
            .await?;
        Ok(())
    }

    async fn extracted_capture_asset(&self, ctx: &Context, id: &str) -> Result<Asset, String> {
        for attempt in 0..=120 {
            let asset = self.asset(ctx, id).await?;
            if asset
                .exif_info
                .as_ref()
                .and_then(|e| e.date_time_original.as_deref())
                .and_then(parse_date)
                .is_some()
            {
                return Ok(asset);
            }
            if attempt == 120 {
                break;
            }
            let _: Value = io(ctx, ShellOperation::Wait { milliseconds: 250 }).await?;
        }
        Err("新しいコピーの撮影日時の抽出を確認できません。元の写真から同じコピー操作を選んで再開してください。元の写真は残しています。".into())
    }
}
