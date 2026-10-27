mod fixture {
    use crate::domain::{AssetKey, Provider};
    use crate::immich_live_writes::{
        Alias, Batch, Dependency, Direction, Edge, Fact, Forward, Intent, Media, Outcome,
        Placement, Resource, Role, Selection, Step,
    };

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
    pub(super) fn batch(shared: bool, offset: u32) -> Result<Batch, String> {
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
        intent.digest = crate::immich_live_writes::intent_digest(&intent)?;
        Ok(Batch {
            format_version: 1,
            id: id(offset + 101),
            intent,
            steps,
            latest_observations: vec![],
        })
    }
}
use super::*;
use crate::app::{Effect, Event, ShellResponse};
use crux_core::Command;
use serde_json::json;
use std::sync::{Arc, Mutex};

fn pair() -> Result<(SavedLibrary, SavedLibrary), String> {
    let before = SavedLibrary {
        schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
        ..SavedLibrary::default()
    };
    let mut desired = before.clone();
    desired
        .immich_live_operations
        .push(fixture::batch(false, 0)?);
    Ok((before, desired))
}
fn drive(
    before: SavedLibrary,
    desired: SavedLibrary,
    mut respond: impl FnMut(&ShellOperation) -> Result<ShellResponse, String>,
) -> Result<Result<SavedLibrary, SaveFailure>, String> {
    let result = Arc::new(Mutex::new(None));
    let output = result.clone();
    let mut command: Command<Effect, Event> = Command::new(move |ctx| async move {
        let value = save(&ctx, &before, &desired).await;
        if let Ok(mut result) = output.lock() {
            *result = Some(value);
        }
    });
    for _ in 0..16 {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut request) in effects {
            let response = respond(&request.operation)?;
            request.resolve(response).map_err(|_| "resolve")?;
        }
    }
    result
        .lock()
        .map_err(|_| "mutex")?
        .take()
        .ok_or_else(|| "save did not complete".into())
}
fn reply(value: Value) -> ShellResponse {
    ShellResponse {
        value: Some(value),
        error: None,
    }
}
fn disk(state: &SavedLibrary, revision: usize) -> ShellResponse {
    reply(json!({"revision": revision.to_string(), "state": state}))
}
#[test]
fn cas_retry_preserves_latest_unrelated_metadata() -> Result<(), String> {
    let (before, desired) = pair()?;
    let mut current = before.clone();
    current.apple_scope = "initial unrelated scope".into();
    let mut writes = 0;
    let result = drive(before, desired, |op| match op {
        ShellOperation::ReadStateVersioned => Ok(disk(&current, writes)),
        ShellOperation::PersistIfCurrent { revision, state } => {
            writes += 1;
            if writes == 1 {
                current.apple_scope = "concurrent native scope".into();
                Ok(reply(json!(false)))
            } else {
                assert_eq!(revision, "1");
                assert_eq!(state.apple_scope, "concurrent native scope");
                current = *state.clone();
                Ok(reply(json!(true)))
            }
        }
        other => Err(format!("unexpected effect: {other:?}")),
    })?
    .map_err(|_| "save failed")?;
    assert_eq!(writes, 2);
    assert_eq!(result.apple_scope, "concurrent native scope");
    assert_eq!(result.immich_live_operations.len(), 1);
    Ok(())
}
#[test]
fn lost_ack_reads_actual_disk_and_classifies_before_desired_or_unknown() -> Result<(), String> {
    for mode in 0..4 {
        let (before, desired) = pair()?;
        let mut current = before.clone();
        let mut wrote = false;
        let result = drive(before, desired, |op| match op {
            ShellOperation::ReadStateVersioned if wrote && mode == 3 => {
                Ok(reply(json!({"revision":"2", "state":null})))
            }
            ShellOperation::ReadStateVersioned => Ok(disk(&current, usize::from(wrote))),
            ShellOperation::PersistIfCurrent { state, .. } => {
                wrote = true;
                if mode == 0 {
                    current = *state.clone();
                    current.apple_scope = "after commit".into();
                }
                if mode == 2 {
                    current = *state.clone();
                    current.immich_live_operations[0].steps[0].outcome =
                        crate::immich_live_writes::Outcome::Unknown {
                            attempt_id: "00000999-0000-4000-8000-000000000000".into(),
                            accepted: None,
                        };
                }
                Ok(ShellResponse {
                    value: None,
                    error: Some("ack lost".into()),
                })
            }
            other => Err(format!("unexpected effect: {other:?}")),
        })?;
        if mode == 0 {
            assert_eq!(
                result.map_err(|_| "readback failed")?.apple_scope,
                "after commit"
            );
        } else {
            let failure = result.err().ok_or("must stop")?;
            assert_eq!(failure.uncertain, mode != 1);
            assert_eq!(failure.state.is_some(), mode != 3);
        }
    }
    Ok(())
}
#[test]
fn perpetual_cas_mismatch_is_bounded_and_readback_is_not_speculative() -> Result<(), String> {
    let (before, desired) = pair()?;
    let mut current = before.clone();
    let mut writes = 0;
    let result = drive(before, desired, |op| match op {
        ShellOperation::ReadStateVersioned => Ok(disk(&current, writes)),
        ShellOperation::PersistIfCurrent { .. } => {
            writes += 1;
            current.apple_scope = format!("writer-{writes}");
            Ok(reply(json!(false)))
        }
        other => Err(format!("unexpected effect: {other:?}")),
    })?
    .err()
    .ok_or("bounded stop")?;
    assert_eq!(writes, 3);
    assert!(!result.uncertain);
    let state = result.state.ok_or("missing confirmed state")?;
    assert_eq!(state.apple_scope, "writer-3");
    assert!(state.immich_live_operations.is_empty());
    Ok(())
}
#[test]
fn third_history_conflict_never_emits_a_write() -> Result<(), String> {
    let (before, desired) = pair()?;
    let mut third = before.clone();
    third
        .immich_live_operations
        .push(fixture::batch(false, 1000)?);
    let failure = drive(before, desired, |op| match op {
        ShellOperation::ReadStateVersioned => Ok(disk(&third, 0)),
        other => Err(format!("unexpected effect: {other:?}")),
    })?
    .err()
    .ok_or("conflicting history")?;
    assert!(failure.uncertain);
    assert_eq!(
        failure.state.ok_or("state")?.immich_live_operations[0].id,
        third.immich_live_operations[0].id
    );
    Ok(())
}

