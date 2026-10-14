use base64::Engine;
use crux_core::Command;
use serde_json::{Value, json};
use std::{collections::BTreeMap, io::Read, path::Path, time::Duration};
use suwop_core::{
    app::{Context, Effect, Event, SavedLibrary, ShellOperation, ShellResponse},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferFile,
    },
    immich::{self, HttpRequest, HttpResponse, Session, UploadPart},
};

const PIXELS: [&str; 4] = [
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==",
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/cetH5QAAAABJRU5ErkJggg==",
];

#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_immich_upload_gps_list_download_stack_sidecar_and_trash() -> Result<(), String> {
    let address = std::env::var("SUWOP_IMMICH_URL").map_err(|e| e.to_string())?;
    let key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|e| e.to_string())?;
    let directory = std::env::temp_dir().join(format!("suwop-live-{}", std::process::id()));
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let cleanup_path = directory.clone();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = exercise(&ctx, &address, &key, &directory).await;
        ctx.send_event(Event::Finished {
            preview_to_select: None,
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
        });
    });
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    loop {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for effect in effects {
            let Effect::Io(mut request) = effect;
            let result = match request.operation {
                ShellOperation::Http(ref http) => execute(&agent, http),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(milliseconds)));
                    Ok(Value::Null)
                }
                ShellOperation::Persist(_) => Ok(Value::Null),
                ShellOperation::ConfirmTrash { .. } => Ok(json!(true)),
                _ => Err("unexpected non-HTTP effect".into()),
            };
            let response = match result {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            request.resolve(response).map_err(|e| e.to_string())?;
        }
    }
    std::fs::remove_dir_all(cleanup_path).map_err(|e| e.to_string())?;
    let event = command.events().last().ok_or("live test did not finish")?;
    match event {
        Event::Finished { error: None, .. } => Ok(()),
        Event::Finished {
            error: Some(error), ..
        } => Err(error),
        _ => Err("unexpected final event".into()),
    }
}

