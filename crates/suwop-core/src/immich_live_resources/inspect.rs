use super::{
    Authority, Completion, ERROR, ImmichLiveResourcePlan, ImmichLiveResourcesView,
    LiveAdditionalParent, LiveDiscoveryTermination, LiveParentObservation, LiveResourceReadFact,
    LiveResourceRole, child, fact, read_denied, uuid,
};
use crate::{
    app::{Context, Event, Model},
    domain::{AssetKey, Provider},
};
use crux_core::Command;
use serde_json::Value;
use serde_json::json;
use std::sync::atomic::Ordering;
const PAGE_SIZE: u32 = 100;
const MAX_PAGES: u32 = 8;
pub(super) fn begin(
    model: &mut Model,
    key: AssetKey,
    request_id: String,
    grant: &str,
    scene: &str,
) -> Command<crate::app::Effect, Event> {
    if model.busy
        || !model.ready
        || model.state.schema_version != crate::immich_live_writes::CURRENT_SCHEMA_VERSION
        || model.immich_visibility.persistence_uncertain
        || model.protection.membership_uncertain
        || read_denied(model, &key)
        || !uuid(&request_id)
        || !uuid(&key.asset_id)
    {
        return Command::done();
    }
    let Some(session) = crate::immich_locked::visibility_session(model, grant, scene) else {
        return Command::done();
    };
    if key.provider != Provider::Immich || key.scope != session.scope() {
        return Command::done();
    }
    let mut blocked: std::collections::BTreeSet<AssetKey> = model
        .protection
        .denied
        .iter()
        .chain(model.immich_visibility.denied.iter())
        .cloned()
        .chain(model.state.protected_entries.iter().map(|e| e.key.clone()))
        .collect();
    for operation in &model.state.immich_visibility_operations {
        if read_denied(model, &operation.key) {
            blocked.insert(operation.key.clone());
        }
    }
    let state = &mut model.immich_live_resources;
    let expected = state.epoch.fetch_add(1, Ordering::SeqCst) + 1;
    let authority = Authority {
        blocked,
        session,
        epoch: state.epoch.clone(),
        expected,
        ordinary: model.ordinary_generation.clone(),
        ordinary_expected: model.ordinary_generation.load(Ordering::SeqCst),
        protection: model.protection.generation.clone(),
        protection_expected: model.protection.generation.load(Ordering::SeqCst),
    };
    state.authority = Some(authority.clone());
    state.view = Some(ImmichLiveResourcesView {
        request_id: request_id.clone(),
        pending: true,
        plan: None,
        error: None,
    });
    Command::new(move |ctx| async move {
        let result = run(&ctx, &authority, &key).await;
        ctx.send_event(Event::ImmichLiveResourcesInspected {
            completion: Completion {
                authority,
                request_id,
                result,
            },
        });
    })
}
async fn pair(
    ctx: &Context,
    a: &Authority,
    key: &AssetKey,
) -> Result<Vec<LiveResourceReadFact>, String> {
    let parent = a
        .json(ctx, &format!("assets/{}", key.asset_id), None)
        .await?;
    let parent_fact = fact(&parent, key, a.session.owner(), LiveResourceRole::Parent)?;
    let id = child(&parent)?;
    if id == key.asset_id {
        return Err(ERROR.into());
    }
    let motion_key = AssetKey {
        asset_id: id.into(),
        ..key.clone()
    };
    if a.blocked.contains(&motion_key) {
        return Err(ERROR.into());
    }
    let motion = a.json(ctx, &format!("assets/{id}"), None).await?;
    if motion.get("livePhotoVideoId") != Some(&Value::Null) {
        return Err(ERROR.into());
    }
    Ok(vec![
        parent_fact,
        fact(
            &motion,
            &motion_key,
            a.session.owner(),
            LiveResourceRole::Motion,
        )?,
    ])
}
async fn discover(
    ctx: &Context,
    a: &Authority,
    targets: &[LiveResourceReadFact],
) -> Result<LiveParentObservation, String> {
    let mut result = LiveParentObservation {
        parents: vec![],
        malformed_candidates: 0,
        protected_candidates: 0,
        pages_observed: 0,
        observations: 0,
        termination: LiveDiscoveryTermination::PageBudget,
        graph_complete: false,
    };
    let mut cursor = None;
    let mut seen = std::collections::BTreeSet::new();
    for _ in 0..MAX_PAGES {
        a.valid()?;
        let mut body = json!({"size":PAGE_SIZE,"withStacked":true,"filter":{"type":{"eq":"IMAGE"},"isMotion":{"eq":true},"visibility":{"in":["timeline","archive","hidden","locked"]}}});
        if let Some(value) = &cursor {
            body["cursor"] = json!(value);
        }
        let Ok(raw) = a.json(ctx, "search/metadata", Some(body)).await else {
            a.valid()?;
            result.termination = LiveDiscoveryTermination::Unavailable;
            return Ok(result);
        };
        result.pages_observed += 1;
        let Some(items) = raw["assets"]["items"]
            .as_array()
            .filter(|v| v.len() <= PAGE_SIZE as usize)
        else {
            result.termination = LiveDiscoveryTermination::Unavailable;
            return Ok(result);
        };
        for item in items {
            result.observations += 1;
            match candidate(item, a, targets) {
                Ok(Some(parent)) if !result.parents.iter().any(|p| p.key == parent.key) => {
                    result.parents.push(parent);
                }
                Ok(_) => {}
                Err(CandidateFailure::Malformed) => result.malformed_candidates += 1,
                Err(CandidateFailure::Protected) => result.protected_candidates += 1,
            }
        }
        match raw["assets"].get("nextCursor") {
            Some(Value::Null) => {
                result.termination =
                    if result.malformed_candidates == 0 && result.protected_candidates == 0 {
                        LiveDiscoveryTermination::ExhaustedPages
                    } else {
                        LiveDiscoveryTermination::Unavailable
                    };
                return Ok(result);
            }
            Some(Value::String(next)) if !next.is_empty() && seen.insert(next.clone()) => {
                cursor = Some(next.clone());
            }
            _ => {
                result.termination = LiveDiscoveryTermination::Unavailable;
                return Ok(result);
            }
        }
    }
    Ok(result)
}
async fn run(
    ctx: &Context,
    a: &Authority,
    key: &AssetKey,
) -> Result<ImmichLiveResourcePlan, String> {
    a.session.status(ctx).await?;
    let targets = pair(ctx, a, key).await?;
    let additional_parents = discover(ctx, a, &targets).await?;
    if pair(ctx, a, key).await? != targets {
        return Err(ERROR.into());
    }
    a.session.status(ctx).await?;
    a.valid()?;
    let mut nonce = [0u8; 16];
    getrandom::getrandom(&mut nonce).map_err(|_| ERROR)?;
    Ok(ImmichLiveResourcePlan {
        plan_id: crate::domain::hex(&nonce),
        read_targets: targets,
        additional_parents,
    })
}