#[test]
fn idempotent_desired_readback_keeps_latest_metadata_without_cas() -> Result<(), String> {
    let (before, desired) = pair()?;
    let mut disk_state = desired.clone();
    disk_state.apple_scope = "new unrelated metadata".into();
    let result = drive(before, desired, |op| match op {
        ShellOperation::ReadStateVersioned => Ok(disk(&disk_state, 8)),
        other => Err(format!("unexpected effect: {other:?}")),
    })?
    .map_err(|_| "idempotent save failed")?;
    assert_eq!(result.apple_scope, "new unrelated metadata");
    Ok(())
}

#[test]
fn malformed_journal_read_is_never_confirmed_durable_state() -> Result<(), String> {
    let (before, desired) = pair()?;
    let mut malformed = serde_json::to_value(before.clone()).map_err(|e| e.to_string())?;
    malformed["immichLiveOperations"] = Value::Null;
    let mut reads = 0;
    let failure = drive(before, desired, |op| match op {
        ShellOperation::ReadStateVersioned => {
            reads += 1;
            Ok(reply(json!({"revision":"1", "state":malformed})))
        }
        other => Err(format!("unexpected effect: {other:?}")),
    })?
    .err()
    .ok_or("malformed read must stop")?;
    assert_eq!(reads, 2);
    assert!(failure.uncertain);
    assert!(failure.state.is_none());
    Ok(())
}
