use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferReceipt, UnifiedPhoto,
    normalize_sha1, same_location,
};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum MetadataAction {
    SetCapturedAt,
    SetLocation,
    RemoveLocation,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetadataInput {
    pub action: MetadataAction,
    pub captured_at: Option<f64>,
    pub time_zone: Option<String>,
    pub latitude: Option<String>,
    pub longitude: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct Coordinates {
    pub latitude: f64,
    pub longitude: f64,
}

/// A validated, single-field change. Absence of location means removal only
/// for `RemoveLocation`; absent fields never erase unrelated metadata.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataChange {
    pub action: MetadataAction,
    pub captured_at: Option<f64>,
    pub time_zone: Option<String>,
    pub location: Option<Coordinates>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MetadataTarget {
    pub id: String,
    pub provider: Provider,
    pub keys: Vec<AssetKey>,
    pub captured_at: Option<f64>,
    pub dates_vary: bool,
    pub location: Option<Coordinates>,
    pub locations_vary: bool,
    pub can_remove_location: bool,
    pub disabled_reason: Option<String>,
}

#[must_use]
pub fn targets(photo: &UnifiedPhoto, snapshots: &[LibrarySnapshot]) -> Vec<MetadataTarget> {
    MetadataAccess::new(snapshots).targets(photo)
}

/// Index each full-access snapshot separately; never combine partial inventories.
pub(crate) struct MetadataAccess<'a> {
    snapshots: Vec<SnapshotKeys<'a>>,
}
struct SnapshotKeys<'a> {
    snapshot: &'a LibrarySnapshot,
    keys: BTreeSet<&'a AssetKey>,
}
impl<'a> MetadataAccess<'a> {
    pub(crate) fn new(snapshots: &'a [LibrarySnapshot]) -> Self {
        Self {
            snapshots: snapshots
                .iter()
                .filter(|s| s.access == ScanAccess::Full)
                .map(|snapshot| SnapshotKeys {
                    snapshot,
                    keys: snapshot.assets.iter().map(|a| &a.key).collect(),
                })
                .collect(),
        }
    }
    pub(crate) fn targets(&self, photo: &UnifiedPhoto) -> Vec<MetadataTarget> {
        let mut groups: BTreeMap<_, Vec<_>> = BTreeMap::new();
        for asset in &photo.assets {
            groups
                .entry((asset.key.provider, &asset.key.scope))
                .or_default()
                .push(asset);
        }
        groups
            .into_iter()
            .map(|((provider, scope), assets)| {
                let first = assets[0];
                let keys: Vec<_> = assets.iter().map(|a| a.key.clone()).collect();
                let dates_vary = assets.iter().any(|a| {
                    a.captured_at.map(f64::to_bits) != first.captured_at.map(f64::to_bits)
                });
                let locations_vary = assets.iter().any(|a| !same_location(first, a));
                let accessible = self.snapshots.iter().any(|entry| {
                    entry.snapshot.provider == provider
                        && entry.snapshot.scope == *scope
                        && keys.iter().all(|key| entry.keys.contains(key))
                });
                MetadataTarget {
                    id: format!("{provider:?}|{scope}"),
                    provider,
                    keys,
                    captured_at: (!dates_vary).then_some(first.captured_at).flatten(),
                    dates_vary,
                    location: (!locations_vary)
                        .then(|| {
                            first
                                .latitude
                                .zip(first.longitude)
                                .map(|(latitude, longitude)| Coordinates {
                                    latitude,
                                    longitude,
                                })
                        })
                        .flatten(),
                    locations_vary,
                    can_remove_location: provider == Provider::Apple && accessible,
                    disabled_reason: (!accessible).then(|| {
                        if provider == Provider::Apple {
                "日時・位置情報の変更には Apple Photos のフルアクセスと最新の一覧が必要です。"
            } else { "Immich の一覧を更新してアクセスを確認してください。" }.into()
                    }),
                }
            })
            .collect()
    }
}

pub fn normalize(input: &MetadataInput) -> Result<MetadataChange, String> {
    let mut change = MetadataChange {
        action: input.action,
        captured_at: None,
        time_zone: None,
        location: None,
    };
    match input.action {
        MetadataAction::SetCapturedAt => {
            if input.latitude.is_some() || input.longitude.is_some() {
                return Err("日時と位置情報は別々に変更してください。".into());
            }
            let value = input
                .captured_at
                .ok_or("変更する日時を指定してください。")?;
            if !value.is_finite() || !(-62_135_596_800.0..253_402_300_800.0).contains(&value) {
                return Err("日時は1年から9999年の範囲で指定してください。".into());
            }
            let zone = input
                .time_zone
                .as_deref()
                .ok_or("日時のタイムゾーンを指定してください。")?;
            zone.parse::<chrono_tz::Tz>()
                .map_err(|_| "日時のタイムゾーンを確認できません。")?;
            change.captured_at = Some(value);
            change.time_zone = Some(zone.into());
        }
        MetadataAction::SetLocation => {
            if input.captured_at.is_some() || input.time_zone.is_some() {
                return Err("日時と位置情報は別々に変更してください。".into());
            }
            change.location = Some(Coordinates {
                latitude: coordinate(input.latitude.as_deref(), 90.0, "緯度")?,
                longitude: coordinate(input.longitude.as_deref(), 180.0, "経度")?,
            });
        }
        MetadataAction::RemoveLocation => {
            if input.captured_at.is_some()
                || input.time_zone.is_some()
                || input.latitude.is_some()
                || input.longitude.is_some()
            {
                return Err("位置情報の削除に新しい日時・座標を含めないでください。".into());
            }
        }
    }
    Ok(change)
}

