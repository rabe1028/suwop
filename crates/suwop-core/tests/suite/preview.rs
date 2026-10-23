use crux_core::Core;
use suwop_core::{
    app::{Event, Model, SavedLibrary, Suwop},
    browser::photo_id,
    domain::{
        AssetKey, LibrarySnapshot, PhotoResource, Provider, ResourceRole, ScanAccess, StoredAsset,
        UnifiedPhoto, catalog,
    },
    immich::{Session, Version},
    media::{PreviewAccess, selected_preview},
};

fn asset(provider: Provider, id: &str, fingerprint: char) -> StoredAsset {
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
            asset_id: id.into(),
        },
        name: format!("{id}.jpg"),
        captured_at: Some(1.0),
        modified_at: Some(2.0),
        revision: "1".into(),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: "original.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(fingerprint.to_string().repeat(40)),
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
fn snapshot(assets: Vec<StoredAsset>, access: ScanAccess) -> LibrarySnapshot {
    LibrarySnapshot {
        provider: assets[0].key.provider,
        scope: assets[0].key.scope.clone(),
        assets,
        access,
        scanned_at: Some(1.0),
    }
}
fn session() -> Session {
    Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "fixture".into(),
        user_id: "owner".into(),
        scope: "remote".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    }
}
fn state() -> SavedLibrary {
    SavedLibrary {
        schema_version: 8,
        apple_scope: "apple".into(),
        snapshots: vec![
            snapshot(
                vec![
                    asset(Provider::Apple, "a", 'a'),
                    asset(Provider::Apple, "unrelated", 'b'),
                ],
                ScanAccess::Limited,
            ),
            snapshot(
                vec![asset(Provider::Immich, "remote-a", 'a')],
                ScanAccess::Full,
            ),
        ],
        ..SavedLibrary::default()
    }
}
fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            session: Some(session()),
            ..Model::default()
        },
    )
}
fn choose(core: &Core<Suwop>, key: AssetKey) {
    assert!(
        core.process_event(Event::ChoosePreview {
            anchor: asset(Provider::Apple, "a", 'a').key,
            key
        })
        .is_empty()
    );
}
fn finish(core: &Core<Suwop>, state: SavedLibrary) {
    assert!(
        core.process_event(Event::Finished {
            state,
            session: Some(session()),
            status: "refreshed".into(),
            error: None,
            preview_to_select: None
        })
        .is_empty()
    );
}
fn source(core: &Core<Suwop>, key: &AssetKey) -> Option<AssetKey> {
    let view = core.view();
    let photo = view
        .photos
        .iter()
        .find(|p| p.assets.iter().any(|a| a.key == *key))?;
    view.preview_sources.get(&photo_id(photo)).cloned()
}

#[test]
fn choosing_one_copy_is_a_pure_read_and_cannot_target_another_photo() {
    let saved = state();
    let core = core(saved.clone());
    let apple = asset(Provider::Apple, "a", 'a').key;
    let remote = asset(Provider::Immich, "remote-a", 'a').key;
    assert_eq!(source(&core, &apple), Some(apple.clone()));
    choose(&core, remote.clone());
    assert_eq!(source(&core, &apple), Some(remote.clone()));
    assert!(!core.view().busy);
    assert_eq!(
        core.view().state.snapshots[0].assets,
        saved.snapshots[0].assets
    );
    assert_eq!(
        core.view().state.snapshots[1].assets,
        saved.snapshots[1].assets
    );
    assert!(core.view().state.receipts.is_empty());
    choose(&core, asset(Provider::Apple, "unrelated", 'b').key);
    assert!(core.view().error.is_some());
    assert_eq!(source(&core, &apple), Some(remote));
    choose(&core, apple.clone());
    assert!(core.view().error.is_none());
    assert_eq!(source(&core, &apple), Some(apple));
}

#[test]
fn choosing_a_preview_during_a_native_operation_does_not_change_its_selection() {
    let remote = asset(Provider::Immich, "remote-a", 'a').key;
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            busy: true,
            state: state(),
            session: Some(session()),
            preview_preferences: vec![remote.clone()],
            ..Model::default()
        },
    );
    let apple = asset(Provider::Apple, "a", 'a').key;
    choose(&core, apple.clone());
    assert_eq!(source(&core, &apple), Some(remote));
    assert!(core.view().busy && core.view().error.is_none());
}

