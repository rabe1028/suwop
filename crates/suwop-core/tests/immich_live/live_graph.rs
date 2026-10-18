//! API-linked graph observations, not Apple Live Photo or product mutation parity.
use super::{execute, fixture_metadata, live_response};
use base64::Engine;
use crux_core::Command;
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use std::{collections::BTreeSet, path::Path, time::Duration};
use suwop_core::{
    app::{Context, Effect, Event, SavedLibrary, ShellOperation},
    domain::{FileSignature, PhotoResource, ResourceRole, TransferFile},
    immich::{self, HttpRequest, HttpResponse, Session},
};

#[path = "live_graph/ordinary_linked.rs"]
mod ordinary_linked;
pub(super) use ordinary_linked::{
    ordinary_linked_controls, ordinary_linked_setup, verify_ordinary_linked,
};

#[path = "live_graph/native_metadata.rs"]
mod native_metadata;
#[path = "live_graph/native_motion.rs"]
mod native_motion;
use native_metadata::metadata_ready;
pub(super) use native_motion::{native_motion_controls, native_motion_setup, native_pair_bytes};

#[path = "live_graph/ordinary_parent.rs"]
mod ordinary_parent;
pub(super) use ordinary_parent::{
    native_parent_probe, ordinary_native_parent_setup, ordinary_parent_controls,
    ordinary_parent_setup,
};

#[path = "live_graph/selected_recovery.rs"]
mod selected_recovery;

#[path = "live_graph/write_contract.rs"]
mod write_contract;
pub(super) use write_contract::{
    native_cid_after_unlock, native_cid_before_product, native_cid_denied, native_cid_observe,
    native_cid_setup,
};

#[path = "live_graph/derivative_headers.rs"]
mod derivative_headers;

#[path = "live_graph/private_video.rs"]
mod private_video;

#[path = "live_graph/ordinary_selected_read.rs"]
mod ordinary_selected_read;

const PIN: &str = "123456";
const V: &[u8] = include_bytes!("../fixtures/live_graph/V.mp4");
const M: &[u8] = include_bytes!("../fixtures/live_graph/M.mp4");

#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_api_linked_video_graph_observations_preserve_originals() -> Result<(), String> {
    let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "fixture URL")?;
    let key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "fixture API key")?;
    let directory = std::env::temp_dir().join(format!("suwop-live-graph-{}", std::process::id()));
    std::fs::create_dir_all(&directory).map_err(|_| "fixture directory")?;
    let work = directory.clone();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = Box::pin(exercise(&ctx, &address, &key, &work)).await;
        let (status, error) = match result {
            Ok(report) => (report.to_string(), None),
            Err(error) => (String::new(), Some(error)),
        };
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status,
            error,
            preview_to_select: None,
        });
    });
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut effect) in effects {
            let response = match &effect.operation {
                ShellOperation::Http(request) => execute(&agent, request),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected graph fixture effect".into()),
            };
            effect
                .resolve(live_response(response))
                .map_err(|_| "graph resolve")?;
        }
    }
    let result = match command.events().last() {
        Some(Event::Finished {
            status,
            error: None,
            ..
        }) => {
            let report = directory.with_extension("report.json");
            std::fs::write(report, status).map_err(|_| String::from("graph report"))
        }
        Some(Event::Finished {
            error: Some(error), ..
        }) => Err(error),
        _ => Err("graph fixture missing completion".into()),
    };
    std::fs::remove_dir_all(directory).map_err(|_| "fixture directory cleanup")?;
    result
}

