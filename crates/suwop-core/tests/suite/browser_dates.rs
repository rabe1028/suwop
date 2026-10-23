use suwop_core::{
    browser::{BrowserOptions, browse, photo_id},
    domain::{AssetKey, Presence, Provider, StoredAsset, UnifiedPhoto},
};

#[test]
fn date_search_uses_the_display_time_zone_including_historical_daylight_saving() {
    let photo = |date| UnifiedPhoto {
        presence: Presence::AppleOnly,
        assets: vec![StoredAsset {
            immich_visibility: None,
            immich_stack: suwop_core::domain::ImmichStackState::Unknown,
            immich_stack_membership: None,
            apple_visibility: suwop_core::domain::AppleVisibility::Visible,
            key: AssetKey {
                provider: Provider::Apple,
                scope: "library".into(),
                asset_id: "boundary".into(),
            },
            name: "boundary.JPG".into(),
            captured_at: Some(date),
            modified_at: None,
            revision: "1".into(),
            resources: vec![],
            is_favorite: false,
            latitude: None,
            longitude: None,
            inventory_complete: true,
            is_offline: false,
            deletion_blockers: vec![],
        }],
    };
    for (timestamp, zone, query) in [
        (1_704_072_600.0, "America/New_York", "2023-12-31"),
        (1_704_072_600.0, "Asia/Tokyo", "2024-01-01"),
        (1_719_808_200.0, "America/New_York", "2024-07-01"),
    ] {
        let item = photo(timestamp);
        let id = photo_id(&item);
        let view = browse(
            &[item],
            &BrowserOptions {
                query: query.into(),
                time_zone: Some(zone.into()),
                ..BrowserOptions::default()
            },
        );
        assert_eq!(view.photo_ids, vec![id]);
    }
}
