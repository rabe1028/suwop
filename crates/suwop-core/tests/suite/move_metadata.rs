//! Replay the Z3 witness against the shared verifier and the real Crux workflow.
use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, TransferBundle, TransferFile,
        TransferIntent, TransferPhase, TransferReceipt, apple_import_plan, verify_destination,
        verify_source,
    },
    immich::{Asset, HttpResponse, Session, Version},
    workflow::HashResult,
};

const IDS: [&str; 2] = [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
];
const OWNER: &str = "33333333-3333-4333-8333-333333333333";

fn native(index: usize) -> Result<Value, String> {
    let witness: Value = serde_json::from_str(include_str!(
        "../../../../formal/move-metadata-witness.json"
    ))
    .map_err(|e| e.to_string())?;
    let field = if index == 0 {
        "source_a_date"
    } else {
        "source_b_date"
    };
    let seconds = witness[field].as_u64().ok_or("missing date")?;
    let date = format!("1970-01-01T00:00:{seconds:02}Z");
    Ok(json!({
        "id": IDS[index], "ownerId": OWNER, "type": "IMAGE",
        "originalFileName": if index == 0 { "photo.jpg" } else { "photo.dng" },
        "checksum": if index == 0 { "a".repeat(40) } else { "b".repeat(40) },
        "fileCreatedAt": date, "fileModifiedAt": date, "updatedAt": date,
        "isFavorite": false, "isOffline": false, "isTrashed": false,
        "isEdited": false, "isExternal": false, "visibility": "timeline",
        "exifInfo": { "dateTimeOriginal": date, "fileSizeInByte": 12 }
    }))
}

fn source() -> Result<TransferBundle, String> {
    let mut assets = Vec::new();
    let mut files = Vec::new();
    for index in 0..2 {
        let native: Asset = serde_json::from_value(native(index)?).map_err(|e| e.to_string())?;
        let asset = native.record("immich", None, Some(&[]));
        files.push(TransferFile {
            resource: asset.resources[0].clone(),
            path: format!("/tmp/formal-audit/source/{index}-0"),
            signature: signature(index),
        });
        assets.push(asset);
    }
    Ok(TransferBundle { assets, files })
}

fn signature(index: usize) -> suwop_core::domain::FileSignature {
    suwop_core::domain::FileSignature {
        sha256: if index == 0 {
            "a".repeat(64)
        } else {
            "b".repeat(64)
        },
        bytes: 12,
    }
}

fn fixture() -> Result<(TransferBundle, TransferBundle, TransferReceipt), String> {
    let source = source()?;
    // Use the real import planner: JPEG + RAW becomes one Apple asset with
    // the first source's metadata. This is also a normal catalog group via
    // the Apple asset's two checksums, without duplicate source byte strings.
    let plan = apple_import_plan(&source)?;
    let mut apple = plan.metadata;
    apple.key = AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: "paired".into(),
    };
    apple.resources = plan
        .entries
        .iter()
        .map(|e| e.file.resource.clone())
        .collect();
    let destination = TransferBundle {
        assets: vec![apple],
        files: source.files.clone(),
    };
    let receipt = TransferReceipt {
        id: "audit".into(),
        created_at: 20.0,
        phase: TransferPhase::Copied,
        intent: TransferIntent::Move,
        source: source.assets.clone(),
        destination: destination.assets.clone(),
        destination_provider: Provider::Apple,
        destination_scope: "apple".into(),
        signatures: source.signatures(),
    };
    Ok((source, destination, receipt))
}

#[test]
fn z3_witness_should_reject_loss_of_the_second_sources_capture_date() -> Result<(), String> {
    let (mut source, destination, receipt) = fixture()?;
    source.validate()?;
    destination.validate()?;
    source.block_duplicates();
    assert!(source.assets.iter().all(|a| a.deletion_blockers.is_empty()));
    verify_source(&receipt, &mut source)?;
    assert_ne!(
        source.assets[1].captured_at,
        destination.assets[0].captured_at
    );
    assert!(
        verify_destination(&receipt, &destination).is_err(),
        "accepted a Move that loses the second source's capture date"
    );
    Ok(())
}

