//! Gated presentation summaries; these values never grant an operation.
use crate::{
    app::Model,
    domain::{AssetKey, Provider},
    immich_live_writes::{Media, ObservedState, Outcome, Placement, original_continuation_open},
};
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementHistory {
    pub batches: Vec<LivePlacementHistoryBatch>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementHistoryBatch {
    #[serde(rename = "batchID")]
    pub batch_id: String,
    pub retired: bool,
    pub can_inspect: bool,
    pub can_new_intent: bool,
    pub resources: Vec<LivePlacementHistoryResource>,
    pub parent_keys: Vec<AssetKey>,
    #[serde(rename = "supersedesStepIDs")]
    pub supersedes_step_ids: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LivePlacementHistoryResource {
    pub key: AssetKey,
    pub name: String,
    #[serde(rename = "stepID")]
    pub step_id: Option<String>,
    pub historical_outcome: String,
    pub current_observation: String,
    pub can_keep: bool,
    pub allowed_destinations: Vec<Placement>,
    pub proposed_destination: Placement,
}
pub(crate) fn view(model: &Model) -> LivePlacementHistory {
    let locked = crate::immich_locked::view(model);
    if locked.state != crate::immich_locked::ImmichLockedState::Open {
        return LivePlacementHistory::default();
    }
    let Some(grant) = locked.grant_id else {
        return LivePlacementHistory::default();
    };
    let Some(scene) = locked.scene_id else {
        return LivePlacementHistory::default();
    };
    let Some(session) = crate::immich_locked::visibility_session(model, &grant, &scene) else {
        return LivePlacementHistory::default();
    };
    let idle = !model.busy
        && model.live_placement.work.is_none()
        && model.live_placement.recovery.is_none()
        && model.live_placement.held.is_empty()
        && !model.live_placement.persistence_uncertain;
    LivePlacementHistory {
        batches: model
            .state
            .immich_live_operations
            .iter()
            .filter(|batch| {
                batch.intent.scope == session.scope() && batch.intent.owner_id == session.owner()
            })
            .map(|batch| {
                let retired = !original_continuation_open(&model.state, &batch.id);
                LivePlacementHistoryBatch {
                    batch_id: batch.id.clone(),
                    retired,
                    can_inspect: idle,
                    can_new_intent: idle
                        && !batch
                            .steps
                            .iter()
                            .any(|step| matches!(step.outcome, Outcome::Unknown { .. })),
                    supersedes_step_ids: batch
                        .steps
                        .iter()
                        .filter(|step| {
                            matches!(step.outcome, Outcome::NotStarted)
                                && !super::super::references::closed(&model.state, batch, step)
                        })
                        .map(|step| step.id.clone())
                        .collect(),
                    parent_keys: batch
                        .intent
                        .selections
                        .iter()
                        .map(|selection| selection.parent.clone())
                        .collect(),
                    resources: resources_for(model, batch, idle),
                }
            })
            .collect(),
    }
}

pub(crate) fn candidates(public: &crate::privacy::PublishedLibrary) -> Vec<AssetKey> {
    public
        .snapshots
        .iter()
        .flat_map(|snapshot| &snapshot.assets)
        .filter(|asset| {
            asset.key.provider == Provider::Immich
                && asset
                    .resources
                    .iter()
                    .any(|r| r.role == crate::domain::ResourceRole::LiveVideo)
        })
        .map(|asset| asset.key.clone())
        .collect()
}

fn resources_for(
    model: &Model,
    batch: &super::Batch,
    idle: bool,
) -> Vec<LivePlacementHistoryResource> {
    batch
        .intent
        .resources
        .iter()
        .map(|resource| {
            let step = batch
                .steps
                .iter()
                .find(|step| step.resource_id == resource.id);
            let outcome = match step.map(|s| &s.outcome) {
                Some(Outcome::NotStarted) => "未送信",
                Some(Outcome::Unknown { .. }) => "送信結果不明（成功未確認）",
                Some(Outcome::Applied { .. }) => "この試行で適用を確認",
                Some(Outcome::NotApplied { .. }) => "未送信を確認",
                None => "変更対象外",
            };
            let observation = batch
                .latest_observations
                .iter()
                .find(|value| value.key == resource.initial.key)
                .map_or("未観測".into(), |value| match &value.state {
                    ObservedState::NotObserved => "未観測".into(),
                    ObservedState::Unavailable(_) => "現在の状態を確認できません".into(),
                    ObservedState::Own(fact) => format!(
                        "現在の観測: {}（過去の送信結果とは別）",
                        match fact.placement {
                            Placement::Timeline => "タイムライン",
                            Placement::Archive => "アーカイブ",
                            Placement::Hidden => "Immich hidden",
                            Placement::Locked => "ロック",
                        }
                    ),
                });
            LivePlacementHistoryResource {
                key: resource.initial.key.clone(),
                name: model
                    .state
                    .snapshots
                    .iter()
                    .flat_map(|snapshot| &snapshot.assets)
                    .find(|asset| asset.key == resource.initial.key)
                    .map_or_else(
                        || resource.initial.key.asset_id.clone(),
                        |asset| asset.name.clone(),
                    ),
                step_id: step.map(|s| s.id.clone()),
                historical_outcome: outcome.into(),
                current_observation: observation,
                allowed_destinations: if resource.initial.media == Media::Image {
                    vec![Placement::Timeline, Placement::Archive, Placement::Locked]
                } else {
                    vec![
                        Placement::Timeline,
                        Placement::Archive,
                        Placement::Hidden,
                        Placement::Locked,
                    ]
                },
                proposed_destination: batch
                    .latest_observations
                    .iter()
                    .find_map(|observation| {
                        if observation.key == resource.initial.key {
                            if let ObservedState::Own(fact) = &observation.state {
                                (resource.initial.media != Media::Image
                                    || fact.placement != Placement::Hidden)
                                    .then_some(fact.placement)
                            } else {
                                None
                            }
                        } else {
                            None
                        }
                    })
                    .unwrap_or(resource.destination),
                can_keep: idle
                    && step.is_some_and(|s| {
                        matches!(s.outcome, Outcome::NotStarted)
                            && !super::super::references::closed(&model.state, batch, s)
                    }),
            }
        })
        .collect()
}
