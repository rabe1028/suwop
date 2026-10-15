//! Read-only selected-original observation, separate from mutation configuration proof.
use super::{
    AssetKey, Deserialize, IdentityMedia, ImmichVisibility, ImmichVisibilityOperation,
    ImmichVisibilityOperationKind, SAFE_ERROR, Serialize, identity_digest, validate_operation,
};
use crate::{domain::StoredAsset, immich::Asset};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum SelectedConfiguration {
    Unlinked,
    Linked,
    Stacked,
    Unverified,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SelectedVisibilityObservation {
    pub selected_identity_digest: String,
    pub visibility: ImmichVisibility,
    pub configuration: SelectedConfiguration,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub configuration_digest: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SelectedVisibilitySummary {
    pub visibility: ImmichVisibility,
    pub configuration: SelectedConfiguration,
}
impl SelectedVisibilityObservation {
    pub(crate) fn summary(&self) -> SelectedVisibilitySummary {
        SelectedVisibilitySummary {
            visibility: self.visibility,
            configuration: self.configuration,
        }
    }
    pub(crate) fn valid(&self) -> bool {
        let digest = |s: &str| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit());
        digest(&self.selected_identity_digest)
            && match (&self.configuration, &self.configuration_digest) {
                (SelectedConfiguration::Unverified, None) => true,
                (SelectedConfiguration::Unverified, Some(_)) | (_, None) => false,
                (_, Some(d)) => digest(d),
            }
    }
}
#[derive(Debug, Clone)]
pub(crate) struct SelectedObservationFacts {
    pub asset: StoredAsset,
    pub key: AssetKey,
    pub observation: SelectedVisibilityObservation,
}
/// Historical constants reconstruct ONLY the known `LockedTransition` IMAGE encoding.
/// Matching proves own identity components, never that current configuration is unlinked.
pub(crate) fn selected_facts(
    value: &serde_json::Value,
    operation: &ImmichVisibilityOperation,
    owner: &str,
) -> Result<SelectedObservationFacts, String> {
    if operation.kind != ImmichVisibilityOperationKind::LockedTransition {
        return Err(SAFE_ERROR.into());
    }
    validate_operation(operation)?;
    let asset: Asset = serde_json::from_value(value.clone()).map_err(|_| SAFE_ERROR)?;
    if asset.id != operation.key.asset_id
        || asset.owner_id != owner
        || asset.media_type != "IMAGE"
        || asset.is_offline
        || asset.is_trashed
        || asset.updated_at.is_empty()
    {
        return Err(SAFE_ERROR.into());
    }
    let checksum = crate::domain::normalize_sha1(Some(&asset.checksum)).ok_or(SAFE_ERROR)?;
    if identity_digest(&operation.key, &checksum, IdentityMedia::Image) != operation.witness_digest
    {
        return Err(SAFE_ERROR.into());
    }
    let visibility = match asset.visibility.as_deref() {
        Some("timeline") => ImmichVisibility::Timeline,
        Some("archive") => ImmichVisibility::Archive,
        Some("locked") => ImmichVisibility::Locked,
        _ => return Err(SAFE_ERROR.into()),
    };
    let link_known = match value.get("livePhotoVideoId") {
        Some(serde_json::Value::Null) => true,
        Some(serde_json::Value::String(id)) => {
            id != &asset.id && crate::immich::valid_id(id).is_ok()
        }
        _ => false,
    };
    let configuration = if link_known {
        match value.get("stack") {
            Some(serde_json::Value::Null) if value["livePhotoVideoId"].is_null() => {
                SelectedConfiguration::Unlinked
            }
            Some(serde_json::Value::Null) => SelectedConfiguration::Linked,
            Some(serde_json::Value::Object(stack))
                if ["id", "primaryAssetId"].iter().all(|field| {
                    stack
                        .get(*field)
                        .and_then(serde_json::Value::as_str)
                        .is_some_and(|id| crate::immich::valid_id(id).is_ok())
                }) && stack
                    .get("assetCount")
                    .and_then(serde_json::Value::as_u64)
                    .is_some_and(|count| count > 0) =>
            {
                SelectedConfiguration::Stacked
            }
            _ => SelectedConfiguration::Unverified,
        }
    } else {
        SelectedConfiguration::Unverified
    };
    let hash = |v| crate::domain::hex(&Sha256::digest(serde_json::to_vec(&v).unwrap_or_default()));
    let selected_identity_digest = hash(serde_json::json!([
        "selectedImage/v1",
        operation.key,
        owner,
        checksum
    ]));
    let configuration_digest = (configuration != SelectedConfiguration::Unverified).then(|| {
        hash(serde_json::json!([
            "selectedConfiguration/v1",
            value.get("livePhotoVideoId"),
            value.get("stack")
        ]))
    });
    Ok(SelectedObservationFacts {
        asset: asset.record(&operation.scope, None, None),
        key: operation.key.clone(),
        observation: SelectedVisibilityObservation {
            selected_identity_digest,
            visibility,
            configuration,
            configuration_digest,
        },
    })
}
#[derive(Debug, Clone)]
pub(crate) struct VerifiedSelectedProjection {
    pub capability: crate::immich_locked::VisibilitySession,
    pub operation_id: String,
    pub facts: SelectedObservationFacts,
}

#[cfg(test)]
mod tests {
    use super::{
        AssetKey, IdentityMedia, ImmichVisibility, ImmichVisibilityOperation,
        ImmichVisibilityOperationKind, SelectedConfiguration, identity_digest, selected_facts,
    };
    use crate::immich_visibility::{AlbumMembershipObservation, facts};
    #[test]
    fn historical_image_match_is_not_a_current_configuration_or_video_write_proof()
    -> Result<(), String> {
        let key = AssetKey {
            provider: crate::domain::Provider::Immich,
            scope: "scope".into(),
            asset_id: "33333333-3333-4333-8333-333333333333".into(),
        };
        let mut operation = ImmichVisibilityOperation {
            kind: ImmichVisibilityOperationKind::LockedTransition,
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into(),
            scope: key.scope.clone(),
            key: key.clone(),
            witness_digest: identity_digest(&key, &"a".repeat(40), IdentityMedia::Image),
            from: ImmichVisibility::Timeline,
            to: ImmichVisibility::Locked,
            outcome: crate::apple_visibility::VisibilityOutcome::Applied,
            observation: Some(ImmichVisibility::Locked),
            album_membership_observation: AlbumMembershipObservation::NotChecked,
            selected_observation: None,
        };
        let mut raw = serde_json::json!({"id":key.asset_id,"ownerId":"owner","type":"IMAGE","originalFileName":"private.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"locked","livePhotoVideoId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","stack":null});
        assert!(facts(&raw, "scope", "owner").is_err());
        let observed = selected_facts(&raw, &operation, "owner")?;
        assert_eq!(
            observed.observation.configuration,
            SelectedConfiguration::Linked
        );
        raw.as_object_mut()
            .ok_or("object")?
            .remove("livePhotoVideoId");
        assert_eq!(
            selected_facts(&raw, &operation, "owner")?
                .observation
                .configuration,
            SelectedConfiguration::Unverified
        );
        raw["livePhotoVideoId"] = serde_json::json!("malformed");
        raw["stack"] = serde_json::json!({"id":"11111111-1111-4111-8111-111111111111","primaryAssetId":"22222222-2222-4222-8222-222222222222","assetCount":2});
        assert_eq!(
            selected_facts(&raw, &operation, "owner")?
                .observation
                .configuration,
            SelectedConfiguration::Unverified
        );
        raw["livePhotoVideoId"] = serde_json::Value::Null;
        assert_eq!(
            selected_facts(&raw, &operation, "owner")?
                .observation
                .configuration,
            SelectedConfiguration::Stacked
        );
        raw["stack"] = serde_json::json!({"id":"malformed"});
        assert_eq!(
            selected_facts(&raw, &operation, "owner")?
                .observation
                .configuration,
            SelectedConfiguration::Unverified
        );
        raw["type"] = serde_json::json!("VIDEO");
        assert!(selected_facts(&raw, &operation, "owner").is_err());
        operation.kind = ImmichVisibilityOperationKind::OrdinaryArchive;
        assert!(selected_facts(&raw, &operation, "owner").is_err());
        Ok(())
    }
}
