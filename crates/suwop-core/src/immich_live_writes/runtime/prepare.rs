//! Fresh graph construction. Values returned here remain preflight data, never grants.
use super::{Authority, ERROR, Explicit, Prepared, issued_id};
use crate::{
    app::Context,
    domain::AssetKey,
    immich_live_writes::{
        Alias, Batch, Dependency, Direction, Edge, Fact, Forward, Intent, LivePlacementDestination,
        LivePlacementPrompt, LivePlacementPromptAlias, LivePlacementPromptResource, Media, Outcome,
        Placement, Resource, ResourceObservation, Role, Selection, Step, StepRef, intent_digest,
        retired_outcomes_digest, validate, validate_library,
    },
};
use std::collections::{BTreeMap, BTreeSet};

pub(super) async fn observe(
    ctx: &Context,
    authority: &Authority,
    key: &AssetKey,
    role: Role,
) -> Result<(ResourceObservation, String), String> {
    authority.valid()?;
    let raw = authority
        .session
        .json(ctx, &format!("assets/{}", key.asset_id), "GET", None)
        .await?;
    let read = crate::immich_live_resources::fact(
        &raw,
        key,
        authority.session.owner(),
        match role {
            Role::Parent => crate::immich_live_resources::LiveResourceRole::Parent,
            Role::Motion => crate::immich_live_resources::LiveResourceRole::Motion,
        },
    )?;
    let forward = match (role, raw.get("livePhotoVideoId")) {
        (Role::Parent, Some(serde_json::Value::String(id))) => {
            crate::immich::valid_id(id)?;
            Forward::Linked(AssetKey {
                asset_id: id.clone(),
                ..key.clone()
            })
        }
        (Role::Motion, Some(serde_json::Value::Null)) => Forward::Unlinked,
        _ => return Err(ERROR.into()),
    };
    let fact = Fact {
        key: key.clone(),
        owner_id: authority.session.owner().into(),
        media: if role == Role::Parent {
            Media::Image
        } else {
            Media::Video
        },
        checksum: read.checksum,
        revision: read.revision,
        placement: match read.visibility {
            crate::immich_live_resources::LiveObservedVisibility::Timeline => Placement::Timeline,
            crate::immich_live_resources::LiveObservedVisibility::Archive => Placement::Archive,
            crate::immich_live_resources::LiveObservedVisibility::Hidden => Placement::Hidden,
            crate::immich_live_resources::LiveObservedVisibility::Locked => Placement::Locked,
        },
        forward,
        unstacked: true,
        offline: false,
        trashed: false,
    };
    let memberships = authority
        .session
        .json(
            ctx,
            &format!("albums?assetId={}", key.asset_id),
            "GET",
            None,
        )
        .await?;
    let albums = memberships.as_array().ok_or(ERROR)?;
    let mut ids = BTreeSet::new();
    for album in albums {
        let id = album["id"].as_str().ok_or(ERROR)?;
        crate::immich::valid_id(id)?;
        if !ids.insert(id.to_owned()) {
            return Err(ERROR.into());
        }
    }
    authority.valid()?;
    let name = raw["originalFileName"]
        .as_str()
        .filter(|name| !name.is_empty())
        .ok_or(ERROR)?
        .to_owned();
    Ok((
        ResourceObservation {
            fact,
            albums: ids.into_iter().collect(),
        },
        name,
    ))
}

