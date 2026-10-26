use super::*;
const MOTION: &str = "66666666-6666-4666-8666-666666666666";
fn inspect(id: &str) -> Event {
    Event::InspectImmichLiveResources {
        parent_key: key(),
        request_id: id.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
struct LiveShell {
    base: Shell,
    motion: Value,
    pages: std::collections::VecDeque<Value>,
    parent_reads: usize,
    motion_reads: usize,
    drift: bool,
}
impl LiveShell {
    fn new(base: Shell) -> Self {
        let mut motion = asset();
        motion["id"] = json!(MOTION);
        motion["type"] = json!("VIDEO");
        motion["visibility"] = json!("hidden");
        Self {
            base,
            motion,
            pages: std::collections::VecDeque::new(),
            parent_reads: 0,
            motion_reads: 0,
            drift: false,
        }
    }
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        if let ShellOperation::Http(r) = op {
            assert_ne!(r.method, "PUT");
            assert!(!r.url.contains("/original"));
            if r.url.ends_with(&format!("/assets/{ASSET}")) {
                self.parent_reads += 1;
                let mut p = asset();
                p["livePhotoVideoId"] = json!(MOTION);
                if self.drift && self.parent_reads > 1 {
                    p["updatedAt"] = json!("changed");
                }
                return Ok(json!({"status":200,"body":p}));
            }
            if r.url.ends_with(&format!("/assets/{MOTION}")) {
                self.motion_reads += 1;
                return Ok(json!({"status":200,"body":self.motion}));
            }
            if r.url.ends_with("/search/metadata") {
                return Ok(
                    json!({"status":200,"body":self.pages.pop_front().unwrap_or_else(||json!({"assets":{"items":[],"nextCursor":null}}))}),
                );
            }
        }
        self.base.respond(op)
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut r) = effects.remove(0);
            let value = self.respond(&r.operation)?;
            effects.extend(
                c.resolve(
                    &mut r,
                    ShellResponse {
                        value: Some(value),
                        error: None,
                    },
                )
                .map_err(|_| "live resolve")?,
            );
        }
        Ok(())
    }
}
#[test]
fn live_plan_reads_exact_pair_and_keeps_shared_unavailable_parents_informational()
-> Result<(), String> {
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    let mut p2 = asset();
    p2["id"] = json!(NEXT);
    p2["livePhotoVideoId"] = json!(MOTION);
    p2["visibility"] = json!("locked");
    p2["stack"] = json!({"id":OP});
    p2["isOffline"] = json!(true);
    let mut bad = p2.clone();
    bad["id"] = json!("malformed");
    s.pages
        .push_back(json!({"assets":{"items":[bad,p2],"nextCursor":null}}));
    s.drain(&c, c.process_event(inspect(OP)))?;
    let plan = c
        .view()
        .immich_live_resources
        .ok_or("view")?
        .plan
        .ok_or("plan")?;
    assert_eq!(plan.read_targets.len(), 2);
    assert_eq!(plan.read_targets[1].key.asset_id, MOTION);
    assert!(!plan.additional_parents.graph_complete);
    assert_eq!(plan.additional_parents.malformed_candidates, 1);
    assert_eq!(plan.additional_parents.parents.len(), 1);
    assert_eq!(plan.additional_parents.parents[0].has_stack, Some(true));
    assert_eq!(plan.additional_parents.parents[0].is_offline, Some(true));
    assert!(s.base.persist_calls == 0);
    Ok(())
}
#[test]
fn live_plan_rejects_post_discovery_revision_or_wrong_motion_owner() -> Result<(), String> {
    for drift in [false, true] {
        let (c, base) = opened(false)?;
        let mut s = LiveShell::new(base);
        s.drift = drift;
        if !drift {
            s.motion["ownerId"] = json!(NEXT);
        }
        s.drain(&c, c.process_event(inspect(OP)))?;
        let view = c.view().immich_live_resources.ok_or("view")?;
        assert!(view.plan.is_none());
        assert!(view.error.is_some());
    }
    Ok(())
}
#[test]
fn old_live_request_cannot_clear_replacement_pending_or_publish_after_close() -> Result<(), String>
{
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    let old = c.process_event(inspect(OP));
    let newer = c.process_event(inspect(NEXT));
    s.drain(&c, old)?;
    let view = c.view().immich_live_resources.ok_or("view")?;
    assert!(view.pending);
    assert_eq!(view.request_id, NEXT);
    s.drain(&c, newer)?;
    assert!(c.view().immich_live_resources.ok_or("view")?.plan.is_some());
    s.base.run(&c, Event::CloseImmichLocked)?;
    assert!(c.view().immich_live_resources.is_none());
    Ok(())
}

