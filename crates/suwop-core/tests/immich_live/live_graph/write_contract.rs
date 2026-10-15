//! Real native-CID write-contract controls; external setup/observers are not product effects.
use super::*;
#[path = "write_contract_queue.rs"]
mod queue;
pub(in super::super) use queue::native_cid_before_product;
use queue::{metadata_stamp, observe_quiet};

pub(in super::super) async fn native_cid_setup(
    ctx: &Context,
    address: &str,
    key: &str,
    root: &Path,
) -> Result<(Session, String, String), String> {
    let session = setup_named(ctx, address, key, "native-cid-image").await?;
    ordinary_parent::write_contract_native_setup(ctx, &session.ordinary, root).await?;
    let control = control(root)?;
    verify_native_cid(&session.ordinary, root, &control)?;
    let parent = control["parent"].as_str().ok_or("CID parent")?;
    let unlinked: Value = session
        .ordinary
        .json(
            ctx,
            &format!("assets/{parent}"),
            "PUT",
            Some(json!({"livePhotoVideoId":null})),
        )
        .await?;
    assert_eq!(unlinked["id"], parent);
    assert_eq!(unlinked.get("livePhotoVideoId"), Some(&Value::Null));
    // onAfterUnlink may change motion visibility: only the following snapshot is baseline.
    for album in control["albums"].as_array().ok_or("CID albums")? {
        session
            .ordinary
            .change_album_members(
                ctx,
                album.as_str().ok_or("CID album")?,
                &[
                    control["parent"].as_str().ok_or("P")?.into(),
                    control["motion"].as_str().ok_or("M")?.into(),
                    control["other"].as_str().ok_or("P2")?.into(),
                ],
                true,
            )
            .await?;
    }
    let fresh = session
        .json(ctx, &format!("assets/{parent}"), "GET", None)
        .await?;
    assert_eq!(fresh["type"], "IMAGE");
    assert_eq!(fresh["visibility"], "timeline");
    assert_eq!(fresh.get("livePhotoVideoId"), Some(&Value::Null));
    assert_eq!(fresh.get("stack"), Some(&Value::Null));
    let share = session.json(ctx, "shared-links", "POST", Some(json!({"type":"INDIVIDUAL","assetIds":[parent],"allowDownload":true,"showMetadata":true}))).await?;
    let share_key = share["key"]
        .as_str()
        .ok_or("CID direct share key")?
        .to_owned();
    if share_key.is_empty()
        || !share_key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("CID direct share key encoding".into());
    }
    observe(ctx, &session, root, "after-unlink-baseline", &share_key).await?;
    let stamp = metadata_stamp(root, &session.ordinary, parent)?;
    std::fs::write(
        root.join("pre-product-metadata-stamp.json"),
        serde_json::to_vec(&stamp).map_err(|_| "CID stamp encode")?,
    )
    .map_err(|_| "CID stamp write")?;
    session.json(ctx, "auth/session/lock", "POST", None).await?;
    session.json(ctx, "auth/logout", "POST", None).await?;
    Ok((session.ordinary, parent.into(), share_key))
}

