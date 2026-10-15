//! PIN-unset, API-key-only ordinary archive acceptance against the isolated server.
use super::{execute, fixture_metadata, live_response};
use base64::Engine;
use crux_core::{Command, Core};
use serde_json::{Value, json};
use std::{path::Path, time::Duration};
use suwop_core::{
    app::{Context, Effect, Event, SavedLibrary, ShellOperation, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, TransferFile,
    },
    immich::{self, HttpResponse, Session},
    immich_archive::ImmichArchiveDestination,
    protection::ProtectionScenePhase,
};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const PIXEL: &str = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGMQj179H4YZkDkAm4oMqSLhGnsAAAAASUVORK5CYII=";
#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_pin_unset_archive_roundtrip_preserves_two_albums_and_original() -> Result<(), String> {
    ordinary_roundtrip(FixtureMedia::Image)
}
#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_pin_unset_video_archive_roundtrip_preserves_two_albums_and_original() -> Result<(), String>
{
    ordinary_roundtrip(FixtureMedia::Video)
}
#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_ordinary_selected_motion_preserves_locked_parent() -> Result<(), String> {
    ordinary_roundtrip(FixtureMedia::LinkedMotion)
}
#[derive(Clone, Copy)]
enum FixtureMedia {
    Image,
    Video,
    LinkedMotion,
}
impl FixtureMedia {
    fn name(self) -> &'static str {
        match self {
            Self::Image => "ordinary.png",
            Self::Video => "ordinary.mp4",
            Self::LinkedMotion => "linked-motion.mp4",
        }
    }
    fn role(self) -> ResourceRole {
        match self {
            Self::Image => ResourceRole::Image,
            Self::Video | Self::LinkedMotion => ResourceRole::Video,
        }
    }
    fn bytes(self) -> Result<Vec<u8>, String> {
        match self {
            Self::Image => base64::engine::general_purpose::STANDARD
                .decode(PIXEL)
                .map_err(|_| "pixel".into()),
            Self::Video => Ok(include_bytes!("../fixtures/live_graph/V.mp4").to_vec()),
            Self::LinkedMotion => Ok(include_bytes!("../fixtures/live_graph/M.mp4").to_vec()),
        }
    }
}
fn ordinary_roundtrip(media: FixtureMedia) -> Result<(), String> {
    let directory = std::env::temp_dir().join(format!(
        "suwop-archive-{}-{}",
        std::process::id(),
        media.name()
    ));
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let (session, id, albums) = setup(&agent, &directory, media)?;
    let key = AssetKey {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        asset_id: id,
    };
    let core = super::live_locked_core(session.clone());
    let mut shell = ArchiveShell {
        agent: &agent,
        directory: &directory,
        writes: 0,
        auth_requests: 0,
        diagnostics: ScanDiagnostics::default(),
    };
    activate_archive(&mut shell, &core)?;
    shell.run(
        &core,
        Event::Refresh {
            permission: false,
            now: now()?,
        },
    )?;
    for (index, to) in [
        ImmichArchiveDestination::Archive,
        ImmichArchiveDestination::Timeline,
    ]
    .into_iter()
    .enumerate()
    {
        verify_hint(&core, &key, to, &shell.diagnostics.trace)?;
        super::visibility::wait_for_stable_asset(
            &agent,
            &session.request(&format!("assets/{}", key.asset_id), "GET", None),
            &key,
        )?;
        shell.run(
            &core,
            Event::PrepareImmichArchive {
                key: key.clone(),
                to,
                operation_id: if index == 0 {
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                } else {
                    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                }
                .into(),
                scene_id: SCENE.into(),
            },
        )?;
        assert_eq!(shell.writes, index + 1);
        assert!(!core.view().ordinary_content_keys.contains(&key));
        let state = read_state(&directory)?;
        let operation = state
            .immich_visibility_operations
            .last()
            .ok_or("ordinary journal")?;
        assert_eq!(
            operation.kind,
            suwop_core::immich_visibility::ImmichVisibilityOperationKind::OrdinaryArchive
        );
        assert_eq!(
            operation.outcome,
            suwop_core::apple_visibility::VisibilityOutcome::Applied
        );
        verify_preserved(&agent, &session, &key, &albums, &directory, media)?;
        if matches!(media, FixtureMedia::LinkedMotion) {
            super::live_graph::ordinary_linked_controls(&agent, &session, &directory)?;
        }
        let refresh_trace_start = shell.diagnostics.trace.len();
        shell.run(
            &core,
            Event::Refresh {
                permission: false,
                now: now()?,
            },
        )?;
        assert!(core.view().ordinary_content_keys.contains(&key));
        recover_scan_revision_race(&mut shell, &core, &session, &key, to, refresh_trace_start)?;
    }
    finish_roundtrip(&shell, &agent, &session, &directory, media)
}
fn finish_roundtrip(
    shell: &ArchiveShell<'_>,
    agent: &ureq::Agent,
    session: &Session,
    directory: &Path,
    media: FixtureMedia,
) -> Result<(), String> {
    assert_eq!(shell.auth_requests, 0);
    assert_eq!(shell.writes, 2);
    let journal = serde_json::to_string(&read_state(directory)?).map_err(|_| "journal")?;
    assert!(!journal.contains("password"));
    assert!(!journal.contains("pinCode"));
    if matches!(media, FixtureMedia::LinkedMotion) {
        super::live_graph::verify_ordinary_linked(agent, session, directory)?;
    }
    std::fs::remove_dir_all(directory).map_err(|e| e.to_string())?;
    Ok(())
}
fn recover_scan_revision_race(
    shell: &mut ArchiveShell<'_>,
    core: &Core<Suwop>,
    session: &Session,
    key: &AssetKey,
    applied: ImmichArchiveDestination,
    refresh_trace_start: usize,
) -> Result<(), String> {
    let next = match applied {
        ImmichArchiveDestination::Timeline => ImmichArchiveDestination::Archive,
        ImmichArchiveDestination::Archive => ImmichArchiveDestination::Timeline,
    };
    let view = core.view();
    let hint = view
        .immich_archive_actions
        .iter()
        .find(|a| &a.key == key)
        .ok_or("post-scan hint")?;
    if hint.to.is_none() {
        assert_eq!(
            hint.reason,
            Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unknown)
        );
        let asset = view
            .state
            .snapshots
            .iter()
            .flat_map(|s| &s.assets)
            .find(|a| &a.key == key)
            .ok_or("post-scan asset")?;
        assert_eq!(
            asset.immich_stack,
            suwop_core::domain::ImmichStackState::Unknown
        );
        assert!(asset.inventory_complete);
        assert_eq!(asset.originals().count(), 1);
        let trace = shell
            .diagnostics
            .trace
            .get(refresh_trace_start..)
            .and_then(|trace| trace.last())
            .ok_or("hydration diagnostic")?;
        assert_eq!(trace["api"], "assetMetadata");
        assert_eq!(trace["status"], 200);
        assert_eq!(trace["purpose"], Value::Null);
        assert_eq!(trace["stackShape"], "null");
        for field in [
            "decode",
            "idMatch",
            "ownerIdMatch",
            "checksumMatch",
            "visibilityMatch",
            "notTrashed",
            "searchRevisionParsed",
            "freshRevisionParsed",
        ] {
            assert_eq!(trace[field], true, "{field}: {trace}");
        }
        assert_eq!(trace["updatedAtInstantMatch"], false);
        let writes = shell.writes;
        super::visibility::wait_for_stable_asset(
            shell.agent,
            &session.request(&format!("assets/{}", key.asset_id), "GET", None),
            key,
        )?;
        assert_eq!(shell.writes, writes);
        shell.run(
            core,
            Event::Refresh {
                permission: false,
                now: now()?,
            },
        )?;
        assert_eq!(shell.writes, writes);
    }
    verify_hint(core, key, next, &shell.diagnostics.trace)
}

