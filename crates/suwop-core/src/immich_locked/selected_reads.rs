//! A fresh authenticated selected-original read exception; never durable authority.
use super::{
    AssetKey, DedicatedSession, ERROR, Model, Value, clear_visibility_key_image, current, epoch,
};
#[derive(Clone)]
pub(super) struct SelectedReadProof {
    pub operation: crate::immich_visibility::ImmichVisibilityOperation,
    pub observation: crate::immich_visibility::SelectedVisibilityObservation,
    pub grant_id: String,
    pub scene_id: String,
    pub generation: u64,
    pub revision: String,
}
pub(super) fn current_selected_read(model: &Model, key: &AssetKey) -> bool {
    let Some(proof) = model.immich_locked.selected_reads.get(key) else {
        return false;
    };
    current(model)
        && proof.observation.visibility == crate::immich_visibility::ImmichVisibility::Locked
        && proof.observation.configuration_digest.is_some()
        && model.immich_locked.grant_id.as_ref() == Some(&proof.grant_id)
        && model.immich_locked.scene_id.as_ref() == Some(&proof.scene_id)
        && epoch(&model.immich_locked) == proof.generation
        && model
            .immich_locked
            .entries
            .iter()
            .any(|entry| entry.asset.key == *key && entry.asset.revision == proof.revision)
        && model
            .state
            .immich_visibility_operations
            .iter()
            .any(|operation| {
                operation.id == proof.operation.id
                    && operation.key == *key
                    && operation.kind == proof.operation.kind
                    && operation.scope == proof.operation.scope
                    && operation.witness_digest == proof.operation.witness_digest
                    && operation.outcome == proof.operation.outcome
                    && operation.observation == proof.operation.observation
                    && operation.from == proof.operation.from
                    && operation.to == proof.operation.to
                    && operation.selected_observation.as_ref() == Some(&proof.observation)
            })
}
impl SelectedReadProof {
    pub(super) fn verify(&self, value: &Value, session: &DedicatedSession) -> Result<(), String> {
        let current = crate::immich_visibility::selected_facts(
            value,
            &self.operation,
            &session.ordinary.user_id,
        )?;
        if current.observation.visibility != crate::immich_visibility::ImmichVisibility::Locked
            || current.observation != self.observation
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
}
pub(crate) fn clear_selected_read_proofs(model: &mut Model) {
    let keys = model
        .immich_locked
        .selected_reads
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    for key in keys {
        clear_visibility_key_image(model, &key);
    }
    model.immich_locked.selected_reads.clear();
}
