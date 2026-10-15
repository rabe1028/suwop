use std::collections::BTreeSet;
use suwop_core::domain::*;

fn asset(provider: Provider, id: &str, hashes: &[&str]) -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: format!("{provider:?}"),
            asset_id: id.into(),
        },
        name: "image.jpg".into(),
        captured_at: Some(10.0),
        modified_at: None,
        revision: "1".into(),
        resources: hashes
            .iter()
            .enumerate()
            .map(|(i, h)| PhotoResource {
                id: i.to_string(),
                name: "image.jpg".into(),
                role: ResourceRole::Image,
                sha1: Some((*h).into()),
                bytes: Some(12),
            })
            .collect(),
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
const JPEG: &str = "1111111111111111111111111111111111111111";
const RAW: &str = "2222222222222222222222222222222222222222";
fn snapshot(provider: Provider, assets: Vec<StoredAsset>) -> LibrarySnapshot {
    LibrarySnapshot {
        provider,
        scope: format!("{provider:?}"),
        assets,
        access: ScanAccess::Full,
        scanned_at: Some(10.0),
    }
}
fn bundle(assets: Vec<StoredAsset>) -> TransferBundle {
    let files = assets
        .iter()
        .flat_map(|a| &a.resources)
        .map(|r| TransferFile {
            resource: r.clone(),
            path: "/tmp/test".into(),
            signature: FileSignature {
                sha256: r.sha1.clone().unwrap_or_default() + "111111111111111111111111",
                bytes: 12,
            },
        })
        .collect();
    TransferBundle { assets, files }
}
fn receipt(
    intent: TransferIntent,
    source: &TransferBundle,
    target: &TransferBundle,
) -> TransferReceipt {
    TransferReceipt {
        id: "test".into(),
        created_at: 10.0,
        phase: TransferPhase::Copied,
        intent,
        source: source.assets.clone(),
        destination: target.assets.clone(),
        destination_provider: Provider::Immich,
        destination_scope: "Immich".into(),
        signatures: source.signatures(),
    }
}

