use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    media::{PlaybackKind, PreviewAccess, files, kind, selected_preview, source},
    workflow::HashResult,
};

fn asset(kind: PlaybackKind) -> StoredAsset {
    let roles = match kind {
        PlaybackKind::Video => vec![ResourceRole::Video],
        PlaybackKind::Live => vec![ResourceRole::Image, ResourceRole::LiveVideo],
    };
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        },
        name: "media.mov".into(),
        captured_at: None,
        modified_at: None,
        revision: "1".into(),
        resources: roles
            .into_iter()
            .enumerate()
            .map(|(i, role)| PhotoResource {
                id: i.to_string(),
                name: if role == ResourceRole::Image {
                    "still.jpg"
                } else {
                    "video.mov"
                }
                .into(),
                role,
                sha1: Some((i + 1).to_string().repeat(40)),
                bytes: Some(12),
            })
            .collect(),
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn snapshot(asset: StoredAsset, access: ScanAccess) -> LibrarySnapshot {
    LibrarySnapshot {
        provider: asset.key.provider,
        scope: asset.key.scope.clone(),
        assets: vec![asset],
        access,
        scanned_at: None,
    }
}
fn session() -> suwop_core::immich::Session {
    suwop_core::immich::Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "fixture".into(),
        user_id: "user".into(),
        scope: "remote".into(),
        version: suwop_core::immich::Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    }
}
fn preview_source(
    photo: &suwop_core::domain::UnifiedPhoto,
    snapshots: &[LibrarySnapshot],
) -> Option<AssetKey> {
    selected_preview(&PreviewAccess::new(snapshots, "apple", Some(&session())).choices(photo, &[]))
}
fn bundle(kind: PlaybackKind, directory: &str) -> TransferBundle {
    let asset = asset(kind);
    TransferBundle {
        files: asset
            .resources
            .iter()
            .map(|r| TransferFile {
                resource: r.clone(),
                path: format!("{directory}/{}", r.id),
                signature: FileSignature {
                    sha256: "a".repeat(64),
                    bytes: 12,
                },
            })
            .collect(),
        assets: vec![asset],
    }
}
fn core(kind: PlaybackKind) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                snapshots: vec![snapshot(asset(kind), ScanAccess::Limited)],
                ..SavedLibrary::default()
            },
            ..Model::default()
        },
    )
}
fn event(kind: PlaybackKind) -> Event {
    Event::Play {
        keys: vec![asset(kind).key],
        id: "11111111-1111-4111-8111-111111111111".into(),
    }
}
fn response(value: Value) -> ShellResponse {
    ShellResponse {
        value: Some(value),
        error: None,
    }
}

#[test]
fn playback_selects_one_accessible_catalog_photo_and_rejects_invalid_inventory()
-> Result<(), String> {
    for kind in [PlaybackKind::Video, PlaybackKind::Live] {
        let local = asset(kind);
        let mut remote = local.clone();
        remote.key.provider = Provider::Immich;
        remote.key.scope = "remote".into();
        let keys = vec![local.key.clone(), remote.key.clone()];
        let mut snapshots = vec![
            snapshot(local.clone(), ScanAccess::Limited),
            snapshot(remote.clone(), ScanAccess::Full),
        ];
        assert_eq!(source(&snapshots, &[], &keys)?, (local.key.clone(), kind));
        snapshots[0].access = ScanAccess::Unavailable;
        assert_eq!(source(&snapshots, &[], &keys)?, (remote.key.clone(), kind));
        snapshots[1].assets[0].is_offline = true;
        assert!(source(&snapshots, &[], &keys).is_err());
        snapshots[1].assets[0].is_offline = false;
        snapshots[1].assets[0].inventory_complete = false;
        assert!(source(&snapshots, &[], &keys).is_err());
        assert!(source(&snapshots, &[], &[]).is_err());
        assert!(
            source(
                &snapshots,
                &[],
                &[AssetKey {
                    asset_id: "missing".into(),
                    ..local.key
                }]
            )
            .is_err()
        );
    }
    let mut snapshot = snapshot(asset(PlaybackKind::Video), ScanAccess::Full);
    let mut second = snapshot.assets[0].clone();
    second.key.asset_id = "second".into();
    second.resources[0].sha1 = Some("f".repeat(40));
    snapshot.assets.push(second);
    let keys: Vec<_> = snapshot.assets.iter().map(|a| a.key.clone()).collect();
    assert!(source(&[snapshot], &[], &keys).is_err());
    Ok(())
}

