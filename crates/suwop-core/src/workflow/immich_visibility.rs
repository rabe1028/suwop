#[path = "immich_visibility/readback.rs"]
pub(crate) mod readback;
use super::{
    AlbumMembershipObservation, AssetKey, ImmichVisibility, ImmichVisibilityOperation,
    PreparedVisibility, SAFE_ERROR, VisibilityCompletion, VisibilityFacts, validate_operation,
};
async fn fresh(
    ctx: &crate::app::Context,
    capability: &crate::immich_archive::VisibilityAuthority,
    key: &AssetKey,
) -> Result<VisibilityFacts, String> {
    capability
        .status(ctx)
        .await
        .map_err(|_| SAFE_ERROR.to_owned())?;
    let value = capability
        .json(ctx, &format!("assets/{}", key.asset_id), "GET", None)
        .await
        .map_err(|_| SAFE_ERROR.to_owned())?;
    let result = capability.facts(&value)?;
    if result.key != *key {
        return Err(SAFE_ERROR.into());
    }
    Ok(result)
}
pub(crate) async fn prepare(
    ctx: &crate::app::Context,
    capability: crate::immich_archive::VisibilityAuthority,
    key: AssetKey,
    to: ImmichVisibility,
    id: String,
) -> Result<PreparedVisibility, String> {
    let first = fresh(ctx, &capability, &key).await?;
    let operation = ImmichVisibilityOperation {
        kind: capability.kind(),
        id,
        scope: key.scope.clone(),
        key,
        witness_digest: first.witness.clone(),
        from: first.visibility,
        to,
        outcome: crate::apple_visibility::VisibilityOutcome::Unknown,
        observation: None,
        album_membership_observation: AlbumMembershipObservation::NotChecked,
    };
    validate_operation(&operation)?;
    let capability = capability.bind(&operation, &first.revision)?;
    let confirmed = capability.confirm(ctx, &operation).await?;
    if !confirmed {
        return Err("変更をキャンセルしました。".into());
    }
    let second = fresh(ctx, &capability, &operation.key).await?;
    if first.witness != second.witness
        || first.revision != second.revision
        || first.visibility != second.visibility
    {
        return Err(SAFE_ERROR.into());
    }
    Ok(PreparedVisibility {
        capability,
        operation,
        revision: second.revision,
    })
}
async fn persist(
    ctx: &crate::app::Context,
    before: &crate::app::SavedLibrary,
    desired: &crate::app::SavedLibrary,
    capability: &crate::immich_archive::VisibilityAuthority,
) -> (
    crate::app::SavedLibrary,
    bool,
    bool,
    Option<Box<crate::immich_archive::RecoveryProof>>,
) {
    let result: Result<serde_json::Value, _> =
        crate::app::io(ctx, crate::app::ShellOperation::Persist(desired.clone())).await;
    if result.is_ok() {
        return (desired.clone(), false, true, None);
    }
    let read: Result<serde_json::Value, _> =
        crate::app::io(ctx, crate::app::ShellOperation::ReadState).await;
    if let Ok(raw) = read {
        if serde_json::to_value(desired)
            .ok()
            .is_some_and(|expected| readback::matches(&expected, &raw))
        {
            return (desired.clone(), false, true, None);
        }
        if serde_json::to_value(before)
            .ok()
            .is_some_and(|expected| readback::matches(&expected, &raw))
        {
            return (before.clone(), false, false, None);
        }
    }
    (
        before.clone(),
        true,
        false,
        (capability.kind() == super::ImmichVisibilityOperationKind::OrdinaryArchive).then(|| {
            Box::new(crate::immich_archive::RecoveryProof {
                scope: capability.scope().into(),
                before: before.clone(),
                desired: desired.clone(),
            })
        }),
    )
}
pub(crate) fn invalidate_remote(state: &mut crate::app::SavedLibrary) {
    for snapshot in &mut state.snapshots {
        if snapshot.provider == crate::domain::Provider::Immich {
            snapshot.access = crate::domain::ScanAccess::Unavailable;
        }
    }
    for snapshot in &mut state.albums {
        if snapshot.provider == crate::domain::Provider::Immich {
            snapshot.access = crate::domain::ScanAccess::Unavailable;
        }
    }
}
fn observe(
    state: &mut crate::app::SavedLibrary,
    facts: &VisibilityFacts,
    kind: super::ImmichVisibilityOperationKind,
) {
    for operation in &mut state.immich_visibility_operations {
        if operation.key == facts.key
            && operation.witness_digest == facts.witness
            && operation.kind == kind
        {
            operation.observation = Some(facts.visibility);
        }
    }
    if facts.visibility != ImmichVisibility::Locked {
        invalidate_remote(state);
    }
}
pub(crate) async fn inspect(
    ctx: &crate::app::Context,
    before: crate::app::SavedLibrary,
    capability: crate::immich_archive::VisibilityAuthority,
    operation: ImmichVisibilityOperation,
) -> VisibilityCompletion {
    let Ok(facts) = fresh(ctx, &capability, &operation.key).await else {
        return VisibilityCompletion {
            recovery_proof: None,
            projection: None,
            state: before,
            uncertain: false,
            status: SAFE_ERROR.into(),
        };
    };
    if facts.witness != operation.witness_digest {
        return VisibilityCompletion {
            recovery_proof: None,
            projection: None,
            state: before,
            uncertain: false,
            status: SAFE_ERROR.into(),
        };
    }
    let mut desired = before.clone();
    observe(&mut desired, &facts, capability.kind());
    let (state, uncertain, committed, recovery_proof) =
        persist(ctx, &before, &desired, &capability).await;
    VisibilityCompletion {
        recovery_proof,
        projection: if committed && !uncertain {
            capability.projection(operation.id, facts)
        } else {
            None
        },
        state,
        uncertain,
        status: if committed {
            "現在の状態を保存しました。写真一覧を更新してください。"
        } else {
            "確認した状態を保存できませんでした。再送せず保存状態を確認してください。"
        }
        .into(),
    }
}
pub(crate) async fn apply(
    ctx: &crate::app::Context,
    before: crate::app::SavedLibrary,
    prepared: PreparedVisibility,
) -> VisibilityCompletion {
    use crate::apple_visibility::VisibilityOutcome;
    let mut desired = before.clone();
    desired
        .immich_visibility_operations
        .push(prepared.operation.clone());
    let (durable, uncertain, committed, recovery_proof) =
        persist(ctx, &before, &desired, &prepared.capability).await;
    if !committed {
        return VisibilityCompletion {
            projection: None,
            recovery_proof,
            state: durable,
            uncertain,
            status: SAFE_ERROR.into(),
        };
    }
    let capability = prepared.capability;
    let mut desired = durable.clone();
    let mut verified = None;
    let response = if fresh(ctx, &capability, &prepared.operation.key)
        .await
        .is_ok_and(|facts| {
            facts.witness == prepared.operation.witness_digest
                && facts.revision == prepared.revision
                && facts.visibility == prepared.operation.from
        }) {
        capability.mutate_visibility(ctx, &prepared.operation).await
    } else {
        if let Some(operation) = desired.immich_visibility_operations.last_mut() {
            operation.outcome = VisibilityOutcome::NotApplied;
        }
        let (state, uncertain, _, recovery_proof) =
            persist(ctx, &durable, &desired, &capability).await;
        return VisibilityCompletion {
            projection: None,
            recovery_proof,
            state,
            uncertain,
            status: "変更は開始されませんでした。".into(),
        };
    };
    if let Ok(facts) = fresh(ctx, &capability, &prepared.operation.key).await
        && facts.witness == prepared.operation.witness_digest
    {
        if response.is_ok()
            && facts.visibility == prepared.operation.to
            && let Some(operation) = desired.immich_visibility_operations.last_mut()
        {
            operation.outcome = VisibilityOutcome::Applied;
        }
        if response.is_ok() && facts.visibility == prepared.operation.to {
            observe(&mut desired, &facts, capability.kind());
            verified = Some(facts);
        }
        if prepared.operation.to == ImmichVisibility::Locked
            && let Ok(serde_json::Value::Array(albums)) = capability
                .json(
                    ctx,
                    &format!("albums?assetId={}", prepared.operation.key.asset_id),
                    "GET",
                    None,
                )
                .await
            && let Some(operation) = desired.immich_visibility_operations.last_mut()
        {
            operation.album_membership_observation = if albums.is_empty() {
                AlbumMembershipObservation::NoAccessibleMemberships
            } else {
                AlbumMembershipObservation::AccessibleMembershipsRemain
            };
        }
    }
    let (state, uncertain, committed, recovery_proof) =
        persist(ctx, &durable, &desired, &capability).await;
    VisibilityCompletion {
        recovery_proof,
        projection: if committed && !uncertain {
            verified.and_then(|facts| capability.projection(prepared.operation.id, facts))
        } else {
            None
        },
        state,
        uncertain,
        status: if committed {
            "変更結果を記録しました。現在の状態を確認してください。"
        } else {
            "変更結果を保存できませんでした。再送せず保存状態を確認してください。"
        }
        .into(),
    }
}