// This fixture-only session is never persisted, published or Debug formatted.
struct Elevated {
    ordinary: Session,
    token: String,
}
impl Elevated {
    fn request(&self, path: &str, method: &str, body: Option<Value>) -> HttpRequest {
        let mut request = self.ordinary.request(path, method, body);
        request.headers.remove("x-api-key");
        request
            .headers
            .insert("Authorization".into(), format!("Bearer {}", self.token));
        request
    }
    async fn json(
        &self,
        ctx: &Context,
        path: &str,
        method: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        checked(ctx, self.request(path, method, body)).await
    }
    async fn unlock(&self, ctx: &Context) -> Result<(), String> {
        self.json(
            ctx,
            "auth/session/unlock",
            "POST",
            Some(json!({"pinCode":PIN})),
        )
        .await?;
        let status = self.json(ctx, "auth/status", "GET", None).await?;
        assert_eq!(status["isElevated"], true);
        Ok(())
    }
}
async fn response(ctx: &Context, request: HttpRequest) -> Result<HttpResponse, String> {
    let label = operation_label(&request);
    suwop_core::app::io(ctx, ShellOperation::Http(request))
        .await
        .map_err(|_| format!("{label} transport failure"))
}
async fn checked(ctx: &Context, request: HttpRequest) -> Result<Value, String> {
    let label = operation_label(&request);
    let response = response(ctx, request).await?;
    if !(200..300).contains(&response.status) {
        return Err(format!("{label} HTTP {}", response.status));
    }
    Ok(response.body)
}
fn operation_label(request: &HttpRequest) -> &'static str {
    let path = request.url.split("/api/").nth(1).unwrap_or("");
    match path {
        "auth/login" => "fixture login",
        "auth/status" => "fixture auth status",
        "auth/pin-code" => "fixture PIN setup",
        "auth/session/unlock" => "fixture PIN unlock",
        "auth/session/lock" => "fixture session lock",
        "auth/logout" => "fixture logout",
        "admin/users" => "fixture user creation",
        "api-keys" => "fixture API key creation",
        "search/metadata" => "fixture catalog scan",
        "assets" if request.method == "PUT" => "fixture visibility write",
        "assets" => "fixture upload",
        "stacks" => "fixture stack creation",
        _ if path.starts_with("albums") => "fixture album metadata",
        _ if path.ends_with("/original?edited=false") => "fixture original read",
        _ if path.starts_with("assets/") => "fixture asset detail",
        _ => "fixture HTTP operation",
    }
}