fn coordinate(input: Option<&str>, limit: f64, label: &str) -> Result<f64, String> {
    let value = input
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|v| v.is_finite() && (-limit..=limit).contains(v));
    value.ok_or_else(|| format!("{label}は -{limit}〜{limit} の数値で指定してください。"))
}

/// Mutate one complete provider/scope group of one displayed photo, the same
/// grouping its targets were offered from. A caller cannot silently edit only a
/// Live companion or one half of a RAW/JPEG pair.
pub fn prepare(
    snapshots: &[LibrarySnapshot],
    receipts: &[TransferReceipt],
    keys: &[AssetKey],
    input: &MetadataInput,
) -> Result<(MetadataTarget, MetadataChange), String> {
    let requested: BTreeSet<_> = keys.iter().collect();
    if requested.is_empty() {
        return Err("変更する写真と保存先を選択してください。".into());
    }
    let photos = crate::display_catalog::photos(snapshots, receipts);
    let selected: Vec<_> = photos
        .iter()
        .filter(|p| p.assets.iter().any(|a| requested.contains(&a.key)))
        .collect();
    let [photo] = selected.as_slice() else {
        return Err("変更する写真を1件選択してください。".into());
    };
    let target = targets(photo, snapshots)
        .into_iter()
        .find(|t| t.keys.iter().collect::<BTreeSet<_>>() == requested)
        .ok_or("写真の保存先・構成が変わっています。一覧を更新してください。")?;
    if let Some(reason) = &target.disabled_reason {
        return Err(reason.clone());
    }
    let change = normalize(input)?;
    if change.action == MetadataAction::RemoveLocation && !target.can_remove_location {
        return Err("この保存先では位置情報の削除に対応していません。".into());
    }
    Ok((target, change))
}

pub fn verify(
    records: &[StoredAsset],
    keys: &[AssetKey],
    change: &MetadataChange,
) -> Result<(), String> {
    let returned: BTreeSet<_> = records.iter().map(|a| &a.key).collect();
    let expected: BTreeSet<_> = keys.iter().collect();
    if records.len() != keys.len()
        || returned.len() != records.len()
        || returned != expected
        || records.iter().any(|a| !matches_change(a, change))
    {
        return Err("日時・位置情報の保存結果を確認できません。一覧を更新してください。".into());
    }
    Ok(())
}

fn matches_change(asset: &StoredAsset, change: &MetadataChange) -> bool {
    match change.action {
        MetadataAction::SetCapturedAt => asset
            .captured_at
            .zip(change.captured_at)
            .is_some_and(|(actual, expected)| crate::domain::same_capture_date(actual, expected)),
        MetadataAction::SetLocation | MetadataAction::RemoveLocation => {
            let mut expected = asset.clone();
            expected.latitude = change.location.as_ref().map(|p| p.latitude);
            expected.longitude = change.location.as_ref().map(|p| p.longitude);
            same_location(asset, &expected)
        }
    }
}

/// Successful `PhotoKit` property writes keep the immutable originals. Reuse
/// their verified fingerprints only for an identical, complete inventory;
/// never reuse the old revision or override a new fingerprint observation.
pub(crate) fn preserve_original_fingerprints(old: &StoredAsset, fresh: &mut StoredAsset) {
    if old.key.provider != Provider::Apple
        || old.key != fresh.key
        || !old.inventory_complete
        || old.is_offline
        || !fresh.inventory_complete
        || fresh.is_offline
        || old.resources.len() != fresh.resources.len()
    {
        return;
    }
    let cached: BTreeMap<_, _> = old.resources.iter().map(|r| (&r.id, r)).collect();
    let observed: BTreeSet<_> = fresh.resources.iter().map(|r| &r.id).collect();
    if cached.len() != old.resources.len()
        || observed.len() != fresh.resources.len()
        || fresh.resources.iter().any(|r| {
            r.sha1.is_some()
                || r.bytes.is_some()
                || cached
                    .get(&r.id)
                    .is_none_or(|c| c.name != r.name || c.role != r.role)
        })
    {
        return;
    }
    for resource in &mut fresh.resources {
        if let Some(original) = cached
            .get(&resource.id)
            .filter(|r| r.role.is_original() && normalize_sha1(r.sha1.as_deref()).is_some())
        {
            resource.sha1.clone_from(&original.sha1);
            resource.bytes = original.bytes;
        }
    }
}

impl MetadataChange {
    pub fn immich_fields(&self) -> Result<serde_json::Value, String> {
        match self.action {
            MetadataAction::SetCapturedAt => {
                let value = self.captured_at.ok_or("日時がありません。")?;
                let zone = self
                    .time_zone
                    .as_deref()
                    .ok_or("タイムゾーンがありません。")?;
                let zone: chrono_tz::Tz = zone.parse().map_err(|_| "タイムゾーンが不正です。")?;
                // Keep the instant in UTC. Historical IANA offsets can include
                // seconds that RFC 3339 offsets cannot represent exactly.
                let date = crate::immich::date_string(value);
                if date.is_empty() {
                    return Err("日時が不正です。".into());
                }
                Ok(serde_json::json!({ "dateTimeOriginal": date, "timeZone": zone.name() }))
            }
            MetadataAction::SetLocation => {
                let point = self.location.as_ref().ok_or("位置情報がありません。")?;
                Ok(serde_json::json!({"latitude":point.latitude,"longitude":point.longitude}))
            }
            MetadataAction::RemoveLocation => {
                Err("Immich の位置情報削除は対応していません。".into())
            }
        }
    }
}
