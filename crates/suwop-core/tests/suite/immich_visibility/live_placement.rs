//! Product Core events/effects with synthetic provider, CAS and native responses.
//! Real storage/native/UI acceptance is intentionally a separate gate.
use super::*;
use suwop_core::immich_live_writes::{LivePlacementDestination, Outcome};
const MOTION: &str = "66666666-6666-4666-8666-666666666666";
#[derive(Clone, Copy)]
enum Confirmation {
    Accept,
    Reject,
}
struct BatchShell {
    base: Shell,
    facts: std::collections::BTreeMap<String, Value>,
    albums: std::collections::BTreeMap<String, Vec<Value>>,
    revision: u64,
    confirmations: usize,
    confirmed_batches: std::collections::BTreeSet<String>,
    captures: usize,
    drains: usize,
    puts: Vec<String>,
    confirmation: Confirmation,
    drain_failures: usize,
    http_count: usize,
    lose_response_at: Option<usize>,
    cancel_after_put: bool,
    cancel_after_read: bool,
    diagnostic_fail: std::collections::BTreeSet<String>,
    deny_persist: bool,
}
impl BatchShell {
    fn new(mut base: Shell) -> Result<Self, String> {
        if base.disk.is_none() {
            base.disk = Some(
                serde_json::to_value(
                    model_denials(false, vec![], std::collections::BTreeSet::new()).state,
                )
                .map_err(|e| e.to_string())?,
            );
        }
        let mut parent = asset();
        parent["livePhotoVideoId"] = json!(MOTION);
        let mut motion = asset();
        motion["id"] = json!(MOTION);
        motion["type"] = json!("VIDEO");
        motion["visibility"] = json!("hidden");
        Ok(Self {
            base,
            facts: std::collections::BTreeMap::from([
                (ASSET.into(), parent),
                (MOTION.into(), motion),
            ]),
            albums: std::collections::BTreeMap::new(),
            revision: 0,
            confirmations: 0,
            confirmed_batches: std::collections::BTreeSet::new(),
            captures: 0,
            drains: 0,
            puts: vec![],
            confirmation: Confirmation::Accept,
            drain_failures: 0,
            http_count: 0,
            lose_response_at: None,
            cancel_after_put: false,
            cancel_after_read: false,
            diagnostic_fail: std::collections::BTreeSet::new(),
            deny_persist: false,
        })
    }
    fn response(&mut self, core: &Core<Suwop>, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::ConfirmImmichLiveKeep { prompt } => {
                let current = core.view().live_keep_prompt.ok_or("keep prompt")?;
                assert_eq!(current.closure_id, prompt.closure_id);
                assert!(!prompt.targets.is_empty());
                assert!(
                    prompt
                        .resources
                        .iter()
                        .all(|r| r.unchanged && r.from == r.to)
                );
                Ok(json!(!matches!(self.confirmation, Confirmation::Reject)))
            }
            ShellOperation::ConfirmImmichLivePlacement { prompt } => {
                self.confirmations += 1;
                self.confirmed_batches.insert(prompt.batch_id.clone());
                let current = core.view().live_placement_prompt.ok_or("live prompt")?;
                assert_eq!(current.intent_digest, prompt.intent_digest);
                assert_eq!(prompt.resources.len(), self.facts.len());
                assert!(prompt.shared_reference_limitations_acknowledged);
                Ok(json!(!matches!(self.confirmation, Confirmation::Reject)))
            }
            ShellOperation::CapturePrivateMediaBatch { keys, .. } => {
                assert_eq!(keys.len(), self.facts.len());
                self.captures += 1;
                Ok(Value::Null)
            }
            ShellOperation::DrainCapturedPrivateMediaBatch { capture_id, .. } => {
                self.drains += 1;
                if self.drain_failures > 0 {
                    self.drain_failures -= 1;
                    return Err("synthetic native termination not confirmed".into());
                }
                Ok(json!({"captureID":capture_id,"cancelledBeforeCapture":false}))
            }
            ShellOperation::ReadStateVersioned => {
                Ok(json!({"revision":self.revision.to_string(),"state":self.base.disk}))
            }
            ShellOperation::PersistIfCurrent { revision, state } => {
                if self.deny_persist {
                    return Err("synthetic storage unavailable".into());
                }
                if revision != &self.revision.to_string() {
                    return Ok(json!(false));
                }
                let before = suwop_core::workflow::migrate(self.base.disk.clone().ok_or("disk")?)?;
                suwop_core::immich_live_writes::validate_transition(&before, state)?;
                self.base.disk = Some(serde_json::to_value(state).map_err(|e| e.to_string())?);
                self.revision += 1;
                Ok(json!(true))
            }
            ShellOperation::Http(request) => self.http(request),
            _ => self.base.respond(op),
        }
    }
    fn http(&mut self, request: &suwop_core::immich::HttpRequest) -> Result<Value, String> {
        self.http_count += 1;
        match request {
            request if request.method == "GET" && request.url.contains("/albums?assetId=") => {
                let id = request.url.rsplit('=').next().ok_or("assetid")?;
                Ok(json!({"status":200,"body":self.albums.get(id).cloned().unwrap_or_default()}))
            }
            request
                if request.method == "GET"
                    && self
                        .facts
                        .keys()
                        .any(|id| request.url.ends_with(&format!("/assets/{id}"))) =>
            {
                let id = request.url.rsplit('/').next().ok_or("id")?;
                if self.diagnostic_fail.contains(id) {
                    return Ok(json!({"status":404,"body":{}}));
                }
                Ok(json!({"status":200,"body":self.facts[id]}))
            }
            request if request.method == "PUT" && request.url.ends_with("/assets") => {
                assert!(self.confirmations > 0);
                assert!(self.captures > 0 && self.drains == self.captures);
                let body = request.body.as_ref().ok_or("body")?;
                let ids = body["ids"].as_array().ok_or("ids")?;
                assert_eq!(ids.len(), 1);
                let id = ids[0].as_str().ok_or("id")?.to_owned();
                let state = suwop_core::workflow::migrate(self.base.disk.clone().ok_or("disk")?)?;
                let batch = state.immich_live_operations.last().ok_or("batch")?;
                assert!(self.confirmed_batches.contains(&batch.id));
                let step = batch
                    .steps
                    .iter()
                    .find(|s| matches!(s.outcome, Outcome::Unknown { accepted: None, .. }))
                    .ok_or("durable unknown")?;
                let resource = batch
                    .intent
                    .resources
                    .iter()
                    .find(|r| r.id == step.resource_id)
                    .ok_or("resource")?;
                assert_eq!(resource.initial.key.asset_id, id);
                self.puts.push(id.clone());
                let fact = self.facts.get_mut(&id).ok_or("fact")?;
                fact["visibility"] = body["visibility"].clone();
                fact["updatedAt"] = json!(format!("after-{}", self.puts.len()));
                if body["visibility"] == "locked" {
                    self.albums.insert(id, vec![]);
                }
                if self.lose_response_at == Some(self.puts.len()) {
                    return Err("lost after provider apply".into());
                }
                Ok(json!({"status":204,"body":null}))
            }
            _ => self.base.respond(&ShellOperation::Http(request.clone())),
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut pending = std::collections::VecDeque::from(core.process_event(event));
        let mut count = 0;
        while let Some(effect) = pending.pop_front() {
            count += 1;
            if count > 1000 {
                return Err("effect budget".into());
            }
            let Effect::Io(mut request) = effect;
            let response = self.response(core, &request.operation);
            if self.cancel_after_put
                && matches!(&request.operation,ShellOperation::Http(r) if r.method=="PUT")
            {
                self.cancel_after_put = false;
                pending.extend(core.process_event(Event::CloseImmichLocked));
            }
            if self.cancel_after_read
                && matches!(&request.operation, ShellOperation::Http(r) if r.method == "GET" && r.url.contains("/assets/"))
            {
                self.cancel_after_read = false;
                pending.extend(core.process_event(Event::CloseImmichLocked));
            }
            let reply = ShellResponse {
                value: response.as_ref().ok().cloned(),
                error: response.err(),
            };
            pending.extend(core.resolve(&mut request, reply).map_err(|_| "resolve")?);
        }
        Ok(())
    }
}
fn placement(id: &str, to: LivePlacementDestination) -> Event {
    Event::PrepareImmichLivePlacement {
        parents: vec![key()],
        destination: to,
        batch_id: id.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn product_pair_lock_restore_has_durable_order_and_successful_model_adoption() -> Result<(), String>
{
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    assert_eq!(shell.puts, vec![ASSET.to_owned(), MOTION.to_owned()]);
    assert!(!core.view().busy);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    let locked = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(
        locked.immich_live_operations[0]
            .steps
            .iter()
            .all(|s| matches!(s.outcome, Outcome::Applied { .. }))
    );
    shell.run(&core, placement(NEXT, LivePlacementDestination::Timeline))?;
    assert_eq!(
        shell.puts,
        vec![
            ASSET.to_owned(),
            MOTION.to_owned(),
            MOTION.to_owned(),
            ASSET.to_owned()
        ]
    );
    assert_eq!(shell.facts[ASSET]["visibility"], "timeline");
    assert_eq!(shell.facts[MOTION]["visibility"], "hidden");
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(!core.view().busy);
    let restored = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(
        restored
            .immich_live_operations
            .iter()
            .flat_map(|batch| &batch.steps)
            .all(|step| matches!(step.outcome, Outcome::Applied { .. }))
    );
    assert!(
        core.view()
            .live_placement_history
            .batches
            .iter()
            .flat_map(|batch| &batch.resources)
            .all(|resource| resource.historical_outcome == "この試行で適用を確認")
    );
    Ok(())
}
#[test]
fn rejected_pair_confirmation_never_captures_persists_or_submits() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.confirmation = Confirmation::Reject;
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    assert_eq!(shell.captures, 0);
    assert_eq!(shell.revision, 0);
    assert!(shell.puts.is_empty());
    Ok(())
}
#[test]
fn mixed_restore_changes_only_locked_members() -> Result<(), String> {
    for motion in ["timeline", "archive", "hidden"] {
        let (core, base) = opened(false)?;
        let mut shell = BatchShell::new(base)?;
        shell.facts.get_mut(ASSET).ok_or("parent")?["visibility"] = json!("locked");
        shell.facts.get_mut(MOTION).ok_or("motion")?["visibility"] = json!(motion);
        shell.run(&core, placement(OP, LivePlacementDestination::Timeline))?;
        assert_eq!(shell.puts, vec![ASSET]);
        assert_eq!(shell.facts[MOTION]["visibility"], motion);
    }
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.facts.get_mut(MOTION).ok_or("motion")?["visibility"] = json!("locked");
    shell.run(&core, placement(OP, LivePlacementDestination::Timeline))?;
    assert_eq!(shell.puts, vec![MOTION]);
    assert_eq!(shell.facts[ASSET]["visibility"], "timeline");
    Ok(())
}
#[test]
fn lost_first_response_keeps_unknown_and_never_submits_motion() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.lose_response_at = Some(1);
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    assert_eq!(shell.puts, vec![ASSET]);
    let state = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(matches!(
        state.immich_live_operations[0].steps[0].outcome,
        Outcome::Unknown { accepted: None, .. }
    ));
    assert!(matches!(
        state.immich_live_operations[0].steps[1].outcome,
        Outcome::NotStarted
    ));
    Ok(())
}
#[test]
fn closing_scene_after_response_keeps_accepted_unknown_without_next_put() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.cancel_after_put = true;
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    assert_eq!(shell.puts, vec![ASSET]);
    let state = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(matches!(
        state.immich_live_operations[0].steps[0].outcome,
        Outcome::Unknown {
            accepted: Some(_),
            ..
        }
    ));
    assert!(matches!(
        state.immich_live_operations[0].steps[1].outcome,
        Outcome::NotStarted
    ));
    Ok(())
}

