//! Read-only inspection and explicit retirement of never-submitted steps.
use super::{
    Arc, Authority, BTreeSet, Command, Context, ERROR, Effect, Event, Model, Ordering,
    SavedLibrary, ShellOperation, durable, io, prepare,
};
use crate::{
    domain::AssetKey,
    immich_live_writes::{
        Batch, Fact, Forward, LiveKeepPrompt, LiveKeepTarget, LivePlacementPromptAlias,
        LivePlacementPromptResource, Media, MemberObservation, ObservationFailure, ObservedState,
        Outcome, Placement, ResourceObservation, Role, StepRef, UnstartedClosure, closure_digest,
        retired_outcomes_digest, validate, validate_library, validate_transition,
    },
};

#[derive(Debug)]
pub(super) struct Work {
    owner: Arc<()>,
    authority: Authority,
    batch_id: String,
    closure: Option<(String, Vec<String>)>,
    prompt: Option<LiveKeepPrompt>,
}
#[derive(Debug, Clone)]
pub struct Completion {
    owner: Arc<()>,
    stage: Stage,
}
#[derive(Debug, Clone)]
enum Stage {
    Observed(Result<Vec<(ResourceObservation, String)>, String>),
    Diagnostic(Vec<MemberObservation>),
    Finished(Box<Result<SavedLibrary, RecoveryFailure>>),
}
#[derive(Debug, Clone)]
struct RecoveryFailure {
    durable: Option<durable::SaveFailure>,
    message: String,
}
pub(crate) fn prompt(model: &Model) -> Option<LiveKeepPrompt> {
    let work = model.live_placement.recovery.as_ref()?;
    work.authority.valid().ok()?;
    work.prompt.clone()
}
pub(crate) fn update(event: &Event, model: &mut Model) -> Option<Command<Effect, Event>> {
    match event {
        Event::InspectImmichLivePlacement {
            batch_id,
            request_id,
            grant_id,
            scene_id,
        } => Some(begin(model, batch_id, request_id, None, grant_id, scene_id)),
        Event::KeepImmichLivePlacement {
            batch_id,
            closure_id,
            step_ids,
            grant_id,
            scene_id,
        } => Some(begin(
            model,
            batch_id,
            closure_id,
            Some(step_ids.clone()),
            grant_id,
            scene_id,
        )),
        Event::ImmichLiveRecoveryCompleted { completion } => {
            Some(completed(model, completion.clone()))
        }
        _ => None,
    }
}
fn begin(
    model: &mut Model,
    batch_id: &str,
    id: &str,
    steps: Option<Vec<String>>,
    grant: &str,
    scene: &str,
) -> Command<Effect, Event> {
    if model.busy
        || !model.ready
        || model.live_placement.work.is_some()
        || model.live_placement.recovery.is_some()
        || !model.live_placement.held.is_empty()
        || model.live_placement.persistence_uncertain
        || model.immich_visibility.persistence_uncertain
        || crate::immich::valid_id(id).is_err()
        || validate_library(&model.state).is_err()
    {
        return Command::done();
    }
    let Some(batch) = model
        .state
        .immich_live_operations
        .iter()
        .find(|b| b.id == batch_id)
    else {
        return Command::done();
    };
    let Some(session) = crate::immich_locked::visibility_session(model, grant, scene) else {
        return Command::done();
    };
    if batch.intent.scope != session.scope() || batch.intent.owner_id != session.owner() {
        return Command::done();
    }
    if let Some(selected) = &steps {
        let unique: BTreeSet<_> = selected.iter().collect();
        if selected.is_empty()
            || unique.len() != selected.len()
            || selected.iter().any(|id| {
                !batch.steps.iter().any(|s| {
                    s.id == *id
                        && matches!(s.outcome, Outcome::NotStarted)
                        && !super::super::references::closed(&model.state, batch, s)
                })
            })
        {
            return Command::done();
        }
    }
    let epoch = model.live_placement.epoch.clone();
    let expected = epoch.fetch_add(1, Ordering::SeqCst) + 1;
    let owner = Arc::new(());
    let authority = Authority {
        owner: owner.clone(),
        session,
        baseline: Arc::new(model.state.clone()),
        epoch,
        expected,
        ordinary: model.ordinary_generation.clone(),
        expected_ordinary: model.ordinary_generation.load(Ordering::SeqCst),
        protection: model.protection.generation.clone(),
        expected_protection: model.protection.generation.load(Ordering::SeqCst),
    };
    let steps_is_keep = steps.is_some();
    model.live_placement.recovery = Some(Work {
        owner: owner.clone(),
        authority: authority.clone(),
        batch_id: batch_id.into(),
        closure: steps.map(|steps| (id.into(), steps)),
        prompt: None,
    });
    model.busy = true;
    model.error = None;
    let batch = batch.clone();
    Command::new(move |ctx| async move {
        let stage = if steps_is_keep {
            Stage::Observed(observe(&ctx, &authority, &batch).await)
        } else {
            Stage::Diagnostic(diagnostic(&ctx, &authority, &batch).await)
        };
        ctx.send_event(Event::ImmichLiveRecoveryCompleted {
            completion: Completion { owner, stage },
        });
    })
}
async fn observe(
    ctx: &Context,
    authority: &Authority,
    batch: &Batch,
) -> Result<Vec<(ResourceObservation, String)>, String> {
    let mut graph = Vec::new();
    for resource in &batch.intent.resources {
        let role = if resource.initial.media == Media::Image {
            Role::Parent
        } else {
            Role::Motion
        };
        let item = prepare::observe(ctx, authority, &resource.initial.key, role).await?;
        if !validate::same_identity(&resource.initial, &item.0.fact) {
            return Err(ERROR.into());
        }
        graph.push(item);
    }
    authority.valid()?;
    Ok(graph)
}
fn completed(model: &mut Model, completion: Completion) -> Command<Effect, Event> {
    let Some(work) = model.live_placement.recovery.as_ref() else {
        return Command::done();
    };
    if !Arc::ptr_eq(&work.owner, &completion.owner) {
        return Command::done();
    }
    let authority = work.authority.clone();
    let batch_id = work.batch_id.clone();
    let closure = work.closure.clone();
    match completion.stage {
        Stage::Diagnostic(observations) => {
            let mut desired = authority.baseline.as_ref().clone();
            let Some(batch) = desired
                .immich_live_operations
                .iter_mut()
                .find(|batch| batch.id == batch_id)
            else {
                return Command::done();
            };
            batch.latest_observations = observations;
            let owner = completion.owner;
            Command::new(move |ctx| async move {
                let result = durable::save(&ctx, &authority.baseline, &desired)
                    .await
                    .map_err(|failure| RecoveryFailure {
                        durable: Some(failure),
                        message: "観測記録の保存を確認できません。".into(),
                    });
                ctx.send_event(Event::ImmichLiveRecoveryCompleted {
                    completion: Completion {
                        owner,
                        stage: Stage::Finished(Box::new(result)),
                    },
                });
            })
        }
        Stage::Observed(result) => {
            let graph = match result.and_then(|graph| authority.valid().map(|()| graph)) {
                Ok(graph) => graph,
                Err(error) => {
                    model.error = Some(error);
                    model.busy = false;
                    model.live_placement.recovery = None;
                    return Command::done();
                }
            };
            let Some(batch) = authority
                .baseline
                .immich_live_operations
                .iter()
                .find(|b| b.id == batch_id)
                .cloned()
            else {
                return Command::done();
            };
            let prompt = closure
                .as_ref()
                .map(|(id, steps)| keep_prompt(&authority, &batch, &graph, id, steps));
            if let Some(work) = model.live_placement.recovery.as_mut() {
                work.prompt.clone_from(&prompt);
            }
            let owner = completion.owner;
            Command::new(move |ctx| async move {
                let result =
                    save_observation(&ctx, &authority, &batch, graph, closure, prompt).await;
                ctx.send_event(Event::ImmichLiveRecoveryCompleted {
                    completion: Completion {
                        owner,
                        stage: Stage::Finished(Box::new(result)),
                    },
                });
            })
        }
        Stage::Finished(result) => finish_saved(model, *result),
    }
}
async fn save_observation(
    ctx: &Context,
    authority: &Authority,
    batch: &Batch,
    graph: Vec<(ResourceObservation, String)>,
    closure: Option<(String, Vec<String>)>,
    prompt: Option<LiveKeepPrompt>,
) -> Result<SavedLibrary, RecoveryFailure> {
    let failure = || RecoveryFailure {
        durable: None,
        message: "確認が取り消されたか、現在の状態が変わりました。記録は保存していません。".into(),
    };
    authority.valid().map_err(|_| failure())?;
    if let Some(prompt) = prompt {
        let confirmed: bool = io(ctx, ShellOperation::ConfirmImmichLiveKeep { prompt })
            .await
            .map_err(|_| failure())?;
        authority.valid().map_err(|_| failure())?;
        if !confirmed {
            return Err(failure());
        }
    }
    // Metadata observation is read-only: never require the 3.3.3 write grant.
    let current = observe(ctx, authority, batch)
        .await
        .map_err(|_| failure())?;
    if graph != current {
        return Err(failure());
    }
    let mut desired = authority.baseline.as_ref().clone();
    let target = desired
        .immich_live_operations
        .iter_mut()
        .find(|b| b.id == batch.id)
        .ok_or_else(failure)?;
    target.latest_observations = graph
        .iter()
        .map(|(item, _)| MemberObservation {
            key: item.fact.key.clone(),
            state: ObservedState::Own(Box::new(item.fact.clone())),
        })
        .collect();
    if let Some((id, steps)) = closure {
        let mut record = UnstartedClosure {
            format_version: 1,
            id,
            references: steps
                .into_iter()
                .map(|step_id| {
                    Ok(StepRef {
                        batch_id: batch.id.clone(),
                        step_id,
                        intent_digest: batch.intent.digest.clone(),
                        retired_outcomes_digest: retired_outcomes_digest(batch)?,
                    })
                })
                .collect::<Result<Vec<_>, String>>()
                .map_err(|_| failure())?,
            current_graph: graph.into_iter().map(|(item, _)| item).collect(),
            digest: String::new(),
        };
        record.digest = closure_digest(&record).map_err(|_| failure())?;
        desired.immich_live_unstarted_closures.push(record);
    }
    validate_transition(&authority.baseline, &desired).map_err(|_| failure())?;
    authority.valid().map_err(|_| failure())?;
    durable::save(ctx, &authority.baseline, &desired)
        .await
        .map_err(|failure| RecoveryFailure {
            durable: Some(failure),
            message: "観測記録の保存を確認できません。元の処理は再送しません。".into(),
        })
}

