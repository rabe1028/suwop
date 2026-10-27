use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile, TransferIntent, TransferPhase,
        TransferReceipt, catalog, verify_source,
    },
    immich::{Asset, HttpResponse, Session, Version},
    metadata::{MetadataAction, MetadataChange, MetadataInput, normalize, prepare, targets},
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const USER: &str = "22222222-2222-4222-8222-222222222222";
const SHA: &str = "1111111111111111111111111111111111111111";

fn asset(provider: Provider) -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: if provider == Provider::Apple {
                "apple"
            } else {
                "remote"
            }
            .into(),
            asset_id: ID.into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.0),
        modified_at: Some(10.0),
        revision: "before".into(),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: "photo.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(SHA.into()),
            bytes: Some(12),
        }],
        is_favorite: true,
        latitude: Some(1.0),
        longitude: Some(2.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn snapshot(provider: Provider, access: ScanAccess) -> LibrarySnapshot {
    let asset = asset(provider);
    LibrarySnapshot {
        provider,
        scope: asset.key.scope.clone(),
        assets: vec![asset],
        access,
        scanned_at: Some(10.0),
    }
}
fn date_input() -> MetadataInput {
    MetadataInput {
        action: MetadataAction::SetCapturedAt,
        captured_at: Some(1_730_615_400.125),
        time_zone: Some("America/New_York".into()),
        latitude: None,
        longitude: None,
    }
}
fn location_input() -> MetadataInput {
    MetadataInput {
        action: MetadataAction::SetLocation,
        captured_at: None,
        time_zone: None,
        latitude: Some(" 0 ".into()),
        longitude: Some("0".into()),
    }
}
fn remove_input() -> MetadataInput {
    MetadataInput {
        action: MetadataAction::RemoveLocation,
        captured_at: None,
        time_zone: None,
        latitude: None,
        longitude: None,
    }
}

#[test]
fn metadata_preserves_utc_instants_and_named_zones_across_dst() -> Result<(), String> {
    let fields = normalize(&date_input())?.immich_fields()?;
    assert_eq!(fields["dateTimeOriginal"], "2024-11-03T06:30:00.125Z");
    assert_eq!(fields["timeZone"], "America/New_York");
    let point = normalize(&location_input())?;
    assert_eq!(
        point.immich_fields()?,
        json!({"latitude":0.0,"longitude":0.0})
    );
    assert!(normalize(&remove_input())?.immich_fields().is_err());
    Ok(())
}

#[test]
fn invalid_metadata_cannot_become_a_native_write() {
    let mut inputs = Vec::new();
    for value in [
        f64::NAN,
        f64::INFINITY,
        -62_135_596_801.0,
        253_402_300_800.0,
    ] {
        let mut input = date_input();
        input.captured_at = Some(value);
        inputs.push(input);
    }
    let mut input = date_input();
    input.time_zone = Some("unknown/timezone".into());
    inputs.push(input);
    let mut input = date_input();
    input.latitude = Some("0".into());
    inputs.push(input);
    for value in ["91", "-91", "NaN", "inf", "", "35,6"] {
        let mut input = location_input();
        input.latitude = Some(value.into());
        inputs.push(input);
    }
    let mut input = location_input();
    input.longitude = Some("181".into());
    inputs.push(input);
    let mut input = location_input();
    input.longitude = None;
    inputs.push(input);
    let mut input = remove_input();
    input.latitude = Some("0".into());
    inputs.push(input);
    for input in inputs {
        let core = core(Provider::Apple, ScanAccess::Full);
        assert!(
            core.process_event(Event::SetMetadata {
                keys: vec![asset(Provider::Apple).key],
                input
            })
            .is_empty()
        );
        assert!(core.view().error.is_some());
        assert_eq!(core.view().state.snapshots[0].access, ScanAccess::Full);
    }
    assert!(
        serde_json::from_value::<MetadataInput>(
            json!({"action":"removeLocation","unexpected":true})
        )
        .is_err()
    );
}

#[test]
fn metadata_requires_one_complete_provider_group_and_full_current_access() -> Result<(), String> {
    let local = snapshot(Provider::Apple, ScanAccess::Full);
    let remote = snapshot(Provider::Immich, ScanAccess::Full);
    let mut snapshots = vec![local, remote];
    let keys = vec![asset(Provider::Apple).key, asset(Provider::Immich).key];
    assert!(prepare(&snapshots, &[], &keys, &date_input()).is_err());
    assert!(prepare(&snapshots, &[], &[keys[1].clone()], &remove_input()).is_err());
    let photos = catalog(&snapshots, &[]);
    let options = targets(&photos[0], &snapshots);
    assert!(options[0].can_remove_location);
    assert!(!options[1].can_remove_location);
    snapshots[0].access = ScanAccess::Limited;
    assert!(prepare(&snapshots, &[], &[keys[0].clone()], &date_input()).is_err());
    snapshots[0].access = ScanAccess::Full;
    let mut related = snapshots[0].assets[0].clone();
    related.key.asset_id = "related".into();
    related.captured_at = Some(20.0);
    related.longitude = None;
    snapshots[0].assets.push(related.clone());
    let photos = catalog(&snapshots, &[]);
    let target = targets(&photos[0], &snapshots).remove(0);
    assert!(target.dates_vary && target.locations_vary);
    assert!(target.captured_at.is_none() && target.location.is_none());
    assert!(prepare(&snapshots, &[], &[keys[0].clone()], &date_input()).is_err());
    assert_eq!(
        prepare(
            &snapshots,
            &[],
            &[keys[0].clone(), related.key],
            &date_input()
        )?
        .0
        .keys
        .len(),
        2
    );
    let unknown = AssetKey {
        asset_id: "missing".into(),
        ..keys[0].clone()
    };
    assert!(prepare(&snapshots, &[], &[keys[0].clone(), unknown], &date_input()).is_err());
    Ok(())
}

fn fixture_state(provider: Provider, access: ScanAccess) -> SavedLibrary {
    let local = asset(Provider::Apple);
    let remote = asset(Provider::Immich);
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        snapshots: vec![snapshot(provider, access)],
        receipts: vec![TransferReceipt {
            id: "copy".into(),
            created_at: 10.0,
            phase: TransferPhase::Copied,
            intent: TransferIntent::Copy,
            source: vec![local],
            destination: vec![remote],
            destination_provider: Provider::Immich,
            destination_scope: "remote".into(),
            signatures: std::collections::BTreeSet::new(),
        }],
        ..SavedLibrary::default()
    }
}
fn core(provider: Provider, access: ScanAccess) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: fixture_state(provider, access),
            session: (provider == Provider::Immich).then(|| Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://server/api".into(),
                key: "test".into(),
                scope: "remote".into(),
                user_id: USER.into(),
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

#[derive(Clone, Copy, Default)]
enum Fault {
    #[default]
    None,
    Value,
    Missing,
    Duplicate,
    Write,
    Persist,
    WrongId,
    Owner,
    Zone,
    DerivedZone,
    Manifest,
    Inventory,
    ResourceDuplicate,
    Role,
    FreshFingerprint,
}
#[derive(Default)]
struct Native {
    writes: usize,
    persists: usize,
    fault: Fault,
    input: Option<MetadataInput>,
    apple_asset: Option<StoredAsset>,
}
impl Native {
    fn handle(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleMetadata { keys, change } => {
                self.writes += 1;
                if matches!(self.fault, Fault::Write) {
                    return Err("unknown native write result".into());
                }
                let record = self.apple_record(change);
                assert_eq!(keys, &vec![record.key.clone()]);
                let records = match self.fault {
                    Fault::Missing => vec![],
                    Fault::Duplicate => vec![record.clone(), record],
                    _ => vec![record],
                };
                serde_json::to_value(records).map_err(|e| e.to_string())
            }
            ShellOperation::AppleScan { scope, .. } => {
                assert_eq!(scope, "apple");
                let input = self.input.as_ref().ok_or("missing input")?;
                let record = self.apple_record(&normalize(input)?);
                serde_json::to_value(LibrarySnapshot {
                    assets: vec![record],
                    ..snapshot(Provider::Apple, ScanAccess::Full)
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::Persist(_) => {
                self.persists += 1;
                if matches!(self.fault, Fault::Persist) {
                    Err("journal failed".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::Http(request) => {
                assert_eq!(
                    request.headers.get("x-api-key").map(String::as_str),
                    Some("test")
                );
                let body = if request.method == "PUT" {
                    assert!(request.url.ends_with("/assets"));
                    self.writes += 1;
                    let mut expected =
                        normalize(self.input.as_ref().ok_or("missing input")?)?.immich_fields()?;
                    expected["ids"] = json!([ID]);
                    assert_eq!(request.body.as_ref(), Some(&expected));
                    Value::Null
                } else if request.url.contains("/asset-files?") {
                    json!([])
                } else {
                    assert_eq!(request.method, "GET");
                    assert!(request.url.ends_with(ID));
                    let mut json = json!({"id":ID,"ownerId":USER,"type":"IMAGE","originalFileName":"photo.jpg","checksum":SHA,
                        "fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z",
                        "isFavorite":true,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false,
                        "exifInfo":{"fileSizeInByte":12,"latitude":1.0,"longitude":2.0}});
                    if matches!(self.fault, Fault::WrongId) {
                        json["id"] = "33333333-3333-4333-8333-333333333333".into();
                    }
                    if matches!(self.fault, Fault::Owner) {
                        json["ownerId"] = "33333333-3333-4333-8333-333333333333".into();
                    }
                    if self.writes > 0 && !matches!(self.fault, Fault::Value) {
                        let fields = normalize(self.input.as_ref().ok_or("missing input")?)?
                            .immich_fields()?;
                        for (key, value) in fields.as_object().ok_or("invalid fields")? {
                            json["exifInfo"][key] = value.clone();
                        }
                        if matches!(self.fault, Fault::Zone) {
                            json["exifInfo"]["timeZone"] = "invalid/zone".into();
                        } else if matches!(self.fault, Fault::DerivedZone) {
                            json["exifInfo"]["timeZone"] = "Asia/Tokyo".into();
                        }
                    }
                    json
                };
                serde_json::to_value(HttpResponse {
                    status: 200,
                    body,
                    path: None,
                })
                .map_err(|e| e.to_string())
            }
            _ => Err(
                "metadata must not export, share, transfer, delete or change credentials".into(),
            ),
        }
    }

    fn apple_record(&self, change: &MetadataChange) -> StoredAsset {
        let mut record = self
            .apple_asset
            .clone()
            .unwrap_or_else(|| asset(Provider::Apple));
        if !matches!(self.fault, Fault::Value) {
            match change.action {
                MetadataAction::SetCapturedAt => record.captured_at = change.captured_at,
                MetadataAction::SetLocation | MetadataAction::RemoveLocation => {
                    record.latitude = change.location.as_ref().map(|p| p.latitude);
                    record.longitude = change.location.as_ref().map(|p| p.longitude);
                }
            }
        }
        record.revision = "after".into();
        for resource in &mut record.resources {
            resource.sha1 = None;
            resource.bytes = None;
        }
        match self.fault {
            Fault::Manifest => record.resources[0].id = "changed".into(),
            Fault::Inventory => record.inventory_complete = false,
            Fault::ResourceDuplicate => record.resources.push(record.resources[0].clone()),
            Fault::Role => record.resources[0].role = ResourceRole::RawImage,
            Fault::FreshFingerprint => {
                record.resources[0].sha1 = Some("2".repeat(40));
                record.resources[0].bytes = Some(99);
            }
            _ => {}
        }
        record
    }
}
fn run(
    core: &Core<Suwop>,
    native: &mut Native,
    provider: Provider,
    input: MetadataInput,
) -> Result<(), String> {
    native.input = Some(input.clone());
    let mut requests = core.process_event(Event::SetMetadata {
        keys: vec![asset(provider).key],
        input,
    });
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let response = match native.handle(&request.operation) {
            Ok(value) => ShellResponse {
                value: Some(value),
                error: None,
            },
            Err(error) => ShellResponse {
                value: None,
                error: Some(error),
            },
        };
        requests.extend(
            core.resolve(&mut request, response)
                .map_err(|e| e.to_string())?,
        );
    }
    assert!(!core.view().busy);
    Ok(())
}

#[test]
fn native_metadata_changes_only_the_selected_field_and_preserves_transfer_history()
-> Result<(), String> {
    for input in [date_input(), location_input(), remove_input()] {
        let core = core(Provider::Apple, ScanAccess::Full);
        let receipts =
            serde_json::to_value(&core.view().state.receipts).map_err(|e| e.to_string())?;
        let mut native = Native::default();
        let change = normalize(&input)?;
        run(&core, &mut native, Provider::Apple, input)?;
        assert!(core.view().error.is_none());
        assert_eq!(native.writes, 1);
        assert_eq!(native.persists, 1);
        assert_eq!(
            serde_json::to_value(&core.view().state.receipts).map_err(|e| e.to_string())?,
            receipts
        );
        let record = &core.view().state.snapshots[0].assets[0];
        assert!(record.is_favorite);
        assert_eq!(record.name, "photo.jpg");
        assert_eq!(record.resources[0].sha1.as_deref(), Some(SHA));
        assert_eq!(record.resources[0].bytes, Some(12));
        if change.action == MetadataAction::SetCapturedAt {
            assert_eq!(record.latitude, Some(1.0));
            assert_eq!(record.longitude, Some(2.0));
        } else {
            assert_eq!(record.captured_at, Some(10.0));
        }
        suwop_core::metadata::verify(
            std::slice::from_ref(record),
            std::slice::from_ref(&record.key),
            &change,
        )?;
    }
    Ok(())
}

#[test]
fn uncertain_incomplete_or_unpersisted_native_metadata_disables_writes_without_retry()
-> Result<(), String> {
    for fault in [
        Fault::Value,
        Fault::Missing,
        Fault::Duplicate,
        Fault::Write,
        Fault::Persist,
    ] {
        let core = core(Provider::Apple, ScanAccess::Full);
        let mut native = Native {
            fault,
            ..Native::default()
        };
        run(&core, &mut native, Provider::Apple, date_input())?;
        assert_eq!(native.writes, 1);
        assert_eq!(native.persists, 1);
        assert!(core.view().error.is_some());
        assert!(core.view().status.contains("保存済み"));
        assert_eq!(
            core.view().state.snapshots[0].access,
            ScanAccess::Unavailable
        );
        assert!(
            core.process_event(Event::SetMetadata {
                keys: vec![asset(Provider::Apple).key],
                input: date_input()
            })
            .is_empty()
        );
        assert_eq!(core.view().state.receipts.len(), 1);
    }
    Ok(())
}

#[test]
fn metadata_and_normal_refresh_preserve_unified_identity_but_not_the_old_deletion_revision()
-> Result<(), String> {
    let mut state = fixture_state(Provider::Apple, ScanAccess::Full);
    state
        .snapshots
        .push(snapshot(Provider::Immich, ScanAccess::Full));
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            ..Model::default()
        },
    );
    assert_eq!(core.view().photos.len(), 1);
    let mut native = Native::default();
    run(&core, &mut native, Provider::Apple, date_input())?;
    assert!(core.view().error.is_none());
    assert_eq!(core.view().photos.len(), 1);
    assert_eq!(core.view().photos[0].assets.len(), 2);
    let fresh = core.view().state.snapshots[0].assets[0].clone();
    assert!(fresh.fingerprints_complete());
    assert_eq!(fresh.revision, "after");
    let mut receipt = core.view().state.receipts[0].clone();
    assert_eq!(receipt.source[0].revision, "before");
    receipt.intent = TransferIntent::Move;
    let signature = FileSignature {
        sha256: "0".repeat(64),
        bytes: 12,
    };
    receipt.signatures.insert(signature.clone());
    let mut bundle = TransferBundle {
        files: vec![TransferFile {
            resource: fresh.resources[0].clone(),
            path: "/tmp/export/photo.jpg".into(),
            signature,
        }],
        assets: vec![fresh],
    };
    // Even restoring the old values cannot turn the new revision into the
    // prior Move proof; the rejection is independent of cached fingerprints.
    bundle.assets[0].captured_at = receipt.source[0].captured_at;
    let error = verify_source(&receipt, &mut bundle)
        .err()
        .ok_or("old revision authorized deletion")?;
    assert!(error.contains("コピー後に転送元が変更"));
    let mut requests = core.process_event(Event::Refresh {
        permission: false,
        now: 20.0,
    });
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let value = native.handle(&request.operation)?;
        requests.extend(
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
    let refreshed = core.view();
    assert!(refreshed.error.is_none());
    assert_eq!(refreshed.photos.len(), 1);
    assert_eq!(refreshed.photos[0].assets.len(), 2);
    let local = refreshed
        .state
        .snapshots
        .iter()
        .find(|s| s.provider == Provider::Apple)
        .and_then(|s| s.assets.first())
        .ok_or("missing refreshed Apple asset")?;
    assert!(local.fingerprints_complete());
    assert_eq!(local.resources[0].bytes, Some(12));
    assert_eq!(native.writes, 1);
    Ok(())
}

#[test]
fn metadata_never_reuses_fingerprints_for_changed_or_incomplete_inventories() -> Result<(), String>
{
    for fault in [
        Fault::Manifest,
        Fault::Inventory,
        Fault::ResourceDuplicate,
        Fault::Role,
        Fault::FreshFingerprint,
    ] {
        let core = core(Provider::Apple, ScanAccess::Full);
        let mut native = Native {
            fault,
            ..Native::default()
        };
        run(&core, &mut native, Provider::Apple, date_input())?;
        assert!(core.view().error.is_none());
        let record = &core.view().state.snapshots[0].assets[0];
        assert_eq!(record.revision, "after");
        if matches!(fault, Fault::FreshFingerprint) {
            assert_eq!(
                record.resources[0].sha1.as_deref(),
                Some("2".repeat(40).as_str())
            );
            assert_eq!(record.resources[0].bytes, Some(99));
        } else {
            assert!(
                record
                    .resources
                    .iter()
                    .all(|r| r.sha1.is_none() && r.bytes.is_none())
            );
        }
    }
    Ok(())
}

#[test]
fn metadata_keeps_known_partial_original_matches_without_inventing_unknown_hashes()
-> Result<(), String> {
    let mut state = fixture_state(Provider::Apple, ScanAccess::Full);
    state.snapshots[0].assets[0].resources.push(PhotoResource {
        id: "raw".into(),
        name: "photo.dng".into(),
        role: ResourceRole::RawImage,
        sha1: None,
        bytes: None,
    });
    state.snapshots[0].assets[0].resources.push(PhotoResource {
        id: "adjustment".into(),
        name: "adjustment.plist".into(),
        role: ResourceRole::Auxiliary,
        sha1: Some("3".repeat(40)),
        bytes: Some(4),
    });
    let source = state.snapshots[0].assets[0].clone();
    assert!(!source.fingerprints_complete());
    state
        .snapshots
        .push(snapshot(Provider::Immich, ScanAccess::Full));
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            ..Model::default()
        },
    );
    assert_eq!(core.view().photos.len(), 1);
    let mut native = Native {
        apple_asset: Some(source),
        ..Native::default()
    };
    run(&core, &mut native, Provider::Apple, location_input())?;
    assert!(core.view().error.is_none());
    assert_eq!(core.view().photos.len(), 1);
    let record = &core.view().state.snapshots[0].assets[0];
    assert_eq!(record.resources[0].sha1.as_deref(), Some(SHA));
    assert_eq!(record.resources[0].bytes, Some(12));
    assert!(record.resources[1].sha1.is_none() && record.resources[1].bytes.is_none());
    assert!(record.resources[2].sha1.is_none() && record.resources[2].bytes.is_none());
    assert!(!record.fingerprints_complete());
    Ok(())
}

#[test]
fn remote_metadata_verifies_ids_ownership_values_and_timezone() -> Result<(), String> {
    for (fault, writes) in [
        (Fault::None, 1),
        (Fault::DerivedZone, 1),
        (Fault::WrongId, 0),
        (Fault::Owner, 0),
        (Fault::Value, 1),
        (Fault::Zone, 1),
    ] {
        let core = core(Provider::Immich, ScanAccess::Full);
        let mut native = Native {
            fault,
            ..Native::default()
        };
        run(&core, &mut native, Provider::Immich, date_input())?;
        assert_eq!(native.writes, writes);
        if matches!(fault, Fault::None | Fault::DerivedZone) {
            assert!(core.view().error.is_none());
            assert_eq!(
                core.view().state.snapshots[0].assets[0].captured_at,
                date_input().captured_at
            );
        } else {
            assert!(core.view().error.is_some());
            assert_eq!(
                core.view().state.snapshots[0].access,
                ScanAccess::Unavailable
            );
        }
        assert_eq!(core.view().state.receipts.len(), 1);
    }
    Ok(())
}

#[test]
fn immich_adjusted_capture_date_precedes_the_file_timestamp_and_invalid_adjustments_are_unknown()
-> Result<(), String> {
    let mut json = json!({"id":ID,"ownerId":USER,"type":"IMAGE","originalFileName":"photo.jpg","checksum":SHA,
        "fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z",
        "isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"isExternal":false});
    let original: Asset = serde_json::from_value(json.clone()).map_err(|e| e.to_string())?;
    json["exifInfo"] = normalize(&date_input())?.immich_fields()?;
    let adjusted: Asset = serde_json::from_value(json.clone()).map_err(|e| e.to_string())?;
    assert_eq!(
        adjusted.record("remote", None, None).captured_at,
        date_input().captured_at
    );
    assert_ne!(
        adjusted.record("remote", None, None).revision,
        original.record("remote", None, None).revision
    );
    json["exifInfo"]["dateTimeOriginal"] = "invalid".into();
    let invalid: Asset = serde_json::from_value(json).map_err(|e| e.to_string())?;
    assert!(invalid.record("remote", None, None).captured_at.is_none());
    Ok(())
}

#[test]
fn metadata_membership_does_not_join_separate_or_limited_snapshots() {
    let first = snapshot(Provider::Apple, ScanAccess::Full);
    let mut second = first.clone();
    second.assets[0].key.asset_id = "second".into();
    let split = vec![first.clone(), second.clone()];
    let photos = catalog(&split, &[]);
    assert_eq!(photos.len(), 1);
    assert_eq!(photos[0].assets.len(), 2);
    assert!(targets(&photos[0], &split)[0].disabled_reason.is_some());
    let mut joined = first;
    joined.assets.extend(second.assets);
    assert!(
        targets(&photos[0], &[joined.clone()])[0]
            .disabled_reason
            .is_none()
    );
    joined.access = ScanAccess::Limited;
    assert!(targets(&photos[0], &[joined])[0].disabled_reason.is_some());
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PreflightFault {
    Drift,
    Cancelled,
    ClosureSaveFailure,
}
struct DurableMetadataNative {
    current: StoredAsset,
    disk: Option<SavedLibrary>,
    writes: usize,
    fail_write: bool,
    fail_final_save: bool,
    lose_final_ack: bool,
    preflight: Option<PreflightFault>,
    after_write_drift: Option<fn(&mut StoredAsset)>,
}
impl DurableMetadataNative {
    fn new() -> Self {
        Self {
            current: asset(Provider::Apple),
            disk: None,
            writes: 0,
            fail_write: false,
            fail_final_save: false,
            lose_final_ack: false,
            preflight: None,
            after_write_drift: None,
        }
    }
    fn handle(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleMetadataObserve { keys } => {
                assert_eq!(keys, &vec![self.current.key.clone()]);
                if self.disk.as_ref().is_some_and(|state| {
                    state.metadata_operations.last().is_some_and(|record| {
                        record.outcome == suwop_core::metadata::MetadataOutcome::SubmittedUnknown
                    })
                }) && self.writes == 0
                {
                    match self.preflight {
                        Some(PreflightFault::Drift) => self.current.latitude = Some(90.0),
                        Some(PreflightFault::Cancelled | PreflightFault::ClosureSaveFailure) => {
                            return Err("cancelled before native write".into());
                        }
                        None => {}
                    }
                }
                serde_json::to_value(vec![self.current.clone()]).map_err(|error| error.to_string())
            }
            ShellOperation::AppleMetadataVerified { before, change } => {
                assert!(self.disk.as_ref().is_some_and(|state| {
                    state.metadata_operations.last().is_some_and(|record| {
                        record.outcome == suwop_core::metadata::MetadataOutcome::SubmittedUnknown
                    })
                }));
                assert_eq!(before[0].revision, self.current.revision);
                self.writes += 1;
                if self.fail_write {
                    return Err("lost native reply".into());
                }
                match change.action {
                    MetadataAction::SetCapturedAt => self.current.captured_at = change.captured_at,
                    MetadataAction::SetLocation | MetadataAction::RemoveLocation => {
                        self.current.latitude =
                            change.location.as_ref().map(|point| point.latitude);
                        self.current.longitude =
                            change.location.as_ref().map(|point| point.longitude);
                    }
                }
                self.current.revision = format!("revision-{}", self.writes);
                if let Some(drift) = self.after_write_drift {
                    drift(&mut self.current);
                }

                serde_json::to_value(vec![self.current.clone()]).map_err(|error| error.to_string())
            }
            ShellOperation::Persist(state) => {
                if self.preflight == Some(PreflightFault::ClosureSaveFailure)
                    && state.metadata_operations.last().is_some_and(|record| {
                        record.outcome == suwop_core::metadata::MetadataOutcome::NotApplied
                    })
                {
                    return Err("cannot prove durable no-submission".into());
                }
                if self.fail_final_save
                    && state.metadata_operations.last().is_some_and(|record| {
                        record.outcome == suwop_core::metadata::MetadataOutcome::VerifiedApplied
                    })
                {
                    return Err("disk failure".into());
                }
                if let Some(previous) = &self.disk {
                    suwop_core::metadata::validate_record_transition(
                        &previous.metadata_operations,
                        &state.metadata_operations,
                    )?;
                }
                self.disk = Some(state.clone());
                if self.lose_final_ack
                    && state.metadata_operations.last().is_some_and(|record| {
                        record.outcome == suwop_core::metadata::MetadataOutcome::VerifiedApplied
                    })
                {
                    return Err("lost persistence acknowledgement".into());
                }
                Ok(Value::Null)
            }
            ShellOperation::ReadStateVersioned => {
                Ok(json!({"revision":"fixture-only","state":self.disk}))
            }
            _ => Err("unexpected metadata I/O".into()),
        }
    }
}
fn run_durable_metadata(
    core: &Core<Suwop>,
    native: &mut DurableMetadataNative,
    event: Event,
) -> Result<(), String> {
    let mut requests = core.process_event(event);
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let response = match native.handle(&request.operation) {
            Ok(value) => ShellResponse {
                value: Some(value),
                error: None,
            },
            Err(error) => ShellResponse {
                value: None,
                error: Some(error),
            },
        };
        requests.extend(
            core.resolve(&mut request, response)
                .map_err(|error| error.to_string())?,
        );
    }
    Ok(())
}
#[test]
fn durable_apple_description_is_local_and_undo_survives_restart() -> Result<(), String> {
    use suwop_core::metadata::{MetadataEdit, MetadataOutcome};
    let core = core(Provider::Apple, ScanAccess::Full);
    let mut native = DurableMetadataNative::new();
    let id = "33333333-3333-4333-8333-333333333333";
    let keys = vec![native.current.key.clone()];
    run_durable_metadata(
        &core,
        &mut native,
        Event::EditMetadata {
            keys,
            edit: MetadataEdit::Description {
                text: "Tokyo station 東京".into(),
            },
            id: id.into(),
        },
    )?;
    assert!(core.view().error.is_none());
    assert_eq!(native.writes, 0);
    let saved = native.disk.clone().ok_or("missing durable state")?;
    assert_eq!(
        saved.metadata_operations[0].outcome,
        MetadataOutcome::VerifiedApplied
    );
    assert_eq!(
        suwop_core::metadata::description_for(&native.current.key, &saved.metadata_operations),
        Some("Tokyo station 東京")
    );
    let restarted = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: saved,
            ..Model::default()
        },
    );
    run_durable_metadata(
        &restarted,
        &mut native,
        Event::RestoreMetadata {
            id: "44444444-4444-4444-8444-444444444444".into(),
            operation_id: id.into(),
            original: false,
        },
    )?;
    assert!(restarted.view().error.is_none());
    assert_eq!(native.writes, 0);
    let saved = native.disk.as_ref().ok_or("missing restored state")?;
    assert_eq!(saved.metadata_operations.len(), 2);
    assert_eq!(
        suwop_core::metadata::description_for(&native.current.key, &saved.metadata_operations),
        Some("")
    );
    Ok(())
}
#[test]
fn durable_metadata_unknown_and_failed_save_never_retry() -> Result<(), String> {
    use suwop_core::metadata::{MetadataEdit, MetadataOutcome};
    for final_save in [false, true] {
        let core = core(Provider::Apple, ScanAccess::Full);
        let mut native = DurableMetadataNative::new();
        native.fail_write = !final_save;
        native.fail_final_save = final_save;
        let keys = vec![native.current.key.clone()];
        run_durable_metadata(
            &core,
            &mut native,
            Event::EditMetadata {
                keys: keys.clone(),
                edit: MetadataEdit::Location {
                    latitude: "35.0".into(),
                    longitude: "139.0".into(),
                },
                id: "55555555-5555-4555-8555-555555555555".into(),
            },
        )?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 1);
        assert_eq!(
            native
                .disk
                .as_ref()
                .ok_or("missing submitted state")?
                .metadata_operations[0]
                .outcome,
            MetadataOutcome::SubmittedUnknown
        );
        run_durable_metadata(
            &core,
            &mut native,
            Event::EditMetadata {
                keys,
                edit: MetadataEdit::Description {
                    text: "do not retry".into(),
                },
                id: "66666666-6666-4666-8666-666666666666".into(),
            },
        )?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 1);
    }
    Ok(())
}

