use super::{
    Alias, Batch, Dependency, Direction, Edge, Fact, Forward, Intent, Media, Outcome, Placement,
    Resource, ResourceObservation, Role, Selection, Step,
};
use crate::{
    app::SavedLibrary,
    domain::{AssetKey, Provider},
};
use serde_json::{Value, json};

fn id(n: u32) -> String {
    format!("{n:08x}-0000-4000-8000-000000000000")
}
fn key(n: u32) -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "owner-scope".into(),
        asset_id: id(n),
    }
}
fn fact(n: u32, placement: Placement) -> Fact {
    Fact {
        key: key(n),
        owner_id: id(9_000),
        media: if n == 3 { Media::Video } else { Media::Image },
        checksum: "a".repeat(40),
        revision: format!("revision-{n}-initial"),
        placement,
        forward: if n == 3 {
            Forward::Unlinked
        } else {
            Forward::Linked(key(3))
        },
        unstacked: true,
        offline: false,
        trashed: false,
    }
}
fn batch(shared: bool, offset: u32) -> Result<Batch, String> {
    let mut resources = Vec::new();
    let mut selections = Vec::new();
    let mut edges = Vec::new();
    let mut aliases = Vec::new();
    let mut dependencies = Vec::new();
    let parents: &[u32] = if shared { &[1, 2] } else { &[1] };
    for &n in parents {
        resources.push(Resource {
            id: id(offset + 10 + n),
            initial: fact(
                n,
                if n == 1 {
                    Placement::Timeline
                } else {
                    Placement::Archive
                },
            ),
            initial_albums: vec![id(7_999 + n)],
            destination: Placement::Locked,
            step_id: Some(id(offset + 20 + n)),
        });
        selections.push(Selection {
            id: id(offset + 30 + n),
            parent: key(n),
        });
        edges.push(Edge {
            id: id(offset + 40 + n),
            selection_id: id(offset + 30 + n),
            parent_resource: id(offset + 10 + n),
            motion_resource: id(offset + 13),
        });
        for (role, resource_id, alias_id) in [
            (Role::Parent, id(offset + 10 + n), id(offset + 49 + 2 * n)),
            (Role::Motion, id(offset + 13), id(offset + 50 + 2 * n)),
        ] {
            aliases.push(Alias {
                id: alias_id,
                edge_id: id(offset + 40 + n),
                role,
                resource_id,
                destination: Placement::Locked,
            });
        }
        dependencies.push(Dependency {
            before: id(offset + 20 + n),
            after: id(offset + 23),
        });
    }
    resources.push(Resource {
        id: id(offset + 13),
        initial: fact(3, Placement::Hidden),
        initial_albums: vec![id(8_002)],
        destination: Placement::Locked,
        step_id: Some(id(offset + 23)),
    });
    let mut steps: Vec<_> = resources
        .iter()
        .map(|r| {
            Ok(Step {
                id: r.step_id.clone().ok_or("step")?,
                resource_id: r.id.clone(),
                outcome: Outcome::NotStarted,
            })
        })
        .collect::<Result<_, String>>()?;
    steps[0].outcome = Outcome::Unknown {
        attempt_id: id(offset + 201),
        accepted: None,
    };
    let mut intent = Intent {
        encoding_version: 1,
        owner_id: id(9_000),
        scope: "owner-scope".into(),
        direction: Direction::Lock,
        selections,
        resources,
        edges,
        aliases,
        observed_additional_parents: vec![key(4)],
        shared_reference_limitations_acknowledged: true,
        dependencies,
        ordered_step_ids: steps.iter().map(|s| s.id.clone()).collect(),
        supersedes: vec![],
        digest: String::new(),
    };
    intent.digest = super::intent_digest(&intent)?;
    Ok(Batch {
        format_version: 1,
        id: id(offset + 101),
        intent,
        steps,
        latest_observations: vec![],
    })
}
fn state(batch: Batch) -> SavedLibrary {
    SavedLibrary {
        schema_version: super::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        immich_live_operations: vec![batch],
        ..SavedLibrary::default()
    }
}
fn seal(batch: &mut Batch) -> Result<(), String> {
    batch.intent.digest = super::intent_digest(&batch.intent)?;
    Ok(())
}
fn initial_graph(batch: &Batch) -> Vec<ResourceObservation> {
    batch
        .intent
        .resources
        .iter()
        .map(|r| ResourceObservation {
            fact: r.initial.clone(),
            albums: r.initial_albums.clone(),
        })
        .collect()
}
fn applied(batch: &mut Batch, index: usize, attempt: u32) -> Result<(), String> {
    let step = &batch.steps[index];
    let resource = super::validate::resource(&batch.intent, &step.resource_id)?;
    let mut graph = if index == 0 {
        initial_graph(batch)
    } else {
        match &batch.steps[index - 1].outcome {
            Outcome::Applied { verified_post, .. } => verified_post.resources.clone(),
            _ => return Err("prior Applied required".into()),
        }
    };
    let selected = graph
        .iter_mut()
        .find(|v| v.fact.key == resource.initial.key)
        .ok_or("selected")?;
    selected.fact.placement = resource.destination;
    selected.fact.revision = format!("revision-after-{attempt}");
    if resource.destination == Placement::Locked {
        selected.albums.clear();
    }
    let receipt = super::Accepted204 {
        batch_id: batch.id.clone(),
        step_id: step.id.clone(),
        attempt_id: id(attempt),
        key: resource.initial.key.clone(),
        intent_digest: batch.intent.digest.clone(),
    };
    let mut post = super::PostFacts {
        encoding_version: 1,
        batch_id: batch.id.clone(),
        step_id: step.id.clone(),
        attempt_id: id(attempt),
        intent_digest: batch.intent.digest.clone(),
        resources: graph,
        digest: String::new(),
    };
    post.digest = super::post_digest(&post)?;
    batch.steps[index].outcome = Outcome::Applied {
        attempt_id: id(attempt),
        accepted: receipt,
        verified_post: Box::new(post),
    };
    Ok(())
}