#[test]
fn explicit_unavailable_copy_never_falls_back_to_another_look() -> Result<(), String> {
    let core = core(state());
    let apple = asset(Provider::Apple, "a", 'a').key;
    let remote = asset(Provider::Immich, "remote-a", 'a').key;
    choose(&core, remote.clone());
    let mut stale = state();
    stale.snapshots[1].access = ScanAccess::Unavailable;
    finish(&core, stale);
    assert_eq!(source(&core, &apple), None);
    let view = core.view();
    let choices = &view.preview_choices[&photo_id(&view.photos[0])];
    let selected = choices
        .iter()
        .find(|c| c.selected)
        .ok_or("chosen copy was not retained")?;
    assert_eq!(selected.key, remote);
    assert!(selected.disabled_reason.is_some());
    choose(&core, selected.key.clone());
    assert!(core.view().error.is_some());
    assert_eq!(source(&core, &apple), None);
    choose(&core, apple.clone());
    assert_eq!(source(&core, &apple), Some(apple));
    Ok(())
}

#[test]
fn selection_follows_the_stored_copy_through_regrouping_but_not_removal() {
    let core = core(state());
    let apple = asset(Provider::Apple, "a", 'a').key;
    let remote = asset(Provider::Immich, "remote-a", 'a').key;
    choose(&core, remote.clone());
    let mut merged = state();
    merged.snapshots[0]
        .assets
        .push(asset(Provider::Apple, "new-copy", 'a'));
    finish(&core, merged.clone());
    assert_eq!(source(&core, &apple), Some(remote.clone()));
    merged.snapshots[1].assets[0].resources[0].sha1 = Some("c".repeat(40));
    finish(&core, merged);
    assert_eq!(source(&core, &apple), Some(apple.clone()));
    assert_eq!(source(&core, &remote), Some(remote.clone()));
    let mut removed = state();
    removed.snapshots[1].assets.clear();
    finish(&core, removed);
    finish(&core, state());
    assert_eq!(source(&core, &apple), Some(apple));
}

#[test]
fn preview_membership_rejects_stale_scopes_missing_records_and_duplicate_inventory() {
    let saved = state();
    let photo = catalog(&saved.snapshots, &[]).remove(0);
    let stale = PreviewAccess::new(&saved.snapshots, "different-library", None);
    assert_eq!(selected_preview(&stale.choices(&photo, &[])), None);
    let mut missing = saved.snapshots.clone();
    missing[0].assets.clear();
    missing[1].assets.clear();
    assert_eq!(
        selected_preview(
            &PreviewAccess::new(&missing, "apple", Some(&session())).choices(&photo, &[])
        ),
        None
    );
    let mut duplicated = vec![saved.snapshots[0].clone(), saved.snapshots[0].clone()];
    assert_eq!(
        selected_preview(&PreviewAccess::new(&duplicated, "apple", None).choices(&photo, &[])),
        None
    );
    duplicated.pop();
    let duplicate = duplicated[0].assets[0].clone();
    duplicated[0].assets.push(duplicate);
    assert_eq!(
        selected_preview(&PreviewAccess::new(&duplicated, "apple", None).choices(&photo, &[])),
        None
    );
}

#[test]
fn preview_cache_identity_tracks_revision_resources_and_server_version() {
    let mut saved = state();
    let photo = catalog(&saved.snapshots, &[]).remove(0);
    let initial =
        PreviewAccess::new(&saved.snapshots, "apple", Some(&session())).choices(&photo, &[]);
    let apple_cache = initial[0].cache_id.clone();
    let remote_cache = initial[1].cache_id.clone();
    saved.snapshots[0].assets[0].revision = "content-saved".into();
    let photo = catalog(&saved.snapshots, &[]).remove(0);
    let changed =
        PreviewAccess::new(&saved.snapshots, "apple", Some(&session())).choices(&photo, &[]);
    assert_ne!(changed[0].cache_id, apple_cache);
    assert!(changed[0].disabled_reason.is_none());
    saved.snapshots[0].assets[0].revision = "1".into();
    saved.snapshots[0].assets[0].resources[0].bytes = Some(13);
    let photo = catalog(&saved.snapshots, &[]).remove(0);
    assert_ne!(
        PreviewAccess::new(&saved.snapshots, "apple", None).choices(&photo, &[])[0].cache_id,
        apple_cache
    );
    let mut upgraded = session();
    upgraded.version.minor = 3;
    let choices =
        PreviewAccess::new(&saved.snapshots, "apple", Some(&upgraded)).choices(&photo, &[]);
    assert_ne!(choices[1].cache_id, remote_cache);
    saved.snapshots[1].access = ScanAccess::Unavailable;
    let unavailable =
        PreviewAccess::new(&saved.snapshots, "apple", Some(&session())).choices(&photo, &[]);
    assert_ne!(unavailable[1].cache_id, remote_cache);
}

#[test]
fn preview_reads_allow_limited_access_and_cached_offline_originals() {
    let mut local = asset(Provider::Apple, "a", 'a');
    local.inventory_complete = false;
    local.is_offline = true;
    let snapshots = vec![snapshot(vec![local.clone()], ScanAccess::Limited)];
    let photo = UnifiedPhoto {
        assets: vec![local.clone()],
        presence: suwop_core::domain::Presence::Unverified,
    };
    assert_eq!(
        selected_preview(&PreviewAccess::new(&snapshots, "apple", None).choices(&photo, &[])),
        Some(local.key)
    );
}

