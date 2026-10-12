use crux_core::Core;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, TransferIntent, TransferPhase,
        TransferReceipt,
    },
    immich::{Asset, HttpRequest, HttpResponse, Session, Version},
    trash::{TrashAction, TrashIdentity, TrashItem, TrashSnapshot},
};
const PHOTO: &str = "11111111-1111-4111-8111-111111111111";
const OWNER: &str = "22222222-2222-4222-8222-222222222222";
const OP: &str = "33333333-3333-4333-8333-333333333333";

fn native(trashed: bool) -> Value {
    json!({"id":PHOTO,"ownerId":OWNER,"type":"IMAGE","originalFileName":"edited.jpg","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"2025-07-01T00:00:00Z","fileModifiedAt":"2025-07-01T00:00:00Z","updatedAt":"revision-1","isFavorite":true,"isOffline":false,"isTrashed":trashed,"isEdited":true,"libraryId":null,"exifInfo":{"fileSizeInByte":12,"dateTimeOriginal":"2025-07-01T00:00:00Z","latitude":35.0,"longitude":139.0}})
}
fn asset(value: &Value) -> Result<Asset, String> {
    serde_json::from_value(value.clone()).map_err(|error| error.to_string())
}
fn key() -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "remote".into(),
        asset_id: PHOTO.into(),
    }
}
fn state(trashed: bool) -> Result<SavedLibrary, String> {
    let remote = asset(&native(trashed))?;
    let mut apple = remote.record("apple", None, None);
    apple.key.provider = Provider::Apple;
    apple.key.asset_id = "apple-copy".into();
    apple.is_offline = false;
    apple.deletion_blockers.clear();
    Ok(SavedLibrary {
        schema_version: 2,
        apple_scope: "apple".into(),
        snapshots: vec![
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "apple".into(),
                access: ScanAccess::Full,
                assets: vec![apple],
                scanned_at: Some(10.0),
            },
            LibrarySnapshot {
                provider: Provider::Immich,
                scope: "remote".into(),
                access: ScanAccess::Full,
                assets: if trashed {
                    vec![]
                } else {
                    vec![remote.record("remote", None, None)]
                },
                scanned_at: Some(10.0),
            },
        ],
        trash: Some(TrashSnapshot {
            scope: "remote".into(),
            verified: true,
            items: if trashed {
                vec![TrashItem {
                    asset: remote.record("remote", None, None),
                    identity: TrashIdentity::from_asset("remote", &remote)?,
                }]
            } else {
                vec![]
            },
        }),
        ..SavedLibrary::default()
    })
}
fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            state,
            ready: true,
            session: Some(Session {
                endpoint: "https://photos.example/api".into(),
                key: "fixture".into(),
                user_id: OWNER.into(),
                scope: "remote".into(),
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
fn change(action: TrashAction) -> Event {
    Event::ChangeTrash {
        keys: vec![key()],
        action,
        id: OP.into(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Fault {
    Cancel,
    Disabled,
    ZeroDays,
    Foreign,
    ChangeDuringConfirmation,
    ChangePolicy,
    StartSaveFailure,
    FinishSaveFailure,
    LoseWrite,
    LoseReadback,
    InvalidRestoreCount,
}

#[derive(Default)]
struct Shell {
    faults: BTreeSet<Fault>,
    photo: Value,
    extra: BTreeMap<String, Value>,
    requests: Vec<HttpRequest>,
    persisted: Vec<SavedLibrary>,
    journal: Option<SavedLibrary>,
    writes: usize,
    policies: usize,
    pages: Vec<Value>,
}
impl Shell {
    fn new(trashed: bool) -> Self {
        Self {
            photo: native(trashed),
            ..Self::default()
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let result = match &request.operation {
                ShellOperation::Persist(state) => {
                    if (!state.pending_trash.is_empty()
                        && self.writes == 0
                        && self.faults.contains(&Fault::StartSaveFailure))
                        || (state.pending_trash.is_empty()
                            && self.writes > 0
                            && self.faults.contains(&Fault::FinishSaveFailure))
                    {
                        Err("save failed".into())
                    } else {
                        self.persisted.push(state.clone());
                        self.journal = Some(state.clone());
                        Ok(Value::Null)
                    }
                }
                ShellOperation::ConfirmTrash { prompt } => {
                    assert!(prompt.names.iter().any(|name| name == "edited.jpg"));
                    assert_eq!(prompt.address, "https://photos.example/api");
                    if self.faults.contains(&Fault::ChangeDuringConfirmation) {
                        self.photo["updatedAt"] = json!("changed");
                    }
                    Ok(json!(!self.faults.contains(&Fault::Cancel)))
                }
                ShellOperation::ReadState => {
                    self.journal.as_ref().map_or(Ok(Value::Null), |state| {
                        serde_json::to_value(state).map_err(|error| error.to_string())
                    })
                }
                ShellOperation::Http(http) => self.http(http),
                _ => return Err(format!("unexpected effect: {:?}", request.operation)),
            };
            let (value, error) = match result {
                Ok(value) => (Some(value), None),
                Err(error) => (None, Some(error)),
            };
            effects.extend(
                core.resolve(&mut request, ShellResponse { value, error })
                    .map_err(|error| error.to_string())?,
            );
        }
        Ok(())
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        assert_eq!(
            request.headers.get("x-api-key").map(String::as_str),
            Some("fixture")
        );
        assert!(request.files.is_empty() && request.download_path.is_none());
        self.requests.push(request.clone());
        let mut body = Value::Null;
        if request.url.ends_with("/config") {
            assert_eq!(request.method, "GET");
            self.policies += 1;
            body = json!({"trash":{"enabled": !self.faults.contains(&Fault::Disabled), "days":if self.faults.contains(&Fault::ZeroDays) {0} else if self.faults.contains(&Fault::ChangePolicy) && self.policies > 1 {1} else {30}}});
        } else if request.url.contains("/assets/") && request.method == "GET" {
            assert_eq!(request.method, "GET");
            if self.writes > 0 && self.faults.contains(&Fault::LoseReadback) {
                return Err("readback unavailable".into());
            }
            let id = request.url.rsplit('/').next().ok_or("missing id")?;
            body = if id == PHOTO {
                self.photo.clone()
            } else {
                self.extra.get(id).cloned().ok_or("unknown fixture id")?
            };
            if self.faults.contains(&Fault::Foreign) {
                body["ownerId"] = json!("99999999-9999-4999-8999-999999999999");
            }
        } else if request.url.ends_with("/assets") || request.url.ends_with("/trash/restore/assets")
        {
            let saved = self
                .journal
                .as_ref()
                .ok_or("mutation before durable journal")?;
            assert_eq!(saved.pending_trash.len(), 1);
            assert_eq!(saved.pending_trash[0].assets[0].key, key());
            assert!(
                saved
                    .snapshots
                    .iter()
                    .filter(|s| s.provider == Provider::Immich)
                    .all(|s| s.access == ScanAccess::Unavailable)
            );
            let deleting = request.method == "DELETE";
            let ids: Vec<_> = saved.pending_trash[0]
                .assets
                .iter()
                .map(|asset| asset.key.asset_id.clone())
                .collect();
            assert_eq!(
                request.body,
                Some(if deleting {
                    json!({"ids":ids,"force":false})
                } else {
                    json!({"ids":ids})
                })
            );
            self.writes += 1;
            self.photo["isTrashed"] = json!(deleting);
            self.photo["updatedAt"] = json!("written");
            for id in &ids {
                if let Some(asset) = self.extra.get_mut(id) {
                    asset["isTrashed"] = json!(deleting);
                    asset["updatedAt"] = json!("written");
                }
            }
            if self.faults.contains(&Fault::LoseWrite) {
                return Err("lost mutation response".into());
            }
            if !deleting {
                body = json!({"count": if self.faults.contains(&Fault::InvalidRestoreCount) {0} else {ids.len()}});
            }
        } else if request.url.contains("/asset-files?") {
            body = json!([]);
        } else if request.url.ends_with("/search/metadata") {
            assert_eq!(request.method, "POST");
            assert_eq!(
                request.body.as_ref().ok_or("missing search")?["filter"]["trashedAt"],
                json!({"ne":null})
            );
            if self.pages.is_empty() {
                body = json!({"assets":{"items":[self.photo.clone()],"nextCursor":null}});
            } else {
                body = self.pages.remove(0);
            }
        } else {
            return Err(format!(
                "unexpected request: {} {}",
                request.method, request.url
            ));
        }
        serde_json::to_value(HttpResponse {
            status: 200,
            body,
            path: None,
        })
        .map_err(|error| error.to_string())
    }
}

#[test]
fn explicit_trash_keeps_apple_copy_and_does_not_use_move_receipts() -> Result<(), String> {
    let mut before = state(false)?;
    before.receipts.push(TransferReceipt {
        id: "old-copy".into(),
        created_at: 1.0,
        phase: TransferPhase::Copied,
        intent: TransferIntent::Copy,
        source: before.snapshots[1].assets.clone(),
        destination: before.snapshots[0].assets.clone(),
        destination_provider: Provider::Apple,
        destination_scope: "apple".into(),
        signatures: BTreeSet::new(),
    });
    let receipts = serde_json::to_value(&before.receipts).map_err(|error| error.to_string())?;
    let original_apple = serde_json::to_value(&before.snapshots[0]).map_err(|e| e.to_string())?;
    let core = core(before);
    let mut shell = Shell::new(false);
    shell.run(&core, change(TrashAction::Trash))?;
    let view = core.view();
    assert_eq!(view.error, None);
    assert_eq!(shell.writes, 1);
    assert!(view.state.pending_trash.is_empty());
    assert_eq!(
        serde_json::to_value(&view.state.receipts).map_err(|error| error.to_string())?,
        receipts
    );
    assert!(view.state.snapshots[1].assets.is_empty());
    assert_eq!(
        serde_json::to_value(&view.state.snapshots[0]).map_err(|e| e.to_string())?,
        original_apple
    );
    assert_eq!(
        view.state
            .trash
            .as_ref()
            .ok_or("missing trash")?
            .items
            .len(),
        1
    );
    Ok(())
}

#[test]
fn restore_verifies_state_and_keeps_original_metadata() -> Result<(), String> {
    let core = core(state(true)?);
    let mut shell = Shell::new(true);
    shell.run(&core, change(TrashAction::Restore))?;
    let view = core.view();
    assert_eq!(view.error, None);
    assert_eq!(shell.writes, 1);
    assert!(view.state.pending_trash.is_empty());
    let restored = view.state.snapshots[1]
        .assets
        .first()
        .ok_or("missing restored photo")?;
    assert!(restored.is_favorite);
    assert_eq!(restored.latitude, Some(35.0));
    assert_eq!(
        restored.resources[0].sha1.as_deref(),
        Some("1111111111111111111111111111111111111111")
    );
    assert!(
        view.state
            .trash
            .as_ref()
            .ok_or("missing trash")?
            .items
            .is_empty()
    );
    Ok(())
}

#[test]
fn cancelled_foreign_changed_and_disabled_trash_never_write() -> Result<(), String> {
    for mode in 0..7 {
        let core = core(state(false)?);
        let mut shell = Shell::new(false);
        match mode {
            0 => {
                shell.faults.insert(Fault::Cancel);
            }
            1 => {
                shell.faults.insert(Fault::Foreign);
            }
            2 => {
                shell.faults.insert(Fault::ChangeDuringConfirmation);
            }
            3 => {
                shell.faults.insert(Fault::Disabled);
            }
            4 => {
                shell.faults.insert(Fault::ZeroDays);
            }
            5 => {
                shell.faults.insert(Fault::ChangePolicy);
            }
            _ => {
                shell.faults.insert(Fault::StartSaveFailure);
            }
        }
        shell.run(&core, change(TrashAction::Trash))?;
        assert_eq!(shell.writes, 0, "mode {mode}");
        assert!(core.view().state.pending_trash.is_empty());
        if mode == 0 {
            assert_eq!(core.view().error, None);
        } else {
            assert!(core.view().error.is_some(), "mode {mode}");
        }
    }
    Ok(())
}

#[test]
fn uncertain_writes_survive_restart_and_only_readback_unlocks_them() -> Result<(), String> {
    for action in [TrashAction::Trash, TrashAction::Restore] {
        for failure in 0..4 {
            let initial_trash = action == TrashAction::Restore;
            if failure == 3 && action == TrashAction::Trash {
                continue;
            }
            let first = core(state(initial_trash)?);
            let mut shell = Shell::new(initial_trash);
            match failure {
                0 => {
                    shell.faults.insert(Fault::LoseWrite);
                }
                1 => {
                    shell.faults.insert(Fault::LoseReadback);
                }
                2 => {
                    shell.faults.insert(Fault::FinishSaveFailure);
                }
                _ => {
                    shell.faults.insert(Fault::InvalidRestoreCount);
                }
            }
            shell.run(&first, change(action))?;
            assert!(first.view().error.is_some());
            assert_eq!(shell.writes, 1);
            assert_eq!(first.view().state.pending_trash.len(), 1);
            shell.run(&first, change(action))?;
            assert_eq!(shell.writes, 1);
            shell.faults.remove(&Fault::LoseReadback);
            shell.faults.remove(&Fault::FinishSaveFailure);
            let recovered = core(SavedLibrary::default());
            shell.run(
                &recovered,
                Event::Initialize {
                    scope: "apple".into(),
                },
            )?;
            assert_eq!(recovered.view().state.pending_trash.len(), 1);
            assert!(
                !recovered
                    .view()
                    .state
                    .trash
                    .as_ref()
                    .ok_or("missing cache")?
                    .verified
            );
            shell.requests.clear();
            shell.run(&recovered, Event::ResolveTrash { id: OP.into() })?;
            assert_eq!(recovered.view().error, None);
            assert!(recovered.view().state.pending_trash.is_empty());
            assert!(shell.requests.iter().all(|request| request.method == "GET"));
            assert_eq!(shell.writes, 1);
        }
    }
    Ok(())
}

#[test]
fn unreadable_or_opposite_result_never_clears_the_pending_record() -> Result<(), String> {
    let first = core(state(false)?);
    let mut shell = Shell::new(false);
    shell.faults.insert(Fault::LoseWrite);
    shell.run(&first, change(TrashAction::Trash))?;
    shell.photo["isTrashed"] = json!(false);
    shell.run(&first, Event::ResolveTrash { id: OP.into() })?;
    assert!(first.view().error.is_some());
    assert_eq!(first.view().state.pending_trash.len(), 1);
    assert_eq!(shell.writes, 1);
    Ok(())
}

#[test]
fn trash_list_is_complete_skips_partners_and_rejects_repeated_cursors_or_active_rows()
-> Result<(), String> {
    for invalid in 0..4 {
        let core = core(state(false)?);
        let mut shell = Shell::new(true);
        match invalid {
            0 => (),
            1 => shell.photo["isTrashed"] = json!(false),
            2 => shell.photo["ownerId"] = json!("other"),
            _ => {
                shell.pages = vec![
                    json!({"assets":{"items":[],"nextCursor":"repeat"}}),
                    json!({"assets":{"items":[],"nextCursor":"repeat"}}),
                ];
            }
        }
        shell.run(
            &core,
            Event::RefreshTrash {
                now: 1_800_000_000.0,
            },
        )?;
        let view = core.view();
        if invalid == 0 || invalid == 2 {
            assert!(view.state.trash.as_ref().ok_or("missing list")?.verified);
            assert_eq!(view.error, None);
            assert_eq!(
                view.state.trash.as_ref().ok_or("missing list")?.items.len(),
                usize::from(invalid == 0)
            );
        } else {
            assert!(view.error.is_some());
            assert!(!view.state.trash.as_ref().ok_or("missing cache")?.verified);
        }
        assert_eq!(shell.writes, 0);
    }
    Ok(())
}

#[test]
fn partner_only_pages_do_not_hide_owned_trash_on_later_pages() -> Result<(), String> {
    let core = core(state(false)?);
    let mut shell = Shell::new(true);
    let mut partner = native(true);
    partner["ownerId"] = json!("other");
    shell.pages = vec![
        json!({"assets":{"items":[partner],"nextCursor":"owned-next"}}),
        json!({"assets":{"items":[native(true)],"nextCursor":null}}),
    ];
    shell.run(
        &core,
        Event::RefreshTrash {
            now: 1_800_000_000.0,
        },
    )?;
    let view = core.view();
    assert_eq!(view.error, None);
    let snapshot = view.state.trash.as_ref().ok_or("missing list")?;
    assert!(snapshot.verified);
    assert_eq!(snapshot.items.len(), 1);
    assert_eq!(snapshot.items[0].identity.key, key());
    assert_eq!(shell.requests.len(), 2);
    assert_eq!(
        shell.requests[1].body.as_ref().ok_or("missing search")?["cursor"],
        "owned-next"
    );
    assert_eq!(shell.writes, 0);
    Ok(())
}

#[test]
fn wrong_scope_provider_and_duplicate_keys_are_denied_before_network() -> Result<(), String> {
    for keys in [
        vec![],
        vec![key(), key()],
        vec![AssetKey {
            scope: "other".into(),
            ..key()
        }],
        vec![AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            ..key()
        }],
    ] {
        let core = core(state(false)?);
        let mut shell = Shell::new(false);
        shell.run(
            &core,
            Event::ChangeTrash {
                keys,
                action: TrashAction::Trash,
                id: OP.into(),
            },
        )?;
        assert!(core.view().error.is_some());
        assert!(shell.requests.is_empty());
        assert_eq!(shell.writes, 0);
    }
    Ok(())
}

#[test]
fn bulk_trash_and_restore_validate_every_selected_owner_before_writing() -> Result<(), String> {
    const SECOND: &str = "44444444-4444-4444-8444-444444444444";
    for action in [TrashAction::Trash, TrashAction::Restore] {
        for foreign_second in [false, true] {
            let trashed = action == TrashAction::Restore;
            let mut additional = native(trashed);
            additional["id"] = json!(SECOND);
            additional["originalFileName"] = json!("second.jpg");
            additional["checksum"] = json!("2".repeat(40));
            let mut library = state(trashed)?;
            let second = asset(&additional)?;
            if trashed {
                library
                    .trash
                    .as_mut()
                    .ok_or("missing trash")?
                    .items
                    .push(TrashItem {
                        asset: second.record("remote", None, None),
                        identity: TrashIdentity::from_asset("remote", &second)?,
                    });
            } else {
                library.snapshots[1]
                    .assets
                    .push(second.record("remote", None, None));
            }
            if foreign_second {
                additional["ownerId"] = json!("other");
            }
            let core = core(library);
            let mut shell = Shell::new(trashed);
            shell.extra.insert(SECOND.into(), additional);
            shell.run(
                &core,
                Event::ChangeTrash {
                    keys: vec![
                        key(),
                        AssetKey {
                            asset_id: SECOND.into(),
                            ..key()
                        },
                    ],
                    action,
                    id: OP.into(),
                },
            )?;
            assert_eq!(shell.writes, usize::from(!foreign_second));
            assert_eq!(core.view().error.is_some(), foreign_second);
            if !foreign_second {
                assert!(core.view().state.pending_trash.is_empty());
            }
        }
    }
    Ok(())
}

#[test]
fn refreshing_a_pending_restore_does_not_unlock_favorites_or_album_membership() -> Result<(), String>
{
    use suwop_core::albums::{AlbumAction, AlbumEdit, AlbumKey};
    let first = core(state(true)?);
    let mut shell = Shell::new(true);
    shell.faults.insert(Fault::LoseWrite);
    shell.run(&first, change(TrashAction::Restore))?;
    let mut refreshed = shell.journal.clone().ok_or("missing journal")?;
    refreshed.snapshots[1].access = ScanAccess::Full;
    refreshed.snapshots[1].assets = vec![asset(&shell.photo)?.record("remote", None, None)];
    let recovered = core(refreshed);
    for event in [
        Event::SetFavorite {
            keys: vec![key()],
            value: false,
        },
        Event::EditAlbum {
            key: AlbumKey {
                provider: Provider::Immich,
                scope: "remote".into(),
                album_id: OP.into(),
            },
            edit: AlbumEdit {
                action: AlbumAction::Add,
                keys: vec![key()],
                title: None,
            },
        },
    ] {
        shell.requests.clear();
        shell.run(&recovered, event)?;
        assert!(recovered.view().error.is_some());
        assert!(shell.requests.is_empty());
        assert_eq!(shell.writes, 1);
    }
    Ok(())
}
