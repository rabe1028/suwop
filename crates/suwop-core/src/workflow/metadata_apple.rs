//! Native callback-owned readback. It is never a renewed write/read grant.
use super::{MetadataWitness, Runtime, same_originals, settle, witness};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset},
    metadata::{AppleMetadataMember, MetadataEdit, MetadataOutcome},
};

impl Runtime<'_> {
    pub(super) fn apple_metadata_witnesses(
        &self,
        keys: &[AssetKey],
        assets: Vec<StoredAsset>,
    ) -> Result<Vec<MetadataWitness>, String> {
        if assets.len() != keys.len() {
            return Err("保存先の全項目を確認できません。".into());
        }
        let mut result: Vec<MetadataWitness> = Vec::new();
        for asset in assets {
            if !keys.contains(&asset.key) || result.iter().any(|w| w.asset.key == asset.key) {
                return Err("異なる項目が返りました。".into());
            }
            let previous = self
                .state
                .metadata_operations
                .iter()
                .rev()
                .filter(|record| record.outcome == MetadataOutcome::VerifiedApplied)
                .flat_map(|record| &record.after)
                .find(|w| w.asset.key == asset.key);
            let description = previous.map_or_else(String::new, |w| w.values.description.clone());
            let zone = previous.and_then(|w| w.values.time_zone.clone());
            result.push(witness(asset, description, zone));
        }
        Ok(result)
    }

    pub(super) async fn apply_apple_metadata_batch(
        &self,
        keys: &[AssetKey],
        edits: &[MetadataEdit],
        before: Vec<MetadataWitness>,
        submitted: &mut bool,
    ) -> Result<Vec<MetadataWitness>, String> {
        self.check_keys(keys)?;
        let fresh = self.metadata_witnesses(keys).await?;
        super::same_witnesses(&before, &fresh)?;
        let members = keys
            .iter()
            .zip(edits)
            .map(|(key, edit)| {
                let original = before
                    .iter()
                    .find(|w| w.asset.key == *key)
                    .ok_or("変更前の項目がありません。")?;
                Ok(AppleMetadataMember {
                    before: original.asset.clone(),
                    change: edit.change()?.ok_or("ネイティブ変更内容がありません。")?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        *submitted = true;
        let assets: Vec<StoredAsset> = io(
            self.ctx,
            ShellOperation::AppleMetadataBatchVerified { members },
        )
        .await?;
        let observed = self.apple_metadata_witnesses(keys, assets)?;
        for (key, edit) in keys.iter().zip(edits) {
            let prior = before
                .iter()
                .find(|w| w.asset.key == *key)
                .ok_or("変更前の項目がありません。")?;
            let current = observed
                .iter()
                .find(|w| w.asset.key == *key)
                .ok_or("変更後の項目がありません。")?;
            same_originals(&prior.asset, &current.asset, edit)?;
            settle::unchanged_fields(&prior.values, &current.values, edit, Provider::Apple)?;
        }
        Ok(observed)
    }
}