pub(in super::super) async fn native_cid_observe(
    ctx: &Context,
    ordinary: Session,
    root: &Path,
    share_key: String,
) -> Result<(), String> {
    let control = control(root)?;
    let parent = control["parent"].as_str().ok_or("CID parent")?;
    let mut login=ordinary.request("auth/login","POST",Some(json!({"email":format!("native-cid-image-{}@example.invalid",std::process::id()),"password":"GraphFixtureOnly123!"})));
    login.headers.remove("x-api-key");
    let body = checked(ctx, login).await?;
    let elevated = Elevated {
        ordinary,
        token: body["accessToken"]
            .as_str()
            .ok_or("CID fixture token")?
            .into(),
    };
    let status = elevated.json(ctx, "auth/status", "GET", None).await?;
    assert_eq!(status["isElevated"], false);
    let parent_detail = response(
        ctx,
        elevated.request(&format!("assets/{parent}"), "GET", None),
    )
    .await?;
    let mut original = elevated.request(
        &format!("assets/{parent}/original?edited=false"),
        "GET",
        None,
    );
    original.download_path = Some(
        root.join("owner-session-before-unlock.bin")
            .to_string_lossy()
            .into_owned(),
    );
    let original = response(ctx, original).await?;
    write_evidence(
        root,
        "owner-session-before-unlock.json",
        &json!({"isElevated":false,"selectedDetailStatus":parent_detail.status,"selectedOriginalStatus":original.status}),
    )?;
    assert_eq!(parent_detail.status, 400);
    assert_eq!(original.status, 404);
    elevated.unlock(ctx).await?;
    observe(ctx, &elevated, root, "after-product-immediate", &share_key).await?;
    observe_quiet(&elevated.ordinary, root, "after-lock")?;
    observe(
        ctx,
        &elevated,
        root,
        "after-product-quiet-window",
        &share_key,
    )
    .await?;
    verify_selected_only(root, &control)?;
    elevated
        .json(ctx, "auth/session/lock", "POST", None)
        .await?;
    elevated.json(ctx, "auth/logout", "POST", None).await?;
    Ok(())
}
pub(in super::super) async fn native_cid_after_unlock(
    ctx: &Context,
    ordinary: Session,
    root: &Path,
    share_key: String,
) -> Result<(), String> {
    observe_external(
        ctx,
        ordinary,
        root,
        share_key,
        "after-product-unlock",
        false,
    )
    .await
}
pub(in super::super) async fn native_cid_denied(
    ctx: &Context,
    ordinary: Session,
    root: &Path,
    share_key: String,
) -> Result<(), String> {
    observe_external(ctx, ordinary, root, share_key, "after-product-denial", true).await
}
async fn observe_external(
    ctx: &Context,
    ordinary: Session,
    root: &Path,
    share_key: String,
    stage: &str,
    denied: bool,
) -> Result<(), String> {
    let mut login = ordinary.request("auth/login", "POST", Some(json!({"email":format!("native-cid-image-{}@example.invalid",std::process::id()),"password":"GraphFixtureOnly123!"})));
    login.headers.remove("x-api-key");
    let body = checked(ctx, login).await?;
    let session = Elevated {
        ordinary,
        token: body["accessToken"].as_str().ok_or("observer token")?.into(),
    };
    session.unlock(ctx).await?;
    observe_quiet(&session.ordinary, root, stage)?;
    observe(ctx, &session, root, stage, &share_key).await?;
    let before: Value = serde_json::from_slice(
        &std::fs::read(root.join("after-unlink-baseline/observations.json"))
            .map_err(|_| "baseline read")?,
    )
    .map_err(|_| "baseline decode")?;
    let after: Value = serde_json::from_slice(
        &std::fs::read(root.join(stage).join("observations.json")).map_err(|_| "observer read")?,
    )
    .map_err(|_| "observer decode")?;
    for index in 0..3 {
        for field in [
            "id",
            "ownerId",
            "type",
            "checksum",
            "livePhotoVideoId",
            "visibility",
        ] {
            assert_eq!(after[index]["fresh"][field], before[index]["fresh"][field]);
        }
        assert_eq!(after[index]["ordinaryDetailStatus"], 200);
        assert_eq!(after[index]["ordinaryOriginalStatus"], 200);
        let ids = |v: &Value| -> Result<BTreeSet<String>, String> {
            v.as_array()
                .ok_or("albums")?
                .iter()
                .map(|a| a["id"].as_str().map(str::to_owned).ok_or("album ID".into()))
                .collect()
        };
        let expected = if index == 0 && !denied {
            BTreeSet::new()
        } else {
            ids(&before[index]["accessibleAlbums"])?
        };
        assert_eq!(ids(&after[index]["accessibleAlbums"])?, expected);
    }
    session.json(ctx, "auth/session/lock", "POST", None).await?;
    session.json(ctx, "auth/logout", "POST", None).await?;
    Ok(())
}
fn control(root: &Path) -> Result<Value, String> {
    serde_json::from_slice(
        &std::fs::read(root.join("parent-control.json")).map_err(|_| "CID control read")?,
    )
    .map_err(|_| "CID control decode".into())
}
async fn observe(
    ctx: &Context,
    session: &Elevated,
    root: &Path,
    stage: &str,
    share_key: &str,
) -> Result<(), String> {
    let control = control(root)?;
    let directory = root.join(stage);
    std::fs::create_dir(&directory).map_err(|_| "CID evidence stage exists")?;
    let (still, movie) = native_pair_bytes()?;
    let mut observations = Vec::new();
    for (role, name, bytes) in [
        ("parent", "synthetic-still.jpg", still),
        ("motion", "synthetic-motion.mov", movie),
        ("other", "other-parent.png", png(1)?),
    ] {
        let id = control[role].as_str().ok_or("CID resource")?;
        let fresh = session
            .json(ctx, &format!("assets/{id}"), "GET", None)
            .await?;
        assert_eq!(fresh["id"], id);
        assert_eq!(fresh["ownerId"], session.ordinary.user_id);
        assert_eq!(
            fresh["type"],
            if role == "motion" { "VIDEO" } else { "IMAGE" }
        );
        let ordinary = response(
            ctx,
            session
                .ordinary
                .request(&format!("assets/{id}"), "GET", None),
        )
        .await?;
        let albums = session
            .json(ctx, &format!("albums?assetId={id}"), "GET", None)
            .await?;
        let mut original =
            session.request(&format!("assets/{id}/original?edited=false"), "GET", None);
        original.download_path = Some(directory.join(name).to_string_lossy().into_owned());
        let elevated_original = response(ctx, original).await?;
        assert_eq!(elevated_original.status, 200);
        assert_eq!(
            std::fs::read(directory.join(name)).map_err(|_| "CID original read")?,
            bytes
        );
        let mut ordinary_original =
            session
                .ordinary
                .request(&format!("assets/{id}/original?edited=false"), "GET", None);
        ordinary_original.download_path = Some(
            directory
                .join(format!("ordinary-{name}"))
                .to_string_lossy()
                .into_owned(),
        );
        let ordinary_original = response(ctx, ordinary_original).await?;
        observations.push(json!({"role":role,"fresh":fresh,"metadataExtractedAt":metadata_stamp(root,&session.ordinary,id)?,"ordinaryDetailStatus":ordinary.status,"ordinaryOriginalStatus":ordinary_original.status,"elevatedOriginalStatus":elevated_original.status,"originalBytesMatch":true,"accessibleAlbums":albums}));
    }
    shared_access(
        ctx,
        session,
        &directory,
        control["parent"].as_str().ok_or("CID shared parent")?,
        share_key,
    )
    .await?;
    std::fs::write(
        directory.join("observations.json"),
        serde_json::to_vec_pretty(&observations).map_err(|_| "CID observations encode")?,
    )
    .map_err(|_| "CID observations write")?;
    Ok(())
}

