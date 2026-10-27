use super::{
    AssetKey, ImportJournal, Provider, Runtime, ShellOperation, io, verify_import_metadata,
};
use crate::{
    domain::ResourceRole,
    immich::{HttpResponse, UploadPart, check_status, valid_id},
};
use crate::{
    external_import::StagedResource,
    immich::{HttpRequest, Session},
};
use serde_json::json;

impl Runtime<'_> {
    async fn create_import_raw_stack(
        &self,
        session: &Session,
        keys: &[AssetKey],
    ) -> Result<(), String> {
        self.check_content_keys(keys)?;
        let ids: Vec<_> = keys.iter().map(|key| key.asset_id.clone()).collect();
        let request = session.request("stacks", "POST", Some(json!({"assetIds":ids})));
        let response: HttpResponse = io(self.ctx, ShellOperation::ImportHttp { request }).await?;
        check_status(response.status)?;
        let mut stack_id = None;
        for key in keys {
            let asset = session.asset(self.ctx, &key.asset_id).await?;
            let membership = asset
                .stack
                .membership
                .as_ref()
                .ok_or("RAW＋JPEG のスタックを確認できません。")?;
            if membership.asset_count != 2 {
                return Err("RAW＋JPEG のスタック構成が一致しません。".into());
            }
            if stack_id.as_ref().is_some_and(|id| id != &membership.id) {
                return Err("RAW＋JPEG が同じスタックにありません。".into());
            }
            stack_id = Some(membership.id.clone());
        }
        Ok(())
    }

    async fn write_created_import_metadata(
        &self,
        session: &Session,
        record: &ImportJournal,
        id: &str,
    ) -> Result<(), String> {
        let mut metadata = json!({"isFavorite":record.item.metadata.favorite});
        if let Some(date) = &record.item.metadata.captured_at {
            metadata["dateTimeOriginal"] = json!(date);
        }
        if let (Some(lat), Some(lon)) = (
            record.item.metadata.latitude,
            record.item.metadata.longitude,
        ) {
            metadata["latitude"] = json!(lat);
            metadata["longitude"] = json!(lon);
        }
        self.check_ordinary_generation()?;
        let request = session.request(&format!("assets/{id}"), "PUT", Some(metadata));
        let response: HttpResponse = io(self.ctx, ShellOperation::ImportHttp { request }).await?;
        check_status(response.status)?;
        Ok(())
    }

    async fn save_import_partial(
        &mut self,
        record: &ImportJournal,
        keys: &[AssetKey],
        created: bool,
    ) -> Result<(), String> {
        let mut partial = self
            .state
            .external_imports
            .iter()
            .find(|entry| entry.id == record.id)
            .cloned()
            .ok_or("取り込み記録がありません。")?;
        partial.destination_keys = keys.to_vec();
        partial.created = Some(created);
        self.save_import(partial).await?;
        Ok(())
    }

    pub(super) async fn import_immich_item(
        &mut self,
        record: &ImportJournal,
    ) -> Result<
        (
            Vec<AssetKey>,
            Vec<String>,
            bool,
            Vec<crate::domain::StoredAsset>,
        ),
        String,
    > {
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        if session.scope != record.destination_scope || session.version.major != 3 {
            return Err("取り込み先アカウントまたは対応する Immich の版を確認できません。".into());
        }
        let mut resources = record.item.resources.clone();
        resources.sort_by_key(|resource| match resource.role {
            ResourceRole::LiveVideo => 0,
            ResourceRole::Image => 1,
            _ => 2,
        });
        let mut keys = Vec::new();
        let mut live_id: Option<String> = None;
        let mut all_created = true;
        for resource in &resources {
            self.check_ordinary_generation()?;
            if !record.source_keys.is_empty() {
                self.check_content_keys(&record.source_keys)?;
            }
            let path: String = io(
                self.ctx,
                ShellOperation::ResolveImportResource {
                    operation: record.staging_operation.clone(),
                    resource: resource.clone(),
                },
            )
            .await?;
            let request = upload_request(&session, record, resource, path, live_id.as_ref());
            let response: HttpResponse =
                io(self.ctx, ShellOperation::ImportHttp { request }).await?;
            check_status(response.status)?;
            let id = response.body["id"]
                .as_str()
                .ok_or("取り込み先IDがありません。")?;
            valid_id(id)?;
            let created = match response.body["status"].as_str() {
                Some("created") => true,
                Some("duplicate") => false,
                _ => return Err("アップロードの作成結果が不明です。".into()),
            };
            let key = AssetKey {
                provider: Provider::Immich,
                scope: session.scope.clone(),
                asset_id: id.into(),
            };
            if created && record.source_keys.contains(&key) {
                return Err("複製元と同じIDが返りました。保存結果を確認してください。".into());
            }
            keys.push(key.clone());
            // Preserve known IDs before readback or any subsequent pair write.
            self.save_import_partial(record, &keys, all_created && created)
                .await?;
            all_created &= created;
            if !created && resources.len() > 1 {
                // An existing child must not be relinked/stacked by importing a
                // new parent. Partial creations remain fenced, never deleted.
                return Err(
                    "組の一部は既に存在します。既存の写真を変更せず、保存結果の確認を待ちます。"
                        .into(),
                );
            }
            self.check_content_keys(std::slice::from_ref(&key))?;
            let observed = session.asset(self.ctx, id).await?;
            if resource.role == ResourceRole::Image && observed.live_photo_video_id != live_id {
                return Err("Live Photo の関連付けを確認できません。".into());
            }
            if created {
                self.write_created_import_metadata(&session, record, id)
                    .await?;
            }
            if resource.role == ResourceRole::LiveVideo {
                live_id = Some(id.into());
            }
        }
        if resources.iter().any(|r| r.role == ResourceRole::RawImage) && resources.len() == 2 {
            self.create_import_raw_stack(&session, &keys).await?;
        }
        if self.workspace.is_none() {
            self.workspace(&record.staging_operation).await?;
        }
        // Export the parent only for Live: its export includes both resources.
        let readback_keys: Vec<_> = keys
            .iter()
            .filter(|key| Some(&key.asset_id) != live_id.as_ref())
            .cloned()
            .collect();
        let bundle = self
            .export_readback(&readback_keys, &format!("import-verify-{}", record.id))
            .await?;
        if all_created {
            verify_import_metadata(record, &bundle.assets)?;
        }
        let hashes = bundle
            .files
            .iter()
            .map(|file| file.signature.sha256.clone())
            .collect();
        Ok((keys, hashes, all_created, bundle.assets))
    }
}

fn upload_request(
    session: &Session,
    record: &ImportJournal,
    resource: &StagedResource,
    path: String,
    live_id: Option<&String>,
) -> HttpRequest {
    let mut request = session.request("assets", "POST", None);
    let captured = record
        .item
        .metadata
        .captured_at
        .clone()
        .unwrap_or(crate::immich::date_string(record.created_at));
    request
        .fields
        .insert("fileCreatedAt".into(), captured.clone());
    request.fields.insert("fileModifiedAt".into(), captured);
    request.fields.insert(
        "isFavorite".into(),
        record.item.metadata.favorite.to_string(),
    );
    if resource.role == ResourceRole::Image
        && let Some(id) = live_id
    {
        request.fields.insert("livePhotoVideoId".into(), id.clone());
    }
    request.files.push(UploadPart {
        field: "assetData".into(),
        path,
        filename: resource.name.clone(),
    });
    request
}
