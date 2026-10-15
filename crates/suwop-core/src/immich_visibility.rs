//! Durable exact-asset visibility intent. Session elevation remains ephemeral.
use crate::{app::Model, domain::AssetKey};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
mod selected_observation;
pub use selected_observation::{
    SelectedConfiguration, SelectedVisibilityObservation, SelectedVisibilitySummary,
};
pub(crate) use selected_observation::{
    SelectedObservationFacts, VerifiedSelectedProjection, selected_facts,
};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichVisibility {
    Timeline,
    Archive,
    Locked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichVisibilityUnsupportedReason {
    Live,
    Video,
    Stack,
    Unknown,
    Unavailable,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichVisibilityWriteAvailability {
    VerificationRequired,
    Supported,
    Unsupported,
}
pub(crate) fn gate_write_hint(
    hint: &mut ImmichVisibilityActionHint,
    availability: ImmichVisibilityWriteAvailability,
) {
    hint.write_availability = if hint.reason.is_some() {
        ImmichVisibilityWriteAvailability::Unsupported
    } else {
        availability
    };
    if availability != ImmichVisibilityWriteAvailability::Supported {
        hint.can_lock = false;
        hint.can_show_timeline = false;
        hint.can_show_archive = false;
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityActionHint {
    pub write_availability: ImmichVisibilityWriteAvailability,
    pub key: AssetKey,
    pub can_lock: bool,
    pub can_show_timeline: bool,
    pub can_show_archive: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<ImmichVisibilityUnsupportedReason>,
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum AlbumMembershipObservation {
    #[default]
    NotChecked,
    NoAccessibleMemberships,
    AccessibleMembershipsRemain,
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ImmichVisibilityOperationKind {
    #[default]
    LockedTransition,
    OrdinaryArchive,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityOperation {
    #[serde(default)]
    pub kind: ImmichVisibilityOperationKind,
    pub id: String,
    pub scope: String,
    pub key: AssetKey,
    pub witness_digest: String,
    pub from: ImmichVisibility,
    pub to: ImmichVisibility,
    pub outcome: crate::apple_visibility::VisibilityOutcome,
    #[serde(default)]
    pub observation: Option<ImmichVisibility>,
    #[serde(default)]
    pub album_membership_observation: AlbumMembershipObservation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_observation: Option<SelectedVisibilityObservation>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilitySummary {
    #[serde(rename = "recordID")]
    pub record_id: String,
    pub from: ImmichVisibility,
    pub to: ImmichVisibility,
    pub outcome: crate::apple_visibility::VisibilityOutcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observation: Option<ImmichVisibility>,
    pub album_membership_observation: AlbumMembershipObservation,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_observation: Option<SelectedVisibilitySummary>,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityView {
    pub persistence_uncertain: bool,
    pub can_recover: bool,
    #[serde(rename = "sceneID", skip_serializing_if = "Option::is_none")]
    pub scene_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history: Option<Vec<ImmichVisibilitySummary>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityPrompt {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    pub generation: u64,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub from: ImmichVisibility,
    pub to: ImmichVisibility,
    pub removes_all_album_membership: bool,
    pub no_automatic_album_restore: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityAuthorization {
    pub deadline_unix_milliseconds: u64,
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
}
#[derive(Debug, Default)]
pub struct ImmichVisibilityModel {
    pub generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub persistence_uncertain: bool,
    pub denied: BTreeSet<AssetKey>,
    pub used_ids: BTreeSet<String>,
    pub message: Option<String>,
}
#[must_use]
pub fn view(model: &Model) -> ImmichVisibilityView {
    let locked = crate::immich_locked::view(model);
    let authorized = locked
        .grant_id
        .as_deref()
        .zip(locked.scene_id.as_deref())
        .and_then(|(grant, scene)| crate::immich_locked::visibility_session(model, grant, scene));
    ImmichVisibilityView {
        persistence_uncertain: model.immich_visibility.persistence_uncertain,
        can_recover: model.immich_visibility.persistence_uncertain
            && authorized.is_some()
            && !model.busy,
        scene_id: authorized.as_ref().map(|c| c.scene_id.clone()),
        history: authorized.as_ref().map(|c| {
            model
                .state
                .immich_visibility_operations
                .iter()
                .filter(|o| {
                    o.kind == ImmichVisibilityOperationKind::LockedTransition
                        && o.scope == c.scope()
                        && !model.state.protected_entries.iter().any(|e| e.key == o.key)
                        && !model.protection.denied.contains(&o.key)
                })
                .map(|o| ImmichVisibilitySummary {
                    record_id: o.id.clone(),
                    from: o.from,
                    to: o.to,
                    outcome: o.outcome,
                    observation: o.observation,
                    album_membership_observation: o.album_membership_observation,
                    selected_observation: o
                        .selected_observation
                        .as_ref()
                        .map(SelectedVisibilityObservation::summary),
                })
                .collect()
        }),
        status: authorized.and(model.immich_visibility.message.clone()),
    }
}
#[must_use]
pub fn actions(model: &Model) -> Vec<ImmichVisibilityActionHint> {
    let public =
        crate::privacy::PublishedLibrary::from_canonical(&crate::protection::ordinary_state(model));
    public
        .snapshots
        .iter()
        .filter(|snapshot| snapshot.access != crate::domain::ScanAccess::Unavailable)
        .flat_map(|snapshot| &snapshot.assets)
        .filter(|asset| asset.key.provider == crate::domain::Provider::Immich)
        .map(|asset| {
            let mut action = hint(asset, false);
            let supported = crate::immich_locked::write_supported(model);
            let verification = model
                .session
                .as_ref()
                .is_some_and(|s| (s.version.major, s.version.minor, s.version.patch) == (3, 3, 3));
            gate_write_hint(
                &mut action,
                if supported {
                    ImmichVisibilityWriteAvailability::Supported
                } else if verification && !crate::immich_locked::write_checked(model) {
                    ImmichVisibilityWriteAvailability::VerificationRequired
                } else {
                    ImmichVisibilityWriteAvailability::Unsupported
                },
            );
            action
        })
        .collect()
}
#[must_use]
pub fn locked_action(key: AssetKey) -> ImmichVisibilityActionHint {
    ImmichVisibilityActionHint {
        write_availability: ImmichVisibilityWriteAvailability::Unsupported,
        key,
        can_lock: false,
        can_show_timeline: false,
        can_show_archive: false,
        reason: Some(ImmichVisibilityUnsupportedReason::Unknown),
    }
}

#[derive(Clone, Copy)]
enum MediaPolicy {
    LockedImage,
    OrdinaryArchive,
}

pub(crate) fn ordinary_archive_reason(
    asset: &crate::domain::StoredAsset,
) -> Option<ImmichVisibilityUnsupportedReason> {
    if asset
        .resources
        .iter()
        .any(|r| r.role == crate::domain::ResourceRole::LiveVideo)
    {
        if asset.is_offline {
            return Some(ImmichVisibilityUnsupportedReason::Unavailable);
        }
        if asset.immich_stack == crate::domain::ImmichStackState::Stacked {
            return Some(ImmichVisibilityUnsupportedReason::Stack);
        }
        return linked_parent_parts(asset)
            .is_none()
            .then_some(ImmichVisibilityUnsupportedReason::Unknown);
    }
    unsupported_reason(asset, MediaPolicy::OrdinaryArchive)
}
fn unsupported_reason(
    asset: &crate::domain::StoredAsset,
    policy: MediaPolicy,
) -> Option<ImmichVisibilityUnsupportedReason> {
    use crate::domain::{Provider, ResourceRole};
    if asset.key.provider != Provider::Immich || asset.is_offline {
        Some(ImmichVisibilityUnsupportedReason::Unavailable)
    } else if asset
        .resources
        .iter()
        .any(|r| r.role == ResourceRole::LiveVideo)
    {
        Some(ImmichVisibilityUnsupportedReason::Live)
    } else if matches!(policy, MediaPolicy::LockedImage)
        && asset
            .resources
            .iter()
            .any(|r| r.role == ResourceRole::Video)
    {
        Some(ImmichVisibilityUnsupportedReason::Video)
    } else if asset.immich_stack == crate::domain::ImmichStackState::Stacked {
        Some(ImmichVisibilityUnsupportedReason::Stack)
    } else if asset.immich_stack == crate::domain::ImmichStackState::Unknown
        || !asset.inventory_complete
        || asset.originals().count() != 1
        || !asset.originals().any(|r| {
            matches!(r.role, ResourceRole::Image | ResourceRole::RawImage)
                || matches!(policy, MediaPolicy::OrdinaryArchive) && r.role == ResourceRole::Video
        })
    {
        Some(ImmichVisibilityUnsupportedReason::Unknown)
    } else {
        None
    }
}
pub(crate) fn hint(asset: &crate::domain::StoredAsset, locked: bool) -> ImmichVisibilityActionHint {
    let reason = unsupported_reason(asset, MediaPolicy::LockedImage);

    ImmichVisibilityActionHint {
        write_availability: if reason.is_none() {
            ImmichVisibilityWriteAvailability::Supported
        } else {
            ImmichVisibilityWriteAvailability::Unsupported
        },
        key: asset.key.clone(),
        can_lock: reason.is_none() && !locked,
        can_show_timeline: reason.is_none() && locked,
        can_show_archive: reason.is_none() && locked,
        reason,
    }
}
pub fn validate_operation(operation: &ImmichVisibilityOperation) -> Result<(), String> {
    if operation.selected_observation.as_ref().is_some_and(|o| {
        operation.kind != ImmichVisibilityOperationKind::LockedTransition || !o.valid()
    }) || crate::apple_visibility::valid_operation_id(&operation.id).is_err()
        || operation.key.provider != crate::domain::Provider::Immich
        || operation.scope.is_empty()
        || operation.scope != operation.key.scope
        || crate::immich::valid_id(&operation.key.asset_id).is_err()
        || operation.witness_digest.len() != 64
        || !operation
            .witness_digest
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
        || !match operation.kind {
            ImmichVisibilityOperationKind::OrdinaryArchive => matches!(
                (operation.from, operation.to),
                (ImmichVisibility::Timeline, ImmichVisibility::Archive)
                    | (ImmichVisibility::Archive, ImmichVisibility::Timeline)
            ),
            ImmichVisibilityOperationKind::LockedTransition => matches!(
                (operation.from, operation.to),
                (
                    ImmichVisibility::Timeline | ImmichVisibility::Archive,
                    ImmichVisibility::Locked
                ) | (
                    ImmichVisibility::Locked,
                    ImmichVisibility::Timeline | ImmichVisibility::Archive
                )
            ),
        }
    {
        return Err("非表示変更の記録が不正です。既存ファイルは変更しません。".into());
    }
    Ok(())
}
#[must_use]
pub fn fences(state: &crate::app::SavedLibrary, key: &AssetKey) -> bool {
    let related = state
        .immich_visibility_operations
        .iter()
        .filter(|operation| {
            &operation.key == key
                && (operation.observation.is_some()
                    || operation.selected_observation.is_some()
                    || operation.outcome != crate::apple_visibility::VisibilityOutcome::NotApplied)
        })
        .collect::<Vec<_>>();
    if related.is_empty() {
        return false;
    }
    if related.iter().any(|operation| {
        operation.selected_observation.is_some()
            || operation.observation == Some(ImmichVisibility::Locked)
            || operation.observation.is_none()
                && operation.outcome != crate::apple_visibility::VisibilityOutcome::NotApplied
    }) {
        return true;
    }
    // Explicit unlocked observation alone never authorizes old cached records.
    let Some(snapshot) = state.snapshots.iter().find(|snapshot| {
        snapshot.provider == crate::domain::Provider::Immich
            && snapshot.scope == key.scope
            && snapshot.access == crate::domain::ScanAccess::Full
    }) else {
        return true;
    };
    !snapshot.assets.iter().any(|asset| {
        &asset.key == key
            && related.iter().all(|operation| {
                operation_witness(asset, operation.kind).as_deref()
                    == Some(operation.witness_digest.as_str())
            })
    })
}
fn linked_parent_parts(
    asset: &crate::domain::StoredAsset,
) -> Option<(&crate::domain::PhotoResource, &crate::domain::PhotoResource)> {
    use crate::domain::{ImmichStackState, Provider, ResourceRole};
    if asset.key.provider != Provider::Immich
        || asset.is_offline
        || asset.immich_stack != ImmichStackState::Unstacked
    {
        return None;
    }
    let [first, second] = asset.resources.as_slice() else {
        return None;
    };
    let (parent, motion) = match (first.role, second.role) {
        (ResourceRole::Image | ResourceRole::RawImage, ResourceRole::LiveVideo) => (first, second),
        (ResourceRole::LiveVideo, ResourceRole::Image | ResourceRole::RawImage) => (second, first),
        _ => return None,
    };
    if parent.id != asset.key.asset_id
        || motion.id == parent.id
        || parent.name == motion.name
        || crate::immich::valid_id(&motion.id).is_err()
        || crate::domain::normalize_sha1(parent.sha1.as_deref()).is_none()
    {
        return None;
    }
    Some((parent, motion))
}
fn operation_witness(
    asset: &crate::domain::StoredAsset,
    kind: ImmichVisibilityOperationKind,
) -> Option<String> {
    if kind == ImmichVisibilityOperationKind::OrdinaryArchive
        && let Some((parent, motion)) = linked_parent_parts(asset)
    {
        return Some(linked_identity_digest(
            &asset.key,
            &crate::domain::normalize_sha1(parent.sha1.as_deref())?,
            &motion.id,
        ));
    }
    asset_witness(asset)
}
fn linked_identity_digest(key: &AssetKey, checksum: &str, child: &str) -> String {
    use sha2::Digest;
    crate::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&(
            key,
            "IMAGE",
            checksum,
            "selectedLiveParent/v1",
            child,
            "unstacked",
        ))
        .unwrap_or_default(),
    ))
}
pub(crate) fn asset_witness(asset: &crate::domain::StoredAsset) -> Option<String> {
    use crate::domain::ResourceRole;
    let originals = asset.originals().collect::<Vec<_>>();
    let [original] = originals.as_slice() else {
        return None;
    };
    let media = match original.role {
        ResourceRole::Image | ResourceRole::RawImage => IdentityMedia::Image,
        ResourceRole::Video => IdentityMedia::Video,
        _ => return None,
    };
    if asset
        .resources
        .iter()
        .any(|r| r.role == ResourceRole::LiveVideo)
    {
        return None;
    }
    let checksum = crate::domain::normalize_sha1(original.sha1.as_deref())?;
    Some(identity_digest(&asset.key, &checksum, media))
}
#[derive(Clone, Copy)]
enum IdentityMedia {
    Image,
    Video,
}
fn identity_digest(key: &AssetKey, checksum: &str, media: IdentityMedia) -> String {
    use sha2::Digest;
    // Keep IMAGE journal bytes identical. VIDEO's tag asserts own forward-null
    // shape only; it never claims reverse-parent independence.
    let identity = match media {
        IdentityMedia::Image => (key, "IMAGE", checksum, "unlinked", "unstacked"),
        IdentityMedia::Video => (key, "VIDEO", checksum, "forwardNull", "unstacked"),
    };
    crate::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&identity).unwrap_or_default(),
    ))
}

#[derive(Debug, Clone)]
pub(crate) struct VisibilityFacts {
    pub asset: crate::domain::StoredAsset,
    pub key: AssetKey,
    pub witness: String,
    pub revision: String,
    pub visibility: ImmichVisibility,
}
pub(crate) fn facts(
    value: &serde_json::Value,
    scope: &str,
    owner: &str,
) -> Result<VisibilityFacts, String> {
    facts_with_policy(value, scope, owner, MediaPolicy::LockedImage)
}
pub(crate) fn ordinary_facts(
    value: &serde_json::Value,
    scope: &str,
    owner: &str,
) -> Result<VisibilityFacts, String> {
    facts_with_policy(value, scope, owner, MediaPolicy::OrdinaryArchive)
}
pub(crate) fn reconciliation_facts(
    value: &serde_json::Value,
    scope: &str,
    owner: &str,
    records: &[&ImmichVisibilityOperation],
) -> Result<VisibilityFacts, String> {
    let policy = if !records.is_empty()
        && records
            .iter()
            .all(|r| r.kind == ImmichVisibilityOperationKind::OrdinaryArchive)
    {
        MediaPolicy::OrdinaryArchive
    } else {
        MediaPolicy::LockedImage
    };
    facts_with_policy(value, scope, owner, policy)
}
fn facts_with_policy(
    value: &serde_json::Value,
    scope: &str,
    owner: &str,
    policy: MediaPolicy,
) -> Result<VisibilityFacts, String> {
    let asset: crate::immich::Asset =
        serde_json::from_value(value.clone()).map_err(|_| "写真の状態を確認できません。")?;
    if asset.owner_id != owner
        || asset.is_offline
        || asset.is_trashed
        || crate::immich::valid_id(&asset.id).is_err()
    {
        return Err("写真の所有者または状態を確認できません。".into());
    }
    let media = match (asset.media_type.as_str(), policy) {
        ("IMAGE", _) => IdentityMedia::Image,
        ("VIDEO", MediaPolicy::OrdinaryArchive) => IdentityMedia::Video,
        _ => return Err("この形式の可視性変更はまだ対応していません。".into()),
    };
    let linked_child =
        match (
            value.get("livePhotoVideoId"),
            policy,
            asset.media_type.as_str(),
        ) {
            (Some(serde_json::Value::Null), _, _) => None,
            (Some(serde_json::Value::String(child)), MediaPolicy::OrdinaryArchive, "IMAGE")
                if child != &asset.id && crate::immich::valid_id(child).is_ok() =>
            {
                Some(child.as_str())
            }
            _ => return Err(
                "Live Photo または連結状態を確認できない写真の非表示変更はまだ対応していません。"
                    .into(),
            ),
        };
    if !matches!(value.get("stack"), Some(serde_json::Value::Null)) {
        return Err(
            "スタックまたは構成を確認できない写真の非表示変更はまだ対応していません。".into(),
        );
    }
    let visibility = match asset.visibility.as_deref() {
        Some("timeline") => ImmichVisibility::Timeline,
        Some("archive") => ImmichVisibility::Archive,
        Some("locked") if matches!(policy, MediaPolicy::LockedImage) => ImmichVisibility::Locked,
        _ => return Err("写真の可視性を確認できません。".into()),
    };
    let checksum = crate::domain::normalize_sha1(Some(&asset.checksum))
        .ok_or("写真の同一性を確認できません。")?;
    let key = AssetKey {
        provider: crate::domain::Provider::Immich,
        scope: scope.into(),
        asset_id: asset.id.clone(),
    };
    if asset.updated_at.is_empty() {
        return Err("写真の更新状態を確認できません。".into());
    }
    let record = asset.record(scope, None, None);
    if linked_child.is_some() && linked_parent_parts(&record).is_none() {
        return Err("選択した写真の構成を確認できません。".into());
    }
    Ok(VisibilityFacts {
        asset: record,
        witness: linked_child.map_or_else(
            || identity_digest(&key, &checksum, media),
            |child| linked_identity_digest(&key, &checksum, child),
        ),
        key,
        revision: asset.updated_at,
        visibility,
    })
}

#[derive(Debug, Clone)]
pub struct PreparedVisibility {
    pub(crate) capability: crate::immich_archive::VisibilityAuthority,
    pub(crate) operation: ImmichVisibilityOperation,
    pub(crate) revision: String,
}
#[derive(Debug, Clone)]
pub(crate) struct VerifiedVisibilityProjection {
    pub capability: crate::immich_locked::VisibilitySession,
    pub operation_id: String,
    pub facts: VisibilityFacts,
}
#[derive(Debug, Clone)]
pub struct VisibilityCompletion {
    pub(crate) recovery_proof: Option<Box<crate::immich_archive::RecoveryProof>>,
    pub(crate) projection: Option<Box<VerifiedVisibilityProjection>>,
    pub(crate) selected_projection: Option<Box<VerifiedSelectedProjection>>,
    pub(crate) state: crate::app::SavedLibrary,
    pub(crate) uncertain: bool,
    pub(crate) status: String,
}
#[path = "workflow/immich_visibility.rs"]
pub(crate) mod workflow;
use workflow::{apply, inspect, invalidate_remote, prepare};
const SAFE_ERROR: &str = "写真の状態を確認できません。変更は再送せず状態を確認してください。";

pub(crate) fn update(
    event: crate::app::Event,
    model: &mut Model,
) -> Option<crux_core::Command<crate::app::Effect, crate::app::Event>> {
    use crate::app::Event;
    use crux_core::Command;
    match event {
        Event::PrepareImmichVisibility {
            key,
            to,
            operation_id,
            grant_id,
            scene_id,
        } => Some(begin(model, key, to, operation_id, &grant_id, &scene_id)),
        Event::ImmichVisibilityPrepared { result } => {
            let prepared = match result {
                Ok(prepared) => prepared,
                Err(message) => {
                    model.busy = false;
                    if model.immich_archive.working {
                        model.immich_archive.message = Some(message);
                    } else {
                        model.immich_visibility.message = Some(message);
                    }
                    model.immich_archive.working = false;
                    model.immich_archive.active_operation = None;
                    return Some(Command::done());
                }
            };
            let mut prepared = prepared;
            if prepared.capability.valid().is_err() {
                abandon_prepared(model);
                return Some(Command::done());
            }
            let previous = model
                .ordinary_generation
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if prepared.capability.advance_own_fence(previous).is_err() {
                abandon_prepared(model);
                return Some(Command::done());
            }
            model
                .immich_visibility
                .denied
                .insert(prepared.operation.key.clone());
            crate::immich_locked::remove_visibility_entry(model, &prepared.operation.key);
            let before = model.state.clone();
            Some(Command::new(move |ctx| async move {
                let result = apply(&ctx, before, prepared).await;
                ctx.send_event(Event::ImmichVisibilityFinished { result });
            }))
        }
        Event::InspectImmichVisibility {
            record_id,
            grant_id,
            scene_id,
        } => {
            if model.busy || model.immich_visibility.persistence_uncertain {
                return Some(Command::done());
            }
            model
                .immich_visibility
                .generation
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let Some(capability) =
                crate::immich_locked::visibility_session(model, &grant_id, &scene_id)
            else {
                return Some(Command::done());
            };
            let Some(operation) = model
                .state
                .immich_visibility_operations
                .iter()
                .find(|o| {
                    o.id == record_id
                        && o.kind == ImmichVisibilityOperationKind::LockedTransition
                        && o.scope == capability.scope()
                        && !model.state.protected_entries.iter().any(|e| e.key == o.key)
                        && !model.protection.denied.contains(&o.key)
                })
                .cloned()
            else {
                return Some(Command::done());
            };
            // Keep the row, but revoke only its preview/pending read before fresh inspection.
            crate::immich_locked::clear_visibility_key_image(model, &operation.key);
            model.busy = true;
            let before = model.state.clone();
            Some(Command::new(move |ctx| async move {
                let result = inspect(&ctx, before, capability.into(), operation).await;
                ctx.send_event(Event::ImmichVisibilityFinished { result });
            }))
        }
        Event::RecoverImmichVisibilityState { grant_id, scene_id } => {
            Some(recover(model, &grant_id, &scene_id))
        }
        Event::ImmichVisibilityFinished { result } => Some(finish(model, result)),
        _ => None,
    }
}

fn begin(
    model: &mut Model,
    key: AssetKey,
    to: ImmichVisibility,
    operation_id: String,
    grant_id: &str,
    scene_id: &str,
) -> crux_core::Command<crate::app::Effect, crate::app::Event> {
    use crate::app::Event;
    use crux_core::Command;

    if model.busy
        || !model.ready
        || model.state.schema_version != 8
        || model.immich_visibility.persistence_uncertain
        || model.protection.membership_uncertain
    {
        return Command::done();
    }
    model
        .immich_visibility
        .generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let Some(capability) = crate::immich_locked::visibility_session(model, grant_id, scene_id)
    else {
        return Command::done();
    };
    if !crate::immich_locked::write_supported(model)
        || key.scope != capability.scope()
        || key.provider != crate::domain::Provider::Immich
        || model.state.protected_entries.iter().any(|e| e.key == key)
        || model.protection.denied.contains(&key)
        || model.state.immich_visibility_operations.iter().any(|o| {
            o.key == key
                && (o.selected_observation.is_some()
                    || o.outcome == crate::apple_visibility::VisibilityOutcome::Unknown
                        && o.observation.is_none())
        })
        || crate::apple_visibility::valid_operation_id(&operation_id).is_err()
        || model
            .state
            .immich_visibility_operations
            .iter()
            .any(|o| o.id == operation_id)
        || !model
            .immich_visibility
            .used_ids
            .insert(operation_id.clone())
    {
        model.immich_visibility.message = Some(SAFE_ERROR.into());
        return Command::done();
    }
    model.busy = true;
    Command::new(move |ctx| async move {
        let result = prepare(&ctx, capability.into(), key, to, operation_id).await;
        ctx.send_event(Event::ImmichVisibilityPrepared { result });
    })
}

fn recover(
    model: &mut Model,
    grant_id: &str,
    scene_id: &str,
) -> crux_core::Command<crate::app::Effect, crate::app::Event> {
    use crate::app::Event;
    use crux_core::Command;

    if model.busy || model.immich_archive.uncertain {
        return Command::done();
    }
    if crate::immich_locked::visibility_session(model, grant_id, scene_id).is_none() {
        return Command::done();
    }
    crate::immich_locked::clear_selected_read_proofs(model);
    if !model.immich_visibility.persistence_uncertain {
        return Command::done();
    }
    model
        .immich_visibility
        .generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let Some(capability) = crate::immich_locked::visibility_session(model, grant_id, scene_id)
    else {
        return Command::done();
    };
    crate::immich_locked::clear_selected_read_proofs(model);
    model.busy = true;
    let before = model.state.clone();
    Command::new(move |ctx| async move {
        let raw: Result<serde_json::Value, _> =
            crate::app::io(&ctx, crate::app::ShellOperation::ReadState).await;
        let state = raw
            .ok()
            .filter(|v| v["schemaVersion"].as_u64() == Some(8))
            .and_then(|v| crate::workflow::migrate(v).ok())
            .filter(|s| {
                serde_json::to_value(&s.connection).ok()
                    == serde_json::to_value(&before.connection).ok()
                    && s.apple_scope == before.apple_scope
                    && capability.valid().is_ok()
            });
        let uncertain = state.is_none();
        let mut state = state.unwrap_or(before);
        if !uncertain {
            invalidate_remote(&mut state);
        }
        ctx.send_event(Event::ImmichVisibilityFinished {
            result: VisibilityCompletion {
                selected_projection: None,
                recovery_proof: None,
                projection: None,
                state,
                uncertain,
                status: if uncertain {
                    "保存状態を確認できません。変更せず再度確認してください。"
                } else {
                    "保存状態を確認しました。写真一覧を更新してください。"
                }
                .into(),
            },
        });
    })
}

#[cfg(test)]
mod stack_hints {
    use super::*;
    use serde_json::json;

    #[test]
    fn stack_knowledge_survives_record_and_disables_both_surfaces() -> Result<(), String> {
        for (stack, expected, reason) in [
            (
                Some(json!(null)),
                crate::domain::ImmichStackState::Unstacked,
                None,
            ),
            (
                Some(json!({"id":"stack"})),
                crate::domain::ImmichStackState::Stacked,
                Some(ImmichVisibilityUnsupportedReason::Stack),
            ),
            (
                None,
                crate::domain::ImmichStackState::Unknown,
                Some(ImmichVisibilityUnsupportedReason::Unknown),
            ),
            (
                Some(json!(false)),
                crate::domain::ImmichStackState::Unknown,
                Some(ImmichVisibilityUnsupportedReason::Unknown),
            ),
        ] {
            let mut value = json!({"id":"asset","ownerId":"owner","type":"IMAGE","originalFileName":"photo.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,"livePhotoVideoId":null});
            if let Some(stack) = stack {
                value["stack"] = stack;
            }
            let asset: crate::immich::Asset =
                serde_json::from_value(value).map_err(|e| e.to_string())?;
            let encoded = serde_json::to_value(&asset).map_err(|e| e.to_string())?;
            let decoded: crate::immich::Asset =
                serde_json::from_value(encoded).map_err(|e| e.to_string())?;
            assert_eq!(decoded.stack, expected);
            let record = asset.record("scope", None, None);
            assert_eq!(record.immich_stack, expected);
            for locked in [false, true] {
                let action = hint(&record, locked);
                assert_eq!(action.reason, reason);
                assert_eq!(action.can_lock, reason.is_none() && !locked);
                assert_eq!(action.can_show_timeline, reason.is_none() && locked);
                assert_eq!(action.can_show_archive, reason.is_none() && locked);
            }
            let mut legacy = serde_json::to_value(record).map_err(|e| e.to_string())?;
            legacy
                .as_object_mut()
                .ok_or("record")?
                .remove("immichStack");
            let legacy: crate::domain::StoredAsset =
                serde_json::from_value(legacy).map_err(|e| e.to_string())?;
            assert_eq!(
                legacy.immich_stack,
                crate::domain::ImmichStackState::Unknown
            );
            assert_eq!(
                hint(&legacy, false).reason,
                Some(ImmichVisibilityUnsupportedReason::Unknown)
            );
        }
        Ok(())
    }
}

fn finish(
    model: &mut Model,
    mut result: VisibilityCompletion,
) -> crux_core::Command<crate::app::Effect, crate::app::Event> {
    if model.changed_during_work {
        crate::app::invalidate_apple(&mut result.state);
    }
    model.state = result.state;
    model.busy = false;
    model.immich_visibility.persistence_uncertain = result.uncertain;
    let ordinary = model.immich_archive.working;
    if ordinary {
        model.immich_archive.uncertain = result.uncertain;
        if result.uncertain {
            if result.recovery_proof.is_some() {
                model.immich_archive.recovery_proof = result.recovery_proof;
            }
        } else {
            model.immich_archive.recovery_proof = None;
        }
        model.immich_archive.active_operation = None;
    }
    if ordinary {
        model.immich_archive.message = Some(result.status);
    } else {
        model.immich_visibility.message = Some(result.status);
    }
    model.immich_archive.working = false;
    if !ordinary && let Some(projection) = result.projection {
        crate::immich_locked::publish_visibility_entry(model, *projection);
    }
    if !ordinary && let Some(projection) = result.selected_projection {
        crate::immich_locked::publish_selected_observation(model, *projection);
    }
    if !result.uncertain {
        model.immich_visibility.denied.clear();
    }
    model
        .ordinary_generation
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    crate::protection::reconcile(model)
}

// Both validation exits precede durable intent and must retire the pending
// native permit as well as its result-routing origin.
fn abandon_prepared(model: &mut Model) {
    model.busy = false;
    model.immich_archive.working = false;
    model.immich_archive.active_operation = None;
}

#[cfg(test)]
mod prepared_cleanup_tests {
    use super::*;
    #[test]
    fn failed_fence_advance_retires_native_permit_and_next_result_origin() {
        let mut model = Model {
            busy: true,
            ..Model::default()
        };
        model.immich_archive.working = true;
        model.immich_archive.active_operation =
            Some(crate::immich_archive::ImmichArchiveAuthorization {
                operation_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into(),
                scene_id: "scene".into(),
                generation: 0,
                scope: "scope".into(),
                key: AssetKey {
                    provider: crate::domain::Provider::Immich,
                    scope: "scope".into(),
                    asset_id: "asset".into(),
                },
                to: crate::immich_archive::ImmichArchiveDestination::Archive,
                url: "https://fixture/api/assets".into(),
            });
        abandon_prepared(&mut model);
        assert!(!model.busy);
        assert!(!model.immich_archive.working);
        assert!(model.immich_archive.active_operation.is_none());
        let _ = finish(
            &mut model,
            VisibilityCompletion {
                selected_projection: None,
                recovery_proof: None,
                projection: None,
                state: crate::app::SavedLibrary::default(),
                uncertain: false,
                status: "PIN result".into(),
            },
        );
        assert_eq!(
            model.immich_visibility.message.as_deref(),
            Some("PIN result")
        );
        assert!(model.immich_archive.message.is_none());
    }
}

#[cfg(test)]
mod media_policy_tests {
    use super::*;
    use serde_json::json;
    use sha2::Digest;

    fn video() -> serde_json::Value {
        json!({"id":"33333333-3333-4333-8333-333333333333","ownerId":"owner","type":"VIDEO","originalFileName":"selected.mp4","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","isFavorite":false,"isOffline":false,"isTrashed":false,"updatedAt":"revision","visibility":"timeline","livePhotoVideoId":null,"stack":null})
    }

    #[test]
    fn video_facts_are_ordinary_only_and_require_explicit_forward_null() -> Result<(), String> {
        let raw = video();
        assert!(ordinary_facts(&raw, "scope", "owner").is_ok());
        assert!(facts(&raw, "scope", "owner").is_err());
        let mut missing = raw.clone();
        missing
            .as_object_mut()
            .ok_or("object")?
            .remove("livePhotoVideoId");
        assert!(ordinary_facts(&missing, "scope", "owner").is_err());
        for patch in [
            json!({"livePhotoVideoId":"44444444-4444-4444-8444-444444444444"}),
            json!({"stack":{}}),
            json!({"visibility":"hidden"}),
            json!({"visibility":"locked"}),
        ] {
            let mut changed = raw.clone();
            changed
                .as_object_mut()
                .ok_or("object")?
                .extend(patch.as_object().ok_or("patch")?.clone());
            assert!(ordinary_facts(&changed, "scope", "owner").is_err());
        }
        Ok(())
    }

    #[test]
    fn video_reconciliation_never_borrows_ordinary_policy_for_mixed_history() -> Result<(), String>
    {
        let raw = video();
        let fresh = ordinary_facts(&raw, "scope", "owner")?;
        let ordinary: ImmichVisibilityOperation = serde_json::from_value(json!({
            "kind":"ordinaryArchive","id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "scope":"scope","key":fresh.key,"witnessDigest":fresh.witness,
            "from":"timeline","to":"archive","outcome":"applied","observation":"archive"
        }))
        .map_err(|e| e.to_string())?;
        assert!(reconciliation_facts(&raw, "scope", "owner", &[&ordinary]).is_ok());
        let mut locked = ordinary.clone();
        locked.kind = ImmichVisibilityOperationKind::LockedTransition;
        locked.to = ImmichVisibility::Locked;
        assert!(reconciliation_facts(&raw, "scope", "owner", &[&ordinary, &locked]).is_err());
        assert!(reconciliation_facts(&raw, "scope", "owner", &[&locked]).is_err());
        assert!(reconciliation_facts(&raw, "scope", "owner", &[]).is_err());
        // Refresh tracks observed records only. An unobserved Unknown of
        // either kind remains an independent canonical content/write fence.
        locked.outcome = crate::apple_visibility::VisibilityOutcome::Unknown;
        locked.observation = None;
        let key = fresh.asset.key.clone();
        let state = crate::app::SavedLibrary {
            snapshots: vec![crate::domain::LibrarySnapshot {
                provider: crate::domain::Provider::Immich,
                scope: "scope".into(),
                access: crate::domain::ScanAccess::Full,
                scanned_at: Some(1.0),
                assets: vec![fresh.asset],
            }],
            immich_visibility_operations: vec![ordinary, locked],
            ..crate::app::SavedLibrary::default()
        };
        assert!(fences(&state, &key));
        Ok(())
    }

    #[test]
    fn image_witness_is_backward_compatible_and_video_is_domain_separated() -> Result<(), String> {
        let key = AssetKey {
            provider: crate::domain::Provider::Immich,
            scope: "scope".into(),
            asset_id: "asset".into(),
        };
        let checksum = "a".repeat(40);
        let old = serde_json::to_vec(&(&key, "IMAGE", &checksum, "unlinked", "unstacked"))
            .map_err(|e| e.to_string())?;
        let expected = crate::domain::hex(&sha2::Sha256::digest(old));
        assert_eq!(
            identity_digest(&key, &checksum, IdentityMedia::Image),
            expected
        );
        assert_ne!(
            identity_digest(&key, &checksum, IdentityMedia::Video),
            expected
        );
        let old_video = serde_json::to_vec(&(&key, "VIDEO", &checksum, "forwardNull", "unstacked"))
            .map_err(|e| e.to_string())?;
        assert_eq!(
            identity_digest(&key, &checksum, IdentityMedia::Video),
            crate::domain::hex(&sha2::Sha256::digest(old_video))
        );
        Ok(())
    }
}

#[cfg(test)]
mod selected_parent_tests {
    use super::*;
    use serde_json::json;
    fn raw() -> serde_json::Value {
        json!({"id":"11111111-1111-4111-8111-111111111111","ownerId":"owner","type":"IMAGE","originalFileName":"parent.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"timeline","livePhotoVideoId":"22222222-2222-4222-8222-222222222222","stack":null})
    }
    #[test]
    fn selected_parent_identity_is_ordinary_only_without_promoting_inventory() -> Result<(), String>
    {
        let fresh = ordinary_facts(&raw(), "scope", "owner")?;
        assert!(!fresh.asset.inventory_complete);
        assert_eq!(fresh.asset.originals().count(), 2);
        assert!(ordinary_archive_reason(&fresh.asset).is_none());
        assert_eq!(
            hint(&fresh.asset, false).reason,
            Some(ImmichVisibilityUnsupportedReason::Live)
        );
        assert!(facts(&raw(), "scope", "owner").is_err());
        assert!(asset_witness(&fresh.asset).is_none());
        assert_eq!(
            operation_witness(&fresh.asset, ImmichVisibilityOperationKind::OrdinaryArchive),
            Some(fresh.witness)
        );
        assert!(
            operation_witness(
                &fresh.asset,
                ImmichVisibilityOperationKind::LockedTransition
            )
            .is_none()
        );
        Ok(())
    }
    #[test]
    fn malformed_duplicate_or_mismatched_parent_resources_are_not_eligible() -> Result<(), String> {
        let fresh = ordinary_facts(&raw(), "scope", "owner")?;
        for variant in 0..5 {
            let mut asset = fresh.asset.clone();
            match variant {
                0 => asset.resources[0].id = "wrong".into(),
                1 => asset.resources[1].id = asset.resources[0].id.clone(),
                2 => asset.resources[1].name = asset.resources[0].name.clone(),
                3 => asset.resources.push(asset.resources[1].clone()),
                _ => asset.resources[0].sha1 = None,
            }
            assert!(ordinary_archive_reason(&asset).is_some());
        }
        for child in [json!(null), json!(""), json!("bad/id"), json!(raw()["id"])] {
            let mut value = raw();
            value["livePhotoVideoId"] = child;
            if value["livePhotoVideoId"].is_null() {
                continue;
            }
            assert!(ordinary_facts(&value, "scope", "owner").is_err());
        }
        let mut missing = raw();
        missing
            .as_object_mut()
            .ok_or("object")?
            .remove("livePhotoVideoId");
        assert!(ordinary_facts(&missing, "scope", "owner").is_err());
        Ok(())
    }
    #[test]
    fn linked_parent_fence_requires_ordinary_kind_and_preserves_unresolved_history()
    -> Result<(), String> {
        let fresh = ordinary_facts(&raw(), "scope", "owner")?;
        let operation: ImmichVisibilityOperation = serde_json::from_value(json!({"kind":"ordinaryArchive","id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","scope":"scope","key":fresh.key,"witnessDigest":fresh.witness,"from":"timeline","to":"archive","outcome":"applied","observation":"archive"})).map_err(|e| e.to_string())?;
        let key = fresh.asset.key.clone();
        let mut state = crate::app::SavedLibrary {
            snapshots: vec![crate::domain::LibrarySnapshot {
                provider: crate::domain::Provider::Immich,
                scope: "scope".into(),
                access: crate::domain::ScanAccess::Full,
                scanned_at: Some(1.0),
                assets: vec![fresh.asset],
            }],
            immich_visibility_operations: vec![operation.clone()],
            ..crate::app::SavedLibrary::default()
        };
        assert!(!fences(&state, &key));
        state.immich_visibility_operations[0].kind =
            ImmichVisibilityOperationKind::LockedTransition;
        assert!(fences(&state, &key));
        state.immich_visibility_operations[0] = operation.clone();
        let mut unknown = operation;
        unknown.observation = None;
        unknown.outcome = crate::apple_visibility::VisibilityOutcome::Unknown;
        state.immich_visibility_operations.push(unknown);
        assert!(fences(&state, &key));
        state.immich_visibility_operations.pop();
        state.snapshots[0].assets[0].resources[1].id =
            "33333333-3333-4333-8333-333333333333".into();
        assert!(fences(&state, &key));
        Ok(())
    }
}
