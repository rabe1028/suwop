//! Actual Rust event/effect provenance, synthetic transport/native receipts.
//! These tests do not claim `PhotoKit` materialization, native CAS or visible pixels.
use super::*;
use suwop_core::immich_locked::live::{ImmichLockedLivePublication, ImmichLockedLiveRole};
const MOTION: &str = "66666666-6666-4666-8666-666666666666";
const PAIR: &str = "77777777-7777-4777-8777-777777777777";
const PREPARED: &str = "88888888-8888-4888-8888-888888888888";
#[derive(Default)]
struct Drift {
    after_read: bool,
    after_publish: bool,
    active: bool,
}
#[derive(Default)]
struct NativeFaults {
    release: bool,
    completion_lease: bool,
    barrier: bool,
}
struct PairedShell {
    base: Shell,
    reads: Vec<String>,
    original_roles: Vec<ImmichLockedLiveRole>,
    prepares: usize,
    publications: usize,
    releases: usize,
    renewals: usize,
    drift: Drift,
    native_faults: NativeFaults,
    short_status_remaining: usize,
    motion_visibility: &'static str,
    bad_forward: bool,
    malformed_size: bool,
    inspections: usize,
    archive_confirmations: usize,
    ordinary_mutations: usize,
    live_barriers: Vec<AssetKey>,
}
impl PairedShell {
    fn new(base: Shell) -> Self {
        Self {
            base,
            reads: vec![],
            original_roles: vec![],
            prepares: 0,
            publications: 0,
            releases: 0,
            renewals: 0,
            drift: Drift::default(),
            native_faults: NativeFaults::default(),
            short_status_remaining: 0,
            motion_visibility: "hidden",
            bad_forward: false,
            malformed_size: false,
            inspections: 0,
            archive_confirmations: 0,
            ordinary_mutations: 0,
            live_barriers: vec![],
        }
    }
    fn metadata(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(r)
                if r.url.ends_with("/auth/status") && self.short_status_remaining > 0 =>
            {
                self.short_status_remaining -= 1;
                let mut response = self.base.respond(op)?;
                let seconds = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "clock")?
                    .as_secs()
                    .checked_add(15)
                    .ok_or("time overflow")?;
                let expires = chrono::DateTime::from_timestamp(
                    i64::try_from(seconds).map_err(|_| "time representation")?,
                    0,
                )
                .ok_or("time")?
                .to_rfc3339();
                response["body"]["pinExpiresAt"] = json!(expires);
                Ok(response)
            }
            ShellOperation::Http(r)
                if r.url.ends_with(&format!("/assets/{ASSET}"))
                    || r.url.ends_with(&format!("/assets/{MOTION}")) =>
            {
                assert_eq!(r.method, "GET");
                if r.headers.contains_key("x-api-key") {
                    assert!(r.url.ends_with(MOTION));
                    assert_eq!(
                        r.headers.get("x-api-key").map(String::as_str),
                        Some("ordinary-api-secret")
                    );
                    assert!(!r.headers.contains_key("Authorization"));
                    self.base.ordinary_reads += 1;
                } else {
                    assert_eq!(
                        r.headers.get("Authorization").map(String::as_str),
                        Some("Bearer dedicated-token-secret")
                    );
                }
                let motion = r.url.ends_with(MOTION);
                let mut raw = asset();
                raw["id"] = json!(if motion { MOTION } else { ASSET });
                raw["type"] = json!(if motion { "VIDEO" } else { "IMAGE" });
                if motion {
                    raw["originalFileName"] = json!("PRIVATE-MOTION.mov");
                }
                raw["visibility"] = json!(if motion {
                    self.motion_visibility
                } else {
                    "locked"
                });
                raw["livePhotoVideoId"] = if motion { Value::Null } else { json!(MOTION) };
                raw["exifInfo"] = json!({"fileSizeInByte":if motion{32}else{16}});
                if self.bad_forward && !motion {
                    raw["livePhotoVideoId"] = json!(OP);
                }
                if self.malformed_size {
                    raw["exifInfo"] = json!({"fileSizeInByte":"16"});
                }
                if self.drift.active {
                    raw["updatedAt"] = json!("different-revision");
                }
                self.reads
                    .push(if motion { MOTION.into() } else { ASSET.into() });
                Ok(json!({"status":200,"body":raw}))
            }
            ShellOperation::Http(r) if r.url.ends_with("/search/metadata") => {
                Ok(json!({"status":200,"body":{"assets":{"items":[],"nextCursor":null}}}))
            }
            _ => Err("unexpected metadata fixture route".into()),
        }
    }
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        if let ShellOperation::Http(r) = op {
            if r.method == "PUT" {
                return self.ordinary_write(r);
            }
            if (r.url.ends_with("/auth/status") && self.short_status_remaining > 0)
                || r.url.ends_with(&format!("/assets/{ASSET}"))
                || r.url.ends_with(&format!("/assets/{MOTION}"))
                || r.url.ends_with("/search/metadata")
            {
                return self.metadata(op);
            }
        }
        match op {
            ShellOperation::ConfirmImmichArchive { prompt } => {
                assert_eq!(
                    prompt.from,
                    suwop_core::immich_archive::ImmichArchiveDestination::Timeline
                );
                assert_eq!(
                    prompt.to,
                    suwop_core::immich_archive::ImmichArchiveDestination::Archive
                );
                self.archive_confirmations += 1;
                Ok(json!(true))
            }
            ShellOperation::QuiesceImmichLockedLive { key, .. } => {
                self.live_barriers.push(key.clone());
                if self.native_faults.barrier {
                    Err("unconfirmed shared motion JOIN".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::InspectImmichLockedLiveStorage {
                pending,
                quote_deadline_unix_milliseconds,
            } => {
                self.inspections += 1;
                assert_eq!(pending.parent_key, key());
                assert_eq!(pending.motion_key.asset_id, MOTION);
                Ok(
                    json!({"storage":{"leaseID":PAIR,"measurementNonce":OP,"deadlineUnixMilliseconds":quote_deadline_unix_milliseconds,"availableBytes":1_073_741_824_u64,"otherUnallocatedBytes":0,"allocationUnitBytes":4096,"capacityClass":"available"},"representations":[]}),
                )
            }
            ShellOperation::ReadImmichLockedLiveMember { read } => {
                Ok(self.read_original(read.as_ref()))
            }
            ShellOperation::PrepareImmichLockedLive { ticket, originals } => {
                self.prepares += 1;
                assert_eq!(originals[0].role, ImmichLockedLiveRole::Parent);
                assert_eq!(originals[1].role, ImmichLockedLiveRole::Motion);
                Ok(
                    json!({"requestID":ticket.pending.request_id,"pairLeaseID":PAIR,"acquisitionLeaseID":ticket.acquisition_lease.lease_id,"preparedID":PREPARED}),
                )
            }
            ShellOperation::PublishImmichLockedLive { publication, .. } => {
                self.publications += 1;
                self.drift.active |= self.drift.after_publish;
                serde_json::to_value(publication).map_err(|_| "publication encode".into())
            }
            ShellOperation::RenewImmichLockedLiveAcquisition {
                ticket,
                previous_lease_id,
                lease,
            } => {
                self.renewals += 1;
                Ok(
                    json!({"requestID":ticket.pending.request_id,"pairLeaseID":PAIR,"previousLeaseID":previous_lease_id,"leaseID":lease.lease_id}),
                )
            }
            ShellOperation::ReleaseImmichLockedLive {
                pending,
                pair_lease_id,
            } => {
                self.releases += 1;
                if self.native_faults.release {
                    Err("unconfirmed native JOIN".into())
                } else {
                    Ok(json!({"pending":pending,"pairLeaseID":pair_lease_id}))
                }
            }
            ShellOperation::ReleaseImmichLockedLives { .. }
            | ShellOperation::ScheduleImmichLockedLiveAcquisitionExpiry { .. } => Ok(Value::Null),
            _ => self.base.respond(op),
        }
    }
    fn read_original(
        &mut self,
        read: &suwop_core::immich_locked::live::ImmichLockedLiveRead,
    ) -> Value {
        let i = usize::from(read.role == ImmichLockedLiveRole::Motion);
        let m = &read.ticket.members[i];
        assert_eq!(read.request.method, "GET");
        assert_eq!(
            read.request.url,
            format!(
                "https://fixture.example/api/assets/{}/original?edited=false",
                m.key.asset_id
            )
        );
        assert_eq!(
            read.request
                .headers
                .get("Accept-Encoding")
                .map(String::as_str),
            Some("identity")
        );
        assert!(!read.request.headers.contains_key("x-api-key"));
        assert!(read.request.ordinary_content_authorization.is_none());
        self.original_roles.push(read.role);
        self.drift.active |= self.drift.after_read;
        json!({"requestID":read.ticket.pending.request_id,"pairLeaseID":PAIR,"role":read.role,"acquisitionLeaseID":if self.native_faults.completion_lease{0}else{read.ticket.acquisition_lease.lease_id},"sha1":m.expected_sha1,"signature":{"sha256":"c".repeat(64),"bytes":if i==0{16}else{32}}})
    }
    fn ordinary_write(&mut self, r: &suwop_core::immich::HttpRequest) -> Result<Value, String> {
        assert_eq!(
            r.url,
            format!("https://fixture.example/api/assets/{MOTION}")
        );
        assert_eq!(
            r.headers.get("x-api-key").map(String::as_str),
            Some("ordinary-api-secret")
        );
        assert!(!r.headers.contains_key("Authorization"));
        assert!(r.immich_visibility_authorization.is_none());
        let permit = r
            .immich_archive_authorization
            .as_ref()
            .ok_or("ordinary permit")?;
        assert_eq!(permit.key.asset_id, MOTION);
        assert_eq!(permit.url, r.url);
        assert_eq!(r.body, Some(json!({"visibility":"archive"})));
        assert_eq!(
            self.base.disk.as_ref().ok_or("intent before write")?["immichVisibilityOperations"][0]
                ["outcome"],
            "unknown"
        );
        self.ordinary_mutations += 1;
        self.motion_visibility = "archive";
        Ok(json!({"status":200,"body":{"id":MOTION,"visibility":"archive"}}))
    }
    fn resolve(&mut self, c: &Core<Suwop>, effect: Effect) -> Result<Vec<Effect>, String> {
        let Effect::Io(mut r) = effect;
        let answer = self.respond(&r.operation);
        c.resolve(
            &mut r,
            ShellResponse {
                value: answer.as_ref().ok().cloned(),
                error: answer.err(),
            },
        )
        .map_err(|_| "resolve paired".into())
    }
    fn drain(&mut self, c: &Core<Suwop>, effects: Vec<Effect>) -> Result<(), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        while let Some(e) = queue.pop_front() {
            queue.extend(self.resolve(c, e)?);
        }
        Ok(())
    }
    fn hold(
        &mut self,
        c: &Core<Suwop>,
        effects: Vec<Effect>,
        predicate: impl Fn(&ShellOperation) -> bool,
    ) -> Result<(Effect, Vec<Effect>), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        while let Some(e) = queue.pop_front() {
            let Effect::Io(r) = &e;
            if predicate(&r.operation) {
                return Ok((e, queue.into()));
            }
            queue.extend(self.resolve(c, e)?);
        }
        Err("expected held effect".into())
    }
    fn hold_barrier(
        &mut self,
        c: &Core<Suwop>,
        effects: Vec<Effect>,
    ) -> Result<(Effect, Vec<Effect>, Vec<Effect>), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        let mut cleanup = vec![];
        while let Some(effect) = queue.pop_front() {
            let Effect::Io(request) = &effect;
            match &request.operation {
                ShellOperation::ReleaseImmichLockedLive { .. } => cleanup.push(effect),
                ShellOperation::QuiesceImmichLockedLive { .. } => {
                    return Ok((effect, queue.into(), cleanup));
                }
                _ => queue.extend(self.resolve(c, effect)?),
            }
        }
        Err("expected exact-key barrier".into())
    }
    fn assert_read_only(&self) {
        assert_eq!(self.base.persist_calls, 0);
        assert_eq!(self.base.writes, 0);
        assert_eq!(self.base.ordinary_reads, 0);
        assert_eq!(self.base.confirmations, 0);
        assert!(
            self.reads
                .iter()
                .all(|id| [ASSET, MOTION].contains(&id.as_str()))
        );
    }
}
fn setup() -> Result<(Core<Suwop>, PairedShell, String), String> {
    setup_placement("hidden")
}
fn setup_placement(placement: &'static str) -> Result<(Core<Suwop>, PairedShell, String), String> {
    let (c, base) = opened(false)?;
    let mut s = PairedShell::new(base);
    s.motion_visibility = placement;
    s.drain(
        &c,
        c.process_event(Event::InspectImmichLiveResources {
            parent_key: key(),
            request_id: OP.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        }),
    )?;
    let plan = c
        .view()
        .immich_live_resources
        .and_then(|v| v.plan)
        .ok_or("metadata plan")?
        .plan_id;
    Ok((c, s, plan))
}
fn request(plan: String, id: &str) -> Event {
    Event::RequestImmichLockedLive {
        plan_id: plan,
        request_id: id.into(),
        scene_id: SCENE.into(),
        grant_id: GRANT.into(),
    }
}
fn stop(id: &str) -> Event {
    Event::StopImmichLockedLive {
        scene_id: SCENE.into(),
        request_id: id.into(),
    }
}
#[test]
fn paired_read_materializes_both_roles_then_rechecks_before_access_without_writes()
-> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    s.drain(&c, c.process_event(request(plan, NEXT)))?;
    let access = c.view().immich_locked_view.live.ok_or("pair access")?;
    assert_eq!(access.pair_lease_id, PAIR);
    assert_eq!(access.prepared_id, PREPARED);
    assert_eq!(
        s.original_roles,
        [ImmichLockedLiveRole::Parent, ImmichLockedLiveRole::Motion]
    );
    assert_eq!(s.prepares, 1);
    assert_eq!(s.publications, 1);
    assert!(s.reads.len() >= 18);
    s.assert_read_only();
    s.drain(&c, c.process_event(stop(NEXT)))?;
    assert!(c.view().immich_locked_view.live.is_none());
    assert_eq!(s.releases, 1);
    Ok(())
}
#[test]
fn native_handoff_receipt_alone_never_publishes_and_postpublication_drift_releases()
-> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    let (held, rest) = s.hold(&c, c.process_event(request(plan, NEXT)), |op| {
        matches!(op, ShellOperation::PublishImmichLockedLive { .. })
    })?;
    assert!(c.view().immich_locked_view.live.is_none());
    s.drift.after_publish = true;
    let mut next = s.resolve(&c, held)?;
    next.extend(rest);
    s.drain(&c, next)?;
    assert!(c.view().immich_locked_view.live.is_none());
    assert_eq!(s.publications, 1);
    assert_eq!(s.releases, 1);
    s.assert_read_only();
    Ok(())
}
#[test]
fn paired_postread_drift_or_wrong_actual_completion_lease_refuses_prepare() -> Result<(), String> {
    for wrong in [false, true] {
        let (c, mut s, plan) = setup()?;
        s.drift.after_read = !wrong;
        s.native_faults.completion_lease = wrong;
        s.drain(&c, c.process_event(request(plan, NEXT)))?;
        assert!(c.view().immich_locked_view.live.is_none());
        assert_eq!(s.original_roles.len(), 1);
        assert_eq!(s.prepares, 0);
        assert_eq!(s.releases, 1);
        s.assert_read_only();
    }
    Ok(())
}
#[test]
fn stopped_preinspect_callback_cannot_start_original_or_resurrect_projection() -> Result<(), String>
{
    let (c, mut s, plan) = setup()?;
    let held = c.process_event(request(plan, NEXT));
    s.drain(&c, c.process_event(stop(NEXT)))?;
    s.drain(&c, held)?;
    assert!(s.original_roles.is_empty());
    assert!(c.view().immich_locked_view.live.is_none());
    s.assert_read_only();
    Ok(())
}
#[test]
fn failed_join_blocks_latest_request_until_exact_retry_ack() -> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    s.drain(&c, c.process_event(request(plan.clone(), NEXT)))?;
    s.native_faults.release = true;
    s.drain(&c, c.process_event(request(plan, PREPARED)))?;
    assert_eq!(s.original_roles.len(), 2);
    assert!(c.view().immich_locked_view.live.is_none());
    s.native_faults.release = false;
    s.drain(&c, c.process_event(stop(NEXT)))?;
    assert_eq!(s.original_roles.len(), 4);
    assert_eq!(
        c.view()
            .immich_locked_view
            .live
            .ok_or("replacement")?
            .pending
            .request_id,
        PREPARED
    );
    s.assert_read_only();
    Ok(())
}
#[test]
fn completion_under_old_actual_lease_is_held_across_single_pair_renewal() -> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    // Real status timestamps give the initial pair a shorter absolute bound.
    // The next checked status extends it deterministically, without a wall sleep.
    s.short_status_remaining = 2;
    let (held, rest) = s.hold(&c, c.process_event(request(plan, NEXT)), |op| {
        matches!(op, ShellOperation::ReadImmichLockedLiveMember { .. })
    })?;
    let v = c.view().immich_locked_view;
    s.drain(
        &c,
        c.process_event(Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: v.generation,
            lease_id: v.lease_id,
        }),
    )?;
    assert_eq!(s.renewals, 1);
    let mut next = s.resolve(&c, held)?;
    next.extend(rest);
    s.drain(&c, next)?;
    assert!(c.view().immich_locked_view.live.is_some());
    assert_eq!(s.original_roles.len(), 2);
    s.assert_read_only();
    Ok(())
}
#[test]
fn published_access_ignores_old_acquisition_timer_but_scene_revoke_still_releases()
-> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    s.drain(&c, c.process_event(request(plan, NEXT)))?;
    let access: ImmichLockedLivePublication = c.view().immich_locked_view.live.ok_or("access")?;
    s.drain(
        &c,
        c.process_event(Event::ExpireImmichLockedLiveAcquisition {
            request_id: NEXT.into(),
            scene_id: SCENE.into(),
            generation: access.pending.generation,
            lease_id: 1,
        }),
    )?;
    assert!(c.view().immich_locked_view.live.is_some());
    s.drain(
        &c,
        c.process_event(Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Inactive,
        }),
    )?;
    assert!(c.view().immich_locked_view.live.is_none());
    assert!(s.releases > 0);
    s.assert_read_only();
    Ok(())
}