async fn setup(ctx: &Context, address: &str, key: &str) -> Result<Elevated, String> {
    setup_named(ctx, address, key, "graph").await
}
async fn setup_named(
    ctx: &Context,
    address: &str,
    key: &str,
    prefix: &str,
) -> Result<Elevated, String> {
    let admin = immich::connect(ctx, address, key, true).await?;
    let email = format!("{prefix}-{}@example.invalid", std::process::id());
    let password = "GraphFixtureOnly123!";
    admin
        .json::<Value>(
            ctx,
            "admin/users",
            "POST",
            Some(json!({"email":email,"password":password,"name":"Synthetic graph fixture"})),
        )
        .await?;
    let mut login = admin.request(
        "auth/login",
        "POST",
        Some(json!({"email":email,"password":password})),
    );
    login.headers.remove("x-api-key");
    let body = checked(ctx, login).await?;
    let token = body["accessToken"]
        .as_str()
        .ok_or("graph login token absent")?
        .to_owned();
    let bootstrap = Elevated {
        ordinary: admin,
        token,
    };
    bootstrap
        .json(ctx, "auth/pin-code", "POST", Some(json!({"pinCode":PIN})))
        .await?;
    let api_key = bootstrap
        .json(
            ctx,
            "api-keys",
            "POST",
            Some(json!({"name":"Synthetic graph fixture","permissions":["all"]})),
        )
        .await?;
    let ordinary = immich::connect(
        ctx,
        address,
        api_key["secret"].as_str().ok_or("graph API key absent")?,
        true,
    )
    .await?;
    let session = Elevated {
        ordinary,
        token: bootstrap.token,
    };
    session.unlock(ctx).await?;
    Ok(session)
}
#[derive(serde::Serialize, serde::Deserialize)]
struct Graph {
    video: String,
    motion: String,
    parent: String,
    other_parent: String,
    peer: String,
}
async fn upload(
    ctx: &Context,
    session: &Session,
    directory: &Path,
    name: &str,
    bytes: &[u8],
    role: ResourceRole,
    motion: Option<&str>,
) -> Result<String, String> {
    let path = directory.join(name);
    std::fs::write(&path, bytes).map_err(|_| "graph media write")?;
    let resource = PhotoResource {
        id: name.into(),
        name: name.into(),
        role,
        sha1: None,
        bytes: Some(bytes.len() as u64),
    };
    let file = TransferFile {
        resource: resource.clone(),
        path: path.to_string_lossy().into_owned(),
        signature: FileSignature {
            sha256: format!("{:x}", sha2::Sha256::digest(bytes)),
            bytes: bytes.len() as u64,
        },
    };
    let mut metadata = fixture_metadata(resource, 0, 1_780_000_000.0);
    metadata.captured_at = None;
    metadata.modified_at = None;
    let (id, created) = session
        .create_upload(ctx, &file, &metadata, 1_780_000_000.0, motion)
        .await?;
    assert!(
        created,
        "fixture bytes must be distinct, never silently deduplicate"
    );
    Ok(id)
}
async fn graph(ctx: &Context, session: &Elevated, directory: &Path) -> Result<Graph, String> {
    let ordinary = &session.ordinary;
    let video = upload(
        ctx,
        ordinary,
        directory,
        "V.mp4",
        V,
        ResourceRole::Video,
        None,
    )
    .await?;
    let motion = upload(
        ctx,
        ordinary,
        directory,
        "M.mp4",
        M,
        ResourceRole::Video,
        None,
    )
    .await?;
    let mut images = Vec::new();
    for (index, name) in ["P.png", "P2.png", "Q.png"].into_iter().enumerate() {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(super::PIXELS[index])
            .map_err(|_| "graph PNG")?;
        images.push(
            upload(
                ctx,
                ordinary,
                directory,
                name,
                &bytes,
                ResourceRole::Image,
                (index < 2).then_some(motion.as_str()),
            )
            .await?,
        );
    }
    let graph = Graph {
        video,
        motion,
        parent: images[0].clone(),
        other_parent: images[1].clone(),
        peer: images[2].clone(),
    };
    for parent in [&graph.parent, &graph.other_parent] {
        let asset = detail(ctx, session, parent).await?;
        assert_eq!(
            asset["livePhotoVideoId"].as_str(),
            Some(graph.motion.as_str())
        );
        assert_eq!(asset["ownerId"].as_str(), Some(ordinary.user_id.as_str()));
        assert_eq!(asset["type"], "IMAGE");
    }
    let motion = detail(ctx, session, &graph.motion).await?;
    assert_eq!(motion["type"], "VIDEO");
    assert_eq!(motion["visibility"], "hidden");
    // Deliberately do not infer reverse independence from this forward null.
    assert!(motion["livePhotoVideoId"].is_null());
    Ok(graph)
}
async fn detail(ctx: &Context, session: &Elevated, id: &str) -> Result<Value, String> {
    session
        .json(ctx, &format!("assets/{id}"), "GET", None)
        .await
}
async fn transition(ctx: &Context, request: HttpRequest) -> Result<(), String> {
    checked(ctx, request).await.map(|_| ())
}
async fn visibility(
    ctx: &Context,
    session: &Elevated,
    ids: &[&str],
    to: &str,
) -> Result<(), String> {
    session.unlock(ctx).await?;
    transition(
        ctx,
        session.request("assets", "PUT", Some(json!({"ids":ids,"visibility":to}))),
    )
    .await
}
async fn original(
    ctx: &Context,
    mut request: HttpRequest,
    directory: &Path,
    name: &str,
    expected: &[u8],
) -> Result<u16, String> {
    let path = directory.join(name);
    request.download_path = Some(path.to_string_lossy().into_owned());
    let response = response(ctx, request).await?;
    if (200..300).contains(&response.status) {
        let actual = std::fs::read(path).map_err(|_| "graph original readback")?;
        assert_eq!(actual.len(), expected.len());
        assert_eq!(actual, expected, "original bytes must be unchanged");
    }
    Ok(response.status)
}
async fn preserve_originals(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    directory: &Path,
) -> Result<(), String> {
    for (id, bytes, label) in [(&graph.video, V, "V"), (&graph.motion, M, "M")] {
        let status = original(
            ctx,
            session.request(&format!("assets/{id}/original?edited=false"), "GET", None),
            directory,
            label,
            bytes,
        )
        .await?;
        assert_eq!(status, 200);
    }
    for (index, id) in [&graph.parent, &graph.other_parent, &graph.peer]
        .into_iter()
        .enumerate()
    {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(super::PIXELS[index])
            .map_err(|_| "graph PNG")?;
        assert_eq!(
            original(
                ctx,
                session.request(&format!("assets/{id}/original?edited=false"), "GET", None),
                directory,
                "image",
                &bytes
            )
            .await?,
            200
        );
    }
    Ok(())
}
async fn albums(ctx: &Context, session: &Session, id: &str) -> Result<Vec<String>, String> {
    let mut ids = Vec::new();
    for title in ["Synthetic graph first", "Synthetic graph second"] {
        let album = session.create_album(ctx, title).await?;
        session
            .change_album_members(ctx, &album.id, &[id.to_owned()], true)
            .await?;
        ids.push(album.id);
    }
    Ok(ids)
}
async fn assert_membership(
    ctx: &Context,
    session: &Elevated,
    id: &str,
    known: &[String],
    expected: bool,
) -> Result<(), String> {
    let value = session
        .json(ctx, &format!("albums?assetId={id}"), "GET", None)
        .await?;
    let current = value.as_array().ok_or("graph album response")?;
    for id in known {
        assert_eq!(
            current
                .iter()
                .any(|a| a["id"].as_str() == Some(id.as_str())),
            expected
        );
    }
    Ok(())
}
async fn scan(ctx: &Context, session: &Elevated, elevated: bool) -> Result<Vec<Value>, String> {
    let mut items = Vec::new();
    let mut cursor = None;
    let mut seen = BTreeSet::new();
    for _ in 0..10_000 {
        let mut body = json!({"size":100,"withStacked":true,"filter":{"visibility":{"in":["timeline","archive","hidden","locked"]}},"orderBy":{"field":"fileCreatedAt","direction":"desc"}});
        if !elevated {
            body["filter"]["visibility"]["in"] = json!(["timeline", "archive", "hidden"]);
        }
        if let Some(cursor) = &cursor {
            body["cursor"] = json!(cursor);
        }
        let request = if elevated {
            session.request("search/metadata", "POST", Some(body))
        } else {
            session
                .ordinary
                .request("search/metadata", "POST", Some(body))
        };
        let value = checked(ctx, request).await?;
        items.extend(
            value["assets"]["items"]
                .as_array()
                .ok_or("graph search items")?
                .iter()
                .cloned(),
        );
        match value["assets"].get("nextCursor") {
            Some(Value::Null) => return Ok(items),
            Some(Value::String(next)) if !next.is_empty() && seen.insert(next.clone()) => {
                cursor = Some(next.clone());
            }
            _ => return Err("graph search cursor malformed or repeated".into()),
        }
    }
    Err("graph search safety bound".into())
}
async fn observe_catalog(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
) -> Result<Value, String> {
    let denied_search = response(ctx,session.ordinary.request("search/metadata","POST",Some(json!({"size":100,"filter":{"visibility":{"in":["timeline","archive","hidden","locked"]}}})))).await?;
    assert_eq!(denied_search.status, 401);
    let listed = scan(ctx, session, true).await?;
    let ordinary = scan(ctx, session, false).await?;
    let parent_locked = detail(ctx, session, &graph.parent).await?["visibility"] == "locked";
    assert_eq!(
        ordinary
            .iter()
            .any(|a| a["id"].as_str() == Some(graph.parent.as_str())),
        !parent_locked
    );
    let parents = listed
        .iter()
        .filter(|a| a["livePhotoVideoId"].as_str() == Some(graph.motion.as_str()))
        .collect::<Vec<_>>();
    // This asserts only known fixture edges. It is NOT a universal absence proof.
    assert!(
        parents
            .iter()
            .any(|a| a["id"].as_str() == Some(graph.parent.as_str()))
    );
    assert!(
        parents
            .iter()
            .any(|a| a["id"].as_str() == Some(graph.other_parent.as_str()))
    );
    Ok(
        json!({"ordinaryLockedFilterStatus":denied_search.status,"ordinaryFilter":["timeline","archive","hidden"],"elevatedFilter":["timeline","archive","hidden","locked"],"ordinaryKnownParentListed":ordinary.iter().any(|a|a["id"].as_str()==Some(graph.parent.as_str())),"ordinaryKnownMotionListed":ordinary.iter().any(|a|a["id"].as_str()==Some(graph.motion.as_str())),"ordinaryKnownVideoListed":ordinary.iter().any(|a|a["id"].as_str()==Some(graph.video.as_str())),"knownParentsListed":true,"knownMotionListed":listed.iter().any(|a| a["id"].as_str()==Some(graph.motion.as_str())),"knownVideoListed":listed.iter().any(|a|a["id"].as_str()==Some(graph.video.as_str()))}),
    )
}
async fn observe_resources(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    phase: &str,
    parent_albums: &[String],
) -> Result<Value, String> {
    let mut resources = Vec::new();
    for (role, id) in [
        ("V", &graph.video),
        ("M", &graph.motion),
        ("P", &graph.parent),
        ("P2", &graph.other_parent),
        ("Q", &graph.peer),
    ] {
        let asset = detail(ctx, session, id).await?;
        let bytes = match role {
            "V" => V.to_vec(),
            "M" => M.to_vec(),
            "P" => png(0)?,
            "P2" => png(1)?,
            _ => png(2)?,
        };
        let checksum = format!("{:x}", Sha1::digest(&bytes));
        let checksum_matches = suwop_core::domain::normalize_sha1(asset["checksum"].as_str())
            .as_deref()
            == Some(checksum.as_str());
        assert!(
            checksum_matches,
            "each resource must retain its original identity"
        );
        assert_eq!(asset["id"].as_str(), Some(id.as_str()));
        assert_eq!(
            asset["ownerId"].as_str(),
            Some(session.ordinary.user_id.as_str())
        );
        assert_eq!(
            asset["type"],
            if matches!(role, "V" | "M") {
                "VIDEO"
            } else {
                "IMAGE"
            }
        );
        if matches!(role, "P" | "P2") {
            assert_eq!(
                asset["livePhotoVideoId"].as_str(),
                Some(graph.motion.as_str())
            );
        } else {
            assert!(asset["livePhotoVideoId"].is_null());
        }
        let revision = asset["updatedAt"]
            .as_str()
            .filter(|r| !r.is_empty())
            .ok_or("graph revision absent")?;
        let memberships = session
            .json(ctx, &format!("albums?assetId={id}"), "GET", None)
            .await?;
        let memberships = memberships.as_array().ok_or("graph memberships")?;
        resources.push(json!({"role":role,"fixtureAssetID":id,"updatedAt":revision,"checksumMatchesOriginal":checksum_matches,"ownerMatches":asset["ownerId"].as_str()==Some(session.ordinary.user_id.as_str()),"type":asset["type"],"visibility":asset["visibility"],"forwardMotionMatches":asset["livePhotoVideoId"].as_str()==Some(graph.motion.as_str()),"forwardMotionNull":asset["livePhotoVideoId"].is_null(),"stackKnown":asset.get("stack").is_some(),"stackPresent":asset["stack"].is_object(),"knownOwnedAlbumIDsPresent":parent_albums.iter().filter(|known| memberships.iter().any(|a|a["id"].as_str()==Some(known.as_str()))).collect::<Vec<_>>() }));
    }
    Ok(json!({"phase":phase,"resources":resources}))
}

