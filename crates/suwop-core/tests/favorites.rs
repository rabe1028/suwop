use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferBundle, TransferFile, TransferIntent, TransferPhase,
        TransferReceipt, verify_source,
    },
    immich::{HttpResponse, Session, Version},
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const OWNER: &str = "22222222-2222-4222-8222-222222222222";
const SHA: &str = "1111111111111111111111111111111111111111";

fn asset(provider: Provider) -> StoredAsset {
    StoredAsset {
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
        is_favorite: false,
        latitude: Some(1.0),
        longitude: Some(2.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn state() -> SavedLibrary {
    SavedLibrary {
        schema_version: 4,
        apple_scope: "apple".into(),
        snapshots: [Provider::Apple, Provider::Immich]
            .into_iter()
            .map(|provider| LibrarySnapshot {
                provider,
                scope: asset(provider).key.scope.clone(),
                assets: vec![asset(provider)],
                access: ScanAccess::Full,
                scanned_at: Some(10.0),
            })
            .collect(),
        ..SavedLibrary::default()
    }
}
fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(Session {
                endpoint: "https://test/api".into(),
                key: "test".into(),
                user_id: OWNER.into(),
                scope: "remote".into(),
                version: Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            ready: true,
            ..Model::default()
        },
    )
}

#[derive(Clone, Copy)]
enum Fault {
    None,
    Duplicate,
    Missing,
    WrongKey,
    WrongValue,
    LostNativeResponse,
    ChangedInventory,
    LostRemoteResponse,
}
struct Native {
    apple: StoredAsset,
    remote_favorite: bool,
    fault: Fault,
    apple_writes: usize,
    remote_writes: usize,
    persist_calls: usize,
    fail_persist: bool,
    saved: Option<SavedLibrary>,
}
impl Native {
    fn new(fault: Fault) -> Self {
        Self {
            apple: asset(Provider::Apple),
            remote_favorite: false,
            fault,
            apple_writes: 0,
            remote_writes: 0,
            persist_calls: 0,
            fail_persist: false,
            saved: None,
        }
    }
    fn remote_asset(&self) -> Value {
        json!({
            "id":ID,"ownerId":OWNER,"type":"IMAGE","originalFileName":"photo.jpg",
            "checksum":SHA,"fileCreatedAt":"1970-01-01T00:00:10Z",
            "fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"1970-01-01T00:00:10Z",
            "isFavorite":self.remote_favorite,"isOffline":false,"isTrashed":false,
            "isEdited":false,"isExternal":false,
            "exifInfo":{"fileSizeInByte":12,"latitude":1.0,"longitude":2.0}
        })
    }
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::AppleFavorite { keys, value } => {
                assert_eq!(keys, vec![self.apple.key.clone()]);
                self.apple_writes += 1;
                self.apple.is_favorite = value;
                self.apple.revision = "after".into();
                self.apple.modified_at = Some(20.0);
                for resource in &mut self.apple.resources {
                    resource.sha1 = None;
                    resource.bytes = None;
                }
                let mut returned = vec![self.apple.clone()];
                match self.fault {
                    Fault::Duplicate => returned.push(self.apple.clone()),
                    Fault::Missing => returned.clear(),
                    Fault::WrongKey => returned[0].key.scope = "other".into(),
                    Fault::WrongValue => returned[0].is_favorite = !value,
                    Fault::LostNativeResponse => return Err("lost native response".into()),
                    Fault::ChangedInventory => returned[0].resources[0].name = "changed.jpg".into(),
                    Fault::None | Fault::LostRemoteResponse => {}
                }
                serde_json::to_value(returned).map_err(|e| e.to_string())
            }
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope,
                assets: vec![self.apple.clone()],
                access: ScanAccess::Full,
                scanned_at: Some(20.0),
            })
            .map_err(|e| e.to_string()),
            ShellOperation::Persist(state) => {
                self.persist_calls += 1;
                if self.fail_persist {
                    return Err("journal unavailable".into());
                }
                self.saved = Some(state);
                Ok(Value::Null)
            }
            ShellOperation::Http(request) => {
                let body = if request.method == "PUT" {
                    self.remote_writes += 1;
                    self.remote_favorite = request
                        .body
                        .as_ref()
                        .and_then(|b| b["isFavorite"].as_bool())
                        .ok_or("missing favorite")?;
                    if matches!(self.fault, Fault::LostRemoteResponse) {
                        return Err("lost remote response".into());
                    }
                    Value::Null
                } else if request.url.ends_with("/search/metadata") {
                    json!({"assets":{"items":[self.remote_asset()],"nextCursor":null}})
                } else if request.url.contains("asset-files") {
                    json!([])
                } else {
                    self.remote_asset()
                };
                serde_json::to_value(HttpResponse {
                    status: 200,
                    body,
                    path: None,
                })
                .map_err(|e| e.to_string())
            }
            _ => Err("unexpected effect".into()),
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        let mut steps = 0;
        while !effects.is_empty() {
            steps += 1;
            if steps > 100 {
                return Err("effect loop did not terminate".into());
            }
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.handle(request.operation.clone()) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        Ok(())
    }
}
fn favorite_event(providers: &[Provider]) -> Event {
    Event::SetFavorite {
        keys: providers.iter().map(|p| asset(*p).key).collect(),
        value: true,
    }
}

