use crux_core::{App, Core};
use serde_json::json;
use suwop_core::{
    app::{Event, Model, SavedLibrary, Suwop},
    domain::{
        AppleVisibility, AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider,
        ResourceRole, ScanAccess, StoredAsset, TransferIntent, TransferPhase, TransferReceipt,
    },
    immich::{PendingUpload, Session, UploadIntent, UploadPhase, Version},
    trash::{AppleTrashOperation, AppleTrashOutcome},
    workflow::migrate,
};

fn asset(provider: Provider, visibility: AppleVisibility) -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        apple_visibility: visibility,
        key: AssetKey {
            provider,
            scope: if provider == Provider::Apple {
                "apple"
            } else {
                "remote"
            }
            .into(),
            asset_id: format!("{provider:?}"),
        },
        name: if provider == Provider::Apple {
            "PRIVATE-original.jpg"
        } else {
            "public-copy.jpg"
        }
        .into(),
        captured_at: Some(100.0),
        modified_at: Some(200.0),
        revision: "PRIVATE-raw-revision".into(),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: "PRIVATE-resource.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some("a".repeat(40)),
            bytes: Some(12),
        }],
        is_favorite: true,
        latitude: Some(37.12345),
        longitude: Some(139.12345),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn snapshot(asset: StoredAsset) -> LibrarySnapshot {
    LibrarySnapshot {
        provider: asset.key.provider,
        scope: asset.key.scope.clone(),
        assets: vec![asset],
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    }
}
fn state(visibility: AppleVisibility) -> SavedLibrary {
    let apple = asset(Provider::Apple, visibility);
    let mut remote = asset(Provider::Immich, AppleVisibility::Unknown);
    remote.revision = "remote-revision".into();
    remote.latitude = None;
    remote.longitude = None;
    remote.resources[0].name = "public-copy.jpg".into();
    SavedLibrary {
        schema_version: 8,
        apple_scope: "apple".into(),
        snapshots: vec![snapshot(apple.clone()), snapshot(remote.clone())],
        receipts: vec![TransferReceipt {
            id: "receipt".into(),
            created_at: 1.0,
            intent: TransferIntent::Move,
            phase: TransferPhase::Copied,
            source: vec![apple.clone()],
            destination: vec![remote],
            destination_provider: Provider::Immich,
            destination_scope: "remote".into(),
            signatures: std::collections::BTreeSet::new(),
        }],
        pending_apple_trash: vec![AppleTrashOperation {
            id: "33333333-3333-4333-8333-333333333333".into(),
            scope: "apple".into(),
            assets: vec![apple],
            outcome: AppleTrashOutcome::Unknown,
            visibility: None,
        }],
        ..SavedLibrary::default()
    }
}
fn model(state: SavedLibrary) -> Model {
    Model {
        ready: true,
        state,
        status: "Processed PRIVATE-original.jpg at 37.12345".into(),
        error: Some("PRIVATE-resource.jpg PRIVATE-raw-revision".into()),
        ..Model::default()
    }
}

const PRIVATE_BYTES: u64 = 987_654_321;
const PRIVATE_SIGNATURE_BYTES: u64 = 876_543_210;
const PRIVATE_BLOCKERS: [&str; 4] = [
    "バーストの非公開写真です。",
    "Live Photo の非公開原本です。",
    "共有ライブラリの非公開写真です。",
    "補助リソースを含む非公開写真です。",
];