#[test]
fn durable_metadata_lost_final_ack_reads_disk_without_reissuing_write() -> Result<(), String> {
    let core = core(Provider::Apple, ScanAccess::Full);
    let mut native = DurableMetadataNative::new();
    native.lose_final_ack = true;
    let keys = vec![native.current.key.clone()];
    run_durable_metadata(
        &core,
        &mut native,
        Event::EditMetadata {
            keys,
            edit: suwop_core::metadata::MetadataEdit::Location {
                latitude: "35".into(),
                longitude: "139".into(),
            },
            id: "77777777-7777-4777-8777-777777777777".into(),
        },
    )?;
    assert!(core.view().error.is_none());
    assert_eq!(native.writes, 1);
    assert_eq!(
        native
            .disk
            .as_ref()
            .ok_or("missing durable commit")?
            .metadata_operations[0]
            .outcome,
        suwop_core::metadata::MetadataOutcome::VerifiedApplied
    );
    Ok(())
}

#[test]
fn metadata_undo_restores_distinct_member_values_without_flattening() -> Result<(), String> {
    let (state, mut records) = distinct_date_fixture()?;
    let keys = records
        .iter()
        .map(|record| record.key.clone())
        .collect::<Vec<_>>();
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            ..Model::default()
        },
    );

    let mut disk: Option<SavedLibrary> = None;
    let mut writes = 0;
    let operation = "88888888-8888-4888-8888-888888888888";
    for event in [
        Event::EditMetadata {
            keys: keys.clone(),
            edit: suwop_core::metadata::MetadataEdit::CapturedAt {
                local: "2024-01-01T00:00:00".into(),
                zone: "UTC".into(),
                occurrence: None,
            },
            id: operation.into(),
        },
        Event::RestoreMetadata {
            id: "99999999-9999-4999-8999-999999999999".into(),
            operation_id: operation.into(),
            original: false,
        },
    ] {
        let mut effects = core.process_event(event);
        while !effects.is_empty() {
            let Effect::Io(mut effect) = effects.remove(0);
            let value = match &effect.operation {
                ShellOperation::AppleMetadataObserve { keys } => serde_json::to_value(
                    records
                        .iter()
                        .filter(|record| keys.contains(&record.key))
                        .cloned()
                        .collect::<Vec<_>>(),
                )
                .map_err(|error| error.to_string())?,
                ShellOperation::AppleMetadataVerified { before, change } => {
                    assert!(disk.as_ref().is_some_and(|state| {
                        state.metadata_operations.last().is_some_and(|record| {
                            record.outcome
                                == suwop_core::metadata::MetadataOutcome::SubmittedUnknown
                        })
                    }));
                    for item in before {
                        let record = records
                            .iter_mut()
                            .find(|record| record.key == item.key)
                            .ok_or("missing member")?;
                        assert_eq!(record.revision, item.revision);
                        record.captured_at = change.captured_at;
                        writes += 1;
                        record.revision = format!("new-{writes}");
                    }
                    serde_json::to_value(
                        records
                            .iter()
                            .filter(|record| before.iter().any(|item| item.key == record.key))
                            .cloned()
                            .collect::<Vec<_>>(),
                    )
                    .map_err(|error| error.to_string())?
                }
                ShellOperation::Persist(state) => {
                    disk = Some(state.clone());
                    Value::Null
                }
                _ => return Err("unexpected multi-member metadata operation".into()),
            };
            effects.extend(
                core.resolve(
                    &mut effect,
                    ShellResponse {
                        value: Some(value),
                        error: None,
                    },
                )
                .map_err(|error| error.to_string())?,
            );
        }
        assert!(core.view().error.is_none(), "{:?}", core.view().error);
    }
    assert_eq!(writes, 4);
    assert_eq!(records[0].captured_at, Some(10.0));
    assert_eq!(records[1].captured_at, Some(20.0));
    let state = disk.ok_or("missing restored journal")?;
    assert_eq!(state.metadata_operations[2].member_edits.len(), 2);
    Ok(())
}

