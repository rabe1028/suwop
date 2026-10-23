use std::collections::BTreeSet;

use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, ScanAccess, StoredAsset},
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
        if keys.iter().any(|k| k.provider == Provider::Immich) {
            self.ensure_session().await?;
        }
        let apple: Vec<_> = keys
            .iter()
            .filter(|k| k.provider == Provider::Apple)
            .cloned()
            .collect();
        let remote: Vec<_> = keys
            .iter()
            .filter(|k| k.provider == Provider::Immich)
            .cloned()
            .collect();
        let amazon: Vec<_> = keys
            .iter()
            .filter(|k| k.provider == Provider::Amazon)
            .cloned()
            .collect();
        // Validate both current libraries and access before the first write.
        for group in [&apple, &remote, &amazon]
            .into_iter()
            .filter(|g| !g.is_empty())
        {
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
        if !apple.is_empty() {
            let result = io(
                self.ctx,
                ShellOperation::AppleFavorite {
                    keys: apple.clone(),
                    value,
                },
            )
            .await;
            self.save_favorite_result(&apple, value, result).await?;
            self.progress("Apple Photos のお気に入りを保存しました。");
        }
        for key in &remote {
            let result = async {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                let asset = session.favorite(self.ctx, &key.asset_id, value).await?;
                Ok(vec![self.immich_record(&asset).await?])
            }
            .await;
            self.save_favorite_result(std::slice::from_ref(key), value, result)
                .await?;
            self.progress("Immich のお気に入りを保存しました。");
        }
        for key in &amazon {
            let connection = self.amazon_session(
                std::slice::from_ref(key),
                crate::immich::OrdinaryContentPurpose::Read,
            )?;
            let result = connection
                .favorite(self.ctx, &key.asset_id, value)
                .await
                .map(|record| vec![record]);
            self.save_favorite_result(std::slice::from_ref(key), value, result)
                .await?;
            self.progress("Amazon Photosのお気に入りを保存しました。");
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