#[test]
fn paired_motion_placements_are_observed_bindings_not_inferred_hidden_state() -> Result<(), String>
{
    for placement in ["timeline", "archive", "hidden", "locked"] {
        let (c, mut s, plan) = setup_placement(placement)?;
        s.drain(&c, c.process_event(request(plan, NEXT)))?;
        assert!(c.view().immich_locked_view.live.is_some());
        assert_eq!(s.original_roles.len(), 2);
        s.assert_read_only();
    }
    Ok(())
}
#[test]
fn changed_forward_or_malformed_present_size_is_refused_before_native_storage() -> Result<(), String>
{
    for malformed in [false, true] {
        let (c, mut s, plan) = setup()?;
        s.malformed_size = malformed;
        s.bad_forward = !malformed;
        s.drain(&c, c.process_event(request(plan, NEXT)))?;
        assert_eq!(s.inspections, 0);
        assert!(s.original_roles.is_empty());
        assert!(c.view().immich_locked_view.live.is_none());
        assert_eq!(s.releases, 1);
        s.assert_read_only();
    }
    Ok(())
}

#[test]
fn c2_always_requires_pair_barrier_even_without_a_pending_pair_and_failure_starts_no_intent()
-> Result<(), String> {
    let (c, mut shell) = opened(false)?;
    shell.live_quiescence_failure = Some("unconfirmed pair JOIN".into());
    shell.run(
        &c,
        prepare(OP, suwop_core::immich_visibility::ImmichVisibility::Locked),
    )?;
    assert_eq!(shell.confirmations, 1);
    assert_eq!(shell.quiescences, [key()]);
    assert_eq!(shell.live_quiescences, [key()]);
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.writes, 0);
    assert!(
        c.view()
            .immich_visibility_view
            .history
            .unwrap_or_default()
            .is_empty()
    );
    Ok(())
}

