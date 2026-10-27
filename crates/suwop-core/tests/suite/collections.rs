use suwop_core::{
    albums::*,
    domain::{AssetKey, Provider, ScanAccess},
};

fn key(id: &str) -> AlbumKey {
    AlbumKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        album_id: id.into(),
    }
}
fn photo(id: &str) -> AssetKey {
    AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: id.into(),
    }
}
fn edit(action: CollectionAction) -> CollectionEdit {
    CollectionEdit {
        action,
        key: None,
        parent: None,
        title: None,
        collections: vec![],
        photos: vec![],
        index: 0,
        order: None,
    }
}
fn fixture() -> AlbumSnapshot {
    let folder = |id: &str, parent, children| StoredCollection {
        key: key(id),
        title: id.into(),
        kind: CollectionKind::Folder,
        parent,
        children,
        abilities: vec![
            CollectionAbility::CreateChild,
            CollectionAbility::RemoveChild,
            CollectionAbility::Move,
            CollectionAbility::ReorderChildren,
            CollectionAbility::Rename,
            CollectionAbility::Delete,
        ],
        date_order: None,
        explanation: None,
        external_url: None,
    };
    AlbumSnapshot {
        provider: Provider::Apple,
        scope: "apple".into(),
        access: ScanAccess::Full,
        albums: vec![StoredAlbum {
            key: key("album"),
            title: "album".into(),
            members: vec![photo("a"), photo("b")],
            permissions: AlbumPermissions::default(),
        }],
        collections: vec![
            folder("root", None, vec![key("child")]),
            folder("child", Some(key("root")), vec![key("album")]),
            StoredCollection {
                key: key("album"),
                title: "album".into(),
                kind: CollectionKind::Album,
                parent: Some(key("child")),
                children: vec![],
                abilities: vec![CollectionAbility::Move, CollectionAbility::ReorderPhotos],
                date_order: None,
                explanation: None,
                external_url: None,
            },
        ],
    }
}

#[test]
fn folder_moves_reject_self_descendants_foreign_scope_and_stale_index() {
    let state = fixture();
    for target in [key("root"), key("child"), key("album")] {
        let mut e = edit(CollectionAction::Move);
        e.key = Some(key("root"));
        e.parent = Some(target);
        assert!(validate_collection_edit(&state, &e).is_err());
    }
    let mut e = edit(CollectionAction::Move);
    e.key = Some(key("album"));
    assert!(validate_collection_edit(&state, &e).is_ok());
    e.index = 99;
    assert!(validate_collection_edit(&state, &e).is_err());
    e.index = 0;
    e.parent = Some(AlbumKey {
        scope: "other".into(),
        ..key("root")
    });
    assert!(validate_collection_edit(&state, &e).is_err());
}

#[test]
fn hierarchy_and_photo_reorder_are_exact_permutations_not_membership_edits() {
    let state = fixture();
    let mut e = edit(CollectionAction::ReorderPhotos);
    e.key = Some(key("album"));
    e.photos = vec![photo("b"), photo("a")];
    assert!(validate_collection_edit(&state, &e).is_ok());
    for keys in [
        vec![photo("a")],
        vec![photo("a"), photo("a")],
        vec![photo("a"), photo("other")],
    ] {
        e.photos = keys;
        assert!(validate_collection_edit(&state, &e).is_err());
    }
    let mut e = edit(CollectionAction::ReorderChildren);
    e.parent = Some(key("root"));
    e.collections = vec![key("child")];
    assert!(validate_collection_edit(&state, &e).is_ok());
    e.collections.push(key("child"));
    assert!(validate_collection_edit(&state, &e).is_err());
}

#[test]
fn native_queue_validation_rejects_new_descendant_before_recursive_delete() {
    let expected = fixture();
    let mut e = edit(CollectionAction::DeleteFolder);
    e.key = Some(key("child"));
    assert!(validate_collection_request(&expected, &expected, &e).is_ok());
    assert_eq!(
        collection_subtree(&expected, &key("child")),
        [key("child"), key("album")].into()
    );
    let mut fresh = expected.clone();
    fresh.collections[2].title = "externally changed".into();
    assert!(validate_collection_request(&expected, &fresh, &e).is_err());
    fresh = expected.clone();
    fresh.collections[1].abilities.clear();
    assert!(validate_collection_request(&expected, &fresh, &e).is_err());
    assert_eq!(expected.albums[0].members, vec![photo("a"), photo("b")]);
}

#[test]
fn cycles_missing_parents_and_shared_smart_permissions_fail_closed() {
    let mut state = fixture();
    state.collections[0].parent = Some(key("child"));
    state.collections[1].children.push(key("root"));
    assert!(validate_collections(&state).is_err());
    state = fixture();
    state.collections[1].parent = Some(key("missing"));
    assert!(validate_collections(&state).is_err());
    for kind in [CollectionKind::Shared, CollectionKind::Smart] {
        state = fixture();
        state.collections[2].kind = kind;
        state.collections[2].abilities.clear();
        let mut e = edit(CollectionAction::ReorderPhotos);
        e.key = Some(key("album"));
        e.photos = vec![photo("b"), photo("a")];
        assert!(validate_collection_edit(&state, &e).is_err());
    }
}

#[test]
fn album_projection_uses_provider_member_order_and_deduplicates_unified_photos()
-> Result<(), serde_json::Error> {
    use suwop_core::domain::{StoredAsset, UnifiedPhoto};
    let asset = |id: &str| -> Result<StoredAsset, serde_json::Error> {
        serde_json::from_value(
            serde_json::json!({"key":photo(id),"name":id,"revision":"r","resources":[],"isFavorite":false,"inventoryComplete":false,"isOffline":false,"deletionBlockers":[]}),
        )
    };
    let photos = vec![
        UnifiedPhoto {
            assets: vec![asset("b")?],
            presence: suwop_core::domain::Presence::AppleOnly,
        },
        UnifiedPhoto {
            assets: vec![asset("a")?],
            presence: suwop_core::domain::Presence::AppleOnly,
        },
    ];
    let view = views(&[fixture()], &photos, &[]);
    assert_eq!(
        view[0].photo_ids,
        vec![
            suwop_core::browser::photo_id(&photos[1]),
            suwop_core::browser::photo_id(&photos[0])
        ]
    );
    Ok(())
}

#[test]
fn native_queue_rejects_changed_root_order_even_when_topology_is_identical() {
    let mut expected = fixture();
    let mut extra = expected.collections[0].clone();
    extra.key = key("second-root");
    extra.children.clear();
    expected.collections.push(extra);
    let mut request = edit(CollectionAction::ReorderChildren);
    request.collections = vec![key("second-root"), key("root")];
    assert!(validate_collection_request(&expected, &expected, &request).is_ok());
    let mut fresh = expected.clone();
    fresh.collections.swap(0, 3);
    assert!(validate_collection_request(&expected, &fresh, &request).is_err());
    request = edit(CollectionAction::Move);
    request.key = Some(key("album"));
    request.index = 1;
    assert!(validate_collection_request(&expected, &expected, &request).is_ok());
    assert!(validate_collection_request(&expected, &fresh, &request).is_err());
}
