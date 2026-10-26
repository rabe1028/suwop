use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    albums::{AlbumAction, AlbumEdit, AlbumKey, AlbumPermissions, AlbumSnapshot, StoredAlbum},
    app::{
        ConnectionSettings, Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse,
        Suwop,
    },
    domain::{
        AssetKey, LibrarySnapshot, PhotoResource, Provider, ResourceRole, ScanAccess, StoredAsset,
    },
    immich::{Asset, HttpRequest, HttpResponse, Session, Version},
    trash::{AppleTrashOperation, AppleTrashOutcome},
};

fn photo_key() -> AssetKey {
    AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: "photo".into(),
    }
}
fn album() -> StoredAlbum {
    StoredAlbum {
        key: AlbumKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            album_id: "album".into(),
        },
        title: "旅行".into(),
        members: vec![],
        permissions: AlbumPermissions {
            add: true,
            remove: true,
            rename: true,
            delete: true,
        },
    }
}
fn snapshot() -> AlbumSnapshot {
    AlbumSnapshot {
        provider: Provider::Apple,
        scope: "apple".into(),
        albums: vec![album()],
        access: ScanAccess::Full,
    }
}
fn fixture_state() -> SavedLibrary {
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        albums: vec![snapshot()],
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            access: ScanAccess::Full,
            scanned_at: None,
            assets: vec![StoredAsset {
                immich_visibility: None,
                immich_stack: suwop_core::domain::ImmichStackState::Unknown,
                immich_stack_membership: None,
                apple_visibility: suwop_core::domain::AppleVisibility::Visible,
                key: photo_key(),
                name: "photo.jpg".into(),
                captured_at: None,
                modified_at: None,
                revision: "revision".into(),
                resources: vec![],
                is_favorite: false,
                latitude: None,
                longitude: None,
                inventory_complete: false,
                is_offline: false,
                deletion_blockers: vec![],
            }],
        }],
        ..SavedLibrary::default()
    }
}
fn core() -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: fixture_state(),
            ..Model::default()
        },
    )
}
struct Native {
    snapshot: AlbumSnapshot,
    writes: usize,
    persists: usize,
    ignore_write: bool,
    remote: Option<RemoteAlbum>,
}
impl Native {
    fn new() -> Self {
        Self {
            snapshot: snapshot(),
            writes: 0,
            persists: 0,
            ignore_write: false,
            remote: None,
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        let mut steps = 0;
        while !effects.is_empty() {
            steps += 1;
            if steps > 30 {
                return Err("nonterminating album workflow".into());
            }
            let Effect::Io(mut request) = effects.remove(0);
            if matches!(&request.operation, ShellOperation::ReadCredential { .. }) {
                effects.extend(
                    core.resolve(
                        &mut request,
                        ShellResponse {
                            value: None,
                            error: Some("Immich credential unavailable".into()),
                        },
                    )
                    .map_err(|e| e.to_string())?,
                );
                continue;
            }
            let value =
                match &request.operation {
                    ShellOperation::AppleAlbums { .. } => serde_json::to_value(&self.snapshot),
                    ShellOperation::AppleAlbumCreate { title, .. } => {
                        self.writes += 1;
                        let mut created = album();
                        created.key.album_id = "new".into();
                        created.title.clone_from(title);
                        self.snapshot.albums.push(created.clone());
                        serde_json::to_value(created)
                    }
                    ShellOperation::AppleAlbumEdit { key, edit } => {
                        self.writes += 1;
                        if !self.ignore_write {
                            if matches!(edit.action, AlbumAction::Delete) {
                                self.snapshot.albums.retain(|a| a.key != *key);
                            } else if let Some(album) =
                                self.snapshot.albums.iter_mut().find(|a| a.key == *key)
                            {
                                match edit.action {
                                    AlbumAction::Rename => {
                                        album.title = edit.title.clone().ok_or("missing name")?;
                                    }
                                    AlbumAction::Add => album.members.extend(edit.keys.clone()),
                                    AlbumAction::Remove => {
                                        album.members.retain(|k| !edit.keys.contains(k));
                                    }
                                    AlbumAction::Delete => {}
                                }
                            }
                        }
                        Ok(Value::Null)
                    }
                    ShellOperation::Persist(_) => {
                        self.persists += 1;
                        Ok(Value::Null)
                    }
                    ShellOperation::Http(http) => {
                        let response = self
                            .remote
                            .as_mut()
                            .ok_or("unexpected Immich album request")?
                            .response(http)?;
                        if matches!(http.method.as_str(), "PATCH" | "PUT" | "DELETE") {
                            self.writes += 1;
                        }
                        serde_json::to_value(response)
                    }
                    _ => return Err(
                        "albums must not mutate photo files, transfer receipts or asset deletion"
                            .into(),
                    ),
                }
                .map_err(|e| e.to_string())?;
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
        assert!(!core.view().busy);
        Ok(())
    }
}
fn edit(action: AlbumAction, keys: Vec<AssetKey>, title: Option<&str>) -> Event {
    Event::EditAlbum {
        key: album().key,
        edit: AlbumEdit {
            action,
            keys,
            title: title.map(str::to_owned),
        },
    }
}

#[test]
fn create_rename_add_remove_and_delete_only_change_the_collection() -> Result<(), String> {
    let core = core();
    let mut native = Native::new();
    native.run(
        &core,
        Event::CreateAlbum {
            provider: Provider::Apple,
            title: "  新しい旅行  ".into(),
        },
    )?;
    assert!(core.view().error.is_none());
    assert!(
        core.view()
            .albums
            .iter()
            .any(|a| a.album.title == "新しい旅行")
    );
    native.run(&core, edit(AlbumAction::Rename, vec![], Some("家族")))?;
    assert_eq!(core.view().albums[0].album.title, "家族");
    native.run(&core, edit(AlbumAction::Add, vec![photo_key()], None))?;
    assert_eq!(core.view().albums[0].photo_ids.len(), 1);
    native.run(&core, edit(AlbumAction::Remove, vec![photo_key()], None))?;
    assert!(core.view().albums[0].photo_ids.is_empty());
    native.run(&core, edit(AlbumAction::Delete, vec![], None))?;
    assert!(core.view().error.is_none());
    assert_eq!(core.view().photos.len(), 1);
    assert!(core.view().state.receipts.is_empty());
    assert_eq!(native.writes, 5);
    assert_eq!(native.persists, 5);
    Ok(())
}

#[test]
fn fresh_capabilities_and_cross_scope_members_stop_before_native_mutation() -> Result<(), String> {
    for denied in [true, false] {
        let core = core();
        let mut native = Native::new();
        let mut key = photo_key();
        if denied {
            native.snapshot.albums[0].permissions.add = false;
        } else {
            key.scope = "other".into();
        }
        native.run(&core, edit(AlbumAction::Add, vec![key], None))?;
        assert!(core.view().error.is_some());
        assert_eq!(native.writes, 0);
        assert_eq!(core.view().photos.len(), 1);
    }
    Ok(())
}

#[test]
fn successful_native_callback_without_saved_membership_invalidates_album_state()
-> Result<(), String> {
    let core = core();
    let mut native = Native::new();
    native.ignore_write = true;
    native.run(&core, edit(AlbumAction::Add, vec![photo_key()], None))?;
    assert!(core.view().error.is_some());
    assert_eq!(core.view().albums[0].access, ScanAccess::Unavailable);
    assert!(!core.view().albums[0].album.permissions.add);
    assert_eq!(native.persists, 0);
    assert_eq!(core.view().photos.len(), 1);
    Ok(())
}

#[test]
fn same_named_albums_remain_separate_and_unavailable_snapshots_are_read_only() -> Result<(), String>
{
    let mut first = snapshot();
    let mut second = snapshot();
    first.access = ScanAccess::Unavailable;
    second.scope = "different".into();
    second.albums[0].key.scope.clone_from(&second.scope);
    let views = suwop_core::albums::views(&[first, second], &[], &[]);
    assert_eq!(views.len(), 2);
    assert_ne!(views[0].album.key, views[1].album.key);
    assert!(views.iter().any(|a| !a.album.permissions.delete));
    let state = suwop_core::workflow::migrate(
        json!({"schemaVersion":2,"appleScope":"apple","snapshots":[],"receipts":[]}),
    )?;
    assert!(state.albums.is_empty());
    Ok(())
}

#[test]
fn apple_albums_remain_available_when_immich_reconnect_fails() -> Result<(), String> {
    for event in [
        Event::RefreshAlbums,
        Event::CreateAlbum {
            provider: Provider::Apple,
            title: "local".into(),
        },
        edit(AlbumAction::Rename, vec![], Some("local")),
    ] {
        let refreshing = matches!(event, Event::RefreshAlbums);
        let mut state = fixture_state();
        state.connection = Some(ConnectionSettings {
            address: "https://offline/api".into(),
            allow_http: false,
            credential_id: "missing".into(),
        });
        let core = Core::new_with(
            Suwop,
            Model {
                state,
                ready: true,
                ..Model::default()
            },
        );
        let mut native = Native::new();
        native.run(&core, event)?;
        assert_eq!(core.view().error.is_some(), refreshing);
        assert!(
            core.view()
                .albums
                .iter()
                .all(|a| a.access == ScanAccess::Full)
        );
        assert_eq!(native.writes, usize::from(!refreshing));
        assert_eq!(native.persists, 1);
    }
    Ok(())
}

const REMOTE_OWNER: &str = "11111111-1111-4111-8111-111111111111";
const REMOTE_ALBUM: &str = "22222222-2222-4222-8222-222222222222";
const COUNTERPART: &str = "33333333-3333-4333-8333-333333333333";
const UNRELATED: &str = "44444444-4444-4444-8444-444444444444";
const TRASH_OPERATION: &str = "55555555-5555-4555-8555-555555555555";

fn remote_key(id: &str) -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "remote".into(),
        asset_id: id.into(),
    }
}