#[test]
fn metadata_proven_preflight_denial_is_not_applied_only_after_durable_save() -> Result<(), String> {
    use suwop_core::metadata::{MetadataEdit, MetadataOutcome};
    for fault in [
        PreflightFault::Drift,
        PreflightFault::Cancelled,
        PreflightFault::ClosureSaveFailure,
    ] {
        let core = core(Provider::Apple, ScanAccess::Full);
        let mut native = DurableMetadataNative::new();
        native.preflight = Some(fault);
        let keys = vec![native.current.key.clone()];
        run_durable_metadata(
            &core,
            &mut native,
            Event::EditMetadata {
                keys,
                edit: MetadataEdit::Location {
                    latitude: "35".into(),
                    longitude: "139".into(),
                },
                id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc".into(),
            },
        )?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 0);
        let expected = if fault == PreflightFault::ClosureSaveFailure {
            MetadataOutcome::SubmittedUnknown
        } else {
            MetadataOutcome::NotApplied
        };
        assert_eq!(
            native
                .disk
                .as_ref()
                .ok_or("missing durable outcome")?
                .metadata_operations[0]
                .outcome,
            expected
        );
        assert_eq!(
            suwop_core::metadata::blocked(
                &[native.current.key.clone()],
                &native.disk.as_ref().ok_or("disk")?.metadata_operations
            ),
            fault == PreflightFault::ClosureSaveFailure
        );
    }
    Ok(())
}