#[test]
fn favorite_and_normal_refresh_keep_unified_originals_and_the_fresh_revision() -> Result<(), String>
{
    let core = core(state());
    let mut native = Native::new(Fault::None);
    assert_eq!(core.view().photos.len(), 1);
    native.run(&core, favorite_event(&[Provider::Apple]))?;
    let changed = core.view();
    assert!(changed.error.is_none());
    assert_eq!(changed.photos.len(), 1);
    assert_eq!(changed.photos[0].assets.len(), 2);
    let fresh = &changed.state.snapshots[0].assets[0];
    assert!(fresh.is_favorite);
    assert!(fresh.fingerprints_complete());
    assert_eq!(fresh.resources[0].bytes, Some(12));
    assert_eq!(fresh.revision, "after");
    assert_eq!(fresh.modified_at, Some(20.0));
    assert_eq!(fresh.captured_at, Some(10.0));
    assert_eq!((fresh.latitude, fresh.longitude), (Some(1.0), Some(2.0)));
    assert!(changed.state.receipts.is_empty());
    native.run(
        &core,
        Event::Refresh {
            permission: false,
            now: 20.0,
        },
    )?;
    let refreshed = core.view();
    assert!(refreshed.error.is_none());
    assert_eq!(refreshed.photos.len(), 1);
    assert_eq!(refreshed.photos[0].assets.len(), 2);
    assert!(refreshed.state.snapshots[0].assets[0].fingerprints_complete());
    assert_eq!(native.apple_writes, 1);
    assert_eq!(native.remote_writes, 0);
    Ok(())
}

#[test]
fn retained_favorite_fingerprints_never_authorize_an_old_move_revision() -> Result<(), String> {
    let signature = FileSignature {
        sha256: "a".repeat(64),
        bytes: 12,
    };
    let mut state = state();
    state.receipts.push(TransferReceipt {
        id: "move".into(),
        created_at: 10.0,
        phase: TransferPhase::Copied,
        intent: TransferIntent::Move,
        source: vec![asset(Provider::Apple)],
        destination: vec![asset(Provider::Immich)],
        destination_provider: Provider::Immich,
        destination_scope: "remote".into(),
        signatures: std::collections::BTreeSet::from([signature.clone()]),
    });
    let core = core(state);
    let mut native = Native::new(Fault::None);
    native.run(&core, favorite_event(&[Provider::Apple]))?;
    assert!(core.view().error.is_none());
    let view = core.view();
    let fresh = view.state.snapshots[0].assets[0].clone();
    assert!(fresh.fingerprints_complete());
    let receipt = &view.state.receipts[0];
    assert_eq!(receipt.source[0].revision, "before");
    assert_eq!(receipt.phase, TransferPhase::Copied);
    let mut bundle = TransferBundle {
        files: vec![TransferFile {
            resource: fresh.resources[0].clone(),
            path: "/tmp/photo.jpg".into(),
            signature,
        }],
        assets: vec![fresh],
    };
    // Isolate the revision check from the different favorite value.
    bundle.assets[0].is_favorite = receipt.source[0].is_favorite;
    let error = verify_source(receipt, &mut bundle)
        .err()
        .ok_or("old Move accepted")?;
    assert!(error.contains("コピー後に転送元が変更"));
    Ok(())
}

