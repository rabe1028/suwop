use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    sharing::{contains_file, filename, sources},
    workflow::HashResult,
};

const SHA1: &str = "1111111111111111111111111111111111111111";
fn asset() -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        },
        name: "original.jpg".into(),
        captured_at: None,
        modified_at: None,
        revision: "1".into(),
        resources: vec![PhotoResource {
            id: "0".into(),
            name: "original.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(SHA1.into()),
            bytes: Some(12),
        }],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn signature() -> FileSignature {
    FileSignature {
        sha256: "a".repeat(64),
        bytes: 12,
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
fn core() -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: 7,
                apple_scope: "apple".into(),
                snapshots: vec![snapshot(asset(), ScanAccess::Limited)],
                ..SavedLibrary::default()
            },
            ..Model::default()
        },
    )
}
fn event() -> Event {
    Event::Share {
        keys: vec![asset().key],
        id: "11111111-1111-4111-8111-111111111111".into(),
    }
}
#[derive(Default)]
enum Fault {
    #[default]
    None,
    Hash,
    Escape,
    Cancel,
    Cleanup,
    Remote,
}
#[derive(Default)]
struct Native {
    cleaned: bool,
    shared: bool,
    fault: Fault,
}
impl Native {
    fn handle(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) if matches!(self.fault, Fault::Remote) => {
                assert_eq!(request.method, "GET");
                assert_eq!(
                    request.headers.get("x-api-key").map(String::as_str),
                    Some("test-key")
                );
                let body = if request.url.contains("/asset-files?") {
                    json!([])
                } else if request.download_path.is_some() {
                    assert!(request.url.ends_with("/original?edited=false"));
                    Value::Null
                } else {
                    json!({"id":"11111111-1111-4111-8111-111111111111","ownerId":"22222222-2222-4222-8222-222222222222","type":"IMAGE","originalFileName":"original.jpg","checksum":SHA1,"fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,"exifInfo":{"fileSizeInByte":12}})
                };
                serde_json::to_value(suwop_core::immich::HttpResponse {
                    status: 200,
                    body,
                    path: request.download_path.clone(),
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::Workspace { .. } => Ok(json!("/tmp/share-workspace")),
            ShellOperation::AppleExport { keys, directory } => {
                if matches!(self.fault, Fault::Cancel) {
                    return Err("cancelled".into());
                }
                assert_eq!(*keys, vec![asset().key]);
                let record = asset();
                serde_json::to_value(TransferBundle {
                    assets: vec![record.clone()],
                    files: vec![TransferFile {
                        resource: record.resources[0].clone(),
                        signature: signature(),
                        path: if matches!(self.fault, Fault::Escape) {
                            "/tmp/private-file".into()
                        } else {
                            format!("{directory}/original")
                        },
                    }],
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::CopyFile { destination, .. } => {
                assert!(contains_file("/tmp/share-workspace/share", destination));
                assert!(destination.ends_with("/original.jpg"));
                Ok(Value::Null)
            }
            ShellOperation::HashFile { .. } => {
                let mut hash = signature();
                if matches!(self.fault, Fault::Hash) {
                    hash.sha256 = "b".repeat(64);
                }
                serde_json::to_value(HashResult {
                    sha1: SHA1.into(),
                    signature: hash,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::ShareFiles(presentation) => {
                let files = &presentation.files;
                let expected = if matches!(self.fault, Fault::Remote) {
                    AssetKey {
                        provider: Provider::Immich,
                        scope: "immich".into(),
                        asset_id: "11111111-1111-4111-8111-111111111111".into(),
                    }
                } else {
                    asset().key
                };
                assert_eq!(presentation.source_keys, Some(vec![expected]));
                self.shared = true;
                assert!(!self.cleaned);
                assert_eq!(files.len(), 1);
                assert_eq!(files[0].name, "original.jpg");
                Ok(json!(true))
            }
            ShellOperation::Cleanup { path } => {
                assert_eq!(path, "/tmp/share-workspace");
                if matches!(self.fault, Fault::Cleanup) {
                    return Err("cleanup failed".into());
                }
                self.cleaned = true;
                Ok(Value::Null)
            }
            _ => Err("sharing must not mutate photos, receipts, credentials or connection".into()),
        }
    }
}
fn response(result: Result<Value, String>) -> ShellResponse {
    match result {
        Ok(value) => ShellResponse {
            value: Some(value),
            error: None,
        },
        Err(error) => ShellResponse {
            value: None,
            error: Some(error),
        },
    }
}
fn run(native: &mut Native, core: &Core<Suwop>) -> Result<(), String> {
    run_event(native, core, event())
}
fn run_event(native: &mut Native, core: &Core<Suwop>, event: Event) -> Result<(), String> {
    let mut requests = core.process_event(event);
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let result = native.handle(&request.operation);
        requests.extend(
            core.resolve(&mut request, response(result))
                .map_err(|e| e.to_string())?,
        );
    }
    assert!(!core.view().busy);
    assert_eq!(core.view().photos.len(), 1);
    assert!(core.view().state.receipts.is_empty());
    Ok(())
}

#[test]
fn native_share_retains_files_until_completion_and_does_not_mutate_the_library()
-> Result<(), String> {
    for completed in [true, false] {
        let core = core();
        let mut native = Native::default();
        let mut requests = core.process_event(event());
        let mut pending = None;
        while !requests.is_empty() {
            let Effect::Io(mut request) = requests.remove(0);
            if matches!(request.operation, ShellOperation::ShareFiles(_)) {
                pending = Some(request);
                break;
            }
            let result = native.handle(&request.operation);
            requests.extend(
                core.resolve(&mut request, response(result))
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(core.view().busy);
        assert!(!native.cleaned);
        assert!(requests.is_empty());
        let mut pending = pending.ok_or("missing native sharing effect")?;
        let cleanup = core
            .resolve(&mut pending, response(Ok(json!(completed))))
            .map_err(|e| e.to_string())?;
        for Effect::Io(mut request) in cleanup {
            let result = native.handle(&request.operation);
            assert!(
                core.resolve(&mut request, response(result))
                    .map_err(|e| e.to_string())?
                    .is_empty()
            );
        }
        assert!(native.cleaned);
        assert!(!core.view().busy);
        assert!(core.view().error.is_none());
        assert_eq!(core.view().photos.len(), 1);
        assert!(core.view().state.receipts.is_empty());
        assert!(core.view().status.contains(if completed {
            "共有しました"
        } else {
            "キャンセル"
        }));
    }
    Ok(())
}

#[test]
fn sharing_presentation_records_chosen_source_instead_of_equivalent_requested_key()
-> Result<(), String> {
    let mut remote = asset();
    remote.key = AssetKey {
        provider: Provider::Immich,
        scope: "remote".into(),
        asset_id: "equivalent".into(),
    };
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: 7,
                apple_scope: "apple".into(),
                snapshots: vec![
                    snapshot(asset(), ScanAccess::Full),
                    snapshot(remote.clone(), ScanAccess::Full),
                ],
                ..SavedLibrary::default()
            },
            ..Model::default()
        },
    );
    let mut native = Native::default();
    run_event(
        &mut native,
        &core,
        Event::Share {
            keys: vec![remote.key],
            id: "11111111-1111-4111-8111-111111111111".into(),
        },
    )?;
    assert!(native.shared && native.cleaned);
    assert!(core.view().error.is_none());
    Ok(())
}

#[test]
fn failed_export_escaped_file_or_changed_staged_content_clean_up_before_sharing()
-> Result<(), String> {
    for fault in [Fault::Cancel, Fault::Escape, Fault::Hash] {
        let core = core();
        let mut native = Native {
            fault,
            ..Native::default()
        };
        run(&mut native, &core)?;
        assert!(native.cleaned);
        assert!(!native.shared);
        assert!(core.view().error.is_some());
    }
    Ok(())
}

#[test]
fn cleanup_failure_is_reported_after_native_sharing_finishes() -> Result<(), String> {
    let core = core();
    let mut native = Native {
        fault: Fault::Cleanup,
        ..Native::default()
    };
    run(&mut native, &core)?;
    assert!(native.shared);
    assert!(core.view().error.is_some_and(|e| e.contains("片付け")));
    Ok(())
}

#[test]
fn sharing_deduplicates_catalog_photos_and_prefers_accessible_local_sources() -> Result<(), String>
{
    let local = asset();
    let mut remote = local.clone();
    remote.key = AssetKey {
        provider: Provider::Immich,
        scope: "immich".into(),
        asset_id: "remote".into(),
    };
    let keys = vec![remote.key.clone(), local.key.clone(), local.key.clone()];
    let mut snapshots = vec![
        snapshot(local.clone(), ScanAccess::Limited),
        snapshot(remote.clone(), ScanAccess::Full),
    ];
    assert_eq!(sources(&snapshots, &[], &keys)?, vec![local.key.clone()]);
    let mut second = local.clone();
    second.key.asset_id = "second-photo".into();
    second.resources[0].sha1 = Some("2".repeat(40));
    let mut batch = snapshot(local.clone(), ScanAccess::Full);
    batch.assets.push(second.clone());
    assert_eq!(
        sources(&[batch], &[], &[local.key.clone(), second.key])?.len(),
        2
    );
    snapshots[0].access = ScanAccess::Unavailable;
    assert_eq!(sources(&snapshots, &[], &keys)?, vec![remote.key]);
    snapshots[1].access = ScanAccess::Unavailable;
    assert!(sources(&snapshots, &[], &keys).is_err());
    assert!(sources(&snapshots, &[], &[]).is_err());
    assert!(
        sources(
            &snapshots,
            &[],
            &[AssetKey {
                asset_id: "unknown".into(),
                ..local.key
            }]
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn sharing_live_parent_does_not_duplicate_its_standalone_companion() -> Result<(), String> {
    let mut parent = asset();
    parent.key.provider = Provider::Immich;
    parent.key.scope = "remote".into();
    parent.key.asset_id = "z-parent".into();
    let mut motion = parent.resources[0].clone();
    motion.id = "motion".into();
    motion.name = "motion.mov".into();
    motion.role = ResourceRole::LiveVideo;
    motion.sha1 = Some("2".repeat(40));
    parent.resources.push(motion.clone());
    let mut companion = parent.clone();
    companion.key.asset_id = "a-companion".into();
    motion.role = ResourceRole::Video;
    companion.resources = vec![motion];
    let mut remote = snapshot(parent.clone(), ScanAccess::Full);
    remote.assets.push(companion.clone());
    assert_eq!(sources(&[remote], &[], &[companion.key])?, vec![parent.key]);
    Ok(())
}

#[test]
fn sharing_never_falls_back_to_only_one_component_of_a_known_pair() {
    let mut parent = asset();
    let mut motion = parent.resources[0].clone();
    motion.id = "motion".into();
    motion.role = ResourceRole::LiveVideo;
    motion.sha1 = Some("2".repeat(40));
    parent.resources.push(motion.clone());
    let mut companion = parent.clone();
    companion.key.provider = Provider::Immich;
    companion.key.scope = "remote".into();
    motion.role = ResourceRole::Video;
    companion.resources = vec![motion];
    let mut snapshots = vec![
        snapshot(parent, ScanAccess::Unavailable),
        snapshot(companion.clone(), ScanAccess::Full),
    ];
    assert!(sources(&snapshots, &[], &[companion.key.clone()]).is_err());
    snapshots[0].access = ScanAccess::Full;
    snapshots[0].assets[0].inventory_complete = false;
    assert!(sources(&snapshots, &[], &[companion.key.clone()]).is_err());
    snapshots[0].assets[0].inventory_complete = true;
    snapshots[0].assets[0].is_offline = true;
    assert!(sources(&snapshots, &[], &[companion.key]).is_err());
}

#[test]
fn sharing_keeps_raw_and_jpeg_when_one_photo_is_split_across_remote_assets() -> Result<(), String> {
    let mut local = asset();
    let mut raw = local.resources[0].clone();
    raw.id = "raw".into();
    raw.name = "original.dng".into();
    raw.role = ResourceRole::RawImage;
    raw.sha1 = Some("2".repeat(40));
    local.resources.push(raw.clone());
    let mut jpeg = local.clone();
    jpeg.key.provider = Provider::Immich;
    jpeg.key.scope = "remote".into();
    jpeg.key.asset_id = "jpeg".into();
    jpeg.resources.truncate(1);
    let mut remote_raw = jpeg.clone();
    remote_raw.key.asset_id = "raw".into();
    remote_raw.resources = vec![raw];
    let mut remote = snapshot(jpeg.clone(), ScanAccess::Full);
    remote.assets.push(remote_raw.clone());
    let mut snapshots = vec![snapshot(local.clone(), ScanAccess::Unavailable), remote];
    assert_eq!(suwop_core::domain::catalog(&snapshots, &[]).len(), 1);
    assert_eq!(
        sources(&snapshots, &[], &[jpeg.key.clone()])?,
        vec![jpeg.key.clone(), remote_raw.key]
    );
    snapshots[1].assets[1].is_offline = true;
    assert!(sources(&snapshots, &[], &[jpeg.key.clone()]).is_err());
    snapshots[0].access = ScanAccess::Limited;
    assert_eq!(sources(&snapshots, &[], &[jpeg.key])?, vec![local.key]);
    Ok(())
}

#[test]
fn export_names_and_file_paths_cannot_escape_the_workspace() -> Result<(), String> {
    assert_eq!(filename("../../photo.jpg")?, "photo.jpg");
    for name in [".", "..", "bad\0.jpg"] {
        assert!(filename(name).is_err());
    }
    for path in [
        "/tmp/share-other/a",
        "/tmp/share/../a",
        "/tmp/share//a",
        "/tmp/share/",
    ] {
        assert!(!contains_file("/tmp/share", path));
    }
    assert!(contains_file("/tmp/share", "/tmp/share/sub/photo.jpg"));
    Ok(())
}

#[test]
fn remote_only_sharing_downloads_the_original_without_any_remote_mutation() -> Result<(), String> {
    let mut remote = asset();
    remote.key = AssetKey {
        provider: Provider::Immich,
        scope: "immich".into(),
        asset_id: "11111111-1111-4111-8111-111111111111".into(),
    };
    let keys = vec![remote.key.clone()];
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: 7,
                apple_scope: "apple".into(),
                snapshots: vec![snapshot(remote, ScanAccess::Full)],
                ..SavedLibrary::default()
            },
            session: Some(suwop_core::immich::Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://server/api".into(),
                key: "test-key".into(),
                scope: "immich".into(),
                user_id: "22222222-2222-4222-8222-222222222222".into(),
                version: suwop_core::immich::Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            ..Model::default()
        },
    );
    let mut native = Native {
        fault: Fault::Remote,
        ..Native::default()
    };
    run_event(
        &mut native,
        &core,
        Event::Share {
            keys,
            id: "11111111-1111-4111-8111-111111111111".into(),
        },
    )?;
    assert!(core.view().error.is_none());
    assert!(native.shared);
    assert!(native.cleaned);
    Ok(())
}

#[test]
fn apple_change_during_delayed_file_preparation_prevents_sharing_and_cleans_workspace()
-> Result<(), String> {
    let core = core();
    let mut native = Native::default();
    let mut changed = false;
    let mut requests = core.process_event(event());
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        if !changed && matches!(request.operation, ShellOperation::HashFile { .. }) {
            assert!(core.process_event(Event::AppleChanged).is_empty());
            changed = true;
        }
        let result = native.handle(&request.operation);
        requests.extend(
            core.resolve(&mut request, response(result))
                .map_err(|e| e.to_string())?,
        );
    }
    assert!(changed);
    assert!(!native.shared);
    assert!(native.cleaned);
    assert!(core.view().error.is_some());
    Ok(())
}