pub(super) async fn prepare(
    ctx: &Context,
    authority: Authority,
    parents: Vec<AssetKey>,
    destination: LivePlacementDestination,
    batch_id: String,
    explicit: Option<Explicit>,
) -> Result<Prepared, String> {
    authority.session.verify_write_contract(ctx).await?;
    authority.valid()?;
    let Discovered {
        facts,
        names,
        pairs,
    } = discover(ctx, &authority, &parents).await?;
    let (direction, resources) = resources_for(&facts, explicit.as_ref(), destination, &batch_id)?;
    let supersedes = supersedes(&authority.baseline, explicit.as_ref())?;
    check_history(&authority.baseline, &resources, &supersedes)?;
    let Relations {
        selections,
        edges,
        aliases,
        dependencies,
    } = relations(&resources, &pairs, &batch_id, direction)?;
    let mut changing: Vec<_> = resources.iter().filter(|r| r.step_id.is_some()).collect();
    changing.sort_by_key(|r| match (direction, r.initial.media) {
        (Direction::Reposition, Media::Image) if r.destination == Placement::Locked => 0,
        (Direction::Reposition, Media::Video) if r.destination == Placement::Locked => 1,
        (Direction::Reposition, Media::Video) => 2,
        (Direction::Reposition, Media::Image) => 3,
        (Direction::Lock, Media::Image) | (Direction::Restore, Media::Video) => 0,
        _ => 1,
    });
    let mut steps = Vec::new();
    for resource in changing {
        let id = resource.step_id.clone().ok_or(ERROR)?;
        let outcome = if steps.is_empty() {
            Outcome::Unknown {
                attempt_id: issued_id(&batch_id, &format!("attempt:{id}")),
                accepted: None,
            }
        } else {
            Outcome::NotStarted
        };
        steps.push(Step {
            id,
            resource_id: resource.id.clone(),
            outcome,
        });
    }
    if steps.is_empty() {
        return Err("関連原本はすでに指定した表示先です。".into());
    }
    let mut intent = Intent {
        encoding_version: 1,
        owner_id: authority.session.owner().into(),
        scope: authority.session.scope().into(),
        direction,
        selections,
        resources,
        edges,
        aliases,
        observed_additional_parents: Vec::new(),
        shared_reference_limitations_acknowledged: true,
        dependencies: dependencies
            .into_iter()
            .map(|(before, after)| Dependency { before, after })
            .collect(),
        ordered_step_ids: steps.iter().map(|step| step.id.clone()).collect(),
        supersedes,
        digest: String::new(),
    };
    intent.digest = intent_digest(&intent)?;
    let batch = Batch {
        format_version: 1,
        id: batch_id.clone(),
        intent,
        steps,
        latest_observations: Vec::new(),
    };
    let mut check = authority.baseline.as_ref().clone();
    check.immich_live_operations.push(batch.clone());
    validate_library(&check)?;
    let prompt = confirmation_prompt(&authority, &batch, &names, pairs);
    Ok(Prepared {
        authority,
        batch,
        prompt,
    })
}

fn check_history(
    state: &crate::app::SavedLibrary,
    resources: &[Resource],
    supersedes: &[StepRef],
) -> Result<(), String> {
    for resource in resources {
        let key = &resource.initial.key;
        if state
            .protected_entries
            .iter()
            .any(|entry| entry.key == *key)
        {
            return Err(ERROR.into());
        }
        for batch in &state.immich_live_operations {
            let Some(prior) = batch
                .intent
                .resources
                .iter()
                .find(|r| r.initial.key == *key)
            else {
                continue;
            };
            if !validate::same_identity(&prior.initial, &resource.initial) {
                return Err(ERROR.into());
            }
            for step in &batch.steps {
                if matches!(step.outcome, Outcome::Unknown { .. })
                    || (matches!(step.outcome, Outcome::NotStarted)
                        && !super::super::references::closed(state, batch, step)
                        && !supersedes.iter().any(|reference| {
                            reference.batch_id == batch.id && reference.step_id == step.id
                        }))
                {
                    return Err("未確定または未開始の変更記録があります。現在の状態と残りの操作を確認してください。".into());
                }
            }
        }
        for record in state
            .immich_visibility_operations
            .iter()
            .filter(|record| record.key == *key)
        {
            if record.outcome == crate::apple_visibility::VisibilityOutcome::Unknown {
                return Err(ERROR.into());
            }
            let digest = match resource.initial.media {
                Media::Image => crate::immich_visibility::original_image_identity_digest(
                    key,
                    &resource.initial.checksum,
                ),
                Media::Video => crate::immich_visibility::original_video_identity_digest(
                    key,
                    &resource.initial.checksum,
                ),
            };
            let matches = record.witness_digest == digest;
            if !matches {
                return Err(ERROR.into());
            }
        }
    }
    Ok(())
}

