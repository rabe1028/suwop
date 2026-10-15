//! Durable exact-asset visibility intent. Session elevation remains ephemeral.
use crate::{app::Model, domain::AssetKey};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
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
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichVisibilityActionHint {
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
        .map(|asset| hint(asset, false))
        .collect()
}
#[must_use]
pub fn locked_action(key: AssetKey) -> ImmichVisibilityActionHint {
    ImmichVisibilityActionHint {
        key,
        can_lock: false,
        can_show_timeline: false,
        can_show_archive: false,
        reason: Some(ImmichVisibilityUnsupportedReason::Unknown),
    }
}

pub(crate) fn hint(asset: &crate::domain::StoredAsset, locked: bool) -> ImmichVisibilityActionHint {
    use crate::domain::{Provider, ResourceRole};
    let reason = if asset.key.provider != Provider::Immich || asset.is_offline {
        Some(ImmichVisibilityUnsupportedReason::Unavailable)
    } else if asset
        .resources
        .iter()
        .any(|r| r.role == ResourceRole::LiveVideo)
    {
        Some(ImmichVisibilityUnsupportedReason::Live)
    } else if asset
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
        || !asset
            .originals()
            .any(|r| matches!(r.role, ResourceRole::Image | ResourceRole::RawImage))
    {
        Some(ImmichVisibilityUnsupportedReason::Unknown)
    } else {
        None
    };
    ImmichVisibilityActionHint {
        key: asset.key.clone(),
        can_lock: reason.is_none() && !locked,
        can_show_timeline: reason.is_none() && locked,
        can_show_archive: reason.is_none() && locked,
        reason,
    }
}
pub fn validate_operation(operation: &ImmichVisibilityOperation) -> Result<(), String> {
    if crate::apple_visibility::valid_operation_id(&operation.id).is_err()
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
                    || operation.outcome != crate::apple_visibility::VisibilityOutcome::NotApplied)
        })
        .collect::<Vec<_>>();
    if related.is_empty() {
        return false;
    }
    if related.iter().any(|operation| {
        operation.observation == Some(ImmichVisibility::Locked)
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
                asset_witness(asset).as_deref() == Some(operation.witness_digest.as_str())
            })
    })
}
pub(crate) fn asset_witness(asset: &crate::domain::StoredAsset) -> Option<String> {
    use crate::domain::ResourceRole;
    let originals = asset.originals().collect::<Vec<_>>();
    let [original] = originals.as_slice() else {
        return None;
    };
    if !matches!(original.role, ResourceRole::Image | ResourceRole::RawImage)
        || asset
            .resources
            .iter()
            .any(|r| r.role == ResourceRole::LiveVideo)
    {
        return None;
    }
    let checksum = crate::domain::normalize_sha1(original.sha1.as_deref())?;
    Some(identity_digest(&asset.key, &checksum))
}
fn identity_digest(key: &AssetKey, checksum: &str) -> String {
    use sha2::Digest;
    crate::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&(key, "IMAGE", checksum, "unlinked", "unstacked")).unwrap_or_default(),
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
    let asset: crate::immich::Asset =
        serde_json::from_value(value.clone()).map_err(|_| "写真の状態を確認できません。")?;
    if asset.owner_id != owner
        || asset.is_offline
        || asset.is_trashed
        || crate::immich::valid_id(&asset.id).is_err()
    {
        return Err("写真の所有者または状態を確認できません。".into());
    }
    if asset.media_type != "IMAGE" {
        return Err("動画の非表示変更はまだ対応していません。".into());
    }
    if !matches!(value.get("livePhotoVideoId"), Some(serde_json::Value::Null)) {
        return Err(
            "Live Photo または連結状態を確認できない写真の非表示変更はまだ対応していません。"
                .into(),
        );
    }
    if !matches!(value.get("stack"), Some(serde_json::Value::Null)) {
        return Err(
            "スタックまたは構成を確認できない写真の非表示変更はまだ対応していません。".into(),
        );
    }
    let visibility = match asset.visibility.as_deref() {
        Some("timeline") => ImmichVisibility::Timeline,
        Some("archive") => ImmichVisibility::Archive,
        Some("locked") => ImmichVisibility::Locked,
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
    Ok(VisibilityFacts {
        asset: asset.record(scope, None, None),
        witness: identity_digest(&key, &checksum),
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
            crate::immich_locked::remove_visibility_entry(model, &operation.key);
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
        || model.state.schema_version != 7
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
    if key.scope != capability.scope()
        || key.provider != crate::domain::Provider::Immich
        || model.state.protected_entries.iter().any(|e| e.key == key)
        || model.protection.denied.contains(&key)
        || model.state.immich_visibility_operations.iter().any(|o| {
            o.key == key
                && o.outcome == crate::apple_visibility::VisibilityOutcome::Unknown
                && o.observation.is_none()
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

    if model.busy
        || !model.immich_visibility.persistence_uncertain
        || model.immich_archive.uncertain
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
    model.busy = true;
    let before = model.state.clone();
    Command::new(move |ctx| async move {
        let raw: Result<serde_json::Value, _> =
            crate::app::io(&ctx, crate::app::ShellOperation::ReadState).await;
        let state = raw
            .ok()
            .filter(|v| v["schemaVersion"].as_u64() == Some(7))
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