async fn exercise(ctx: &Context, address: &str, key: &str, directory: &Path) -> Result<(), String> {
    let session = immich::connect(ctx, address, key, true).await?;
    assert!(session.version.uses_cursor());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs_f64();
    let mut ids = Vec::new();
    for (i, pixel) in PIXELS.iter().enumerate() {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(pixel)
            .map_err(|e| e.to_string())?;
        let path = directory.join(format!("pixel-{i}.png"));
        std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
        let resource = PhotoResource {
            id: i.to_string(),
            name: format!("pixel-{i}.png"),
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
        let metadata = fixture_metadata(resource, i, now);
        let id = if i == 3 {
            upload_sidecar(ctx, &session, &file, directory, now).await?
        } else {
            session.upload(ctx, &file, &metadata, now, None).await?
        };
        let fetched = session.asset(ctx, &id).await?;
        assert_eq!(fetched.original_file_name, metadata.name);
        let captured = fetched
            .record(&session.scope, None, None)
            .captured_at
            .ok_or("missing capture date")?;
        assert!(
            (captured - now).abs() < 0.001,
            "subsecond capture date changed"
        );
        if i < 3 {
            let exif = fetched.exif_info.ok_or("missing GPS metadata")?;
            assert!((exif.latitude.ok_or("missing latitude")? - 35.681_236).abs() < 0.000_001);
            assert!((exif.longitude.ok_or("missing longitude")? - 139.767_125).abs() < 0.000_001);
        }
        let downloaded = directory.join(format!("download-{i}.png"));
        session
            .download(ctx, &id, &downloaded.to_string_lossy())
            .await?;
        assert_eq!(std::fs::read(downloaded).map_err(|e| e.to_string())?, bytes);
        ids.push(id);
    }
    wait_for(ctx, &session, &ids, true).await?;
    assert!(session.favorite(ctx, &ids[0], true).await?.is_favorite);
    assert!(!session.favorite(ctx, &ids[0], false).await?.is_favorite);
    exercise_metadata(ctx, &session, &ids[..2]).await?;
    exercise_albums(ctx, &session, &ids[..2]).await?;
    ids.push(exercise_edited_preview(ctx, &session, directory, now).await?);
    ids.extend(exercise_adjusted_dates(ctx, &session, directory, now).await?);
    let _: Value = session
        .json(
            ctx,
            "stacks",
            "POST",
            Some(json!({"assetIds":[ids[1],ids[2]]})),
        )
        .await?;
    wait_for(ctx, &session, &ids, true).await?;
    let files = session.files(ctx, &ids[3]).await?;
    assert!(files.iter().any(|f| f.kind == "sidecar"));
    let asset = session.asset(ctx, &ids[3]).await?;
    let record = asset.record(&session.scope, None, Some(&files));
    assert!(
        record
            .resources
            .iter()
            .any(|r| r.role == ResourceRole::Auxiliary)
    );
    assert!(
        record
            .deletion_blockers
            .iter()
            .any(|b| b.contains("sidecar"))
    );
    exercise_trash(ctx, &session, &ids).await
}

async fn exercise_trash(ctx: &Context, session: &Session, ids: &[String]) -> Result<(), String> {
    use suwop_core::trash::TrashAction;
    assert!(session.trash_retention(ctx).await? > 0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs_f64();
    let assets = session.list(ctx, now).await?;
    let state = SavedLibrary {
        schema_version: 5,
        apple_scope: "unused-test-library".into(),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            access: ScanAccess::Full,
            assets: assets
                .iter()
                .map(|asset| asset.record(&session.scope, None, None))
                .collect(),
            scanned_at: Some(now),
        }],
        ..SavedLibrary::default()
    };
    let keys: Vec<_> = ids
        .iter()
        .map(|id| AssetKey {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            asset_id: id.clone(),
        })
        .collect();
    let trashed = suwop_core::workflow::run(
        ctx,
        Event::ChangeTrash {
            keys: keys.clone(),
            action: TrashAction::Trash,
            id: "10000000-0000-4000-8000-000000000001".into(),
        },
        state,
        Some(session.clone()),
    )
    .await;
    if let Some(error) = trashed.error {
        return Err(error);
    }
    assert!(trashed.state.pending_trash.is_empty());
    wait_for(ctx, session, ids, false).await?;
    let listed = suwop_core::workflow::run(
        ctx,
        Event::RefreshTrash { now: now + 300.0 },
        trashed.state,
        Some(session.clone()),
    )
    .await;
    if let Some(error) = listed.error {
        return Err(error);
    }
    let deleted = listed.state.trash.as_ref().ok_or("trash list missing")?;
    assert!(
        deleted.verified
            && ids.iter().all(|id| deleted
                .items
                .iter()
                .any(|item| item.identity.key.asset_id == *id))
    );
    let restored = suwop_core::workflow::run(
        ctx,
        Event::ChangeTrash {
            keys,
            action: TrashAction::Restore,
            id: "10000000-0000-4000-8000-000000000002".into(),
        },
        listed.state,
        Some(session.clone()),
    )
    .await;
    if let Some(error) = restored.error {
        return Err(error);
    }
    assert!(restored.state.pending_trash.is_empty());
    wait_for(ctx, session, ids, true).await?;
    // Keep the fixture cleanup behavior, after proving the user-facing round trip.
    session.trash(ctx, ids).await?;
    wait_for(ctx, session, ids, false).await
}

