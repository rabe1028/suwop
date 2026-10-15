//! API-linked selected-parent placement; no native Live or pair protection claim.
use super::*;

pub(in super::super) async fn ordinary_parent_setup(
    ctx: &Context,
    session: &Session,
    directory: &Path,
) -> Result<(String, Vec<String>), String> {
    setup_pair(ctx, session, directory, false, "parent").await
}
pub(in super::super) async fn ordinary_native_parent_setup(
    ctx: &Context,
    session: &Session,
    directory: &Path,
) -> Result<(String, Vec<String>), String> {
    setup_pair(ctx, session, directory, true, "parent").await
}
pub(super) async fn write_contract_native_setup(
    ctx: &Context,
    session: &Session,
    directory: &Path,
) -> Result<(String, Vec<String>), String> {
    setup_pair(ctx, session, directory, true, "write-contract").await
}
pub(super) async fn native_checkpoint_setup(
    ctx: &Context,
    session: &Session,
    directory: &Path,
    checkpoint: &str,
) -> Result<(String, Vec<String>), String> {
    setup_pair(ctx, session, directory, true, checkpoint).await
}
async fn setup_pair(
    ctx: &Context,
    session: &Session,
    directory: &Path,
    native: bool,
    checkpoint: &str,
) -> Result<(String, Vec<String>), String> {
    let (still, movie) = if native {
        native_pair_bytes()?
    } else {
        (png(0)?, M.to_vec())
    };
    let motion = upload(
        ctx,
        session,
        directory,
        if native {
            "synthetic-motion.mov"
        } else {
            "M.mp4"
        },
        &movie,
        ResourceRole::Video,
        None,
    )
    .await?;
    let parent = upload(
        ctx,
        session,
        directory,
        if native {
            "synthetic-still.jpg"
        } else {
            "P.png"
        },
        &still,
        ResourceRole::Image,
        Some(&motion),
    )
    .await?;
    let other = upload(
        ctx,
        session,
        directory,
        "P2.png",
        &png(1)?,
        ResourceRole::Image,
        Some(&motion),
    )
    .await?;
    if native {
        metadata_ready(session, [&parent, &motion, &other], checkpoint)?;
    }
    let mut known = vec![];
    for title in ["Parent placement first", "Parent placement second"] {
        let album = session.create_album(ctx, title).await?;
        session
            .change_album_members(
                ctx,
                &album.id,
                &[parent.clone(), motion.clone(), other.clone()],
                true,
            )
            .await?;
        known.push(album.id);
    }
    let mut baseline = Vec::new();
    for (id, visibility, media) in [
        (&parent, "timeline", "IMAGE"),
        (&motion, "hidden", "VIDEO"),
        (&other, "timeline", "IMAGE"),
    ] {
        let value: Value = session
            .json(ctx, &format!("assets/{id}"), "GET", None)
            .await?;
        assert_eq!(value["id"], *id);
        assert_eq!(value["ownerId"], session.user_id);
        assert_eq!(value["visibility"], visibility);
        assert_eq!(value["type"], media);
        if id != &motion {
            assert_eq!(value["livePhotoVideoId"], motion);
        }
        baseline.push(value);
    }
    std::fs::write(directory.join("parent-control.json"), serde_json::to_vec(&json!({"parent":parent,"motion":motion,"other":other,"albums":known,"baseline":baseline,"nativePair":native})).map_err(|_| "parent control encode")?).map_err(|_| "parent control write")?;
    Ok((parent, known))
}

