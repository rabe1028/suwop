use crux_core::Command;
use serde_json::{Value, json};
use std::collections::VecDeque;
use suwop_core::{
    app::{Effect, Event, SavedLibrary, ShellOperation, ShellResponse},
    domain::{
        AssetKey, FileSignature, PhotoResource, Provider, ResourceRole, StoredAsset, TransferFile,
    },
    immich::{HttpRequest, HttpResponse, Session, Version},
};

const ID: &str = "11111111-1111-4111-8111-111111111111";

fn metadata() -> StoredAsset {
    StoredAsset {
        immich_parent_revision: None,
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        },
        name: "photo.png".into(),
        captured_at: Some(1_730_615_400.125),
        modified_at: Some(1_730_615_500.25),
        revision: "adjusted".into(),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: "photo.png".into(),
            role: ResourceRole::Image,
            sha1: Some("a".repeat(40)),
            bytes: Some(233),
        }],
        is_favorite: true,
        latitude: Some(0.0),
        longitude: Some(0.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

fn response(status: u16, body: Value) -> HttpResponse {
    HttpResponse {
        status,
        body,
        path: None,
    }
}

struct UploadRun {
    requests: Vec<HttpRequest>,
    waits: usize,
    result: Result<String, String>,
}

fn upload(
    metadata: StoredAsset,
    major: u32,
    responses: Vec<HttpResponse>,
) -> Result<UploadRun, String> {
    upload_with_wait(metadata, major, responses, false)
}

fn upload_with_wait(
    metadata: StoredAsset,
    major: u32,
    responses: Vec<HttpResponse>,
    cancel_wait: bool,
) -> Result<UploadRun, String> {
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let session = Session {
            ordinary_content_guard: None,
            ordinary_content_context: None,
            endpoint: "https://photos.example/proxy/api".into(),
            key: "fixture".into(),
            user_id: "owner".into(),
            scope: "remote".into(),
            version: Version {
                major,
                minor: 2,
                patch: 4,
            },
        };
        let file = TransferFile {
            resource: metadata.resources[0].clone(),
            path: "/tmp/fixture.png".into(),
            signature: FileSignature {
                sha256: "a".repeat(64),
                bytes: 233,
            },
        };
        let result = session
            .upload(&ctx, &file, &metadata, 1_730_615_800.0, None)
            .await;
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status: result.as_ref().ok().cloned().unwrap_or_default(),
            error: result.err(),
            preview_to_select: None,
        });
    });
    let mut responses: VecDeque<_> = responses.into();
    let mut requests = Vec::new();
    let mut waits = 0;
    loop {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for effect in effects {
            let Effect::Io(mut request) = effect;
            let value = match &request.operation {
                ShellOperation::Http(http) => {
                    requests.push(http.clone());
                    serde_json::to_value(responses.pop_front().ok_or("unexpected HTTP retry")?)
                        .map_err(|e| e.to_string())?
                }
                ShellOperation::Wait { milliseconds } => {
                    assert_eq!(*milliseconds, 250);
                    waits += 1;
                    if cancel_wait {
                        request
                            .resolve(ShellResponse {
                                value: None,
                                error: Some("cancelled".into()),
                            })
                            .map_err(|e| e.to_string())?;
                        continue;
                    }
                    Value::Null
                }
                _ => return Err("unexpected native effect".into()),
            };
            request
                .resolve(ShellResponse {
                    value: Some(value),
                    error: None,
                })
                .map_err(|e| e.to_string())?;
        }
    }
    let result = match command.events().last().ok_or("upload did not finish")? {
        Event::Finished {
            status,
            error: None,
            ..
        } => Ok(status),
        Event::Finished {
            error: Some(error), ..
        } => Err(error),
        _ => return Err("unexpected upload result".into()),
    };
    assert!(responses.is_empty());
    Ok(UploadRun {
        requests,
        waits,
        result,
    })
}