#[test]
fn sha1_normalizes_hex_and_base64() {
    assert_eq!(
        normalize_sha1(Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")),
        Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into())
    );
    assert_eq!(
        normalize_sha1(Some("AAAAAAAAAAAAAAAAAAAAAAAAAAA=")),
        Some("0000000000000000000000000000000000000000".into())
    );
    for value in [None, Some(""), Some("file.jpg"), Some("***")] {
        assert!(normalize_sha1(value).is_none());
    }
}
#[test]
fn identical_originals_are_grouped_across_providers() {
    let photos = catalog(
        &[
            snapshot(Provider::Apple, vec![asset(Provider::Apple, "a", &[JPEG])]),
            snapshot(
                Provider::Immich,
                vec![asset(Provider::Immich, "b", &[JPEG])],
            ),
        ],
        &[],
    );
    assert_eq!(photos.len(), 1);
    assert_eq!(photos[0].presence, Presence::Both);
}
#[test]
fn filenames_never_prove_identity() {
    let photos = catalog(
        &[
            snapshot(Provider::Apple, vec![asset(Provider::Apple, "a", &[JPEG])]),
            snapshot(Provider::Immich, vec![asset(Provider::Immich, "b", &[RAW])]),
        ],
        &[],
    );
    assert_eq!(photos.len(), 2);
}
#[test]
fn raw_jpeg_and_duplicate_multiplicity_are_partial() {
    for hashes in [vec![JPEG, RAW], vec![JPEG, JPEG]] {
        let photos = catalog(
            &[
                snapshot(Provider::Apple, vec![asset(Provider::Apple, "a", &hashes)]),
                snapshot(
                    Provider::Immich,
                    vec![asset(Provider::Immich, "b", &[JPEG])],
                ),
            ],
            &[],
        );
        assert_eq!(photos[0].presence, Presence::Partial);
    }
}
#[test]
fn absent_unhashed_limited_disconnected_and_offline_are_unverified() {
    let mut apple = snapshot(Provider::Apple, vec![asset(Provider::Apple, "a", &[JPEG])]);
    let mut immich = snapshot(Provider::Immich, vec![]);
    for access in [ScanAccess::Limited, ScanAccess::Unavailable] {
        immich.access = access;
        assert_eq!(
            catalog(&[apple.clone(), immich.clone()], &[])[0].presence,
            Presence::Unverified
        );
    }
    immich.access = ScanAccess::Full;
    assert_eq!(
        catalog(&[apple.clone(), immich.clone()], &[])[0].presence,
        Presence::AppleOnly
    );
    apple.assets[0].resources[0].sha1 = None;
    assert_eq!(
        catalog(&[apple.clone(), immich.clone()], &[])[0].presence,
        Presence::Unverified
    );
    apple.assets[0].is_offline = true;
    assert_eq!(
        catalog(&[apple, immich], &[])[0].presence,
        Presence::Unverified
    );
}
#[test]
fn foreign_scopes_and_duplicate_page_records_are_ignored() {
    let a = asset(Provider::Apple, "a", &[JPEG]);
    let mut foreign = a.clone();
    foreign.key.scope = "other".into();
    assert_eq!(
        catalog(
            &[snapshot(Provider::Apple, vec![a.clone(), a, foreign])],
            &[]
        )
        .len(),
        1
    );
}
#[test]
fn offline_existing_copy_cannot_count_as_both() {
    let mut b = asset(Provider::Immich, "b", &[JPEG]);
    b.is_offline = true;
    assert_eq!(
        catalog(
            &[
                snapshot(Provider::Apple, vec![asset(Provider::Apple, "a", &[JPEG])]),
                snapshot(Provider::Immich, vec![b])
            ],
            &[]
        )[0]
        .presence,
        Presence::Unverified
    );
}
#[test]
fn copy_receipts_can_never_authorize_deletion() {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    let receipt = receipt(TransferIntent::Copy, &source, &target);
    assert!(!receipt.move_blockers().is_empty());
    assert!(verify_source(&receipt, &mut source.clone()).is_err());
}
#[test]
fn legacy_receipts_default_to_copy() -> Result<(), Box<dyn std::error::Error>> {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    let mut raw = serde_json::to_value(receipt(TransferIntent::Move, &source, &target))?;
    if let Some(object) = raw.as_object_mut() {
        object.remove("intent");
    }
    let decoded: TransferReceipt = serde_json::from_value(raw)?;
    assert_eq!(decoded.intent, TransferIntent::Copy);
    Ok(())
}
#[test]
fn complete_raw_jpeg_move_requires_fresh_originals() -> Result<(), String> {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG, RAW])]);
    let target = bundle(vec![asset(Provider::Immich, "b", &[JPEG, RAW])]);
    let receipt = receipt(TransferIntent::Move, &source, &target);
    verify_source(&receipt, &mut source.clone())?;
    verify_destination(&receipt, &target)?;
    let mut missing = target.clone();
    missing.files.pop();
    assert!(verify_destination(&receipt, &missing).is_err());
    let mut changed = target;
    changed.files[0].signature.sha256 = "a".repeat(64);
    assert!(verify_destination(&receipt, &changed).is_err());
    Ok(())
}
#[test]
fn source_revision_new_blockers_and_location_changes_block_deletion() {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    let receipt = receipt(TransferIntent::Move, &source, &target);
    let mut fresh = source.clone();
    fresh.assets[0].revision = "2".into();
    assert!(verify_source(&receipt, &mut fresh).is_err());
    let mut fresh = source.clone();
    fresh.assets[0].deletion_blockers.push("sidecar".into());
    assert!(verify_source(&receipt, &mut fresh).is_err());
    let mut fresh = source;
    fresh.assets[0].latitude = Some(35.0);
    assert!(verify_source(&receipt, &mut fresh).is_err());
}
#[test]
fn independent_byte_identical_assets_cannot_be_moved_even_with_legacy_receipt() {
    let mut source = bundle(vec![
        asset(Provider::Apple, "a", &[JPEG]),
        asset(Provider::Apple, "b", &[JPEG]),
    ]);
    let target = bundle(vec![asset(Provider::Immich, "c", &[JPEG])]);
    let receipt = receipt(TransferIntent::Move, &source, &target);
    assert!(verify_source(&receipt, &mut source).is_err());
    assert!(
        source
            .assets
            .iter()
            .all(|a| !a.deletion_blockers.is_empty())
    );
    source.files.pop();
    assert!(source.validate().is_err());
}
#[test]
fn destination_location_is_verified_before_move() {
    let mut source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let mut target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    source.assets[0].latitude = Some(35.0);
    source.assets[0].longitude = Some(139.0);
    let receipt = receipt(TransferIntent::Move, &source, &target);
    assert!(verify_destination(&receipt, &target).is_err());
    target.assets[0].latitude = Some(35.0);
    target.assets[0].longitude = Some(139.0);
    assert!(verify_destination(&receipt, &target).is_ok());
}

