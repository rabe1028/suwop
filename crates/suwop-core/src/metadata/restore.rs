use super::{MetadataEdit, MetadataOutcome, MetadataRecord};
use crate::domain::Provider;
use serde::{Deserialize, Serialize};

/// View-only availability. Persistence retains the operation evidence unchanged.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataRestoreAvailability {
    pub id: String,
    pub undo_reason: Option<String>,
    pub original_reason: Option<String>,
}

#[must_use]
pub fn restore_availability(records: &[MetadataRecord]) -> Vec<MetadataRestoreAvailability> {
    records
        .iter()
        .map(|record| MetadataRestoreAvailability {
            id: record.id.clone(),
            undo_reason: restore_edits(records, record, false).err(),
            original_reason: restore_edits(records, record, true).err(),
        })
        .collect()
}

pub fn restore_edits(
    records: &[MetadataRecord],
    record: &MetadataRecord,
    original: bool,
) -> Result<Vec<MetadataEdit>, String> {
    if record.outcome != MetadataOutcome::VerifiedApplied {
        return Err(
            "結果不明の操作は取り消しを自動実行できません。現在を確認してください。".into(),
        );
    }
    let baseline = if original {
        records
            .iter()
            .find(|candidate| {
                candidate.keys == record.keys && candidate.edit.field() == record.edit.field()
            })
            .unwrap_or(record)
    } else {
        record
    };
    record.keys.iter().map(|key| {
        let value = baseline.before.iter().find(|item| item.asset.key == *key).ok_or("元の値がありません。")?;
        let edit = record.edit.restoring(&value.values)?;
        if key.provider == Provider::Immich && matches!(edit, MetadataEdit::RemoveLocation) {
            return Err("元の位置情報はありません。Immichは位置情報の削除に対応していないため戻せません。".into());
        }
        edit.change()?;
        Ok(edit)
    }).collect()
}