#[test]
fn bounded_cursor_traversal_never_claims_reverse_graph_closure() -> Result<(), String> {
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    for page in 0..8 {
        s.pages
            .push_back(json!({"assets":{"items":[],"nextCursor":format!("opaque-{page}")}}));
    }
    s.drain(&c, c.process_event(inspect(OP)))?;
    let plan = c
        .view()
        .immich_live_resources
        .ok_or("view")?
        .plan
        .ok_or("plan")?;
    assert_eq!(plan.additional_parents.pages_observed, 8);
    assert_eq!(
        plan.additional_parents.termination,
        suwop_core::immich_live_resources::LiveDiscoveryTermination::PageBudget
    );
    assert!(!plan.additional_parents.graph_complete);
    Ok(())
}
#[test]
fn preexisting_b_denied_parent_emits_no_metadata_effects() -> Result<(), String> {
    let c = core(true);
    let mut shell = Shell {
        confirmed: true,
        ..Shell::default()
    };
    shell.run(&c, open(GRANT))?;
    assert!(c.process_event(inspect(OP)).is_empty());
    assert!(c.view().immich_live_resources.is_none());
    Ok(())
}

#[test]
fn already_denied_motion_is_not_fetched_and_cannot_form_a_plan() -> Result<(), String> {
    let mut motion_key = key();
    motion_key.asset_id = MOTION.into();
    let c = core_denials(false, vec![], [motion_key].into_iter().collect());
    let mut base = Shell {
        confirmed: true,
        ..Shell::default()
    };
    base.run(&c, open(GRANT))?;
    let mut s = LiveShell::new(base);
    s.drain(&c, c.process_event(inspect(OP)))?;
    let view = c.view().immich_live_resources.ok_or("view")?;
    assert!(view.plan.is_none());
    assert!(view.error.is_some());
    assert_eq!(s.parent_reads, 1);
    assert_eq!(s.motion_reads, 0);
    Ok(())
}

#[test]
fn held_live_completion_after_scene_revocation_cannot_republish() -> Result<(), String> {
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    let held = c.process_event(inspect(OP));
    s.base.run(
        &c,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Inactive,
        },
    )?;
    s.drain(&c, held)?;
    assert!(c.view().immich_live_resources.is_none());
    assert_eq!(s.parent_reads, 0);
    assert_eq!(s.motion_reads, 0);
    Ok(())
}
#[test]
fn repeated_cursor_reports_unavailable_without_promoting_absence_to_proof() -> Result<(), String> {
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    for _ in 0..2 {
        s.pages
            .push_back(json!({"assets":{"items":[],"nextCursor":"same"}}));
    }
    s.drain(&c, c.process_event(inspect(OP)))?;
    let plan = c
        .view()
        .immich_live_resources
        .ok_or("view")?
        .plan
        .ok_or("plan")?;
    assert_eq!(plan.additional_parents.pages_observed, 2);
    assert_eq!(
        plan.additional_parents.termination,
        suwop_core::immich_live_resources::LiveDiscoveryTermination::Unavailable
    );
    assert!(!plan.additional_parents.graph_complete);
    Ok(())
}

#[test]
fn held_current_http_response_after_close_cannot_issue_member_reads() -> Result<(), String> {
    let (c, base) = opened(false)?;
    let mut s = LiveShell::new(base);
    let held = c.process_event(inspect(OP));
    assert!(!held.is_empty());
    s.base.run(&c, Event::CloseImmichLocked)?;
    s.drain(&c, held)?;
    assert!(c.view().immich_live_resources.is_none());
    assert_eq!(s.parent_reads, 0);
    assert_eq!(s.motion_reads, 0);
    Ok(())
}

