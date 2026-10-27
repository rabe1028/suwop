//! Pure transfer lifecycle reducer. A workflow saves the receipt of each
//! [`Step`] and performs its [`LifecycleEffect`] only after that save has
//! completed. Evidence is created only by the shared verification in this
//! module, never by a provider adapter, and binds the complete receipt it was
//! verified against: a same-ID receipt with any other field is rejected.
//!
//! | from | event | to | effect |
//! |---|---|---|---|
//! | (none) | [`start`] | `Copying` | `PersistThenImport` |
//! | `Copying` | `CopyVerified` | `Copied` | `Persist` |
//! | `Copied` | `AuthorizeDeletion` (explicit Move only) | `DeletingSource` | `PersistThenDelete` |
//! | `DeletingSource` | `DeletionNotSubmitted(live attempt)` | `Copied` | `Persist` |
//! | `DeletingSource` | `DeletionSucceeded(submitted attempt)` | `Moved` | `Persist` |
//! | `DeletingSource` | `DeletionUnknown(submitted attempt)` | `DeletionUncertain` | `Persist` |
//! | `DeletingSource` | [`recover`] (no live attempt) | `DeletionUncertain` | `Persist` |
//!
//! Every other pair is rejected. A failed or cancelled import has no event:
//! the receipt stays `Copying`. A [`DeletionAttempt`] exists only inside the
//! operation that saved `DeletingSource`; it is never persisted. After a
//! restart or a dropped operation there is no attempt, so the only transition
//! is [`recover`] to `DeletionUncertain`, and deletion is never issued again.
use std::collections::BTreeSet;

use crate::domain::{
    AssetKey, StoredAsset, TransferBundle, TransferIntent, TransferPhase, TransferReceipt,
    verify_destination, verify_source,
};

/// Destination originals freshly read back and matched against one receipt.
#[derive(Debug)]
pub struct VerifiedDestination {
    receipt: TransferReceipt,
    assets: Vec<StoredAsset>,
}

/// Source originals freshly read and unchanged since one Move was copied.
#[derive(Debug)]
pub struct VerifiedSource {
    receipt: TransferReceipt,
    assets: Vec<StoredAsset>,
}

/// Both sides of one explicit Move, freshly verified against the same receipt.
#[derive(Debug)]
pub struct DeletionAuthority {
    receipt: TransferReceipt,
    source: Vec<StoredAsset>,
}

/// The one live deletion attempt of a saved `DeletingSource` receipt. It
/// cannot be cloned or persisted. Returning it unconsumed is the proof that
/// the native deletion was never issued.
#[derive(Debug, PartialEq)]
pub struct DeletionAttempt {
    receipt: Box<TransferReceipt>,
    sources: Vec<StoredAsset>,
}

/// An attempt whose native deletion was, or may have been, issued.
#[derive(Debug, PartialEq)]
pub struct SubmittedDeletion {
    receipt: Box<TransferReceipt>,
}

impl DeletionAttempt {
    /// The saved `DeletingSource` receipt this attempt belongs to.
    #[must_use]
    pub fn receipt(&self) -> &TransferReceipt {
        &self.receipt
    }

    /// Freshly verified sources to delete.
    #[must_use]
    pub fn sources(&self) -> &[StoredAsset] {
        &self.sources
    }

    /// Every key whose access epoch the deletion depends on: the sources and
    /// the verified destination copies.
    #[must_use]
    pub fn dependencies(&self) -> Vec<AssetKey> {
        self.sources
            .iter()
            .chain(&self.receipt.destination)
            .map(|a| a.key.clone())
            .collect()
    }

