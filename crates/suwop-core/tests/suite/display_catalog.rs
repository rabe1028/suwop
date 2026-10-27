use suwop_core::{
    display_catalog,
    domain::*,
    metadata::{self, MetadataAction, MetadataInput},
};

fn asset(provider: Provider, id: &str, name: &str) -> StoredAsset {
    StoredAsset {
        immich_parent_revision: None,
        immich_visibility: None,
        immich_stack: ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: format!("{provider:?}"),
            asset_id: id.into(),
        },
        name: name.into(),
        captured_at: Some(100.125),
        modified_at: None,
        revision: "1".into(),
        resources: vec![PhotoResource {
            id: id.into(),
            name: name.into(),
            role: ResourceRole::Image,
            sha1: None,
            bytes: None,
        }],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn snapshots(assets: &[StoredAsset]) -> Vec<LibrarySnapshot> {
    [Provider::Apple, Provider::Immich]
        .into_iter()
        .map(|provider| LibrarySnapshot {
            provider,
            scope: format!("{provider:?}"),
            access: ScanAccess::Full,
            scanned_at: Some(200.0),
            assets: assets
                .iter()
                .filter(|a| a.key.provider == provider)
                .cloned()
                .collect(),
        })
        .collect()
}
#[test]
fn unverified_pair_is_one_tile_but_not_canonical_identity() {
    let a = asset(Provider::Apple, "apple", "P1075884.JPG");
    let b = asset(Provider::Immich, "immich", "P1075884.JPG");
    let s = snapshots(&[a, b]);
    let display = display_catalog::photos(&s, &[]);
    assert_eq!(display.len(), 1);
    assert_eq!(display[0].presence, Presence::Unverified);
    assert_eq!(catalog(&s, &[]).len(), 2);
}
#[test]
fn ambiguity_different_dates_and_conflicting_originals_do_not_merge() {
    let a = asset(Provider::Apple, "apple", "P1075884.JPG");
    let b = asset(Provider::Immich, "immich", "P1075884.JPG");
    let duplicate = asset(Provider::Apple, "duplicate", "P1075884.JPG");
    assert_eq!(
        display_catalog::photos(&snapshots(&[a.clone(), b.clone(), duplicate]), &[]).len(),
        3
    );
    let mut later = b.clone();
    later.captured_at = Some(100.126);
    assert_eq!(
        display_catalog::photos(&snapshots(&[a.clone(), later]), &[]).len(),
        2
    );
    let mut a = a;
    let mut b = b;
    a.resources[0].sha1 = Some("a".repeat(40));
    b.resources[0].sha1 = Some("b".repeat(40));
    assert_eq!(display_catalog::photos(&snapshots(&[a, b]), &[]).len(), 2);
}
#[test]
fn raw_jpeg_stack_groups_visible_members_and_cross_provider_pair() {
    let mut a = asset(Provider::Apple, "apple", "P1075884.JPG");
    let mut raw = a.resources[0].clone();
    raw.name = "P1075884.RW2".into();
    raw.role = ResourceRole::RawImage;
    a.resources.push(raw);
    let mut b = asset(Provider::Immich, "jpeg", "P1075884.JPG");
    let mut c = asset(Provider::Immich, "raw", "P1075884.RW2");
    c.resources[0].role = ResourceRole::RawImage;
    for member in [&mut b, &mut c] {
        member.immich_stack = ImmichStackState::Stacked;
        member.immich_stack_membership = Some(ImmichStackMembership {
            id: "stack".into(),
            primary_asset_id: "jpeg".into(),
            asset_count: 3,
        });
    }
    let s = snapshots(&[a, b, c]);
    let result = display_catalog::photos(&s, &[]);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].assets.len(), 3); // Never invent the missing/private fourth asset.
    assert_eq!(catalog(&s, &[]).len(), 3);
}
#[test]
fn stacked_photo_metadata_target_is_accepted_by_prepare() -> Result<(), String> {
    let mut jpeg = asset(Provider::Immich, "jpeg", "P1075884.JPG");
    let mut raw = asset(Provider::Immich, "raw", "P1075884.RW2");
    raw.resources[0].role = ResourceRole::RawImage;
    for member in [&mut jpeg, &mut raw] {
        member.immich_stack = ImmichStackState::Stacked;
        member.immich_stack_membership = Some(ImmichStackMembership {
            id: "stack".into(),
            primary_asset_id: "jpeg".into(),
            asset_count: 2,
        });
    }
    let s = snapshots(&[jpeg, raw]);
    let photos = display_catalog::photos(&s, &[]);
    let [photo] = photos.as_slice() else {
        return Err("the stack is not one displayed photo".into());
    };
    let [target] = metadata::targets(photo, &s)
        .try_into()
        .map_err(|_| "one target")?;
    assert_eq!(target.keys.len(), 2);
    let input = MetadataInput {
        action: MetadataAction::SetCapturedAt,
        captured_at: Some(1_730_615_400.0),
        time_zone: Some("Asia/Tokyo".into()),
        latitude: None,
        longitude: None,
    };
    let (prepared, _) = metadata::prepare(&s, &[], &target.keys, &input)?;
    assert_eq!(prepared.keys, target.keys);
    // Half of the displayed stack is never a valid target.
    assert!(metadata::prepare(&s, &[], &target.keys[..1], &input).is_err());
    Ok(())
}
#[test]
fn incomplete_or_contradictory_stack_metadata_does_not_invent_membership() {
    let mut a = asset(Provider::Immich, "a", "A.JPG");
    let mut b = asset(Provider::Immich, "b", "B.JPG");
    a.immich_stack = ImmichStackState::Stacked;
    b.immich_stack = ImmichStackState::Stacked;
    assert_eq!(
        display_catalog::photos(&snapshots(&[a.clone(), b.clone()]), &[]).len(),
        2
    );
    a.immich_stack_membership = Some(ImmichStackMembership {
        id: "stack".into(),
        primary_asset_id: "a".into(),
        asset_count: 2,
    });
    b.immich_stack_membership = Some(ImmichStackMembership {
        id: "stack".into(),
        primary_asset_id: "b".into(),
        asset_count: 2,
    });
    assert_eq!(display_catalog::photos(&snapshots(&[a, b]), &[]).len(), 2);
}
#[test]
fn stack_api_roundtrip_keeps_membership_and_legacy_safety() -> Result<(), serde_json::Error> {
    use suwop_core::immich::stack::StackInventory;
    let value = serde_json::json!({"id":"11111111-1111-4111-8111-111111111111","primaryAssetId":"22222222-2222-4222-8222-222222222222","assetCount":2});
    let stack: StackInventory = serde_json::from_value(value.clone())?;
    assert_eq!(stack.state, ImmichStackState::Stacked);
    assert!(stack.membership.is_some());
    assert_eq!(serde_json::to_value(stack)?, value);
    for value in [serde_json::json!({}), serde_json::json!({"id":"malformed"})] {
        let stack: StackInventory = serde_json::from_value(value)?;
        assert_eq!(stack.state, ImmichStackState::Stacked);
        assert!(stack.membership.is_none());
    }
    Ok(())
}
