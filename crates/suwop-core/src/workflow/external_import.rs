//! Staged-file import and explicit duplication. These operations never create
//! transfer receipts, so neither can authorize source deletion.
use super::{Runtime, ShellOperation, io};
use crate::{
    domain::{AssetKey, Provider},
    external_import::{ImportItem, ImportJournal, ImportPhase, ImportPurpose},
    sharing::ShareFile,
};

mod apple_completion;
mod immich;
mod lifecycle;
#[cfg(test)]
mod tests;

impl Runtime<'_> {
    pub(super) async fn import_staged(
        &mut self,
        id: &str,
        destination: Provider,
        items: Vec<ImportItem>,
        now: f64,
    ) -> Result<(), String> {
        self.import_items(id, destination, items, ImportPurpose::External, &[], now)
            .await
    }

    pub(super) async fn duplicate(
        &mut self,
        keys: &[AssetKey],
        destination: Provider,
        current: bool,
        id: &str,
        now: f64,
    ) -> Result<(), String> {
        // One physical asset owns one metadata set and may contain multiple
        // originals (RAW+JPEG / Live). Never merge unrelated source keys or
        // spread the first asset's metadata over independent photos.
        if keys.len() != 1 {
            return Err("複製する表示元の写真を一つ選択してください。".into());
        }
        self.check_keys(keys)?;
        self.ensure_connections(keys.iter().map(|key| key.provider).chain([destination]))
            .await?;
        self.workspace(id).await?;
        let files = if current {
            if keys.len() != 1 {
                return Err("現在の見た目を複製する表示元を一つ選択してください。".into());
            }
            self.export_current_media(&keys[0], 0, false).await?
        } else {
            let bundle = self.export(keys, "duplicate-originals").await?;
            self.check_transfer_trash(&bundle.assets)?;
            bundle
                .files
                .into_iter()
                .map(|file| ShareFile {
                    path: file.path,
                    name: file.resource.name,
                })
                .collect()
        };
        self.check_content_keys(keys)?;
        let mut items: Vec<ImportItem> = io(
            self.ctx,
            ShellOperation::StageImportFiles {
                operation: id.into(),
                files,
            },
        )
        .await?;
        // A selected catalog photo supplies an explicit logical grouping;
        // external file selection never guesses a RAW pair from its filename.
        if !current && items.len() == 2 && items.iter().all(|item| item.resources.len() == 1) {
            let roles: Vec<_> = items.iter().map(|item| item.resources[0].role).collect();
            if roles.contains(&crate::domain::ResourceRole::Image)
                && roles.contains(&crate::domain::ResourceRole::RawImage)
            {
                let second = items.pop().ok_or("原本がありません。")?;
                items[0].resources.extend(second.resources);
            }
        }
        if let Some(source) = self
            .state
            .snapshots
            .iter()
            .flat_map(|snapshot| &snapshot.assets)
            .find(|asset| keys.contains(&asset.key))
        {
            for item in &mut items {
                item.metadata.captured_at = source.captured_at.map(crate::immich::date_string);
                item.metadata.latitude = source.latitude;
                item.metadata.longitude = source.longitude;
                item.metadata.favorite = source.is_favorite;
            }
        }
        let purpose = if current {
            ImportPurpose::DuplicateCurrent
        } else {
            ImportPurpose::DuplicateOriginal
        };
        self.import_items(id, destination, items, purpose, keys, now)
            .await
    }

    async fn import_items(
        &mut self,
        id: &str,
        destination: Provider,
        items: Vec<ImportItem>,
        purpose: ImportPurpose,
        sources: &[AssetKey],
        now: f64,
    ) -> Result<(), String> {
        if items.is_empty() || items.len() > 100 {
            return Err("取り込む写真を1〜100件選択してください。".into());
        }
        if self
            .state
            .external_imports
            .iter()
            .any(|entry| entry.staging_operation == id)
        {
            return Err("開始済みの取り込みです。記録から保存結果を確認してください。".into());
        }
        if destination == Provider::Amazon {
            return Err(
                "外部ファイルの取り込み先には Apple Photos または Immich を選択してください。"
                    .into(),
            );
        }
        self.ensure_connections([destination]).await?;
        let scope = match destination {
            Provider::Apple => self.state.apple_scope.clone(),
            Provider::Immich => self
                .session
                .as_ref()
                .ok_or("Immich に接続してください。")?
                .scope
                .clone(),
            Provider::Amazon => unreachable!(),
        };
        let mut records = Vec::new();
        let mut item_ids = std::collections::BTreeSet::new();
        let mut tokens = std::collections::BTreeSet::new();
        for item in items {
            if !item_ids.insert(item.id.clone())
                || item
                    .resources
                    .iter()
                    .any(|r| !tokens.insert(r.token.clone()))
            {
                return Err("同じファイルが複数の写真構成に含まれています。".into());
            }
            let record = ImportJournal {
                id: item.id.clone(),
                staging_operation: id.into(),
                created_at: now,
                purpose,
                destination,
                destination_scope: scope.clone(),
                source_keys: sources.to_vec(),
                item,
                phase: ImportPhase::Prepared,
                destination_keys: Vec::new(),
                created: None,
            };
            record.validate()?;
            // Resolve each token before any persistent or remote change.
            for resource in &record.item.resources {
                let _: String = io(
                    self.ctx,
                    ShellOperation::ResolveImportResource {
                        operation: id.into(),
                        resource: resource.clone(),
                    },
                )
                .await?;
            }
            records.push(record);
        }
        let previous = self.state.external_imports.clone();
        self.state.external_imports.extend(records.clone());
        if let Err(error) = self.persist().await {
            self.state.external_imports = previous;
            return Err(error);
        }
        for record in records {
            if let Err(error) = self.submit_import_record(&record).await {
                // Only Prepared proves that native submission was never authorized.
                // Preserve uncertain attempts and their staged bytes unchanged.
                self.cancel_prepared_imports(id).await?;
                self.release_terminal_import_staging(id).await?;
                return Err(error);
            }
        }
        self.release_terminal_import_staging(id).await
    }

    async fn submit_import_record(&mut self, record: &ImportJournal) -> Result<(), String> {
        if !record.source_keys.is_empty() {
            self.check_content_keys(&record.source_keys)?;
        }
        // An earlier creation may have retired this batch's Apple authority.
        let mut authority_keys = record.source_keys.clone();
        if record.destination == Provider::Apple {
            authority_keys.push(AssetKey {
                provider: Provider::Apple,
                scope: record.destination_scope.clone(),
                asset_id: String::new(),
            });
        }
        self.check_content_generation(&authority_keys)?;
        let submitting = record.prepare_submission()?;
        self.save_import(submitting.clone()).await?;
        let permit = record.submission_after_save(&submitting)?;
        let result = self.submit_import(&submitting).await;
        match result {
            Ok((keys, hashes, created, assets)) => match permit.verified(keys, hashes, created) {
                Ok(finished) => {
                    if finished.destination == Provider::Apple {
                        self.save_completed_apple_import(finished, &assets).await?;
                    } else {
                        self.save_verified_import(finished, &assets).await?;
                    }
                }
                Err(error) => {
                    self.mark_import_uncertain(&record.id).await?;
                    return Err(error);
                }
            },
            Err(error) => {
                drop(permit);
                self.mark_import_uncertain(&record.id).await?;
                return Err(error);
            }
        }
        Ok(())
    }

    async fn mark_import_uncertain(&mut self, id: &str) -> Result<(), String> {
        let latest = self
            .state
            .external_imports
            .iter()
            .find(|entry| entry.id == id)
            .ok_or("取り込み記録がありません。")?
            .recover();
        self.save_import(latest).await
    }

    async fn save_import(&mut self, record: ImportJournal) -> Result<(), String> {
        let slot = self
            .state
            .external_imports
            .iter_mut()
            .find(|entry| entry.id == record.id)
            .ok_or("取り込み記録がありません。")?;
        let previous = std::mem::replace(slot, record.clone());
        if let Err(error) = self.persist().await {
            if let Some(slot) = self
                .state
                .external_imports
                .iter_mut()
                .find(|entry| entry.id == record.id)
            {
                *slot = previous;
            }
            return Err(error);
        }
        Ok(())
    }

    async fn save_verified_import(
        &mut self,
        record: ImportJournal,
        assets: &[crate::domain::StoredAsset],
    ) -> Result<(), String> {
        self.check_ordinary_generation()?;
        if !record.source_keys.is_empty() {
            self.check_content_keys(&record.source_keys)?;
        }
        let previous_snapshots = self.state.snapshots.clone();
        self.publish_copies(
            record.destination,
            &record.destination_scope,
            assets,
            record.created_at,
        );
        if let Err(error) = self.save_import(record).await {
            self.state.snapshots = previous_snapshots;
            return Err(error);
        }
        Ok(())
    }

    async fn submit_import(
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
        self.check_ordinary_generation()?;
        if !record.source_keys.is_empty() {
            self.check_content_keys(&record.source_keys)?;
        }
        match record.destination {
            Provider::Apple => {
                let keys: Vec<AssetKey> = io(
                    self.ctx,
                    ShellOperation::AppleImportStaged {
                        operation: record.staging_operation.clone(),
                        item: record.item.clone(),
                        scope: record.destination_scope.clone(),
                    },
                )
                .await?;
                let mut partial = record.clone();
                partial.destination_keys = keys.clone();
                partial.created = Some(true);
                self.save_import(partial.clone()).await?;
                if self.workspace.is_none() {
                    self.workspace(&record.staging_operation).await?;
                }
                let bundle = self.completed_apple_import_readback(&partial).await?;
                verify_import_metadata(record, &bundle.assets)?;
                let hashes = bundle
                    .files
                    .into_iter()
                    .map(|f| f.signature.sha256)
                    .collect();
                Ok((keys, hashes, true, bundle.assets))
            }
            Provider::Immich => self.import_immich_item(record).await,
            Provider::Amazon => Err("この保存先は外部取り込みに対応していません。".into()),
        }
    }
}