fn inspect_batch() -> Event {
    Event::InspectImmichLivePlacement {
        batch_id: OP.into(),
        request_id: "77777777-7777-4777-8777-777777777777".into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
fn keep_batch(step: String) -> Event {
    Event::KeepImmichLivePlacement {
        batch_id: OP.into(),
        closure_id: "88888888-8888-4888-8888-888888888888".into(),
        step_ids: vec![step],
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn inspect_then_keep_unstarted_never_upgrades_unknown_or_retries_provider() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.lose_response_at = Some(1);
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    let before = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    let outcomes = before.immich_live_operations[0].steps.clone();
    shell.run(&core, inspect_batch())?;
    let inspected = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(inspected.immich_live_operations[0].steps, outcomes);
    assert_eq!(
        inspected.immich_live_operations[0]
            .latest_observations
            .len(),
        2
    );
    shell.run(&core, keep_batch(outcomes[1].id.clone()))?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(after.immich_live_operations[0].steps, outcomes);
    assert_eq!(after.immich_live_unstarted_closures.len(), 1);
    assert!(!suwop_core::immich_live_writes::original_continuation_open(
        &after, OP
    ));
    assert_eq!(shell.puts, vec![ASSET]);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    Ok(())
}
#[test]
fn keep_refusal_and_storage_failure_do_not_report_saved_or_change_outcomes() -> Result<(), String> {
    for refuse in [true, false] {
        let (core, base) = opened(false)?;
        let mut shell = BatchShell::new(base)?;
        shell.lose_response_at = Some(1);
        shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
        let before = shell.base.disk.clone().ok_or("disk")?;
        let state = suwop_core::workflow::migrate(before.clone())?;
        shell.confirmation = if refuse {
            Confirmation::Reject
        } else {
            Confirmation::Accept
        };
        shell.deny_persist = !refuse;
        shell.run(
            &core,
            keep_batch(state.immich_live_operations[0].steps[1].id.clone()),
        )?;
        assert_eq!(shell.base.disk, Some(before));
        assert!(!core.view().status.contains("記録しました"));
        assert_eq!(shell.puts, vec![ASSET]);
    }
    Ok(())
}
#[test]
fn inspect_partial_failure_and_changed_own_relation_remain_diagnostic_only() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.lose_response_at = Some(1);
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    let before = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    shell.facts.get_mut(ASSET).ok_or("parent")?["livePhotoVideoId"] = Value::Null;
    shell.diagnostic_fail.insert(MOTION.into());
    shell.run(&core, inspect_batch())?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(
        before.immich_live_operations[0].steps,
        after.immich_live_operations[0].steps
    );
    assert!(
        matches!(&after.immich_live_operations[0].latest_observations[0].state, suwop_core::immich_live_writes::ObservedState::Own(fact) if fact.forward == suwop_core::immich_live_writes::Forward::Unlinked)
    );
    assert!(matches!(
        &after.immich_live_operations[0].latest_observations[1].state,
        suwop_core::immich_live_writes::ObservedState::Unavailable(_)
    ));
    assert_eq!(shell.puts, vec![ASSET]);
    Ok(())
}
#[test]
fn inspect_cancel_stops_new_reads_and_records_unobserved_remainder() -> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.lose_response_at = Some(1);
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    shell.cancel_after_read = true;
    shell.run(&core, inspect_batch())?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(matches!(
        &after.immich_live_operations[0].latest_observations[1].state,
        suwop_core::immich_live_writes::ObservedState::NotObserved
    ));
    assert_eq!(shell.puts, vec![ASSET]);
    Ok(())
}

fn targets(
    values: &[(&str, suwop_core::immich_live_writes::Placement)],
) -> Vec<suwop_core::immich_live_writes::LiveResourceDestination> {
    values
        .iter()
        .map(
            |(id, destination)| suwop_core::immich_live_writes::LiveResourceDestination {
                key: AssetKey {
                    asset_id: (*id).into(),
                    ..key()
                },
                destination: *destination,
            },
        )
        .collect()
}
fn explicit(
    parents: Vec<AssetKey>,
    destinations: Vec<suwop_core::immich_live_writes::LiveResourceDestination>,
    predecessor: Option<String>,
    supersedes: Vec<String>,
) -> Event {
    Event::PrepareImmichLiveResourcePlacements {
        parents,
        destinations,
        batch_id: NEXT.into(),
        predecessor_batch_id: predecessor,
        supersedes_step_ids: supersedes,
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn explicit_mixed_shared_motion_writes_once_in_safe_dependency_order() -> Result<(), String> {
    use suwop_core::immich_live_writes::Placement;
    const SECOND: &str = "99999999-9999-4999-8999-999999999999";
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    let mut second = shell.facts[ASSET].clone();
    second["id"] = json!(SECOND);
    shell.facts.insert(SECOND.into(), second);
    shell.run(
        &core,
        explicit(
            vec![
                key(),
                AssetKey {
                    asset_id: SECOND.into(),
                    ..key()
                },
            ],
            targets(&[
                (ASSET, Placement::Locked),
                (SECOND, Placement::Archive),
                (MOTION, Placement::Timeline),
            ]),
            None,
            vec![],
        ),
    )?;
    assert_eq!(shell.puts, vec![ASSET, MOTION, SECOND]);
    let state = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(state.immich_live_operations[0].intent.resources.len(), 3);
    assert_eq!(state.immich_live_operations[0].intent.edges.len(), 2);
    assert!(
        state.immich_live_operations[0]
            .steps
            .iter()
            .all(|step| matches!(step.outcome, Outcome::Applied { .. }))
    );
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    Ok(())
}
#[test]
fn explicit_map_rejects_missing_duplicate_conflicting_and_parent_hidden_targets()
-> Result<(), String> {
    use suwop_core::immich_live_writes::Placement;
    for values in [
        vec![(ASSET, Placement::Archive)],
        vec![
            (ASSET, Placement::Archive),
            (MOTION, Placement::Hidden),
            (MOTION, Placement::Locked),
        ],
        vec![(ASSET, Placement::Hidden), (MOTION, Placement::Timeline)],
    ] {
        let (core, base) = opened(false)?;
        let mut shell = BatchShell::new(base)?;
        shell.run(&core, explicit(vec![key()], targets(&values), None, vec![]))?;
        assert!(shell.puts.is_empty());
        assert_eq!(shell.confirmations, 0);
        assert_eq!(shell.revision, 0);
    }
    Ok(())
}
#[test]
fn explicit_new_intent_retires_unstarted_cursor_without_rewriting_old_result() -> Result<(), String>
{
    use suwop_core::immich_live_writes::Placement;
    let (first, base) = opened(false)?;
    let mut initial = BatchShell::new(base)?;
    initial.run(&first, placement(OP, LivePlacementDestination::Locked))?;
    let mut state = suwop_core::workflow::migrate(initial.base.disk.clone().ok_or("disk")?)?;
    state.immich_live_operations[0].steps[1].outcome = Outcome::NotStarted;
    suwop_core::immich_live_writes::validate_library(&state)?;
    let original = state.immich_live_operations[0].clone();
    let mut model = model_denials(false, vec![], std::collections::BTreeSet::new());
    model.state = state.clone();
    let core = Core::new_with(Suwop, model);
    let mut base = Shell {
        confirmed: true,
        disk: Some(serde_json::to_value(&state).map_err(|e| e.to_string())?),
        ..Shell::default()
    };
    base.run(&core, open(GRANT))?;
    let mut shell = BatchShell::new(base)?;
    shell.facts.get_mut(ASSET).ok_or("parent")?["visibility"] = json!("locked");
    shell.run(
        &core,
        explicit(
            vec![key()],
            targets(&[(ASSET, Placement::Archive), (MOTION, Placement::Hidden)]),
            Some(OP.into()),
            vec![original.steps[1].id.clone()],
        ),
    )?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(after.immich_live_operations.len(), 2);
    assert_eq!(after.immich_live_operations[0], original);
    assert!(!suwop_core::immich_live_writes::original_continuation_open(
        &after, OP
    ));
    assert_eq!(after.immich_live_operations[1].intent.supersedes.len(), 1);
    assert_eq!(shell.puts, vec![ASSET]);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    Ok(())
}

const SECOND_PARENT: &str = "99999999-9999-4999-8999-999999999999";
fn paused_shared() -> Result<
    (
        Core<Suwop>,
        BatchShell,
        Vec<suwop_core::immich_live_writes::Step>,
    ),
    String,
> {
    use suwop_core::immich_live_writes::Placement;
    let (first, base) = opened(false)?;
    let mut initial = BatchShell::new(base)?;
    let mut second = initial.facts[ASSET].clone();
    second["id"] = json!(SECOND_PARENT);
    initial.facts.insert(SECOND_PARENT.into(), second);
    initial.run(
        &first,
        Event::PrepareImmichLiveResourcePlacements {
            parents: vec![
                key(),
                AssetKey {
                    asset_id: SECOND_PARENT.into(),
                    ..key()
                },
            ],
            destinations: targets(&[
                (ASSET, Placement::Locked),
                (SECOND_PARENT, Placement::Locked),
                (MOTION, Placement::Locked),
            ]),
            batch_id: OP.into(),
            predecessor_batch_id: None,
            supersedes_step_ids: vec![],
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    let mut state = suwop_core::workflow::migrate(initial.base.disk.clone().ok_or("disk")?)?;
    for step in state.immich_live_operations[0].steps.iter_mut().skip(1) {
        step.outcome = Outcome::NotStarted;
    }
    suwop_core::immich_live_writes::validate_library(&state)?;
    let steps = state.immich_live_operations[0].steps.clone();
    let mut model = model_denials(false, vec![], std::collections::BTreeSet::new());
    model.state = state.clone();
    let core = Core::new_with(Suwop, model);
    let mut base = Shell {
        confirmed: true,
        disk: Some(serde_json::to_value(&state).map_err(|e| e.to_string())?),
        ..Shell::default()
    };
    base.run(&core, open(GRANT))?;
    let mut shell = BatchShell::new(base)?;
    shell.facts.get_mut(ASSET).ok_or("parent")?["visibility"] = json!("locked");
    let mut second = shell.facts[ASSET].clone();
    second["id"] = json!(SECOND_PARENT);
    second["visibility"] = json!("timeline");
    shell.facts.insert(SECOND_PARENT.into(), second);
    Ok((core, shell, steps))
}
#[test]
fn partial_keep_allows_fresh_remaining_intent_but_never_reuses_closed_reference()
-> Result<(), String> {
    use suwop_core::immich_live_writes::Placement;
    let (core, mut shell, steps) = paused_shared()?;
    shell.run(&core, keep_batch(steps[1].id.clone()))?;
    let kept = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert!(!suwop_core::immich_live_writes::original_continuation_open(
        &kept, OP
    ));
    let before = shell.base.disk.clone();
    shell.run(
        &core,
        explicit(
            vec![
                key(),
                AssetKey {
                    asset_id: SECOND_PARENT.into(),
                    ..key()
                },
            ],
            targets(&[
                (ASSET, Placement::Locked),
                (SECOND_PARENT, Placement::Archive),
                (MOTION, Placement::Timeline),
            ]),
            Some(OP.into()),
            vec![steps[1].id.clone()],
        ),
    )?;
    assert_eq!(shell.base.disk, before);
    assert!(shell.puts.is_empty());
    shell.run(
        &core,
        explicit(
            vec![
                key(),
                AssetKey {
                    asset_id: SECOND_PARENT.into(),
                    ..key()
                },
            ],
            targets(&[
                (ASSET, Placement::Locked),
                (SECOND_PARENT, Placement::Archive),
                (MOTION, Placement::Timeline),
            ]),
            Some(OP.into()),
            vec![steps[2].id.clone()],
        ),
    )?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(after.immich_live_operations.len(), 2);
    assert_eq!(after.immich_live_operations[0].steps, steps);
    assert_eq!(after.immich_live_unstarted_closures.len(), 1);
    assert_eq!(shell.puts, vec![MOTION, SECOND_PARENT]);
    assert!(!suwop_core::immich_live_writes::original_continuation_open(
        &after, OP
    ));
    Ok(())
}
#[test]
fn partial_keep_allows_second_explicit_keep_and_rejects_duplicate_target() -> Result<(), String> {
    let (core, mut shell, steps) = paused_shared()?;
    shell.run(&core, keep_batch(steps[1].id.clone()))?;
    let second = Event::KeepImmichLivePlacement {
        batch_id: OP.into(),
        closure_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc".into(),
        step_ids: vec![steps[2].id.clone()],
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    };
    shell.run(&core, second)?;
    let after = suwop_core::workflow::migrate(shell.base.disk.clone().ok_or("disk")?)?;
    assert_eq!(
        after.immich_live_unstarted_closures.len(),
        2,
        "status={} error={:?}",
        core.view().status,
        core.view().error
    );
    assert_eq!(after.immich_live_operations[0].steps, steps);
    assert!(shell.puts.is_empty());
    let before = shell.base.disk.clone();
    shell.run(&core, keep_batch(steps[1].id.clone()))?;
    assert_eq!(shell.base.disk, before);
    Ok(())
}
#[test]
fn unknown_predecessor_and_active_runtime_cannot_start_new_intent_or_keep_unknown()
-> Result<(), String> {
    use suwop_core::immich_live_writes::Placement;
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.lose_response_at = Some(1);
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    let before = shell.base.disk.clone();
    let state = suwop_core::workflow::migrate(before.clone().ok_or("disk")?)?;
    shell.run(
        &core,
        explicit(
            vec![key()],
            targets(&[(ASSET, Placement::Archive), (MOTION, Placement::Hidden)]),
            Some(OP.into()),
            vec![state.immich_live_operations[0].steps[1].id.clone()],
        ),
    )?;
    shell.run(
        &core,
        keep_batch(state.immich_live_operations[0].steps[0].id.clone()),
    )?;
    assert_eq!(shell.base.disk, before);
    assert_eq!(shell.puts, vec![ASSET]);
    let (core, _) = opened(false)?;
    let outstanding = core.process_event(placement(OP, LivePlacementDestination::Locked));
    assert!(!outstanding.is_empty());
    assert!(
        core.process_event(keep_batch("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into()))
            .is_empty()
    );
    assert!(
        core.process_event(explicit(
            vec![key()],
            targets(&[(ASSET, Placement::Archive), (MOTION, Placement::Hidden)]),
            None,
            vec![]
        ))
        .is_empty()
    );
    Ok(())
}

#[test]
fn failed_capture_cleanup_is_reachable_after_scene_loss_and_never_resumes_writes()
-> Result<(), String> {
    let (core, base) = opened(false)?;
    let mut shell = BatchShell::new(base)?;
    shell.drain_failures = 2;
    shell.run(&core, placement(OP, LivePlacementDestination::Locked))?;
    let cleanup = core
        .view()
        .live_placement_cleanup
        .ok_or("retained termination token")?;
    assert!(cleanup.can_retry);
    assert!(!core.view().busy);
    assert!(shell.puts.is_empty());
    let initial = (
        shell.confirmations,
        shell.captures,
        shell.drains,
        shell.http_count,
        shell.revision,
    );
    shell.run(
        &core,
        Event::RetryImmichLiveCleanup {
            capture_id: format!("{}-foreign", cleanup.capture_id),
        },
    )?;
    assert_eq!(
        initial,
        (
            shell.confirmations,
            shell.captures,
            shell.drains,
            shell.http_count,
            shell.revision
        )
    );
    shell.run(&core, Event::CloseImmichLocked)?;
    assert!(core.view().live_placement_history.batches.is_empty());
    assert_eq!(
        core.view()
            .live_placement_cleanup
            .as_ref()
            .map(|value| &value.capture_id),
        Some(&cleanup.capture_id)
    );
    let http = shell.http_count;
    shell.run(
        &core,
        Event::RetryImmichLiveCleanup {
            capture_id: cleanup.capture_id.clone(),
        },
    )?;
    assert_eq!(
        core.view()
            .live_placement_cleanup
            .as_ref()
            .map(|value| &value.capture_id),
        Some(&cleanup.capture_id)
    );
    assert!(!core.view().busy);
    assert_eq!(shell.http_count, http);
    shell.run(
        &core,
        Event::RetryImmichLiveCleanup {
            capture_id: cleanup.capture_id.clone(),
        },
    )?;
    assert!(core.view().live_placement_cleanup.is_none());
    assert!(!core.view().busy);
    assert_eq!(shell.confirmations, 1);
    assert_eq!(shell.captures, 1);
    assert_eq!(shell.drains, 3);
    assert_eq!(shell.http_count, http);
    assert_eq!(shell.revision, 0);
    assert!(shell.puts.is_empty());
    let settled = shell.drains;
    shell.run(
        &core,
        Event::RetryImmichLiveCleanup {
            capture_id: cleanup.capture_id,
        },
    )?;
    assert_eq!(shell.drains, settled);
    assert!(shell.puts.is_empty());
    Ok(())
}