async fn shared_access(
    ctx: &Context,
    session: &Elevated,
    directory: &Path,
    parent: &str,
    share_key: &str,
) -> Result<(), String> {
    let mut detail =
        session
            .ordinary
            .request(&format!("assets/{parent}?key={share_key}"), "GET", None);
    detail.headers.clear();
    let detail_response = response(ctx, detail)
        .await
        .map_err(|_| "CID share detail transport")?;
    let path = directory.join("direct-share-synthetic-still.jpg");
    let mut original = session.ordinary.request(
        &format!("assets/{parent}/original?edited=false&key={share_key}"),
        "GET",
        None,
    );
    original.headers.clear();
    original.download_path = Some(path.to_string_lossy().into_owned());
    let original_response = response(ctx, original)
        .await
        .map_err(|_| "CID share original transport")?;
    let matches = if original_response.status == 200 {
        Some(
            std::fs::read(&path).map_err(|_| "CID direct share original read")?
                == native_pair_bytes()?.0,
        )
    } else {
        None
    };
    // A separately observed server limitation, never counted as protected access.
    assert_eq!(detail_response.status, 200);
    assert_eq!(detail_response.body["id"], parent);
    assert_eq!(original_response.status, 200);
    if original_response.status == 200 {
        assert_eq!(matches, Some(true));
    }
    std::fs::write(directory.join("direct-share-observations.json"), serde_json::to_vec_pretty(&json!({"authority":"preexistingIndividualSharedLinkKeyOnly","selectedParent":parent,"detailStatus":detail_response.status,"detailIDMatches":detail_response.body["id"].as_str()==Some(parent),"detailVisibility":detail_response.body["visibility"],"originalStatus":original_response.status,"originalBytesMatch":matches})).map_err(|_| "CID direct share encode")?).map_err(|_| "CID direct share evidence")?;
    Ok(())
}

