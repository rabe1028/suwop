use suwop_core::{
    domain::{ResourceRole, StoredAsset},
    media::PlaybackKind,
    sharing::{CurrentImageFacts, CurrentMediaExport, CurrentMediaFile, verify_current_media},
};

fn fixture(live: bool) -> Result<(StoredAsset, CurrentMediaExport), serde_json::Error> {
    let roles = if live {
        serde_json::json!([{"id":"i","name":"still.jpg","role":"image"},{"id":"v","name":"motion.mov","role":"liveVideo"}])
    } else {
        serde_json::json!([{"id":"v","name":"video.mov","role":"video"}])
    };
    let asset: StoredAsset = serde_json::from_value(
        serde_json::json!({"key":{"provider":"apple","scope":"apple","assetID":"selected"},"appleVisibility":"visible","name":"media.mov","revision":"native-revision","resources":roles,"isFavorite":false,"inventoryComplete":true,"isOffline":false,"deletionBlockers":[]}),
    )?;
    let mut files = vec![CurrentMediaFile {
        path: "/work/current.mov".into(),
        role: if live {
            ResourceRole::LiveVideo
        } else {
            ResourceRole::Video
        },
        content_identifier: live.then(|| "pair-id".into()),
        has_location: false,
        has_still_image_time: live,
        duration_ms: 2000,
        video_tracks: 1,
        audio_tracks: 1,
        metadata_tracks: u32::from(live),
        only_pair_metadata: live,
        image: None,
    }];
    if live {
        files.push(CurrentMediaFile {
            path: "/work/current.jpg".into(),
            role: ResourceRole::Image,
            content_identifier: Some("pair-id".into()),
            has_location: false,
            has_still_image_time: false,
            duration_ms: 0,
            video_tracks: 0,
            audio_tracks: 0,
            metadata_tracks: 0,
            only_pair_metadata: false,
            image: Some(CurrentImageFacts {
                content_type: "public.jpeg".into(),
                width: 320,
                height: 240,
                orientation: 1,
                frames: 1,
            }),
        });
    }
    let export = CurrentMediaExport {
        asset: asset.clone(),
        fresh_asset: asset.clone(),
        kind: if live {
            PlaybackKind::Live
        } else {
            PlaybackKind::Video
        },
        files,
        input_duration_ms: 2000,
        input_video_tracks: 1,
        input_audio_tracks: 1,
        location_removed: false,
    };
    Ok((asset, export))
}

#[test]
fn current_movie_preserves_duration_tracks_source_identity_and_scoped_output()
-> Result<(), serde_json::Error> {
    let (asset, export) = fixture(false)?;
    assert!(verify_current_media(&asset, &export, "/work", false).is_ok());
    for fault in 0..5 {
        let mut wrong = export.clone();
        match fault {
            0 => wrong.files[0].duration_ms = 1900,
            1 => wrong.files[0].audio_tracks = 0,
            2 => wrong.fresh_asset.revision = "new".into(),
            3 => wrong.files[0].path = "/work/../leak.mov".into(),
            _ => wrong.fresh_asset.key.asset_id = "counterpart".into(),
        }
        assert!(verify_current_media(&asset, &wrong, "/work", false).is_err());
    }
    Ok(())
}

#[test]
fn current_live_requires_complete_pair_matching_identifier_and_real_still_time()
-> Result<(), serde_json::Error> {
    let (asset, export) = fixture(true)?;
    assert!(verify_current_media(&asset, &export, "/work", false).is_ok());
    for fault in 0..5 {
        let mut wrong = export.clone();
        match fault {
            0 => {
                wrong.files.pop();
            }
            1 => wrong.files[1].content_identifier = Some("other".into()),
            2 => wrong.files[0].has_still_image_time = false,
            3 => wrong.files[1].path = wrong.files[0].path.clone(),
            _ => wrong.files[1].image = None,
        }
        assert!(verify_current_media(&asset, &wrong, "/work", false).is_err());
    }
    Ok(())
}

#[test]
fn gps_removed_movies_reject_static_or_timed_location_metadata() -> Result<(), serde_json::Error> {
    let (asset, mut export) = fixture(false)?;
    export.location_removed = true;
    assert!(verify_current_media(&asset, &export, "/work", true).is_ok());
    export.files[0].has_location = true;
    assert!(verify_current_media(&asset, &export, "/work", true).is_err());
    export.files[0].has_location = false;
    export.files[0].metadata_tracks = 1;
    assert!(verify_current_media(&asset, &export, "/work", true).is_err());
    export.files[0].metadata_tracks = 0;
    assert!(verify_current_media(&asset, &export, "/work", false).is_err());
    Ok(())
}

#[test]
fn gps_free_live_keeps_only_approved_pairing_metadata() -> Result<(), serde_json::Error> {
    let (asset, mut export) = fixture(true)?;
    export.location_removed = true;
    assert!(verify_current_media(&asset, &export, "/work", true).is_ok());
    export.files[0].only_pair_metadata = false;
    assert!(verify_current_media(&asset, &export, "/work", true).is_err());
    export.files[0].only_pair_metadata = true;
    export.files[1].has_location = true;
    assert!(verify_current_media(&asset, &export, "/work", true).is_err());
    Ok(())
}
