use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset},
    metadata::{MetadataEdit, MetadataOutcome, MetadataRecord, MetadataValues, MetadataWitness},
};

#[path = "metadata_apple.rs"]
mod apple;
#[path = "metadata_settle.rs"]
mod settle;

impl Runtime<'_> {
    async fn metadata_witnesses(&self, keys: &[AssetKey]) -> Result<Vec<MetadataWitness>, String> {
        self.check_keys(keys)?;
        let mut result = Vec::new();
        if keys
            .first()
            .is_some_and(|key| key.provider == Provider::Apple)
        {
            let assets: Vec<StoredAsset> = io(
                self.ctx,
                ShellOperation::AppleMetadataObserve {
                    keys: keys.to_vec(),
                },
            )
            .await?;
            result = self.apple_metadata_witnesses(keys, assets)?;
        } else {
            let session = self.session.as_ref().ok_or("Immichに接続してください。")?;
            for key in keys {
                let (asset, description, zone) = session
                    .metadata_observation(self.ctx, &key.asset_id)
                    .await?;
                let stored = self.immich_record(&asset).await?;
                if stored.key != *key {
                    return Err("写真のアカウントが変わりました。".into());
                }
                result.push(witness(stored, description, zone));
            }
        }
        Ok(result)
    }
    pub(super) async fn edit_metadata(
        &mut self,
        keys: &[AssetKey],
        edit: &MetadataEdit,
        id: &str,
        restores: Option<String>,
    ) -> Result<String, String> {
        self.edit_metadata_members(keys, edit, id, restores, None)
            .await
    }
    async fn edit_metadata_members(
        &mut self,
        keys: &[AssetKey],
        edit: &MetadataEdit,
        id: &str,
        restores: Option<String>,
        members: Option<Vec<MetadataEdit>>,
    ) -> Result<String, String> {
        let (provider, member_edits) = self.admit_metadata(keys, edit, id, members)?;
        self.ensure_connections([provider]).await?;
        let before = self.metadata_witnesses(keys).await?;
        if before.is_empty() {
            return Err("変更する項目がありません。".into());
        }
        self.admit_metadata_target(keys, edit)?;
        let record = MetadataRecord {
            id: id.into(),
            keys: keys.to_vec(),
            edit: edit.clone(),
            member_edits: member_edits.clone(),
            before: before.clone(),
            after: Vec::new(),
            outcome: MetadataOutcome::SubmittedUnknown,
            restores,
            current: Vec::new(),
        };
        self.state.metadata_operations.push(record.clone());
        self.persist().await?;
        // Only this private cursor can attest no provider submission occurred.
        let mut submitted = false;
        let applied = self
            .metadata_apply_after_intent(keys, &member_edits, provider, &before, &mut submitted)
            .await;
        let expected = match applied {
            Ok(expected) => expected,
            Err(error) => {
                if !submitted {
                    self.metadata_not_applied(id).await;
                }
                return Err(error);
            }
        };
        self.finish_metadata(keys, &member_edits, provider, record, expected)
            .await
    }
    async fn metadata_apply_after_intent(
        &mut self,
        keys: &[AssetKey],
        members: &[MetadataEdit],
        provider: Provider,
        before: &[MetadataWitness],
        submitted: &mut bool,
    ) -> Result<Vec<MetadataWitness>, String> {
        self.check_keys(keys)?;
        let current = self.metadata_witnesses(keys).await?;
        same_witnesses(before, &current)?;
        self.apply_metadata_members(keys, members, provider, current, submitted)
            .await
    }
    async fn metadata_not_applied(&mut self, id: &str) {
        let Some(index) = self
            .state
            .metadata_operations
            .iter()
            .position(|record| record.id == id)
        else {
            return;
        };
        self.state.metadata_operations[index].outcome = MetadataOutcome::NotApplied;
        if self.persist().await.is_err() && !self.metadata_commit_readback(index).await {
            self.state.metadata_operations[index].outcome = MetadataOutcome::SubmittedUnknown;
        }
    }
    async fn finish_metadata(
        &mut self,
        keys: &[AssetKey],
        member_edits: &[MetadataEdit],
        provider: Provider,
        mut record: MetadataRecord,
        expected: Vec<MetadataWitness>,
    ) -> Result<String, String> {
        let id = record.id.clone();
        let edit = record.edit.clone();
        let mut after = if provider == Provider::Immich {
            settle::after_write(self, keys, expected, member_edits).await?
        } else if matches!(member_edits.first(), Some(MetadataEdit::Description { .. })) {
            let after = self.metadata_witnesses(keys).await?;
            same_witnesses(&expected, &after)?;
            after
        } else {
            // The one native transaction already freshly read every selected
            // member after its real callback. A PhotoObserver notification may
            // invalidate the old presentation epoch, never these owned facts.
            expected
        };
        if provider == Provider::Apple {
            for item in &mut after {
                let index = keys
                    .iter()
                    .position(|key| key == &item.asset.key)
                    .ok_or("項目が変わりました。")?;
                let member = &member_edits[index];
                if let MetadataEdit::Description { text } = member {
                    item.values.description.clone_from(text);
                }
                if let MetadataEdit::CapturedAt { zone, .. } = member {
                    item.values.time_zone = Some(zone.clone());
                }
            }
        }
        for item in &after {
            let index = keys
                .iter()
                .position(|key| key == &item.asset.key)
                .ok_or("項目が変わりました。")?;
            if !member_edits[index].matches_provider(provider, &item.values)? {
                return Err(
                    "変更結果を確認できません。再送せず現在の状態を確認してください。".into(),
                );
            }
        }
        record.after = after.clone();
        record.outcome = MetadataOutcome::VerifiedApplied;
        let index = self
            .state
            .metadata_operations
            .iter()
            .position(|item| item.id == id)
            .ok_or("変更記録がありません。")?;
        self.state.metadata_operations[index] = record;
        let mut assets: Vec<StoredAsset> = after.into_iter().map(|w| w.asset).collect();
        self.preserve_original_fingerprints(&mut assets);
        self.replace_records(assets);
        if let Err(error) = self.persist().await
            && !self.metadata_commit_readback(index).await
        {
            self.state.metadata_operations[index].outcome = MetadataOutcome::SubmittedUnknown;
            self.state.metadata_operations[index].after.clear();
            return Err(error);
        }
        Ok(
            if provider == Provider::Apple && matches!(edit, MetadataEdit::Description { .. }) {
                "アプリ内の説明を保存しました。Photosのキャプションには同期しません。"
            } else {
                "メタデータの保存結果を再取得して確認しました。"
            }
            .into(),
        )
    }
    async fn metadata_commit_readback(&mut self, index: usize) -> bool {
        let read: Result<serde_json::Value, String> =
            io(self.ctx, ShellOperation::ReadStateVersioned).await;
        let Ok(read) = read else {
            return false;
        };
        let Some(raw) = read.get("state").filter(|value| !value.is_null()) else {
            return false;
        };
        let Ok(state) = super::migrate(raw.clone()) else {
            return false;
        };
        let desired = &self.state.metadata_operations[index];
        let Some(durable) = state
            .metadata_operations
            .iter()
            .find(|record| record.id == desired.id)
        else {
            return false;
        };
        let mut expected = desired.clone();
        expected.current.clone_from(&durable.current);
        let (Ok(expected), Ok(actual)) = (
            serde_json::to_value(expected),
            serde_json::to_value(durable),
        ) else {
            return false;
        };
        if expected != actual {
            return false;
        }
        self.state.metadata_operations = state.metadata_operations;
        true
    }
    fn admit_metadata(
        &self,
        keys: &[AssetKey],
        edit: &MetadataEdit,
        id: &str,
        members: Option<Vec<MetadataEdit>>,
    ) -> Result<(Provider, Vec<MetadataEdit>), String> {
        crate::immich::valid_id(id)?;
        if self
            .state
            .metadata_operations
            .iter()
            .any(|record| record.id == id)
        {
            return Err("この変更IDは既に記録されています。再送しません。".into());
        }
        if self.state.metadata_operations.iter().any(|record| {
            record.outcome == MetadataOutcome::SubmittedUnknown
                && record.keys.iter().any(|key| keys.contains(key))
        }) {
            return Err("結果不明のメタデータ操作があります。暗黙に再送しません。".into());
        }
        let member_edits = members.unwrap_or_else(|| vec![edit.clone(); keys.len()]);
        if member_edits.len() != keys.len() {
            return Err("復元する項目の数が一致しません。".into());
        }
        for member in &member_edits {
            member.change()?;
            if std::mem::discriminant(member) != std::mem::discriminant(edit)
                && !matches!(
                    (member, edit),
                    (MetadataEdit::RemoveLocation, MetadataEdit::Location { .. })
                        | (MetadataEdit::Location { .. }, MetadataEdit::RemoveLocation)
                )
            {
                return Err("復元する情報の種類が一致しません。".into());
            }
        }
        let provider = self.check_keys(keys)?;
        if provider == Provider::Amazon {
            return Err("この保存先のメタデータ変更経路は提供されていません。".into());
        }
        if provider == Provider::Immich {
            for member in &member_edits {
                if let Some(change) = member.change()? {
                    change.immich_fields()?;
                }
            }
        }
        Ok((provider, member_edits))
    }
    fn admit_metadata_target(&self, keys: &[AssetKey], edit: &MetadataEdit) -> Result<(), String> {
        // Reuse the canonical complete provider/scope grouping admission.
        if let Some(change) = &edit.change()? {
            let input = crate::metadata::MetadataInput {
                action: change.action,
                captured_at: change.captured_at,
                time_zone: change.time_zone.clone(),
                latitude: change.location.as_ref().map(|p| p.latitude.to_string()),
                longitude: change.location.as_ref().map(|p| p.longitude.to_string()),
            };
            crate::metadata::prepare(
                &self.state.presentation_snapshots(),
                &self.state.receipts,
                keys,
                &input,
            )?;
        } else {
            let grouped = crate::display_catalog::photos(
                &self.state.presentation_snapshots(),
                &self.state.receipts,
            );
            let target = grouped
                .iter()
                .flat_map(|photo| {
                    crate::metadata::targets(photo, &self.state.presentation_snapshots())
                })
                .find(|target| target.keys == keys)
                .ok_or("写真の構成が変わりました。")?;
            if let Some(reason) = target.disabled_reason {
                return Err(reason);
            }
        }
        Ok(())
    }
    async fn apply_metadata_members(
        &mut self,
        keys: &[AssetKey],
        member_edits: &[MetadataEdit],
        provider: Provider,
        current: Vec<MetadataWitness>,
        submitted: &mut bool,
    ) -> Result<Vec<MetadataWitness>, String> {
        if provider == Provider::Apple
            && !matches!(member_edits.first(), Some(MetadataEdit::Description { .. }))
        {
            return self
                .apply_apple_metadata_batch(keys, member_edits, current, submitted)
                .await;
        }
        let mut expected = current;
        for (key, member) in keys.iter().zip(member_edits) {
            self.check_keys(keys)?;
            let fresh = self.metadata_witnesses(keys).await?;
            same_witnesses(&expected, &fresh)?;
            if let MetadataEdit::Description { text } = member {
                if provider == Provider::Immich {
                    *submitted = true;
                    self.session
                        .as_ref()
                        .ok_or("接続がありません。")?
                        .write_description(self.ctx, &key.asset_id, text)
                        .await?;
                }
            } else if let Some(change) = member.change()? {
                let registry = self.registry();
                let writer = registry
                    .metadata(provider)
                    .ok_or("変更経路がありません。")?;
                *submitted = true;
                writer
                    .change_metadata(self.read_io(), std::slice::from_ref(key), &change)
                    .await?;
            }
            let observed = self.metadata_witnesses(keys).await?;
            let prior = expected
                .iter()
                .find(|item| item.asset.key == *key)
                .ok_or("変更前の項目がありません。")?;
            let current = observed
                .iter()
                .find(|item| item.asset.key == *key)
                .ok_or("変更後の項目がありません。")?;
            same_originals(&prior.asset, &current.asset, member)?;
            settle::unchanged_fields(&prior.values, &current.values, member, provider)?;
            for other in expected.iter().filter(|item| item.asset.key != *key) {
                let current = observed
                    .iter()
                    .find(|item| item.asset.key == other.asset.key)
                    .ok_or("項目が変わりました。")?;
                same_witnesses(std::slice::from_ref(other), std::slice::from_ref(current))?;
            }
            expected = observed;
        }
        Ok(expected)
    }
    pub(super) async fn inspect_metadata(&mut self, operation_id: &str) -> Result<String, String> {
        let index = self
            .state
            .metadata_operations
            .iter()
            .position(|record| record.id == operation_id)
            .ok_or("変更記録がありません。")?;
        let keys = self.state.metadata_operations[index].keys.clone();
        let provider = self.check_keys(&keys)?;
        self.ensure_connections([provider]).await?;
        let mut observations = Vec::new();
        for key in &keys {
            self.check_keys(&keys)?;
            let witness = self
                .metadata_witnesses(std::slice::from_ref(key))
                .await
                .ok()
                .and_then(|items| items.into_iter().next());
            observations.push(crate::metadata::MetadataObservation {
                key: key.clone(),
                unavailable: witness.is_none(),
                witness,
            });
        }
        self.state.metadata_operations[index].current = observations;
        self.persist().await?;
        Ok(
            "現在のメタデータを記録しました。過去の結果不明は変更せず、書込みも再送しません。"
                .into(),
        )
    }
    pub(super) async fn restore_metadata(
        &mut self,
        id: &str,
        operation_id: &str,
        original: bool,
    ) -> Result<String, String> {
        let record = self
            .state
            .metadata_operations
            .iter()
            .find(|record| record.id == operation_id)
            .cloned()
            .ok_or("変更記録がありません。")?;
        let edits =
            crate::metadata::restore_edits(&self.state.metadata_operations, &record, original)?;
        let now = self.metadata_witnesses(&record.keys).await?;
        same_witnesses(&record.after, &now)?;
        let first = edits.first().ok_or("元の値がありません。")?.clone();
        self.edit_metadata_members(&record.keys, &first, id, Some(record.id), Some(edits))
            .await
    }
}
fn witness(asset: StoredAsset, description: String, time_zone: Option<String>) -> MetadataWitness {
    let values = MetadataValues {
        captured_at: asset.captured_at,
        time_zone,
        latitude: asset.latitude,
        longitude: asset.longitude,
        description,
    };
    MetadataWitness { asset, values }
}
fn same_witnesses(expected: &[MetadataWitness], actual: &[MetadataWitness]) -> Result<(), String> {
    if expected.len() != actual.len()
        || expected.iter().any(|old| {
            actual
                .iter()
                .find(|new| new.asset.key == old.asset.key)
                .is_none_or(|new| serde_json::to_value(old).ok() != serde_json::to_value(new).ok())
        })
    {
        return Err("写真またはメタデータが変更されています。古い値を上書きしません。".into());
    }
    Ok(())
}

fn same_originals(
    before: &StoredAsset,
    after: &StoredAsset,
    edit: &MetadataEdit,
) -> Result<(), String> {
    let mut expected = before.clone();
    expected.revision.clone_from(&after.revision);
    expected.modified_at = after.modified_at;
    match edit {
        MetadataEdit::CapturedAt { .. } => expected.captured_at = after.captured_at,
        MetadataEdit::Location { .. } | MetadataEdit::RemoveLocation => {
            expected.latitude = after.latitude;
            expected.longitude = after.longitude;
        }
        MetadataEdit::Description { .. } => {}
    }
    if expected != *after {
        return Err("指定したメタデータ以外の原本・関連資源・写真の状態が変わりました。".into());
    }
    Ok(())
}