// Diagnostic observations are not freshness proofs. A changed own checksum or
// edge is reported as observed and never changes the historical step outcome.
async fn diagnostic(ctx: &Context, authority: &Authority, batch: &Batch) -> Vec<MemberObservation> {
    let mut values = Vec::new();
    for resource in &batch.intent.resources {
        let key = resource.initial.key.clone();
        let state = if authority.valid().is_err() {
            ObservedState::NotObserved
        } else {
            match authority
                .session
                .json(ctx, &format!("assets/{}", key.asset_id), "GET", None)
                .await
            {
                Ok(raw) => match diagnostic_fact(&raw, &resource.initial) {
                    Ok(fact) => ObservedState::Own(Box::new(fact)),
                    Err(failure) => ObservedState::Unavailable(failure),
                },
                Err(_) => ObservedState::Unavailable(ObservationFailure::Unavailable),
            }
        };
        values.push(MemberObservation { key, state });
    }
    values
}
fn diagnostic_fact(raw: &serde_json::Value, initial: &Fact) -> Result<Fact, ObservationFailure> {
    let malformed = ObservationFailure::Malformed;
    if raw["id"].as_str() != Some(&initial.key.asset_id)
        || raw["ownerId"].as_str() != Some(&initial.owner_id)
    {
        return Err(ObservationFailure::IdentityMismatch);
    }
    let mut fact = initial.clone();
    fact.media = match raw["type"].as_str() {
        Some("IMAGE") => Media::Image,
        Some("VIDEO") => Media::Video,
        _ => return Err(malformed),
    };
    fact.checksum = crate::domain::normalize_sha1(raw["checksum"].as_str()).ok_or(malformed)?;
    fact.revision = raw["updatedAt"]
        .as_str()
        .filter(|v| !v.trim().is_empty())
        .ok_or(malformed)?
        .into();
    fact.placement = match raw["visibility"].as_str() {
        Some("timeline") => Placement::Timeline,
        Some("archive") => Placement::Archive,
        Some("hidden") => Placement::Hidden,
        Some("locked") => Placement::Locked,
        _ => return Err(malformed),
    };
    fact.forward = match raw.get("livePhotoVideoId") {
        Some(serde_json::Value::Null) => Forward::Unlinked,
        Some(serde_json::Value::String(id))
            if crate::immich::valid_id(id).is_ok() && *id != initial.key.asset_id =>
        {
            Forward::Linked(AssetKey {
                asset_id: id.clone(),
                ..initial.key.clone()
            })
        }
        _ => return Err(malformed),
    };
    fact.unstacked = match raw.get("stack") {
        Some(serde_json::Value::Null) => true,
        Some(serde_json::Value::Object(_)) => false,
        _ => return Err(malformed),
    };
    fact.offline = raw["isOffline"].as_bool().ok_or(malformed)?;
    fact.trashed = raw["isTrashed"].as_bool().ok_or(malformed)?;
    Ok(fact)
}