fn extracted_date(date: Option<&str>) -> HttpResponse {
    response(
        200,
        json!({
            "id":ID,"ownerId":"owner","type":"IMAGE","originalFileName":"photo.png",
            "checksum":"a".repeat(40),"fileCreatedAt":"2024-11-03T06:30:00.125Z",
            "fileModifiedAt":"2024-11-03T06:31:40.250Z","updatedAt":"2024-11-03T06:31:40Z",
            "isFavorite":true,"isOffline":false,"isTrashed":false,
            "exifInfo":{"dateTimeOriginal":date}
        }),
    )
}

#[test]
fn a_new_copy_locks_the_adjusted_capture_instant_without_changing_file_timestamps()
-> Result<(), String> {
    for major in [2, 3] {
        let run = upload(
            metadata(),
            major,
            vec![
                response(201, json!({"id":ID,"status":"created"})),
                extracted_date(Some("2020-01-01T00:00:00Z")),
                response(200, Value::Null),
            ],
        )?;
        assert_eq!(run.result?, ID);
        assert_eq!(run.requests.len(), 3);
        let post = &run.requests[0];
        assert_eq!(post.method, "POST");
        assert_eq!(post.url, "https://photos.example/proxy/api/assets");
        assert_eq!(post.fields["fileCreatedAt"], "2024-11-03T06:30:00.125Z");
        assert_eq!(post.fields["fileModifiedAt"], "2024-11-03T06:31:40.250Z");
        assert_eq!(post.files[0].path, "/tmp/fixture.png");
        assert_eq!(post.headers["x-immich-checksum"], "a".repeat(40));
        assert_eq!(run.requests[1].method, "GET");
        let put = &run.requests[2];
        assert_eq!(put.method, "PUT");
        assert_eq!(
            put.url,
            format!("https://photos.example/proxy/api/assets/{ID}")
        );
        assert_eq!(
            put.body,
            Some(json!({
                "dateTimeOriginal":"2024-11-03T06:30:00.125Z","isFavorite":true,
                "latitude":0.0,"longitude":0.0,
            }))
        );
    }
    Ok(())
}

#[test]
fn duplicate_copies_do_not_overwrite_independent_capture_dates_or_other_metadata()
-> Result<(), String> {
    let run = upload(
        metadata(),
        3,
        vec![response(200, json!({"id":ID,"status":"duplicate"}))],
    )?;
    assert_eq!(run.result?, ID);
    assert_eq!(run.requests.len(), 1);
    assert_eq!(run.requests[0].method, "POST");
    Ok(())
}

#[test]
fn an_unknown_library_date_does_not_invent_an_exif_adjustment() -> Result<(), String> {
    let mut unknown = metadata();
    unknown.captured_at = None;
    unknown.modified_at = None;
    let run = upload(
        unknown,
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            extracted_date(Some("2020-01-01T00:00:00Z")),
            response(200, Value::Null),
        ],
    )?;
    assert!(run.result.is_ok());
    assert_eq!(
        run.requests[0].fields["fileCreatedAt"],
        "2024-11-03T06:36:40Z"
    );
    assert!(
        run.requests[2]
            .body
            .as_ref()
            .ok_or("missing metadata update")?
            .get("dateTimeOriginal")
            .is_none()
    );
    Ok(())
}

#[test]
fn invalid_source_dates_refuse_the_upload_before_any_remote_write() -> Result<(), String> {
    for date in [
        f64::NAN,
        f64::INFINITY,
        -62_135_596_801.0,
        253_402_300_800.0,
    ] {
        for modified in [false, true] {
            let mut source = metadata();
            if modified {
                source.modified_at = Some(date);
            } else {
                source.captured_at = Some(date);
            }
            let run = upload(source, 3, vec![])?;
            assert!(run.result.is_err());
            assert!(run.requests.is_empty());
        }
    }
    Ok(())
}

#[test]
fn an_unknown_upload_or_metadata_result_never_retries_a_write() -> Result<(), String> {
    for status in ["pending", ""] {
        let run = upload(
            metadata(),
            3,
            vec![response(200, json!({"id":ID,"status":status}))],
        )?;
        assert!(run.result.is_err());
        assert_eq!(run.requests.len(), 1);
    }
    let run = upload(
        metadata(),
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            extracted_date(Some("2020-01-01T00:00:00Z")),
            response(503, Value::Null),
        ],
    )?;
    assert!(run.result.is_err());
    assert_eq!(run.requests.len(), 3);
    Ok(())
}