fn remote_photo(id: &str) -> Value {
    json!({
        "id":id,"ownerId":REMOTE_OWNER,"type":"IMAGE",
        "originalFileName":format!("{id}.jpg"),
        "checksum":if id == COUNTERPART { "1".repeat(40) } else { "2".repeat(40) },
        "fileCreatedAt":"2026-01-01T00:00:00Z",
        "fileModifiedAt":"2026-01-01T00:00:00Z",
        "updatedAt":"2026-01-01T00:00:00Z",
        "isFavorite":false,"isOffline":false,"isTrashed":false
    })
}

struct RemoteAlbum {
    title: String,
    members: Vec<String>,
    deleted: bool,
    owner: String,
}

impl RemoteAlbum {
    fn info(&self) -> Value {
        json!({"id":REMOTE_ALBUM,"albumName":self.title,"ownerId":self.owner})
    }

    fn response(&mut self, request: &HttpRequest) -> Result<HttpResponse, String> {
        let route = request
            .url
            .strip_prefix("https://example/api/")
            .ok_or("unexpected album origin")?;
        let album_route = format!("albums/{REMOTE_ALBUM}");
        let members_route = format!("{album_route}/assets");
        let body = match (request.method.as_str(), route) {
            ("GET", "albums") => json!(if self.deleted {
                vec![]
            } else {
                vec![self.info()]
            }),
            ("GET", route) if route == album_route => self.info(),
            ("POST", "search/metadata") => {
                let body = request.body.as_ref().ok_or("missing album search body")?;
                assert_eq!(body["filter"]["albumIds"]["any"], json!([REMOTE_ALBUM]));
                json!({"assets":{"items":self.members.iter().map(|id| remote_photo(id)).collect::<Vec<_>>(),"nextCursor":null}})
            }
            ("GET", route) if route.starts_with("assets/") => {
                let id = route.strip_prefix("assets/").ok_or("missing photo ID")?;
                if ![COUNTERPART, UNRELATED].contains(&id) {
                    return Err("unexpected album photo".into());
                }
                remote_photo(id)
            }
            ("PATCH", route) if route == album_route => {
                self.title = request
                    .body
                    .as_ref()
                    .and_then(|b| b["albumName"].as_str())
                    .ok_or("missing album title")?
                    .into();
                self.info()
            }
            ("DELETE", route) if route == album_route => {
                self.deleted = true;
                Value::Null
            }
            (method @ ("PUT" | "DELETE"), route) if route == members_route => {
                let ids: Vec<String> = serde_json::from_value(
                    request.body.as_ref().ok_or("missing member body")?["ids"].clone(),
                )
                .map_err(|e| e.to_string())?;
                assert!(
                    ids.iter()
                        .all(|id| [COUNTERPART, UNRELATED].contains(&id.as_str()))
                );
                if method == "PUT" {
                    self.members.extend(ids.clone());
                } else {
                    self.members.retain(|id| !ids.contains(id));
                }
                json!(
                    ids.iter()
                        .map(|id| json!({"id":id,"success":true}))
                        .collect::<Vec<_>>()
                )
            }
            _ => return Err("album workflow attempted an unrelated request".into()),
        };
        Ok(HttpResponse {
            status: 200,
            body,
            path: None,
        })
    }
}

