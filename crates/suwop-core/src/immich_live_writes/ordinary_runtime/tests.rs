mod fixture {
    use crate::domain::{AssetKey, Provider};
    use crate::immich_live_writes::{
        Alias, Batch, Dependency, Direction, Edge, Fact, Forward, Intent, Media, Outcome,
        Placement, Resource, Role, Selection, Step,
    };

    pub(super) fn id(n: u32) -> String {
        format!("{n:08x}-0000-4000-8000-000000000000")
    }
    pub(super) fn key(n: u32) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: super::scope(),
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
            scope: super::scope(),
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
use crate::app::{ConnectionSettings, Effect, Event, ShellResponse};
use crate::app::{SavedLibrary, Suwop};
use crux_core::Core;
use serde_json::json;
fn scope() -> String {
    format!("https://fixture.invalid/api#{}", fixture::id(9000))
}
fn model(shared: bool) -> Result<Model, String> {
    let state = SavedLibrary {
        schema_version: 10,
        connection: Some(ConnectionSettings {
            address: "https://fixture.invalid".into(),
            allow_http: false,
            credential_id: "synthetic-only".into(),
        }),
        immich_live_operations: vec![fixture::batch(shared, 0)?],
        ..SavedLibrary::default()
    };
    Ok(Model {
        state,
        session: Some(Session {
            ordinary_content_guard: None,
            ordinary_content_context: None,
            endpoint: "https://fixture.invalid/api".into(),
            key: "synthetic-only".into(),
            user_id: fixture::id(9000),
            scope: scope(),
            version: crate::immich::Version {
                major: 3,
                minor: 2,
                patch: 4,
            },
        }),
        ready: true,
        ..Model::default()
    })
}
fn raw(id: &str, parent_visibility: &str) -> Value {
    let motion = id == fixture::id(3);
    json!({"id":id,"ownerId":fixture::id(9000),"type":if motion {"VIDEO"}else{"IMAGE"},
        "checksum":"a".repeat(40),"updatedAt":"fresh-revision","visibility":if motion {"hidden"}else{parent_visibility},
        "stack":null,"isOffline":false,"isTrashed":false,"livePhotoVideoId":if motion {Value::Null}else{json!(fixture::id(3))},
        "originalFileName":if motion {"motion.mov"}else{"parent.heic"},
        "fileCreatedAt":"2026-10-23T00:00:00Z","fileModifiedAt":"2026-10-23T00:00:00Z","isFavorite":false,
        "isEdited":false,"isExternal":false,"libraryId":null,"exifInfo":null})
}
fn resource_raw(id: &str) -> Value {
    let n = u32::from_str_radix(id.split('-').next().unwrap_or_default(), 16).unwrap_or_default();
    let mut value = raw(id, "timeline");
    if n % 10 == 3 {
        value["type"] = json!("VIDEO");
        value["visibility"] = json!("hidden");
        value["livePhotoVideoId"] = Value::Null;
        value["originalFileName"] = json!("synthetic-motion.mov");
    } else {
        value["livePhotoVideoId"] = json!(fixture::id(n + 2));
    }
    value
}
fn batch_for(
    index: u32,
    physical: u32,
    target_scope: &str,
) -> Result<crate::immich_live_writes::Batch, String> {
    let batch = fixture::batch(false, index * 1000)?;
    let mut encoded = serde_json::to_value(batch).map_err(|e| e.to_string())?;

    edit(&mut encoded, physical, target_scope);
    let mut batch: crate::immich_live_writes::Batch =
        serde_json::from_value(encoded).map_err(|e| e.to_string())?;
    batch.intent.digest = crate::immich_live_writes::intent_digest(&batch.intent)?;
    Ok(batch)
}
fn many(count: u32) -> Result<Model, String> {
    let mut model = model(false)?;
    model.state.immich_live_operations = (0..count)
        .map(|n| batch_for(n, n * 10, &scope()))
        .collect::<Result<_, _>>()?;
    Ok(model)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Fault {
    Hash,
    Drift,
    End,
    NativeTerminal,
    Workspace,
    BeginRejection,
    AckLoss,
}
#[derive(Default)]
struct Shell {
    privacy_mode: usize,
    metadata: usize,
    originals: usize,
    begins: usize,
    plays: usize,
    ends: usize,
    faults: BTreeSet<Fault>,
    sealed: BTreeSet<String>,
    scopes: Vec<String>,
    log: Vec<String>,
}
impl Shell {
    fn metadata_response(&mut self, request: &crate::immich::HttpRequest) -> Result<Value, String> {
        self.metadata += 1;
        assert_eq!(request.method, "GET");
        assert!(request.download_path.is_none());
        let mut value = resource_raw(request.url.rsplit('/').next().ok_or("id")?);
        match self.privacy_mode {
            1 => value["visibility"] = json!("locked"),
            2 => value["checksum"] = json!("b".repeat(40)),
            3 => return Ok(json!({"status":404,"body":null,"path":null})),
            4 => value = json!({"id":"malformed-private-asset"}),
            _ => {}
        }
        if self.faults.contains(&Fault::Drift) && self.originals == 2 {
            value["updatedAt"] = json!("after-original-drift");
        }
        self.log.push("metadata".into());
        Ok(json!({"status":200,"body":value,"path":null}))
    }
    fn respond(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) => self.metadata_response(request),
            ShellOperation::Workspace { id } => {
                assert!(crate::immich::valid_id(id).is_ok());
                self.log.push("workspace".into());
                if self.faults.contains(&Fault::Workspace) {
                    return Ok(json!("/fixture/untrusted-directory"));
                }
                Ok(json!(format!("/fixture/tmp/suwop-{id}")))
            }
            ShellOperation::BeginOrdinaryLivePairRead {
                scope_id,
                keys,
                workspace,
                presentation,
            } => {
                self.begins += 1;
                self.scopes.push(scope_id.clone());
                assert_eq!(keys, &vec![fixture::key(1), fixture::key(3)]);
                assert_eq!(presentation.parent_key, keys[0]);
                assert!(workspace.ends_with(scope_id));
                self.log.push("begin".into());
                if self.faults.contains(&Fault::BeginRejection) || self.sealed.contains(scope_id) {
                    return Ok(json!(false));
                }
                if self.faults.contains(&Fault::AckLoss) {
                    return Err("synthetic Begin acknowledgement lost".into());
                }
                Ok(json!(true))
            }
            ShellOperation::OrdinaryLivePairReadHttp { scope_id, request } => {
                assert!(self.scopes.contains(scope_id));
                if self.sealed.contains(scope_id) {
                    return Err("scope revoked".into());
                }
                assert_eq!(request.method, "GET");
                assert!(request.url.ends_with("/original?edited=false"));
                assert!(request.immich_visibility_authorization.is_none());
                let authorization = request
                    .ordinary_content_authorization
                    .as_ref()
                    .ok_or("ordinary auth")?;
                assert!(matches!(
                    authorization.purpose,
                    OrdinaryContentPurpose::Read
                ));
                let key = if self.originals == 0 {
                    fixture::key(1)
                } else {
                    fixture::key(3)
                };
                assert_eq!(authorization.source_keys, vec![key.clone()]);
                assert!(request.url.contains(&key.asset_id));
                assert!(
                    request
                        .download_path
                        .as_ref()
                        .is_some_and(|p| p.contains(scope_id))
                );
                self.originals += 1;
                self.log.push("original+hash".into());
                Ok(
                    json!({"response":{"status":200,"body":null,"path":request.download_path},"hash":{"sha1":if self.faults.contains(&Fault::Hash){"b".repeat(40)}else{"a".repeat(40)},"signature":{"sha256":"c".repeat(64),"bytes":8}}}),
                )
            }
            ShellOperation::PlayOrdinaryLivePairRead { scope_id, plan } => {
                assert!(self.scopes.contains(scope_id));
                assert_eq!(plan.source_keys, vec![fixture::key(1), fixture::key(3)]);
                assert_eq!(plan.files.len(), 2);
                assert_eq!(self.originals, 2);
                assert!(self.metadata >= 10);
                self.plays += 1;
                self.log.push("play".into());
                Ok(Value::Null)
            }
            ShellOperation::EndOrdinaryLivePairRead {
                scope_id,
                retry_cleanup,
            } => {
                assert!(crate::immich::valid_id(scope_id).is_ok());
                self.sealed.insert(scope_id.clone());
                self.ends += 1;
                self.log
                    .push(if *retry_cleanup { "retry-end" } else { "end" }.into());
                if self.faults.contains(&Fault::NativeTerminal) {
                    Err(super::NATIVE_TERMINAL_UNAVAILABLE.into())
                } else if self.faults.contains(&Fault::End) {
                    Err("synthetic unlink failure".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::Cleanup { .. } => {
                self.log.push("cleanup".into());
                Ok(Value::Null)
            }
            other => Err(format!("forbidden/unexpected effect {other:?}")),
        }
    }
    fn drain(&mut self, core: &Core<Suwop>, effects: Vec<Effect>) -> Result<(), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        while let Some(Effect::Io(mut request)) = queue.pop_front() {
            let response = match self.respond(&request.operation) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            queue.extend(
                core.resolve(&mut request, response)
                    .map_err(|_| "resolve")?,
            );
        }
        Ok(())
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.drain(core, core.process_event(event))
    }
}
fn refresh_event(id: &str) -> Event {
    Event::RefreshOrdinaryLivePair {
        parent_key: fixture::key(1),
        request_id: id.into(),
    }
}
fn play_event(id: &str) -> Event {
    Event::PlayOrdinaryLivePair {
        parent_key: fixture::key(1),
        request_id: id.into(),
    }
}
fn ready() -> Result<(Core<Suwop>, Shell), String> {
    let core = Core::new_with(Suwop, model(false)?);
    let mut shell = Shell::default();
    shell.run(&core, refresh_event("refresh-1"))?;
    assert_eq!(shell.metadata, 4);
    let action = core
        .view()
        .ordinary_live_actions
        .into_iter()
        .find(|a| a.parent_key == fixture::key(1))
        .ok_or("ordinary action")?;
    assert!(action.can_refresh && action.can_play);
    assert!(action.cleanup_request_id.is_none());
    Ok((core, shell))
}
#[test]
fn actual_core_product_refresh_to_owned_originals_playback_and_cleanup_join() -> Result<(), String>
{
    let (core, mut shell) = ready()?;
    shell.run(&core, play_event("play-1"))?;
    assert_eq!(
        (shell.begins, shell.originals, shell.plays, shell.ends),
        (1, 2, 1, 1)
    );
    assert!(
        shell.log.iter().position(|s| s == "play").ok_or("play")?
            < shell.log.iter().position(|s| s == "end").ok_or("end")?
    );
    assert_eq!(core.view().ordinary_live_pairs.len(), 1);
    let count = shell.log.len();
    shell.run(
        &core,
        Event::SetFavorite {
            keys: vec![fixture::key(1)],
            value: true,
        },
    )?;
    shell.run(
        &core,
        Event::Copy {
            keys: vec![fixture::key(1)],
            intent: crate::domain::TransferIntent::Copy,
            id: fixture::id(50000),
            now: 0.0,
        },
    )?;
    shell.run(
        &core,
        Event::TrashApple {
            keys: vec![fixture::key(1)],
            id: fixture::id(50001),
        },
    )?;
    assert_eq!(
        shell.log.len(),
        count,
        "display proof must not authorize metadata, transfer or deletion effects"
    );
    Ok(())
}
#[test]
fn original_hash_or_post_read_drift_rejects_play_and_joins_exact_scope() -> Result<(), String> {
    for hash in [true, false] {
        let (core, mut shell) = ready()?;
        shell
            .faults
            .insert(if hash { Fault::Hash } else { Fault::Drift });
        shell.run(&core, play_event("play-1"))?;
        assert_eq!(shell.plays, 0);
        assert_eq!(shell.ends, 1);
        assert_eq!(shell.originals, if hash { 1 } else { 2 });
    }
    Ok(())
}
#[test]
fn cancel_while_original_pending_seals_owner_then_late_result_cannot_play() -> Result<(), String> {
    let (core, mut shell) = ready()?;
    let mut queue: std::collections::VecDeque<_> = core.process_event(play_event("play-1")).into();
    let mut held = None;
    while let Some(Effect::Io(mut request)) = queue.pop_front() {
        if matches!(
            request.operation,
            ShellOperation::OrdinaryLivePairReadHttp { .. }
        ) {
            held = Some(request);
            break;
        }
        let value = shell.respond(&request.operation)?;
        queue.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    let mut held = held.ok_or("pending original")?;
    shell.run(
        &core,
        Event::CancelOrdinaryLivePair {
            request_id: "play-1".into(),
        },
    )?;
    assert_eq!(shell.ends, 1);
    let reply = match shell.respond(&held.operation) {
        Ok(value) => ShellResponse {
            value: Some(value),
            error: None,
        },
        Err(error) => ShellResponse {
            value: None,
            error: Some(error),
        },
    };
    shell.drain(
        &core,
        core.resolve(&mut held, reply).map_err(|_| "late resolve")?,
    )?;
    assert_eq!(shell.plays, 0);
    assert_eq!(shell.ends, 2);
    // An explicit Stop is not reported as a failed read.
    assert_eq!(core.view().error, None);
    Ok(())
}
#[test]
fn failed_cleanup_retains_scope_until_explicit_retry_and_blocks_replacement() -> Result<(), String>
{
    let (core, mut shell) = ready()?;
    shell.faults.insert(Fault::End);
    shell.run(&core, play_event("play-1"))?;
    let action = core
        .view()
        .ordinary_live_actions
        .into_iter()
        .find(|a| a.parent_key == fixture::key(1))
        .ok_or("cleanup action")?;
    assert!(!action.can_refresh && !action.can_play);
    assert_eq!(action.cleanup_request_id.as_deref(), Some("play-1"));
    let metadata = shell.metadata;
    shell.run(&core, refresh_event("must-not-replace"))?;
    assert_eq!(shell.metadata, metadata);
    shell.faults.remove(&Fault::End);
    shell.run(
        &core,
        Event::RetryOrdinaryLivePairCleanup {
            request_id: "wrong-owner".into(),
        },
    )?;
    assert_eq!(shell.ends, 1);
    shell.run(
        &core,
        Event::RetryOrdinaryLivePairCleanup {
            request_id: "play-1".into(),
        },
    )?;
    assert_eq!(shell.ends, 2);
    assert_eq!(shell.log.last().map(String::as_str), Some("retry-end"));
    shell.run(&core, refresh_event("fresh-after-join"))?;
    assert_eq!(shell.metadata, metadata + 4);
    Ok(())
}
#[test]
fn native_terminal_unavailable_blocks_reads_without_cleanup_retry() -> Result<(), String> {
    let (core, mut shell) = ready()?;
    shell.faults.insert(Fault::NativeTerminal);
    shell.run(&core, play_event("play-1"))?;
    assert_eq!((shell.plays, shell.ends, shell.begins), (1, 1, 1));
    let view = core.view();
    assert!(
        view.ordinary_live_actions
            .iter()
            .all(|a| a.cleanup_request_id.is_none() && !a.can_play && !a.can_refresh)
    );
    let progress = view.ordinary_live_progress.ok_or("retained native work")?;
    assert_eq!(progress.request_id, "play-1");
    assert!(!progress.can_cancel);
    assert_eq!(progress.phase, super::NATIVE_UNCERTAIN);
    assert_eq!(view.error.as_deref(), Some(super::NATIVE_UNCERTAIN));
    // The exact retry token is ignored: no End can claim a native terminal.
    shell.faults.clear();
    shell.run(
        &core,
        Event::RetryOrdinaryLivePairCleanup {
            request_id: "play-1".into(),
        },
    )?;
    assert_eq!(shell.ends, 1);
    // Reads and replacement playback stay refused while native ownership is uncertain.
    let metadata = shell.metadata;
    shell.run(&core, refresh_event("must-not-refresh"))?;
    shell.run(&core, play_event("must-not-play"))?;
    assert_eq!(shell.metadata, metadata);
    assert_eq!((shell.plays, shell.begins, shell.originals), (1, 1, 2));
    assert!(core.view().ordinary_live_progress.is_some());
    Ok(())
}
#[test]
fn generation_loss_before_private_acquired_completion_forbids_play() -> Result<(), String> {
    let model = model(false)?;
    let generation = model.ordinary_generation.clone();
    let core = Core::new_with(Suwop, model);
    let mut shell = Shell::default();
    shell.run(&core, refresh_event("refresh"))?;
    let mut queue: std::collections::VecDeque<_> = core.process_event(play_event("play")).into();
    while let Some(Effect::Io(mut request)) = queue.pop_front() {
        let value = shell.respond(&request.operation)?;
        if matches!(
            request.operation,
            ShellOperation::OrdinaryLivePairReadHttp { .. }
        ) {
            generation.fetch_add(1, Ordering::SeqCst);
        }
        queue.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    assert_eq!(shell.plays, 0);
    assert_eq!(shell.ends, 1);
    Ok(())
}

#[test]
fn begin_known_rejection_and_registered_ack_loss_both_join_exact_scope() -> Result<(), String> {
    for reject in [true, false] {
        let (core, mut shell) = ready()?;
        shell.faults.insert(if reject {
            Fault::BeginRejection
        } else {
            Fault::AckLoss
        });
        shell.run(&core, play_event("play-begin"))?;
        assert_eq!(shell.originals, 0);
        assert_eq!(shell.plays, 0);
        assert_eq!(shell.ends, 1);
        assert_eq!(
            shell.log.iter().filter(|v| v.as_str() == "cleanup").count(),
            0
        );
    }
    Ok(())
}
#[test]
fn cancellation_before_workspace_reply_seals_queued_begin_without_original_io() -> Result<(), String>
{
    let (core, mut shell) = ready()?;
    let mut queue: std::collections::VecDeque<_> =
        core.process_event(play_event("play-before-begin")).into();
    let mut held = None;
    while let Some(Effect::Io(mut request)) = queue.pop_front() {
        if matches!(request.operation, ShellOperation::Workspace { .. }) {
            held = Some(request);
            break;
        }
        let value = shell.respond(&request.operation)?;
        queue.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
    let mut held = held.ok_or("pending workspace")?;
    shell.run(
        &core,
        Event::CancelOrdinaryLivePair {
            request_id: "play-before-begin".into(),
        },
    )?;
    assert_eq!(shell.ends, 1);
    let value = shell.respond(&held.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "workspace reply")?,
    )?;
    assert_eq!(shell.begins, 1);
    assert_eq!(shell.originals, 0);
    assert_eq!(shell.plays, 0);
    assert_eq!(shell.ends, 2);
    assert_eq!(
        shell.log.iter().filter(|v| v.as_str() == "cleanup").count(),
        0
    );
    Ok(())
}

#[test]
fn malformed_workspace_response_is_not_used_for_begin_or_arbitrary_cleanup() -> Result<(), String> {
    let (core, mut shell) = ready()?;
    shell.faults.insert(Fault::Workspace);
    shell.run(&core, play_event("play-bad-workspace"))?;
    assert_eq!(shell.begins, 0);
    assert_eq!(shell.originals, 0);
    assert_eq!(shell.plays, 0);
    assert_eq!(shell.ends, 0);
    assert!(!shell.log.iter().any(|s| s == "cleanup"));
    Ok(())
}

#[test]
fn generic_discovery_visits_all_35_pairs_and_preserves_all_rows_on_refresh() -> Result<(), String> {
    let core = Core::new_with(Suwop, many(35)?);
    let mut shell = Shell::default();
    assert!(core.view().ordinary_live_actions.is_empty());
    assert!(core.view().ordinary_live_pairs.is_empty());
    for id in ["discover-all-1", "discover-all-2"] {
        let before = shell.metadata;
        shell.run(
            &core,
            Event::RefreshOrdinaryLivePairs {
                request_id: id.into(),
            },
        )?;
        assert_eq!(shell.metadata - before, 35 * 4);
        assert_eq!(core.view().ordinary_live_pairs.len(), 35);
        assert_eq!(core.view().ordinary_live_actions.len(), 35);
        let parents: BTreeSet<_> = core
            .view()
            .ordinary_live_pairs
            .into_iter()
            .map(|p| p.parent_key)
            .collect();
        assert!(parents.contains(&AssetKey {
            asset_id: fixture::id(341),
            ..fixture::key(1)
        }));
    }
    Ok(())
}
#[test]
fn generic_discovery_never_exposes_locked_unavailable_malformed_or_drift_ids() -> Result<(), String>
{
    for mode in 1..=4 {
        let core = Core::new_with(Suwop, model(false)?);
        let mut shell = Shell {
            privacy_mode: mode,
            ..Shell::default()
        };
        shell.run(
            &core,
            Event::RefreshOrdinaryLivePairs {
                request_id: "discover-private".into(),
            },
        )?;
        assert!(core.view().ordinary_live_actions.is_empty());
        assert!(core.view().ordinary_live_pairs.is_empty());
        let public =
            serde_json::to_string(&core.view().ordinary_live_actions).map_err(|e| e.to_string())?;
        assert!(!public.contains(&fixture::id(1)));
        assert!(!public.contains("synthetic"));
    }
    Ok(())
}
#[test]
fn generic_discovery_filters_foreign_scope_even_when_physical_ids_are_identical()
-> Result<(), String> {
    let mut model = model(false)?;
    let foreign = "https://other.invalid/api#another-owner";
    model
        .state
        .immich_live_operations
        .push(batch_for(1, 0, foreign)?);
    let core = Core::new_with(Suwop, model);
    let mut shell = Shell::default();
    assert!(core.view().ordinary_live_actions.is_empty());
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: "discover-account".into(),
        },
    )?;
    assert_eq!(shell.metadata, 4);
    let view = core.view();
    assert_eq!(view.ordinary_live_pairs.len(), 1);
    assert!(
        view.ordinary_live_actions
            .iter()
            .all(|a| a.parent_key.scope == scope())
    );
    assert!(
        !serde_json::to_string(&view.ordinary_live_actions)
            .map_err(|e| e.to_string())?
            .contains(foreign)
    );
    Ok(())
}
#[test]
fn stale_proof_has_no_public_action_or_pair_identifier() -> Result<(), String> {
    let model = model(false)?;
    let generation = model.ordinary_generation.clone();
    let core = Core::new_with(Suwop, model);
    let mut shell = Shell::default();
    shell.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: "discover".into(),
        },
    )?;
    assert_eq!(core.view().ordinary_live_actions.len(), 1);
    generation.fetch_add(1, Ordering::SeqCst);
    assert!(core.view().ordinary_live_actions.is_empty());
    assert!(core.view().ordinary_live_pairs.is_empty());
    Ok(())
}
#[test]
fn cancelled_generic_discovery_stops_remaining_35_candidate_gets() -> Result<(), String> {
    let core = Core::new_with(Suwop, many(35)?);
    let mut shell = Shell::default();
    let mut effects = core.process_event(Event::RefreshOrdinaryLivePairs {
        request_id: "discover-cancel".into(),
    });
    let progress = core
        .view()
        .ordinary_live_progress
        .ok_or("discovery progress")?;
    assert_eq!(progress.request_id, "discover-cancel");
    assert!(progress.can_cancel);
    assert!(!progress.phase.contains(&fixture::id(1)));
    assert_eq!(effects.len(), 1);
    let Effect::Io(mut held) = effects.remove(0);
    assert!(core.view().ordinary_live_actions.is_empty());
    shell.run(
        &core,
        Event::CancelOrdinaryLivePair {
            request_id: "discover-cancel".into(),
        },
    )?;
    let value = shell.respond(&held.operation)?;
    shell.drain(
        &core,
        core.resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "late discovery")?,
    )?;
    assert_eq!(shell.metadata, 1);
    assert!(core.view().ordinary_live_actions.is_empty());
    assert!(core.view().ordinary_live_pairs.is_empty());
    assert!(core.view().ordinary_live_progress.is_none());
    Ok(())
}
#[test]
fn account_change_exposes_only_exact_owned_cleanup_with_no_read_or_play_authority()
-> Result<(), String> {
    let (core, mut shell) = ready()?;
    shell.faults.insert(Fault::End);
    shell.run(&core, play_event("owned-cleanup"))?;
    let mut other = model(false)?;
    let mut session = other.session.take().ok_or("session")?;
    session.endpoint = "https://other.invalid/api".into();
    session.scope = format!("{}#{}", session.endpoint, session.user_id);
    other.state.connection.as_mut().ok_or("connection")?.address = "https://other.invalid".into();
    shell.run(
        &core,
        Event::Finished {
            state: other.state,
            session: Some(session),
            status: String::new(),
            error: None,
            preview_to_select: None,
        },
    )?;
    let view = core.view();
    assert!(view.ordinary_live_pairs.is_empty());
    assert_eq!(view.ordinary_live_actions.len(), 1);
    let action = &view.ordinary_live_actions[0];
    assert_eq!(action.parent_key, fixture::key(1));
    assert_eq!(action.cleanup_request_id.as_deref(), Some("owned-cleanup"));
    assert!(!action.can_refresh && !action.can_play);
    let count = shell.metadata;
    shell.run(&core, play_event("foreign-play"))?;
    assert_eq!(shell.metadata, count);
    assert_eq!(shell.plays, 1);
    shell.faults.remove(&Fault::End);
    shell.run(
        &core,
        Event::RetryOrdinaryLivePairCleanup {
            request_id: "owned-cleanup".into(),
        },
    )?;
    assert!(core.view().ordinary_live_actions.is_empty());
    Ok(())
}

fn edit(value: &mut Value, physical: u32, scope: &str) {
    match value {
        Value::Object(object) => {
            if object.contains_key("scope") {
                object.insert("scope".into(), json!(scope));
            }
            if object.contains_key("provider") {
                for n in [1, 3, 4] {
                    if object.get("assetID").and_then(Value::as_str) == Some(&fixture::id(n)) {
                        object.insert("assetID".into(), json!(fixture::id(n + physical)));
                        break;
                    }
                }
            }
            for child in object.values_mut() {
                edit(child, physical, scope);
            }
        }
        Value::Array(values) => {
            for child in values {
                edit(child, physical, scope);
            }
        }
        _ => {}
    }
}
