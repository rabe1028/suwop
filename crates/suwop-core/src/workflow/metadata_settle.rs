//! Read-only settling of our own Immich metadata write. Sidecar extraction may
//! advance updatedAt and recalculate the observed zone for date/location writes.
//! Other witnessed fields remain exact; drift or failure retains durable unknown.
use super::{MetadataWitness, Runtime, same_witnesses};
use crate::{
    app::{ShellOperation, io},
    domain::AssetKey,
};

pub(super) async fn after_write(
    runtime: &Runtime<'_>,
    keys: &[AssetKey],
    mut expected: Vec<MetadataWitness>,
    edits: &[crate::metadata::MetadataEdit],
) -> Result<Vec<MetadataWitness>, String> {
    let mut stable = 0;
    for _ in 0..20 {
        let _: serde_json::Value =
            io(runtime.ctx, ShellOperation::Wait { milliseconds: 500 }).await?;
        let observed = runtime.metadata_witnesses(keys).await?;
        let mut normalized = observed.clone();
        for fresh in &mut normalized {
            if let Some(previous) = expected.iter().find(|old| old.asset.key == fresh.asset.key) {
                fresh.asset.revision.clone_from(&previous.asset.revision);
                if let Some(index) = keys.iter().position(|key| *key == fresh.asset.key)
                    && edits
                        .get(index)
                        .is_some_and(|edit| matches!(edit.field(), "location" | "date"))
                    && provider_observed_zone(&previous.values, &fresh.values)
                {
                    fresh
                        .values
                        .time_zone
                        .clone_from(&previous.values.time_zone);
                }
            }
        }
        // Only this post-submission settling window permits revision movement.
        // Restore admission and every subsequent write still compare it exactly.
        same_witnesses(&expected, &normalized)?;
        stable = if same_witnesses(&expected, &observed).is_ok() {
            stable + 1
        } else {
            0
        };
        expected = observed;
        if stable == 4 {
            return Ok(expected);
        }
    }
    Err("変更後のメタデータが安定していません。結果不明のまま保持し、再送しません。".into())
}

/// A provider write may change only the selected metadata field, independently
/// of whether its requested value was observed successfully.
pub(super) fn unchanged_fields(
    before: &crate::metadata::MetadataValues,
    after: &crate::metadata::MetadataValues,
    edit: &crate::metadata::MetadataEdit,
    provider: crate::domain::Provider,
) -> Result<(), String> {
    let field = edit.field();
    let derived_zone = provider == crate::domain::Provider::Immich
        && field == "location"
        && provider_observed_zone(before, after);
    if (field != "date"
        && (before.captured_at != after.captured_at
            || (!derived_zone && before.time_zone != after.time_zone)))
        || (field != "location"
            && (before.latitude != after.latitude || before.longitude != after.longitude))
        || (field != "description" && before.description != after.description)
    {
        return Err(
            "指定していないメタデータも変化しました。結果不明として保持し、再送しません。".into(),
        );
    }
    Ok(())
}

// Immich sidecar extraction may recompute the display zone from GPS. This is an observed provider
// result, not a requested timezone value. The absolute instant remains exact.
fn provider_observed_zone(
    before: &crate::metadata::MetadataValues,
    after: &crate::metadata::MetadataValues,
) -> bool {
    before.captured_at == after.captured_at
        && after
            .time_zone
            .as_deref()
            .is_some_and(crate::metadata::fixed_zone::valid)
}

#[cfg(test)]
mod tests {
    use super::unchanged_fields;
    use crate::metadata::{MetadataEdit, MetadataValues};

    #[test]
    fn selected_change_never_authorizes_collateral_metadata_drift() {
        let before = MetadataValues {
            captured_at: Some(1.0),
            time_zone: Some("Asia/Tokyo".into()),
            latitude: Some(35.0),
            longitude: Some(139.0),
            description: "original".into(),
        };
        let mut after = before.clone();
        after.description = "new caption".into();
        let caption = MetadataEdit::Description {
            text: after.description.clone(),
        };
        assert!(
            unchanged_fields(&before, &after, &caption, crate::domain::Provider::Apple).is_ok()
        );
        after.latitude = None;
        assert!(
            unchanged_fields(&before, &after, &caption, crate::domain::Provider::Apple).is_err()
        );
        let mut after = before.clone();
        after.latitude = Some(37.0);
        after.longitude = Some(-122.0);
        let location = MetadataEdit::Location {
            latitude: "37".into(),
            longitude: "-122".into(),
        };
        assert!(
            unchanged_fields(&before, &after, &location, crate::domain::Provider::Apple).is_ok()
        );
        after.time_zone = Some("America/Los_Angeles".into());
        assert!(
            unchanged_fields(&before, &after, &location, crate::domain::Provider::Apple).is_err()
        );
        let mut after = before.clone();
        after.captured_at = Some(2.0);
        after.time_zone = Some("UTC".into());
        let date = MetadataEdit::CapturedAt {
            local: "2024-01-01T00:00:00".into(),
            zone: "UTC".into(),
            occurrence: None,
        };
        assert!(unchanged_fields(&before, &after, &date, crate::domain::Provider::Apple).is_ok());
        after.description.clear();
        assert!(unchanged_fields(&before, &after, &date, crate::domain::Provider::Apple).is_err());
    }
    #[test]
    fn immich_location_zone_is_observed_but_never_allows_instant_or_other_field_changes() {
        let before = MetadataValues {
            captured_at: Some(1_704_067_200.0),
            time_zone: Some("UTC-5".into()),
            latitude: None,
            longitude: None,
            description: "unchanged".into(),
        };
        let mut after = before.clone();
        after.time_zone = Some("America/Los_Angeles".into());
        let edit = MetadataEdit::Location {
            latitude: "37.7749".into(),
            longitude: "-122.4194".into(),
        };
        let check = |after: &MetadataValues| {
            unchanged_fields(&before, after, &edit, crate::domain::Provider::Immich)
        };
        assert!(check(&after).is_ok());
        after.captured_at = Some(1_704_067_201.0);
        assert!(check(&after).is_err());
        after.captured_at = before.captured_at;
        after.time_zone = Some("not/a-zone".into());
        assert!(check(&after).is_err());
        after.time_zone = None;
        assert!(check(&after).is_err());
        after.time_zone = Some("UTC-8".into());
        after.description = "concurrent change".into();
        assert!(check(&after).is_err());
    }
}
