//! Explicit product paired-placement events against isolated, generated provider fixtures.
//! Actual HTTP/graph/album/full-original evidence; native prompt/JOIN and journal CAS are fixture adapters.
use super::*;
use crux_core::Core;
use selected_recovery::Fixture;
use suwop_core::{
    app::{ConnectionSettings, Model, Suwop},
    immich_live_writes::LivePlacementDestination,
    immich_locked::Secret,
    protection::ProtectionScenePhase,
};
#[path = "paired_visibility_shell.rs"]
mod shell;
use shell::PairShell;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const LOCK: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RESTORE: &str = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_paired_visibility_lock_restore_preserves_graph_and_originals() -> Result<(), String> {
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("pair evidence directory")?,
    )
    .join("paired-visibility");
    std::fs::create_dir(&root).map_err(|_| "pair evidence directory exists")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup_paired_visibility(&agent, &root)?;
    let before = prepare_fixture(&agent, &fixture, &root)?;
    let (core, mut host) = start(&agent, &fixture, &root)?;
    host.run(
        &core,
        placement(&fixture, LOCK, LivePlacementDestination::Locked),
    )?;
    let version = &fixture.elevated.ordinary.version;
    if version.major == 3 && version.minor == 2 && version.patch == 4 {
        assert!(
            host.puts.is_empty(),
            "3.2.4 must reject product placement with zero product writes"
        );
        assert_eq!(host.confirmations, 0);
        assert_eq!(observe(&agent, &fixture, &root)?, before);
        old_server_read(&agent, &fixture, &root, &before)?;
    } else {
        assert_eq!(host.puts, [fixture.parent.clone(), fixture.motion.clone()]);
        assert!(core.view().error.is_none(), "{:?}", core.view().error);
        let locked = observe(&agent, &fixture, &root)?;
        assert_transition(&before, &locked, "locked")?;
        write(&root, "observer-locked.json", &locked)?;
        host.run(
            &core,
            placement(&fixture, RESTORE, LivePlacementDestination::Timeline),
        )?;
        assert_eq!(
            host.puts,
            [
                fixture.parent.clone(),
                fixture.motion.clone(),
                fixture.motion.clone(),
                fixture.parent.clone()
            ]
        );
        assert!(core.view().error.is_none(), "{:?}", core.view().error);
        let restored = observe(&agent, &fixture, &root)?;
        assert_transition(&before, &restored, "timeline")?;
        write(&root, "observer-restored.json", &restored)?;
        loss_restart_inspect(&agent, &fixture, &root, &core, &mut host, &restored)?;
    }
    write(
        &root,
        "product-trace.json",
        &json!({"puts":host.puts,"trace":host.trace,"journal":host.raw()?,"nativeBoundary":"synthetic confirmation/JOIN and file CAS; actual provider HTTP, metadata, albums and full original SHA256"}),
    )?;
    host.run(&core, Event::CloseImmichLocked)?;
    fixture.close(&agent)
}
fn prepare_fixture(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<Value, String> {
    // Explicit external fixture setup is outside the measured product trace.
    fixture.set_visibility(agent, "timeline")?;
    let initial = observe(agent, fixture, root)?;
    let album = initial[2]["albumIDs"]
        .as_array()
        .and_then(|v| v.first())
        .and_then(Value::as_str)
        .ok_or("fixture album")?;
    let added = execute(
        agent,
        &fixture.elevated.request(
            &format!("albums/{album}/assets"),
            "PUT",
            Some(json!({"ids":[fixture.parent,fixture.motion]})),
        ),
    )?;
    let added: HttpResponse =
        serde_json::from_value(added).map_err(|_| "external fixture album response")?;
    immich::check_status(added.status)?;
    write(
        root,
        "external-setup.json",
        &json!({
            "boundary":"external generated-fixture setup, excluded from product HTTP trace",
            "selectedParentVisibility":"timeline", "albumID":album,
            "albumMembersAdded":[fixture.parent,fixture.motion]
        }),
    )?;
    let before = observe(agent, fixture, root)?;
    // Normal Live arrangement: only the parent is set externally; the provider keeps
    // the paired motion hidden. assert_transition restores exactly this shape.
    assert_eq!(before[0]["identity"]["visibility"], "timeline");
    assert_eq!(before[1]["identity"]["visibility"], "hidden");
    assert!(
        !before[0]["albumIDs"]
            .as_array()
            .ok_or("parent albums")?
            .is_empty()
    );
    assert!(
        !before[1]["albumIDs"]
            .as_array()
            .ok_or("motion albums")?
            .is_empty()
    );
    write(root, "observer-before.json", &before)?;
    Ok(before)
}
fn old_server_read(
    agent: &ureq::Agent,
    fixture: &Fixture,
    root: &Path,
    before: &Value,
) -> Result<(), String> {
    use suwop_core::immich_live_writes::*;
    let state = historical_state(fixture, historical_facts(agent, fixture)?, before)?;
    write(
        root,
        "old-server-synthetic-history-setup.json",
        &json!({"boundary":"synthetic persisted history bound to independently observed generated P/M identities; not product write authority", "state":state}),
    )?;
    let historical =
        serde_json::to_value(&state.immich_live_operations).map_err(|_| "historical encode")?;
    let core = Core::new_with(
        Suwop,
        Model {
            state: state.clone(),
            session: Some(fixture.elevated.ordinary.clone()),
            ready: true,
            ..Model::default()
        },
    );
    assert!(core.view().immich_locked_view.grant_id.is_none());
    let mut read = PairShell::new(agent, fixture, root, &state)?;
    read.run(
        &core,
        Event::RefreshOrdinaryLivePairs {
            request_id: history_id(0x00fe_e070),
        },
    )?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    let pairs = core.view().ordinary_live_pairs;
    assert_eq!(
        pairs.len(),
        1,
        "actual no-PIN product refresh must publish a fresh pair on 3.2.4"
    );
    assert_eq!(pairs[0].parent_key, fixture.key());
    assert_eq!(pairs[0].motion_key.asset_id, fixture.motion);
    assert_eq!(pairs[0].parent_visibility, Placement::Timeline);
    // Fresh provider facts: the paired motion stays hidden in the normal arrangement.
    assert_eq!(pairs[0].motion_visibility, Placement::Hidden);
    read.run(
        &core,
        Event::PlayOrdinaryLivePair {
            parent_key: fixture.key(),
            request_id: history_id(0x00fe_e080),
        },
    )?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert_eq!(
        read.originals.len(),
        2,
        "actual scoped provider originals must both be hashed"
    );
    assert_eq!((read.plays, read.ends), (1, 1));
    assert!(!read.read_workspaces.is_empty());
    assert!(read.read_workspaces.iter().all(|path| !path.exists()));
    assert!(read.puts.is_empty());
    assert_eq!(read.confirmations, 0);
    assert_eq!(
        serde_json::to_value(&read.raw()?.immich_live_operations)
            .map_err(|_| "historical after")?,
        historical
    );
    assert_eq!(observe(agent, fixture, root)?, *before);
    write(
        root,
        "old-server-product-read.json",
        &json!({"boundary":"actual Core no-PIN refresh + scoped provider original downloads with actual SHA1/SHA256/size; synthetic Begin/Play/End receipts and exact local workspace cleanup, no OS playback claim", "trace":read.trace,"pairs":pairs,"originalHashes":read.originals,"syntheticPlayReceipts":read.plays,"exactWorkspaceCleanups":read.ends,"workspacesRemoved":read.read_workspaces.iter().all(|path|!path.exists()),"puts":read.puts,"confirmations":read.confirmations,"historicalOutcomesUnchanged":true}),
    )
}
fn history_id(n: u32) -> String {
    format!("{n:08x}-0000-4000-8000-000000000000")
}
fn historical_facts(
    agent: &ureq::Agent,
    fixture: &Fixture,
) -> Result<Vec<suwop_core::immich_live_writes::Fact>, String> {
    use suwop_core::immich_live_writes::*;
    let mut facts = Vec::new();
    for (index, asset_id) in [&fixture.parent, &fixture.motion].into_iter().enumerate() {
        let response: HttpResponse = serde_json::from_value(execute(
            agent,
            &fixture
                .elevated
                .request(&format!("assets/{asset_id}"), "GET", None),
        )?)
        .map_err(|_| "historical fixture metadata")?;
        immich::check_status(response.status)?;
        let raw = response.body;
        assert_eq!(raw["id"], *asset_id);
        assert_eq!(raw["ownerId"], fixture.elevated.ordinary.user_id);
        facts.push(Fact {
            key: suwop_core::domain::AssetKey {
                asset_id: asset_id.clone(),
                ..fixture.key()
            },
            owner_id: fixture.elevated.ordinary.user_id.clone(),
            media: if index == 0 {
                Media::Image
            } else {
                Media::Video
            },
            checksum: suwop_core::domain::normalize_sha1(raw["checksum"].as_str())
                .ok_or("historical checksum")?,
            revision: raw["updatedAt"]
                .as_str()
                .ok_or("historical revision")?
                .into(),
            placement: Placement::Timeline,
            forward: if index == 0 {
                Forward::Linked(suwop_core::domain::AssetKey {
                    asset_id: fixture.motion.clone(),
                    ..fixture.key()
                })
            } else {
                Forward::Unlinked
            },
            unstacked: raw["stack"].is_null(),
            offline: raw["isOffline"].as_bool().ok_or("historical offline")?,
            trashed: raw["isTrashed"].as_bool().ok_or("historical trash")?,
        });
    }
    Ok(facts)
}
fn historical_intent(
    fixture: &Fixture,
    facts: Vec<suwop_core::immich_live_writes::Fact>,
    before: &Value,
) -> Result<suwop_core::immich_live_writes::Intent, String> {
    use suwop_core::immich_live_writes::*;
    let mut intent = Intent {
        encoding_version: 1,
        owner_id: fixture.elevated.ordinary.user_id.clone(),
        scope: fixture.key().scope,
        direction: Direction::Lock,
        selections: vec![Selection {
            id: history_id(0x00fe_e001),
            parent: fixture.key(),
        }],
        resources: historical_resources(facts, before)?,
        edges: vec![Edge {
            id: history_id(0x00fe_e030),
            selection_id: history_id(0x00fe_e001),
            parent_resource: history_id(0x00fe_e010),
            motion_resource: history_id(0x00fe_e011),
        }],
        aliases: (0_u32..)
            .zip([Role::Parent, Role::Motion])
            .map(|(index, role)| Alias {
                id: history_id(0x00fe_e040 + index),
                edge_id: history_id(0x00fe_e030),
                role,
                resource_id: history_id(0x00fe_e010 + index),
                destination: Placement::Locked,
            })
            .collect(),
        observed_additional_parents: vec![suwop_core::domain::AssetKey {
            asset_id: fixture.other.clone(),
            ..fixture.key()
        }],
        shared_reference_limitations_acknowledged: true,
        dependencies: vec![Dependency {
            before: history_id(0x00fe_e020),
            after: history_id(0x00fe_e021),
        }],
        ordered_step_ids: vec![history_id(0x00fe_e020), history_id(0x00fe_e021)],
        supersedes: vec![],
        digest: String::new(),
    };
    intent.digest = intent_digest(&intent)?;
    Ok(intent)
}
fn historical_resources(
    facts: Vec<suwop_core::immich_live_writes::Fact>,
    before: &Value,
) -> Result<Vec<suwop_core::immich_live_writes::Resource>, String> {
    use suwop_core::immich_live_writes::*;
    facts
        .into_iter()
        .enumerate()
        .map(|(index, fact)| {
            let offset = u32::try_from(index).map_err(|_| "historical index")?;
            let albums = before[index]["albumIDs"]
                .as_array()
                .ok_or("observer albums")?
                .iter()
                .map(|value| value.as_str().map(str::to_owned).ok_or("observer album ID"))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Resource {
                id: history_id(0x00fe_e010 + offset),
                initial: fact,
                initial_albums: albums,
                destination: Placement::Locked,
                step_id: Some(history_id(0x00fe_e020 + offset)),
            })
        })
        .collect()
}
fn historical_state(
    fixture: &Fixture,
    facts: Vec<suwop_core::immich_live_writes::Fact>,
    before: &Value,
) -> Result<SavedLibrary, String> {
    use suwop_core::immich_live_writes::*;
    let intent = historical_intent(fixture, facts, before)?;
    let steps = vec![
        Step {
            id: history_id(0x00fe_e020),
            resource_id: history_id(0x00fe_e010),
            outcome: Outcome::Unknown {
                attempt_id: history_id(0x00fe_e050),
                accepted: None,
            },
        },
        Step {
            id: history_id(0x00fe_e021),
            resource_id: history_id(0x00fe_e011),
            outcome: Outcome::NotStarted,
        },
    ];
    let state = SavedLibrary {
        schema_version: 9,
        connection: Some(ConnectionSettings {
            address: fixture.elevated.ordinary.endpoint.clone(),
            allow_http: true,
            credential_id: "paired-fixture".into(),
        }),
        immich_live_operations: vec![Batch {
            format_version: 1,
            id: history_id(0x00fe_e060),
            intent,
            steps,
            latest_observations: vec![],
        }],
        ..SavedLibrary::default()
    };
    validate_library(&state)?;
    Ok(state)
}
fn loss_restart_inspect(
    agent: &ureq::Agent,
    fixture: &Fixture,
    root: &Path,
    core: &Core<Suwop>,
    host: &mut PairShell<'_>,
    restored: &Value,
) -> Result<(), String> {
    const LOST: &str = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const INSPECT: &str = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    let initial_puts = host.puts.len();
    host.lose_response_at = Some(initial_puts + 2);
    host.run(
        core,
        placement(fixture, LOST, LivePlacementDestination::Locked),
    )?;
    assert_eq!(
        &host.puts[initial_puts..],
        &[fixture.parent.clone(), fixture.motion.clone()]
    );
    let durable = host.raw()?;
    let batch = durable
        .immich_live_operations
        .iter()
        .find(|batch| batch.id == LOST)
        .ok_or("lost batch")?;
    assert_eq!(batch.steps.len(), 2);
    assert!(batch.steps.iter().any(|step| matches!(
        step.outcome,
        suwop_core::immich_live_writes::Outcome::Unknown { .. }
    )));
    let historical = serde_json::to_value(&batch.steps).map_err(|_| "lost historical steps")?;
    let applied = observe(agent, fixture, root)?;
    assert_transition(restored, &applied, "locked")?;
    write(root, "lost-204-provider-observation.json", &applied)?;
    write(
        root,
        "lost-204-durable-before-restart.json",
        &serde_json::to_value(&durable).map_err(|_| "lost journal evidence")?,
    )?;
    host.run(core, Event::CloseImmichLocked)?;
    let restarted = Core::new_with(
        Suwop,
        Model {
            state: durable.clone(),
            session: Some(fixture.elevated.ordinary.clone()),
            ready: true,
            ..Model::default()
        },
    );
    let mut fresh = PairShell::new(agent, fixture, root, &durable)?;
    authenticate(&mut fresh, &restarted, fixture)?;
    assert!(
        fresh.puts.is_empty(),
        "restart/authentication never replays a PUT"
    );
    fresh.run(
        &restarted,
        Event::InspectImmichLivePlacement {
            batch_id: LOST.into(),
            request_id: INSPECT.into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(
        restarted.view().error.is_none(),
        "{:?}",
        restarted.view().error
    );
    assert!(
        fresh.puts.is_empty(),
        "Inspect cannot replay an unknown step"
    );
    assert_eq!(fresh.confirmations, 0);
    let after = fresh.raw()?;
    let inspected = after
        .immich_live_operations
        .iter()
        .find(|batch| batch.id == LOST)
        .ok_or("inspected batch")?;
    assert_eq!(
        serde_json::to_value(&inspected.steps).map_err(|_| "inspected historical steps")?,
        historical
    );
    assert_eq!(inspected.latest_observations.len(), 2);
    assert_eq!(observe(agent, fixture, root)?, applied);
    write(
        root,
        "lost-204-inspect-after-restart.json",
        &json!({"puts":fresh.puts,"trace":fresh.trace,"journal":after,"assertion":"Inspect adds observations without changing historical outcomes or replaying provider writes"}),
    )?;
    fresh.run(&restarted, Event::CloseImmichLocked)
}
fn placement(fixture: &Fixture, id: &str, destination: LivePlacementDestination) -> Event {
    Event::PrepareImmichLivePlacement {
        parents: vec![fixture.key()],
        destination,
        batch_id: id.into(),
        grant_id: GRANT.into(),
        scene_id: SCENE.into(),
    }
}
fn start<'a>(
    agent: &'a ureq::Agent,
    fixture: &'a Fixture,
    root: &'a Path,
) -> Result<(Core<Suwop>, PairShell<'a>), String> {
    let state = SavedLibrary {
        schema_version: 9,
        connection: Some(ConnectionSettings {
            address: fixture.elevated.ordinary.endpoint.clone(),
            allow_http: true,
            credential_id: "paired-fixture".into(),
        }),
        ..SavedLibrary::default()
    };
    let core = Core::new_with(
        Suwop,
        Model {
            state: state.clone(),
            session: Some(fixture.elevated.ordinary.clone()),
            ready: true,
            ..Model::default()
        },
    );
    let mut host = PairShell::new(agent, fixture, root, &state)?;
    authenticate(&mut host, &core, fixture)?;
    host.trace.clear();
    Ok((core, host))
}
fn authenticate(
    host: &mut PairShell<'_>,
    core: &Core<Suwop>,
    fixture: &Fixture,
) -> Result<(), String> {
    host.run(
        core,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    host.run(
        core,
        Event::OpenImmichLocked {
            scene_id: SCENE.into(),
            request_id: GRANT.into(),
            email: Secret(fixture.email.clone()),
            password: Secret("GraphFixtureOnly123!".into()),
            pin_code: Secret(PIN.into()),
        },
    )?;
    assert_eq!(
        core.view().immich_locked_view.grant_id.as_deref(),
        Some(GRANT)
    );
    Ok(())
}
fn write(root: &Path, name: &str, value: &Value) -> Result<(), String> {
    std::fs::write(
        root.join(name),
        serde_json::to_vec_pretty(value).map_err(|_| "pair evidence encode")?,
    )
    .map_err(|_| "pair evidence write".into())
}
fn observe(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<Value, String> {
    let pair = native_pair_bytes()?;
    let expected = [pair.0, pair.1, png(1)?];
    let mut rows = vec![];
    for (index, id) in [&fixture.parent, &fixture.motion, &fixture.other]
        .into_iter()
        .enumerate()
    {
        let get = |path: &str, destination: Option<&Path>| -> Result<Value, String> {
            let mut request = fixture.elevated.request(path, "GET", None);
            request.download_path = destination.map(|p| p.to_string_lossy().into_owned());
            let response: HttpResponse = serde_json::from_value(execute(agent, &request)?)
                .map_err(|_| "pair observer response")?;
            immich::check_status(response.status)?;
            Ok(response.body)
        };
        let detail = get(&format!("assets/{id}"), None)?;
        assert_eq!(detail["id"], *id);
        assert_eq!(detail["ownerId"], fixture.elevated.ordinary.user_id);
        assert_eq!(detail["type"], if index == 1 { "VIDEO" } else { "IMAGE" });
        assert_eq!(
            detail["livePhotoVideoId"],
            if index == 1 {
                Value::Null
            } else {
                json!(fixture.motion)
            }
        );
        assert!(detail["stack"].is_null());
        let albums = get(&format!("albums?assetId={id}"), None)?;
        let ids = albums
            .as_array()
            .ok_or("pair observer album list")?
            .iter()
            .map(|a| {
                a["id"]
                    .as_str()
                    .map(str::to_owned)
                    .ok_or("pair observer album id")
            })
            .collect::<Result<BTreeSet<_>, _>>()?;
        let path = root.join(format!("observer-{index}.bin"));
        get(&format!("assets/{id}/original?edited=false"), Some(&path))?;
        let bytes = std::fs::read(path).map_err(|_| "pair original read")?;
        assert_eq!(bytes, expected[index]);
        let identity = [
            "id",
            "ownerId",
            "type",
            "checksum",
            "visibility",
            "livePhotoVideoId",
        ]
        .into_iter()
        .map(|field| (field.to_owned(), detail[field].clone()))
        .collect::<serde_json::Map<_, _>>();
        rows.push(json!({"identity":identity,"albumIDs":ids,"originalSHA256":format!("{:x}",sha2::Sha256::digest(bytes))}));
    }
    Ok(json!(rows))
}
fn assert_transition(before: &Value, after: &Value, visibility: &str) -> Result<(), String> {
    assert_eq!(
        after[2], before[2],
        "undiscovered shared parent remains unchanged"
    );
    for index in 0..2 {
        let destination = if index == 1 && visibility == "timeline" {
            "hidden"
        } else {
            visibility
        };
        assert_eq!(after[index]["identity"]["visibility"], destination);
        assert!(
            after[index]["albumIDs"]
                .as_array()
                .ok_or("pair album observation")?
                .is_empty(),
            "lock removes memberships and restore never recreates them"
        );
        let mut expected = before[index].clone();
        expected["identity"]["visibility"] = json!(destination);
        expected["albumIDs"] = json!([]);
        assert_eq!(
            after[index], expected,
            "full original hash and P/M graph must survive"
        );
    }
    Ok(())
}