fn keep_prompt(
    authority: &Authority,
    batch: &Batch,
    graph: &[(ResourceObservation, String)],
    id: &str,
    steps: &[String],
) -> LiveKeepPrompt {
    LiveKeepPrompt {
                targets: steps.iter().filter_map(|id| {
                    let step = batch.steps.iter().find(|step| step.id == *id)?;
                    let resource = validate::resource(&batch.intent, &step.resource_id).ok()?;
                    let (_, name) = graph.iter().find(|(item, _)| item.fact.key == resource.initial.key)?;
                    Some(LiveKeepTarget { step_id: id.clone(), key: resource.initial.key.clone(), name: name.clone() })
                }).collect(),
                batch_id: batch.id.clone(), closure_id: id.into(), grant_id: authority.session.grant_id.clone(),
                scene_id: authority.session.scene_id.clone(), generation: authority.session.expected,
                resources: graph.iter().map(|(item, name)| LivePlacementPromptResource {
                    key: item.fact.key.clone(), name: name.clone(), role: if item.fact.media == Media::Image { Role::Parent } else { Role::Motion },
                    from: item.fact.placement, to: item.fact.placement, album_count: u32::try_from(item.albums.len()).unwrap_or(u32::MAX),
                    unchanged: true, removes_all_album_membership: false,
                }).collect(),
                aliases: batch.intent.edges.iter().filter_map(|edge| {
                    Some(LivePlacementPromptAlias { parent_key: validate::resource(&batch.intent, &edge.parent_resource).ok()?.initial.key.clone(),
                        motion_key: validate::resource(&batch.intent, &edge.motion_resource).ok()?.initial.key.clone() })
                }).collect(),
                explanation: "現在確認できた配置を維持し、選択した未送信項目だけを終了します。原本への書込みは行いません。送信結果が不明な項目は不明のまま履歴に残り、成功として扱いません。元の処理は再開されません。".into(),

}
}