fn supersedes(
    state: &crate::app::SavedLibrary,
    explicit: Option<&Explicit>,
) -> Result<Vec<StepRef>, String> {
    let Some(explicit) = explicit else {
        return Ok(vec![]);
    };
    let Some(id) = &explicit.predecessor else {
        return if explicit.step_ids.is_empty() {
            Ok(vec![])
        } else {
            Err(ERROR.into())
        };
    };
    let old = state
        .immich_live_operations
        .iter()
        .find(|batch| batch.id == *id)
        .ok_or(ERROR)?;
    if old
        .steps
        .iter()
        .any(|step| matches!(step.outcome, Outcome::Unknown { .. }))
    {
        return Err(ERROR.into());
    }
    let ids: BTreeSet<_> = explicit.step_ids.iter().collect();
    let remaining: BTreeSet<_> = old
        .steps
        .iter()
        .filter(|step| {
            matches!(step.outcome, Outcome::NotStarted)
                && !super::super::references::closed(state, old, step)
        })
        .map(|step| &step.id)
        .collect();
    // Retire the original cursor as one explicit new plan; no hidden siblings
    // are left waiting for an implicit continuation.
    if ids.is_empty() || ids.len() != explicit.step_ids.len() || ids != remaining {
        return Err(ERROR.into());
    }
    let digest = retired_outcomes_digest(old)?;
    Ok(explicit
        .step_ids
        .iter()
        .map(|id| StepRef {
            batch_id: old.id.clone(),
            step_id: id.clone(),
            intent_digest: old.intent.digest.clone(),
            retired_outcomes_digest: digest.clone(),
        })
        .collect())
}

struct Discovered {
    facts: BTreeMap<AssetKey, ResourceObservation>,
    names: BTreeMap<AssetKey, String>,
    pairs: Vec<(AssetKey, AssetKey)>,
}
async fn discover(
    ctx: &Context,
    authority: &Authority,
    parents: &[AssetKey],
) -> Result<Discovered, String> {
    let mut facts = BTreeMap::new();
    let mut names = BTreeMap::new();
    let mut pairs = Vec::new();
    for parent in parents {
        let (p, name) = observe(ctx, authority, parent, Role::Parent).await?;
        let Forward::Linked(motion) = &p.fact.forward else {
            return Err(ERROR.into());
        };
        let motion = motion.clone();
        if parents.contains(&motion) {
            return Err(ERROR.into());
        }
        names.insert(parent.clone(), name);
        facts.insert(parent.clone(), p);
        if !facts.contains_key(&motion) {
            let (m, name) = observe(ctx, authority, &motion, Role::Motion).await?;
            names.insert(motion.clone(), name);
            facts.insert(motion.clone(), m);
        }
        pairs.push((parent.clone(), motion));
    }
    Ok(Discovered {
        facts,
        names,
        pairs,
    })
}

struct Relations {
    selections: Vec<Selection>,
    edges: Vec<Edge>,
    aliases: Vec<Alias>,
    dependencies: BTreeSet<(String, String)>,
}
fn relations(
    resources: &[Resource],
    pairs: &[(AssetKey, AssetKey)],
    batch_id: &str,
    direction: Direction,
) -> Result<Relations, String> {
    let by_key: BTreeMap<_, _> = resources
        .iter()
        .map(|r| (r.initial.key.clone(), r))
        .collect();
    let mut selections = Vec::new();
    let mut edges = Vec::new();
    let mut aliases = Vec::new();
    let mut dependencies = BTreeSet::new();
    for (parent, motion) in pairs {
        let p = by_key.get(parent).ok_or(ERROR)?;
        let m = by_key.get(motion).ok_or(ERROR)?;
        let selection_id = issued_id(batch_id, &format!("selection:{}", parent.asset_id));
        let edge_id = issued_id(batch_id, &format!("edge:{}", parent.asset_id));
        selections.push(Selection {
            id: selection_id.clone(),
            parent: parent.clone(),
        });
        edges.push(Edge {
            id: edge_id.clone(),
            selection_id,
            parent_resource: p.id.clone(),
            motion_resource: m.id.clone(),
        });
        for (role, resource) in [(Role::Parent, *p), (Role::Motion, *m)] {
            aliases.push(Alias {
                id: issued_id(batch_id, &format!("alias:{edge_id}:{role:?}")),
                edge_id: edge_id.clone(),
                resource_id: resource.id.clone(),
                role,
                destination: resource.destination,
            });
        }
        if let (Some(p), Some(m)) = (&p.step_id, &m.step_id) {
            dependencies.insert(
                if direction == Direction::Lock
                    || (direction == Direction::Reposition
                        && by_key.get(parent).ok_or(ERROR)?.destination == Placement::Locked)
                {
                    (p.clone(), m.clone())
                } else {
                    (m.clone(), p.clone())
                },
            );
        }
    }
    Ok(Relations {
        selections,
        edges,
        aliases,
        dependencies,
    })
}