fn fingerprint_state(visibility: AppleVisibility, unavailable: bool) -> SavedLibrary {
    let mut canonical = state(visibility);
    let mut private = canonical.snapshots[0].assets[0].clone();
    private.resources[0].id = "PRIVATE-live-inventory-id".into();
    private.resources[0].role = ResourceRole::LiveVideo;
    private.resources[0].sha1 = Some("b".repeat(40));
    private.resources[0].bytes = Some(PRIVATE_BYTES);
    private.deletion_blockers = PRIVATE_BLOCKERS.into_iter().map(str::to_owned).collect();
    let mut public = canonical.snapshots[1].assets[0].clone();
    public.resources[0].sha1 = Some("e".repeat(40));
    public.resources[0].bytes = Some(123_321);
    canonical.snapshots = vec![snapshot(private.clone()), snapshot(public.clone())];
    if unavailable {
        canonical.snapshots[0].access = ScanAccess::Unavailable;
    }
    canonical.pending_apple_trash[0].assets = vec![private.clone()];
    let private_signature = FileSignature {
        sha256: "d".repeat(64),
        bytes: PRIVATE_SIGNATURE_BYTES,
    };
    let receipt = &mut canonical.receipts[0];
    receipt.source = vec![private.clone()];
    receipt.destination = vec![public.clone()];
    receipt.signatures = [private_signature].into();
    let mut destination_private = receipt.clone();
    destination_private.id = "private-destination".into();
    destination_private.source = vec![public.clone()];
    destination_private.destination = vec![private.clone()];
    destination_private.destination_provider = Provider::Apple;
    destination_private.destination_scope = "apple".into();
    let mut independent = receipt.clone();
    independent.id = "independent-public-receipt".into();
    independent.source = vec![public.clone()];
    independent.destination = vec![public.clone()];
    independent.signatures = [FileSignature {
        sha256: "f".repeat(64),
        bytes: 765_432_111,
    }]
    .into();
    canonical
        .receipts
        .extend([destination_private, independent]);
    add_fingerprint_uploads(&mut canonical, &[private, public]);
    canonical
}

fn add_fingerprint_uploads(canonical: &mut SavedLibrary, sources: &[StoredAsset]) {
    for source in sources {
        let private = source.key.provider == Provider::Apple;
        let signature = FileSignature {
            sha256: if private { "d" } else { "f" }.repeat(64),
            bytes: if private {
                PRIVATE_SIGNATURE_BYTES
            } else {
                765_432_111
            },
        };
        canonical.pending_uploads.push(PendingUpload {
            key: canonical.snapshots[1].assets[0].key.clone(),
            source: source.clone(),
            resource: source.resources[0].clone(),
            signature: signature.clone(),
            live_id: Some("record-routing-id".into()),
            phase: UploadPhase::MetadataStarted,
        });
        canonical.upload_intents.push(UploadIntent {
            scope: "remote".into(),
            token: format!("intent-{}", source.key.asset_id),
            source: source.clone(),
            resource: source.resources[0].clone(),
            signature,
            live_id: Some("record-routing-id".into()),
        });
    }
}

#[test]
fn private_upload_and_receipt_fingerprints_and_move_facts_do_not_escape_the_whole_view()
-> Result<(), Box<dyn std::error::Error>> {
    for (visibility, unavailable) in [
        (AppleVisibility::Hidden, false),
        (AppleVisibility::Unknown, false),
        (AppleVisibility::Visible, true),
    ] {
        let canonical = fingerprint_state(visibility, unavailable);
        let saved = serde_json::to_value(&canonical)?;
        let model = model(canonical.clone());
        let view = Suwop.view(&model);
        let published = serde_json::to_string(&view)?;
        for secret in [
            "b".repeat(40),
            "d".repeat(64),
            PRIVATE_BYTES.to_string(),
            PRIVATE_SIGNATURE_BYTES.to_string(),
            "PRIVATE-live-inventory-id".into(),
            "liveVideo".into(),
        ]
        .into_iter()
        .chain(PRIVATE_BLOCKERS.into_iter().map(str::to_owned))
        {
            assert!(!published.contains(&secret), "leaked {secret}: {published}");
        }
        assert_eq!(serde_json::to_value(&model.state)?, saved);
        assert!(!canonical.receipts[0].move_blockers().is_empty());
        for receipt in &view.state.receipts[..2] {
            assert!(receipt.signatures.is_empty());
            assert_eq!(receipt.phase, TransferPhase::Copied);
            assert_eq!(
                view.move_blockers[&receipt.id],
                vec!["写真の可視性を確認して一覧を更新してください。"]
            );
        }
        assert!(view.state.pending_uploads[0].resource.sha1.is_none());
        assert!(view.state.pending_uploads[0].resource.bytes.is_none());
        assert_eq!(
            view.state.pending_uploads[0].resource.role,
            ResourceRole::Image
        );
        assert!(view.state.pending_uploads[0].signature.sha256.is_empty());
        assert_eq!(view.state.pending_uploads[0].signature.bytes, 0);
        assert_eq!(
            view.state.pending_uploads[0].key,
            canonical.pending_uploads[0].key
        );
        assert_eq!(
            view.state.pending_uploads[0].phase,
            UploadPhase::MetadataStarted
        );
        assert_eq!(
            view.state.upload_intents[0].token,
            canonical.upload_intents[0].token
        );
        assert_eq!(
            view.state.upload_intents[0].live_id,
            canonical.upload_intents[0].live_id
        );
        for (published, original) in [
            (
                serde_json::to_value(&view.state.snapshots[1])?,
                serde_json::to_value(&canonical.snapshots[1])?,
            ),
            (
                serde_json::to_value(&view.state.receipts[2])?,
                serde_json::to_value(&canonical.receipts[2])?,
            ),
            (
                serde_json::to_value(&view.state.pending_uploads[1])?,
                serde_json::to_value(&canonical.pending_uploads[1])?,
            ),
            (
                serde_json::to_value(&view.state.upload_intents[1])?,
                serde_json::to_value(&canonical.upload_intents[1])?,
            ),
        ] {
            assert_eq!(published, original);
        }
    }
    Ok(())
}