#[test]
fn live_playback_requires_the_exact_still_and_companion_not_raw_or_auxiliary_files()
-> Result<(), String> {
    let mut bundle = bundle(PlaybackKind::Live, "/tmp/media");
    assert_eq!(files(&bundle, PlaybackKind::Live)?.len(), 2);
    assert_eq!(
        files(&bundle, PlaybackKind::Live)?[1].resource.role,
        ResourceRole::LiveVideo
    );
    assert!(files(&bundle, PlaybackKind::Video).is_err());
    bundle.files.push(bundle.files[1].clone());
    assert!(files(&bundle, PlaybackKind::Live).is_err());
    bundle.files.pop();
    bundle.files.remove(0);
    assert!(files(&bundle, PlaybackKind::Live).is_err());
    bundle.assets[0].resources[0].role = ResourceRole::RawImage;
    assert!(files(&bundle, PlaybackKind::Live).is_err());
    Ok(())
}

#[test]
fn live_parent_is_selected_before_its_standalone_companion_regardless_of_ids() -> Result<(), String>
{
    let mut parent = asset(PlaybackKind::Live);
    parent.key.provider = Provider::Immich;
    parent.key.scope = "remote".into();
    parent.key.asset_id = "z-parent".into();
    let mut companion = asset(PlaybackKind::Video);
    companion.key = AssetKey {
        asset_id: "a-companion".into(),
        ..parent.key.clone()
    };
    companion.resources[0]
        .sha1
        .clone_from(&parent.resources[1].sha1);
    let mut remote = snapshot(parent.clone(), ScanAccess::Full);
    remote.assets.push(companion.clone());
    let mut snapshots = vec![remote];
    let photos = suwop_core::domain::catalog(&snapshots, &[]);
    assert_eq!(photos.len(), 1);
    assert_eq!(photos[0].assets[0].key, companion.key);
    assert_eq!(kind(&photos[0]), Some(PlaybackKind::Live));
    assert_eq!(
        preview_source(&photos[0], &snapshots),
        Some(parent.key.clone())
    );
    assert_eq!(
        source(&snapshots, &[], &[companion.key.clone()])?,
        (parent.key.clone(), PlaybackKind::Live)
    );
    // An Apple copy of only the motion component does not provide a Live pair.
    let mut local_companion = companion.clone();
    local_companion.key.provider = Provider::Apple;
    local_companion.key.scope = "apple".into();
    snapshots.push(snapshot(local_companion, ScanAccess::Limited));
    assert_eq!(
        source(&snapshots, &[], &[companion.key.clone()])?,
        (parent.key.clone(), PlaybackKind::Live)
    );
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                snapshots: snapshots.clone(),
                ..SavedLibrary::default()
            },
            session: Some(session()),
            ..Model::default()
        },
    );
    assert_eq!(core.view().media.values().next(), Some(&PlaybackKind::Live));
    assert_eq!(
        core.view().preview_sources.values().next(),
        Some(&parent.key)
    );
    // Do not fall back to an ordinary video when its Live parent is incomplete.
    snapshots[0].assets[0].inventory_complete = false;
    assert!(source(&snapshots, &[], &[companion.key.clone()]).is_err());
    let mut local_parent = parent.clone();
    local_parent.key.provider = Provider::Apple;
    local_parent.key.scope = "apple".into();
    snapshots[1].assets.push(local_parent.clone());
    let photos = suwop_core::domain::catalog(&snapshots, &[]);
    assert_eq!(
        preview_source(&photos[0], &snapshots),
        Some(local_parent.key.clone())
    );
    snapshots[1].access = ScanAccess::Unavailable;
    assert_eq!(
        preview_source(&photos[0], &snapshots),
        Some(parent.key.clone())
    );
    snapshots[0].access = ScanAccess::Unavailable;
    assert_eq!(preview_source(&photos[0], &snapshots), None);
    snapshots[1].access = ScanAccess::Limited;
    assert_eq!(
        source(&snapshots, &[], &[companion.key])?,
        (local_parent.key, PlaybackKind::Live)
    );
    Ok(())
}

