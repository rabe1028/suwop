//! The common journal runner. A [`JournalChange`] is applied to the in-memory
//! library, saved, and only then acknowledged as a [`DurableStage`]. A failed
//! save restores the touched journal, so an unsent stage can never become a
//! phantom fence through a later unrelated save. Only this module can create
//! a [`DurableStage`], and it authorizes exactly one submission whose plan
//! equals the saved data. Access epochs are still checked separately at the
//! native boundary; a durable stage is not access authority.
use super::Runtime;
use crate::{
    amazon::{UploadRecord, UploadRecordPhase},
    domain::{AssetKey, FileSignature, StoredAsset, TransferPhase, TransferReceipt},
    immich::{PendingUpload, UploadIntent, UploadPhase},
    provider::{ImportWindow, Io},
};

/// The exact saved data one stage authorizes, compared structurally.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum StageBinding {
    /// The complete saved `Copying` receipt, before any destination write.
    Copying(TransferReceipt),
    /// The complete saved `DeletingSource` receipt, before native deletion.
    DeletingSource(TransferReceipt),
    /// Any later receipt phase; it authorizes no write.
    Receipt {
        id: String,
        phase: TransferPhase,
    },
    /// The Amazon record saved before its single POST.
    AmazonUpload(UploadRecord),
    AmazonResult {
        record: UploadRecord,
        node_id: Option<String>,
    },
    /// The Immich intent saved before its single POST.
    ImmichIntent {
        scope: String,
        token: String,
        source: AssetKey,
        signature: FileSignature,
    },
    ImmichIntentResult {
        scope: String,
        token: String,
    },
    /// The pending copy whose `MetadataStarted` was saved before its PUT.
    ImmichMetadata(AssetKey),
    ImmichPendingRemoved(AssetKey),
}

impl StageBinding {
    pub(crate) fn immich_intent(intent: &UploadIntent) -> Self {
        Self::ImmichIntent {
            scope: intent.scope.clone(),
            token: intent.token.clone(),
            source: intent.source.key.clone(),
            signature: intent.signature.clone(),
        }
    }
}

/// Proof that one journal stage was durably saved. It cannot be cloned, so a
/// save authorizes one submission and is never reused for another plan.
#[derive(Debug)]
pub(crate) struct DurableStage {
    binding: StageBinding,
}

impl DurableStage {
    pub(crate) fn authorize(self, expected: &StageBinding) -> Result<(), String> {
        if self.binding == *expected {
            Ok(())
        } else {
            Err("保存した段階と実行する操作が一致しません。書込みは開始しません。".into())
        }
    }
}

#[derive(Debug)]
pub(crate) enum JournalChange {
    /// A receipt produced by the lifecycle reducer, inserted or replaced by ID.
    Receipt(TransferReceipt),
    AmazonUpload(UploadRecord),
    /// Definite non-storage: remove exactly this unsent-or-refused record.
    AmazonRelease(UploadRecord),
    AmazonCreated {
        record: UploadRecord,
        node_id: String,
    },
    AmazonVerified(UploadRecord),
    ImmichIntent(UploadIntent),
    ImmichIntentRemoved {
        scope: String,
        token: String,
    },
    ImmichIntentPromoted {
        token: String,
        pending: PendingUpload,
    },
    ImmichMetadataStarted(AssetKey),
    ImmichPendingRemoved(AssetKey),
}

impl JournalChange {
    fn binding(&self) -> StageBinding {
        match self {
            Self::Receipt(receipt) => match receipt.phase {
                TransferPhase::Copying => StageBinding::Copying(receipt.clone()),
                TransferPhase::DeletingSource => StageBinding::DeletingSource(receipt.clone()),
                phase => StageBinding::Receipt {
                    id: receipt.id.clone(),
                    phase,
                },
            },
            Self::AmazonUpload(record) => StageBinding::AmazonUpload(record.clone()),
            Self::AmazonRelease(record) | Self::AmazonVerified(record) => {
                StageBinding::AmazonResult {
                    record: record.clone(),
                    node_id: None,
                }
            }
            Self::AmazonCreated { record, node_id } => StageBinding::AmazonResult {
                record: record.clone(),
                node_id: Some(node_id.clone()),
            },
            Self::ImmichIntent(intent) => StageBinding::immich_intent(intent),
            Self::ImmichIntentRemoved { scope, token } => StageBinding::ImmichIntentResult {
                scope: scope.clone(),
                token: token.clone(),
            },
            Self::ImmichIntentPromoted { token, pending } => StageBinding::ImmichIntentResult {
                scope: pending.key.scope.clone(),
                token: token.clone(),
            },
            Self::ImmichMetadataStarted(key) => StageBinding::ImmichMetadata(key.clone()),
            Self::ImmichPendingRemoved(key) => StageBinding::ImmichPendingRemoved(key.clone()),
        }
    }
}