fn verify_import_metadata(
    record: &ImportJournal,
    assets: &[crate::domain::StoredAsset],
) -> Result<(), String> {
    if assets.is_empty() {
        return Err("取り込み先の情報を確認できません。".into());
    }
    let metadata = &record.item.metadata;
    let expected_date = metadata
        .captured_at
        .as_deref()
        .and_then(crate::immich::parse_date);
    for asset in assets {
        if expected_date.is_some_and(|expected| {
            asset
                .captured_at
                .is_none_or(|actual| !crate::domain::same_capture_date(actual, expected))
        }) || asset.is_favorite != metadata.favorite
        {
            return Err("撮影日時またはお気に入りの保存結果を確認できません。".into());
        }
        if let (Some(lat), Some(lon)) = (metadata.latitude, metadata.longitude)
            && (asset
                .latitude
                .is_none_or(|value| (value - lat).abs() > 0.000_01)
                || asset
                    .longitude
                    .is_none_or(|value| (value - lon).abs() > 0.000_01))
        {
            return Err("位置情報の保存結果を確認できません。".into());
        }
    }
    Ok(())
}

impl Runtime<'_> {
    fn check_import_inspection_access(&self, record: &ImportJournal) -> Result<(), String> {
        let current_scope = match record.destination {
            Provider::Apple => Some(self.state.apple_scope.as_str()),
            Provider::Immich => self.session.as_ref().map(|s| s.scope.as_str()),
            Provider::Amazon => None,
        };
        if current_scope != Some(record.destination_scope.as_str()) {
            return Err("取り込み先アカウントが変わっています。".into());
        }
        if !record.source_keys.is_empty() {
            self.check_content_keys(&record.source_keys)?;
        }
        let access = crate::privacy::ContentAccess::new(&self.state);
        if record.destination_keys.iter().any(|key| {
            access.protected(key)
                || self
                    .state
                    .apple_visibility_operations
                    .iter()
                    .any(|o| o.fences(key))
        }) {
            return Err("保護された保存結果は通常の取り込み記録から確認できません。".into());
        }
        Ok(())
    }

    pub(super) async fn inspect_import(&mut self, id: &str) -> Result<(), String> {
        let record = self
            .state
            .external_imports
            .iter()
            .find(|entry| entry.id == id)
            .cloned()
            .ok_or("取り込み記録がありません。")?
            .recover();
        if record.phase != ImportPhase::Uncertain
            || record.created.is_none()
            || record.destination_keys.is_empty()
        {
            return Err("保存先IDまたは作成応答が不明です。自動再送信せず、保存先のライブラリで確認してください。".into());
        }
        self.ensure_connections([record.destination]).await?;
        self.check_import_inspection_access(&record)?;
        let keys = if record.destination == Provider::Immich
            && record
                .item
                .resources
                .iter()
                .any(|r| r.role == crate::domain::ResourceRole::LiveVideo)
        {
            record
                .destination_keys
                .iter()
                .skip(1)
                .cloned()
                .collect::<Vec<_>>()
        } else {
            record.destination_keys.clone()
        };
        if self.workspace.is_none() {
            self.workspace(&record.staging_operation).await?;
        }
        let bundle = self
            .export_readback(&keys, &format!("reconcile-import-{}", record.id))
            .await?;
        if record.created == Some(true) {
            verify_import_metadata(&record, &bundle.assets)?;
            if record.destination == Provider::Immich
                && record.item.resources.len() == 2
                && record
                    .item
                    .resources
                    .iter()
                    .any(|resource| resource.role == crate::domain::ResourceRole::RawImage)
            {
                let memberships: Vec<_> = bundle
                    .assets
                    .iter()
                    .map(|asset| asset.immich_stack_membership.as_ref())
                    .collect();
                let first = memberships
                    .first()
                    .and_then(|value| *value)
                    .ok_or("RAW＋JPEG の関連付けを確認できません。")?;
                if first.asset_count != 2
                    || memberships
                        .iter()
                        .any(|member| member.is_none_or(|value| value.id != first.id))
                {
                    return Err("RAW＋JPEG が同じスタックにありません。".into());
                }
            }
        }
        let finished = record.reconcile(
            bundle
                .files
                .into_iter()
                .map(|file| file.signature.sha256)
                .collect(),
        )?;
        self.save_verified_import(finished, &bundle.assets).await?;
        if self
            .state
            .external_imports
            .iter()
            .filter(|entry| entry.staging_operation == record.staging_operation)
            .all(|entry| !entry.retains_staged_bytes())
        {
            let _: serde_json::Value = io(
                self.ctx,
                ShellOperation::ReleaseImportStaging {
                    operation: record.staging_operation,
                },
            )
            .await?;
        }
        Ok(())
    }
}