#[test]
fn preview_http_contract_keeps_legacy_versions_and_prefers_edits_when_supported()
-> Result<(), String> {
    for (major, minor, edited) in [
        (2, 0, false),
        (2, 5, false),
        (2, 6, true),
        (3, 0, true),
        (3, 2, true),
        (4, 0, false),
    ] {
        let mut session = session();
        session.version = Version {
            major,
            minor,
            patch: 0,
        };
        for preview in [false, true] {
            let request =
                session.preview_request("11111111-1111-4111-8111-111111111111", preview)?;
            assert_eq!(request.method, "GET");
            assert_eq!(request.url.contains("edited=true"), edited);
            assert_eq!(request.url.contains("size=preview"), preview);
            assert_eq!(request.url.contains("size=thumbnail"), !preview);
            assert!(request.body.is_none());
        }
    }
    assert!(session().preview_request("../missing", true).is_err());
    Ok(())
}

#[test]
fn date_search_and_order_follow_the_selected_copy_including_unknown_and_unavailable_dates()
-> Result<(), String> {
    use suwop_core::browser::{BrowserOptions, PhotoSort};
    let mut saved = state();
    saved.snapshots[0].assets[0].captured_at = Some(1_704_067_200.0); // 2024-01-01 UTC
    saved.snapshots[0].assets[1].captured_at = Some(1_719_792_000.0); // 2024-07-01 UTC
    saved.snapshots[1].assets[0].captured_at = Some(1_735_689_600.0); // 2025-01-01 UTC
    let core = core(saved.clone());
    let apple = saved.snapshots[0].assets[0].key.clone();
    let remote = saved.snapshots[1].assets[0].key.clone();
    let unrelated = saved.snapshots[0].assets[1].key.clone();
    let ids = |key: &AssetKey| -> Result<String, String> {
        core.view()
            .photos
            .iter()
            .find(|p| p.assets.iter().any(|a| a.key == *key))
            .map(photo_id)
            .ok_or("missing photo".into())
    };
    let paired_id = ids(&apple)?;
    let unrelated_id = ids(&unrelated)?;
    assert_eq!(
        core.view().browser.photo_ids,
        vec![unrelated_id.clone(), paired_id.clone()]
    );
    choose(&core, remote.clone());
    assert_eq!(
        core.view().browser.photo_ids,
        vec![paired_id.clone(), unrelated_id.clone()]
    );
    let browse = |query: &str, sort| {
        assert!(
            core.process_event(Event::Browse {
                options: BrowserOptions {
                    query: query.into(),
                    sort,
                    time_zone: Some("UTC".into()),
                    ..BrowserOptions::default()
                }
            })
            .is_empty()
        );
    };
    browse("2024-01-01", PhotoSort::Newest);
    assert!(core.view().browser.photo_ids.is_empty());
    browse("2025-01-01", PhotoSort::Newest);
    assert_eq!(core.view().browser.photo_ids, vec![paired_id.clone()]);
    saved.snapshots[1].access = ScanAccess::Unavailable;
    finish(&core, saved.clone());
    assert_eq!(core.view().browser.photo_ids, vec![paired_id.clone()]);
    assert!(source(&core, &apple).is_none());
    browse("", PhotoSort::Oldest);
    assert_eq!(
        core.view().browser.photo_ids,
        vec![unrelated_id.clone(), paired_id.clone()]
    );
    saved.snapshots[1].assets[0].captured_at = None;
    finish(&core, saved);
    assert_eq!(core.view().browser.photo_ids, vec![unrelated_id, paired_id]);
    browse("2025-01-01", PhotoSort::Newest);
    assert!(core.view().browser.photo_ids.is_empty());
    browse("2024-01-01", PhotoSort::Newest);
    assert!(core.view().browser.photo_ids.is_empty());
    Ok(())
}

#[test]
fn unverified_display_pair_can_switch_sources_without_establishing_identity() {
    let mut saved = state();
    saved.snapshots[0].assets.truncate(1);
    saved.snapshots[0].assets[0].resources[0].sha1 = None;
    let app = core(saved.clone());
    let view = app.view();
    assert_eq!(view.photos.len(), 1);
    assert_eq!(
        view.photos[0].presence,
        suwop_core::domain::Presence::Unverified
    );
    assert_eq!(catalog(&saved.snapshots, &saved.receipts).len(), 2);
    let remote = saved.snapshots[1].assets[0].key.clone();
    choose(&app, remote.clone());
    let after = app.view();
    assert_eq!(
        after.preview_sources.get(&photo_id(&after.photos[0])),
        Some(&remote)
    );
    assert!(after.state.receipts.is_empty());
}
