use super::Runtime;
use crate::{
    amazon::{Connection, UploadOutcome, UploadRecord, formats},
    app::{Event, ShellOperation, io},
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, TransferBundle, TransferFile},
};
use serde_json::Value;
use std::collections::BTreeSet;

impl Runtime<'_> {
    pub(super) fn execute_provider_event(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        match event {
            Event::ConfigureAmazon { credential_id, now } => {
                Box::pin(async move { self.configure_amazon(&credential_id, now).await })
            }
            Event::DisconnectAmazon => Box::pin(async move { self.disconnect_amazon().await }),
            Event::ResolveAmazonUploads { id } => {
                Box::pin(async move { self.resolve_amazon_uploads(&id).await })
            }
            Event::CopyTo {
                keys,
                destination,
                intent,
                id,
                now,
            } => Box::pin(async move {
                self.copy_to(&keys, destination, intent, &id, now).await?;
                Ok("コピーを検証しました。元データは残っています。".into())
            }),
            _ => Box::pin(async { Err("不正な操作です。".into()) }),
        }
    }

    pub(super) fn amazon_session(
        &self,
        keys: &[AssetKey],
        purpose: crate::immich::OrdinaryContentPurpose,
    ) -> Result<Connection, String> {
        let mut connection = self
            .state
            .amazon_connection
            .clone()
            .ok_or("Amazon Photosに接続してください。")?;
        connection.content_authorization = Some(crate::immich::OrdinaryContentAuthorization {
            source_keys: keys.to_vec(),
            expected_revision: self.ordinary_revision.clone(),
            purpose,
        });
        connection.ordinary_guard = Some(crate::immich::OrdinarySessionGuard {
            generation: self.ordinary_generation.clone(),
            expected: self.started_ordinary_generation,
        });
        Ok(connection)
    }
    pub(super) async fn configure_amazon(
        &mut self,
        credential_id: &str,
        now: f64,
    ) -> Result<String, String> {
        let mut connection = Connection::provisional(credential_id)?;
        if let Err(error) = connection.connect(self.ctx).await {
            self.discard_provisional_amazon_credential(credential_id)
                .await;
            return Err(error);
        }
        let old = self.state.clone();
        self.state.amazon_connection = Some(connection);
        self.state.schema_version = 9;
        self.state
            .snapshots
            .retain(|s| s.provider != Provider::Amazon);
        if let Err(error) = self.persist().await {
            self.state = old;
            self.discard_provisional_amazon_credential(credential_id)
                .await;
            return Err(error);
        }
        // The connection is durable now; a later refresh failure keeps it.
        if let Some(previous) = old
            .amazon_connection
            .filter(|c| c.credential_id != credential_id)
        {
            let _: Result<Value, _> = io(
                self.ctx,
                ShellOperation::RemoveAmazonCredential {
                    account: previous.credential_id,
                },
            )
            .await;
        }
        self.refresh_amazon(now).await?;
        self.persist().await?;
        Ok("Amazon Photosに接続しました。".into())
    }

    /// Remove a login reference that was never durably adopted. The current
    /// connection's credential is never removed, including when it was reused.
    async fn discard_provisional_amazon_credential(&self, credential_id: &str) {
        if self
            .state
            .amazon_connection
            .as_ref()
            .is_some_and(|c| c.credential_id == credential_id)
        {
            return;
        }
        let _: Result<Value, _> = io(
            self.ctx,
            ShellOperation::RemoveAmazonCredential {
                account: credential_id.into(),
            },
        )
        .await;
    }

    pub(super) async fn disconnect_amazon(&mut self) -> Result<String, String> {
        let old = self.state.clone();
        self.state.amazon_connection = None;
        self.state
            .snapshots
            .retain(|s| s.provider != Provider::Amazon);
        self.state.albums.retain(|s| s.provider != Provider::Amazon);
        if let Err(error) = self.persist().await {
            self.state = old;
            return Err(error);
        }
        if let Some(connection) = old.amazon_connection {
            let _: Value = io(
                self.ctx,
                ShellOperation::RemoveAmazonCredential {
                    account: connection.credential_id,
                },
            )
            .await?;
        }
        Ok("Amazon Photosの接続を解除しました。転送履歴は保持しています。".into())
    }

    pub(super) async fn refresh_amazon(&mut self, now: f64) -> Result<(), String> {
        let Some(connection) = self.state.amazon_connection.clone() else {
            return Ok(());
        };
        let mut checked = connection.clone();
        checked.connect(self.ctx).await?;
        if checked.scope != connection.scope {
            return Err(
                "Amazon Photosのアカウントが変わりました。接続設定から確認してください。".into(),
            );
        }
        let mut records = Vec::new();
        let mut seen = BTreeSet::new();
        let mut expected = None;
        loop {
            self.check_content_generation(&[])?;
            if records.len() >= 9999 {
                self.replace(LibrarySnapshot {
                    provider: Provider::Amazon,
                    scope: connection.scope.clone(),
                    assets: records,
                    access: ScanAccess::Limited,
                    scanned_at: Some(now),
                });
                return Err("Amazon Photosは取得可能なページ上限に達しました。取得済み分を表示しています。一覧は未完了です。".into());
            }
            let (total, nodes) = connection.page(self.ctx, records.len()).await?;
            if expected.is_some_and(|old| old != total)
                || (nodes.is_empty() && records.len() != total)
            {
                return Err(
                    "取得中にAmazon Photosの一覧が変わりました。未完了として再読込してください。"
                        .into(),
                );
            }
            expected = Some(total);
            for node in nodes {
                if !seen.insert(node.id.clone()) {
                    return Err("Amazon Photosのページが重複しました。一覧は未完了です。".into());
                }
                records.push(node.record(&connection));
            }
            self.preserve_original_fingerprints(&mut records);
            let complete = records.len() == total;
            self.replace(LibrarySnapshot {
                provider: Provider::Amazon,
                scope: connection.scope.clone(),
                assets: records.clone(),
                access: if complete {
                    ScanAccess::Full
                } else {
                    ScanAccess::Limited
                },
                scanned_at: Some(now),
            });
            self.progress("Amazon Photosの取得済み写真を表示しています。");
            self.ctx.send_event(Event::FetchProgress {
                status: format!("Amazon Photosを取得中: {} / {total} 件", records.len()),
            });
            if complete {
                return Ok(());
            }
            if records.len() > total {
                return Err("Amazon Photosの一覧件数が一致しません。".into());
            }
        }
    }

    pub(super) fn publish_amazon_copies(
        &mut self,
        assets: &[crate::domain::StoredAsset],
        now: f64,
    ) {
        let Some(connection) = &self.state.amazon_connection else {
            return;
        };
        if let Some(snapshot) = self
            .state
            .snapshots
            .iter_mut()
            .find(|s| s.provider == Provider::Amazon && s.scope == connection.scope)
        {
            for asset in assets {
                snapshot.assets.retain(|a| a.key != asset.key);
                snapshot.assets.push(asset.clone());
            }
            // New copies were verified, but concurrent catalog membership was not.
            snapshot.access = ScanAccess::Limited;
        } else {
            self.state.snapshots.push(LibrarySnapshot {
                provider: Provider::Amazon,
                scope: connection.scope.clone(),
                assets: assets.to_vec(),
                access: ScanAccess::Limited,
                scanned_at: Some(now),
            });
        }
    }

    pub(super) fn preflight_amazon(&self, keys: &[AssetKey]) -> Result<(), String> {
        self.state
            .amazon_connection
            .as_ref()
            .ok_or("Amazon Photosに接続してください。")?;
        if self.state.amazon_uploads.iter().any(|r| {
            !r.verified
                && self
                    .state
                    .amazon_connection
                    .as_ref()
                    .is_some_and(|c| c.scope == r.scope)
        }) {
            return Err("Amazon Photosへの未確定アップロードがあります。接続設定で結果を再確認してください。自動再送はしません。".into());
        }
        for key in keys {
            let asset = self
                .state
                .snapshots
                .iter()
                .flat_map(|s| &s.assets)
                .find(|a| a.key == *key)
                .ok_or("転送元の原本を確認できません。")?;
            for resource in &asset.resources {
                formats::check_resource(resource)?;
            }
        }
        Ok(())
    }

    pub(super) async fn export_amazon(
        &self,
        keys: &[AssetKey],
        directory: &str,
        purpose: crate::immich::OrdinaryContentPurpose,
    ) -> Result<TransferBundle, String> {
        let connection = self.amazon_session(keys, purpose)?;
        let mut bundle = TransferBundle {
            assets: vec![],
            files: vec![],
        };
        for (index, key) in keys.iter().enumerate() {
            if key.provider != Provider::Amazon || key.scope != connection.scope {
                return Err("Amazon Photosのアカウントが一致しません。".into());
            }
            let node = connection.node(self.ctx, &key.asset_id).await?;
            let path = format!("{directory}/{index}-original");
            let hash = connection.download(self.ctx, &node, &path).await?;
            let mut record = node.record(&connection);
            let resource = record
                .resources
                .first_mut()
                .ok_or("Amazon Photosの原本がありません。")?;
            resource.sha1 = Some(hash.sha1);
            bundle.files.push(TransferFile {
                resource: resource.clone(),
                path,
                signature: hash.signature,
            });
            bundle.assets.push(record);
        }
        Ok(bundle)
    }

    pub(super) async fn import_amazon(
        &mut self,
        bundle: &TransferBundle,
    ) -> Result<Vec<AssetKey>, String> {
        let keys: Vec<_> = bundle.assets.iter().map(|a| a.key.clone()).collect();
        let connection = self.amazon_session(&keys, crate::immich::OrdinaryContentPurpose::Read)?;
        // Validate the entire set before the first remote write.
        for file in &bundle.files {
            formats::check_resource(&file.resource)?;
        }
        let mut imported = Vec::new();
        for file in &bundle.files {
            let hash: crate::amazon::Hash = io(
                self.ctx,
                ShellOperation::AmazonHashFile {
                    path: file.path.clone(),
                },
            )
            .await?;
            if hash.signature != file.signature {
                return Err("アップロード前に原本が変わりました。".into());
            }
            let request = connection
                .upload_request(
                    self.ctx,
                    file,
                    &hash.md5,
                    bundle
                        .assets
                        .iter()
                        .find(|asset| asset.resources.iter().any(|r| r.id == file.resource.id))
                        .and_then(|asset| asset.captured_at),
                )
                .await?;
            let (index, record) = self
                .journal_amazon_upload(&connection, file, &hash.md5)
                .await?;
            // Never retried. Only definite non-storage releases this attempt's fence.
            let response = match connection.submit_upload(self.ctx, request).await? {
                UploadOutcome::Accepted(response) => response,
                UploadOutcome::Refused(reason) => {
                    return Err(match self.release_amazon_upload(index, &record).await {
                        Ok(()) => reason,
                        Err(error) => format!("{reason}\n{error}"),
                    });
                }
            };
            let id = response.body["id"].as_str().ok_or(
                "Amazon Photosのアップロード結果が不明です。再送せず一覧を確認してください。",
            )?;
            let node = connection.node(self.ctx, id).await?;
            node.validate(&connection)?;
            self.state.amazon_uploads[index].node_id = Some(node.id.clone());
            self.persist().await?;
            let path = format!("{}/amazon-{index}", self.directory("readback")?);
            let readback = connection.download(self.ctx, &node, &path).await?;
            if readback.signature != file.signature {
                return Err(
                    "Amazon Photosに保存された原本のSHA-256が一致しません。元の原本は残します。"
                        .into(),
                );
            }
            self.state.amazon_uploads[index].verified = true;
            self.persist().await?;
            imported.push(AssetKey {
                provider: Provider::Amazon,
                scope: connection.scope.clone(),
                asset_id: node.id,
            });
        }
        Ok(imported)
    }

    /// Journal the upload before its POST. If saving fails no POST is issued, and
    /// memory is restored so a later unrelated save cannot create a phantom fence.
    async fn journal_amazon_upload(
        &mut self,
        connection: &Connection,
        file: &TransferFile,
        md5: &str,
    ) -> Result<(usize, UploadRecord), String> {
        let record = UploadRecord {
            receipt_id: self
                .state
                .receipts
                .last()
                .ok_or("転送記録がありません。")?
                .id
                .clone(),
            scope: connection.scope.clone(),
            name: file.resource.name.clone(),
            signature: file.signature.clone(),
            md5: md5.into(),
            node_id: None,
            verified: false,
        };
        let index = self.state.amazon_uploads.len();
        self.state.amazon_uploads.push(record.clone());
        if let Err(error) = self.persist().await {
            self.state.amazon_uploads.truncate(index);
            return Err(error);
        }
        Ok((index, record))
    }

    /// Remove only this attempt's record after proof that it was not stored. If
    /// the removal cannot be saved, the durable fence is kept in memory as well.
    async fn release_amazon_upload(
        &mut self,
        index: usize,
        expected: &UploadRecord,
    ) -> Result<(), String> {
        if self.state.amazon_uploads.get(index) != Some(expected) {
            return Err("Amazon Photosの転送記録を確認できません。書込みは再送しません。".into());
        }
        let record = self.state.amazon_uploads.remove(index);
        if let Err(error) = self.persist().await {
            self.state.amazon_uploads.insert(index, record);
            return Err(error);
        }
        Ok(())
    }

    pub(super) async fn resolve_amazon_uploads(&mut self, id: &str) -> Result<String, String> {
        let connection = self
            .state
            .amazon_connection
            .clone()
            .ok_or("Amazon Photosに接続してください。")?;
        self.workspace(id).await?;
        let indices: Vec<_> = self
            .state
            .amazon_uploads
            .iter()
            .enumerate()
            .filter(|(_, r)| r.scope == connection.scope && !r.verified)
            .map(|(i, _)| i)
            .collect();
        for index in indices {
            let saved = self.state.amazon_uploads[index].clone();
            let source_keys: Vec<_> = self
                .state
                .receipts
                .iter()
                .find(|r| r.id == saved.receipt_id)
                .ok_or("転送元の記録がありません。再送せず確認してください。")?
                .source
                .iter()
                .map(|a| a.key.clone())
                .collect();
            self.check_content_keys(&source_keys)?;
            let connection =
                self.amazon_session(&source_keys, crate::immich::OrdinaryContentPurpose::Read)?;
            let node_id = if let Some(node_id) = saved.node_id {
                node_id
            } else {
                // A lost POST response must only trigger reads. Require one
                // candidate, then verify its actual bytes before clearing the fence.
                let mut offset = 0;
                let mut candidates = Vec::new();
                let mut expected = None;
                let mut seen = BTreeSet::new();
                loop {
                    if offset >= 9999 {
                        return Err("保存結果の探索がAmazon Photosの一覧上限に達しました。再送せずAmazon Photos上で確認してください。".into());
                    }
                    let (total, nodes) = connection.page(self.ctx, offset).await?;
                    if expected.is_some_and(|old| old != total)
                        || (nodes.is_empty() && offset != total)
                    {
                        return Err(
                            "保存結果の探索中に一覧が変わりました。書込みは再送していません。"
                                .into(),
                        );
                    }
                    expected = Some(total);
                    for node in nodes {
                        if !seen.insert(node.id.clone()) {
                            return Err("保存結果の探索でページが重複しました。".into());
                        }
                        offset += 1;
                        if node.content_properties.size == saved.signature.bytes
                            && node.content_properties.md5.eq_ignore_ascii_case(&saved.md5)
                        {
                            candidates.push(node.id);
                        }
                    }
                    if offset >= total {
                        break;
                    }
                }
                if candidates.len() != 1 {
                    return Err("保存結果の写真を一意に特定できません。書込みは再送しません。Amazon Photos上で確認してください。".into());
                }
                let node_id = candidates.remove(0);
                self.state.amazon_uploads[index].node_id = Some(node_id.clone());
                self.persist().await?;
                node_id
            };
            let node = connection.node(self.ctx, &node_id).await?;
            let path = format!("{}/amazon-{index}", self.directory("reconcile")?);
            let hash = connection.download(self.ctx, &node, &path).await?;
            if hash.signature != saved.signature || hash.md5 != saved.md5 {
                return Err(
                    "Amazon Photosの原本と転送記録が一致しません。元の原本は残します。".into(),
                );
            }
            self.state.amazon_uploads[index].verified = true;
            self.persist().await?;
        }
        Ok(
            "Amazon Photosのアップロード結果を再取得して照合しました。書込みの再送はしていません。"
                .into(),
        )
    }
}