#[test]
fn first_postwrite_metadata_observation_never_adopts_resource_or_membership_drift()
-> Result<(), String> {
    use suwop_core::metadata::{MetadataEdit, MetadataOutcome};
    let cases: [fn(&mut StoredAsset); 5] = [
        |asset| asset.resources[0].sha1 = None,
        |asset| asset.resources[0].bytes = None,
        |asset| {
            asset.immich_stack_membership = Some(suwop_core::domain::ImmichStackMembership {
                id: "unexpected-stack".into(),
                primary_asset_id: asset.key.asset_id.clone(),
                asset_count: 2,
            });
        },
        |asset| asset.inventory_complete = false,
        |asset| asset.deletion_blockers.push("new blocker".into()),
    ];
    for drift in cases {
        let core = core(Provider::Apple, ScanAccess::Full);
        let mut native = DurableMetadataNative::new();
        native.after_write_drift = Some(drift);
        let original = native.current.clone();
        run_durable_metadata(
            &core,
            &mut native,
            Event::EditMetadata {
                keys: vec![original.key.clone()],
                edit: MetadataEdit::Location {
                    latitude: "35".into(),
                    longitude: "139".into(),
                },
                id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd".into(),
            },
        )?;
        assert_eq!(native.writes, 1);
        assert!(core.view().error.is_some());
        let record = &native
            .disk
            .as_ref()
            .ok_or("missing durable state")?
            .metadata_operations[0];
        assert_eq!(record.outcome, MetadataOutcome::SubmittedUnknown);
        assert!(record.after.is_empty());
        assert_eq!(record.before[0].asset, original);
    }
    Ok(())
}