fn finish_saved(
    model: &mut Model,
    result: Result<SavedLibrary, RecoveryFailure>,
) -> Command<Effect, Event> {
    let (state, uncertain, saved) = match result {
        Ok(state) => (Some(state), false, true),
        Err(failure) => {
            model.error = Some(failure.message);
            let uncertain = failure
                .durable
                .as_ref()
                .is_some_and(|failure| failure.uncertain);
            (
                failure.durable.and_then(|failure| failure.state),
                uncertain,
                false,
            )
        }
    };
    model.live_placement.persistence_uncertain |= uncertain;
    if let Some(state) = state {
        if validate_transition(&model.state, &state).is_ok() {
            model.state.immich_live_operations = state.immich_live_operations;
            model.state.immich_live_unstarted_closures = state.immich_live_unstarted_closures;
            model.state.immich_live_legacy_reconciliations =
                state.immich_live_legacy_reconciliations;
        } else {
            model.live_placement.persistence_uncertain = true;
        }
    }
    model.status = if saved && !model.live_placement.persistence_uncertain {
        "現在の観測を記録しました。過去の送信結果は変更していません。"
    } else {
        "観測記録を完了できませんでした。元の処理は再送しません。"
    }
    .into();
    if model.live_placement.persistence_uncertain {
        model.error = Some(ERROR.into());
    }
    model.busy = false;
    model.live_placement.recovery = None;
    Command::done()
}
