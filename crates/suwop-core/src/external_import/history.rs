use super::{ImportNotice, ImportPhase};
use crate::{
    app::Model,
    domain::{AssetKey, Provider},
};

/// An account-bound opaque status for a result whose destination has not yet
/// entered the ordinary catalog. Never exposes resource names, hashes or IDs.
pub(crate) fn notices(model: &Model, ordinary: &[AssetKey]) -> Vec<ImportNotice> {
    let access = crate::privacy::ContentAccess::new(&model.state);
    model
        .state
        .external_imports
        .iter()
        .filter(|record| {
            let current = match record.destination {
                Provider::Apple => record.destination_scope == model.state.apple_scope,
                Provider::Immich => model
                    .session
                    .as_ref()
                    .is_some_and(|s| s.scope == record.destination_scope),
                Provider::Amazon => false,
            };
            current
                && record.source_keys.iter().all(|k| ordinary.contains(k))
                && !record.destination_keys.iter().all(|k| ordinary.contains(k))
                && record.destination_keys.iter().all(|key| {
                    !access.protected(key)
                        && !model
                            .state
                            .apple_visibility_operations
                            .iter()
                            .any(|o| o.fences(key))
                        && (!model
                            .state
                            .snapshots
                            .iter()
                            .any(|s| s.assets.iter().any(|a| &a.key == key))
                            || ordinary.contains(key))
                })
        })
        .map(|record| ImportNotice {
            id: record.id.clone(),
            phase: record.phase,
            can_inspect: matches!(
                record.phase,
                ImportPhase::Uncertain | ImportPhase::Submitting
            ) && record.created.is_some()
                && !record.destination_keys.is_empty(),
        })
        .collect()
}