enum CandidateFailure {
    Malformed,
    Protected,
}
impl From<()> for CandidateFailure {
    fn from((): ()) -> Self {
        Self::Malformed
    }
}

fn candidate(
    item: &Value,
    a: &Authority,
    targets: &[LiveResourceReadFact],
) -> Result<Option<LiveAdditionalParent>, CandidateFailure> {
    let owner = item["ownerId"].as_str().ok_or(())?;
    if owner != a.session.owner() {
        return Ok(None);
    }
    let id = item["id"].as_str().filter(|id| uuid(id)).ok_or(())?;
    if item["type"].as_str() != Some("IMAGE") {
        return Err(CandidateFailure::Malformed);
    }
    let key = AssetKey {
        asset_id: id.into(),
        ..targets[0].key.clone()
    };
    if a.blocked.contains(&key) {
        return Err(CandidateFailure::Protected);
    }
    let revision = item["updatedAt"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or(())?;
    let linked = child(item).map_err(|_| ())?;
    if linked != targets[1].key.asset_id || key == targets[0].key {
        return Ok(None);
    }
    Ok(Some(LiveAdditionalParent {
        key,
        revision: revision.into(),
        visibility: serde_json::from_value(item["visibility"].clone()).ok(),
        is_offline: item["isOffline"].as_bool(),
        is_trashed: item["isTrashed"].as_bool(),
        has_stack: item.get("stack").map(|s| !s.is_null()),
    }))
}