    /// Consume the attempt immediately before issuing the native deletion.
    /// Afterwards non-submission can no longer be claimed.
    #[must_use]
    pub fn submit(self) -> SubmittedDeletion {
        SubmittedDeletion {
            receipt: self.receipt,
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum LifecycleEffect {
    /// Save the new `Copying` receipt, then write to the destination.
    PersistThenImport,
    Persist,
    /// Save `DeletingSource`, then issue one native deletion for this attempt.
    PersistThenDelete(DeletionAttempt),
}

#[derive(Debug)]
pub enum LifecycleEvent {
    CopyVerified(VerifiedDestination),
    AuthorizeDeletion(DeletionAuthority),
    /// The live attempt, returned unconsumed: never issued.
    DeletionNotSubmitted(DeletionAttempt),
    DeletionSucceeded(SubmittedDeletion),
    /// Failed, lost, cancelled or otherwise ambiguous after submission.
    DeletionUnknown(SubmittedDeletion),
}

#[derive(Debug)]
pub struct Step {
    pub receipt: TransferReceipt,
    pub effect: LifecycleEffect,
}

fn keys(assets: &[StoredAsset]) -> BTreeSet<&AssetKey> {
    assets.iter().map(|a| &a.key).collect()
}

/// Admit a new receipt. Nothing may be written before it is saved.
pub fn start(receipt: TransferReceipt) -> Result<Step, String> {
    if receipt.phase != TransferPhase::Copying
        || !receipt.destination.is_empty()
        || receipt.source.is_empty()
        || receipt.signatures.is_empty()
        || keys(&receipt.source).len() != receipt.source.len()
    {
        return Err("転送記録を開始できません。書込みは開始しません。".into());
    }
    Ok(Step {
        receipt,
        effect: LifecycleEffect::PersistThenImport,
    })
}

/// A saved `DeletingSource` without a live attempt, after a restart or a
/// dropped operation. Its deletion may have happened and is never retried.
#[must_use]
pub fn recover(receipt: &TransferReceipt) -> Option<Step> {
    (receipt.phase == TransferPhase::DeletingSource).then(|| {
        let mut next = receipt.clone();
        next.phase = TransferPhase::DeletionUncertain;
        Step {
            receipt: next,
            effect: LifecycleEffect::Persist,
        }
    })
}

/// Copies created by this receipt's import, read back in its destination.
pub fn verify_copy(
    receipt: &TransferReceipt,
    created: &[AssetKey],
    fresh: &TransferBundle,
) -> Result<VerifiedDestination, String> {
    let expected: BTreeSet<_> = created.iter().collect();
    if receipt.phase != TransferPhase::Copying
        || expected.is_empty()
        || expected != keys(&fresh.assets)
        || created.iter().any(|key| {
            key.provider != receipt.destination_provider || key.scope != receipt.destination_scope
        })
    {
        return Err("作成したコピーを転送先で確認できません。元データは残します。".into());
    }
    let mut bound = receipt.clone();
    bound.destination.clone_from(&fresh.assets);
    verify_destination(&bound, fresh)?;
    Ok(VerifiedDestination {
        receipt: receipt.clone(),
        assets: fresh.assets.clone(),
    })
}

/// The receipt's recorded destination, freshly read again.
pub fn verify_destination_evidence(
    receipt: &TransferReceipt,
    fresh: &TransferBundle,
) -> Result<VerifiedDestination, String> {
    verify_destination(receipt, fresh)?;
    Ok(VerifiedDestination {
        receipt: receipt.clone(),
        assets: fresh.assets.clone(),
    })
}

/// The receipt's source, freshly read and unchanged since the copy.
pub fn verify_source_evidence(
    receipt: &TransferReceipt,
    fresh: &mut TransferBundle,
) -> Result<VerifiedSource, String> {
    verify_source(receipt, fresh)?;
    Ok(VerifiedSource {
        receipt: receipt.clone(),
        assets: fresh.assets.clone(),
    })
}

impl DeletionAuthority {
    pub fn new(
        receipt: &TransferReceipt,
        source: VerifiedSource,
        destination: VerifiedDestination,
    ) -> Result<Self, String> {
        if source.receipt != *receipt
            || destination.receipt != *receipt
            || keys(&source.assets) != keys(&receipt.source)
            || keys(&destination.assets) != keys(&receipt.destination)
        {
            return Err("移動の確認結果が転送記録と一致しません。元データは残します。".into());
        }
        Ok(Self {
            receipt: destination.receipt,
            source: source.assets,
        })
    }
}

pub fn reduce(receipt: &TransferReceipt, event: LifecycleEvent) -> Result<Step, String> {
    let mut next = receipt.clone();
    let effect = match (receipt.phase, event) {
        (TransferPhase::Copying, LifecycleEvent::CopyVerified(verified))
            if verified.receipt == *receipt =>
        {
            next.destination = verified.assets;
            next.phase = TransferPhase::Copied;
            LifecycleEffect::Persist
        }
        (TransferPhase::Copied, LifecycleEvent::AuthorizeDeletion(authority))
            if receipt.intent == TransferIntent::Move
                && receipt.move_blockers().is_empty()
                && !receipt.destination.is_empty()
                && authority.receipt == *receipt =>
        {
            next.phase = TransferPhase::DeletingSource;
            LifecycleEffect::PersistThenDelete(DeletionAttempt {
                receipt: Box::new(next.clone()),
                sources: authority.source,
            })
        }
        (TransferPhase::DeletingSource, LifecycleEvent::DeletionNotSubmitted(attempt))
            if *attempt.receipt == *receipt =>
        {
            next.phase = TransferPhase::Copied;
            LifecycleEffect::Persist
        }
        (TransferPhase::DeletingSource, LifecycleEvent::DeletionSucceeded(submitted))
            if *submitted.receipt == *receipt =>
        {
            next.phase = TransferPhase::Moved;
            LifecycleEffect::Persist
        }
        (TransferPhase::DeletingSource, LifecycleEvent::DeletionUnknown(submitted))
            if *submitted.receipt == *receipt =>
        {
            next.phase = TransferPhase::DeletionUncertain;
            LifecycleEffect::Persist
        }
        _ => {
            return Err("この転送記録の状態では実行できません。元データは残します。".into());
        }
    };
    Ok(Step {
        receipt: next,
        effect,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        AppleVisibility, FileSignature, ImmichStackState, PhotoResource, Provider, ResourceRole,
    };

    fn asset(provider: Provider, id: &str) -> StoredAsset {
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
            name: "photo.jpg".into(),
            captured_at: Some(1.0),
            modified_at: None,
            revision: "r".into(),
            resources: vec![PhotoResource {
                id: id.into(),
                name: "photo.jpg".into(),
                role: ResourceRole::Image,
                sha1: Some("1".repeat(40)),
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

    fn copied(intent: TransferIntent) -> TransferReceipt {
        TransferReceipt {
            id: "receipt".into(),
            created_at: 1.0,
            phase: TransferPhase::Copied,
            intent,
            source: vec![asset(Provider::Apple, "source")],
            destination: vec![asset(Provider::Immich, "copy")],
            destination_provider: Provider::Immich,
            destination_scope: "Immich".into(),
            signatures: [FileSignature {
                sha256: "a".repeat(64),
                bytes: 3,
            }]
            .into(),
        }
    }

    fn authority(receipt: &TransferReceipt) -> DeletionAuthority {
        DeletionAuthority {
            receipt: receipt.clone(),
            source: receipt.source.clone(),
        }
    }

    fn attempt(moving: &TransferReceipt) -> Result<(TransferReceipt, DeletionAttempt), String> {
        let step = reduce(moving, LifecycleEvent::AuthorizeDeletion(authority(moving)))?;
        match step.effect {
            LifecycleEffect::PersistThenDelete(attempt) => Ok((step.receipt, attempt)),
            _ => Err("no attempt".into()),
        }
    }

    #[test]
    fn deletion_requires_an_explicit_move_bound_to_the_same_full_receipt() -> Result<(), String> {
        let copy = copied(TransferIntent::Copy);
        assert!(reduce(&copy, LifecycleEvent::AuthorizeDeletion(authority(&copy))).is_err());
        let moving = copied(TransferIntent::Move);
        let mut changed = moving.clone();
        changed.signatures.clear();
        assert!(
            reduce(
                &changed,
                LifecycleEvent::AuthorizeDeletion(authority(&moving))
            )
            .is_err()
        );
        let (deleting, attempt) = attempt(&moving)?;
        assert_eq!(deleting.phase, TransferPhase::DeletingSource);
        assert_eq!(attempt.sources(), moving.source.as_slice());
        assert_eq!(attempt.dependencies().len(), 2);
        Ok(())
    }

    #[test]
    fn outcomes_need_this_live_attempt_in_the_matching_state() -> Result<(), String> {
        let moving = copied(TransferIntent::Move);
        let (deleting, live) = attempt(&moving)?;
        // An attempt for another receipt state cannot settle this one.
        let mut other = moving.clone();
        other.created_at = 2.0;
        let (_, foreign) = attempt(&other)?;
        assert!(reduce(&deleting, LifecycleEvent::DeletionNotSubmitted(foreign)).is_err());
        // A submitted attempt can no longer roll back.
        let step = reduce(&deleting, LifecycleEvent::DeletionUnknown(live.submit()))?;
        assert_eq!(step.receipt.phase, TransferPhase::DeletionUncertain);
        Ok(())
    }

    #[test]
    fn a_recovered_deleting_receipt_only_becomes_uncertain() -> Result<(), String> {
        let (deleting, _) = attempt(&copied(TransferIntent::Move))?;
        let recovered = recover(&deleting).ok_or("no recovery")?;
        assert_eq!(recovered.receipt.phase, TransferPhase::DeletionUncertain);
        assert!(recover(&copied(TransferIntent::Move)).is_none());
        Ok(())
    }
}
