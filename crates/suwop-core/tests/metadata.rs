use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, LibrarySnapshot, PhotoResource, Provider, ResourceRole, ScanAccess, StoredAsset,
        TransferIntent, TransferPhase, TransferReceipt, catalog,
    },
    immich::{Asset, HttpResponse, Session, Version},
    metadata::{MetadataAction, MetadataInput, normalize, prepare, targets},
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const USER: &str = "22222222-2222-4222-8222-222222222222";
const SHA: &str = "1111111111111111111111111111111111111111";

fn asset(provider: Provider) -> StoredAsset {
    StoredAsset {
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

fn core(provider: Provider, access: ScanAccess) -> Core<Suwop> {
    let local = asset(Provider::Apple);
    let remote = asset(Provider::Immich);
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: SavedLibrary {
                schema_version: 2,
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
            },
            session: (provider == Provider::Immich).then(|| Session {
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
}
#[derive(Default)]
struct Native {
    writes: usize,
    persists: usize,
    fault: Fault,
    input: Option<MetadataInput>,
}
impl Native {
    fn handle(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleMetadata { keys, change } => {
                self.writes += 1;
                if matches!(self.fault, Fault::Write) {
                    return Err("unknown native write result".into());
                }
                let mut record = asset(Provider::Apple);
                assert_eq!(keys, &vec![record.key.clone()]);
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
                record.resources[0].sha1 = None;
                record.resources[0].bytes = None;
                let records = match self.fault {
                    Fault::Missing => vec![],
                    Fault::Duplicate => vec![record.clone(), record],
                    _ => vec![record],
                };
                serde_json::to_value(records).map_err(|e| e.to_string())
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
                            json["exifInfo"]["timeZone"] = "UTC".into();
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
        assert!(record.resources[0].sha1.is_none());
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
fn remote_metadata_verifies_ids_ownership_values_and_timezone() -> Result<(), String> {
    for (fault, writes) in [
        (Fault::None, 1),
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
        if matches!(fault, Fault::None) {
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
