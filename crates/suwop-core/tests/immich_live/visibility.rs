//! Real isolated-server evidence. Confirmations are host-injected, not UI acceptance.
use super::{execute, fixture_metadata, live_locked_core, live_response};
use base64::Engine;
use crux_core::{Command, Core};
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path, time::Duration};
use suwop_core::{
    app::{Context, Effect, Event, SavedLibrary, ShellOperation, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, TransferFile,
    },
    immich::{self, HttpRequest, HttpResponse, Session},
    immich_locked::Secret,
    immich_visibility::{AlbumMembershipObservation, ImmichVisibility},
};
const FILE_CAPTURE_TIME: f64 = 1_780_000_000.0;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const PIXEL: &str = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAGElEQVR4nGOQiV3+331z2f+7yZr/GZA5AK3EDe2NVSbWAAAAAElFTkSuQmCC";
#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_immich_single_image_visibility_removes_two_owned_albums_and_never_restores_them()
-> Result<(), String> {
    let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "missing test URL")?;
    let api_key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "missing test key")?;
    let directory =
        std::env::temp_dir().join(format!("suwop-visibility-live-{}", std::process::id()));
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let (session, id, albums) = setup(&agent, address, api_key, &directory)?;
    let key = AssetKey {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        asset_id: id,
    };
    let core = live_locked_core(session.clone());
    let mut shell = LiveVisibilityShell {
        agent: &agent,
        directory: &directory,
        writes: 0,
        elevated_memberships: vec![],
        fresh_observations: vec![],
        fact_requests: BTreeMap::new(),
    };
    shell.run(
        &core,
        Event::Refresh {
            permission: false,
            now: scan_now()?,
        },
    )?;
    assert!(core.view().ordinary_content_keys.contains(&key));
    assert!(
        core.view()
            .immich_visibility_actions
            .iter()
            .any(|a| a.key == key && a.can_lock)
    );
    shell.run(&core, Event::RefreshAlbums)?;
    for album in &albums {
        assert!(album_contains(&agent, &session, album, &key.asset_id)?);
    }
    wait_for_stable_asset(
        &agent,
        &session.request(&format!("assets/{}", key.asset_id), "GET", None),
        &key,
    )?;
    shell.run(&core, open(GRANT))?;
    shell.run(
        &core,
        prepare(
            &key,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ImmichVisibility::Locked,
            GRANT,
        ),
    )?;
    assert_eq!(shell.writes, 1);
    assert_roster(&core, &key, GRANT, true)?;
    assert_eq!(shell.elevated_memberships.len(), 1);
    assert!(
        albums
            .iter()
            .all(|id| !shell.elevated_memberships[0].contains(id))
    );
    let view = core.view();
    let history = view.immich_visibility_view.history.ok_or("no history")?;
    assert_eq!(
        history[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Applied
    );
    assert_eq!(
        history[0].album_membership_observation,
        AlbumMembershipObservation::NoAccessibleMemberships
    );
    assert!(!view.ordinary_content_keys.contains(&key));
    for album in &albums {
        assert!(!album_contains(&agent, &session, album, &key.asset_id)?);
    }
    let denied: HttpResponse = serde_json::from_value(execute(
        &agent,
        &session.request(&format!("assets/{}", key.asset_id), "GET", None),
    )?)
    .map_err(|_| "response")?;
    assert!(!(200..300).contains(&denied.status));
    verify_cycles(
        &mut shell, &core, &agent, &session, &key, &albums, &directory,
    )?;
    assert_eq!(shell.writes, 4);
    verify_stacked_hints(&mut shell, &core, &session, &directory)?;
    assert!(
        !serde_json::to_string(&journal(&directory)?.immich_visibility_operations)
            .map_err(|_| "journal encode")?
            .contains("visibility-fixture.png")
    );
    std::fs::remove_dir_all(directory).map_err(|e| e.to_string())?;
    Ok(())
}
fn open(grant: &str) -> Event {
    Event::OpenImmichLocked {
        scene_id: SCENE.into(),
        request_id: grant.into(),
        email: Secret(
            std::env::var("IMMICH_TEST_EMAIL").unwrap_or_else(|_| "suwop@example.invalid".into()),
        ),
        password: Secret(
            std::env::var("IMMICH_TEST_PASSWORD").unwrap_or_else(|_| "SuwopIntegration123!".into()),
        ),
        pin_code: Secret(std::env::var("IMMICH_TEST_PIN").unwrap_or_else(|_| "123456".into())),
    }
}
fn prepare(key: &AssetKey, id: &str, to: ImmichVisibility, grant: &str) -> Event {
    Event::PrepareImmichVisibility {
        key: key.clone(),
        to,
        operation_id: id.into(),
        grant_id: grant.into(),
        scene_id: SCENE.into(),
    }
}
fn journal(directory: &Path) -> Result<SavedLibrary, String> {
    serde_json::from_slice(
        &std::fs::read(directory.join("journal.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|_| "journal decode".into())
}
fn album_contains(
    agent: &ureq::Agent,
    session: &Session,
    id: &str,
    asset: &str,
) -> Result<bool, String> {
    let response: HttpResponse = serde_json::from_value(execute(
        agent,
        &session.request(&format!("albums?assetId={asset}"), "GET", None),
    )?)
    .map_err(|_| "album response")?;
    immich::check_status(response.status)?;
    Ok(album_ids(&response.body)?.iter().any(|album| album == id))
}
fn verify_original(
    agent: &ureq::Agent,
    session: &Session,
    key: &AssetKey,
    directory: &Path,
) -> Result<(), String> {
    let mut request = session.request(
        &format!("assets/{}/original?edited=false", key.asset_id),
        "GET",
        None,
    );
    let path = directory.join("readback.png");
    request.download_path = Some(path.to_string_lossy().into_owned());
    let response: HttpResponse =
        serde_json::from_value(execute(agent, &request)?).map_err(|_| "original response")?;
    immich::check_status(response.status)?;
    assert_eq!(
        std::fs::read(path).map_err(|e| e.to_string())?,
        base64::engine::general_purpose::STANDARD
            .decode(PIXEL)
            .map_err(|_| "pixel decode")?
    );
    Ok(())
}
struct LiveVisibilityShell<'a> {
    agent: &'a ureq::Agent,
    directory: &'a Path,
    writes: usize,
    elevated_memberships: Vec<Vec<String>>,
    fresh_observations: Vec<(String, String)>,
    fact_requests: BTreeMap<String, HttpRequest>,
}
impl LiveVisibilityShell<'_> {
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let prepare_id = if let Event::PrepareImmichVisibility { operation_id, .. } = &event {
            Some(operation_id.clone())
        } else {
            None
        };
        let observation_start = self.fresh_observations.len();
        if let Event::PrepareImmichVisibility { key, .. } = &event
            && let Some(request) = self.fact_requests.get(&key.asset_id)
        {
            wait_for_stable_asset(self.agent, request, key)?;
        }
        if matches!(event, Event::OpenImmichLocked { .. }) {
            self.fact_requests.clear();
            self.drain(
                core,
                core.process_event(Event::ImmichLockedSceneChanged {
                    scene_id: SCENE.into(),
                    phase: suwop_core::protection::ProtectionScenePhase::Active,
                }),
            )?;
        }
        self.drain(core, core.process_event(event))?;
        if let Some(id) = prepare_id
            && !journal(self.directory)?
                .immich_visibility_operations
                .iter()
                .any(|o| o.id == id)
        {
            let view = core.view();
            return Err(format!(
                "visibility preparation produced no durable intent: status={:?}, lockedState={:?}, busy={}, freshFacts={:?}",
                view.immich_visibility_view.status,
                view.immich_locked_view.state,
                view.busy,
                &self.fresh_observations[observation_start..]
            ));
        }
        Ok(())
    }
    fn drain(&mut self, core: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let result = self.respond(core, &request.operation);
            effects.extend(
                core.resolve(&mut request, live_response(result))
                    .map_err(|_| "visibility resolve")?,
            );
        }
        if let Some(error) = core.view().error {
            return Err(error);
        }
        Ok(())
    }
    fn respond(&mut self, core: &Core<Suwop>, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) => {
                if let Some(permit) = &request.immich_visibility_authorization {
                    let grant = core.view().immich_locked_view;
                    assert_eq!(grant.grant_id.as_deref(), Some(permit.grant_id.as_str()));
                    assert_eq!(grant.scene_id.as_deref(), Some(permit.scene_id.as_str()));
                    assert_eq!(grant.generation, permit.generation);
                    assert!(
                        journal(self.directory)?
                            .immich_visibility_operations
                            .iter()
                            .any(|o| o.id == permit.operation_id
                                && o.outcome
                                    == suwop_core::apple_visibility::VisibilityOutcome::Unknown)
                    );
                    self.writes += 1;
                }
                let value = execute(self.agent, request)?;
                if request.method == "GET"
                    && let Some(visibility) = value["body"]["visibility"].as_str()
                {
                    if request
                        .headers
                        .get("Authorization")
                        .is_some_and(|v| v.starts_with("Bearer "))
                        && let Some(id) = value["body"]["id"].as_str()
                    {
                        self.fact_requests.insert(id.into(), request.clone());
                    }
                    self.fresh_observations.push((
                        visibility.into(),
                        value["body"]["updatedAt"]
                            .as_str()
                            .unwrap_or("missing")
                            .into(),
                    ));
                }
                if request.url.contains("/albums?assetId=") {
                    assert!(
                        request
                            .headers
                            .get("Authorization")
                            .is_some_and(|value| value.starts_with("Bearer "))
                    );
                    let response: HttpResponse = serde_json::from_value(value.clone())
                        .map_err(|_| "album membership response")?;
                    immich::check_status(response.status)?;
                    self.elevated_memberships.push(album_ids(&response.body)?);
                }
                Ok(value)
            }
            ShellOperation::ConfirmImmichVisibility { .. } => Ok(json!(true)),
            ShellOperation::Persist(state) => {
                let path = self.directory.join("journal.tmp");
                std::fs::write(
                    &path,
                    serde_json::to_vec(state).map_err(|_| "journal encode")?,
                )
                .map_err(|e| e.to_string())?;
                std::fs::rename(path, self.directory.join("journal.json"))
                    .map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            ShellOperation::ReadState => {
                serde_json::to_value(journal(self.directory)?).map_err(|_| "journal encode".into())
            }
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope: scope.clone(),
                assets: vec![],
                access: ScanAccess::Full,
                scanned_at: Some(scan_now()?),
            })
            .map_err(|_| "scan encode".into()),
            ShellOperation::AppleAlbums { scope } => {
                Ok(json!({"provider":"apple","scope":scope,"albums":[],"access":"full"}))
            }
            ShellOperation::ReleaseImmichLockedImage { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. } => Ok(Value::Null),
            _ => Err("unexpected visibility fixture effect".into()),
        }
    }
}
fn setup(
    agent: &ureq::Agent,
    address: String,
    key: String,
    directory: &Path,
) -> Result<(Session, String, Vec<String>), String> {
    let directory = directory.to_path_buf();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = Box::pin(prepare_fixture(&ctx, &address, &key, &directory)).await;
        let (session, status, error) = match result {
            Ok((session, id, albums)) => (
                Some(session),
                json!({"id":id,"albums":albums}).to_string(),
                None,
            ),
            Err(error) => (None, String::new(), Some(error)),
        };
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session,
            status,
            error,
            preview_to_select: None,
        });
    });
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut request) in effects {
            let result = match &request.operation {
                ShellOperation::Http(http) => execute(agent, http),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected visibility setup effect".into()),
            };
            request
                .resolve(live_response(result))
                .map_err(|_| "setup resolve")?;
        }
    }
    let Event::Finished {
        session: Some(session),
        status,
        error: None,
        ..
    } = command.events().last().ok_or("setup completion")?
    else {
        return Err("visibility setup failed".into());
    };
    let fixture: Value = serde_json::from_str(&status).map_err(|_| "setup decode")?;
    Ok((
        session,
        fixture["id"].as_str().ok_or("fixture ID")?.into(),
        fixture["albums"]
            .as_array()
            .ok_or("fixture albums")?
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| "album ID".into())
            })
            .collect::<Result<_, String>>()?,
    ))
}
async fn prepare_fixture(
    ctx: &Context,
    address: &str,
    key: &str,
    directory: &Path,
) -> Result<(Session, String, Vec<String>), String> {
    let session = immich::connect(ctx, address, key, true).await?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(PIXEL)
        .map_err(|_| "pixel decode")?;
    let path = directory.join("visibility-fixture.png");
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    let resource = PhotoResource {
        id: "visibility-fixture".into(),
        name: "visibility-fixture.png".into(),
        role: ResourceRole::Image,
        sha1: None,
        bytes: Some(bytes.len() as u64),
    };
    let file = TransferFile {
        resource: resource.clone(),
        path: path.to_string_lossy().into_owned(),
        signature: FileSignature {
            sha256: "0".repeat(64),
            bytes: bytes.len() as u64,
        },
    };
    let metadata = fixture_metadata(resource, 0, FILE_CAPTURE_TIME);
    let id = session
        .upload(ctx, &file, &metadata, FILE_CAPTURE_TIME, None)
        .await?;
    let peers = [
        "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGMQj179H4YZkDkAm4oMqSLhGnsAAAAASUVORK5CYII=",
        "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGMo1LH+D8MMyBwAinELCxHIAcEAAAAASUVORK5CYII=",
    ];
    for (index, pixel) in peers.iter().enumerate() {
        let peer_bytes = base64::engine::general_purpose::STANDARD
            .decode(pixel)
            .map_err(|_| "peer decode")?;
        let peer_path = directory.join(format!("stack-peer-{index}.png"));
        std::fs::write(&peer_path, &peer_bytes).map_err(|e| e.to_string())?;
        let mut peer_file = file.clone();
        peer_file.path = peer_path.to_string_lossy().into_owned();
        peer_file.resource.name = format!("stack-peer-{index}.png");
        peer_file.resource.bytes = Some(peer_bytes.len() as u64);
        peer_file.signature.bytes = peer_bytes.len() as u64;
        let peer = session
            .upload(ctx, &peer_file, &metadata, FILE_CAPTURE_TIME, None)
            .await?;
        std::fs::write(directory.join(format!("stack-peer-id-{index}")), peer)
            .map_err(|e| e.to_string())?;
    }
    let mut albums = Vec::new();
    for title in ["C2 owned first", "C2 owned second"] {
        let album = session.create_album(ctx, title).await?;
        session
            .change_album_members(ctx, &album.id, std::slice::from_ref(&id), true)
            .await?;
        albums.push(album.id);
    }
    Ok((session, id, albums))
}

