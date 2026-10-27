//! Read-only discovery over currently authorized physical records. No grouping
//! here constitutes original verification, a Move receipt, or deletion authority.
use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::domain::{
    AssetKey, LibrarySnapshot, ResourceRole, ScanAccess, StoredAsset, normalize_sha1,
};

const GROUP_LIMIT: usize = 100;
const MEMBER_LIMIT: usize = 100;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrganizationDate {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub time_zone: String,
}
impl OrganizationDate {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=9999).contains(&self.year)
            || NaiveDate::from_ymd_opt(self.year, self.month, self.day).is_none()
            || self.time_zone.parse::<chrono_tz::Tz>().is_err()
        {
            return Err("有効な日付とタイムゾーンを指定してください。".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrganizationMember {
    pub key: AssetKey,
    pub revision: String,
    pub name: String,
}
impl From<&StoredAsset> for OrganizationMember {
    fn from(asset: &StoredAsset) -> Self {
        Self {
            key: asset.key.clone(),
            revision: asset.revision.clone(),
            name: asset.name.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PlaceGroup {
    pub id: String,
    /// Centre of a 0.01-degree coordinate cell, not a geocoded place name.
    pub latitude: f64,
    pub longitude: f64,
    pub members: Vec<OrganizationMember>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RecollectionGroup {
    pub year: i32,
    pub members: Vec<OrganizationMember>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateGroup {
    pub id: String,
    pub members: Vec<OrganizationMember>,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrganizationView {
    pub people: crate::organization_people::OrganizationPeopleView,
    pub places: Vec<PlaceGroup>,
    pub recollections: Vec<RecollectionGroup>,
    pub duplicates: Vec<DuplicateGroup>,
    pub reference_date: Option<OrganizationDate>,
    pub error: Option<String>,
    /// Each section is bounded to 100 groups and each group to 100 records.
    pub truncated: bool,
}

type Signature = Vec<(u8, String, u64)>;
fn signature(asset: &StoredAsset) -> Option<Signature> {
    if !asset.fingerprints_complete() {
        return None;
    }
    let mut signature = asset
        .originals()
        .map(|resource| {
            let role = match resource.role {
                ResourceRole::Image => 0,
                ResourceRole::RawImage => 1,
                ResourceRole::Video => 2,
                ResourceRole::LiveVideo => 3,
                ResourceRole::Auxiliary => return None,
            };
            Some((
                role,
                normalize_sha1(resource.sha1.as_deref())?,
                resource.bytes.filter(|bytes| *bytes > 0)?,
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    if signature.is_empty() {
        return None;
    }
    signature.sort(); // Deliberately a multiset: repeated originals retain multiplicity.
    Some(signature)
}
fn members(assets: Vec<&StoredAsset>, truncated: &mut bool) -> Vec<OrganizationMember> {
    if assets.len() > MEMBER_LIMIT {
        *truncated = true;
    }
    assets
        .into_iter()
        .take(MEMBER_LIMIT)
        .map(OrganizationMember::from)
        .collect()
}

fn coordinate_cell(asset: &StoredAsset) -> Option<(i32, i32)> {
    let (latitude, longitude) = (asset.latitude?, asset.longitude?);
    if !latitude.is_finite()
        || !longitude.is_finite()
        || !(-90.0..=90.0).contains(&latitude)
        || !(-180.0..=180.0).contains(&longitude)
    {
        return None;
    }
    #[allow(clippy::cast_possible_truncation)]
    let mut cell = (
        (latitude * 100.0).round() as i32,
        (longitude * 100.0).round() as i32,
    );
    if cell.1 == 18_000 {
        cell.1 = -18_000;
    }
    Some(cell)
}

/// Caller supplies the publication plus exact current ordinary membership.
/// Duplicate/ambiguous physical keys and unavailable snapshots are excluded.
#[must_use]
pub fn project(
    snapshots: &[LibrarySnapshot],
    authorized: &[AssetKey],
    reference: Option<&OrganizationDate>,
    error: Option<&String>,
) -> OrganizationView {
    let allowed: BTreeSet<_> = authorized.iter().collect();
    let mut records = BTreeMap::new();
    for snapshot in snapshots {
        if snapshot.access == ScanAccess::Unavailable {
            continue;
        }
        for asset in &snapshot.assets {
            if allowed.contains(&asset.key)
                && asset.content_visible()
                && !matches!(
                    asset.immich_visibility,
                    Some(
                        crate::immich_visibility::ImmichVisibility::Locked
                            | crate::immich_visibility::ImmichVisibility::Archive
                    )
                )
                && asset.key.provider == snapshot.provider
                && asset.key.scope == snapshot.scope
            {
                records
                    .entry(&asset.key)
                    .and_modify(|entry| *entry = None)
                    .or_insert(Some(asset));
            }
        }
    }
    let mut places: BTreeMap<(i32, i32), Vec<&StoredAsset>> = BTreeMap::new();
    let mut recollections: BTreeMap<i32, Vec<&StoredAsset>> = BTreeMap::new();
    let mut duplicates: BTreeMap<Signature, Vec<&StoredAsset>> = BTreeMap::new();
    let reference = reference.filter(|date| date.validate().is_ok());
    let zone = reference.and_then(|date| date.time_zone.parse::<chrono_tz::Tz>().ok());
    for asset in records
        .into_values()
        .flatten()
        .filter(|asset| !asset.is_offline)
    {
        if let Some(cell) = coordinate_cell(asset) {
            places.entry(cell).or_default().push(asset);
        }
        if let (Some(reference), Some(zone), Some(seconds)) = (reference, zone, asset.captured_at)
            && seconds.is_finite()
            && (-62_135_596_800.0..253_402_300_800.0).contains(&seconds)
        {
            #[allow(clippy::cast_possible_truncation)]
            let date = DateTime::<Utc>::from_timestamp(seconds.floor() as i64, 0);
            if let Some(date) = date.map(|date| date.with_timezone(&zone))
                && date.year() < reference.year
                && date.month() == reference.month
                && date.day() == reference.day
            {
                recollections.entry(date.year()).or_default().push(asset);
            }
        }
        if let Some(signature) = signature(asset) {
            duplicates.entry(signature).or_default().push(asset);
        }
    }
    let mut result = OrganizationView {
        reference_date: reference.cloned(),
        error: error.cloned(),
        ..OrganizationView::default()
    };
    for ((latitude, longitude), assets) in places.into_iter().take(GROUP_LIMIT + 1) {
        let members = members(assets, &mut result.truncated);
        result.places.push(PlaceGroup {
            id: format!("{latitude}:{longitude}"),
            latitude: f64::from(latitude) / 100.0,
            longitude: f64::from(longitude) / 100.0,
            members,
        });
    }
    for (year, assets) in recollections.into_iter().rev().take(GROUP_LIMIT + 1) {
        let members = members(assets, &mut result.truncated);
        result
            .recollections
            .push(RecollectionGroup { year, members });
    }
    for assets in duplicates
        .into_values()
        .filter(|assets| assets.len() > 1)
        .take(GROUP_LIMIT + 1)
    {
        let first = &assets[0].key;
        // A transient UI identity, scoped to a physical member; never persisted.
        let id = serde_json::to_string(first).unwrap_or_default();
        let members = members(assets, &mut result.truncated);
        result.duplicates.push(DuplicateGroup { id, members });
    }
    truncate_groups(&mut result);
    result
}

fn truncate_groups(result: &mut OrganizationView) {
    if [
        result.places.len(),
        result.recollections.len(),
        result.duplicates.len(),
    ]
    .into_iter()
    .any(|length| length > GROUP_LIMIT)
    {
        result.truncated = true;
    }
    result.places.truncate(GROUP_LIMIT);
    result.recollections.truncate(GROUP_LIMIT);
    result.duplicates.truncate(GROUP_LIMIT);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AppleVisibility, ImmichStackState, PhotoResource, Provider};

    fn asset(id: &str) -> StoredAsset {
        StoredAsset {
            key: AssetKey {
                provider: Provider::Apple,
                scope: "scope".into(),
                asset_id: id.into(),
            },
            apple_visibility: AppleVisibility::Visible,
            immich_visibility: None,
            immich_stack: ImmichStackState::Unknown,
            immich_stack_membership: None,
            name: id.into(),
            captured_at: Some(1_577_934_000.0),
            modified_at: None,
            revision: "revision".into(),
            resources: vec![PhotoResource {
                id: "image".into(),
                name: "image.jpg".into(),
                role: ResourceRole::Image,
                sha1: Some("a".repeat(40)),
                bytes: Some(10),
            }],
            is_favorite: false,
            latitude: Some(35.123),
            longitude: Some(139.123),
            inventory_complete: true,
            is_offline: false,
            deletion_blockers: vec![],
        }
    }
    fn project_assets(
        assets: Vec<StoredAsset>,
        reference: Option<&OrganizationDate>,
    ) -> OrganizationView {
        let keys = assets.iter().map(|a| a.key.clone()).collect::<Vec<_>>();
        project(
            &[LibrarySnapshot {
                provider: Provider::Apple,
                scope: "scope".into(),
                assets,
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            }],
            &keys,
            reference,
            None,
        )
    }
    #[test]
    fn duplicate_review_preserves_physical_keys_and_full_original_multiplicity() {
        let first = asset("first");
        let mut matching = asset("matching");
        let mut repeated = asset("repeated");
        repeated.resources.push(repeated.resources[0].clone());
        let mut raw = asset("raw");
        raw.resources[0].role = ResourceRole::RawImage;
        let mut unknown_bytes = asset("unknown_bytes");
        unknown_bytes.resources[0].bytes = None;
        let view = project_assets(
            vec![
                first.clone(),
                matching.clone(),
                repeated,
                raw,
                unknown_bytes,
            ],
            None,
        );
        assert_eq!(view.duplicates.len(), 1);
        assert_eq!(view.duplicates[0].members.len(), 2);
        assert_eq!(view.duplicates[0].members[0].key, first.key);
        assert_eq!(view.duplicates[0].members[1].key, matching.key);
        matching.resources[0].sha1 = Some("matching".repeat(40));
        assert!(
            project_assets(vec![first, matching], None)
                .duplicates
                .is_empty()
        );
    }
    #[test]
    fn authorization_ambiguity_and_unavailable_snapshots_exclude_every_section() {
        let a = asset("a");
        let snapshot = LibrarySnapshot {
            provider: Provider::Apple,
            scope: "scope".into(),
            assets: vec![a.clone()],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        };
        assert!(
            project(std::slice::from_ref(&snapshot), &[], None, None)
                .places
                .is_empty()
        );
        assert!(
            project(
                &[snapshot.clone(), snapshot.clone()],
                std::slice::from_ref(&a.key),
                None,
                None
            )
            .places
            .is_empty()
        );
        let mut unavailable = snapshot;
        unavailable.access = ScanAccess::Unavailable;
        assert!(
            project(&[unavailable], &[a.key], None, None)
                .places
                .is_empty()
        );
    }
    #[test]
    fn recollections_use_source_local_date_and_strictly_past_years() {
        let reference = OrganizationDate {
            year: 2026,
            month: 1,
            day: 2,
            time_zone: "Asia/Tokyo".into(),
        };
        let mut a = asset("a");
        a.captured_at = Some(1_578_006_000.0); // 2020-01-02T23:00Z = Jan 3 in Tokyo
        assert!(
            project_assets(vec![a.clone()], Some(&reference))
                .recollections
                .is_empty()
        );
        a.captured_at = Some(1_577_905_200.0); // 2020-01-01T19:00Z = Jan 2 in Tokyo
        let view = project_assets(vec![a], Some(&reference));
        assert_eq!(view.recollections.len(), 1);
        assert_eq!(view.recollections[0].year, 2020);
        let invalid = OrganizationDate {
            year: 2026,
            month: 2,
            day: 29,
            time_zone: "UTC".into(),
        };
        assert!(invalid.validate().is_err());
        assert!(
            OrganizationDate {
                time_zone: "invalid".into(),
                ..reference
            }
            .validate()
            .is_err()
        );
    }
    #[test]
    fn coordinate_validation_and_member_output_are_bounded() {
        let mut bad = asset("bad");
        bad.latitude = Some(f64::NAN);
        assert!(project_assets(vec![bad], None).places.is_empty());
        let assets = (0..=MEMBER_LIMIT)
            .map(|id| asset(&format!("{id:04}")))
            .collect();
        let view = project_assets(assets, None);
        assert!(view.truncated);
        assert_eq!(view.places[0].members.len(), MEMBER_LIMIT);
        assert_eq!(view.duplicates[0].members.len(), MEMBER_LIMIT);
        assert!((view.places[0].latitude - 35.12).abs() < f64::EPSILON);
    }
    #[test]
    fn organization_app_projection_omits_hidden_protected_and_revoked_records() {
        use crux_core::App;
        let mut model = crate::app::Model::default();
        model.state.apple_scope = "scope".into();
        model.organization_reference = Some(OrganizationDate {
            year: 2026,
            month: 1,
            day: 2,
            time_zone: "UTC".into(),
        });
        let visible = asset("visible");
        let mut hidden = asset("hidden");
        hidden.apple_visibility = AppleVisibility::Hidden;
        let protected = asset("protected");
        model.protection.denied.insert(protected.key.clone());
        model.state.snapshots.push(LibrarySnapshot {
            provider: Provider::Apple,
            scope: "scope".into(),
            assets: vec![visible.clone(), hidden, protected],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        });
        let view = crate::app::Suwop.view(&model);
        assert_eq!(view.organization.places.len(), 1);
        assert_eq!(view.organization.places[0].members.len(), 1);
        assert_eq!(view.organization.places[0].members[0].key, visible.key);
        assert!(view.organization.duplicates.is_empty());
        model.state.snapshots[0].access = ScanAccess::Unavailable;
        assert!(
            crate::app::Suwop
                .view(&model)
                .organization
                .places
                .is_empty()
        );
    }
    #[test]
    fn scopes_and_full_raw_jpeg_and_live_components_are_distinct() {
        let mut a = asset("same-id");
        a.resources.push(PhotoResource {
            id: "raw".into(),
            name: "raw.dng".into(),
            role: ResourceRole::RawImage,
            sha1: Some("b".repeat(40)),
            bytes: Some(20),
        });
        let mut b = a.clone();
        b.key.scope = "other".into();
        let snapshots = vec![
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "scope".into(),
                assets: vec![a.clone()],
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            },
            LibrarySnapshot {
                provider: Provider::Apple,
                scope: "other".into(),
                assets: vec![b.clone()],
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
            },
        ];
        let view = project(&snapshots, &[a.key.clone(), b.key.clone()], None, None);
        assert_eq!(view.duplicates[0].members.len(), 2);
        b.key.scope = "scope".into();
        b.key.asset_id = "partial".into();
        b.resources.remove(0); // shared RAW alone is not a complete match
        assert!(
            project_assets(vec![a.clone(), b.clone()], None)
                .duplicates
                .is_empty()
        );
        b.resources = a.resources.clone();
        b.resources[1].role = ResourceRole::LiveVideo;
        assert!(project_assets(vec![a, b], None).duplicates.is_empty());
    }
    #[test]
    fn locked_and_archived_records_cannot_leak_even_if_caller_lists_their_keys() {
        let mut locked = asset("locked");
        locked.key.provider = Provider::Immich;
        locked.immich_visibility = Some(crate::immich_visibility::ImmichVisibility::Locked);
        let mut archived = locked.clone();
        archived.key.asset_id = "archived".into();
        archived.immich_visibility = Some(crate::immich_visibility::ImmichVisibility::Archive);
        let snapshots = [LibrarySnapshot {
            provider: Provider::Immich,
            scope: "scope".into(),
            assets: vec![locked.clone(), archived.clone()],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        }];
        let view = project(&snapshots, &[locked.key, archived.key], None, None);
        assert!(view.places.is_empty());
        assert!(view.duplicates.is_empty());
    }
    #[test]
    #[ignore = "manual projection scaling measurement"]
    fn organization_projection_scaling() -> Result<(), std::io::Error> {
        use std::io::Write;
        for count in [10_000, 100_000] {
            let assets = (0..count)
                .map(|id| asset(&format!("{id:06}")))
                .collect::<Vec<_>>();
            let started = std::time::Instant::now();
            let view = project_assets(assets, None);
            writeln!(
                std::io::stderr(),
                "organization {count} records: {:?}; places={} duplicates={} members={} truncated={}",
                started.elapsed(),
                view.places.len(),
                view.duplicates.len(),
                view.places[0].members.len(),
                view.truncated
            )?;
            assert!(view.truncated);
            assert_eq!(view.places[0].members.len(), MEMBER_LIMIT);
        }
        Ok(())
    }
}