/// The touched journal before a change, restored if the save fails.
enum Undo {
    Receipts(Vec<TransferReceipt>),
    Amazon(Vec<UploadRecord>),
    Immich {
        intents: Vec<UploadIntent>,
        pending: Vec<PendingUpload>,
    },
}

/// The one saved Amazon record equal to `record` in the expected phase.
fn amazon_position(
    records: &[UploadRecord],
    record: &UploadRecord,
    phase: UploadRecordPhase,
) -> Result<usize, String> {
    let positions: Vec<_> = records
        .iter()
        .enumerate()
        .filter(|(_, r)| *r == record)
        .map(|(i, _)| i)
        .collect();
    match positions.as_slice() {
        [index] if record.phase() == phase => Ok(*index),
        _ => Err("Amazon Photosの転送記録を確認できません。書込みは再送しません。".into()),
    }
}

impl Runtime<'_> {
    fn apply_journal(&mut self, change: JournalChange) -> Result<Undo, String> {
        let state = &mut self.state;
        match change {
            JournalChange::Receipt(receipt) => {
                let undo = Undo::Receipts(state.receipts.clone());
                if let Some(saved) = state.receipts.iter_mut().find(|r| r.id == receipt.id) {
                    *saved = receipt;
                } else {
                    state.receipts.push(receipt);
                }
                Ok(undo)
            }
            JournalChange::AmazonUpload(record) => {
                if record.phase() != UploadRecordPhase::Submitting
                    || state.amazon_uploads.contains(&record)
                {
                    return Err(
                        "Amazon Photosの転送記録が重複しています。書込みは開始しません。".into(),
                    );
                }
                let undo = Undo::Amazon(state.amazon_uploads.clone());
                state.amazon_uploads.push(record);
                Ok(undo)
            }
            JournalChange::AmazonRelease(record) => {
                let index = amazon_position(
                    &state.amazon_uploads,
                    &record,
                    UploadRecordPhase::Submitting,
                )?;
                let undo = Undo::Amazon(state.amazon_uploads.clone());
                state.amazon_uploads.remove(index);
                Ok(undo)
            }
            JournalChange::AmazonCreated { record, node_id } => {
                let index = amazon_position(
                    &state.amazon_uploads,
                    &record,
                    UploadRecordPhase::Submitting,
                )?;
                let undo = Undo::Amazon(state.amazon_uploads.clone());
                state.amazon_uploads[index].node_id = Some(node_id);
                Ok(undo)
            }
            JournalChange::AmazonVerified(record) => {
                let index =
                    amazon_position(&state.amazon_uploads, &record, UploadRecordPhase::Created)?;
                let undo = Undo::Amazon(state.amazon_uploads.clone());
                state.amazon_uploads[index].verified = true;
                Ok(undo)
            }
            change => self.apply_immich_journal(change),
        }
    }

    fn apply_immich_journal(&mut self, change: JournalChange) -> Result<Undo, String> {
        let state = &mut self.state;
        let undo = Undo::Immich {
            intents: state.upload_intents.clone(),
            pending: state.pending_uploads.clone(),
        };
        match change {
            JournalChange::ImmichIntent(intent) => {
                if state.upload_intents.iter().any(|p| p.token == intent.token) {
                    return Err("アップロードの固有 ID が重複しています。".into());
                }
                state.upload_intents.push(intent);
            }
            JournalChange::ImmichIntentRemoved { scope, token } => {
                state
                    .upload_intents
                    .retain(|p| p.scope != scope || p.token != token);
            }
            JournalChange::ImmichIntentPromoted { token, pending } => {
                state.upload_intents.retain(|p| p.token != token);
                state.pending_uploads.push(pending);
            }
            JournalChange::ImmichMetadataStarted(key) => {
                let entry = state
                    .pending_uploads
                    .iter_mut()
                    .find(|p| p.key == key)
                    .ok_or("作成済みコピーの記録がありません。")?;
                entry.phase = UploadPhase::MetadataStarted;
            }
            JournalChange::ImmichPendingRemoved(key) => {
                state.pending_uploads.retain(|p| p.key != key);
            }
            _ => return Err("転送記録の変更が不正です。".into()),
        }
        Ok(undo)
    }

    fn undo_journal(&mut self, undo: Undo) {
        match undo {
            Undo::Receipts(receipts) => self.state.receipts = receipts,
            Undo::Amazon(records) => self.state.amazon_uploads = records,
            Undo::Immich { intents, pending } => {
                self.state.upload_intents = intents;
                self.state.pending_uploads = pending;
            }
        }
    }

    /// Apply one journal change and wait for its durable save. The returned
    /// stage is the only authority for the write that the change precedes.
    pub(super) async fn persist_stage(
        &mut self,
        change: JournalChange,
    ) -> Result<DurableStage, String> {
        let binding = change.binding();
        let undo = self.apply_journal(change)?;
        if let Err(error) = self.persist().await {
            // No write was issued; memory must match the durable journal.
            self.undo_journal(undo);
            return Err(error);
        }
        Ok(DurableStage { binding })
    }
}