fn prepare(operation: &ShellOperation, kind: PlaybackKind) -> Result<Value, String> {
    match operation {
        ShellOperation::Workspace { .. } => Ok(json!("/tmp/media")),
        ShellOperation::AppleExport { directory, .. } => {
            serde_json::to_value(bundle(kind, directory)).map_err(|e| e.to_string())
        }
        ShellOperation::CopyFile {
            source,
            destination,
        } => {
            assert!(source.starts_with("/tmp/media/playback-source/"));
            assert!(destination.starts_with("/tmp/media/playback/"));
            Ok(Value::Null)
        }
        ShellOperation::HashFile { path } => {
            let i = usize::from(path.ends_with("/video.mov") && kind == PlaybackKind::Live);
            serde_json::to_value(HashResult {
                sha1: (i + 1).to_string().repeat(40),
                signature: FileSignature {
                    sha256: "a".repeat(64),
                    bytes: 12,
                },
            })
            .map_err(|e| e.to_string())
        }
        _ => Err("playback must not mutate photos or contact an unrelated server".into()),
    }
}

#[test]
fn playback_keeps_verified_originals_until_the_native_player_closes() -> Result<(), String> {
    for kind in [PlaybackKind::Video, PlaybackKind::Live] {
        let core = core(kind);
        let mut requests = core.process_event(event(kind));
        let pending = loop {
            let Effect::Io(mut request) = requests.remove(0);
            if let ShellOperation::PlayMedia { plan } = &request.operation {
                assert_eq!(plan.kind, kind);
                assert_eq!(
                    plan.files.len(),
                    if kind == PlaybackKind::Live { 2 } else { 1 }
                );
                break request;
            }
            let value = prepare(&request.operation, kind)?;
            requests.extend(
                core.resolve(&mut request, response(value))
                    .map_err(|e| e.to_string())?,
            );
        };
        assert!(requests.is_empty());
        assert!(core.view().busy);
        assert_eq!(core.view().media.len(), 1);
        let mut pending = pending;
        let mut cleanup = core
            .resolve(&mut pending, response(Value::Null))
            .map_err(|e| e.to_string())?;
        let Effect::Io(mut cleanup) = cleanup.remove(0);
        assert!(matches!(cleanup.operation, ShellOperation::Cleanup { .. }));
        assert!(
            core.resolve(&mut cleanup, response(Value::Null))
                .map_err(|e| e.to_string())?
                .is_empty()
        );
        assert!(!core.view().busy);
        assert!(core.view().error.is_none());
        assert_eq!(core.view().photos.len(), 1);
        assert!(core.view().state.receipts.is_empty());
    }
    Ok(())
}