fn known_date_baseline(
    assets: &[StoredAsset],
) -> Result<suwop_core::metadata::MetadataRecord, String> {
    use suwop_core::metadata::{
        MetadataEdit, MetadataOutcome, MetadataRecord, MetadataValues, MetadataWitness,
    };
    let mut edits = Vec::new();
    let mut witnesses = Vec::new();
    for asset in assets {
        let (local, occurrence) = suwop_core::metadata::time_zone::local(
            asset.captured_at.ok_or("fixture date")?,
            "UTC",
        )?;
        edits.push(MetadataEdit::CapturedAt {
            local,
            zone: "UTC".into(),
            occurrence,
        });
        witnesses.push(MetadataWitness {
            asset: asset.clone(),
            values: MetadataValues {
                captured_at: asset.captured_at,
                time_zone: Some("UTC".into()),
                latitude: asset.latitude,
                longitude: asset.longitude,
                description: String::new(),
            },
        });
    }
    let record = MetadataRecord {
        id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee".into(),
        keys: assets.iter().map(|asset| asset.key.clone()).collect(),
        edit: edits.first().ok_or("fixture edit")?.clone(),
        member_edits: edits,
        before: witnesses.clone(),
        after: witnesses,
        outcome: MetadataOutcome::VerifiedApplied,
        restores: None,
        current: Vec::new(),
    };
    suwop_core::metadata::validate_records(std::slice::from_ref(&record))?;
    Ok(record)
}