#[test]
fn visible_immich_same_hash_evidence_is_preserved_independently_of_private_apple() {
    let canonical = state(AppleVisibility::Hidden);
    let public = canonical.snapshots[1].assets[0].clone();
    assert_eq!(
        canonical.snapshots[0].assets[0].resources[0].sha1,
        public.resources[0].sha1
    );
    let view = Suwop.view(&model(canonical));
    assert_eq!(view.photos.len(), 1);
    assert_eq!(view.photos[0].assets, vec![public.clone()]);
    assert_eq!(view.state.receipts[0].destination, vec![public]);
    assert!(view.state.receipts[0].source[0].resources.is_empty());
}
#[test]
fn private_projection_retains_counterpart_and_pending_recovery_without_mutating_canonical()
-> Result<(), Box<dyn std::error::Error>> {
    for visibility in [AppleVisibility::Unknown, AppleVisibility::Hidden] {
        let canonical = state(visibility);
        let saved = serde_json::to_value(&canonical)?;
        let model = model(canonical);
        let view = Suwop.view(&model);
        let public = serde_json::to_string(&view)?;
        for secret in [
            "PRIVATE-original.jpg",
            "PRIVATE-resource.jpg",
            "PRIVATE-raw-revision",
            "37.12345",
            "139.12345",
        ] {
            assert!(!public.contains(secret), "leaked {secret}: {public}");
        }
        assert_eq!(view.photos.len(), 1);
        assert_eq!(view.photos[0].assets[0].key.provider, Provider::Immich);
        assert!(public.contains("public-copy.jpg"));
        assert_eq!(view.state.pending_apple_trash.len(), 1);
        assert_eq!(
            view.state.pending_apple_trash[0].outcome,
            AppleTrashOutcome::Unknown
        );
        assert_eq!(view.state.receipts.len(), 1);
        assert_eq!(view.pending_apple_count, 0);
        assert_eq!(serde_json::to_value(&model.state)?, saved);
    }
    Ok(())
}
#[test]
fn journal_only_sources_are_redacted_from_state_and_stale_text()
-> Result<(), Box<dyn std::error::Error>> {
    let mut canonical = state(AppleVisibility::Visible);
    let apple = canonical.snapshots.remove(0).assets.remove(0);
    canonical.receipts.clear();
    canonical.pending_apple_trash.clear();
    let signature = suwop_core::domain::FileSignature {
        sha256: "1".repeat(64),
        bytes: 12,
    };
    canonical.pending_uploads.push(PendingUpload {
        key: asset(Provider::Immich, AppleVisibility::Unknown).key,
        source: apple.clone(),
        resource: apple.resources[0].clone(),
        signature: signature.clone(),
        live_id: None,
        phase: UploadPhase::MetadataPending,
    });
    canonical.upload_intents.push(UploadIntent {
        scope: "remote".into(),
        token: "intent".into(),
        source: apple,
        resource: asset(Provider::Apple, AppleVisibility::Visible)
            .resources
            .remove(0),
        signature,
        live_id: None,
    });
    let view = Suwop.view(&model(canonical));
    let public = serde_json::to_string(&view)?;
    assert!(!public.contains("PRIVATE-"));
    assert_eq!(view.state.pending_uploads.len(), 1);
    assert_eq!(view.state.upload_intents.len(), 1);
    Ok(())
}
#[test]
fn schema_migration_keeps_evidence_and_marks_missing_visibility_unknown()
-> Result<(), Box<dyn std::error::Error>> {
    let canonical = state(AppleVisibility::Visible);
    for version in [1, 2] {
        let mut old = serde_json::to_value(&canonical)?;
        old["schemaVersion"] = json!(version);
        old["snapshots"][0]["assets"][0]
            .as_object_mut()
            .ok_or("asset")?
            .remove("appleVisibility");
        old["receipts"][0]["source"][0]
            .as_object_mut()
            .ok_or("receipt")?
            .remove("appleVisibility");
        let migrated = migrate(old)?;
        assert_eq!(migrated.schema_version, 8);
        assert_eq!(
            migrated.snapshots[0].assets[0].apple_visibility,
            AppleVisibility::Unknown
        );
        assert_eq!(
            migrated.receipts[0].source[0].revision,
            "PRIVATE-raw-revision"
        );
        assert_eq!(
            migrated.receipts[0].intent,
            if version == 1 {
                TransferIntent::Copy
            } else {
                TransferIntent::Move
            }
        );
        assert_eq!(
            migrated.snapshots[0].assets[0].captured_at,
            Some(if version == 1 { 978_307_300.0 } else { 100.0 })
        );
    }
    let roundtrip = migrate(serde_json::to_value(&canonical)?)?;
    assert_eq!(
        serde_json::to_value(roundtrip)?,
        serde_json::to_value(canonical)?
    );
    assert!(migrate(json!({"schemaVersion":99})).is_err());
    Ok(())
}
#[test]
fn old_upload_intent_evidence_matches_fresh_visible_source_but_not_modified_original()
-> Result<(), Box<dyn std::error::Error>> {
    let fresh = asset(Provider::Apple, AppleVisibility::Visible);
    let mut old = fresh.clone();
    old.apple_visibility = AppleVisibility::Unknown;
    let intent = UploadIntent {
        scope: "remote".into(),
        token: "intent".into(),
        source: old,
        resource: fresh.resources[0].clone(),
        signature: suwop_core::domain::FileSignature {
            sha256: "1".repeat(64),
            bytes: 12,
        },
        live_id: None,
    };
    let mut raw = serde_json::to_value(state(AppleVisibility::Visible))?;
    raw["schemaVersion"] = json!(2);
    raw["uploadIntents"] = json!([intent]);
    raw["uploadIntents"][0]["source"]
        .as_object_mut()
        .ok_or("source")?
        .remove("appleVisibility");
    let migrated = migrate(raw)?;
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "fixture".into(),
        scope: "remote".into(),
        user_id: "owner".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let file = suwop_core::domain::TransferFile {
        resource: fresh.resources[0].clone(),
        path: "/private/original".into(),
        signature: migrated.upload_intents[0].signature.clone(),
    };
    assert!(migrated.upload_intents[0].matches(&session, &file, &fresh, None));
    let mut modified = fresh;
    modified.revision.push_str("changed");
    assert!(!migrated.upload_intents[0].matches(&session, &file, &modified, None));
    Ok(())
}
#[test]
fn stale_apple_anchor_cannot_fall_back_to_visible_immich_for_reads() {
    for unavailable in [false, true] {
        let mut saved = state(if unavailable {
            AppleVisibility::Visible
        } else {
            AppleVisibility::Hidden
        });
        saved.pending_apple_trash.clear();
        if unavailable {
            saved.snapshots[0].access = ScanAccess::Unavailable;
        }
        let key = saved.snapshots[0].assets[0].key.clone();
        for event in [
            Event::Play {
                keys: vec![key.clone()],
                id: "play".into(),
            },
            Event::Share {
                keys: vec![key],
                id: "share".into(),
            },
        ] {
            let core = Core::new_with(Suwop, model(saved.clone()));
            assert!(core.process_event(event).is_empty());
            assert!(!core.view().busy);
            assert!(core.view().error.is_some());
        }
    }
}

