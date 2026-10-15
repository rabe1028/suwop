//! Metadata-bearing selected motion product fixture. No parent operation policy.
use super::*;

pub(in super::super) fn native_pair_bytes() -> Result<(Vec<u8>, Vec<u8>), String> {
    const STILL: &[u8] =
        include_bytes!("../../../../../Tests/fixtures/native_live_pair/media/synthetic-still.jpg");
    const MOVIE: &[u8] =
        include_bytes!("../../../../../Tests/fixtures/native_live_pair/media/synthetic-motion.mov");
    let manifest: Value = serde_json::from_str(include_str!(
        "../../../../../Tests/fixtures/native_live_pair/manifest.json"
    ))
    .map_err(|_| "native pair manifest")?;
    for (index, bytes) in [STILL, MOVIE].into_iter().enumerate() {
        let expected = &manifest["files"][index];
        assert_eq!(
            expected["path"],
            ["media/synthetic-still.jpg", "media/synthetic-motion.mov"][index]
        );
        assert_eq!(expected["bytes"].as_u64(), Some(bytes.len() as u64));
        assert_eq!(expected["sha1"], format!("{:x}", sha1::Sha1::digest(bytes)));
        assert_eq!(
            expected["sha256"],
            format!("{:x}", sha2::Sha256::digest(bytes))
        );
    }
    Ok((STILL.to_vec(), MOVIE.to_vec()))
}

pub(in super::super) async fn native_motion_setup(
    ctx: &Context,
    session: &Session,
    directory: &Path,
) -> Result<(String, Vec<String>), String> {
    let (still, movie) = native_pair_bytes()?;
    let motion = upload(
        ctx,
        session,
        directory,
        "synthetic-motion.mov",
        &movie,
        ResourceRole::Video,
        None,
    )
    .await?;
    let parent = upload(
        ctx,
        session,
        directory,
        "synthetic-still.jpg",
        &still,
        ResourceRole::Image,
        Some(&motion),
    )
    .await?;
    let other = upload(
        ctx,
        session,
        directory,
        "other-parent.png",
        &png(1)?,
        ResourceRole::Image,
        Some(&motion),
    )
    .await?;
    native_metadata::metadata_ready(session, [&parent, &motion, &other])?;
    for (id, to) in [(&motion, "timeline"), (&other, "archive")] {
        let value: Value = session
            .json(
                ctx,
                &format!("assets/{id}"),
                "PUT",
                Some(json!({"visibility":to})),
            )
            .await?;
        assert_eq!(value["id"], *id);
        assert_eq!(value["visibility"], to);
    }
    let mut albums = Vec::new();
    for title in ["Native motion first", "Native motion second"] {
        let album = session.create_album(ctx, title).await?;
        session
            .change_album_members(
                ctx,
                &album.id,
                &[parent.clone(), motion.clone(), other.clone()],
                true,
            )
            .await?;
        albums.push(album.id);
    }
    std::fs::write(
        directory.join("native-motion-control.json"),
        serde_json::to_vec(&json!({"parent":parent,"motion":motion,"other":other,"albums":albums}))
            .map_err(|_| "native control encode")?,
    )
    .map_err(|_| "native control write")?;
    Ok((motion, albums))
}

pub(in super::super) fn native_motion_controls(
    agent: &ureq::Agent,
    session: &Session,
    directory: &Path,
    stage: &str,
) -> Result<(), String> {
    let control: Value = serde_json::from_slice(
        &std::fs::read(directory.join("native-motion-control.json"))
            .map_err(|_| "native control read")?,
    )
    .map_err(|_| "native control decode")?;
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("native evidence root")?,
    )
    .join(stage);
    std::fs::create_dir(&root).map_err(|_| "native evidence stage exists")?;
    let (still, movie) = native_pair_bytes()?;
    let mut observations = Vec::new();
    for (role, name, expected, visibility) in [
        ("parent", "synthetic-still.jpg", still, Some("timeline")),
        (
            "motion",
            "synthetic-motion.mov",
            movie,
            Some(if stage == "after-archive" {
                "archive"
            } else {
                "timeline"
            }),
        ),
        ("other", "other-parent.png", png(1)?, Some("archive")),
    ] {
        let id = control[role].as_str().ok_or("native resource id")?;
        let fresh: HttpResponse = serde_json::from_value(execute(
            agent,
            &session.request(&format!("assets/{id}"), "GET", None),
        )?)
        .map_err(|_| "native detail decode")?;
        assert_eq!(fresh.status, 200);
        assert_eq!(fresh.body["id"], id);
        assert_eq!(fresh.body["ownerId"], session.user_id);
        assert_eq!(
            fresh.body["type"],
            if role == "motion" { "VIDEO" } else { "IMAGE" }
        );
        assert_eq!(
            fresh.body["visibility"],
            visibility.ok_or("native expected visibility")?
        );
        if role == "motion" {
            assert_eq!(fresh.body.get("livePhotoVideoId"), Some(&Value::Null));
        } else {
            assert_eq!(fresh.body["livePhotoVideoId"], control["motion"]);
        }
        let memberships: HttpResponse = serde_json::from_value(execute(
            agent,
            &session.request(&format!("albums?assetId={id}"), "GET", None),
        )?)
        .map_err(|_| "native memberships decode")?;
        assert_eq!(memberships.status, 200);
        let actual = memberships
            .body
            .as_array()
            .ok_or("native memberships")?
            .iter()
            .map(|a| a["id"].as_str().ok_or("native album id"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        let expected_albums = control["albums"]
            .as_array()
            .ok_or("native albums")?
            .iter()
            .map(|a| a.as_str().ok_or("native known album id"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        assert_eq!(actual, expected_albums);
        let path = root.join(name);
        let mut request =
            session.request(&format!("assets/{id}/original?edited=false"), "GET", None);
        request.download_path = Some(path.to_string_lossy().into_owned());
        let original: HttpResponse = serde_json::from_value(execute(agent, &request)?)
            .map_err(|_| "native original decode")?;
        assert_eq!(original.status, 200);
        assert_eq!(
            std::fs::read(path).map_err(|_| "native original read")?,
            expected
        );
        observations.push(json!({"role":role,"fresh":fresh.body,"memberships":memberships.body,"originalBytesMatch":true}));
    }
    std::fs::write(
        root.join("observations.json"),
        serde_json::to_vec_pretty(&observations).map_err(|_| "native observations encode")?,
    )
    .map_err(|_| "native observations write")?;
    Ok(())
}