fn verify_hint(
    core: &Core<Suwop>,
    key: &AssetKey,
    to: ImmichArchiveDestination,
    trace: &[Value],
) -> Result<(), String> {
    let view = core.view();
    let hint = view
        .immich_archive_actions
        .iter()
        .find(|a| &a.key == key)
        .ok_or("ordinary archive hint")?;
    let asset = view
        .state
        .snapshots
        .iter()
        .flat_map(|s| &s.assets)
        .find(|a| &a.key == key)
        .ok_or("ordinary asset")?;
    let scan_access = view
        .state
        .snapshots
        .iter()
        .find(|s| s.assets.iter().any(|a| &a.key == key))
        .map(|s| &s.access);
    assert_eq!(
        hint.to,
        Some(to),
        "reason={:?}, stack={:?}, visibility={:?}, inventoryComplete={}, originals={}, scanAccess={scan_access:?}, safeTrace={trace:?}",
        hint.reason,
        asset.immich_stack,
        asset.immich_visibility,
        asset.inventory_complete,
        asset.originals().count()
    );
    Ok(())
}

fn now() -> Result<f64, String> {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .map_err(|e| e.to_string())
}
fn read_state(directory: &Path) -> Result<SavedLibrary, String> {
    serde_json::from_slice(&std::fs::read(directory.join("state.json")).map_err(|e| e.to_string())?)
        .map_err(|_| "state decode".into())
}
// Raw metadata stays transient in this fixture; only fixed labels and booleans
// enter the assertion trace. Never emit IDs, names, checksums, revisions or headers.
#[derive(Default)]
struct ScanDiagnostics {
    search: Vec<Value>,
    trace: Vec<Value>,
}
impl ScanDiagnostics {
    fn observe(&mut self, request: &immich::HttpRequest, response: &Result<Value, String>) {
        let path = request.url.split("/api/").nth(1).unwrap_or("");
        let Ok(response) = response else {
            self.trace.push(json!({"transportOk":false}));
            return;
        };
        let status = response["status"].as_u64();
        let body = &response["body"];
        if path == "search/metadata" {
            self.search = body["assets"]["items"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            self.trace
                .push(json!({"api":"searchMetadata","method":request.method,"status":status}));
        } else if request.method == "GET"
            && let Some(id) = path.strip_prefix("assets/")
            && !id.contains('/')
            && !id.contains('?')
        {
            let source = self
                .search
                .iter()
                .find(|asset| asset["id"].as_str() == Some(id));
            let decode = serde_json::from_value::<immich::Asset>(body.clone()).is_ok();
            let mut trace = json!({"api":"assetMetadata","status":status,"decode":decode,"stackShape":stack_shape(body),"searchCandidate":source.is_some(),"purpose":request.ordinary_content_authorization.as_ref().map(|a| format!("{:?}",a.purpose))});
            if let Some(source) = source {
                trace["searchStackShape"] = json!(stack_shape(source));
                for field in ["id", "ownerId", "checksum", "updatedAt", "visibility"] {
                    trace[format!("{field}Match")] =
                        json!(source.get(field).is_some() && source.get(field) == body.get(field));
                }
                let parse_revision = |asset: &Value| {
                    asset["updatedAt"]
                        .as_str()
                        .and_then(|revision| chrono::DateTime::parse_from_rfc3339(revision).ok())
                };
                let search_revision = parse_revision(source);
                let fresh_revision = parse_revision(body);
                trace["searchRevisionParsed"] = json!(search_revision.is_some());
                trace["freshRevisionParsed"] = json!(fresh_revision.is_some());
                trace["updatedAtInstantMatch"] = json!(
                    search_revision
                        .zip(fresh_revision)
                        .is_some_and(|(search, fresh)| search == fresh)
                );
                trace["notTrashed"] = json!(body["isTrashed"] == false);
            }
            self.trace.push(trace);
        }
    }
}
fn stack_shape(asset: &Value) -> &'static str {
    match asset.get("stack") {
        None => "absent",
        Some(Value::Null) => "null",
        Some(Value::Object(_)) => "object",
        Some(_) => "other",
    }
}
struct ArchiveShell<'a> {
    agent: &'a ureq::Agent,
    directory: &'a Path,
    writes: usize,
    auth_requests: usize,
    diagnostics: ScanDiagnostics,
}
impl ArchiveShell<'_> {
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        while !effects.is_empty() {
            let Effect::Io(mut effect) = effects.remove(0);
            let result = self.respond(core, &effect.operation);
            effects.extend(
                core.resolve(&mut effect, live_response(result))
                    .map_err(|_| "resolve")?,
            );
        }
        if let Some(error) = core.view().error {
            return Err(error);
        }
        Ok(())
    }
    fn respond(&mut self, core: &Core<Suwop>, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(request) => {
                if request.url.contains("/auth/") {
                    self.auth_requests += 1;
                    return Err("ordinary operation attempted authentication".into());
                }
                if let Some(permit) = &request.immich_archive_authorization {
                    assert_eq!(request.url, permit.url);
                    assert_eq!(request.method, "PUT");
                    assert_eq!(
                        core.view().immich_archive_view.active_operation.as_ref(),
                        Some(permit)
                    );
                    assert!(
                        read_state(self.directory)?
                            .immich_visibility_operations
                            .iter()
                            .any(|o| o.id == permit.operation_id
                                && o.outcome
                                    == suwop_core::apple_visibility::VisibilityOutcome::Unknown)
                    );
                    self.writes += 1;
                }
                let response = execute(self.agent, request);
                self.diagnostics.observe(request, &response);
                response
            }
            ShellOperation::ConfirmImmichArchive { prompt } => {
                assert_ne!(prompt.from, prompt.to);
                assert!(
                    !serde_json::to_string(prompt)
                        .map_err(|_| "prompt")?
                        .contains("album")
                );
                Ok(json!(true))
            }
            ShellOperation::Persist(state) => {
                let path = self.directory.join("state.tmp");
                std::fs::write(&path, serde_json::to_vec(state).map_err(|_| "persist")?)
                    .map_err(|e| e.to_string())?;
                std::fs::rename(path, self.directory.join("state.json"))
                    .map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            ShellOperation::ReadState => {
                serde_json::to_value(read_state(self.directory)?).map_err(|_| "read state".into())
            }
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope: scope.clone(),
                assets: vec![],
                access: ScanAccess::Full,
                scanned_at: Some(now()?),
            })
            .map_err(|_| "scan".into()),
            ShellOperation::Wait { milliseconds } => {
                std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                Ok(Value::Null)
            }
            _ => Err("unexpected archive effect".into()),
        }
    }
}
fn setup(
    agent: &ureq::Agent,
    directory: &Path,
    media: FixtureMedia,
) -> Result<(Session, String, Vec<String>), String> {
    let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "URL")?;
    let key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "key")?;
    let directory = directory.to_path_buf();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = if matches!(media, FixtureMedia::LinkedMotion) {
            super::live_graph::ordinary_linked_setup(&ctx, &address, &key, &directory).await
        } else {
            fixture(&ctx, &address, &key, &directory, media).await
        };
        let (session, status, error) = match result {
            Ok((session, id, albums)) => (
                Some(session),
                json!({"id":id,"albums":albums}).to_string(),
                None,
            ),
            Err(e) => (None, String::new(), Some(e)),
        };
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session,
            status,
            error,
            preview_to_select: None,
        });
    });
    let mut failed_http = None;
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut effect) in effects {
            let result = match &effect.operation {
                ShellOperation::Http(request) => {
                    let response = execute(agent, request);
                    if let Ok(value) = &response
                        && let Some(status) = value["status"].as_u64()
                        && !(200..300).contains(&status)
                    {
                        let route = request
                            .url
                            .split("/api/")
                            .nth(1)
                            .unwrap_or("unknown")
                            .split('?')
                            .next()
                            .unwrap_or("unknown");
                        failed_http =
                            Some(format!("fixture HTTP {} {route}: {status}", request.method));
                    }
                    response
                }
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected setup effect".into()),
            };
            effect
                .resolve(live_response(result))
                .map_err(|_| "setup resolve")?;
        }
    }
    let finished = command.events().last();
    if let Some(Event::Finished {
        error: Some(error), ..
    }) = &finished
    {
        return Err(failed_http.unwrap_or_else(|| error.clone()));
    }
    let Some(Event::Finished {
        session: Some(session),
        status,
        error: None,
        ..
    }) = finished
    else {
        return Err(failed_http
            .unwrap_or_else(|| "PIN-unset fixture setup failed without HTTP error".into()));
    };
    let value: Value = serde_json::from_str(&status).map_err(|_| "setup decode")?;
    Ok((
        session,
        value["id"].as_str().ok_or("setup id")?.into(),
        serde_json::from_value(value["albums"].clone()).map_err(|_| "setup albums")?,
    ))
}
async fn pin_unset_session(
    ctx: &Context,
    admin: &Session,
    suffix: &str,
) -> Result<Session, String> {
    let email = format!("archive-{}-{suffix}@example.invalid", std::process::id());
    let password = "ArchiveFixtureOnly123!";
    let _: Value = admin
        .json(
            ctx,
            "admin/users",
            "POST",
            Some(json!({"email":email,"password":password,"name":"Archive fixture"})),
        )
        .await?;
    let mut login = admin.request(
        "auth/login",
        "POST",
        Some(json!({"email":email,"password":password})),
    );
    login.headers.remove("x-api-key");
    let response: HttpResponse = suwop_core::app::io(ctx, ShellOperation::Http(login)).await?;
    immich::check_status(response.status)?;
    let token = response.body["accessToken"].as_str().ok_or("setup token")?;
    let mut request = admin.request("auth/status", "GET", None);
    request.headers.remove("x-api-key");
    request
        .headers
        .insert("Authorization".into(), format!("Bearer {token}"));
    let status: HttpResponse =
        suwop_core::app::io(ctx, ShellOperation::Http(request.clone())).await?;
    immich::check_status(status.status)?;
    assert_eq!(status.body["pinCode"], false);
    request.url = format!("{}/api-keys", admin.endpoint);
    request.method = "POST".into();
    request.body = Some(json!({"name":"Archive fixture","permissions":["all"]}));
    let response: HttpResponse =
        suwop_core::app::io(ctx, ShellOperation::Http(request.clone())).await?;
    immich::check_status(response.status)?;
    let key = response.body["secret"]
        .as_str()
        .ok_or("setup API key")?
        .to_owned();
    request.url = format!("{}/auth/logout", admin.endpoint);
    request.body = None;
    let logout: HttpResponse = suwop_core::app::io(ctx, ShellOperation::Http(request)).await?;
    immich::check_status(logout.status)?;
    immich::connect(ctx, &admin.endpoint, &key, true).await
}
async fn fixture(
    ctx: &Context,
    address: &str,
    key: &str,
    directory: &Path,
    media: FixtureMedia,
) -> Result<(Session, String, Vec<String>), String> {
    let admin = immich::connect(ctx, address, key, true)
        .await
        .map_err(|_| "fixture admin connect")?;
    let session = pin_unset_session(ctx, &admin, media.name())
        .await
        .map_err(|_| "fixture new user/session")?;
    let bytes = media.bytes()?;
    let path = directory.join(media.name());
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    let resource = PhotoResource {
        id: "ordinary".into(),
        name: media.name().into(),
        role: media.role(),
        sha1: None,
        bytes: Some(bytes.len() as u64),
    };
    let file = TransferFile {
        resource: resource.clone(),
        path: path.to_string_lossy().into_owned(),
        signature: FileSignature {
            sha256: {
                use sha2::Digest;
                suwop_core::domain::hex(&sha2::Sha256::digest(&bytes))
            },
            bytes: bytes.len() as u64,
        },
    };
    let metadata = fixture_metadata(resource, 0, 1_780_000_000.0);
    let id = session
        .upload(ctx, &file, &metadata, now()?, None)
        .await
        .map_err(|_| "fixture upload")?;
    let mut albums = vec![];
    for title in ["Archive owned first", "Archive owned second"] {
        let album = session
            .create_album(ctx, title)
            .await
            .map_err(|_| "fixture create album")?;
        session
            .change_album_members(ctx, &album.id, std::slice::from_ref(&id), true)
            .await
            .map_err(|_| "fixture album members")?;
        albums.push(album.id);
    }
    Ok((session, id, albums))
}
fn verify_preserved(
    agent: &ureq::Agent,
    session: &Session,
    key: &AssetKey,
    albums: &[String],
    directory: &Path,
    media: FixtureMedia,
) -> Result<(), String> {
    let response: HttpResponse = serde_json::from_value(execute(
        agent,
        &session.request(&format!("albums?assetId={}", key.asset_id), "GET", None),
    )?)
    .map_err(|_| "albums")?;
    immich::check_status(response.status)?;
    for album in albums {
        assert!(
            response
                .body
                .as_array()
                .ok_or("album memberships")?
                .iter()
                .any(|a| a["id"].as_str() == Some(album))
        );
    }
    let mut request = session.request(
        &format!("assets/{}/original?edited=false", key.asset_id),
        "GET",
        None,
    );
    let path = directory.join("readback.png");
    request.download_path = Some(path.to_string_lossy().into_owned());
    let response: HttpResponse =
        serde_json::from_value(execute(agent, &request)?).map_err(|_| "original")?;
    immich::check_status(response.status)?;
    assert_eq!(
        std::fs::read(path).map_err(|e| e.to_string())?,
        media.bytes()?
    );
    Ok(())
}

fn activate_archive(shell: &mut ArchiveShell<'_>, core: &Core<Suwop>) -> Result<(), String> {
    shell.run(
        core,
        Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    shell.run(
        core,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )
}
