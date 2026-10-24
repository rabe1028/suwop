use std::collections::BTreeSet;

use crate::{
    domain::{AssetKey, Provider, ScanAccess, StoredAsset},
    provider::{Ability, PROVIDERS},
};

use super::Runtime;

impl Runtime<'_> {
    pub(super) async fn favorite(
        &mut self,
        keys: &[AssetKey],
        value: bool,
    ) -> Result<String, String> {
        let keys: BTreeSet<_> = keys.iter().cloned().collect();
        if keys.is_empty() {
            return Err("写真を選択してください。".into());
        }
        self.ensure_connections(keys.iter().map(|k| k.provider))
            .await?;
        let groups: Vec<(Provider, Vec<AssetKey>)> = PROVIDERS
            .into_iter()
            .map(|provider| {
                let group = keys
                    .iter()
                    .filter(|k| k.provider == provider)
                    .cloned()
                    .collect::<Vec<_>>();
                (provider, group)
            })
            .filter(|(_, group)| !group.is_empty())
            .collect();
        // Validate every current library and access before the first write.
        for (_, group) in &groups {
            self.check_keys(group)?;
        }
        if keys.iter().any(|key| {
            !self.state.snapshots.iter().any(|s| {
                s.access == ScanAccess::Full
                    && s.provider == key.provider
                    && s.scope == key.scope
                    && s.assets.iter().any(|a| a.key == *key)
            })
        }) {
            return Err(
                "選択した写真を確認できません。一覧とアクセス権を確認してください。".into(),
            );
        }
        // Every selected library must offer the ability before the first write.
        let registry = self.registry();
        let mut writers = Vec::new();
        for (provider, group) in &groups {
            let writer = registry
                .favorites(*provider)
                .ok_or_else(|| registry.missing(*provider, Ability::Favorite))?;
            writers.push((writer, group));
        }
        for (writer, group) in writers {
            for batch in group.chunks(writer.batch_size().max(1)) {
                let result = writer.set_favorite(self.read_io(), batch, value).await;
                self.save_favorite_result(batch, value, result).await?;
                self.progress(writer.saved_status());
            }
        }
        Ok(format!("{} 件のお気に入りを変更しました。", keys.len()))
    }

    async fn save_favorite_result(
        &mut self,
        keys: &[AssetKey],
        value: bool,
        result: Result<Vec<StoredAsset>, String>,
    ) -> Result<(), String> {
        let provider = self.check_keys(keys)?;
        let result = result.and_then(|fresh| {
            let returned: BTreeSet<_> = fresh.iter().map(|a| &a.key).collect();
            if fresh.len() != keys.len()
                || returned.len() != fresh.len()
                || returned != keys.iter().collect()
                || fresh.iter().any(|a| a.is_favorite != value)
            {
                return Err(
                    "お気に入りの保存結果を確認できません。一覧を更新してください。".into(),
                );
            }
            Ok(fresh)
        });
        match result {
            Ok(mut fresh) => {
                // Only a verified property write can retain immutable-original
                // fingerprints; the new native revision is always kept.
                self.preserve_original_fingerprints(&mut fresh);
                self.replace_records(fresh);
                if let Err(error) = self.persist().await {
                    self.invalidate(provider);
                    return Err(error);
                }
                Ok(())
            }
            Err(error) => {
                // A lost response may follow a committed write. Do not retry
                // automatically or permit another change against stale state.
                self.invalidate(provider);
                self.persist().await?;
                Err(error)
            }
        }
    }
}
