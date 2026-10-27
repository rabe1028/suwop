use crate::domain::{AssetKey, StoredAsset};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(
    tag = "type",
    content = "data",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum MetadataEdit {
    CapturedAt {
        local: String,
        zone: String,
        occurrence: Option<super::time_zone::Occurrence>,
    },
    Location {
        latitude: String,
        longitude: String,
    },
    RemoveLocation,
    Description {
        text: String,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataValues {
    pub captured_at: Option<f64>,
    pub time_zone: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Apple values live only in this application's durable journal.
    pub description: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataWitness {
    pub asset: StoredAsset,
    pub values: MetadataValues,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum MetadataOutcome {
    SubmittedUnknown,
    NotApplied,
    VerifiedApplied,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataRecord {
    pub id: String,
    pub keys: Vec<AssetKey>,
    pub edit: MetadataEdit,
    pub member_edits: Vec<MetadataEdit>,
    pub before: Vec<MetadataWitness>,
    pub after: Vec<MetadataWitness>,
    pub outcome: MetadataOutcome,
    /// Undo records append; they never erase the original operation.
    pub restores: Option<String>,
    #[serde(default)]
    pub current: Vec<MetadataObservation>,
}
/// A Rust-planned member of one atomic Apple metadata transaction.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleMetadataMember {
    pub before: crate::domain::StoredAsset,
    pub change: super::MetadataChange,
}

impl MetadataEdit {
    #[must_use]
    pub fn field(&self) -> &'static str {
        match self {
            Self::CapturedAt { .. } => "date",
            Self::Location { .. } | Self::RemoveLocation => "location",
            Self::Description { .. } => "description",
        }
    }

    pub fn change(&self) -> Result<Option<super::MetadataChange>, String> {
        let input = match self {
            Self::CapturedAt {
                local,
                zone,
                occurrence,
            } => super::MetadataInput {
                action: super::MetadataAction::SetCapturedAt,
                captured_at: Some(super::time_zone::resolve(local, zone, *occurrence)?),
                time_zone: Some(zone.clone()),
                latitude: None,
                longitude: None,
            },
            Self::Location {
                latitude,
                longitude,
            } => super::MetadataInput {
                action: super::MetadataAction::SetLocation,
                captured_at: None,
                time_zone: None,
                latitude: Some(latitude.clone()),
                longitude: Some(longitude.clone()),
            },
            Self::RemoveLocation => super::MetadataInput {
                action: super::MetadataAction::RemoveLocation,
                captured_at: None,
                time_zone: None,
                latitude: None,
                longitude: None,
            },
            Self::Description { text } => {
                if text.len() > 65_536 || text.contains('\0') {
                    return Err("説明は65536バイト以内で、NULを含めず入力してください。".into());
                }
                return Ok(None);
            }
        };
        super::normalize(&input).map(Some)
    }
    /// Immich persists the requested instant but may derive its display zone
    /// from GPS. The requested IANA name remains in the edit, never in observed values.
    pub fn matches_provider(
        &self,
        provider: crate::domain::Provider,
        actual: &MetadataValues,
    ) -> Result<bool, String> {
        if provider == crate::domain::Provider::Immich && matches!(self, Self::CapturedAt { .. }) {
            let desired = self.change()?.ok_or("変更内容がありません。")?;
            return Ok(actual
                .captured_at
                .zip(desired.captured_at)
                .is_some_and(|(a, b)| crate::domain::same_capture_date(a, b))
                && actual
                    .time_zone
                    .as_deref()
                    .is_some_and(super::fixed_zone::valid));
        }
        self.matches(actual)
    }

    pub fn matches(&self, actual: &MetadataValues) -> Result<bool, String> {
        if let Self::Description { text } = self {
            return Ok(actual.description == *text);
        }
        let desired = self.change()?.ok_or("変更内容がありません。")?;
        Ok(match desired.action {
            super::MetadataAction::SetCapturedAt => {
                actual
                    .captured_at
                    .zip(desired.captured_at)
                    .is_some_and(|(a, b)| crate::domain::same_capture_date(a, b))
                    && actual
                        .time_zone
                        .as_deref()
                        .zip(desired.time_zone.as_deref())
                        .zip(actual.captured_at)
                        .is_some_and(|((actual, requested), instant)| {
                            super::fixed_zone::equivalent(requested, actual, instant)
                        })
            }
            super::MetadataAction::SetLocation => desired.location.is_some_and(|point| {
                actual.latitude == Some(point.latitude) && actual.longitude == Some(point.longitude)
            }),
            super::MetadataAction::RemoveLocation => {
                actual.latitude.is_none() && actual.longitude.is_none()
            }
        })
    }
    pub fn restoring(&self, value: &MetadataValues) -> Result<Self, String> {
        match self {
            Self::Description { .. } => Ok(Self::Description {
                text: value.description.clone(),
            }),
            Self::Location { .. } | Self::RemoveLocation => {
                match value.latitude.zip(value.longitude) {
                    Some((latitude, longitude)) => Ok(Self::Location {
                        latitude: latitude.to_string(),
                        longitude: longitude.to_string(),
                    }),
                    None if value.latitude.is_none() && value.longitude.is_none() => {
                        Ok(Self::RemoveLocation)
                    }
                    _ => Err("元の座標が不完全です。".into()),
                }
            }
            Self::CapturedAt { .. } => {
                let instant = value
                    .captured_at
                    .ok_or("元の日時が不明なため復元できません。")?;
                let zone = value
                    .time_zone
                    .as_deref()
                    .ok_or("元のタイムゾーンが不明なため復元できません。")?;
                let (local, occurrence) = super::time_zone::local(instant, zone)?;
                Ok(Self::CapturedAt {
                    local,
                    zone: zone.into(),
                    occurrence,
                })
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataObservation {
    pub key: AssetKey,
    pub witness: Option<MetadataWitness>,
    pub unavailable: bool,
}
#[must_use]
pub fn blocked(keys: &[AssetKey], records: &[MetadataRecord]) -> bool {
    records.iter().any(|record| {
        record.outcome == MetadataOutcome::SubmittedUnknown
            && record.keys.iter().any(|key| keys.contains(key))
    })
}
#[must_use]
pub fn description_for<'a>(key: &AssetKey, records: &'a [MetadataRecord]) -> Option<&'a str> {
    records
        .iter()
        .rev()
        .filter(|record| record.outcome == MetadataOutcome::VerifiedApplied)
        .flat_map(|record| &record.after)
        .find(|item| item.asset.key == *key)
        .map(|item| item.values.description.as_str())
}
pub fn validate_records(records: &[MetadataRecord]) -> Result<(), String> {
    let mut ids = std::collections::BTreeSet::new();
    for record in records {
        crate::immich::valid_id(&record.id)?;
        let keys = record
            .keys
            .iter()
            .collect::<std::collections::BTreeSet<_>>();
        if !ids.insert(&record.id)
            || keys.is_empty()
            || keys.len() != record.keys.len()
            || record.before.len() != keys.len()
            || record.member_edits.len() != keys.len()
        {
            return Err("メタデータの変更記録が不正です。".into());
        }
        if record
            .before
            .iter()
            .map(|item| &item.asset.key)
            .collect::<std::collections::BTreeSet<_>>()
            != keys
        {
            return Err("メタデータの元の項目が一致しません。".into());
        }
        for edit in &record.member_edits {
            edit.change()?;
        }
        if record.outcome == MetadataOutcome::VerifiedApplied {
            if record.after.len() != keys.len() {
                return Err("保存結果の項目が不足しています。".into());
            }
            for (key, edit) in record.keys.iter().zip(&record.member_edits) {
                let after = record
                    .after
                    .iter()
                    .find(|item| item.asset.key == *key)
                    .ok_or("保存結果が一致しません。")?;
                if !edit.matches_provider(key.provider, &after.values)? {
                    return Err("保存結果と変更内容が一致しません。".into());
                }
            }
        } else if !record.after.is_empty() {
            return Err("結果不明の記録を成功の証拠にできません。".into());
        }
    }
    Ok(())
}
pub fn validate_record_transition(
    old: &[MetadataRecord],
    new: &[MetadataRecord],
) -> Result<(), String> {
    validate_records(new)?;
    for record in old {
        let fresh = new
            .iter()
            .find(|item| item.id == record.id)
            .ok_or("既存のメタデータ記録を削除できません。")?;
        let mut expected = record.clone();
        expected.current.clone_from(&fresh.current);
        if record.outcome == MetadataOutcome::SubmittedUnknown
            && matches!(
                fresh.outcome,
                MetadataOutcome::VerifiedApplied | MetadataOutcome::NotApplied
            )
        {
            expected.after.clone_from(&fresh.after);
            expected.outcome = fresh.outcome;
        }
        if serde_json::to_value(expected).map_err(|_| "変更記録を検証できません。")?
            != serde_json::to_value(fresh).map_err(|_| "変更記録を検証できません。")?
        {
            return Err("既存のメタデータ変更記録を上書きできません。".into());
        }
    }
    for fresh in new
        .iter()
        .filter(|item| !old.iter().any(|before| before.id == item.id))
    {
        if fresh.outcome != MetadataOutcome::SubmittedUnknown {
            return Err("新しい変更は送信前記録から開始してください。".into());
        }
    }
    Ok(())
}
