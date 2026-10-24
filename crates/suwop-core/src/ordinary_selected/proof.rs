use crate::{
    app::{Model, SavedLibrary},
    domain::{AssetKey, Provider, ResourceRole, StoredAsset},
    immich::Session,
    immich_visibility::{
        ImmichVisibility, ImmichVisibilityOperation, ImmichVisibilityOperationKind,
        SelectedConfiguration, SelectedVisibilityObservation,
    },
};
use serde_json::Value;
#[derive(Debug, Clone)]
pub(crate) struct VerifiedPresentation {
    pub proof_id: String,
    pub asset: StoredAsset,
    pub observation: SelectedVisibilityObservation,
    records: Vec<ImmichVisibilityOperation>,
    pub scope: String,
    pub owner: String,
    pub generation: u64,
}
impl VerifiedPresentation {
    pub(crate) fn from_fresh(
        raw: &Value,
        state: &SavedLibrary,
        session: &Session,
        generation: u64,
    ) -> Result<Self, String> {
        let key = AssetKey {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            asset_id: raw["id"].as_str().ok_or("写真を確認できません。")?.into(),
        };
        if crate::immich_live_writes::fences(state, &key) {
            return Err("Live Photo の変更記録を確認してください。".into());
        }
        let records = state
            .immich_visibility_operations
            .iter()
            .filter(|o| o.key == key)
            .cloned()
            .collect::<Vec<_>>();
        let original = records
            .iter()
            .find(|o| {
                o.kind == ImmichVisibilityOperationKind::LockedTransition
                    && o.selected_observation
                        .as_ref()
                        .is_some_and(|s| s.configuration != SelectedConfiguration::Unverified)
            })
            .ok_or("確認記録がありません。")?;
        let facts = crate::immich_visibility::selected_facts(raw, original, &session.user_id)?;
        if facts.observation.visibility == ImmichVisibility::Locked
            || facts.observation.configuration == SelectedConfiguration::Unverified
        {
            return Err("現在の表示先を確認できません。".into());
        }
        for record in &records {
            match record.kind {
                ImmichVisibilityOperationKind::LockedTransition => {
                    let own =
                        crate::immich_visibility::selected_facts(raw, record, &session.user_id)?;
                    if own.observation.selected_identity_digest
                        != facts.observation.selected_identity_digest
                    {
                        return Err("原本が一致しません。".into());
                    }
                    if let Some(saved) = &record.selected_observation
                        && (saved.configuration == SelectedConfiguration::Unverified
                            || saved.selected_identity_digest
                                != own.observation.selected_identity_digest)
                    {
                        return Err("原本の記録を確認できません。".into());
                    }
                    // The known historical IMAGE encoding above proves own identity;
                    // its old null graph is never asserted as current graph state.
                }
                ImmichVisibilityOperationKind::OrdinaryArchive => {
                    let matching_policy = crate::immich_visibility::ordinary_facts(
                        raw,
                        &session.scope,
                        &session.user_id,
                    )
                    .is_ok_and(|facts| facts.witness == record.witness_digest);
                    if !matching_policy
                        && !crate::immich_visibility::matches_original_image_identity(
                            raw,
                            record,
                            &session.scope,
                            &session.user_id,
                        )?
                    {
                        return Err("原本の記録が一致しません。".into());
                    }
                }
            }
        }
        let mut asset = facts.asset;
        asset.resources.retain(|r| {
            r.id == key.asset_id && matches!(r.role, ResourceRole::Image | ResourceRole::RawImage)
        });
        if asset.resources.len() != 1 {
            return Err("選択した原本を確認できません。".into());
        }
        asset.inventory_complete = false;
        let mut nonce = [0u8; 16];
        getrandom::getrandom(&mut nonce).map_err(|_| "読み出しの準備ができません。")?;
        Ok(Self {
            proof_id: crate::domain::hex(&nonce),
            asset,
            observation: facts.observation,
            records,
            scope: session.scope.clone(),
            owner: session.user_id.clone(),
            generation,
        })
    }
    pub(crate) fn same_records(&self, state: &SavedLibrary) -> bool {
        if crate::immich_live_writes::fences(state, &self.asset.key) {
            return false;
        }
        let records = state
            .immich_visibility_operations
            .iter()
            .filter(|o| o.key == self.asset.key)
            .collect::<Vec<_>>();
        serde_json::to_value(records).ok() == serde_json::to_value(&self.records).ok()
            && !state
                .protected_entries
                .iter()
                .any(|e| e.key == self.asset.key)
    }
    pub(crate) fn matches_state(&self, state: &SavedLibrary) -> bool {
        let records = state
            .immich_visibility_operations
            .iter()
            .filter(|o| o.key == self.asset.key)
            .collect::<Vec<_>>();
        serde_json::to_value(records).ok() == serde_json::to_value(&self.records).ok()
            && !state
                .protected_entries
                .iter()
                .any(|e| e.key == self.asset.key)
            && state.snapshots.iter().any(|s| {
                s.scope == self.scope
                    && s.provider == Provider::Immich
                    && s.access == crate::domain::ScanAccess::Full
                    && s.assets.iter().any(|a| a == &self.asset)
            })
    }
    pub(crate) fn verify_raw(&self, raw: &Value) -> Result<(), String> {
        let original = self
            .records
            .iter()
            .find(|o| {
                o.kind == ImmichVisibilityOperationKind::LockedTransition
                    && o.selected_observation.is_some()
            })
            .ok_or("確認記録がありません。")?;
        let facts = crate::immich_visibility::selected_facts(raw, original, &self.owner)?;
        if facts.observation != self.observation || facts.asset.revision != self.asset.revision {
            return Err("写真の状態が変わりました。更新してください。".into());
        }
        Ok(())
    }
    pub(crate) fn current(&self, model: &Model) -> bool {
        model
            .session
            .as_ref()
            .is_some_and(|s| s.scope == self.scope && s.user_id == self.owner)
            && self.matches_state(&model.state)
            && !model.protection.membership_uncertain
            && !model.immich_visibility.persistence_uncertain
            && !model.protection.denied.contains(&self.asset.key)
            && !model.immich_visibility.denied.contains(&self.asset.key)
            && model
                .ordinary_generation
                .load(std::sync::atomic::Ordering::SeqCst)
                == self.generation
    }
}