fn png(index: usize) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(super::PIXELS[index])
        .map_err(|_| "graph PNG".into())
}
async fn assert_ordinary_accessible(
    ctx: &Context,
    session: &Elevated,
    id: &str,
    expected_visibility: &str,
) -> Result<(), String> {
    let ordinary = response(
        ctx,
        session
            .ordinary
            .request(&format!("assets/{id}"), "GET", None),
    )
    .await?;
    assert_eq!(ordinary.status, 200);
    assert_eq!(ordinary.body["id"].as_str(), Some(id));
    assert_eq!(
        ordinary.body["ownerId"].as_str(),
        Some(session.ordinary.user_id.as_str())
    );
    assert_eq!(ordinary.body["visibility"], expected_visibility);
    Ok(())
}

async fn video_transitions(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    known: &[String],
    directory: &Path,
    known_albums: &[String],
    observations: &mut Vec<Value>,
) -> Result<(), String> {
    assert_ordinary_accessible(ctx, session, &graph.video, "timeline").await?;
    for to in ["archive", "timeline"] {
        transition(
            ctx,
            session.ordinary.request(
                "assets",
                "PUT",
                Some(json!({"ids":[graph.video],"visibility":to})),
            ),
        )
        .await?;
        assert_eq!(detail(ctx, session, &graph.video).await?["visibility"], to);
        assert_membership(ctx, session, &graph.video, known, true).await?;
        observations.push(
            observe_resources(
                ctx,
                session,
                graph,
                &format!("video-ordinary-{to}"),
                known_albums,
            )
            .await?,
        );
    }
    preserve_originals(ctx, session, graph, directory).await?;
    visibility(ctx, session, &[&graph.video], "locked").await?;
    observations.push(observe_resources(ctx, session, graph, "video-locked", known_albums).await?);
    preserve_originals(ctx, session, graph, directory).await?;
    let denied = response(
        ctx,
        session
            .ordinary
            .request(&format!("assets/{}", graph.video), "GET", None),
    )
    .await?;
    // v3.2.4 requireAccess rejects inaccessible asset IDs with BadRequest (400).
    assert_eq!(denied.status, 400);
    assert_membership(ctx, session, &graph.video, known, false).await?;
    for to in ["archive", "timeline"] {
        visibility(ctx, session, &[&graph.video], to).await?;
        assert_eq!(detail(ctx, session, &graph.video).await?["visibility"], to);
        assert_membership(ctx, session, &graph.video, known, false).await?;
        observations.push(
            observe_resources(
                ctx,
                session,
                graph,
                &format!("video-explicit-unlock-{to}"),
                known_albums,
            )
            .await?,
        );
    }
    Ok(())
}

