//! Deterministic serialization fixture only: no provider, session, native JOIN, or write authority.
//! Default stdout is Rust canonical JSON; --verify checks a Swift re-encoding from stdin.
use serde::{Deserialize, Serialize};
use sha2::Digest;
use std::io::{Read, Write};
use suwop_core::{
    app::SavedLibrary,
    domain::{AssetKey, Provider},
    immich_live_writes::{
        self as live, Accepted204, Alias, Batch, Dependency, Direction, Edge, Fact, Forward,
        Intent, LegacyReconciliation, LegacyRef, Media, MemberObservation, NoSubmissionRecord,
        ObservationFailure, ObservedState, Outcome, Placement, PostFacts, Resource,
        ResourceObservation, Role, Selection, Step, StepRef, UnstartedClosure,
    },
    immich_visibility::{
        AlbumMembershipObservation, ImmichVisibility, SelectedConfiguration,
        SelectedVisibilityObservation,
    },
};

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Case {
    name: String,
    library: SavedLibrary,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Corpus {
    format_version: u32,
    valid_states: Vec<Case>,
    /// Serde-only samples, NOT valid reconciliation records or issued legacy witnesses.
    scalar_legacy_refs: Vec<LegacyRef>,
}
fn id(n: u32) -> String {
    format!("{n:08x}-0000-4000-8000-000000000000")
}
fn key(n: u32) -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "wire-owner-scope".into(),
        asset_id: id(n),
    }
}
fn fact(n: u32, placement: Placement) -> Fact {
    Fact {
        key: key(n),
        owner_id: id(9000),
        media: if n == 2 { Media::Video } else { Media::Image },
        checksum: "a".repeat(40),
        revision: format!("wire-revision-{n}"),
        placement,
        forward: if n == 2 {
            Forward::Unlinked
        } else {
            Forward::Linked(key(2))
        },
        unstacked: true,
        offline: false,
        trashed: false,
    }
}
fn pair(parent_unchanged: bool) -> Result<Batch, String> {
    let parent = Resource {
        id: id(11),
        initial: fact(
            1,
            if parent_unchanged {
                Placement::Locked
            } else {
                Placement::Timeline
            },
        ),
        initial_albums: vec![id(81)],
        destination: Placement::Locked,
        step_id: (!parent_unchanged).then(|| id(21)),
    };
    let motion = Resource {
        id: id(12),
        initial: fact(2, Placement::Hidden),
        initial_albums: vec![id(82)],
        destination: Placement::Locked,
        step_id: Some(id(22)),
    };
    let resources = vec![parent, motion];
    let mut steps: Vec<_> = resources
        .iter()
        .filter_map(|r| {
            r.step_id.as_ref().map(|s| Step {
                id: s.clone(),
                resource_id: r.id.clone(),
                outcome: Outcome::NotStarted,
            })
        })
        .collect();
    let first = steps.first_mut().ok_or("missing first step")?;
    first.outcome = Outcome::Unknown {
        attempt_id: id(201),
        accepted: None,
    };
    let mut intent = Intent {
        encoding_version: 1,
        owner_id: id(9000),
        scope: "wire-owner-scope".into(),
        direction: Direction::Lock,
        selections: vec![Selection {
            id: id(31),
            parent: key(1),
        }],
        resources,
        edges: vec![Edge {
            id: id(41),
            selection_id: id(31),
            parent_resource: id(11),
            motion_resource: id(12),
        }],
        aliases: vec![
            Alias {
                id: id(51),
                edge_id: id(41),
                role: Role::Parent,
                resource_id: id(11),
                destination: Placement::Locked,
            },
            Alias {
                id: id(52),
                edge_id: id(41),
                role: Role::Motion,
                resource_id: id(12),
                destination: Placement::Locked,
            },
        ],
        observed_additional_parents: vec![],
        shared_reference_limitations_acknowledged: true,
        dependencies: if parent_unchanged {
            vec![]
        } else {
            vec![Dependency {
                before: id(21),
                after: id(22),
            }]
        },
        ordered_step_ids: steps.iter().map(|s| s.id.clone()).collect(),
        supersedes: vec![],
        digest: String::new(),
    };
    intent.digest = live::intent_digest(&intent)?;
    Ok(Batch {
        format_version: 1,
        id: id(101),
        intent,
        steps,
        latest_observations: vec![],
    })
}
fn accepted(batch: &Batch) -> Result<Accepted204, String> {
    let step = batch.steps.first().ok_or("missing first step")?;
    let resource = batch
        .intent
        .resources
        .iter()
        .find(|r| r.step_id.as_ref() == Some(&step.id))
        .ok_or("resource")?;
    Ok(Accepted204 {
        batch_id: batch.id.clone(),
        step_id: step.id.clone(),
        attempt_id: id(201),
        key: resource.initial.key.clone(),
        intent_digest: batch.intent.digest.clone(),
    })
}
fn observed(batch: &mut Batch) {
    batch.latest_observations = batch
        .intent
        .resources
        .iter()
        .enumerate()
        .map(|(i, r)| MemberObservation {
            key: r.initial.key.clone(),
            state: if i == 0 {
                ObservedState::Own(Box::new(r.initial.clone()))
            } else {
                ObservedState::Unavailable(ObservationFailure::Denied)
            },
        })
        .collect();
}
fn case(name: &str, batch: Batch) -> Case {
    Case {
        name: name.into(),
        library: SavedLibrary {
            schema_version: live::CURRENT_SCHEMA_VERSION,
            apple_scope: "wire-apple".into(),
            immich_live_operations: vec![batch],
            ..SavedLibrary::default()
        },
    }
}
fn closed_and_reconciled() -> Result<Case, String> {
    let batch = pair(false)?;
    let motion = batch.steps.get(1).ok_or("NotStarted motion")?;
    let graph: Vec<_> = batch
        .intent
        .resources
        .iter()
        .map(|resource| ResourceObservation {
            fact: resource.initial.clone(),
            albums: resource.initial_albums.clone(),
        })
        .collect();
    let mut closure = UnstartedClosure {
        format_version: 1,
        id: id(401),
        references: vec![StepRef {
            batch_id: batch.id.clone(),
            step_id: motion.id.clone(),
            intent_digest: batch.intent.digest.clone(),
            retired_outcomes_digest: live::retired_outcomes_digest(&batch)?,
        }],
        current_graph: graph.clone(),
        digest: String::new(),
    };
    closure.digest = live::closure_digest(&closure)?;
    let legacy = suwop_core::immich_visibility::ImmichVisibilityOperation {
        kind: suwop_core::immich_visibility::ImmichVisibilityOperationKind::LockedTransition,
        id: id(501),
        scope: key(1).scope,
        key: key(1),
        // Frozen schema-7 IMAGE witness codec, independently revalidated by validate_library.
        witness_digest: format!(
            "{:x}",
            sha2::Sha256::digest(
                serde_json::to_vec(&(key(1), "IMAGE", "a".repeat(40), "unlinked", "unstacked"))
                    .map_err(|_| "legacy identity encode")?
            )
        ),
        from: ImmichVisibility::Timeline,
        to: ImmichVisibility::Locked,
        outcome: suwop_core::apple_visibility::VisibilityOutcome::Applied,
        observation: Some(ImmichVisibility::Locked),
        album_membership_observation: AlbumMembershipObservation::NoAccessibleMemberships,
        selected_observation: None,
    };
    let mut reconciliation = LegacyReconciliation {
        format_version: 1,
        id: id(502),
        parent: key(1),
        legacy: vec![LegacyRef {
            operation_id: legacy.id.clone(),
            record_digest: live::legacy_record_digest(&legacy)?,
            acknowledged_observation: legacy.observation,
            acknowledged_albums: legacy.album_membership_observation,
            acknowledged_selected: legacy.selected_observation.clone(),
        }],
        confirmed_graph: graph,
        digest: String::new(),
    };
    reconciliation.digest = live::reconciliation_digest(&reconciliation)?;
    let mut value = case(
        "closed-not-started-with-unknown-and-legacy-reconciliation",
        batch,
    );
    value.library.immich_live_unstarted_closures.push(closure);
    value.library.immich_visibility_operations.push(legacy);
    value
        .library
        .immich_live_legacy_reconciliations
        .push(reconciliation);
    live::validate_library(&value.library)?;
    Ok(value)
}
fn corpus() -> Result<Corpus, String> {
    let mut unknown = pair(false)?;
    observed(&mut unknown);
    let mut acknowledged = pair(false)?;
    acknowledged.steps.first_mut().ok_or("step")?.outcome = Outcome::Unknown {
        attempt_id: id(201),
        accepted: Some(accepted(&unknown)?),
    };
    acknowledged.latest_observations = acknowledged
        .intent
        .resources
        .iter()
        .map(|r| MemberObservation {
            key: r.initial.key.clone(),
            state: ObservedState::NotObserved,
        })
        .collect();
    let mut not_applied = pair(false)?;
    let receipt = accepted(&not_applied)?;
    not_applied.steps.first_mut().ok_or("step")?.outcome = Outcome::NotApplied {
        attempt_id: receipt.attempt_id.clone(),
        no_submission: NoSubmissionRecord {
            batch_id: receipt.batch_id,
            step_id: receipt.step_id,
            attempt_id: receipt.attempt_id,
            key: receipt.key,
            intent_digest: receipt.intent_digest,
        },
    };
    let mut applied = pair(false)?;
    let receipt = accepted(&applied)?;
    let mut graph: Vec<_> = applied
        .intent
        .resources
        .iter()
        .map(|r| ResourceObservation {
            fact: r.initial.clone(),
            albums: r.initial_albums.clone(),
        })
        .collect();
    let selected = graph.first_mut().ok_or("selected")?;
    selected.fact.placement = Placement::Locked;
    selected.fact.revision = "wire-after-accepted".into();
    selected.albums.clear();
    let mut post = PostFacts {
        encoding_version: 1,
        batch_id: receipt.batch_id.clone(),
        step_id: receipt.step_id.clone(),
        attempt_id: receipt.attempt_id.clone(),
        intent_digest: receipt.intent_digest.clone(),
        resources: graph,
        digest: String::new(),
    };
    post.digest = live::post_digest(&post)?;
    applied.steps.first_mut().ok_or("step")?.outcome = Outcome::Applied {
        attempt_id: receipt.attempt_id.clone(),
        accepted: receipt,
        verified_post: Box::new(post),
    };
    Ok(Corpus {
        format_version: 1,
        valid_states: vec![
            case("unknown-null", unknown),
            case("unknown-accepted", acknowledged),
            case("not-applied", not_applied),
            case("applied-prefix", applied),
            case("unchanged-parent-null-step", pair(true)?),
            closed_and_reconciled()?,
        ],
        scalar_legacy_refs: vec![
            LegacyRef {
                operation_id: id(501),
                record_digest: "b".repeat(64),
                acknowledged_observation: None,
                acknowledged_albums: AlbumMembershipObservation::NotChecked,
                acknowledged_selected: None,
            },
            LegacyRef {
                operation_id: id(502),
                record_digest: "c".repeat(64),
                acknowledged_observation: Some(ImmichVisibility::Locked),
                acknowledged_albums: AlbumMembershipObservation::NoAccessibleMemberships,
                acknowledged_selected: Some(SelectedVisibilityObservation {
                    selected_identity_digest: "d".repeat(64),
                    visibility: ImmichVisibility::Locked,
                    configuration: SelectedConfiguration::Linked,
                    configuration_digest: Some("e".repeat(64)),
                }),
            },
        ],
    })
}
fn main() -> Result<(), String> {
    let verify = match std::env::args().skip(1).collect::<Vec<_>>().as_slice() {
        [] => false,
        [arg] if arg == "--verify" => true,
        _ => return Err("expected no arguments or --verify".into()),
    };
    let (value, original) = if verify {
        let mut input = String::new();
        std::io::stdin()
            .read_to_string(&mut input)
            .map_err(|e| e.to_string())?;
        let raw: serde_json::Value = serde_json::from_str(&input).map_err(|e| e.to_string())?;
        let value: Corpus = serde_json::from_value(raw.clone()).map_err(|e| e.to_string())?;
        (value, Some(raw))
    } else {
        (corpus()?, None)
    };
    if value.format_version != 1
        || value.valid_states.len() != 6
        || value.scalar_legacy_refs.len() != 2
    {
        return Err("unexpected wire corpus".into());
    }
    for case in &value.valid_states {
        live::validate_library(&case.library)?;
    }
    let canonical = serde_json::to_value(&value).map_err(|e| e.to_string())?;
    if let Some(original) = original {
        let expected = serde_json::to_value(corpus()?).map_err(|e| e.to_string())?;
        if canonical != expected {
            return Err("Swift wire changed typed Rust fixture values".into());
        }
        // Existing optional DTO keys may be omitted; only new batch subtrees require raw key preservation.
        let originals = original["validStates"].as_array().ok_or("wire states")?;
        let normalized = canonical["validStates"]
            .as_array()
            .ok_or("normalized states")?;
        for (before, after) in originals.iter().zip(normalized) {
            for field in [
                "immichLiveOperations",
                "immichLiveUnstartedClosures",
                "immichLiveLegacyReconciliations",
            ] {
                if before["library"].get(field) != after["library"].get(field) {
                    return Err("Swift wire omitted or changed canonical batch fields".into());
                }
            }
        }
        if original["scalarLegacyRefs"] != canonical["scalarLegacyRefs"] {
            return Err("Swift wire omitted or changed serde-only nullable legacy fields".into());
        }
    } else {
        std::io::stdout()
            .write_all(&serde_json::to_vec_pretty(&canonical).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