#[test]
fn favorite_rejects_stale_scopes_and_insufficient_access_before_any_write() -> Result<(), String> {
    for provider in [Provider::Apple, Provider::Immich] {
        for access in [
            ScanAccess::Full,
            ScanAccess::Limited,
            ScanAccess::Unavailable,
        ] {
            let mut state = state();
            let index = usize::from(provider == Provider::Immich);
            state.snapshots[index].access = access;
            if access == ScanAccess::Full {
                // Snapshot membership alone must not authorize an old scope.
                state.snapshots[index].scope = "stale".into();
                state.snapshots[index].assets[0].key.scope = "stale".into();
            }
            let keys = state
                .snapshots
                .iter()
                .flat_map(|s| &s.assets)
                .map(|a| a.key.clone())
                .collect();
            let core = core(state);
            let mut native = Native::new(Fault::None);
            native.run(&core, Event::SetFavorite { keys, value: true })?;
            assert!(core.view().error.is_some());
            assert_eq!(native.apple_writes + native.remote_writes, 0);
            assert_eq!(native.persist_calls, 0);
        }
    }
    Ok(())
}

#[test]
fn uncertain_or_invalid_favorite_results_disable_writes_until_refresh() -> Result<(), String> {
    for fault in [
        Fault::Duplicate,
        Fault::Missing,
        Fault::WrongKey,
        Fault::WrongValue,
        Fault::LostNativeResponse,
    ] {
        let core = core(state());
        let mut native = Native::new(fault);
        native.run(&core, favorite_event(&[Provider::Apple]))?;
        assert!(core.view().error.is_some());
        assert!(native.apple.is_favorite); // Native write may already be committed.
        assert_eq!(
            core.view().state.snapshots[0].access,
            ScanAccess::Unavailable
        );
        let saved = native.saved.as_ref().ok_or("invalidation not persisted")?;
        assert_eq!(saved.snapshots[0].access, ScanAccess::Unavailable);
        native.run(&core, favorite_event(&[Provider::Apple]))?;
        assert_eq!(native.apple_writes, 1);
        native.fault = Fault::None;
        native.run(
            &core,
            Event::Refresh {
                permission: false,
                now: 20.0,
            },
        )?;
        assert!(core.view().error.is_none());
        native.run(&core, favorite_event(&[Provider::Apple]))?;
        assert!(core.view().error.is_none());
        assert_eq!(native.apple_writes, 2);
    }
    Ok(())
}

#[test]
fn changed_original_inventory_never_inherits_favorite_fingerprints() -> Result<(), String> {
    let core = core(state());
    let mut native = Native::new(Fault::ChangedInventory);
    native.run(&core, favorite_event(&[Provider::Apple]))?;
    assert!(core.view().error.is_none());
    let fresh = &core.view().state.snapshots[0].assets[0];
    assert_eq!(fresh.revision, "after");
    assert_eq!(fresh.resources[0].name, "changed.jpg");
    assert!(fresh.resources[0].sha1.is_none());
    assert!(fresh.resources[0].bytes.is_none());
    assert_eq!(core.view().photos.len(), 2);
    Ok(())
}

#[test]
fn failed_favorite_persistence_disables_the_current_session() -> Result<(), String> {
    for provider in [Provider::Apple, Provider::Immich] {
        let core = core(state());
        let mut native = Native::new(Fault::None);
        native.fail_persist = true;
        native.run(&core, favorite_event(&[provider]))?;
        assert!(core.view().error.is_some());
        let index = usize::from(provider == Provider::Immich);
        assert_eq!(
            core.view().state.snapshots[index].access,
            ScanAccess::Unavailable
        );
        native.run(&core, favorite_event(&[provider]))?;
        assert_eq!(native.apple_writes + native.remote_writes, 1);
        assert_eq!(native.persist_calls, 1);
    }
    Ok(())
}

#[test]
fn uncertain_remote_favorite_preserves_the_verified_apple_result() -> Result<(), String> {
    let core = core(state());
    let mut native = Native::new(Fault::LostRemoteResponse);
    native.run(&core, favorite_event(&[Provider::Apple, Provider::Immich]))?;
    let view = core.view();
    assert!(view.error.is_some());
    assert!(view.state.snapshots[0].assets[0].is_favorite);
    assert!(view.state.snapshots[0].assets[0].fingerprints_complete());
    assert_eq!(view.state.snapshots[0].access, ScanAccess::Full);
    assert_eq!(view.state.snapshots[1].access, ScanAccess::Unavailable);
    assert!(native.remote_favorite);
    assert!(view.state.receipts.is_empty());
    native.run(&core, favorite_event(&[Provider::Apple, Provider::Immich]))?;
    assert_eq!(native.apple_writes, 1);
    assert_eq!(native.remote_writes, 1);
    Ok(())
}