#[test]
fn delayed_original_from_retired_a_cannot_replace_or_release_new_b_access() -> Result<(), String> {
    let (c, mut s, plan) = setup()?;
    let (held, rest) = s.hold(&c, c.process_event(request(plan.clone(), NEXT)), |op| {
        matches!(op, ShellOperation::ReadImmichLockedLiveMember { .. })
    })?;
    s.drain(&c, c.process_event(stop(NEXT)))?;
    s.drain(&c, c.process_event(request(plan, PREPARED)))?;
    let before = c.view().immich_locked_view.live.ok_or("new B access")?;
    let mut late = s.resolve(&c, held)?;
    late.extend(rest);
    s.drain(&c, late)?;
    assert_eq!(c.view().immich_locked_view.live, Some(before));
    assert_eq!(s.releases, 1);
    s.assert_read_only();
    Ok(())
}

fn ordinary_motion_setup() -> Result<(Core<Suwop>, PairedShell, String), String> {
    let mut model = model_denials(false, vec![], std::collections::BTreeSet::new());
    let mut raw = asset();
    raw["id"] = json!(MOTION);
    raw["type"] = json!("VIDEO");
    raw["originalFileName"] = json!("PRIVATE-MOTION.mov");
    let parsed: suwop_core::immich::Asset =
        serde_json::from_value(raw).map_err(|_| "motion catalog")?;
    model
        .state
        .snapshots
        .push(suwop_core::domain::LibrarySnapshot {
            provider: Provider::Immich,
            scope: key().scope.clone(),
            access: suwop_core::domain::ScanAccess::Full,
            scanned_at: Some(1.0),
            assets: vec![parsed.record(&key().scope, None, None)],
        });
    let c = Core::new_with(Suwop, model);
    let mut base = Shell {
        confirmed: true,
        ..Shell::default()
    };
    base.run(&c, open(GRANT))?;
    let mut s = PairedShell::new(base);
    s.motion_visibility = "timeline";
    s.drain(
        &c,
        c.process_event(Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        }),
    )?;
    assert!(
        c.view()
            .immich_archive_actions
            .iter()
            .any(|a| a.key.asset_id == MOTION
                && a.reason.is_none()
                && a.to == Some(suwop_core::immich_archive::ImmichArchiveDestination::Archive))
    );
    s.drain(
        &c,
        c.process_event(Event::InspectImmichLiveResources {
            parent_key: key(),
            request_id: OP.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        }),
    )?;
    let plan = c
        .view()
        .immich_live_resources
        .and_then(|v| v.plan)
        .ok_or("ordinary M pair plan")?
        .plan_id;
    Ok((c, s, plan))
}
#[derive(Clone, Copy)]
enum PairConsumerState {
    Published,
    Prequote,
    Retired,
    None,
}
fn prepare_consumer_state(
    c: &Core<Suwop>,
    s: &mut PairedShell,
    plan: String,
    state: PairConsumerState,
) -> Result<Vec<Effect>, String> {
    match state {
        PairConsumerState::Published => {
            s.drain(c, c.process_event(request(plan, NEXT)))?;
            assert!(c.view().immich_locked_view.live.is_some());
            Ok(vec![])
        }
        PairConsumerState::Prequote => {
            let (held, rest) = s.hold(c, c.process_event(request(plan, NEXT)), |op| {
                matches!(op, ShellOperation::InspectImmichLockedLiveStorage { .. })
            })?;
            assert!(s.original_roles.is_empty());
            let mut deferred = vec![held];
            deferred.extend(rest);
            Ok(deferred)
        }
        PairConsumerState::Retired => {
            let (read, rest) = s.hold(c, c.process_event(request(plan, NEXT)), |op| {
                matches!(op, ShellOperation::ReadImmichLockedLiveMember { .. })
            })?;
            let (release, remaining) = s.hold(c, c.process_event(stop(NEXT)), |op| {
                matches!(op, ShellOperation::ReleaseImmichLockedLive { .. })
            })?;
            assert!(c.view().immich_locked_view.live_pending.is_none());
            let mut deferred = vec![read];
            deferred.extend(rest);
            deferred.push(release);
            deferred.extend(remaining);
            Ok(deferred)
        }
        PairConsumerState::None => Ok(vec![]),
    }
}
fn prepare_motion_archive() -> Event {
    Event::PrepareImmichArchive {
        key: AssetKey {
            asset_id: MOTION.into(),
            ..key()
        },
        to: suwop_core::immich_archive::ImmichArchiveDestination::Archive,
        operation_id: "99999999-9999-4999-8999-999999999999".into(),
        scene_id: SCENE.into(),
    }
}
#[test]
fn ordinary_shared_motion_requires_live_join_before_intent_for_active_prequote_retired_and_missing_owner()
-> Result<(), String> {
    for state in [
        PairConsumerState::Published,
        PairConsumerState::Prequote,
        PairConsumerState::Retired,
        PairConsumerState::None,
    ] {
        for failed in [false, true] {
            let (c, mut s, plan) = ordinary_motion_setup()?;
            let mut deferred = prepare_consumer_state(&c, &mut s, plan, state)?;
            let auth_before = s
                .base
                .paths
                .iter()
                .filter(|p| ["auth/login", "auth/session/unlock"].contains(&p.as_str()))
                .count();
            let (held, rest, cleanup) =
                s.hold_barrier(&c, c.process_event(prepare_motion_archive()))?;
            deferred.extend(cleanup);
            let Effect::Io(io) = &held;
            let ShellOperation::QuiesceImmichLockedLive {
                key: target,
                pending,
            } = &io.operation
            else {
                return Err("expected live barrier".into());
            };
            assert_eq!(target.asset_id, MOTION);
            assert_eq!(
                pending.is_some(),
                matches!(
                    state,
                    PairConsumerState::Published | PairConsumerState::Prequote
                )
            );
            if let Some(p) = pending {
                assert_eq!(p.parent_key.asset_id, ASSET);
                assert_eq!(p.motion_key.asset_id, MOTION);
            }
            assert_eq!(s.archive_confirmations, 1);
            assert_eq!(s.base.confirmations, 0);
            assert_eq!(s.base.persist_calls, 0);
            assert_eq!(s.ordinary_mutations, 0);
            assert!(
                s.base.quiescences.is_empty(),
                "ordinary path retains existing VIDEO policy"
            );
            assert!(c.view().immich_locked_view.live.is_none());
            // Simulated native callbacks/cleanup finish while the all-consumer
            // JOIN response is still held. No permission is inferred from them.
            s.drain(&c, deferred)?;
            assert_eq!(s.base.persist_calls, 0);
            assert_eq!(s.ordinary_mutations, 0);
            s.native_faults.barrier = failed;
            let mut after = s.resolve(&c, held)?;
            after.extend(rest);
            s.drain(&c, after)?;
            assert_eq!(s.live_barriers.len(), 1);
            assert_eq!(s.ordinary_mutations, usize::from(!failed));
            assert_eq!(s.base.writes, 0);
            assert_eq!(
                s.base
                    .paths
                    .iter()
                    .filter(|p| ["auth/login", "auth/session/unlock"].contains(&p.as_str()))
                    .count(),
                auth_before
            );
            if failed {
                assert_eq!(s.base.persist_calls, 0);
                assert!(
                    c.view()
                        .immich_archive_view
                        .history
                        .unwrap_or_default()
                        .is_empty()
                );
            } else {
                let disk = s.base.disk.as_ref().ok_or("ordinary journal")?;
                assert_eq!(
                    disk["immichVisibilityOperations"][0]["kind"],
                    "ordinaryArchive"
                );
                assert_eq!(
                    disk["immichVisibilityOperations"][0]["key"]["assetID"],
                    MOTION
                );
                assert_eq!(disk["immichVisibilityOperations"][0]["outcome"], "applied");
            }
        }
    }
    Ok(())
}

