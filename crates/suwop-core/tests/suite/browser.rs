use suwop_core::{
    browser::{BrowserOptions, PhotoFilter, PhotoSort, browse, photo_id},
    domain::{AssetKey, Presence, Provider, ResourceRole, StoredAsset, UnifiedPhoto},
};
fn photo(id: &str, date: Option<f64>, role: ResourceRole, favorite: bool) -> UnifiedPhoto {
    UnifiedPhoto {
        presence: Presence::AppleOnly,
        assets: vec![StoredAsset {
            immich_parent_revision: None,
            immich_visibility: None,
            immich_stack: suwop_core::domain::ImmichStackState::Unknown,
            immich_stack_membership: None,
            apple_visibility: suwop_core::domain::AppleVisibility::Visible,
            key: AssetKey {
                provider: Provider::Apple,
                scope: "library".into(),
                asset_id: id.into(),
            },
            name: format!("{id}.JPG"),
            captured_at: date,
            modified_at: None,
            revision: "1".into(),
            resources: vec![suwop_core::domain::PhotoResource {
                id: "original".into(),
                name: format!("{id}.JPG"),
                role,
                sha1: None,
                bytes: None,
            }],
            is_favorite: favorite,
            latitude: None,
            longitude: None,
            inventory_complete: true,
            is_offline: false,
            deletion_blockers: vec![],
        }],
    }
}
#[test]
fn sort_keeps_unknown_dates_last_and_is_stable() {
    let photos = vec![
        photo("unknown", None, ResourceRole::Image, false),
        photo("late", Some(20.0), ResourceRole::Image, false),
        photo("early", Some(10.0), ResourceRole::Image, false),
    ];
    let mut options = BrowserOptions::default();
    assert_eq!(
        browse(&photos, &options).photo_ids,
        vec![
            photo_id(&photos[1]),
            photo_id(&photos[2]),
            photo_id(&photos[0])
        ]
    );
    options.sort = PhotoSort::Oldest;
    assert_eq!(
        browse(&photos, &options).photo_ids,
        vec![
            photo_id(&photos[2]),
            photo_id(&photos[1]),
            photo_id(&photos[0])
        ]
    );
    options.sort = PhotoSort::Name;
    assert_eq!(
        browse(&photos, &options).photo_ids,
        vec![
            photo_id(&photos[2]),
            photo_id(&photos[1]),
            photo_id(&photos[0])
        ]
    );
}

#[test]
fn subsecond_dates_before_the_unix_epoch_search_the_correct_calendar_day() {
    let photos = vec![
        photo("before", Some(-0.25), ResourceRole::Image, false),
        photo("after", Some(0.25), ResourceRole::Image, false),
    ];
    for (query, index) in [("1969-12-31", 0), ("1970-01-01", 1)] {
        let view = browse(
            &photos,
            &BrowserOptions {
                query: query.into(),
                time_zone: Some("UTC".into()),
                ..BrowserOptions::default()
            },
        );
        assert_eq!(view.photo_ids, vec![photo_id(&photos[index])]);
    }
}
#[test]
fn search_and_filters_combine_without_changing_collection_counts() {
    let mut photos = vec![
        photo("Summer", Some(1_704_067_200.0), ResourceRole::Image, true),
        photo("Winter", Some(10.0), ResourceRole::Video, false),
    ];
    photos[0].presence = Presence::Both;
    let mut options = BrowserOptions {
        query: "SUMMER 2024".into(),
        filter: PhotoFilter::Favorites,
        presence: Some(Presence::Both),
        ..BrowserOptions::default()
    };
    let view = browse(&photos, &options);
    assert_eq!(view.photo_ids, vec![photo_id(&photos[0])]);
    assert_eq!(view.total, 2);
    assert_eq!(view.favorites, 1);
    assert_eq!(view.videos, 1);
    options.presence = Some(Presence::ImmichOnly);
    assert!(browse(&photos, &options).photo_ids.is_empty());
    options.presence = None;
    options.query = "summer absent".into();
    assert!(browse(&photos, &options).photo_ids.is_empty());
}
#[test]
fn media_collections_distinguish_live_companions_from_regular_videos() {
    let photos = vec![
        photo("raw", None, ResourceRole::RawImage, false),
        photo("live", None, ResourceRole::LiveVideo, false),
        photo("video", None, ResourceRole::Video, false),
    ];
    for (filter, indices) in [
        (PhotoFilter::Raw, vec![0]),
        (PhotoFilter::Live, vec![1]),
        (PhotoFilter::Videos, vec![2]),
        (PhotoFilter::Photos, vec![1, 0]),
    ] {
        let view = browse(
            &photos,
            &BrowserOptions {
                filter,
                ..BrowserOptions::default()
            },
        );
        assert_eq!(
            view.photo_ids,
            indices
                .into_iter()
                .map(|i| photo_id(&photos[i]))
                .collect::<Vec<_>>()
        );
    }
}
#[test]
fn merged_favorites_count_once_and_ids_match_the_swift_bridge() {
    let mut item = photo("a", None, ResourceRole::Image, false);
    let mut other = item.assets[0].clone();
    other.key.provider = Provider::Immich;
    other.key.asset_id = "b".into();
    other.is_favorite = true;
    item.assets.push(other);
    assert_eq!(photo_id(&item), "apple|library|a+immich|library|b");
    let view = browse(
        &[item],
        &BrowserOptions {
            filter: PhotoFilter::Favorites,
            ..BrowserOptions::default()
        },
    );
    assert_eq!(view.favorites, 1);
    assert_eq!(view.photo_ids.len(), 1);
}
#[test]
fn browsing_remains_available_while_native_work_is_running() {
    use crux_core::Core;
    use suwop_core::app::{Event, Model, SavedLibrary, Suwop};
    use suwop_core::domain::{LibrarySnapshot, ScanAccess};
    let item = photo("a", None, ResourceRole::Image, true);
    let id = photo_id(&item);
    let core = Core::new_with(
        Suwop,
        Model {
            busy: true,
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "library".into(),
                snapshots: vec![LibrarySnapshot {
                    provider: Provider::Apple,
                    scope: "library".into(),
                    assets: item.assets,
                    access: ScanAccess::Full,
                    scanned_at: None,
                }],
                ..SavedLibrary::default()
            },
            ..Model::default()
        },
    );
    assert!(
        core.process_event(Event::Browse {
            options: BrowserOptions {
                filter: PhotoFilter::Favorites,
                ..BrowserOptions::default()
            }
        })
        .is_empty()
    );
    assert!(core.view().busy);
    assert_eq!(core.view().browser.photo_ids, vec![id]);
}

