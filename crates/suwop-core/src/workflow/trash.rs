use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, normalize_sha1},
    immich::{Asset, Session, valid_id},
    trash::{TrashAction, TrashIdentity, TrashItem, TrashOperation, TrashPrompt, TrashSnapshot},
};
use std::collections::BTreeSet;

impl Runtime<'_> {
    pub(super) async fn refresh_trash(&mut self, now: f64) -> Result<String, String> {
        if let Some(snapshot) = &mut self.state.trash {
            snapshot.verified = false;
        }
        self.ensure_session().await?;
        let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
        let items = session.list_trash(self.ctx, now).await?;
        self.state.trash = Some(TrashSnapshot {
            scope: session.scope.clone(),
            items,
            verified: true,
        });
        self.persist().await?;
        Ok("Immich の最近削除した項目を更新しました。".into())
    }

    pub(super) async fn change_trash(
        &mut self,
        keys: &[AssetKey],
        action: TrashAction,
        id: &str,
    ) -> Result<String, String> {
        valid_id(id)?;
        if self
            .state
            .pending_trash
            .iter()
            .any(|operation| operation.id == id)
        {
            return Err("この操作の結果を先に確認してください。".into());
        }
        self.ensure_session().await?;
        if self.check_keys(keys)? != Provider::Immich {
            return Err("通常のゴミ箱操作は Immich を対象にしてください。".into());
        }
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        session.supports_trash()?;
        let days = if action == TrashAction::Trash {
            Some(session.trash_retention(self.ctx).await?)
        } else {
            None
        };
        let assets = self.trash_selection(&session, keys, action).await?;
        let confirmed: bool = io(
            self.ctx,
            ShellOperation::ConfirmTrash {
                prompt: TrashPrompt {
                    action,
                    address: session.endpoint.clone(),
                    names: assets
                        .iter()
                        .map(|a| a.original_file_name.clone())
                        .collect(),
                    retention_days: days,
                },
            },
        )
        .await?;
        if !confirmed {
            return Ok("ゴミ箱の操作をキャンセルしました。".into());
        }
        if action == TrashAction::Trash && Some(session.trash_retention(self.ctx).await?) != days {
            return Err("ゴミ箱の保持設定が変わりました。操作を開始しません。".into());
        }
        let checked = self.trash_selection(&session, keys, action).await?;
        for (expected, fresh) in assets.iter().zip(&checked) {
            if fresh.is_trashed != (action == TrashAction::Restore)
                || fresh.updated_at != expected.updated_at
                || TrashIdentity::from_asset(&session.scope, fresh)?
                    != TrashIdentity::from_asset(&session.scope, expected)?
            {
                return Err("確認中に写真が変更されました。一覧を更新してください。".into());
            }
        }
        let operation = TrashOperation {
            id: id.into(),
            scope: session.scope.clone(),
            action,
            assets: assets
                .iter()
                .map(|asset| TrashIdentity::from_asset(&session.scope, asset))
                .collect::<Result<_, _>>()?,
        };
        // The durable pending record is a write fence. A timeout, cancellation, crash,
        // or failed readback leaves it in place and never schedules another mutation.
        let before = self.state.clone();
        self.invalidate(Provider::Immich);
        if let Some(trash) = &mut self.state.trash {
            trash.verified = false;
        }
        self.state.pending_trash.push(operation.clone());
        if let Err(error) = self.persist().await {
            self.state = before;
            return Err(error);
        }
        let ids: Vec<_> = assets.iter().map(|asset| asset.id.clone()).collect();
        match action {
            TrashAction::Trash => session.trash(self.ctx, &ids).await?,
            TrashAction::Restore => session.restore_selected(self.ctx, &ids).await?,
        }
        let fresh = self.verify_trash_result(&session, &operation).await?;
        self.finish_trash(&session, &operation, &fresh, Some(&before))
            .await?;
        Ok(match action {
            TrashAction::Trash => format!("{} 件を Immich のゴミ箱に移しました。", keys.len()),
            TrashAction::Restore => {
                format!("{} 件を Immich のゴミ箱から復元しました。", keys.len())
            }
        })
    }

    async fn trash_selection(
        &self,
        session: &Session,
        keys: &[AssetKey],
        action: TrashAction,
    ) -> Result<Vec<Asset>, String> {
        let mut selected = Vec::new();
        for key in keys {
            let asset = session.owned_asset(self.ctx, &key.asset_id).await?;
            if asset.is_trashed != (action == TrashAction::Restore) {
                return Err("写真の削除状態が変わりました。一覧を更新してください。".into());
            }
            let identity = TrashIdentity::from_asset(&session.scope, &asset)?;
            match action {
                TrashAction::Trash => {
                    let expected = self
                        .state
                        .snapshots
                        .iter()
                        .filter(|snapshot| {
                            snapshot.provider == Provider::Immich
                                && snapshot.scope == session.scope
                                && snapshot.access == ScanAccess::Full
                        })
                        .flat_map(|snapshot| &snapshot.assets)
                        .find(|a| a.key == *key)
                        .ok_or("選択した写真を一覧で確認できません。")?;
                    let original = expected
                        .resources
                        .iter()
                        .find(|resource| resource.id == key.asset_id && resource.role.is_original())
                        .ok_or("原本の識別情報がありません。")?;
                    let record = self.immich_record(&asset).await?;
                    if expected.revision != record.revision
                        || expected.name != asset.original_file_name
                        || normalize_sha1(original.sha1.as_deref()).as_ref()
                            != Some(&identity.checksum)
                    {
                        return Err("選択後に写真が変わりました。一覧を更新してください。".into());
                    }
                }
                TrashAction::Restore => {
                    let snapshot = self
                        .state
                        .trash
                        .as_ref()
                        .filter(|snapshot| snapshot.scope == session.scope && snapshot.verified)
                        .ok_or("Immich のゴミ箱を更新してください。")?;
                    let expected = snapshot
                        .items
                        .iter()
                        .find(|item| item.identity.key == *key)
                        .ok_or("選択した写真がゴミ箱一覧にありません。")?;
                    if expected.identity != identity
                        || expected.asset.revision
                            != asset.record(&session.scope, None, None).revision
                    {
                        return Err(
                            "選択後にゴミ箱の写真が変わりました。一覧を更新してください。".into(),
                        );
                    }
                }
            }
            selected.push(asset);
        }
        Ok(selected)
    }

    pub(super) async fn resolve_trash(&mut self, id: &str) -> Result<String, String> {
        let operation = self
            .state
            .pending_trash
            .iter()
            .find(|operation| operation.id == id)
            .cloned()
            .ok_or("確認する操作がありません。")?;
        self.ensure_session().await?;
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        self.validate_pending_trash(&session, &operation)?;
        let fresh = self.verify_trash_result(&session, &operation).await?;
        self.finish_trash(&session, &operation, &fresh, None)
            .await?;
        Ok("ゴミ箱の操作結果を読み取りで確認しました。一覧を更新してください。".into())
    }

    fn validate_pending_trash(
        &self,
        session: &Session,
        operation: &TrashOperation,
    ) -> Result<(), String> {
        valid_id(&operation.id)?;
        for identity in &operation.assets {
            valid_id(&identity.key.asset_id)?;
        }
        if self
            .state
            .pending_trash
            .iter()
            .filter(|pending| pending.id == operation.id)
            .count()
            != 1
        {
            return Err("操作の記録が重複または欠落しています。再送しません。".into());
        }
        if operation.scope != session.scope
            || operation.assets.is_empty()
            || operation.assets.iter().any(|asset| {
                asset.key.provider != Provider::Immich || asset.key.scope != session.scope
            })
            || operation
                .assets
                .iter()
                .map(|a| &a.key)
                .collect::<BTreeSet<_>>()
                .len()
                != operation.assets.len()
        {
            return Err("操作を開始した Immich アカウントに接続してください。".into());
        }
        Ok(())
    }

    async fn verify_trash_result(
        &self,
        session: &Session,
        operation: &TrashOperation,
    ) -> Result<Vec<Asset>, String> {
        self.validate_pending_trash(session, operation)?;
        let mut assets = Vec::new();
        for identity in &operation.assets {
            let asset = session
                .owned_asset(self.ctx, &identity.key.asset_id)
                .await?;
            if asset.is_trashed != (operation.action == TrashAction::Trash)
                || TrashIdentity::from_asset(&session.scope, &asset)? != *identity
            {
                return Err(
                    "操作の結果を確認できません。再送せず、後で結果を確認してください。".into(),
                );
            }
            assets.push(asset);
        }
        Ok(assets)
    }

    async fn finish_trash(
        &mut self,
        session: &Session,
        operation: &TrashOperation,
        fresh: &[Asset],
        before: Option<&crate::app::SavedLibrary>,
    ) -> Result<(), String> {
        let pending = self.state.clone();
        let mut records = Vec::new();
        if operation.action == TrashAction::Restore {
            for asset in fresh {
                records.push(self.immich_record(asset).await?);
            }
        }
        let changed: BTreeSet<_> = operation.assets.iter().map(|asset| &asset.key).collect();
        if let Some(before) = before {
            self.state.snapshots.clone_from(&before.snapshots);
        }
        for snapshot in &mut self.state.snapshots {
            if snapshot.provider == Provider::Immich && snapshot.scope == session.scope {
                snapshot
                    .assets
                    .retain(|asset| !changed.contains(&asset.key));
            }
        }
        if operation.action == TrashAction::Restore {
            if let Some(snapshot) = self
                .state
                .snapshots
                .iter_mut()
                .find(|s| s.provider == Provider::Immich && s.scope == session.scope)
            {
                snapshot.assets.extend(records);
            } else {
                self.state.snapshots.push(LibrarySnapshot {
                    provider: Provider::Immich,
                    scope: session.scope.clone(),
                    assets: records,
                    access: ScanAccess::Limited,
                    scanned_at: None,
                });
            }
        }
        if let Some(snapshot) = &mut self.state.trash {
            snapshot
                .items
                .retain(|item| !changed.contains(&item.identity.key));
            snapshot.verified = false;
        }
        if operation.action == TrashAction::Trash {
            let items: Vec<_> = fresh
                .iter()
                .map(|asset| {
                    Ok(TrashItem {
                        identity: TrashIdentity::from_asset(&session.scope, asset)?,
                        asset: asset.record(&session.scope, None, None),
                    })
                })
                .collect::<Result<_, String>>()?;
            if let Some(snapshot) = self
                .state
                .trash
                .as_mut()
                .filter(|s| s.scope == session.scope)
            {
                snapshot.items.extend(items);
            } else {
                self.state.trash = Some(TrashSnapshot {
                    scope: session.scope.clone(),
                    items,
                    verified: false,
                });
            }
        }
        self.state
            .pending_trash
            .retain(|pending| pending.id != operation.id);
        if let Err(error) = self.persist().await {
            self.state = pending;
            return Err(error);
        }
        Ok(())
    }
}