#[test]
fn one_pair_is_one_edge_batch_and_shared_motion_is_one_physical_step() -> Result<(), String> {
    let one = state(batch(false, 0)?);
    super::validate_library(&one)?;
    let shared = state(batch(true, 0)?);
    super::validate_library(&shared)?;
    assert_eq!(shared.immich_live_operations[0].intent.edges.len(), 2);
    assert_eq!(shared.immich_live_operations[0].steps.len(), 3);
    assert_eq!(
        shared.immich_live_operations[0]
            .intent
            .aliases
            .iter()
            .filter(|a| a.role == Role::Motion)
            .count(),
        2
    );
    assert!(matches!(
        shared.immich_live_operations[0].steps[0].outcome,
        Outcome::Unknown { .. }
    ));
    assert!(
        shared.immich_live_operations[0].steps[1..]
            .iter()
            .all(|s| s.outcome == Outcome::NotStarted)
    );
    Ok(())
}

#[test]
fn same_checksum_distinct_parents_keep_multiplicity_but_duplicate_physical_nodes_fail()
-> Result<(), String> {
    let mut b = batch(true, 0)?;
    assert_eq!(
        b.intent.resources[0].initial.checksum,
        b.intent.resources[1].initial.checksum
    );
    super::validate_library(&state(b.clone()))?;
    b.intent.resources[1].initial.key = key(1);
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn conflicting_alias_target_and_dangling_selection_never_validate() -> Result<(), String> {
    let mut b = batch(true, 0)?;
    b.intent.aliases[3].destination = Placement::Hidden;
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    let mut b = batch(true, 0)?;
    b.intent.edges[1].selection_id = id(700);
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn confirmed_order_must_satisfy_every_shared_motion_dependency() -> Result<(), String> {
    let mut b = batch(true, 0)?;
    b.steps.swap(1, 2);
    b.intent.ordered_step_ids = b.steps.iter().map(|s| s.id.clone()).collect();
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    let mut b = batch(true, 0)?;
    b.intent.dependencies.pop();
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn restore_requires_motion_before_both_parents_and_preserves_hidden_destination()
-> Result<(), String> {
    let mut b = batch(true, 0)?;
    b.intent.direction = Direction::Restore;
    for r in &mut b.intent.resources {
        r.destination = r.initial.placement;
        r.initial.placement = Placement::Locked;
        r.initial_albums.clear();
    }
    let destinations: std::collections::BTreeMap<_, _> = b
        .intent
        .resources
        .iter()
        .map(|r| (r.id.clone(), r.destination))
        .collect();
    for a in &mut b.intent.aliases {
        a.destination = *destinations.get(&a.resource_id).ok_or("resource")?;
    }
    for d in &mut b.intent.dependencies {
        std::mem::swap(&mut d.before, &mut d.after);
    }
    b.steps.rotate_right(1);
    for step in &mut b.steps {
        step.outcome = Outcome::NotStarted;
    }
    b.steps[0].outcome = Outcome::Unknown {
        attempt_id: id(201),
        accepted: None,
    };
    b.intent.ordered_step_ids = b.steps.iter().map(|s| s.id.clone()).collect();
    seal(&mut b)?;
    super::validate_library(&state(b.clone()))?;
    assert_eq!(b.intent.resources[2].destination, Placement::Hidden);
    b.steps.swap(0, 1);
    b.intent.ordered_step_ids = b.steps.iter().map(|s| s.id.clone()).collect();
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn unchanged_motion_remains_in_full_graph_and_hold_without_fake_step() -> Result<(), String> {
    let mut b = batch(false, 0)?;
    b.intent.resources[1].initial.placement = Placement::Locked;
    b.intent.resources[1].step_id = None;
    b.steps.pop();
    b.intent.ordered_step_ids.pop();
    b.intent.dependencies.clear();
    seal(&mut b)?;
    let state = state(b);
    super::validate_library(&state)?;
    assert!(super::fences(&state, &key(3)));
    assert_eq!(super::holds(&state)[0].keys.len(), 2);
    Ok(())
}

#[test]
fn submitted_prefix_cannot_cross_unknown_not_applied_or_not_started() -> Result<(), String> {
    for first in [
        Outcome::NotStarted,
        Outcome::Unknown {
            attempt_id: id(201),
            accepted: None,
        },
    ] {
        let mut b = batch(true, 0)?;
        b.steps[0].outcome = first;
        b.steps[1].outcome = Outcome::Unknown {
            attempt_id: id(202),
            accepted: None,
        };
        assert!(super::validate_library(&state(b)).is_err());
    }
    let mut b = batch(true, 0)?;
    let r = &b.intent.resources[0];
    b.steps[0].outcome = Outcome::NotApplied {
        attempt_id: id(201),
        no_submission: super::NoSubmissionRecord {
            batch_id: b.id.clone(),
            step_id: b.steps[0].id.clone(),
            attempt_id: id(201),
            key: r.initial.key.clone(),
            intent_digest: b.intent.digest.clone(),
        },
    };
    b.steps[1].outcome = Outcome::Unknown {
        attempt_id: id(202),
        accepted: None,
    };
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn applied_rollover_requires_whole_graph_and_exact_unselected_revisions() -> Result<(), String> {
    let mut b = batch(true, 0)?;
    applied(&mut b, 0, 201)?;
    applied(&mut b, 1, 202)?;
    b.steps[2].outcome = Outcome::Unknown {
        attempt_id: id(203),
        accepted: None,
    };
    super::validate_library(&state(b.clone()))?;
    if let Outcome::Applied { verified_post, .. } = &mut b.steps[1].outcome {
        verified_post.resources[0].fact.revision = "external-P3-drift-same-checksum".into();
        verified_post.digest = super::post_digest(verified_post)?;
    }
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn exact204_binding_does_not_replace_post_pair_and_album_validation() -> Result<(), String> {
    let mut b = batch(false, 0)?;
    applied(&mut b, 0, 201)?;
    if let Outcome::Applied { verified_post, .. } = &mut b.steps[0].outcome {
        verified_post.resources[0].albums = vec![id(8_000)];
        verified_post.digest = super::post_digest(verified_post)?;
    }
    assert!(super::validate_library(&state(b)).is_err());
    let mut b = batch(false, 0)?;
    applied(&mut b, 0, 201)?;
    if let Outcome::Applied { accepted, .. } = &mut b.steps[0].outcome {
        accepted.key = key(4);
    }
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn matching_latest_observation_never_upgrades_unknown_or_releases_any_alias_hold()
-> Result<(), String> {
    let mut b = batch(true, 0)?;
    let outcomes: Vec<_> = b.steps.iter().map(|s| s.outcome.clone()).collect();
    b.latest_observations = b
        .intent
        .resources
        .iter()
        .map(|r| {
            let mut fact = r.initial.clone();
            fact.placement = Placement::Locked;
            super::MemberObservation {
                key: fact.key.clone(),
                state: super::ObservedState::Own(Box::new(fact)),
            }
        })
        .collect();
    let state = state(b);
    super::validate_library(&state)?;
    assert_eq!(
        state.immich_live_operations[0]
            .steps
            .iter()
            .map(|s| s.outcome.clone())
            .collect::<Vec<_>>(),
        outcomes
    );
    for n in [1, 2, 3] {
        assert!(super::fences(&state, &key(n)));
    }
    assert!(!super::fences(&state, &key(4)));
    assert!(crate::immich_visibility::fences(&state, &key(3)));
    assert!(!crate::privacy::ContentAccess::new(&state).can_operate(&key(3)));
    assert!(
        !crate::privacy::ContentAccess::new(&state)
            .can_present(&key(1), &std::collections::BTreeSet::from([key(1)]))
    );
    Ok(())
}

#[test]
fn unrelated_success_cannot_clear_unknown_batch_on_same_physical_key() -> Result<(), String> {
    let mut state = state(batch(true, 0)?);
    let mut complete = batch(false, 1_000)?;
    applied(&mut complete, 0, 1_201)?;
    applied(&mut complete, 1, 1_202)?;
    state.immich_live_operations.push(complete);
    super::validate_library(&state)?;
    let holds = super::holds(&state);
    assert_eq!(holds.len(), 2);
    assert_eq!(holds[0].reason, super::LiveHoldReason::UncertainSubmission);
    assert_eq!(holds[1].reason, super::LiveHoldReason::FreshContextRequired);
    assert!(super::fences(&state, &key(3)));
    Ok(())
}

#[test]
fn id_namespace_and_digest_cover_alias_confirmation_and_attempt_definitions() -> Result<(), String>
{
    let mut b = batch(true, 0)?;
    b.intent.aliases[0].id = b.intent.selections[0].id.clone();
    seal(&mut b)?;
    assert!(super::validate_library(&state(b)).is_err());
    let mut b = batch(false, 0)?;
    b.intent.shared_reference_limitations_acknowledged = false;
    assert!(super::validate_library(&state(b)).is_err());
    let mut b = batch(false, 0)?;
    applied(&mut b, 0, 201)?;
    b.steps[1].outcome = Outcome::Unknown {
        attempt_id: id(201),
        accepted: None,
    };
    assert!(super::validate_library(&state(b)).is_err());
    Ok(())
}

#[test]
fn schema_one_through_eight_migrate_without_inventing_group_or_changing_old_journals()
-> Result<(), String> {
    for version in 1..=8 {
        let input = json!({"schemaVersion":version,"appleScope":"apple","connection":null,"snapshots":[],"receipts":[],"immichVisibilityOperations":[]});
        let migrated = crate::workflow::migrate(input)?;
        assert_eq!(migrated.schema_version, super::CURRENT_SCHEMA_VERSION);
        assert!(migrated.immich_live_operations.is_empty());
        assert!(migrated.immich_live_unstarted_closures.is_empty());
        assert!(migrated.immich_live_legacy_reconciliations.is_empty());
    }
    Ok(())
}

#[test]
fn legacy_version_rejects_nonnull_new_fields_even_empty_before_deserialization() {
    for version in 1..=8 {
        for field in [
            "immichLiveOperations",
            "immichLiveUnstartedClosures",
            "immichLiveLegacyReconciliations",
        ] {
            let mut input = json!({"schemaVersion":version,"appleScope":"apple","connection":null});
            input[field] = json!([]);
            assert!(crate::workflow::migrate(input.clone()).is_err());
            assert_eq!(input["schemaVersion"], version);
        }
    }
}

#[test]
fn strict_current_schema_and_unknown_future_formats_fail_without_defaulting_to_not_started()
-> Result<(), String> {
    let state = state(batch(false, 0)?);
    let raw = serde_json::to_value(&state).map_err(|e| e.to_string())?;
    crate::workflow::migrate(raw.clone())?;
    for field in [
        "immichLiveOperations",
        "immichLiveUnstartedClosures",
        "immichLiveLegacyReconciliations",
    ] {
        let mut missing = raw.clone();
        missing.as_object_mut().ok_or("state")?.remove(field);
        assert!(crate::workflow::migrate(missing).is_err());
    }
    let mut malformed = raw.clone();
    malformed["immichLiveOperations"][0]["steps"][0]["outcome"] =
        json!({"type":"futureSubmittedState"});
    assert!(crate::workflow::migrate(malformed).is_err());
    let mut future = raw.clone();
    future["schemaVersion"] = json!(10);
    assert!(crate::workflow::migrate(future).is_err());
    let mut future = raw;
    future["immichLiveOperations"][0]["formatVersion"] = json!(2);
    assert!(crate::workflow::migrate(future).is_err());
    Ok(())
}

#[test]
fn readback_only_exact_before_or_desired_is_conclusive_and_third_state_stays_uncertain()
-> Result<(), String> {
    use super::readback::{DurableReadback, classify};

    let before = SavedLibrary {
        schema_version: super::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        ..SavedLibrary::default()
    };
    let desired = state(batch(false, 0)?);
    let encode = |s: &SavedLibrary| serde_json::to_value(s).map_err(|e| e.to_string());
    assert_eq!(
        classify(&before, &desired, Some(&encode(&before)?)),
        DurableReadback::Before
    );
    assert_eq!(
        classify(&before, &desired, Some(&encode(&desired)?)),
        DurableReadback::Desired
    );
    assert_eq!(
        classify(&before, &desired, None),
        DurableReadback::Uncertain
    );
    let mut third = encode(&desired)?;
    third["appleScope"] = json!("other");
    assert_eq!(
        classify(&before, &desired, Some(&third)),
        DurableReadback::Uncertain
    );
    let mut forged = encode(&desired)?;
    forged["newUnknownField"] = Value::Null;
    assert_eq!(
        classify(&before, &desired, Some(&forged)),
        DurableReadback::Uncertain
    );
    Ok(())
}

fn keep_current(
    state: &SavedLibrary,
    step_index: usize,
    closure_id: u32,
) -> Result<super::UnstartedClosure, String> {
    let batch = &state.immich_live_operations[0];
    let step = &batch.steps[step_index];
    let selected = super::validate::resource(&batch.intent, &step.resource_id)?;
    let mut graph = initial_graph(batch);
    for value in &mut graph {
        if value.fact.key == selected.initial.key {
            value.fact.placement = selected.destination;
            value.fact.revision = "external-state-before-KeepCurrent".into();
            if selected.destination == Placement::Locked {
                value.albums.clear();
            }
        }
    }
    let mut closure = super::UnstartedClosure {
        format_version: 1,
        id: id(closure_id),
        references: vec![super::StepRef {
            batch_id: batch.id.clone(),
            step_id: step.id.clone(),
            intent_digest: batch.intent.digest.clone(),
            retired_outcomes_digest: super::retired_outcomes_digest(batch)?,
        }],
        current_graph: graph,
        digest: String::new(),
    };
    closure.digest = super::closure_digest(&closure)?;
    Ok(closure)
}

#[test]
fn keep_current_is_exact_no_write_closure_and_later_unknown_cannot_corrupt_it_or_be_discharged()
-> Result<(), String> {
    let mut b = batch(false, 0)?;
    applied(&mut b, 0, 201)?;
    let original = b.clone();
    let mut state = state(b);
    let closure = keep_current(&state, 1, 401)?;
    state.immich_live_unstarted_closures.push(closure.clone());
    super::validate_library(&state)?;
    assert_eq!(
        super::holds(&state)[0].reason,
        super::LiveHoldReason::FreshContextRequired
    );
    assert_eq!(state.immich_live_operations[0], original);
    state.immich_live_operations.push(batch(true, 1_000)?);
    super::validate_library(&state)?;
    let loaded =
        crate::workflow::migrate(serde_json::to_value(&state).map_err(|e| e.to_string())?)?;
    assert_eq!(loaded.immich_live_unstarted_closures[0], closure);
    assert_eq!(
        super::holds(&loaded)[1].reason,
        super::LiveHoldReason::UncertainSubmission
    );
    assert!(super::fences(&loaded, &key(3)));
    Ok(())
}

#[test]
fn closure_cannot_reference_unknown_or_close_one_shared_physical_step_twice() -> Result<(), String>
{
    let mut b = batch(true, 0)?;
    applied(&mut b, 0, 201)?;
    let mut library = state(b);
    let closure = keep_current(&library, 2, 401)?;
    library.immich_live_unstarted_closures.push(closure);
    super::validate_library(&library)?;
    let duplicate = keep_current(&library, 2, 402)?;
    library.immich_live_unstarted_closures.push(duplicate);
    assert!(super::validate_library(&library).is_err());
    let mut library = state(batch(false, 0)?);
    let invalid = keep_current(&library, 0, 401)?;
    library.immich_live_unstarted_closures.push(invalid);
    assert!(super::validate_library(&library).is_err());
    Ok(())
}

#[test]
fn supersession_retains_original_history_and_cannot_be_consumed_by_two_new_batches()
-> Result<(), String> {
    let mut old = batch(false, 0)?;
    applied(&mut old, 0, 201)?;
    let reference = super::StepRef {
        batch_id: old.id.clone(),
        step_id: old.steps[1].id.clone(),
        intent_digest: old.intent.digest.clone(),
        retired_outcomes_digest: super::retired_outcomes_digest(&old)?,
    };
    let mut successor = batch(false, 1_000)?;
    successor.intent.supersedes.push(reference.clone());
    seal(&mut successor)?;
    let mut library = state(old.clone());
    library.immich_live_operations.push(successor);
    super::validate_library(&library)?;
    assert_eq!(library.immich_live_operations[0], old);
    assert!(super::fences(&library, &key(3)));
    let mut duplicate = batch(false, 2_000)?;
    duplicate.intent.supersedes.push(reference);
    seal(&mut duplicate)?;
    library.immich_live_operations.push(duplicate);
    assert!(super::validate_library(&library).is_err());
    Ok(())
}

#[test]
fn cyclic_supersession_is_rejected_even_when_every_referenced_step_is_known_unstarted()
-> Result<(), String> {
    // Digests include refs, so a fabricated cycle also fails digest binding.
    // The explicit iterative cycle check independently rejects graph cycles.
    let edges = std::collections::BTreeMap::from([
        ("a", std::collections::BTreeSet::from(["b"])),
        ("b", std::collections::BTreeSet::from(["a"])),
    ]);
    assert!(super::references::acyclic(&edges).is_err());
    let mut a = batch(false, 0)?;
    a.intent.supersedes.push(super::StepRef {
        batch_id: id(999),
        step_id: id(998),
        intent_digest: "a".repeat(64),
        retired_outcomes_digest: "b".repeat(64),
    });
    seal(&mut a)?;
    assert!(super::validate_library(&state(a)).is_err());
    Ok(())
}

fn legacy_record(operation_id: u32) -> crate::immich_visibility::ImmichVisibilityOperation {
    use crate::{
        apple_visibility::VisibilityOutcome,
        immich_visibility::{
            AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
            ImmichVisibilityOperationKind,
        },
    };
    ImmichVisibilityOperation {
        kind: ImmichVisibilityOperationKind::LockedTransition,
        id: id(operation_id),
        scope: key(1).scope,
        key: key(1),
        witness_digest: crate::immich_visibility::original_image_identity_digest(
            &key(1),
            &"a".repeat(40),
        ),
        from: ImmichVisibility::Timeline,
        to: ImmichVisibility::Locked,
        outcome: VisibilityOutcome::Applied,
        observation: Some(ImmichVisibility::Locked),
        album_membership_observation: AlbumMembershipObservation::NoAccessibleMemberships,
        selected_observation: None,
    }
}

#[test]
fn legacy_reconciliation_history_survives_later_batch_legacy_append_and_inspect_changes()
-> Result<(), String> {
    let mut library = SavedLibrary {
        schema_version: super::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        ..SavedLibrary::default()
    };
    let legacy = legacy_record(501);
    let reference = super::LegacyRef {
        operation_id: legacy.id.clone(),
        record_digest: super::legacy_record_digest(&legacy)?,
        acknowledged_observation: legacy.observation,
        acknowledged_albums: legacy.album_membership_observation,
        acknowledged_selected: legacy.selected_observation.clone(),
    };
    let mut reconciliation = super::LegacyReconciliation {
        format_version: 1,
        id: id(502),
        parent: key(1),
        legacy: vec![reference],
        confirmed_graph: initial_graph(&batch(false, 0)?),
        digest: String::new(),
    };
    reconciliation.digest = super::reconciliation_digest(&reconciliation)?;
    library.immich_visibility_operations.push(legacy);
    library
        .immich_live_legacy_reconciliations
        .push(reconciliation.clone());
    super::validate_library(&library)?;
    library.immich_live_operations.push(batch(true, 1_000)?);
    let mut later = legacy_record(503);
    later.outcome = crate::apple_visibility::VisibilityOutcome::Unknown;
    later.observation = None;
    library.immich_visibility_operations.push(later);
    library.immich_visibility_operations[0].observation =
        Some(crate::immich_visibility::ImmichVisibility::Archive);
    let loaded =
        crate::workflow::migrate(serde_json::to_value(&library).map_err(|e| e.to_string())?)?;
    assert_eq!(loaded.immich_live_legacy_reconciliations[0], reconciliation);
    assert!(crate::immich_visibility::fences(&loaded, &key(1)));
    assert!(super::fences(&loaded, &key(3)));
    Ok(())
}

#[test]
fn read_only_drift_denial_and_unobserved_members_roundtrip_without_authority_or_history_rewrite()
-> Result<(), String> {
    let mut b = batch(true, 0)?;
    let original = b.clone();
    let mut changed = b.intent.resources[0].initial.clone();
    changed.forward = Forward::Unlinked;
    changed.checksum = "b".repeat(40);
    changed.offline = true;
    changed.trashed = true;
    changed.unstacked = false;
    b.latest_observations = vec![
        super::MemberObservation {
            key: key(1),
            state: super::ObservedState::Own(Box::new(changed)),
        },
        super::MemberObservation {
            key: key(2),
            state: super::ObservedState::NotObserved,
        },
        super::MemberObservation {
            key: key(3),
            state: super::ObservedState::Unavailable(super::ObservationFailure::Denied),
        },
    ];
    let library = state(b);
    let loaded =
        crate::workflow::migrate(serde_json::to_value(&library).map_err(|e| e.to_string())?)?;
    let after = &loaded.immich_live_operations[0];
    assert_eq!(after.intent, original.intent);
    assert_eq!(after.steps, original.steps);
    assert_eq!(after.latest_observations.len(), 3);
    for n in [1, 2, 3] {
        assert!(super::fences(&loaded, &key(n)));
    }
    assert!(crate::ordinary_selected::security_differs(
        &state(original),
        &loaded
    ));
    Ok(())
}

#[test]
fn closure_retires_entire_original_cursor_without_closing_unreferenced_siblings()
-> Result<(), String> {
    let mut old = batch(true, 0)?;
    applied(&mut old, 0, 201)?;
    let old_id = old.id.clone();
    let mut library = state(old);
    assert!(super::original_continuation_open(&library, &old_id));
    let closure = keep_current(&library, 2, 401)?;
    library.immich_live_unstarted_closures.push(closure);
    super::validate_library(&library)?;
    assert!(!super::original_continuation_open(&library, &old_id));
    assert_eq!(
        super::holds(&library)[0].reason,
        super::LiveHoldReason::UnstartedRemainder
    );
    assert_eq!(
        library.immich_live_operations[0].steps[1].outcome,
        Outcome::NotStarted
    );
    // Read-only observations do not change the retirement snapshot.
    library.immich_live_operations[0].latest_observations = vec![
        super::MemberObservation {
            key: key(1),
            state: super::ObservedState::NotObserved,
        },
        super::MemberObservation {
            key: key(2),
            state: super::ObservedState::Unavailable(super::ObservationFailure::Unavailable),
        },
        super::MemberObservation {
            key: key(3),
            state: super::ObservedState::NotObserved,
        },
    ];
    super::validate_library(&library)?;
    // An old sibling cannot resume as Unknown OR jump directly to Applied.
    let mut altered = library.clone();
    altered.immich_live_operations[0].steps[1].outcome = Outcome::Unknown {
        attempt_id: id(202),
        accepted: None,
    };
    assert!(super::validate_library(&altered).is_err());
    applied(&mut library.immich_live_operations[0], 1, 202)?;
    assert!(super::validate_library(&library).is_err());
    Ok(())
}

#[test]
fn successor_retires_original_batch_but_does_not_close_other_not_started_steps()
-> Result<(), String> {
    let mut old = batch(true, 0)?;
    applied(&mut old, 0, 201)?;
    let mut successor = batch(true, 1_000)?;
    successor.intent.supersedes.push(super::StepRef {
        batch_id: old.id.clone(),
        step_id: old.steps[2].id.clone(),
        intent_digest: old.intent.digest.clone(),
        retired_outcomes_digest: super::retired_outcomes_digest(&old)?,
    });
    seal(&mut successor)?;
    let old_id = old.id.clone();
    let new_id = successor.id.clone();
    let mut library = state(old);
    library.immich_live_operations.push(successor);
    super::validate_library(&library)?;
    assert!(!super::original_continuation_open(&library, &old_id));
    assert!(super::original_continuation_open(&library, &new_id));
    assert_eq!(
        super::holds(&library)[0].reason,
        super::LiveHoldReason::UnstartedRemainder
    );
    assert_eq!(
        super::holds(&library)[1].reason,
        super::LiveHoldReason::UncertainSubmission
    );
    Ok(())
}

#[test]
fn keep_current_adopts_different_observed_placement_without_claiming_old_destination()
-> Result<(), String> {
    let mut old = batch(true, 0)?;
    applied(&mut old, 0, 201)?;
    let original = old.clone();
    let mut library = state(old);
    let mut closure = keep_current(&library, 2, 401)?;
    let motion = closure
        .current_graph
        .iter_mut()
        .find(|v| v.fact.key == key(3))
        .ok_or("motion")?;
    motion.fact.placement = Placement::Hidden; // Old intent asked for Locked.
    motion.albums = vec![id(8_002)];
    closure.digest = super::closure_digest(&closure)?;
    library.immich_live_unstarted_closures.push(closure.clone());
    let loaded =
        crate::workflow::migrate(serde_json::to_value(&library).map_err(|e| e.to_string())?)?;
    assert_eq!(loaded.immich_live_operations[0], original);
    assert_eq!(loaded.immich_live_unstarted_closures[0], closure);
    // P2 is not automatically closed when the shared M remainder is closed.
    assert_eq!(
        super::holds(&loaded)[0].reason,
        super::LiveHoldReason::UnstartedRemainder
    );
    assert!(!super::original_continuation_open(&loaded, &original.id));
    assert!(super::fences(&loaded, &key(3)));
    Ok(())
}

#[test]
fn role_specific_initial_transition_matrix_is_exhaustive_without_enabling_nonlock_changes() {
    use Placement::{Archive as A, Hidden as H, Locked as L, Timeline as T};
    let image_lock = [(T, T), (A, A), (L, L), (T, L), (A, L)];
    let image_restore = [(T, T), (A, A), (L, L), (L, T), (L, A)];
    let video_lock = [(T, T), (A, A), (H, H), (L, L), (T, L), (A, L), (H, L)];
    let video_restore = [(T, T), (A, A), (H, H), (L, L), (L, T), (L, A), (L, H)];
    for (media, direction, enabled) in [
        (Media::Image, Direction::Lock, image_lock.as_slice()),
        (Media::Image, Direction::Restore, image_restore.as_slice()),
        (Media::Video, Direction::Lock, video_lock.as_slice()),
        (Media::Video, Direction::Restore, video_restore.as_slice()),
    ] {
        for from in [T, A, H, L] {
            for to in [T, A, H, L] {
                assert_eq!(
                    super::transition_allowed(media, direction, from, to),
                    enabled.contains(&(from, to))
                );
            }
        }
    }
}

#[test]
fn durable_transition_requires_first_unknown_and_never_submits_later_step_without_prior_intent()
-> Result<(), String> {
    let empty = SavedLibrary {
        schema_version: super::CURRENT_SCHEMA_VERSION,
        ..SavedLibrary::default()
    };
    let mut first = state(batch(true, 0)?);
    super::validate_transition(&empty, &first)?;
    let mut unattempted = first.clone();
    unattempted.immich_live_operations[0].steps[0].outcome = Outcome::NotStarted;
    assert!(super::validate_transition(&empty, &unattempted).is_err());
    let mut premature_applied = first.clone();
    applied(&mut premature_applied.immich_live_operations[0], 0, 201)?;
    assert!(super::validate_transition(&empty, &premature_applied).is_err());
    super::validate_transition(&first, &premature_applied)?;
    first = premature_applied;
    let mut second_intent = first.clone();
    second_intent.immich_live_operations[0].steps[1].outcome = Outcome::Unknown {
        attempt_id: id(202),
        accepted: None,
    };
    super::validate_transition(&first, &second_intent)?;
    let mut without_intent = first.clone();
    applied(&mut without_intent.immich_live_operations[0], 1, 202)?;
    assert!(super::validate_transition(&first, &without_intent).is_err());
    super::validate_transition(&second_intent, &without_intent)?;
    Ok(())
}

#[test]
fn durable_transition_rejects_replay_attempt_change_historical_rewrite_and_record_deletion()
-> Result<(), String> {
    let before = state(batch(false, 0)?);
    let mut replay = before.clone();
    replay.immich_live_operations[0].steps[0].outcome = Outcome::Unknown {
        attempt_id: id(299),
        accepted: None,
    };
    assert!(super::validate_transition(&before, &replay).is_err());
    let mut applied_state = before.clone();
    applied(&mut applied_state.immich_live_operations[0], 0, 201)?;
    let mut changed = applied_state.clone();
    if let Outcome::Applied { verified_post, .. } =
        &mut changed.immich_live_operations[0].steps[0].outcome
    {
        verified_post.resources[0].fact.revision = "rewritten-previous-Applied".into();
        verified_post.digest = super::post_digest(verified_post)?;
    }
    super::validate_library(&changed)?;
    assert!(super::validate_transition(&applied_state, &changed).is_err());
    changed.immich_live_operations.clear();
    assert!(super::validate_transition(&applied_state, &changed).is_err());
    Ok(())
}

#[test]
fn applied_and_next_unknown_require_two_separate_durable_transitions() -> Result<(), String> {
    let before = state(batch(false, 0)?);
    let mut result_only = before.clone();
    applied(&mut result_only.immich_live_operations[0], 0, 201)?;
    let mut combined = result_only.clone();
    combined.immich_live_operations[0].steps[1].outcome = Outcome::Unknown {
        attempt_id: id(202),
        accepted: None,
    };
    super::validate_library(&combined)?;
    assert!(super::validate_transition(&before, &combined).is_err());
    super::validate_transition(&before, &result_only)?;
    super::validate_transition(&result_only, &combined)?;
    Ok(())
}

#[test]
fn result_update_cannot_be_combined_with_closure_or_successor_retirement() -> Result<(), String> {
    let before = state(batch(false, 0)?);
    let mut result_only = before.clone();
    applied(&mut result_only.immich_live_operations[0], 0, 201)?;
    let mut closure_state = result_only.clone();
    closure_state
        .immich_live_unstarted_closures
        .push(keep_current(&result_only, 1, 401)?);
    super::validate_library(&closure_state)?;
    assert!(super::validate_transition(&before, &closure_state).is_err());
    super::validate_transition(&result_only, &closure_state)?;
    let old = &result_only.immich_live_operations[0];
    let mut successor = batch(false, 1_000)?;
    successor.intent.supersedes.push(super::StepRef {
        batch_id: old.id.clone(),
        step_id: old.steps[1].id.clone(),
        intent_digest: old.intent.digest.clone(),
        retired_outcomes_digest: super::retired_outcomes_digest(old)?,
    });
    seal(&mut successor)?;
    let mut successor_state = result_only.clone();
    successor_state.immich_live_operations.push(successor);
    super::validate_library(&successor_state)?;
    assert!(super::validate_transition(&before, &successor_state).is_err());
    super::validate_transition(&result_only, &successor_state)?;
    Ok(())
}

#[test]
fn unknown_receipt_only_update_is_one_durable_change_and_cannot_hide_batch_append()
-> Result<(), String> {
    let before = state(batch(false, 0)?);
    let mut receipt_only = before.clone();
    let batch = &mut receipt_only.immich_live_operations[0];
    batch.steps[0].outcome = Outcome::Unknown {
        attempt_id: id(201),
        accepted: Some(super::Accepted204 {
            batch_id: batch.id.clone(),
            step_id: batch.steps[0].id.clone(),
            attempt_id: id(201),
            key: key(1),
            intent_digest: batch.intent.digest.clone(),
        }),
    };
    super::validate_transition(&before, &receipt_only)?;
    receipt_only
        .immich_live_operations
        .push(self::batch(false, 1_000)?);
    super::validate_library(&receipt_only)?;
    assert!(super::validate_transition(&before, &receipt_only).is_err());
    Ok(())
}

#[test]
fn live_history_fences_exact_physical_keys_and_invalidates_ordinary_authority() -> Result<(), String>
{
    let mut library = state(batch(true, 0)?);
    let before = library.clone();
    let held = library.immich_live_operations[0].intent.resources[0]
        .initial
        .key
        .clone();
    let mut unrelated = held.clone();
    unrelated.asset_id = id(999);
    let access = crate::privacy::ContentAccess::new(&library);
    assert!(!access.can_operate(&held));
    assert!(!access.can_present(&held, &std::collections::BTreeSet::from([held.clone()])));
    assert!(access.can_operate(&unrelated));
    assert!(!super::fences(&library, &unrelated));
    library.immich_live_operations[0].latest_observations = library.immich_live_operations[0]
        .intent
        .resources
        .iter()
        .map(|r| super::MemberObservation {
            key: r.initial.key.clone(),
            state: super::ObservedState::Own(Box::new(r.initial.clone())),
        })
        .collect();
    assert!(crate::ordinary_selected::security_differs(
        &before, &library
    ));
    assert!(super::fences(&library, &held));
    // A matching observation never becomes an old submission receipt.
    assert!(matches!(
        library.immich_live_operations[0].steps[0].outcome,
        Outcome::Unknown { accepted: None, .. }
    ));
    Ok(())
}

#[test]
fn schema_eight_migration_preserves_nonempty_legacy_visibility_journal() -> Result<(), String> {
    let operation = legacy_record(400);
    let raw = json!({
        "schemaVersion": 8, "appleScope": "apple", "connection": null,
        "immichVisibilityOperations": [operation], "snapshots": [], "receipts": []
    });
    let old = raw["immichVisibilityOperations"].clone();
    let migrated = crate::workflow::migrate(raw)?;
    assert_eq!(
        serde_json::to_value(&migrated.immich_visibility_operations).map_err(|e| e.to_string())?,
        old
    );
    assert!(migrated.immich_live_operations.is_empty());
    assert!(migrated.immich_live_unstarted_closures.is_empty());
    assert!(migrated.immich_live_legacy_reconciliations.is_empty());
    Ok(())
}

#[test]
fn keep_unstarted_sibling_preserves_unknown_and_retires_original_cursor() -> Result<(), String> {
    let before = state(batch(false, 0)?);
    let old = before.immich_live_operations[0].clone();
    let mut after = before.clone();
    after
        .immich_live_unstarted_closures
        .push(keep_current(&before, 1, 450)?);
    super::validate_transition(&before, &after)?;
    assert_eq!(after.immich_live_operations[0], old);
    assert!(!super::original_continuation_open(&after, &old.id));
    assert!(super::fences(&after, &old.intent.resources[0].initial.key));
    let mut illegal = before.clone();
    illegal
        .immich_live_unstarted_closures
        .push(keep_current(&before, 0, 451)?);
    assert!(super::validate_library(&illegal).is_err());
    let mut late = after.clone();
    late.immich_live_operations[0].steps[1].outcome = Outcome::Unknown {
        attempt_id: match &old.steps[0].outcome {
            Outcome::Unknown { attempt_id, .. } => attempt_id.clone(),
            _ => return Err("fixture must begin Unknown".into()),
        },
        accepted: None,
    };
    assert!(super::validate_transition(&after, &late).is_err());
    Ok(())
}