#[test]
fn local_journal_disposition_confirmation_does_not_reveal_a_private_apple_source()
-> Result<(), Box<dyn std::error::Error>> {
    let mut canonical = state(AppleVisibility::Hidden);
    let source = canonical.snapshots[0].assets[0].clone();
    let signature = suwop_core::domain::FileSignature {
        sha256: "1".repeat(64),
        bytes: 12,
    };
    let remote = canonical.snapshots[1].assets[0].key.clone();
    canonical.pending_uploads.push(PendingUpload {
        key: remote.clone(),
        source: source.clone(),
        resource: source.resources[0].clone(),
        signature: signature.clone(),
        live_id: None,
        phase: UploadPhase::MetadataPending,
    });
    canonical.upload_intents.push(UploadIntent {
        scope: "remote".into(),
        token: "intent".into(),
        source: source.clone(),
        resource: source.resources[0].clone(),
        signature,
        live_id: None,
    });
    for event in [
        Event::ForgetUploadRecord { key: remote },
        Event::ForgetUploadIntent {
            scope: "remote".into(),
            token: "intent".into(),
        },
    ] {
        let core = Core::new_with(Suwop, model(canonical.clone()));
        let mut effects = core.process_event(event);
        assert_eq!(effects.len(), 1);
        let suwop_core::app::Effect::Io(request) = effects.remove(0);
        let name = match request.operation {
            suwop_core::app::ShellOperation::ConfirmForgetUpload { prompt } => prompt.name,
            suwop_core::app::ShellOperation::ConfirmForgetUploadIntent { prompt } => prompt.name,
            _ => return Err("expected local disposition confirmation".into()),
        };
        assert_eq!(name, "非公開の写真");
        assert_eq!(canonical.pending_uploads[0].source, source);
    }
    Ok(())
}

