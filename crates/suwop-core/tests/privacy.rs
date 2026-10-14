use crux_core::{App, Core};
use serde_json::json;
use suwop_core::{
    app::{Event, Model, SavedLibrary, Suwop},
    domain::{
        AppleVisibility, AssetKey, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferIntent, TransferPhase, TransferReceipt,
    },
    immich::{PendingUpload, Session, UploadIntent, UploadPhase, Version},
    trash::{AppleTrashOperation, AppleTrashOutcome},
    workflow::migrate,
};

fn asset(provider: Provider, visibility: AppleVisibility) -> StoredAsset {
    StoredAsset {
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
        schema_version: 3,
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
        assert_eq!(migrated.schema_version, 3);
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