fn replay_core(
    source: &TransferBundle,
    destination: &TransferBundle,
    receipt: TransferReceipt,
) -> Core<Suwop> {
    let snapshot = |provider, assets| LibrarySnapshot {
        provider,
        scope: if provider == Provider::Apple {
            "apple"
        } else {
            "immich"
        }
        .into(),
        assets,
        access: ScanAccess::Full,
        scanned_at: Some(20.0),
    };
    let state = SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        receipts: vec![receipt],
        snapshots: vec![
            snapshot(Provider::Immich, source.assets.clone()),
            snapshot(Provider::Apple, destination.assets.clone()),
        ],
        ..SavedLibrary::default()
    };
    let photos = suwop_core::domain::catalog(&state.snapshots, &state.receipts);
    assert_eq!(photos.len(), 1, "normal UI can select this complete group");
    Core::new_with(
        Suwop,
        Model {
            state,
            ready: true,
            session: Some(Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://test.invalid/api".into(),
                key: "test".into(),
                user_id: OWNER.into(),
                scope: "immich".into(),
                version: Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            ..Model::default()
        },
    )
}

#[test]
fn z3_witness_should_not_reach_delete_in_the_real_crux_workflow() -> Result<(), String> {
    let (source, destination, receipt) = fixture()?;
    let core = replay_core(&source, &destination, receipt);
    let mut effects = core.process_event(Event::CompleteMove {
        id: "audit".into(),
        workspace: "audit".into(),
    });
    let mut deleted = 0;
    let mut durable = TransferPhase::Copied;
    let mut steps = 0;
    while !effects.is_empty() {
        steps += 1;
        assert!(steps < 100, "effect loop must terminate");
        let Effect::Io(mut request) = effects.remove(0);
        let value = match &request.operation {
            ShellOperation::Workspace { .. } => json!("/tmp/formal-audit"),
            ShellOperation::Cleanup { .. } => Value::Null,
            ShellOperation::Persist(state) => {
                durable = state.receipts[0].phase;
                Value::Null
            }
            ShellOperation::AppleExport { .. } => {
                serde_json::to_value(&destination).map_err(|e| e.to_string())?
            }
            ShellOperation::HashFile { path } => {
                let index = usize::from(path.ends_with("1-0"));
                serde_json::to_value(HashResult {
                    sha1: source.files[index]
                        .resource
                        .sha1
                        .clone()
                        .ok_or("missing hash")?,
                    signature: signature(index),
                })
                .map_err(|e| e.to_string())?
            }
            ShellOperation::Http(http) | ShellOperation::HttpDeletion(http) => {
                let body = if http.method == "DELETE" {
                    assert_eq!(durable, TransferPhase::DeletingSource);
                    deleted += http
                        .body
                        .as_ref()
                        .and_then(|b| b["ids"].as_array())
                        .ok_or("missing delete ids")?
                        .len();
                    Value::Null
                } else if http.download_path.is_some() {
                    Value::Null
                } else if http.url.contains("asset-files") {
                    json!([])
                } else {
                    let index = IDS
                        .iter()
                        .position(|id| http.url.ends_with(id))
                        .ok_or("unexpected HTTP")?;
                    native(index)?
                };
                serde_json::to_value(HttpResponse {
                    status: 200,
                    body,
                    path: http.download_path.clone(),
                })
                .map_err(|e| e.to_string())?
            }
            operation => return Err(format!("unexpected effect: {operation:?}")),
        };
        effects.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|e| e.to_string())?,
        );
    }
    assert!(
        core.view()
            .error
            .as_deref()
            .is_some_and(|error| error.contains("転送元すべての撮影日時・位置情報・お気に入り")),
        "unexpected failure: {:?}",
        core.view().error
    );
    assert!(!core.view().busy);
    assert_eq!(durable, TransferPhase::Copied);
    assert_eq!(core.view().state.receipts[0].phase, TransferPhase::Copied);
    assert_eq!(
        deleted, 0,
        "Move deleted originals even though the second capture date was lost"
    );
    Ok(())
}

#[test]
fn a_new_move_cannot_gain_verified_destination_evidence_from_the_witness() -> Result<(), String> {
    let (_, destination, mut receipt) = fixture()?;
    receipt.phase = TransferPhase::Copying;
    receipt.destination.clear();
    let created = destination
        .assets
        .iter()
        .map(|a| a.key.clone())
        .collect::<Vec<_>>();
    assert!(suwop_core::transfer_lifecycle::verify_copy(&receipt, &created, &destination).is_err());
    receipt.intent = TransferIntent::Copy;
    assert!(suwop_core::transfer_lifecycle::verify_copy(&receipt, &created, &destination).is_ok());
    Ok(())
}
