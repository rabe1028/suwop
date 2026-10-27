//! Read-only completion of an already durably identified Apple creation.
use super::{AssetKey, ImportJournal, ImportPhase, Provider, Runtime, ShellOperation, io};
use crate::domain::{StoredAsset, TransferBundle};
use std::collections::BTreeSet;

impl Runtime<'_> {
    pub(super) async fn completed_apple_import_readback(
        &self,
        record: &ImportJournal,
    ) -> Result<TransferBundle, String> {
        self.check_ordinary_generation()?;
        if record.destination != Provider::Apple
            || record.phase != ImportPhase::Submitting
            || record.created != Some(true)
            || record.destination_keys.is_empty()
            || !self.state.external_imports.contains(record)
        {
            return Err("作成済みの取り込み記録を確認できません。".into());
        }
        let bundle: TransferBundle = io(
            self.ctx,
            ShellOperation::AppleImportReadback {
                operation: record.staging_operation.clone(),
                item_id: record.id.clone(),
                keys: record.destination_keys.clone(),
                directory: self.directory(&format!("import-verify-{}", record.id))?,
            },
        )
        .await?;
        bundle.validate()?;
        let keys: BTreeSet<&AssetKey> = bundle.assets.iter().map(|asset| &asset.key).collect();
        if keys != record.destination_keys.iter().collect()
            || bundle.assets.iter().any(|asset| !asset.content_visible())
        {
            return Err("作成した写真の原本または可視性が一致しません。".into());
        }
        // Protection/session invalidation remains fatal. Only the Apple catalog
        // notification may be crossed by these exact creation-owned facts.
        self.check_ordinary_generation()?;
        Ok(bundle)
    }

    pub(super) async fn save_completed_apple_import(
        &mut self,
        record: ImportJournal,
        assets: &[StoredAsset],
    ) -> Result<(), String> {
        self.check_ordinary_generation()?;
        if self
            .check_content_generation(&record.destination_keys)
            .is_ok()
        {
            return self.save_verified_import(record, assets).await;
        }
        // Persist completion, not a stale ordinary catalog projection. Subsequent
        // items still use the original generation and cannot acquire new writes.
        crate::app::invalidate_apple(&mut self.state);
        self.save_import(record).await
    }
}