fn confirmation_prompt(
    authority: &Authority,
    batch: &Batch,
    names: &BTreeMap<AssetKey, String>,
    pairs: Vec<(AssetKey, AssetKey)>,
) -> LivePlacementPrompt {
    LivePlacementPrompt {
        batch_id: batch.id.clone(), intent_digest: batch.intent.digest.clone(), grant_id: authority.session.grant_id.clone(),
        generation: authority.session.expected, scene_id: authority.session.scene_id.clone(),
        resources: batch.intent.resources.iter().map(|r| LivePlacementPromptResource {
            key: r.initial.key.clone(), name: names[&r.initial.key].clone(),
            role: if r.initial.media == Media::Image { Role::Parent } else { Role::Motion },
            from: r.initial.placement, to: r.destination, album_count: u32::try_from(r.initial_albums.len()).unwrap_or(u32::MAX),
            unchanged: r.step_id.is_none(), removes_all_album_membership: r.step_id.is_some() && r.destination == Placement::Locked,
        }).collect(),
        aliases: pairs.into_iter().map(|(parent_key, motion_key)| LivePlacementPromptAlias { parent_key, motion_key }).collect(),
        shared_reference_limitations_acknowledged: true,
        continuing_access_disclosure: "追加の関連写真の探索は完全な関係グラフを証明しません。選択した写真・動画だけを変更します。既存の共有リンクや別の関連原本からアクセスが続く場合があります。再表示してもアルバム所属は自動で戻りません。".into(),
    }
}

fn resources_for(
    facts: &BTreeMap<AssetKey, ResourceObservation>,
    explicit: Option<&Explicit>,
    destination: LivePlacementDestination,
    batch_id: &str,
) -> Result<(Direction, Vec<Resource>), String> {
    let targets = explicit
        .as_ref()
        .map(|value| {
            let values: BTreeMap<_, _> = value
                .destinations
                .iter()
                .map(|target| (target.key.clone(), target.destination))
                .collect();
            if values.len() != value.destinations.len()
                || values.len() != facts.len()
                || values.keys().any(|key| !facts.contains_key(key))
            {
                return Err(ERROR.to_owned());
            }
            Ok(values)
        })
        .transpose()?;
    let direction = if explicit.is_some() {
        Direction::Reposition
    } else if destination == LivePlacementDestination::Locked {
        Direction::Lock
    } else {
        Direction::Restore
    };
    let mut resources = Vec::new();
    for (key, observation) in facts {
        let to = if let Some(targets) = &targets {
            *targets.get(key).ok_or(ERROR)?
        } else {
            match (destination, observation.fact.media) {
                (LivePlacementDestination::Locked, _) => Placement::Locked,
                (_, _) if observation.fact.placement != Placement::Locked => {
                    observation.fact.placement
                }
                (_, Media::Video) => Placement::Hidden,
                (LivePlacementDestination::Timeline, _) => Placement::Timeline,
                (LivePlacementDestination::Archive, _) => Placement::Archive,
            }
        };
        let resource_id = issued_id(batch_id, &format!("resource:{}", key.asset_id));
        resources.push(Resource {
            id: resource_id.clone(),
            initial: observation.fact.clone(),
            initial_albums: observation.albums.clone(),
            destination: to,
            step_id: (observation.fact.placement != to)
                .then(|| issued_id(batch_id, &format!("step:{resource_id}"))),
        });
    }
    Ok((direction, resources))
}