#[test]
fn move_preserves_capture_date_and_favorite() {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let mut target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    let saved = receipt(TransferIntent::Move, &source, &target);
    assert!(verify_destination(&saved, &target).is_ok());
    target.assets[0].is_favorite = true;
    assert!(verify_destination(&saved, &target).is_err());
    target.assets[0].is_favorite = false;
    target.assets[0].captured_at = Some(20.0);
    assert!(verify_destination(&saved, &target).is_err());
    let mut fresh = source;
    fresh.assets[0].captured_at = Some(20.0);
    assert!(verify_source(&saved, &mut fresh).is_err());
}
#[test]
fn missing_capture_date_cannot_be_invented_or_removed_during_move() {
    let mut source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let mut target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    source.assets[0].captured_at = None;
    let saved = receipt(TransferIntent::Move, &source, &target);
    assert!(verify_destination(&saved, &target).is_err());
    target.assets[0].captured_at = None;
    assert!(verify_destination(&saved, &target).is_ok());
    source.assets[0].captured_at = Some(10.0);
    let saved = receipt(TransferIntent::Move, &source, &target);
    assert!(verify_destination(&saved, &target).is_err());
}
#[test]
fn terminal_or_uncertain_receipts_never_retry_deletion() {
    let source = bundle(vec![asset(Provider::Apple, "a", &[JPEG])]);
    let target = bundle(vec![asset(Provider::Immich, "b", &[JPEG])]);
    for phase in [
        TransferPhase::Copying,
        TransferPhase::DeletingSource,
        TransferPhase::DeletionUncertain,
        TransferPhase::Moved,
    ] {
        let mut r = receipt(TransferIntent::Move, &source, &target);
        r.phase = phase;
        assert!(verify_source(&r, &mut source.clone()).is_err());
    }
}
#[test]
fn apple_facts_and_import_plan_are_domain_decisions() -> Result<(), String> {
    let a = asset(Provider::Apple, "a", &[JPEG]);
    let described = describe_apple(AppleFacts {
        asset: a.clone(),
        full_access: false,
        can_delete: true,
        burst: true,
        shared: false,
        live: false,
    });
    assert_eq!(described.deletion_blockers.len(), 2);
    let mut source = bundle(vec![a]);
    source.assets[0].resources.push(PhotoResource {
        id: "raw".into(),
        name: "raw.dng".into(),
        role: ResourceRole::RawImage,
        sha1: Some(RAW.into()),
        bytes: Some(12),
    });
    source = bundle(source.assets);
    let plan = apple_import_plan(&source)?;
    assert_eq!(
        plan.entries
            .iter()
            .map(|e| e.kind.as_str())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["photo", "alternatePhoto"])
    );
    Ok(())
}