fn fenced_remote_album(members: Vec<String>) -> Result<(Core<Suwop>, Native), String> {
    let mut state = fixture_state();
    let mut original = state.snapshots[0].assets[0].clone();
    original.resources = vec![PhotoResource {
        id: "original".into(),
        name: original.name.clone(),
        role: ResourceRole::Image,
        sha1: Some("1".repeat(40)),
        bytes: Some(12),
    }];
    original.inventory_complete = true;
    state.snapshots[0].assets[0] = original.clone();
    state.pending_apple_trash.push(AppleTrashOperation {
        id: TRASH_OPERATION.into(),
        scope: "apple".into(),
        assets: vec![original],
        outcome: AppleTrashOutcome::Unknown,
        visibility: None,
    });
    let assets = [COUNTERPART, UNRELATED]
        .into_iter()
        .map(|id| {
            serde_json::from_value::<Asset>(remote_photo(id))
                .map(|asset| asset.record("remote", None, None))
                .map_err(|e| e.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    state.snapshots.push(LibrarySnapshot {
        provider: Provider::Immich,
        scope: "remote".into(),
        assets,
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "test".into(),
        user_id: REMOTE_OWNER.into(),
        scope: "remote".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let core = Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(session),
            ready: true,
            ..Model::default()
        },
    );
    let mut native = Native::new();
    native.remote = Some(RemoteAlbum {
        title: "旅行".into(),
        members,
        deleted: false,
        owner: REMOTE_OWNER.into(),
    });
    Ok((core, native))
}

fn remote_edit(action: AlbumAction, keys: Vec<AssetKey>, title: Option<&str>) -> Event {
    Event::EditAlbum {
        key: AlbumKey {
            provider: Provider::Immich,
            scope: "remote".into(),
            album_id: REMOTE_ALBUM.into(),
        },
        edit: AlbumEdit {
            action,
            keys,
            title: title.map(str::to_owned),
        },
    }
}

#[test]
fn pending_apple_delete_allows_album_only_edits_and_unrelated_members() -> Result<(), String> {
    for action in [
        AlbumAction::Rename,
        AlbumAction::Delete,
        AlbumAction::Add,
        AlbumAction::Remove,
    ] {
        let mut members = vec![COUNTERPART.into()];
        if matches!(action, AlbumAction::Remove) {
            members.push(UNRELATED.into());
        }
        let (core, mut native) = fenced_remote_album(members)?;
        let before = serde_json::to_value(core.view().state).map_err(|e| e.to_string())?;
        let keys = if matches!(action, AlbumAction::Add | AlbumAction::Remove) {
            vec![remote_key(UNRELATED)]
        } else {
            vec![]
        };
        let rename = matches!(action, AlbumAction::Rename);
        let deleting = matches!(action, AlbumAction::Delete);
        let adding = matches!(action, AlbumAction::Add);
        native.run(&core, remote_edit(action, keys, rename.then_some("家族")))?;
        let view = core.view();
        assert!(view.error.is_none(), "{:?}", view.error);
        assert_eq!(native.writes, 1);
        assert_eq!(native.persists, 1);
        let after = serde_json::to_value(&view.state).map_err(|e| e.to_string())?;
        for field in ["pendingAppleTrash", "snapshots", "receipts"] {
            assert_eq!(after[field], before[field], "{field}");
        }
        let remote = native.remote.as_ref().ok_or("missing remote album")?;
        assert_eq!(remote.deleted, deleting);
        if !deleting {
            let saved = view
                .state
                .albums
                .iter()
                .find(|s| s.provider == Provider::Immich)
                .and_then(|s| s.albums.first())
                .ok_or("missing saved album")?;
            assert!(saved.members.contains(&remote_key(COUNTERPART)));
            assert_eq!(saved.members.contains(&remote_key(UNRELATED)), adding);
            assert_eq!(saved.title, if rename { "家族" } else { "旅行" });
        }
    }
    Ok(())
}

#[test]
fn pending_apple_delete_still_fences_target_album_members_and_owner_changes() -> Result<(), String>
{
    for action in [AlbumAction::Add, AlbumAction::Remove] {
        let members = if matches!(action, AlbumAction::Remove) {
            vec![COUNTERPART.into()]
        } else {
            vec![]
        };
        let (core, mut native) = fenced_remote_album(members)?;
        let before = serde_json::to_value(core.view().state).map_err(|e| e.to_string())?;
        native.run(
            &core,
            remote_edit(action, vec![remote_key(COUNTERPART)], None),
        )?;
        assert!(
            core.view()
                .error
                .as_deref()
                .is_some_and(|e| e.contains("削除結果が不明"))
        );
        assert_eq!(native.writes, 0);
        assert_eq!(native.persists, 0);
        assert_eq!(
            serde_json::to_value(core.view().state).map_err(|e| e.to_string())?,
            before
        );
    }
    let (core, mut native) = fenced_remote_album(vec![COUNTERPART.into()])?;
    native.remote.as_mut().ok_or("missing remote album")?.owner = UNRELATED.into();
    native.run(
        &core,
        remote_edit(AlbumAction::Rename, vec![], Some("家族")),
    )?;
    assert!(core.view().error.is_some());
    assert_eq!(native.writes, 0);
    assert_eq!(native.persists, 0);
    assert_eq!(core.view().state.pending_apple_trash.len(), 1);
    Ok(())
}

#[test]
fn gallery_materializes_candidates_only_for_the_open_album() -> Result<(), String> {
    use crux_core::App;
    let mut state = fixture_state();
    let template = state.snapshots[0].assets[0].clone();
    state.snapshots[0].assets = (0..1_000)
        .map(|index| {
            let mut asset = template.clone();
            asset.key.asset_id = index.to_string();
            asset
        })
        .collect();
    state.albums[0].albums = (0..100)
        .map(|index| {
            let mut item = album();
            item.key.album_id = index.to_string();
            item
        })
        .collect();
    let key = state.albums[0].albums[0].key.clone();
    let mut model = Model {
        state,
        ready: true,
        ..Model::default()
    };
    let view = Suwop.view(&model);
    assert!(view.albums.iter().all(|a| a.candidates.is_empty()));
    let baseline = serde_json::to_vec(&view).map_err(|e| e.to_string())?.len();
    let _ = Suwop.update(
        Event::BrowseAlbumCandidates {
            key: Some(key.clone()),
        },
        &mut model,
    );
    let view = Suwop.view(&model);
    assert_eq!(
        view.albums
            .iter()
            .map(|a| a.candidates.len())
            .sum::<usize>(),
        1_000
    );
    assert_eq!(
        view.albums
            .iter()
            .find(|a| a.album.key == key)
            .map(|a| a.candidates.len()),
        Some(1_000)
    );
    // Adding 99 unopened albums must not multiply the candidate payload.
    assert!(serde_json::to_vec(&view).map_err(|e| e.to_string())?.len() < baseline + 300_000);
    model.state.snapshots[0].assets[0].apple_visibility =
        suwop_core::domain::AppleVisibility::Hidden;
    assert_eq!(
        Suwop
            .view(&model)
            .albums
            .iter()
            .map(|a| a.candidates.len())
            .sum::<usize>(),
        999
    );
    let _ = Suwop.update(Event::BrowseAlbumCandidates { key: None }, &mut model);
    assert!(
        Suwop
            .view(&model)
            .albums
            .iter()
            .all(|a| a.candidates.is_empty())
    );
    Ok(())
}

#[test]
fn indexed_album_members_preserve_gallery_order_and_candidate_authority() {
    use crux_core::App;
    let mut state = fixture_state();
    let template = Suwop
        .view(&Model {
            state: state.clone(),
            ready: true,
            ..Model::default()
        })
        .photos[0]
        .clone();
    let mut photos = vec![template.clone(), template.clone(), template];
    for (index, photo) in photos.iter_mut().enumerate() {
        photo.assets[0].key.asset_id = index.to_string();
    }
    let mut second_member = photos[0].assets[0].clone();
    second_member.key.asset_id = "extra".into();
    photos[0].assets.push(second_member.clone());
    state.snapshots[0].assets = photos.iter().flat_map(|p| p.assets.clone()).collect();
    let mut missing = photo_key();
    missing.asset_id = "absent".into();
    state.albums[0].albums[0].members = vec![
        photos[2].assets[0].key.clone(),
        second_member.key.clone(),
        photos[0].assets[0].key.clone(),
        missing,
    ];
    let key = state.albums[0].albums[0].key.clone();
    let expected = vec![
        suwop_core::browser::photo_id(&photos[0]),
        suwop_core::browser::photo_id(&photos[2]),
    ];
    for access in [
        ScanAccess::Full,
        ScanAccess::Limited,
        ScanAccess::Unavailable,
    ] {
        state.albums[0].access = access;
        let result = suwop_core::albums::views_for_picker(
            &state.albums,
            &photos,
            &state.snapshots,
            Some(&key),
        );
        assert_eq!(result[0].photo_ids, expected);
        assert_eq!(
            result[0].candidates.len(),
            usize::from(access == ScanAccess::Full)
        );
        if access == ScanAccess::Full {
            assert_eq!(result[0].candidates[0].key, photos[1].assets[0].key);
        }
    }
}

#[test]
#[ignore = "explicit local performance comparison"]
fn indexed_album_large_library_comparison() -> Result<(), std::io::Error> {
    use crux_core::App;
    use std::{collections::BTreeSet, time::Instant};
    let mut state = fixture_state();
    let template = Suwop
        .view(&Model {
            state: state.clone(),
            ready: true,
            ..Model::default()
        })
        .photos[0]
        .clone();
    let photos: Vec<_> = (0..50_000)
        .map(|index| {
            let mut photo = template.clone();
            photo.assets[0].key.asset_id = index.to_string();
            photo
        })
        .collect();
    state.snapshots[0].assets = photos.iter().flat_map(|p| p.assets.clone()).collect();
    state.albums[0].albums = (0..100)
        .map(|index| {
            let mut item = album();
            item.key.album_id = format!("{index:03}");
            item.members = photos
                .iter()
                .skip(index)
                .step_by(100)
                .map(|p| p.assets[0].key.clone())
                .collect();
            item
        })
        .collect();
    let start = Instant::now();
    let before: Vec<Vec<String>> = state.albums[0]
        .albums
        .iter()
        .map(|item| {
            let members: BTreeSet<_> = item.members.iter().collect();
            photos
                .iter()
                .filter(|photo| {
                    photo
                        .assets
                        .iter()
                        .any(|asset| members.contains(&asset.key))
                })
                .map(suwop_core::browser::photo_id)
                .collect()
        })
        .collect();
    let before_seconds = start.elapsed().as_secs_f64();
    let start = Instant::now();
    let after = suwop_core::albums::views(&state.albums, &photos, &state.snapshots);
    let after_seconds = start.elapsed().as_secs_f64();
    assert_eq!(
        before,
        after
            .iter()
            .map(|v| v.photo_ids.clone())
            .collect::<Vec<_>>()
    );
    std::fs::write(
        std::env::temp_dir().join(format!("suwop-album-benchmark-{}.json", std::process::id())),
        json!({
            "photos": 50_000,
            "albums": 100,
            "before_seconds": before_seconds,
            "after_seconds": after_seconds,
        })
        .to_string(),
    )?;
    Ok(())
}