#[test]
fn selected_motion_capture_precedes_live_projection_revocation_and_all_release_effects()
-> Result<(), String> {
    for state in [PairConsumerState::Published, PairConsumerState::Prequote] {
        let (c, mut s, plan) = ordinary_motion_setup()?;
        let deferred = prepare_consumer_state(&c, &mut s, plan, state)?;
        let before = c.view();
        let effects = c.process_event(prepare_motion_archive());
        assert_eq!(
            effects.len(),
            1,
            "No cleanup or HTTP may precede native all-owner capture"
        );
        let after = c.view();
        assert_eq!(
            before.private_content_revision,
            after.private_content_revision
        );
        assert_eq!(
            serde_json::to_value(&before.immich_locked_view.live).map_err(|_| "view")?,
            serde_json::to_value(&after.immich_locked_view.live).map_err(|_| "view")?
        );
        assert_eq!(
            serde_json::to_value(&before.immich_locked_view.live_pending).map_err(|_| "view")?,
            serde_json::to_value(&after.immich_locked_view.live_pending).map_err(|_| "view")?
        );
        assert_eq!(
            before.immich_archive_view.scene_id,
            after.immich_archive_view.scene_id
        );
        assert_eq!(
            before.immich_archive_view.generation,
            after.immich_archive_view.generation
        );
        let effect = effects.into_iter().next().ok_or("capture")?;
        let Effect::Io(io) = &effect;
        let ShellOperation::CapturePrivateMediaKey { key } = &io.operation else {
            return Err("capture first".into());
        };
        assert_eq!(key.asset_id, MOTION);
        assert_eq!(
            (s.releases, s.archive_confirmations, s.ordinary_mutations),
            (0, 0, 0)
        );
        let next = s.resolve(&c, effect)?;
        s.drain(&c, next)?;
        s.drain(&c, deferred)?;
        assert_eq!(s.ordinary_mutations, 1);
        assert_eq!(s.live_barriers.len(), 1);
    }
    Ok(())
}