#[test]
fn matching_dates_do_not_generate_an_unnecessary_exif_sidecar() -> Result<(), String> {
    let mut source = metadata();
    source.latitude = None;
    source.longitude = None;
    let run = upload(
        source,
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            extracted_date(Some("2024-11-03T06:30:00.125Z")),
            response(200, Value::Null),
        ],
    )?;
    assert!(run.result.is_ok());
    assert_eq!(run.requests[2].body, Some(json!({"isFavorite":true})));
    assert_eq!(run.waits, 0);
    Ok(())
}

#[test]
fn one_millisecond_offsets_do_not_request_exif_writes_but_larger_offsets_do() -> Result<(), String>
{
    for major in [2, 3] {
        for (offset, adjustment) in [
            (0.0, false),
            (0.0005, false),
            (0.001, false),
            (-0.001, false),
            (0.002, true),
            (-0.002, true),
        ] {
            let mut source = metadata();
            source.captured_at = Some(offset);
            source.latitude = None;
            source.longitude = None;
            let run = upload(
                source,
                major,
                vec![
                    response(201, json!({"id":ID,"status":"created"})),
                    extracted_date(Some("1970-01-01T00:00:00Z")),
                    response(200, Value::Null),
                ],
            )?;
            assert!(run.result.is_ok());
            let body = run.requests[2].body.as_ref().ok_or("missing update")?;
            assert_eq!(body.get("dateTimeOriginal").is_some(), adjustment);
            assert_eq!(body["isFavorite"], true);
            assert_eq!(run.waits, 0);
        }
    }
    Ok(())
}

#[test]
fn metadata_readback_uses_the_same_inclusive_capture_tolerance() {
    let change = suwop_core::metadata::MetadataChange {
        action: suwop_core::metadata::MetadataAction::SetCapturedAt,
        captured_at: Some(0.0),
        time_zone: None,
        location: None,
    };
    for (offset, matching) in [
        (0.0, true),
        (0.0005, true),
        (0.001, true),
        (-0.001, true),
        (0.002, false),
        (-0.002, false),
        (f64::NAN, false),
        (f64::INFINITY, false),
    ] {
        let mut asset = metadata();
        asset.captured_at = Some(offset);
        let key = asset.key.clone();
        assert_eq!(
            suwop_core::metadata::verify(&[asset], &[key], &change).is_ok(),
            matching
        );
    }
}

#[test]
fn extraction_waits_read_only_then_applies_one_adjustment() -> Result<(), String> {
    let run = upload(
        metadata(),
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            extracted_date(None),
            extracted_date(Some("2020-01-01T00:00:00Z")),
            response(200, Value::Null),
        ],
    )?;
    assert!(run.result.is_ok());
    assert_eq!(run.waits, 1);
    assert_eq!(
        run.requests
            .iter()
            .map(|r| r.method.as_str())
            .collect::<Vec<_>>(),
        ["POST", "GET", "GET", "PUT"]
    );
    Ok(())
}

#[test]
fn cancelled_failed_or_timed_out_extraction_never_attempts_metadata_writes() -> Result<(), String> {
    let cancelled = upload_with_wait(
        metadata(),
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            extracted_date(None),
        ],
        true,
    )?;
    let failed = upload(
        metadata(),
        3,
        vec![
            response(201, json!({"id":ID,"status":"created"})),
            response(503, Value::Null),
        ],
    )?;
    let mut responses = vec![response(201, json!({"id":ID,"status":"created"}))];
    responses.extend((0..=120).map(|_| extracted_date(None)));
    let expired = upload(metadata(), 3, responses)?;
    assert_eq!(expired.waits, 120);
    for run in [cancelled, failed, expired] {
        assert!(run.result.is_err());
        assert_eq!(
            run.requests.iter().filter(|r| r.method == "POST").count(),
            1
        );
        assert!(!run.requests.iter().any(|r| r.method == "PUT"));
    }
    Ok(())
}