async fn exercise(
    ctx: &Context,
    address: &str,
    key: &str,
    directory: &Path,
) -> Result<Value, String> {
    let session = setup(ctx, address, key).await?;
    let result = Box::pin(scenario(ctx, &session, directory)).await;
    // Attempt logout even if lock fails; no cleanup acknowledgement on failure.
    let lock = response(ctx, session.request("auth/session/lock", "POST", None)).await;
    let logout = response(ctx, session.request("auth/logout", "POST", None)).await;
    let lock_ok = lock.is_ok_and(|r| (200..300).contains(&r.status));
    let logout_ok = logout.is_ok_and(|r| (200..300).contains(&r.status));
    let mut report = result?;
    report["remoteLockConfirmed"] = json!(lock_ok);
    report["logoutConfirmed"] = json!(logout_ok);
    assert!(lock_ok && logout_ok, "fixture cleanup must be acknowledged");
    Ok(report)
}
async fn parent_only_lock(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    directory: &Path,
    parent_albums: &[String],
) -> Result<(u16, Value), String> {
    assert_ordinary_accessible(ctx, session, &graph.parent, "timeline").await?;
    visibility(ctx, session, &[&graph.parent], "locked").await?;
    assert_eq!(
        detail(ctx, session, &graph.parent).await?["visibility"],
        "locked"
    );
    assert_eq!(
        detail(ctx, session, &graph.motion).await?["visibility"],
        "hidden"
    );
    assert_eq!(
        detail(ctx, session, &graph.other_parent).await?["visibility"],
        "timeline"
    );
    assert_membership(ctx, session, &graph.parent, parent_albums, false).await?;
    let denied = response(
        ctx,
        session
            .ordinary
            .request(&format!("assets/{}", graph.parent), "GET", None),
    )
    .await?;
    // v3.2.4 requireAccess rejects inaccessible asset IDs with BadRequest (400).
    assert_eq!(denied.status, 400);
    let motion_status = original(
        ctx,
        session.ordinary.request(
            &format!("assets/{}/original?edited=false", graph.motion),
            "GET",
            None,
        ),
        directory,
        "motion-ordinary",
        M,
    )
    .await?;
    // Observed v3.2.4: locking only the IMAGE does not protect its hidden motion original.
    assert_eq!(motion_status, 200);
    let while_locked = observe_catalog(ctx, session, graph).await?;
    Ok((motion_status, while_locked))
}
async fn pair_transitions(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    parent_albums: &[String],
    directory: &Path,
    known_albums: &[String],
    observations: &mut Vec<Value>,
) -> Result<(), String> {
    visibility(ctx, session, &[&graph.parent], "archive").await?;
    assert_membership(ctx, session, &graph.parent, parent_albums, false).await?;
    visibility(ctx, session, &[&graph.parent, &graph.motion], "locked").await?;
    for id in [&graph.parent, &graph.motion] {
        assert_eq!(detail(ctx, session, id).await?["visibility"], "locked");
    }
    let other_parent = detail(ctx, session, &graph.other_parent).await?;
    assert_eq!(
        other_parent["visibility"], "timeline",
        "locking the supplied pair must not change the unsupplied parent's visibility"
    );
    assert_eq!(
        other_parent["livePhotoVideoId"].as_str(),
        Some(graph.motion.as_str()),
        "the unsupplied parent must retain its forward link to the motion asset"
    );
    observations.push(
        observe_resources(
            ctx,
            session,
            graph,
            "pair-supplied-ids-locked",
            known_albums,
        )
        .await?,
    );
    preserve_originals(ctx, session, graph, directory).await?;
    Ok(())
}
async fn parent_archive_roundtrips(
    ctx: &Context,
    session: &Elevated,
    graph: &Graph,
    parent_albums: &[String],
    known_albums: &[String],
    observations: &mut Vec<Value>,
) -> Result<(), String> {
    for to in ["archive", "timeline"] {
        transition(
            ctx,
            session.ordinary.request(
                "assets",
                "PUT",
                Some(json!({"ids":[graph.parent],"visibility":to})),
            ),
        )
        .await?;
        assert_eq!(detail(ctx, session, &graph.parent).await?["visibility"], to);
        assert_eq!(
            detail(ctx, session, &graph.motion).await?["visibility"],
            "hidden"
        );
        assert_membership(ctx, session, &graph.parent, parent_albums, true).await?;
        observations.push(
            observe_resources(
                ctx,
                session,
                graph,
                &format!("parent-ordinary-{to}"),
                known_albums,
            )
            .await?,
        );
    }
    Ok(())
}
async fn scenario(ctx: &Context, session: &Elevated, directory: &Path) -> Result<Value, String> {
    let graph = Box::pin(graph(ctx, session, directory)).await?;
    preserve_originals(ctx, session, &graph, directory).await?;
    let video_albums = albums(ctx, &session.ordinary, &graph.video).await?;
    let parent_albums = albums(ctx, &session.ordinary, &graph.parent).await?;
    let known_albums = parent_albums
        .iter()
        .chain(&video_albums)
        .cloned()
        .collect::<Vec<_>>();
    let mut observations =
        vec![observe_resources(ctx, session, &graph, "initial-linked", &known_albums).await?];
    video_transitions(
        ctx,
        session,
        &graph,
        &video_albums,
        directory,
        &known_albums,
        &mut observations,
    )
    .await?;

    parent_archive_roundtrips(
        ctx,
        session,
        &graph,
        &parent_albums,
        &known_albums,
        &mut observations,
    )
    .await?;
    observations.push(
        observe_resources(
            ctx,
            session,
            &graph,
            "after-ordinary-archive-roundtrips",
            &known_albums,
        )
        .await?,
    );
    preserve_originals(ctx, session, &graph, directory).await?;
    let before_stack = observe_catalog(ctx, session, &graph).await?;
    session
        .ordinary
        .json::<Value>(
            ctx,
            "stacks",
            "POST",
            Some(json!({"assetIds":[graph.parent,graph.peer]})),
        )
        .await?;
    assert!(detail(ctx, session, &graph.parent).await?["stack"].is_object());
    let (motion_status, while_locked) =
        parent_only_lock(ctx, session, &graph, directory, &parent_albums).await?;
    preserve_originals(ctx, session, &graph, directory).await?;
    observations
        .push(observe_resources(ctx, session, &graph, "parent-only-locked", &known_albums).await?);
    pair_transitions(
        ctx,
        session,
        &graph,
        &parent_albums,
        directory,
        &known_albums,
        &mut observations,
    )
    .await?;
    preserve_originals(ctx, session, &graph, directory).await?;
    visibility(ctx, session, &[&graph.parent], "timeline").await?;
    visibility(ctx, session, &[&graph.motion], "archive").await?;
    assert_eq!(
        detail(ctx, session, &graph.parent).await?["visibility"],
        "timeline"
    );
    assert_eq!(
        detail(ctx, session, &graph.motion).await?["visibility"],
        "archive"
    );
    assert_eq!(
        detail(ctx, session, &graph.other_parent).await?["livePhotoVideoId"].as_str(),
        Some(graph.motion.as_str())
    );
    assert_membership(ctx, session, &graph.parent, &parent_albums, false).await?;
    preserve_originals(ctx, session, &graph, directory).await?;
    observations.push(
        observe_resources(
            ctx,
            session,
            &graph,
            "split-explicit-unlock-destinations",
            &known_albums,
        )
        .await?,
    );
    Ok(
        json!({"fixtureOwnerID":session.ordinary.user_id,"fixtureMotionID":graph.motion,"knownOwnedParentAlbumIDs":parent_albums,"knownOwnedVideoAlbumIDs":video_albums,"observations":observations,"apiLinkedNotAppleLive":true,"multipleParentsAccepted":true,"originalsVerified":true,"ordinaryVideoArchivePreservesOwnedAlbums":true,"parentOnlyLockMotionVisibility":"hidden","parentOnlyLockOrdinaryMotionOriginalStatus":motion_status,"beforeStack":before_stack,"whileParentLocked":while_locked,"graphAtomicityProven":false,"reverseAbsenceProven":false,"productMutationSupportClaimed":false}),
    )
}

#[path = "live_graph/selected_video_fixture.rs"]
pub(super) mod selected_video_fixture;

fn drive_setup(agent: &ureq::Agent, command: &mut Command<Effect, Event>) -> Result<(), String> {
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            return Ok(());
        }
        for Effect::Io(mut request) in effects {
            let result = match &request.operation {
                ShellOperation::Http(http) => execute(agent, http),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected external video setup effect".into()),
            };
            request
                .resolve(live_response(result))
                .map_err(|_| "video setup resolve")?;
        }
    }
}

#[path = "live_graph/private_live.rs"]
mod private_live;
