use serde_json::json;
use suwop_core::{
    browser::{BrowserOptions, PhotoFilter, browse},
    domain::{LibrarySnapshot, Provider, ScanAccess, catalog},
    immich::Asset,
};

#[test]
fn real_immich_live_parent_and_standalone_companion_remain_one_photo()
-> Result<(), Box<dyn std::error::Error>> {
    let mut value = json!({"id":"parent","ownerId":"owner","type":"IMAGE","originalFileName":"live.heic","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","isFavorite":false,"isOffline":false,"isTrashed":false,"livePhotoVideoId":"companion"});
    let parent: Asset = serde_json::from_value(value.clone())?;
    value["id"] = json!("companion");
    value["type"] = json!("VIDEO");
    value["originalFileName"] = json!("live.mov");
    value["checksum"] = json!("2222222222222222222222222222222222222222");
    value["livePhotoVideoId"] = json!(null);
    let companion: Asset = serde_json::from_value(value)?;
    let photos = catalog(
        &[LibrarySnapshot {
            provider: Provider::Immich,
            scope: "library".into(),
            access: ScanAccess::Full,
            scanned_at: None,
            assets: vec![
                parent.record("library", Some(&companion), Some(&[])),
                companion.record("library", None, Some(&[])),
            ],
        }],
        &[],
    );
    assert_eq!(photos.len(), 1);
    for (filter, expected) in [
        (PhotoFilter::Photos, 1),
        (PhotoFilter::Live, 1),
        (PhotoFilter::Videos, 0),
    ] {
        let view = browse(
            &photos,
            &BrowserOptions {
                filter,
                ..BrowserOptions::default()
            },
        );
        assert_eq!(view.photo_ids.len(), expected);
        assert_eq!(view.videos, 0);
        assert_eq!(view.live, 1);
    }
    Ok(())
}
