//! External input and duplication have their own authority: a staged file is
//! not an asset in any provider. An import never grants source deletion rights.
use serde::{Deserialize, Serialize};

use crate::domain::{AssetKey, Provider, ResourceRole};

pub(crate) mod history;
#[cfg(test)]
mod tests;
mod validation;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImportPurpose {
    External,
    DuplicateOriginal,
    DuplicateCurrent,
}

/// Facts inspected from the staged bytes by native ImageIO/AVFoundation.
/// Paths are deliberately absent: the native staging lease resolves opaque IDs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StagedResource {
    pub token: String,
    pub name: String,
    pub role: ResourceRole,
    pub media_type: String,
    pub sha256: String,
    pub bytes: u64,
    pub content_identifier: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportMetadata {
    pub captured_at: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub favorite: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportItem {
    pub id: String,
    pub resources: Vec<StagedResource>,
    pub metadata: ImportMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImportPhase {
    Prepared,
    Submitting,
    Verified,
    AlreadyPresent,
    Uncertain,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportJournal {
    pub id: String,
    pub staging_operation: String,
    pub created_at: f64,
    pub purpose: ImportPurpose,
    pub destination: Provider,
    pub destination_scope: String,
    pub source_keys: Vec<AssetKey>,
    pub item: ImportItem,
    pub phase: ImportPhase,
    pub destination_keys: Vec<AssetKey>,
    pub created: Option<bool>,
}

/// Non-serializable, non-cloneable authority for a single submission. The
/// coordinator creates this only after successfully saving `Submitting`.
#[derive(Debug)]
pub struct ImportSubmission {
    journal: ImportJournal,
}

impl ImportJournal {
    pub fn validate(&self) -> Result<(), String> {
        validation::validate(self)
    }

    /// Plan the durable transition before obtaining a submission token.
    pub fn prepare_submission(&self) -> Result<Self, String> {
        self.validate()?;
        if self.phase != ImportPhase::Prepared {
            return Err(
                "開始済みの取り込みを再送信できません。保存結果を確認してください。".into(),
            );
        }
        let mut next = self.clone();
        next.phase = ImportPhase::Submitting;
        Ok(next)
    }

    /// Must be called with the exact record acknowledged by durable storage.
    pub(crate) fn submission_after_save(&self, saved: &Self) -> Result<ImportSubmission, String> {
        if self.prepare_submission()? != *saved {
            return Err("取り込みの永続記録が送信内容と一致しません。".into());
        }
        Ok(ImportSubmission {
            journal: saved.clone(),
        })
    }

    /// Startup never resubmits a request whose response may have been lost.
    #[must_use]
    pub fn recover(&self) -> Self {
        let mut recovered = self.clone();
        if recovered.phase == ImportPhase::Submitting {
            recovered.phase = ImportPhase::Uncertain;
        }
        recovered
    }

    #[must_use]
    pub fn retains_staged_bytes(&self) -> bool {
        matches!(
            self.phase,
            ImportPhase::Prepared | ImportPhase::Submitting | ImportPhase::Uncertain
        )
    }

    pub fn cancel_before_submission(&self) -> Result<Self, String> {
        if self.phase != ImportPhase::Prepared {
            return Err(
                "保存を開始した取り込みは取消できません。保存結果を確認してください。".into(),
            );
        }
        let mut next = self.clone();
        next.phase = ImportPhase::Cancelled;
        Ok(next)
    }
}

impl ImportSubmission {
    #[must_use]
    pub fn journal(&self) -> &ImportJournal {
        &self.journal
    }

    /// Only exact bytes and independently read-back keys can complete a write.
    /// `created` is the provider's creation disposition, not inferred from a key.
    pub fn verified(
        self,
        keys: Vec<AssetKey>,
        sha256s: Vec<String>,
        created: bool,
    ) -> Result<ImportJournal, String> {
        let mut journal = self.journal;
        if keys.is_empty()
            || keys.iter().any(|key| {
                key.provider != journal.destination
                    || key.scope != journal.destination_scope
                    || key.asset_id.is_empty()
            })
            || keys.iter().collect::<std::collections::BTreeSet<_>>().len() != keys.len()
        {
            return Err("保存先の識別情報を確認できません。".into());
        }
        let mut expected: Vec<_> = journal
            .item
            .resources
            .iter()
            .map(|r| r.sha256.clone())
            .collect();
        let mut actual = sha256s;
        expected.sort();
        actual.sort();
        if expected != actual {
            return Err("保存先で原本の全構成を確認できません。".into());
        }
        if created && keys.iter().any(|key| journal.source_keys.contains(key)) {
            return Err("元の写真と同じIDです。複製を確認できません。".into());
        }
        journal.destination_keys = keys;
        journal.created = Some(created);
        journal.phase = if created {
            ImportPhase::Verified
        } else {
            ImportPhase::AlreadyPresent
        };
        Ok(journal)
    }

    #[must_use]
    pub fn uncertain(self) -> ImportJournal {
        self.journal.recover()
    }
}

/// Normal catalog saves cannot erase or rewind another workflow's journal.
/// The local store calls this inside its transaction, alongside Live validation.
pub fn validate_transition(
    before: &[ImportJournal],
    after: &[ImportJournal],
) -> Result<(), String> {
    let mut ids = std::collections::BTreeSet::new();
    for record in after {
        record.validate()?;
        if !ids.insert(&record.id) {
            return Err("取り込み記録のIDが重複しています。".into());
        }
        if !before.iter().any(|old| old.id == record.id) && record.phase != ImportPhase::Prepared {
            return Err("取り込み記録を途中の状態から作成できません。".into());
        }
    }
    for old in before {
        let new = after
            .iter()
            .find(|entry| entry.id == old.id)
            .ok_or("既存の取り込み記録を削除できません。")?;
        let mut identity = new.clone();
        identity.phase = old.phase;
        identity.destination_keys.clone_from(&old.destination_keys);
        identity.created = old.created;
        if identity != *old {
            return Err("取り込みの保存内容を途中で変更できません。".into());
        }
        if old.created == Some(false) && new.created != Some(false) {
            return Err("既存の写真を新規作成として扱えません。".into());
        }
        if old
            .destination_keys
            .iter()
            .any(|key| !new.destination_keys.contains(key))
        {
            return Err("確認済みの取り込み先IDを削除できません。".into());
        }
        let allowed = old == new
            || matches!(
                (old.phase, new.phase),
                (
                    ImportPhase::Prepared,
                    ImportPhase::Submitting | ImportPhase::Cancelled
                ) | (
                    ImportPhase::Submitting,
                    ImportPhase::Submitting
                        | ImportPhase::Verified
                        | ImportPhase::AlreadyPresent
                        | ImportPhase::Uncertain
                ) | (
                    ImportPhase::Uncertain,
                    ImportPhase::Verified | ImportPhase::AlreadyPresent
                )
            );
        if !allowed {
            return Err("取り込み記録を巻き戻せません。".into());
        }
    }
    Ok(())
}

impl ImportJournal {
    /// Read-only reconciliation never issues submission authority. A missing
    /// creation response cannot be invented from a checksum match.
    pub fn reconcile(&self, sha256s: Vec<String>) -> Result<Self, String> {
        if self.phase != ImportPhase::Uncertain {
            return Err("未確認の取り込み記録を選択してください。".into());
        }
        let created = self
            .created
            .ok_or("作成応答を取得できませんでした。保存先のライブラリを確認してください。")?;
        ImportSubmission {
            journal: self.clone(),
        }
        .verified(self.destination_keys.clone(), sha256s, created)
    }
}

/// Public status without any staged-file or destination asset identity.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImportNotice {
    pub id: String,
    pub phase: ImportPhase,
    pub can_inspect: bool,
}