fn verify_cycles(
    shell: &mut LiveVisibilityShell<'_>,
    core: &Core<Suwop>,
    agent: &ureq::Agent,
    session: &Session,
    key: &AssetKey,
    albums: &[String],
    directory: &Path,
) -> Result<(), String> {
    for (index, to) in [ImmichVisibility::Timeline, ImmichVisibility::Archive]
        .into_iter()
        .enumerate()
    {
        if index == 1 {
            shell.run(core, open("33333333-3333-4333-8333-333333333333"))?;
            shell.run(
                core,
                prepare(
                    key,
                    "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                    ImmichVisibility::Locked,
                    "33333333-3333-4333-8333-333333333333",
                ),
            )?;
        }
        if index == 1 {
            assert_eq!(shell.elevated_memberships.len(), 2);
            assert!(
                albums
                    .iter()
                    .all(|id| !shell.elevated_memberships[1].contains(id))
            );
        }
        let current_grant = if index == 0 {
            "88888888-8888-4888-8888-888888888888"
        } else {
            "99999999-9999-4999-8999-999999999999"
        };
        shell.run(core, open(current_grant))?;
        let entry = core
            .view()
            .immich_locked_view
            .entries
            .ok_or("locked entries")?
            .into_iter()
            .find(|e| e.id == key.asset_id)
            .ok_or("locked fixture")?;
        assert!(entry.visibility_action.can_show_timeline);
        assert!(entry.visibility_action.can_show_archive);
        let operation = if index == 0 {
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        } else {
            "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        };
        shell.run(core, prepare(key, operation, to, current_grant))?;
        assert_roster(core, key, current_grant, false)?;
        assert!(!core.view().ordinary_content_keys.contains(key));
        assert!(
            journal(directory)?
                .immich_visibility_operations
                .iter()
                .all(|o| o.observation == Some(to))
        );
        for album in albums {
            assert!(!album_contains(agent, session, album, &key.asset_id)?);
        }
        verify_original(agent, session, key, directory)?;
        shell.run(
            core,
            Event::Refresh {
                permission: false,
                now: scan_now()?,
            },
        )?;
        assert!(core.view().ordinary_content_keys.contains(key));
        for snapshot in &core.view().state.albums {
            for album in &snapshot.albums {
                if albums.contains(&album.key.album_id) {
                    assert!(!album.members.contains(key));
                }
            }
        }
        shell.run(core, Event::RefreshAlbums)?;
        for album in &core.view().state.albums {
            for record in &album.albums {
                if albums.contains(&record.key.album_id) {
                    assert!(!record.members.contains(key));
                }
            }
        }
    }
    Ok(())
}

// Catalog cutoff concerns server insertion time, independent of original capture dates.
fn scan_now() -> Result<f64, String> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .map_err(|_| "system clock precedes Unix epoch".into())
}

