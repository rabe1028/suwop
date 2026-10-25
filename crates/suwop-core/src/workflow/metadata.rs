use crate::{
    domain::{AssetKey, StoredAsset},
    metadata::{MetadataInput, prepare, verify},
    provider::{Ability, offers, unsupported},
};

use super::Runtime;

impl Runtime<'_> {
    pub(super) async fn change_metadata(
        &mut self,
        keys: &[AssetKey],
        input: &MetadataInput,
    ) -> Result<String, String> {
        if let Some(key) = keys
            .iter()
            .find(|key| !offers(key.provider, Ability::Metadata))
        {
            return Err(unsupported(key.provider, Ability::Metadata));
        }
        let (target, change) = prepare(
            &self.state.presentation_snapshots(),
            &self.state.receipts,
            keys,
            input,
        )?;
        self.ensure_connections([target.provider]).await?;
        self.check_keys(&target.keys)?;
        let registry = self.registry();
        let writer = registry
            .metadata(target.provider)
            .ok_or_else(|| registry.missing(target.provider, Ability::Metadata))?;
        let result: Result<Vec<StoredAsset>, String> = async {
            let fresh = writer
                .change_metadata(self.read_io(), &target.keys, &change)
                .await?;
            verify(&fresh, &target.keys, &change)?;
            Ok(fresh)
        }
        .await;
        match result {
            Ok(mut fresh) => {
                // Metadata changes do not produce a new transfer/deletion receipt.
                // Keep catalog identity for unchanged PhotoKit originals, while
                // fresh revisions invalidate the old deletion proof.
                self.preserve_original_fingerprints(&mut fresh);
                self.replace_records(fresh);
                if let Err(error) = self.persist().await {
                    self.invalidate(target.provider);
                    return Err(error);
                }
                Ok("選択した保存先の日時・位置情報を保存しました。".into())
            }
            Err(error) => {
                // A timeout or incomplete native response may follow a committed
                // write. Disable mutations until an explicit refresh, never retry.
                self.invalidate(target.provider);
                self.persist().await?;
                Err(error)
            }
        }
    }
}