impl ImportWindow for Runtime<'_> {
    fn upload_intents(&self) -> Vec<UploadIntent> {
        self.state.upload_intents.clone()
    }

    fn pending_uploads(&self) -> Vec<PendingUpload> {
        self.state.pending_uploads.clone()
    }

    fn amazon_uploads(&self) -> Vec<UploadRecord> {
        self.state.amazon_uploads.clone()
    }

    fn cataloged(&self, key: &AssetKey) -> Option<StoredAsset> {
        self.state
            .snapshots
            .iter()
            .flat_map(|s| &s.assets)
            .find(|a| a.key == *key)
            .cloned()
    }

    fn work_directory(&self, name: &str) -> Result<String, String> {
        self.directory(name)
    }

    fn check_destination(&self, keys: &[AssetKey]) -> Result<(), String> {
        self.check_keys(keys).map(|_| ())
    }

    fn check_source(&self, source: &StoredAsset) -> Result<(), String> {
        self.check_content_generation(std::slice::from_ref(&source.key))?;
        self.check_transfer_trash(std::slice::from_ref(source))
    }

    fn stage(&mut self, change: JournalChange) -> Io<'_, DurableStage> {
        Box::pin(self.persist_stage(change))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Provider, TransferIntent};

    fn receipt(id: &str, phase: TransferPhase) -> TransferReceipt {
        TransferReceipt {
            id: id.into(),
            created_at: 1.0,
            phase,
            intent: TransferIntent::Move,
            source: vec![],
            destination: vec![],
            destination_provider: Provider::Immich,
            destination_scope: "remote".into(),
            signatures: std::collections::BTreeSet::new(),
        }
    }

    #[test]
    fn a_saved_stage_authorizes_only_its_own_complete_plan() {
        let saved = receipt("receipt", TransferPhase::DeletingSource);
        let expected = StageBinding::DeletingSource(saved.clone());
        let mut changed = saved.clone();
        changed.destination_scope = "another".into();
        for other in [
            StageBinding::DeletingSource(receipt("another", TransferPhase::DeletingSource)),
            StageBinding::DeletingSource(changed),
            StageBinding::Copying(receipt("receipt", TransferPhase::Copying)),
        ] {
            let stage = DurableStage { binding: other };
            assert!(stage.authorize(&expected).is_err());
        }
        let stage = DurableStage {
            binding: JournalChange::Receipt(saved).binding(),
        };
        assert!(stage.authorize(&expected).is_ok());
    }
}