// Pinned getByAssetId joins album_asset directly; it does not filter asset visibility.
fn album_ids(value: &Value) -> Result<Vec<String>, String> {
    value
        .as_array()
        .ok_or("album membership list")?
        .iter()
        .map(|album| {
            album["id"]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| "album membership ID".into())
        })
        .collect()
}

// Allow background server jobs to settle before a new user intent. Never retry a mutation.
fn wait_for_stable_asset(
    agent: &ureq::Agent,
    request: &HttpRequest,
    key: &AssetKey,
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut previous = None;
    let mut stable = 0;
    while std::time::Instant::now() < deadline {
        let response: HttpResponse = serde_json::from_value(execute(agent, request)?)
            .map_err(|_| "stable facts response")?;
        immich::check_status(response.status)?;
        if response.body["id"].as_str() != Some(key.asset_id.as_str()) {
            return Err("stable facts identity mismatch".into());
        }
        let revision = response.body["updatedAt"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("stable facts revision")?
            .to_owned();
        let visibility = response.body["visibility"]
            .as_str()
            .ok_or("stable facts visibility")?
            .to_owned();
        let current = (revision, visibility);
        stable = if previous.as_ref() == Some(&current) {
            stable + 1
        } else {
            0
        };
        if stable >= 2 {
            return Ok(());
        }
        previous = Some(current);
        std::thread::sleep(Duration::from_millis(250));
    }
    Err("fixture asset did not settle before a new intent".into())
}

fn verify_stacked_hints(
    shell: &mut LiveVisibilityShell<'_>,
    core: &Core<Suwop>,
    session: &Session,
    directory: &Path,
) -> Result<(), String> {
    let key = &AssetKey {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        asset_id: std::fs::read_to_string(directory.join("stack-peer-id-0"))
            .map_err(|e| e.to_string())?,
    };
    let peer =
        std::fs::read_to_string(directory.join("stack-peer-id-1")).map_err(|e| e.to_string())?;
    let response: HttpResponse = serde_json::from_value(execute(
        shell.agent,
        &session.request(
            "stacks",
            "POST",
            Some(json!({"assetIds":[key.asset_id,peer]})),
        ),
    )?)
    .map_err(|_| "stack response")?;
    immich::check_status(response.status)?;
    shell.run(
        core,
        Event::Refresh {
            permission: false,
            now: scan_now()?,
        },
    )?;
    let hint = core
        .view()
        .immich_visibility_actions
        .into_iter()
        .find(|a| a.key == *key)
        .ok_or("stack hint")?;
    assert_eq!(
        hint.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Stack)
    );
    assert!(!hint.can_lock);
    // Independent setup session: ordinary Refresh deliberately revokes the product session.
    fixture_lock_stack(shell.agent, session, &key.asset_id)?;
    shell.run(core, open("77777777-7777-4777-8777-777777777777"))?;
    let entry = core
        .view()
        .immich_locked_view
        .entries
        .ok_or("stack locked entries")?
        .into_iter()
        .find(|e| e.id == key.asset_id)
        .ok_or("stack locked entry")?;
    assert_eq!(
        entry.visibility_action.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Stack)
    );
    assert!(!entry.visibility_action.can_show_timeline);
    assert!(!entry.visibility_action.can_show_archive);
    assert_eq!(shell.writes, 4);
    Ok(())
}