#[test]
fn playback_rejects_escaped_files_or_changed_content_and_reports_cleanup_failures()
-> Result<(), String> {
    for fault in ["escape", "hash", "native", "cleanup"] {
        let kind = PlaybackKind::Video;
        let core = core(kind);
        let mut requests = core.process_event(event(kind));
        let mut played = false;
        let mut cleaned = false;
        while !requests.is_empty() {
            let Effect::Io(mut request) = requests.remove(0);
            let value = match &request.operation {
                ShellOperation::AppleExport { .. } if fault == "escape" => {
                    serde_json::to_value(bundle(kind, "/tmp/unrelated"))
                        .map_err(|e| e.to_string())?
                }
                ShellOperation::HashFile { .. } if fault == "hash" => {
                    serde_json::to_value(HashResult {
                        sha1: "1".repeat(40),
                        signature: FileSignature {
                            bytes: 12,
                            sha256: "b".repeat(64),
                        },
                    })
                    .map_err(|e| e.to_string())?
                }
                ShellOperation::PlayMedia { .. } => {
                    played = true;
                    Value::Null
                }
                ShellOperation::Cleanup { .. } => {
                    cleaned = true;
                    Value::Null
                }
                operation => prepare(operation, kind)?,
            };
            let failed = (fault == "native"
                && matches!(request.operation, ShellOperation::PlayMedia { .. }))
                || (fault == "cleanup"
                    && matches!(request.operation, ShellOperation::Cleanup { .. }));
            let response = if failed {
                ShellResponse {
                    value: None,
                    error: Some("cancelled or cleanup failed".into()),
                }
            } else {
                response(value)
            };
            requests.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(cleaned);
        assert_eq!(played, matches!(fault, "native" | "cleanup"));
        assert!(core.view().error.is_some());
        assert!(!core.view().busy);
        assert_eq!(core.view().photos.len(), 1);
    }
    Ok(())
}

#[test]
fn remote_playback_reads_the_authenticated_original_and_never_mutates_the_server()
-> Result<(), String> {
    let mut video = asset(PlaybackKind::Video);
    video.key = AssetKey {
        provider: Provider::Immich,
        scope: "remote".into(),
        asset_id: "11111111-1111-4111-8111-111111111111".into(),
    };
    let keys = vec![video.key.clone()];
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                snapshots: vec![snapshot(video, ScanAccess::Full)],
                ..SavedLibrary::default()
            },
            session: Some(suwop_core::immich::Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://server/api".into(),
                key: "test-key".into(),
                user_id: "22222222-2222-4222-8222-222222222222".into(),
                scope: "remote".into(),
                version: suwop_core::immich::Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            ..Model::default()
        },
    );
    let mut requests = core.process_event(Event::Play {
        keys,
        id: "11111111-1111-4111-8111-111111111111".into(),
    });
    let mut played = false;
    let mut cleaned = false;
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let value = match &request.operation {
            ShellOperation::Http(http) => {
                assert_eq!(http.method, "GET");
                assert_eq!(
                    http.headers.get("x-api-key").map(String::as_str),
                    Some("test-key")
                );
                let body = if http.download_path.is_some() {
                    assert!(http.url.ends_with("/original?edited=false"));
                    Value::Null
                } else if http.url.contains("/asset-files?") {
                    json!([])
                } else {
                    json!({"id":"11111111-1111-4111-8111-111111111111","ownerId":"22222222-2222-4222-8222-222222222222","type":"VIDEO","originalFileName":"video.mov","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,"exifInfo":{"fileSizeInByte":12}})
                };
                serde_json::to_value(suwop_core::immich::HttpResponse {
                    status: 200,
                    body,
                    path: http.download_path.clone(),
                })
                .map_err(|e| e.to_string())?
            }
            ShellOperation::PlayMedia { plan } => {
                assert_eq!(plan.kind, PlaybackKind::Video);
                played = true;
                Value::Null
            }
            ShellOperation::Cleanup { .. } => {
                cleaned = true;
                Value::Null
            }
            operation => prepare(operation, PlaybackKind::Video)?,
        };
        requests.extend(
            core.resolve(&mut request, response(value))
                .map_err(|e| e.to_string())?,
        );
    }
    assert!(played && cleaned);
    assert!(core.view().error.is_none());
    assert_eq!(core.view().photos.len(), 1);
    assert!(core.view().state.receipts.is_empty());
    Ok(())
}

#[test]
fn apple_change_during_delayed_playback_preparation_never_opens_player() -> Result<(), String> {
    for kind in [PlaybackKind::Video, PlaybackKind::Live] {
        let core = core(kind);
        let mut requests = core.process_event(event(kind));
        let mut changed = false;
        let mut cleaned = false;
        while !requests.is_empty() {
            let Effect::Io(mut request) = requests.remove(0);
            assert!(!matches!(
                request.operation,
                ShellOperation::PlayMedia { .. }
            ));
            let value = if matches!(request.operation, ShellOperation::Cleanup { .. }) {
                cleaned = true;
                Value::Null
            } else {
                if !changed && matches!(request.operation, ShellOperation::HashFile { .. }) {
                    assert!(core.process_event(Event::AppleChanged).is_empty());
                    changed = true;
                }
                prepare(&request.operation, kind)?
            };
            requests.extend(
                core.resolve(&mut request, response(value))
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(changed && cleaned);
        assert!(core.view().error.is_some());
    }
    Ok(())
}

#[test]
fn unverified_live_pair_remains_one_playable_selection() -> Result<(), String> {
    let mut apple = asset(PlaybackKind::Live);
    apple.captured_at = Some(100.125);
    for resource in &mut apple.resources {
        resource.sha1 = None;
    }
    let mut remote = apple.clone();
    remote.key.provider = Provider::Immich;
    remote.key.scope = "remote".into();
    let keys = vec![apple.key.clone(), remote.key.clone()];
    let snapshots: Vec<_> = [apple, remote]
        .into_iter()
        .map(|a| LibrarySnapshot {
            provider: a.key.provider,
            scope: a.key.scope.clone(),
            assets: vec![a],
            access: ScanAccess::Full,
            scanned_at: Some(200.0),
        })
        .collect();
    assert_eq!(
        source(&snapshots, &[], &keys)?,
        (keys[0].clone(), PlaybackKind::Live)
    );
    Ok(())
}