fn write_evidence(root: &Path, name: &str, value: &Value) -> Result<(), String> {
    std::fs::write(
        root.join(name),
        serde_json::to_vec_pretty(value).map_err(|_| "probe evidence encode")?,
    )
    .map_err(|_| "probe evidence write".into())
}
fn verify_selected_only(root: &Path, control: &Value) -> Result<(), String> {
    let read = |name: &str| -> Result<Value, String> {
        serde_json::from_slice(&std::fs::read(root.join(name)).map_err(|_| "comparison read")?)
            .map_err(|_| "comparison decode".into())
    };
    let before = read("after-unlink-baseline/observations.json")?;
    for stage in ["after-product-immediate", "after-product-quiet-window"] {
        let after = read(&format!("{stage}/observations.json"))?;
        assert_eq!(after[0]["fresh"]["visibility"], "locked");
        assert_eq!(after[0]["fresh"]["livePhotoVideoId"], Value::Null);
        assert!(
            after[0]["accessibleAlbums"]
                .as_array()
                .ok_or("selected albums")?
                .is_empty()
        );
        assert_eq!(after[0]["ordinaryDetailStatus"], 400);
        assert_eq!(after[0]["ordinaryOriginalStatus"], 404);
        for i in 1..=2 {
            assert_eq!(after[i]["role"], before[i]["role"]);
            for field in [
                "id",
                "ownerId",
                "type",
                "checksum",
                "livePhotoVideoId",
                "visibility",
            ] {
                assert_eq!(
                    after[i]["fresh"][field], before[i]["fresh"][field],
                    "unselected exact facts changed"
                );
            }
            let ids = |v: &Value| -> Result<BTreeSet<String>, String> {
                v.as_array()
                    .ok_or("membership array")?
                    .iter()
                    .map(|a| {
                        a["id"]
                            .as_str()
                            .map(str::to_owned)
                            .ok_or("membership ID".into())
                    })
                    .collect()
            };
            assert_eq!(
                ids(&after[i]["accessibleAlbums"])?,
                ids(&before[i]["accessibleAlbums"])?
            );
            assert_eq!(
                ids(&after[i]["accessibleAlbums"])?,
                control["albums"]
                    .as_array()
                    .ok_or("control albums")?
                    .iter()
                    .map(|id| id.as_str().map(str::to_owned).ok_or("control album ID"))
                    .collect::<Result<BTreeSet<_>, _>>()?
            );
            assert_eq!(after[i]["ordinaryDetailStatus"], 200);
            assert_eq!(after[i]["ordinaryOriginalStatus"], 200);
            assert_eq!(after[i]["originalBytesMatch"], true);
        }
        let share = read(&format!("{stage}/direct-share-observations.json"))?;
        write_evidence(
            root,
            &format!("{stage}-summary.json"),
            &json!({"selectedRemainsLocked":true,"selectedAlbumsRemoved":true,"ordinarySelectedReadDenied":true,"unselectedMotionAndOtherPreserved":true,"directShareDetailStatus":share["detailStatus"],"directShareOriginalStatus":share["originalStatus"],"directShareOriginalBytesMatch":share["originalBytesMatch"],"scope":"C2 single-selected IMAGE only; existing direct share negative control is separate"}),
        )?;
    }
    Ok(())
}

fn verify_native_cid(session: &Session, root: &Path, control: &Value) -> Result<(), String> {
    let sql = std::fs::read_to_string(root.join("metadata-completion.sql"))
        .map_err(|_| "CID SQL read")?;
    let project = std::env::var("IMMICH_TEST_PROJECT").map_err(|_| "CID isolated project")?;
    let compose =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docker/immich-test/docker-compose.yml");
    let sql = sql
        .replace(
            "'metadataExtractedAt',j.",
            "'livePhotoCID',e.\"livePhotoCID\",'metadataExtractedAt',j.",
        )
        .replace(
            "FROM asset a LEFT JOIN",
            "FROM asset a LEFT JOIN asset_exif e ON e.\"assetId\"=a.id LEFT JOIN",
        );
    let rows = native_metadata::query_metadata(&project, &compose, &sql)?;
    for role in ["parent", "motion"] {
        let row = rows
            .as_array()
            .ok_or("CID rows")?
            .iter()
            .find(|row| row["id"] == control[role] && row["ownerId"] == session.user_id)
            .ok_or("exact CID row")?;
        assert_eq!(row["livePhotoCID"], "B18D9CC0-335C-4B73-880D-627A3A78D9C3");
        assert!(row["metadataExtractedAt"].as_str().is_some());
    }
    write_evidence(root, "native-cid-established.json", &rows)
}