fn fixture_lock_stack(agent: &ureq::Agent, session: &Session, id: &str) -> Result<(), String> {
    let mut login = session.request("auth/login", "POST", Some(json!({
        "email":std::env::var("IMMICH_TEST_EMAIL").unwrap_or_else(|_| "suwop@example.invalid".into()),
        "password":std::env::var("IMMICH_TEST_PASSWORD").unwrap_or_else(|_| "SuwopIntegration123!".into()),
    })));
    login.headers.remove("x-api-key");
    let response: HttpResponse =
        serde_json::from_value(execute(agent, &login)?).map_err(|_| "fixture login response")?;
    immich::check_status(response.status).map_err(|_| "fixture login rejected")?;
    let token = response.body["accessToken"]
        .as_str()
        .ok_or("fixture login token missing")?;
    let mut request = session.request(
        "auth/session/unlock",
        "POST",
        Some(
            json!({"pinCode":std::env::var("IMMICH_TEST_PIN").unwrap_or_else(|_| "123456".into())}),
        ),
    );
    request.headers.remove("x-api-key");
    request
        .headers
        .insert("Authorization".into(), format!("Bearer {token}"));
    let result = (|| {
        let response: HttpResponse = serde_json::from_value(execute(agent, &request)?)
            .map_err(|_| "fixture PIN response")?;
        immich::check_status(response.status).map_err(|_| "fixture PIN rejected")?;
        request.url = format!("{}/assets", session.endpoint);
        request.method = "PUT".into();
        request.body = Some(json!({"ids":[id],"visibility":"locked"}));
        let response: HttpResponse = serde_json::from_value(execute(agent, &request)?)
            .map_err(|_| "fixture stack lock response")?;
        immich::check_status(response.status).map_err(|_| "fixture stack lock rejected".to_owned())
    })();
    request.url = format!("{}/auth/logout", session.endpoint);
    request.method = "POST".into();
    request.body = None;
    let cleanup: HttpResponse =
        serde_json::from_value(execute(agent, &request)?).map_err(|_| "fixture logout response")?;
    immich::check_status(cleanup.status).map_err(|_| "fixture logout rejected")?;
    result
}

fn assert_roster(
    core: &Core<Suwop>,
    key: &AssetKey,
    grant: &str,
    locked: bool,
) -> Result<(), String> {
    let roster = core.view().immich_locked_view;
    assert_eq!(roster.grant_id.as_deref(), Some(grant));
    let entry = roster
        .entries
        .ok_or("same-grant roster")?
        .into_iter()
        .find(|e| e.id == key.asset_id);
    assert_eq!(entry.is_some(), locked);
    if let Some(entry) = entry {
        assert!(entry.visibility_action.can_show_timeline);
        assert!(entry.visibility_action.can_show_archive);
    }
    Ok(())
}
