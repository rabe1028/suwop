use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset},
    metadata::{MetadataInput, prepare, verify},
};

use super::Runtime;

impl Runtime<'_> {
    pub(super) async fn change_metadata(
        &mut self,
        keys: &[AssetKey],
        input: &MetadataInput,
    ) -> Result<String, String> {
        let (target, change) = prepare(&self.state.snapshots, &self.state.receipts, keys, input)?;
        if target.provider == Provider::Immich {
            self.ensure_session().await?;
        }
        self.check_keys(&target.keys)?;
        let result: Result<Vec<StoredAsset>, String> = async {
            let fresh = if target.provider == Provider::Apple {
                io(
                    self.ctx,
                    ShellOperation::AppleMetadata {
                        keys: target.keys.clone(),
                        change: change.clone(),
                    },
                )
                .await?
            } else {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                let ids: Vec<_> = target.keys.iter().map(|k| k.asset_id.clone()).collect();
                let assets = session.metadata(self.ctx, &ids, &change).await?;
                let mut records = Vec::new();
                for asset in assets {
                    records.push(self.immich_record(&asset).await?);
                }
                records
            };
            verify(&fresh, &target.keys, &change)?;
            Ok(fresh)
        }
        .await;
        match result {
            Ok(fresh) => {
                // Metadata changes do not produce a new transfer/deletion receipt.
                // Fresh native records replace cached hashes; old revisions cannot
                // authorize deletion after an independent metadata change.
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
