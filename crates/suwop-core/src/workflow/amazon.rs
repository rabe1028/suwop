use super::{JournalChange, Runtime};
use crate::{
    amazon::{Connection, UploadRecord, UploadRecordPhase},
    app::{Event, ShellOperation, io},
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess},
    provider::{ListRequest, Listing},
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
        purpose: crate::transport::OrdinaryContentPurpose,
    ) -> Result<Connection, String> {
        Ok(self.amazon_backend()?.session(keys, purpose))
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
        self.state.schema_version = crate::immich_live_writes::CURRENT_SCHEMA_VERSION;
        self.state
            .snapshots
            .retain(|s| s.provider != Provider::Amazon);
        self.invalidate_amazon();
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
        let warning = self.refresh_amazon(now).await?;
        self.persist().await?;
        if let Some(warning) = warning {
            return Err(warning);
        }
        Ok("Amazon Photosに接続しました。".into())
    }

    /// A connected account without a current inventory is Unavailable, never
    /// absent: absence would let Apple/Immich-only claims ignore Amazon.
    pub(super) fn invalidate_amazon(&mut self) {
        self.invalidate(Provider::Amazon);
        let Some(scope) = self
            .state
            .amazon_connection
            .as_ref()
            .map(|c| c.scope.clone())
        else {
            return;
        };
        if !self
            .state
            .snapshots
            .iter()
            .any(|s| s.provider == Provider::Amazon && s.scope == scope)
        {
            self.state.snapshots.push(LibrarySnapshot {
                provider: Provider::Amazon,
                scope,
                assets: vec![],
                access: ScanAccess::Unavailable,
                scanned_at: None,
            });
        }
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

    /// Records are only placed in the workflow state; publication belongs to the
    /// caller's final result (for `Refresh`, after its generation admission).
    /// `Ok(Some(_))` reports a Limited partial catalog at the unofficial page cap.
    pub(super) async fn refresh_amazon(&mut self, now: f64) -> Result<Option<String>, String> {
        let registry = self.registry();
        let Some(listing) = registry.listing(Provider::Amazon) else {
            return Ok(None);
        };
        let (mut snapshot, warning) = listing
            .list(
                self.read_io(),
                ListRequest {
                    permission: false,
                    now,
                },
            )
            .await
            .map(Listing::into_snapshot)?;
        self.preserve_original_fingerprints(&mut snapshot.assets);
        self.replace(snapshot);
        Ok(warning)
    }

    /// Find the one node a lost POST may have created, by reads only.
    async fn find_uploaded_node(&self, saved: &UploadRecord) -> Result<String, String> {
        let connection = self.amazon_backend()?.listing_session();
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
            if expected.is_some_and(|old| old != total) || (nodes.is_empty() && offset != total) {
                return Err(
                    "保存結果の探索中に一覧が変わりました。書込みは再送していません。".into(),
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
        Ok(candidates.remove(0))
    }

    /// Journal reconciliation reads only the Amazon destination, never the
    /// original source, which may since have been deleted or hidden. It never
    /// changes a receipt phase or grants Move/deletion authority.
    pub(super) async fn resolve_amazon_uploads(&mut self, id: &str) -> Result<String, String> {
        let scope = self
            .state
            .amazon_connection
            .as_ref()
            .ok_or("Amazon Photosに接続してください。")?
            .scope
            .clone();
        self.workspace(id).await?;
        let unresolved: Vec<_> = self
            .state
            .amazon_uploads
            .iter()
            .filter(|r| r.scope == scope && r.phase() != UploadRecordPhase::Verified)
            .cloned()
            .collect();
        for (index, saved) in unresolved.into_iter().enumerate() {
            let node_id = if let Some(node_id) = &saved.node_id {
                node_id.clone()
            } else {
                let node_id = self.find_uploaded_node(&saved).await?;
                self.persist_stage(JournalChange::AmazonCreated {
                    record: saved.clone(),
                    node_id: node_id.clone(),
                })
                .await?;
                node_id
            };
            let created = UploadRecord {
                node_id: Some(node_id.clone()),
                ..saved
            };
            // Bind the exact journaled destination. Current owner, generation,
            // protection and denial still apply to it; drift keeps the fence.
            let key = AssetKey {
                provider: Provider::Amazon,
                scope: scope.clone(),
                asset_id: node_id,
            };
            let keys = std::slice::from_ref(&key);
            self.check_keys(keys)?;
            let connection = self.amazon_session(
                keys,
                crate::transport::OrdinaryContentPurpose::DestinationReadback,
            )?;
            let node = connection.node(self.ctx, &key.asset_id).await?;
            let path = format!("{}/amazon-{index}", self.directory("reconcile")?);
            let hash = connection.download(self.ctx, &node, &path).await?;
            if hash.signature != created.signature || hash.md5 != created.md5 {
                return Err(
                    "Amazon Photosの原本と転送記録が一致しません。元の原本は残します。".into(),
                );
            }
            self.check_keys(keys)?;
            self.persist_stage(JournalChange::AmazonVerified(created))
                .await?;
        }
        Ok(
            "Amazon Photosのアップロード結果を再取得して照合しました。書込みの再送はしていません。"
                .into(),
        )
    }
}