#[test]
fn visibility_journal_fence_redacts_nested_state_and_stale_error_without_hiding_counterpart()
-> Result<(), Box<dyn std::error::Error>> {
    use suwop_core::apple_visibility::{
        AppleVisibilityOperation, VisibilityAction, VisibilityOutcome, VisibilityTarget,
    };
    let mut canonical = state(AppleVisibility::Visible);
    canonical
        .apple_visibility_operations
        .push(AppleVisibilityOperation {
            id: "44444444-4444-4444-8444-444444444444".into(),
            scope: "apple".into(),
            action: VisibilityAction::Hide,
            outcome: VisibilityOutcome::Unknown,
            targets: vec![VisibilityTarget {
                key: canonical.snapshots[0].assets[0].key.clone(),
                witness_digest: "a".repeat(64),
                observation: None,
            }],
        });
    let before = serde_json::to_value(&canonical)?;
    let model = model(canonical);
    let view = Suwop.view(&model);
    let public = serde_json::to_string(&view)?;
    for secret in [
        "PRIVATE-original.jpg",
        "PRIVATE-resource.jpg",
        "PRIVATE-raw-revision",
        "37.12345",
        "139.12345",
        &"a".repeat(64),
    ] {
        assert!(!public.contains(secret), "leaked {secret}");
    }
    assert_eq!(view.photos.len(), 1);
    assert_eq!(view.photos[0].assets[0].key.provider, Provider::Immich);
    assert_eq!(serde_json::to_value(&model.state)?, before);
    Ok(())
}