#[test]
fn provider_filter_selects_projected_members_without_changing_verified_presence()
-> Result<(), serde_json::Error> {
    use crux_core::Core;
    use serde_json::json;
    use suwop_core::app::{Event, Model, SavedLibrary, Suwop};
    use suwop_core::domain::{AppleVisibility, LibrarySnapshot, ScanAccess};

    let make_asset = |id, provider, captured_at, fingerprint: Option<&str>| {
        let mut asset = photo(id, captured_at, ResourceRole::Image, false)
            .assets
            .remove(0);
        asset.key.provider = provider;
        asset.resources[0].sha1 = fingerprint.map(str::to_owned);
        asset
    };
    let shared_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let verified_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let unrelated_hash = "cccccccccccccccccccccccccccccccccccccccc";
    let apple_assets = vec![
        make_asset("pending", Provider::Apple, Some(30.0), None),
        make_asset("shared-a", Provider::Apple, Some(20.0), Some(shared_hash)),
        make_asset(
            "verified-a",
            Provider::Apple,
            Some(10.0),
            Some(verified_hash),
        ),
        StoredAsset {
            apple_visibility: AppleVisibility::Hidden,
            ..make_asset("hidden", Provider::Apple, Some(40.0), None)
        },
    ];
    let immich_assets = vec![
        make_asset("shared-i", Provider::Immich, Some(20.0), Some(shared_hash)),
        make_asset(
            "unrelated",
            Provider::Immich,
            Some(5.0),
            Some(unrelated_hash),
        ),
    ];
    let core = Core::new_with(
        Suwop,
        Model {
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "library".into(),
                snapshots: [
                    (Provider::Apple, apple_assets),
                    (Provider::Immich, immich_assets),
                ]
                .into_iter()
                .map(|(provider, assets)| LibrarySnapshot {
                    provider,
                    scope: "library".into(),
                    assets,
                    access: ScanAccess::Full,
                    scanned_at: Some(50.0),
                })
                .collect(),
                ..SavedLibrary::default()
            },
            ..Model::default()
        },
    );
    let pending = "apple|library|pending";
    let shared = "apple|library|shared-a+immich|library|shared-i";
    let verified = "apple|library|verified-a";
    let unrelated = "immich|library|unrelated";
    let browse_options = |options| {
        assert!(core.process_event(Event::Browse { options }).is_empty());
        core.view().browser.photo_ids
    };
    for (provider, expected) in [
        (Provider::Apple, vec![pending, shared, verified]),
        (Provider::Immich, vec![shared, unrelated]),
    ] {
        let options = BrowserOptions {
            provider: Some(provider),
            ..BrowserOptions::default()
        };
        assert_eq!(browse_options(options), expected);
    }

    let legacy_options = serde_json::from_value(json!({
        "query": "",
        "filter": "all",
        "sort": "newest",
        "presence": "appleOnly"
    }))?;
    assert_eq!(browse_options(legacy_options), vec![verified]);
    let public = core.view();
    let presence = |id| {
        public
            .photos
            .iter()
            .find(|p| photo_id(p) == id)
            .map(|p| p.presence)
    };
    assert_eq!(presence(pending), Some(Presence::Unverified));
    assert_eq!(presence(shared), Some(Presence::Both));
    Ok(())
}
