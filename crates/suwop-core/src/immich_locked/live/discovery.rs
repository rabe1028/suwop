//! Cached metadata observation for a truthful action label, never acquisition authority.
use crate::{
    domain::{ImmichStackState, Provider, ResourceRole, StoredAsset},
    immich_visibility::SelectedConfiguration,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedLiveDiscovery {
    #[default]
    Unknown,
    ObservedLinked,
    ObservedUnlinked,
    Unsupported,
}

/// Missing forward metadata is deliberately different from an explicit null.
/// Incomplete companion inventory is not a refusal: a fresh pair inspection must fetch M later.
pub(in crate::immich_locked) fn discovery_hint(
    asset: &StoredAsset,
    forward: Option<&Value>,
) -> ImmichLockedLiveDiscovery {
    use ImmichLockedLiveDiscovery::{ObservedLinked, ObservedUnlinked, Unknown, Unsupported};
    if asset.key.provider != Provider::Immich
        || crate::immich::valid_id(&asset.key.asset_id).is_err()
        || asset.is_offline
        || !asset
            .originals()
            .any(|r| r.id == asset.key.asset_id && r.role == ResourceRole::Image)
        || asset.immich_stack == ImmichStackState::Stacked
    {
        return Unsupported;
    }
    match forward {
        None => Unknown,
        Some(Value::Null) => ObservedUnlinked,
        Some(Value::String(id))
            if !id.eq_ignore_ascii_case(&asset.key.asset_id)
                && crate::immich::valid_id(id).is_ok() =>
        {
            if asset.immich_stack == ImmichStackState::Unknown {
                Unknown
            } else {
                ObservedLinked
            }
        }
        Some(_) => Unsupported,
    }
}

/// These configurations came from the existing exact selected-observation path.
/// Read discovery remains independent from that journal's disabled write actions.
pub(in crate::immich_locked) fn selected_discovery_hint(
    asset: &StoredAsset,
    configuration: SelectedConfiguration,
) -> ImmichLockedLiveDiscovery {
    match configuration {
        SelectedConfiguration::Unlinked => discovery_hint(asset, Some(&Value::Null)),
        SelectedConfiguration::Linked => {
            let forward = asset
                .resources
                .iter()
                .find(|r| r.role == ResourceRole::LiveVideo)
                .map(|r| Value::String(r.id.clone()));
            discovery_hint(asset, forward.as_ref())
        }
        SelectedConfiguration::Stacked => ImmichLockedLiveDiscovery::Unsupported,
        SelectedConfiguration::Unverified => discovery_hint(asset, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::immich::Asset;
    use serde_json::json;
    const P: &str = "11111111-1111-4111-8111-111111111111";
    const M: &str = "22222222-2222-4222-8222-222222222222";

    fn record() -> Result<StoredAsset, String> {
        let asset: Asset = serde_json::from_value(json!({
            "id":P,"ownerId":"owner","type":"IMAGE","originalFileName":"parent.jpg",
            "checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z",
            "fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision",
            "isFavorite":false,"isOffline":false,"isTrashed":false,
            "visibility":"locked","stack":null,"livePhotoVideoId":M
        }))
        .map_err(|e| e.to_string())?;
        Ok(asset.record("scope", None, None))
    }

    #[test]
    fn missing_null_and_distinct_link_have_different_observations() -> Result<(), String> {
        let asset = record()?;
        // A linked parent has incomplete catalog inventory until M is freshly inspected.
        assert!(!asset.inventory_complete);
        assert_eq!(
            discovery_hint(&asset, None),
            ImmichLockedLiveDiscovery::Unknown
        );
        assert_eq!(
            discovery_hint(&asset, Some(&Value::Null)),
            ImmichLockedLiveDiscovery::ObservedUnlinked
        );
        assert_eq!(
            discovery_hint(&asset, Some(&json!(M))),
            ImmichLockedLiveDiscovery::ObservedLinked
        );
        for malformed in [json!(P), json!("bad-id"), json!(123), json!({})] {
            assert_eq!(
                discovery_hint(&asset, Some(&malformed)),
                ImmichLockedLiveDiscovery::Unsupported
            );
        }
        Ok(())
    }

    #[test]
    fn primary_kind_stack_offline_and_unknown_metadata_are_not_playable_hints() -> Result<(), String>
    {
        let asset = record()?;
        for role in [
            ResourceRole::RawImage,
            ResourceRole::Video,
            ResourceRole::Auxiliary,
        ] {
            let mut unsupported = asset.clone();
            unsupported.resources[0].role = role;
            assert_eq!(
                discovery_hint(&unsupported, Some(&json!(M))),
                ImmichLockedLiveDiscovery::Unsupported
            );
        }
        let mut changed = asset.clone();
        changed.immich_stack = ImmichStackState::Stacked;
        assert_eq!(
            discovery_hint(&changed, Some(&json!(M))),
            ImmichLockedLiveDiscovery::Unsupported
        );
        changed.immich_stack = ImmichStackState::Unknown;
        assert_eq!(
            discovery_hint(&changed, Some(&json!(M))),
            ImmichLockedLiveDiscovery::Unknown
        );
        changed.is_offline = true;
        assert_eq!(
            discovery_hint(&changed, Some(&json!(M))),
            ImmichLockedLiveDiscovery::Unsupported
        );
        Ok(())
    }

    #[test]
    fn selected_linked_observation_keeps_discovery_independent_of_disabled_writes()
    -> Result<(), String> {
        let asset = record()?;
        assert_eq!(
            selected_discovery_hint(&asset, SelectedConfiguration::Linked),
            ImmichLockedLiveDiscovery::ObservedLinked
        );
        assert_eq!(
            selected_discovery_hint(&asset, SelectedConfiguration::Unlinked),
            ImmichLockedLiveDiscovery::ObservedUnlinked
        );
        assert_eq!(
            selected_discovery_hint(&asset, SelectedConfiguration::Unverified),
            ImmichLockedLiveDiscovery::Unknown
        );
        assert_eq!(
            selected_discovery_hint(&asset, SelectedConfiguration::Stacked),
            ImmichLockedLiveDiscovery::Unsupported
        );
        Ok(())
    }
}