async fn wait_for(
    ctx: &Context,
    session: &Session,
    ids: &[String],
    present: bool,
) -> Result<(), String> {
    for _ in 0..40 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs_f64();
        let assets = session.list(ctx, now).await?;
        if ids
            .iter()
            .all(|id| assets.iter().any(|a| &a.id == id) == present)
        {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err("search index did not reach the expected state".into())
}

async fn exercise_adjusted_dates(
    ctx: &Context,
    session: &Session,
    directory: &Path,
    now: f64,
) -> Result<Vec<String>, String> {
    let embedded = 1_577_901_845.125;
    let adjusted = 1_730_615_400.125;
    let mut ids = Vec::new();
    for (index, bytes) in [
        include_bytes!("fixtures/control-date.png").as_slice(),
        include_bytes!("fixtures/adjusted-date.png").as_slice(),
        include_bytes!("fixtures/matching-date.png").as_slice(),
    ]
    .into_iter()
    .enumerate()
    {
        let file = date_fixture(directory, index, bytes)?;
        let mut metadata = fixture_metadata(file.resource.clone(), index, now);
        metadata.captured_at = match index {
            1 => Some(adjusted),
            2 => Some(embedded),
            _ => None,
        };
        metadata.modified_at = None;
        metadata.latitude = None;
        metadata.longitude = None;
        metadata.is_favorite = true;
        let expected = metadata.captured_at.unwrap_or(embedded);
        let origin = date_fixture_origin(session, &file, &metadata, index);
        let id = create_marked_date_fixture(ctx, session, &file, &origin, now).await?;
        let preview = directory.join(format!("date-{index}-preview.jpg"));
        wait_preview(ctx, session, &id, &preview, 4.0 / 3.0).await?;
        wait_metadata_queues(ctx, session).await?;
        verify_timeline_dates(ctx, session, &id, expected, index != 1).await?;
        if index == 2 {
            verify_ordinary_copy(ctx, session, &id).await?;
        }
        // Rendering follows initial metadata extraction. Request another read,
        // drain its queues, then verify the library adjustment still wins.
        let _: Value = session
            .json(
                ctx,
                "assets/jobs",
                "POST",
                Some(json!({
                    "assetIds":[id], "name":"refresh-metadata",
                })),
            )
            .await?;
        wait_metadata_queues(ctx, session).await?;
        verify_timeline_dates(ctx, session, &id, expected, index != 1).await?;
        if index == 2 {
            verify_ordinary_copy(ctx, session, &id).await?;
        }
        let before_duplicate = session.asset(ctx, &id).await?;
        assert_eq!(
            before_duplicate
                .record(&session.scope, None, None)
                .resources[0]
                .sha1,
            file.resource.sha1
        );
        let captured = before_duplicate
            .record(&session.scope, None, None)
            .captured_at
            .ok_or("missing EXIF capture instant")?;
        assert!(
            (captured - expected).abs() < 0.001,
            "embedded EXIF replaced the library capture instant"
        );
        assert!(
            before_duplicate
                .exif_info
                .as_ref()
                .and_then(|exif| exif.date_time_original.as_ref())
                .is_some()
        );
        assert_eq!(before_duplicate.original_file_name, metadata.name);
        assert!(before_duplicate.is_favorite && !before_duplicate.is_trashed);
        metadata.captured_at = Some(adjusted + 86_400.0);
        metadata.is_favorite = false;
        verify_duplicate_keeps_origin(ctx, session, &file, &origin, &metadata, now).await?;
        let after_duplicate = session.asset(ctx, &id).await?;
        assert_eq!(after_duplicate.checksum, before_duplicate.checksum);
        assert_eq!(
            after_duplicate.original_file_name,
            before_duplicate.original_file_name
        );
        assert_eq!(after_duplicate.is_favorite, before_duplicate.is_favorite);
        assert_eq!(
            after_duplicate
                .record(&session.scope, None, None)
                .captured_at,
            Some(expected)
        );
        let original = directory.join(format!("date-{index}-original.png"));
        session
            .download(ctx, &id, &original.to_string_lossy())
            .await?;
        assert_eq!(std::fs::read(original).map_err(|e| e.to_string())?, bytes);
        ids.push(id);
    }
    Ok(ids)
}

async fn verify_ordinary_copy(ctx: &Context, session: &Session, id: &str) -> Result<(), String> {
    let files = session.files(ctx, id).await?;
    assert!(!files.iter().any(|file| file.kind == "sidecar"));
    let asset = session.asset(ctx, id).await?;
    let record = asset.record(&session.scope, None, Some(&files));
    assert!(
        record.deletion_blockers.is_empty(),
        "a matching-date ordinary copy must remain eligible for a later move"
    );
    Ok(())
}

async fn verify_timeline_dates(
    ctx: &Context,
    session: &Session,
    id: &str,
    expected: f64,
    embedded_zone: bool,
) -> Result<(), String> {
    let asset: Value = session
        .json(ctx, &format!("assets/{id}"), "GET", None)
        .await?;
    // The embedded control is +09:00; the known library adjustment is explicitly
    // an absolute UTC date. localDateTime encodes local wall time with a Z suffix.
    for (field, expected) in [
        ("fileCreatedAt", expected),
        (
            "localDateTime",
            expected + if embedded_zone { 32_400.0 } else { 0.0 },
        ),
    ] {
        let value = asset[field].as_str().ok_or("missing timeline date")?;
        let date = chrono::DateTime::parse_from_rfc3339(value).map_err(|e| e.to_string())?;
        #[allow(clippy::cast_precision_loss)]
        let seconds = date.timestamp_millis() as f64 / 1000.0;
        assert!(
            (seconds - expected).abs() < 0.001,
            "{field}: expected {expected}, received {value}"
        );
    }
    Ok(())
}

fn date_fixture(directory: &Path, index: usize, bytes: &[u8]) -> Result<TransferFile, String> {
    use sha1::Digest;
    let input = directory.join(format!("date-{index}.png"));
    std::fs::write(&input, bytes).map_err(|e| e.to_string())?;
    Ok(TransferFile {
        resource: PhotoResource {
            id: "original".into(),
            name: format!("date-{index}.png"),
            role: ResourceRole::Image,
            sha1: Some(suwop_core::domain::hex(&sha1::Sha1::digest(bytes))),
            bytes: Some(bytes.len() as u64),
        },
        path: input.to_string_lossy().into_owned(),
        signature: FileSignature {
            sha256: suwop_core::domain::hex(&sha2::Sha256::digest(bytes)),
            bytes: bytes.len() as u64,
        },
    })
}

/// Harness-only admin reads. A queued metadata refresh returning HTTP 204 does
/// not prove it ran; observe both extraction and its sidecar follow-up queues.
async fn wait_metadata_queues(ctx: &Context, session: &Session) -> Result<(), String> {
    let mut idle_rounds = 0;
    for _ in 0..120 {
        let mut idle = true;
        for name in ["metadataExtraction", "sidecar"] {
            let queue: Value = session
                .json(ctx, &format!("queues/{name}"), "GET", None)
                .await?;
            if queue["name"] != name || queue["isPaused"] != false {
                return Err(format!("metadata queue {name} is unavailable or paused"));
            }
            let statistics = &queue["statistics"];
            if statistics["failed"]
                .as_u64()
                .ok_or("missing failed job count")?
                != 0
            {
                return Err(format!("metadata queue {name} contains failed jobs"));
            }
            for field in ["active", "waiting", "delayed", "paused"] {
                idle &= statistics[field]
                    .as_u64()
                    .ok_or("missing queue job count")?
                    == 0;
            }
        }
        idle_rounds = if idle { idle_rounds + 1 } else { 0 };
        // A sidecar job can enqueue extraction between the two queue reads.
        if idle_rounds == 2 {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err("metadata and sidecar queues did not finish processing".into())
}

async fn exercise_edited_preview(
    ctx: &Context,
    session: &Session,
    directory: &Path,
    now: f64,
) -> Result<String, String> {
    use suwop_core::editing::{ImageTransform, PixelCrop, PixelSize, read_immich_transform};
    let bytes = base64::engine::general_purpose::STANDARD.decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAFElEQVR4nGP4z8DAAMb//0MZ2DgAGRwO8lIWG74AAAAASUVORK5CYII="
    ).map_err(|e| e.to_string())?;
    let input = directory.join("preview-contract.png");
    std::fs::write(&input, &bytes).map_err(|e| e.to_string())?;
    let resource = PhotoResource {
        id: "preview".into(),
        name: "preview-contract.png".into(),
        role: ResourceRole::Image,
        sha1: None,
        bytes: Some(bytes.len() as u64),
    };
    let file = TransferFile {
        resource: resource.clone(),
        path: input.to_string_lossy().into_owned(),
        signature: FileSignature {
            sha256: "0".repeat(64),
            bytes: bytes.len() as u64,
        },
    };
    let id = session
        .upload(ctx, &file, &fixture_metadata(resource, 4, now), now, None)
        .await?;
    let path = directory.join("preview.jpg");
    let before_preview = wait_preview(ctx, session, &id, &path, 4.0 / 3.0).await?;
    let before = session.asset(ctx, &id).await?;
    let dimensions = PixelSize {
        width: 4,
        height: 3,
    };
    let transform = ImageTransform {
        crop: PixelCrop {
            x: 0,
            y: 0,
            width: 2,
            height: 1,
        },
        clockwise_quarter_turns: 1,
        flip_horizontal: false,
        color: suwop_core::editing::ColorAdjustments::default(),
    };
    let _: Value = session
        .json(
            ctx,
            &format!("assets/{id}/edits"),
            "PUT",
            Some(json!({ "edits": transform.immich_actions(dimensions)? })),
        )
        .await?;
    let actions: Value = session
        .json(ctx, &format!("assets/{id}/edits"), "GET", None)
        .await?;
    assert_eq!(read_immich_transform(dimensions, &id, actions)?, transform);
    // The service can return an unedited fallback while its queued renderer is
    // pending. A successful HTTP response alone must not satisfy this test.
    let edited_preview = wait_preview(ctx, session, &id, &path, 0.5).await?;
    assert_ne!(before_preview, edited_preview);
    let after = session.asset(ctx, &id).await?;
    assert_eq!(after.id, before.id);
    assert_eq!(after.checksum, before.checksum);
    assert_eq!(after.original_file_name, before.original_file_name);
    assert_eq!(after.is_favorite, before.is_favorite);
    assert_eq!(
        after.record(&session.scope, None, None).captured_at,
        before.record(&session.scope, None, None).captured_at
    );
    assert_eq!(after.is_edited, Some(true));
    let current = directory.join("current-original.png");
    let input = session
        .current_image_input(
            ctx,
            &after.record(&session.scope, None, None),
            &current.to_string_lossy(),
        )
        .await?;
    assert_eq!(
        read_immich_transform(
            dimensions,
            &id,
            input.edits.clone().ok_or("missing current edits")?
        )?,
        transform
    );
    session.verify_current_image_input(ctx, &input).await?;
    assert_eq!(std::fs::read(&current).map_err(|e| e.to_string())?, bytes);
    let files = session.files(ctx, &id).await?;
    assert!(
        suwop_core::domain::allow_deletion(&[after.record(&session.scope, None, Some(&files))])
            .is_err()
    );
    let original = directory.join("preview-original.png");
    session
        .download(ctx, &id, &original.to_string_lossy())
        .await?;
    assert_eq!(std::fs::read(original).map_err(|e| e.to_string())?, bytes);
    Ok(id)
}

async fn wait_preview(
    ctx: &Context,
    session: &Session,
    id: &str,
    path: &Path,
    aspect: f64,
) -> Result<Vec<u8>, String> {
    for _ in 0..80 {
        let mut request = session.preview_request(id, true)?;
        request.download_path = Some(path.to_string_lossy().into_owned());
        let response: HttpResponse =
            suwop_core::app::io(ctx, ShellOperation::Http(request)).await?;
        if response.status == 200 {
            let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
            if let Some((width, height)) = jpeg_dimensions(&bytes)
                && (f64::from(width) / f64::from(height) - aspect).abs() < 0.02
            {
                return Ok(bytes);
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    Err(format!(
        "preview did not reach expected rendered aspect {aspect}"
    ))
}

/// Read the SOF dimensions of the harness's JPEG previews without decoding
/// pixels. Covers baseline/progressive JPEG and skips variable-size segments.
fn jpeg_dimensions(bytes: &[u8]) -> Option<(u16, u16)> {
    if bytes.get(..2)? != [0xff, 0xd8] {
        return None;
    }
    let mut cursor: usize = 2;
    while bytes.get(cursor)? == &0xff {
        while bytes.get(cursor)? == &0xff {
            cursor += 1;
        }
        let marker = *bytes.get(cursor)?;
        cursor += 1;
        if matches!(marker, 0xd9 | 0xda) {
            return None;
        }
        if matches!(marker, 0x01 | 0xd0..=0xd8) {
            continue;
        }
        let length = u16::from_be_bytes(bytes.get(cursor..cursor + 2)?.try_into().ok()?);
        if length < 2 {
            return None;
        }
        let segment = bytes.get(cursor..cursor.checked_add(usize::from(length))?)?;
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) && length >= 7 {
            let height = u16::from_be_bytes(segment.get(3..5)?.try_into().ok()?);
            let width = u16::from_be_bytes(segment.get(5..7)?.try_into().ok()?);
            return (width > 0 && height > 0).then_some((width, height));
        }
        cursor += usize::from(length);
    }
    None
}

async fn exercise_albums(ctx: &Context, session: &Session, ids: &[String]) -> Result<(), String> {
    let album = session.create_album(ctx, "Suwop album contract").await?;
    session
        .rename_album(ctx, &album.id, "Suwop renamed album")
        .await?;
    session
        .change_album_members(ctx, &album.id, ids, true)
        .await?;
    let members = session.album_members(ctx, &album.id).await?;
    assert!(ids.iter().all(|id| members.iter().any(|a| &a.id == id)));
    session
        .change_album_members(ctx, &album.id, &ids[..1], false)
        .await?;
    assert!(
        session
            .album_members(ctx, &album.id)
            .await?
            .iter()
            .all(|a| a.id != ids[0])
    );
    session.delete_album(ctx, &album.id).await?;
    for id in ids {
        assert!(!session.asset(ctx, id).await?.is_trashed);
    }
    Ok(())
}

async fn exercise_metadata(ctx: &Context, session: &Session, ids: &[String]) -> Result<(), String> {
    use suwop_core::metadata::{MetadataAction, MetadataInput, normalize};
    let mut before = Vec::new();
    for id in ids {
        before.push(session.asset(ctx, id).await?);
    }
    let date = MetadataInput {
        action: MetadataAction::SetCapturedAt,
        captured_at: Some(1_730_615_400.125),
        time_zone: Some("America/New_York".into()),
        latitude: None,
        longitude: None,
    };
    let originals = session.metadata(ctx, ids, &normalize(&date)?).await?;
    for (asset, original) in originals.iter().zip(&before) {
        assert_eq!(
            asset.record(&session.scope, None, None).captured_at,
            date.captured_at
        );
        let exif = asset.exif_info.as_ref().ok_or("missing adjusted EXIF")?;
        let prior = original.exif_info.as_ref().ok_or("missing original EXIF")?;
        assert_eq!(exif.time_zone.as_deref(), Some("America/New_York"));
        assert_eq!(
            (exif.latitude, exif.longitude),
            (prior.latitude, prior.longitude)
        );
        assert_eq!(asset.id, original.id);
        assert_eq!(asset.checksum, original.checksum);
        assert_eq!(asset.original_file_name, original.original_file_name);
        assert_eq!(asset.is_favorite, original.is_favorite);
        assert_eq!(asset.is_trashed, original.is_trashed);
    }
    let location = MetadataInput {
        action: MetadataAction::SetLocation,
        captured_at: None,
        time_zone: None,
        latitude: Some("0".into()),
        longitude: Some("0".into()),
    };
    let located = session.metadata(ctx, ids, &normalize(&location)?).await?;
    for (asset, before) in located.iter().zip(&originals) {
        assert_eq!(asset.id, before.id);
        assert_eq!(asset.checksum, before.checksum);
        assert_eq!(asset.original_file_name, before.original_file_name);
        assert_eq!(
            asset.record(&session.scope, None, None).captured_at,
            date.captured_at
        );
        let exif = asset.exif_info.as_ref().ok_or("missing adjusted EXIF")?;
        assert_eq!((exif.latitude, exif.longitude), (Some(0.0), Some(0.0)));
        assert_eq!(exif.time_zone.as_deref(), Some("America/New_York"));
        assert_eq!(asset.is_favorite, before.is_favorite);
        assert_eq!(asset.is_trashed, before.is_trashed);
    }
    Ok(())
}

fn execute(agent: &ureq::Agent, spec: &HttpRequest) -> Result<Value, String> {
    let mut builder = ureq::http::Request::builder()
        .method(spec.method.as_str())
        .uri(&spec.url);
    for (key, value) in &spec.headers {
        builder = builder.header(key, value);
    }
    let body = if spec.files.is_empty() {
        if let Some(body) = &spec.body {
            builder = builder.header("Content-Type", "application/json");
            serde_json::to_vec(body).map_err(|e| e.to_string())?
        } else {
            Vec::new()
        }
    } else {
        builder = builder.header(
            "Content-Type",
            "multipart/form-data; boundary=suwop-fixture",
        );
        multipart(spec)?
    };
    let request = builder.body(body).map_err(|e| e.to_string())?;
    let mut response = agent.run(request).map_err(|e| e.to_string())?;
    let status = response.status().as_u16();
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    let body = if let Some(path) = &spec.download_path {
        std::fs::write(path, bytes).map_err(|e| e.to_string())?;
        Value::Null
    } else if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).map_err(|e| format!("HTTP {status}: {e}"))?
    };
    serde_json::to_value(HttpResponse {
        status,
        body,
        path: spec.download_path.clone(),
    })
    .map_err(|e| e.to_string())
}

fn multipart(spec: &HttpRequest) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    for (field, value) in &spec.fields {
        bytes.extend_from_slice(format!("--suwop-fixture\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    for file in &spec.files {
        bytes.extend_from_slice(format!("--suwop-fixture\r\nContent-Disposition: form-data; name=\"{}\"; filename=\"{}\"\r\nContent-Type: application/octet-stream\r\n\r\n", file.field, file.filename).as_bytes());
        bytes.extend_from_slice(&std::fs::read(&file.path).map_err(|e| e.to_string())?);
        bytes.extend_from_slice(b"\r\n");
    }
    bytes.extend_from_slice(b"--suwop-fixture--\r\n");
    Ok(bytes)
}

async fn upload_sidecar(
    ctx: &Context,
    session: &Session,
    file: &TransferFile,
    directory: &Path,
    now: f64,
) -> Result<String, String> {
    let sidecar = directory.join("pixel.xmp");
    std::fs::write(&sidecar, b"<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
        .map_err(|e| e.to_string())?;
    let mut request = session.request("assets", "POST", None);
    request.fields = BTreeMap::from([
        ("fileCreatedAt".into(), immich::date_string(now)),
        ("fileModifiedAt".into(), immich::date_string(now)),
    ]);
    request.files = vec![
        UploadPart {
            field: "assetData".into(),
            path: file.path.clone(),
            filename: file.resource.name.clone(),
        },
        UploadPart {
            field: "sidecarData".into(),
            path: sidecar.to_string_lossy().into_owned(),
            filename: "pixel.xmp".into(),
        },
    ];
    let response: HttpResponse = suwop_core::app::io(ctx, ShellOperation::Http(request)).await?;
    immich::check_status(response.status)?;
    Ok(response.body["id"]
        .as_str()
        .ok_or("missing sidecar asset id")?
        .to_owned())
}

fn fixture_metadata(resource: PhotoResource, index: usize, now: f64) -> StoredAsset {
    StoredAsset {
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "fixture".into(),
            asset_id: index.to_string(),
        },
        name: resource.name.clone(),
        captured_at: Some(now),
        modified_at: Some(now),
        revision: "fixture".into(),
        resources: vec![resource],
        is_favorite: true,
        latitude: Some(35.681_236),
        longitude: Some(139.767_125),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

async fn create_marked_date_fixture(
    ctx: &Context,
    session: &Session,
    file: &TransferFile,
    origin: &suwop_core::immich::UploadIntent,
    now: f64,
) -> Result<String, String> {
    let (id, created) = session
        .create_intended_upload(ctx, file, origin, now)
        .await?;
    assert!(created);
    assert_eq!(session.reconcile_upload_intent(ctx, origin).await?, id);
    let plan = session
        .prepare_upload_metadata(ctx, &id, &origin.source)
        .await?;
    session.apply_upload_metadata(ctx, &id, plan.body).await?;
    Ok(id)
}

async fn verify_duplicate_keeps_origin(
    ctx: &Context,
    session: &Session,
    file: &TransferFile,
    origin: &suwop_core::immich::UploadIntent,
    metadata: &StoredAsset,
    now: f64,
) -> Result<(), String> {
    let id = session.reconcile_upload_intent(ctx, origin).await?;
    let mut other_origin = origin.clone();
    other_origin.token = origin
        .token
        .replace("44444444-4444-4444-8444", "55555555-5555-4555-8555");
    other_origin.source = metadata.clone();
    let (duplicate, created) = session
        .create_intended_upload(ctx, file, &other_origin, now)
        .await?;
    assert!(!created);
    assert_eq!(duplicate, id);
    assert!(
        session
            .reconcile_upload_intent(ctx, &other_origin)
            .await
            .is_err()
    );
    assert_eq!(session.reconcile_upload_intent(ctx, origin).await?, id);
    Ok(())
}

fn date_fixture_origin(
    session: &Session,
    file: &TransferFile,
    metadata: &StoredAsset,
    index: usize,
) -> suwop_core::immich::UploadIntent {
    suwop_core::immich::UploadIntent {
        scope: session.scope.clone(),
        token: format!("44444444-4444-4444-8444-{index:012}"),
        source: metadata.clone(),
        resource: file.resource.clone(),
        signature: file.signature.clone(),
        live_id: None,
    }
}
