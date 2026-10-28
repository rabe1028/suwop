use suwop_core::{
    domain::{
        AppleVisibility, AssetKey, FileSignature, ImmichStackState, PhotoResource, Provider,
        ResourceRole, StoredAsset, TransferBundle, TransferFile, TransferIntent, TransferPhase,
        TransferReceipt,
    },
    transfer_lifecycle::{
        DeletionAttempt, DeletionAuthority, LifecycleEffect, LifecycleEvent, recover, reduce,
        start, verify_copy, verify_destination_evidence, verify_source_evidence,
    },
};

const SHA1: &str = "1111111111111111111111111111111111111111";

fn signature() -> FileSignature {
    FileSignature {
        sha256: "a".repeat(64),
        bytes: 3,
    }
}

fn asset(provider: Provider, scope: &str, id: &str) -> StoredAsset {
    StoredAsset {
        immich_parent_revision: None,
        immich_visibility: None,
        immich_stack: ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: scope.into(),
            asset_id: id.into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.0),
        modified_at: None,
        revision: "revision".into(),
        resources: vec![PhotoResource {
            id: id.into(),
            name: "photo.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(SHA1.into()),
            bytes: Some(3),
        }],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

fn bundle(assets: Vec<StoredAsset>) -> TransferBundle {
    let files = assets
        .iter()
        .map(|a| TransferFile {
            resource: a.resources[0].clone(),
            path: format!("/work/{}", a.key.asset_id),
            signature: signature(),
        })
        .collect();
    TransferBundle { assets, files }
}

fn source() -> StoredAsset {
    asset(Provider::Apple, "apple", "source")
}

fn copy_target() -> StoredAsset {
    asset(Provider::Immich, "remote", "copy")
}

fn copying(id: &str, intent: TransferIntent) -> TransferReceipt {
    TransferReceipt {
        id: id.into(),
        created_at: 1.0,
        phase: TransferPhase::Copying,
        intent,
        source: vec![source()],
        destination: vec![],
        destination_provider: Provider::Immich,
        destination_scope: "remote".into(),
        signatures: [signature()].into(),
    }
}

/// Run the copy half through the public reducer and shared verification.
fn copied(id: &str, intent: TransferIntent) -> Result<TransferReceipt, String> {
    let step = start(copying(id, intent))?;
    assert_eq!(step.effect, LifecycleEffect::PersistThenImport);
    let created = [copy_target().key];
    let verified = verify_copy(&step.receipt, &created, &bundle(vec![copy_target()]))?;
    let step = reduce(&step.receipt, LifecycleEvent::CopyVerified(verified))?;
    assert_eq!(step.effect, LifecycleEffect::Persist);
    assert_eq!(step.receipt.phase, TransferPhase::Copied);
    Ok(step.receipt)
}

fn authority(receipt: &TransferReceipt) -> Result<DeletionAuthority, String> {
    let mut fresh_source = bundle(vec![source()]);
    let source = verify_source_evidence(receipt, &mut fresh_source)?;
    let destination = verify_destination_evidence(receipt, &bundle(vec![copy_target()]))?;
    DeletionAuthority::new(receipt, source, destination)
}

/// The saved `DeletingSource` receipt and its one live attempt.
fn deleting(id: &str) -> Result<(TransferReceipt, DeletionAttempt), String> {
    let receipt = copied(id, TransferIntent::Move)?;
    let step = reduce(
        &receipt,
        LifecycleEvent::AuthorizeDeletion(authority(&receipt)?),
    )?;
    match step.effect {
        LifecycleEffect::PersistThenDelete(attempt) => Ok((step.receipt, attempt)),
        _ => Err("no deletion attempt".into()),
    }
}

#[test]
fn an_explicit_move_deletes_only_through_its_live_attempt() -> Result<(), String> {
    let (receipt, attempt) = deleting("move")?;
    assert_eq!(receipt.phase, TransferPhase::DeletingSource);
    assert_eq!(attempt.receipt(), &receipt);
    assert_eq!(attempt.sources(), [source()].as_slice());
    // The deletion depends on the source and on the verified destination.
    assert_eq!(attempt.dependencies(), [source().key, copy_target().key]);
    let moved = reduce(
        &receipt,
        LifecycleEvent::DeletionSucceeded(attempt.submit()),
    )?;
    assert_eq!(moved.receipt.phase, TransferPhase::Moved);

    let (receipt, attempt) = deleting("unknown")?;
    let uncertain = reduce(&receipt, LifecycleEvent::DeletionUnknown(attempt.submit()))?;
    assert_eq!(uncertain.receipt.phase, TransferPhase::DeletionUncertain);

    let (receipt, attempt) = deleting("unsent")?;
    let unsent = reduce(&receipt, LifecycleEvent::DeletionNotSubmitted(attempt))?;
    assert_eq!(unsent.receipt.phase, TransferPhase::Copied);
    Ok(())
}

#[test]
fn an_attempt_settles_only_its_own_receipt() -> Result<(), String> {
    let (first, _) = deleting("first")?;
    let (_, second) = deleting("second")?;
    assert!(reduce(&first, LifecycleEvent::DeletionNotSubmitted(second)).is_err());
    let (_, third) = deleting("third")?;
    assert!(reduce(&first, LifecycleEvent::DeletionSucceeded(third.submit())).is_err());
    Ok(())
}

#[test]
fn a_recovered_deleting_receipt_becomes_uncertain_and_never_deletes() -> Result<(), String> {
    let (receipt, _dropped) = deleting("restart")?;
    let recovered = recover(&receipt).ok_or("no recovery")?;
    assert_eq!(recovered.receipt.phase, TransferPhase::DeletionUncertain);
    assert_eq!(recovered.effect, LifecycleEffect::Persist);
    // Recovery applies only to DeletingSource; uncertainty is terminal.
    assert!(recover(&recovered.receipt).is_none());
    assert!(recover(&copied("copied", TransferIntent::Move)?).is_none());
    Ok(())
}

#[test]
fn copy_and_legacy_receipts_can_never_produce_deletion_authority() -> Result<(), String> {
    let receipt = copied("copy", TransferIntent::Copy)?;
    assert!(authority(&receipt).is_err());
    // A legacy receipt has no intent field and decodes as Copy.
    let mut raw =
        serde_json::to_value(copied("legacy", TransferIntent::Move)?).map_err(|e| e.to_string())?;
    raw.as_object_mut().ok_or("receipt")?.remove("intent");
    let legacy: TransferReceipt = serde_json::from_value(raw).map_err(|e| e.to_string())?;
    assert_eq!(legacy.intent, TransferIntent::Copy);
    assert!(authority(&legacy).is_err());
    Ok(())
}

#[test]
fn evidence_for_a_same_id_receipt_with_any_other_field_is_rejected() -> Result<(), String> {
    let receipt = copied("same", TransferIntent::Move)?;
    let mut revised = receipt.clone();
    revised.source[0].revision = "edited".into();
    let mut resigned = receipt.clone();
    resigned.signatures = [FileSignature {
        sha256: "b".repeat(64),
        bytes: 3,
    }]
    .into();
    let mut retargeted = receipt.clone();
    retargeted.destination = vec![asset(Provider::Immich, "remote", "other")];
    let mut copy_intent = receipt.clone();
    copy_intent.intent = TransferIntent::Copy;
    for changed in [revised, resigned, retargeted, copy_intent] {
        let evidence = authority(&receipt)?;
        assert!(reduce(&changed, LifecycleEvent::AuthorizeDeletion(evidence)).is_err());
    }
    // Evidence verified for one receipt never combines with another's.
    let other = copied("other", TransferIntent::Move)?;
    let mut fresh_source = bundle(vec![source()]);
    let source = verify_source_evidence(&receipt, &mut fresh_source)?;
    let destination = verify_destination_evidence(&other, &bundle(vec![copy_target()]))?;
    assert!(DeletionAuthority::new(&receipt, source, destination).is_err());
    Ok(())
}

#[test]
fn a_started_or_finished_deletion_never_accepts_another_authorization() -> Result<(), String> {
    let receipt = copied("move", TransferIntent::Move)?;
    for phase in [
        TransferPhase::Copying,
        TransferPhase::DeletingSource,
        TransferPhase::Moved,
        TransferPhase::DeletionUncertain,
    ] {
        let evidence = authority(&receipt)?;
        let mut restarted = receipt.clone();
        restarted.phase = phase;
        assert!(
            reduce(&restarted, LifecycleEvent::AuthorizeDeletion(evidence)).is_err(),
            "{phase:?}"
        );
    }
    Ok(())
}

#[test]
fn partial_or_foreign_copies_are_not_this_receipts_destination() -> Result<(), String> {
    let receipt = start(copying("partial", TransferIntent::Move))?.receipt;
    let extra = asset(Provider::Immich, "remote", "extra");
    let partial = [copy_target().key, extra.key.clone()];
    assert!(verify_copy(&receipt, &partial, &bundle(vec![copy_target()])).is_err());
    assert!(verify_copy(&receipt, &[], &bundle(vec![])).is_err());
    let foreign = asset(Provider::Immich, "another-server#another-owner", "copy");
    let created = [foreign.key.clone()];
    assert!(verify_copy(&receipt, &created, &bundle(vec![foreign])).is_err());
    Ok(())
}

#[test]
fn only_a_fresh_empty_copying_receipt_can_start() {
    let mut started = copying("copy", TransferIntent::Copy);
    started.phase = TransferPhase::Copied;
    assert!(start(started).is_err());
    let mut prefilled = copying("copy", TransferIntent::Copy);
    prefilled.destination = vec![copy_target()];
    assert!(start(prefilled).is_err());
    let mut unsigned = copying("copy", TransferIntent::Copy);
    unsigned.signatures.clear();
    assert!(start(unsigned).is_err());
}