#[test]
fn immich_missing_original_location_is_explained_before_undo_and_never_submitted()
-> Result<(), String> {
    use suwop_core::metadata::{MetadataEdit, restore_availability};
    let current = asset(Provider::Immich);
    let mut record = known_date_baseline(std::slice::from_ref(&current))?;
    record.edit = MetadataEdit::Location {
        latitude: "1".into(),
        longitude: "2".into(),
    };
    record.member_edits = vec![record.edit.clone()];
    record.before[0].asset.latitude = None;
    record.before[0].asset.longitude = None;
    record.before[0].values.latitude = None;
    record.before[0].values.longitude = None;
    suwop_core::metadata::validate_records(std::slice::from_ref(&record))?;
    let available = restore_availability(std::slice::from_ref(&record));
    assert!(
        available[0]
            .undo_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("位置情報の削除"))
    );
    assert_eq!(available[0].undo_reason, available[0].original_reason);
    let mut state = fixture_state(Provider::Immich, ScanAccess::Full);
    state.metadata_operations = vec![record.clone()];
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            ..Model::default()
        },
    );
    for original in [false, true] {
        let effects = core.process_event(Event::RestoreMetadata {
            operation_id: record.id.clone(),
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff".into(),
            original,
        });
        assert!(
            effects.is_empty(),
            "unsupported undo must not read, write or persist"
        );
        assert!(
            core.view()
                .error
                .as_deref()
                .is_some_and(|error| error.contains("位置情報の削除"))
        );
    }
    Ok(())
}

fn distinct_date_fixture() -> Result<(SavedLibrary, [StoredAsset; 2]), String> {
    let mut first = asset(Provider::Apple);
    first.captured_at = Some(10.0);
    let mut second = first.clone();
    second.key.asset_id = "second".into();
    second.captured_at = Some(20.0);
    let mut state = fixture_state(Provider::Apple, ScanAccess::Full);
    state.receipts.clear();
    state.snapshots[0].assets = vec![first.clone(), second.clone()];
    state.metadata_operations = vec![known_date_baseline(&state.snapshots[0].assets)?];
    Ok((state, [first, second]))
}