fn reducer_model() -> Model {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "fixture-only".into(),
        user_id: OWNER.into(),
        scope: key().scope,
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    Model {
        state: SavedLibrary {
            schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
            connection: Some(ConnectionSettings {
                address: session.endpoint.clone(),
                allow_http: false,
                credential_id: "fixture-only".into(),
            }),
            ..SavedLibrary::default()
        },
        session: Some(session),
        ready: true,
        ..Model::default()
    }
}
fn resolve_command(
    s: &mut LiveShell,
    mut command: crux_core::Command<Effect, Event>,
) -> Result<Vec<Event>, String> {
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut r) in effects {
            let value = s.respond(&r.operation)?;
            r.resolve(ShellResponse {
                value: Some(value),
                error: None,
            })
            .map_err(|_| "direct reducer effect")?;
        }
    }
    Ok(command.events().collect())
}
fn reducer_open(model: &mut Model, s: &mut LiveShell) -> Result<(), String> {
    use crux_core::App;
    let events = [
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
        open(GRANT),
    ];
    let mut queue: std::collections::VecDeque<_> = events.into();
    while let Some(event) = queue.pop_front() {
        queue.extend(resolve_command(s, Suwop.update(event, model))?);
    }
    Ok(())
}
#[test]
fn current_completion_denied_without_epoch_change_is_terminal_not_reappearing() -> Result<(), String>
{
    use crux_core::App;
    for policy in 0..3 {
        let mut model = reducer_model();
        let mut s = LiveShell::new(Shell {
            confirmed: true,
            ..Shell::default()
        });
        reducer_open(&mut model, &mut s)?;
        let events = resolve_command(&mut s, Suwop.update(inspect(OP), &mut model))?;
        assert_eq!(events.len(), 1);
        let epoch = model
            .ordinary_generation
            .load(std::sync::atomic::Ordering::SeqCst);
        match policy {
            0 => model.protection.membership_uncertain = true,
            1 => model.immich_visibility.persistence_uncertain = true,
            _ => {
                let mut child = key();
                child.asset_id = MOTION.into();
                model.protection.denied.insert(child);
            }
        }
        for event in events {
            let _ = Suwop.update(event, &mut model);
        }
        assert_eq!(
            model
                .ordinary_generation
                .load(std::sync::atomic::Ordering::SeqCst),
            epoch
        );
        model.protection.membership_uncertain = false;
        model.immich_visibility.persistence_uncertain = false;
        model.protection.denied.clear();
        assert!(Suwop.view(&model).immich_live_resources.is_none());
    }
    Ok(())
}

#[test]
fn preexisting_uncertainty_does_not_emit_inspection_http() -> Result<(), String> {
    use crux_core::App;
    for membership in [true, false] {
        let mut model = reducer_model();
        let mut s = LiveShell::new(Shell {
            confirmed: true,
            ..Shell::default()
        });
        reducer_open(&mut model, &mut s)?;
        if membership {
            model.protection.membership_uncertain = true;
        } else {
            model.immich_visibility.persistence_uncertain = true;
        }
        let mut command = Suwop.update(inspect(OP), &mut model);
        assert_eq!(command.effects().count(), 0);
        assert!(Suwop.view(&model).immich_live_resources.is_none());
    }
    Ok(())
}

#[test]
fn protected_discovery_candidate_is_omitted_without_calling_server_data_malformed()
-> Result<(), String> {
    let mut protected = key();
    protected.asset_id = NEXT.into();
    let c = core_denials(false, vec![], [protected].into_iter().collect());
    let mut base = Shell {
        confirmed: true,
        ..Shell::default()
    };
    base.run(&c, open(GRANT))?;
    let mut s = LiveShell::new(base);
    let mut p2 = asset();
    p2["id"] = json!(NEXT);
    p2["livePhotoVideoId"] = json!(MOTION);
    s.pages
        .push_back(json!({"assets":{"items":[p2],"nextCursor":null}}));
    s.drain(&c, c.process_event(inspect(OP)))?;
    let plan = c
        .view()
        .immich_live_resources
        .ok_or("view")?
        .plan
        .ok_or("plan")?;
    assert!(plan.additional_parents.parents.is_empty());
    assert_eq!(plan.additional_parents.protected_candidates, 1);
    assert_eq!(plan.additional_parents.malformed_candidates, 0);
    assert!(!plan.additional_parents.graph_complete);
    Ok(())
}
