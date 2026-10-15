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
async fn fresh_value(
    ctx: &crate::app::Context,
    capability: &crate::immich_archive::VisibilityAuthority,
    key: &AssetKey,
) -> Result<serde_json::Value, String> {
    capability
        .status(ctx)
        .await
        .map_err(|_| SAFE_ERROR.to_owned())?;
    let value = capability
        .json(ctx, &format!("assets/{}", key.asset_id), "GET", None)
        .await
        .map_err(|_| SAFE_ERROR.to_owned())?;
    capability
        .status(ctx)
        .await
        .map_err(|_| SAFE_ERROR.to_owned())?;
    Ok(value)
}
pub(crate) async fn prepare(
    ctx: &crate::app::Context,
    capability: crate::immich_archive::VisibilityAuthority,
    key: AssetKey,
    to: ImmichVisibility,
    id: String,
) -> Result<PreparedVisibility, String> {
    capability.verify_write_contract(ctx).await?;
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
        selected_observation: None,
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
            // Only a newer full original-policy proof supersedes fallback evidence.
            operation.selected_observation = None;
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
    let Ok(value) = fresh_value(ctx, &capability, &operation.key).await else {
        return VisibilityCompletion {
            selected_projection: None,
            recovery_proof: None,
            projection: None,
            state: before,
            uncertain: false,
            status: SAFE_ERROR.into(),
        };
    };
    let facts = match capability.facts(&value) {
        Ok(facts) if facts.witness == operation.witness_digest => facts,
        _ => return inspect_selected(ctx, before, capability, operation, value).await,
    };
    let mut desired = before.clone();
    observe(&mut desired, &facts, capability.kind());
    let (state, uncertain, committed, recovery_proof) =
        persist(ctx, &before, &desired, &capability).await;
    VisibilityCompletion {
        selected_projection: None,
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
async fn inspect_selected(
    ctx: &crate::app::Context,
    before: crate::app::SavedLibrary,
    capability: crate::immich_archive::VisibilityAuthority,
    operation: ImmichVisibilityOperation,
    value: serde_json::Value,
) -> VisibilityCompletion {
    let Ok(facts) = super::selected_facts(&value, &operation, capability.owner()) else {
        return VisibilityCompletion {
            selected_projection: None,
            recovery_proof: None,
            projection: None,
            state: before,
            uncertain: false,
            status: SAFE_ERROR.into(),
        };
    };
    let mut desired = before.clone();
    let Some(record) = desired
        .immich_visibility_operations
        .iter_mut()
        .find(|o| o.id == operation.id)
    else {
        return VisibilityCompletion {
            selected_projection: None,
            recovery_proof: None,
            projection: None,
            state: before,
            uncertain: false,
            status: SAFE_ERROR.into(),
        };
    };
    record.selected_observation = Some(facts.observation.clone());
    let (state, uncertain, committed, recovery_proof) =
        persist(ctx, &before, &desired, &capability).await;
    let status = if committed {
        "選択した項目の現在の状態を保存しました。構成が変わっているため、表示先の変更と通常の一覧表示は引き続き利用できません。"
    } else {
        "確認した状態を保存できませんでした。変更は再送しないでください。"
    }.into();
    VisibilityCompletion {
        selected_projection: if committed && !uncertain {
            capability.selected_projection(operation.id, facts)
        } else {
            None
        },
        recovery_proof,
        projection: None,
        state,
        uncertain,
        status,
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
            selected_projection: None,
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
        })
        && capability.verify_write_contract(ctx).await.is_ok()
    {
        capability.mutate_visibility(ctx, &prepared.operation).await
    } else {
        if let Some(operation) = desired.immich_visibility_operations.last_mut() {
            operation.outcome = VisibilityOutcome::NotApplied;
        }
        let (state, uncertain, _, recovery_proof) =
            persist(ctx, &durable, &desired, &capability).await;
        return VisibilityCompletion {
            selected_projection: None,
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
        selected_projection: None,
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
