//! Dedicated metadata-only product plan. No pair mutation/playback claim.
use super::*;
#[test]
#[ignore = "requires the isolated Docker Immich 3.3.3 harness"]
fn real_live_resource_plan_observes_shared_motion_without_mutation_authority() -> Result<(), String>
{
    let root =
        std::env::temp_dir().join(format!("suwop-live-resource-plan-{}", std::process::id()));
    std::fs::create_dir(&root).map_err(|_| "live plan directory")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup_live_plan(&agent, &root)?;
    let session = &fixture.elevated.ordinary;
    assert_eq!(
        (
            session.version.major,
            session.version.minor,
            session.version.patch
        ),
        (3, 3, 3)
    );
    let connection = ConnectionSettings {
        address: session.endpoint.clone(),
        allow_http: true,
        credential_id: "live-plan-fixture".into(),
    };
    let state = SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        connection: Some(connection),
        ..SavedLibrary::default()
    };
    let raw = serde_json::to_value(&state).map_err(|_| "live plan state")?;
    let core = Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(session.clone()),
            ready: true,
            ..Model::default()
        },
    );
    let mut shell = RecoveryShell::new(&agent, &root, session, &raw)?;
    shell.authenticate(&core, &fixture.email, GRANT)?;
    let before = shell.raw()?;
    setup_visibility(&agent, &fixture, &fixture.other, "locked")?;
    for motion_visibility in ["hidden", "locked"] {
        setup_visibility(&agent, &fixture, &fixture.motion, motion_visibility)?;
        let resources_before = observe(&agent, &fixture)?;
        shell.reset_trace();
        shell.run(
            &core,
            Event::InspectImmichLiveResources {
                parent_key: fixture.key(),
                request_id: OP.into(),
                grant_id: GRANT.into(),
                scene_id: SCENE.into(),
            },
        )?;
        let plan = core
            .view()
            .immich_live_resources
            .ok_or("live plan view")?
            .plan
            .ok_or("live plan unavailable")?;
        assert_eq!(plan.read_targets.len(), 2);
        assert_eq!(plan.read_targets[0].key, fixture.key());
        assert_eq!(plan.read_targets[1].key.asset_id, fixture.motion);
        assert_targets(&plan, &fixture, &resources_before, motion_visibility)?;
        assert!(!plan.additional_parents.graph_complete);
        assert!(
            plan.additional_parents
                .parents
                .iter()
                .any(|p| p.key.asset_id == fixture.other)
        );
        assert_eq!(shell.raw()?, before);
        assert_eq!(observe(&agent, &fixture)?, resources_before);
        assert!(
            !shell
                .trace
                .iter()
                .any(|s| s.contains("persist") || s.contains("PUT") || s.contains("original"))
        );
        evidence(
            &format!("live-resource-plan-{motion_visibility}"),
            &serde_json::to_value(&plan).map_err(|_| "plan encode")?,
        )?;
    }
    shell.run(&core, Event::CloseImmichLocked)?;
    assert!(core.view().immich_live_resources.is_none());
    fixture.close(&agent)?;
    std::fs::remove_dir_all(root).map_err(|_| "live plan cleanup")?;
    Ok(())
}

fn observe(agent: &ureq::Agent, fixture: &Fixture) -> Result<Value, String> {
    let mut result = Vec::new();
    for (id, kind) in [
        (&fixture.parent, "IMAGE"),
        (&fixture.motion, "VIDEO"),
        (&fixture.other, "IMAGE"),
    ] {
        let response: HttpResponse = serde_json::from_value(execute(
            agent,
            &fixture
                .elevated
                .request(&format!("assets/{id}"), "GET", None),
        )?)
        .map_err(|_| "live observer detail")?;
        assert_eq!(response.status, 200);
        assert_eq!(response.body["id"], *id);
        assert_eq!(response.body["ownerId"], fixture.elevated.ordinary.user_id);
        assert_eq!(response.body["type"], kind);
        let albums: HttpResponse = serde_json::from_value(execute(
            agent,
            &fixture
                .elevated
                .request(&format!("albums?assetId={id}"), "GET", None),
        )?)
        .map_err(|_| "live observer albums")?;
        assert_eq!(albums.status, 200);
        result.push(json!({"asset":response.body,"albums":albums.body}));
    }
    Ok(json!(result))
}

fn setup_visibility(
    agent: &ureq::Agent,
    fixture: &Fixture,
    id: &str,
    visibility: &str,
) -> Result<(), String> {
    let response: HttpResponse = serde_json::from_value(execute(
        agent,
        &fixture.elevated.request(
            &format!("assets/{id}"),
            "PUT",
            Some(json!({"visibility":visibility})),
        ),
    )?)
    .map_err(|_| "live plan fixture visibility setup")?;
    assert_eq!(response.status, 200);
    assert_eq!(response.body["id"], id);
    assert_eq!(response.body["visibility"], visibility);
    Ok(())
}

fn assert_targets(
    plan: &suwop_core::immich_live_resources::ImmichLiveResourcePlan,
    fixture: &Fixture,
    resources_before: &Value,
    motion_visibility: &str,
) -> Result<(), String> {
    use suwop_core::immich_live_resources::{LiveObservedVisibility, LiveResourceRole};
    let session = &fixture.elevated.ordinary;
    let observed = resources_before
        .as_array()
        .ok_or("live observer resource list")?;
    for (index, id, role, kind) in [
        (0, &fixture.parent, LiveResourceRole::Parent, "IMAGE"),
        (1, &fixture.motion, LiveResourceRole::Motion, "VIDEO"),
    ] {
        let target = plan.read_targets.get(index).ok_or("live plan target")?;
        let asset = &observed.get(index).ok_or("live observer member")?["asset"];
        assert_eq!(target.role, role);
        assert_eq!(target.key.provider, Provider::Immich);
        assert_eq!(target.key.scope, session.scope);
        assert_eq!(
            target.key.scope,
            format!("{}#{}", session.endpoint, session.user_id)
        );
        assert_eq!(target.key.asset_id, *id);
        assert_eq!(asset["id"], *id);
        assert_eq!(asset["ownerId"], session.user_id);
        assert_eq!(asset["type"], kind);
        assert_eq!(
            target.checksum,
            suwop_core::domain::normalize_sha1(asset["checksum"].as_str())
                .ok_or("live observer checksum")?
        );
        assert_eq!(
            target.revision,
            asset["updatedAt"]
                .as_str()
                .filter(|v| !v.is_empty())
                .ok_or("live observer revision")?
        );
        assert_eq!(
            serde_json::to_value(target.visibility).map_err(|_| "live visibility encode")?,
            asset["visibility"]
        );
    }
    let expected_motion = match motion_visibility {
        "hidden" => LiveObservedVisibility::Hidden,
        "locked" => LiveObservedVisibility::Locked,
        _ => return Err("unexpected live fixture motion placement".into()),
    };
    assert_eq!(plan.read_targets[1].visibility, expected_motion);
    assert_eq!(observed[1]["asset"]["visibility"], motion_visibility);
    Ok(())
}