pub(in super::super) fn ordinary_parent_controls(
    agent: &ureq::Agent,
    session: &Session,
    directory: &Path,
    stage: &str,
) -> Result<(), String> {
    let control: Value = serde_json::from_slice(
        &std::fs::read(directory.join("parent-control.json")).map_err(|_| "parent control read")?,
    )
    .map_err(|_| "parent control decode")?;
    let native = control["nativePair"].as_bool().unwrap_or(false);
    let native_bytes = if native {
        Some(native_pair_bytes()?)
    } else {
        None
    };
    let evidence = evidence_directory(&control, stage)?;
    let ids = [
        control["parent"].as_str().ok_or("parent")?,
        control["motion"].as_str().ok_or("motion")?,
        control["other"].as_str().ok_or("other")?,
    ];
    let mut observations = Vec::new();
    for (index, id) in ids.into_iter().enumerate() {
        let response: HttpResponse = serde_json::from_value(execute(
            agent,
            &session.request(&format!("assets/{id}"), "GET", None),
        )?)
        .map_err(|_| "control detail")?;
        assert_eq!(response.status, 200);
        let value = response.body;
        for field in ["id", "ownerId", "type", "checksum", "livePhotoVideoId"] {
            assert_eq!(value[field], control["baseline"][index][field]);
        }
        assert_eq!(
            value["visibility"],
            if index == 0 {
                json!(if stage == "after-archive" {
                    "archive"
                } else {
                    "timeline"
                })
            } else {
                control["baseline"][index]["visibility"].clone()
            }
        );
        let memberships: HttpResponse = serde_json::from_value(execute(
            agent,
            &session.request(&format!("albums?assetId={id}"), "GET", None),
        )?)
        .map_err(|_| "control albums")?;
        assert_eq!(memberships.status, 200);
        let actual = memberships
            .body
            .as_array()
            .ok_or("memberships")?
            .iter()
            .map(|a| a["id"].as_str().ok_or("membership id"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        let expected_albums = control["albums"]
            .as_array()
            .ok_or("known albums")?
            .iter()
            .map(|a| a.as_str().ok_or("known album id"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        assert_eq!(actual, expected_albums);
        let path = if let Some(root) = &evidence {
            root.join(match index {
                0 => "synthetic-still.jpg",
                1 => "synthetic-motion.mov",
                _ => "other-parent.png",
            })
        } else {
            directory.join(format!("parent-control-{index}.bin"))
        };
        let mut request =
            session.request(&format!("assets/{id}/original?edited=false"), "GET", None);
        request.download_path = Some(path.to_string_lossy().into_owned());
        let original: HttpResponse =
            serde_json::from_value(execute(agent, &request)?).map_err(|_| "control original")?;
        assert_eq!(original.status, 200);
        let expected = match index {
            0 => native_bytes
                .as_ref()
                .map_or_else(|| png(0), |p| Ok(p.0.clone()))?,
            1 => native_bytes
                .as_ref()
                .map_or_else(|| M.to_vec(), |p| p.1.clone()),
            _ => png(1)?,
        };
        assert_eq!(std::fs::read(path).map_err(|_| "control bytes")?, expected);
        observations.push(json!({"role":(["parent","motion","other"][index]),"fresh":value,"memberships":memberships.body,"originalBytesMatch":true}));
    }
    if let Some(root) = evidence {
        std::fs::write(
            root.join("api-observations.json"),
            serde_json::to_vec(&observations).map_err(|_| "observation encode")?,
        )
        .map_err(|_| "observation write")?;
    }
    Ok(())
}

fn evidence_directory(control: &Value, stage: &str) -> Result<Option<std::path::PathBuf>, String> {
    if control["nativePair"].as_bool().unwrap_or(false) {
        let root = std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR")
            .ok_or("native pair evidence directory must be supplied by harness")?;
        let stage = std::path::PathBuf::from(root).join("parent").join(stage);
        std::fs::create_dir_all(&stage).map_err(|_| "evidence directory")?;
        let record = stage.join("api-relation.json");
        let encoded = serde_json::to_vec(&control).map_err(|_| "evidence relation encode")?;
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(record)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(&encoded)
            })
            .map_err(|_| "evidence relation write")?;
        Ok(Some(stage))
    } else {
        Ok(None)
    }
}

// Disposable fixture diagnosis: no acceptance assertion is weakened here.
pub(in super::super) fn native_parent_probe(
    agent: &ureq::Agent,
    session: &Session,
    directory: &Path,
) -> Result<(), String> {
    let control: Value = serde_json::from_slice(
        &std::fs::read(directory.join("parent-control.json")).map_err(|_| "probe control")?,
    )
    .map_err(|_| "probe decode")?;
    let mut samples = Vec::new();
    for phase in ["before-revision-settle", "after-revision-settle"] {
        let mut resources = Vec::new();
        for role in ["parent", "motion", "other"] {
            let id = control[role].as_str().ok_or("probe id")?;
            if phase == "after-revision-settle" {
                super::super::visibility::wait_for_stable_asset(
                    agent,
                    &session.request(&format!("assets/{id}"), "GET", None),
                    &suwop_core::domain::AssetKey {
                        provider: suwop_core::domain::Provider::Immich,
                        scope: session.scope.clone(),
                        asset_id: id.into(),
                    },
                )?;
            }
            let reply: HttpResponse = serde_json::from_value(execute(
                agent,
                &session.request(&format!("albums?assetId={id}"), "GET", None),
            )?)
            .map_err(|_| "probe albums")?;
            assert_eq!(reply.status, 200);
            let memberships = reply
                .body
                .as_array()
                .ok_or("probe membership array")?
                .iter()
                .map(|a| a["id"].clone())
                .collect::<Vec<_>>();
            resources
                .push(json!({"role":role,"memberships":memberships,"albumAddAcknowledged":true}));
        }
        samples.push(json!({"stage":phase,"resources":resources,"proof":"bounded API revision settling, not global job completion"}));
    }
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("probe evidence root")?,
    )
    .join("parent");
    std::fs::create_dir_all(&root).map_err(|_| "probe directory")?;
    std::fs::write(
        root.join("setup-memberships.json"),
        serde_json::to_vec_pretty(&samples).map_err(|_| "probe encode")?,
    )
    .map_err(|_| "probe write")?;
    let motion = control["motion"].as_str().ok_or("probe motion")?;
    let path = root.join("setup-motion-original.mov");
    let mut request = session.request(
        &format!("assets/{motion}/original?edited=false"),
        "GET",
        None,
    );
    request.download_path = Some(path.to_string_lossy().into_owned());
    let original: HttpResponse =
        serde_json::from_value(execute(agent, &request)?).map_err(|_| "probe original")?;
    assert_eq!(original.status, 200);
    assert_eq!(
        std::fs::read(path).map_err(|_| "probe bytes")?,
        native_pair_bytes()?.1
    );
    Ok(())
}
