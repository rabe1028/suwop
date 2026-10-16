use super::{Deserialize, ERROR, Serialize, Value};
/// App headroom, not an OS requirement or a maximum movie size.
pub const PRIVATE_VIDEO_HEADROOM_BYTES: u64 = 256 * 1024 * 1024;
#[derive(Debug, Clone, Copy, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedVideoCapacityClass {
    ImportantUsage,
    Available,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedVideoStorageFacts {
    #[serde(rename = "leaseID")]
    pub lease_id: String,
    pub measurement_nonce: String,
    pub deadline_unix_milliseconds: u64,
    pub available_bytes: u64,
    /// Only OTHER leases' future, not-yet-allocated commitments.
    pub other_unallocated_bytes: u64,
    pub allocation_unit_bytes: u64,
    pub capacity_class: ImmichLockedVideoCapacityClass,
}
pub(super) fn now_ms() -> Result<u64, String> {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| ERROR)?
            .as_millis(),
    )
    .map_err(|_| ERROR.into())
}
pub(super) fn budget(
    facts: &ImmichLockedVideoStorageFacts,
    expected: Option<u64>,
) -> Result<u64, String> {
    crate::immich::valid_id(&facts.lease_id)?;
    crate::immich::valid_id(&facts.measurement_nonce)?;
    if facts.deadline_unix_milliseconds <= now_ms()? || facts.allocation_unit_bytes == 0 {
        return Err(ERROR.into());
    }
    let usable = facts
        .available_bytes
        .checked_sub(PRIVATE_VIDEO_HEADROOM_BYTES)
        .and_then(|n| n.checked_sub(facts.other_unallocated_bytes))
        .ok_or(ERROR)?;
    let rounded = usable / facts.allocation_unit_bytes * facts.allocation_unit_bytes;
    let maximum = expected.unwrap_or(rounded);
    if maximum == 0 || maximum > rounded {
        return Err("動画を取得する空き容量が不足しています。".into());
    }
    Ok(maximum)
}
pub(super) fn size(raw: &Value) -> Result<Option<u64>, String> {
    let exif = match raw.get("exifInfo") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(exif)) => exif,
        _ => return Err(ERROR.into()),
    };
    match exif.get("fileSizeInByte") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|n| *n > 0)
            .map(Some)
            .ok_or_else(|| ERROR.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn facts(available: u64) -> ImmichLockedVideoStorageFacts {
        ImmichLockedVideoStorageFacts {
            lease_id: "11111111-1111-4111-8111-111111111111".into(),
            measurement_nonce: "22222222-2222-4222-8222-222222222222".into(),
            deadline_unix_milliseconds: u64::MAX,
            available_bytes: available,
            other_unallocated_bytes: 0,
            allocation_unit_bytes: 4096,
            capacity_class: ImmichLockedVideoCapacityClass::ImportantUsage,
        }
    }
    #[test]
    fn known_and_absent_size_share_finite_capacity_budget_without_movie_cap() {
        let f = facts(PRIVATE_VIDEO_HEADROOM_BYTES + 1024 * 1024 * 1024);
        assert_eq!(
            budget(&f, Some(900 * 1024 * 1024)).ok(),
            Some(900 * 1024 * 1024)
        );
        assert_eq!(budget(&f, None).ok(), Some(1024 * 1024 * 1024));
        assert!(budget(&f, Some(1024 * 1024 * 1024 + 1)).is_err());
        assert!(budget(&f, Some(0)).is_err());
    }
    #[test]
    fn headroom_other_unallocated_commitments_rounding_and_expiry_are_enforced() {
        let mut f = facts(PRIVATE_VIDEO_HEADROOM_BYTES + 8193);
        f.other_unallocated_bytes = 4096;
        assert_eq!(budget(&f, None).ok(), Some(4096));
        f.available_bytes = PRIVATE_VIDEO_HEADROOM_BYTES;
        assert!(budget(&f, Some(1)).is_err());
        f.available_bytes = u64::MAX;
        f.other_unallocated_bytes = u64::MAX;
        assert!(budget(&f, None).is_err());
        f = facts(u64::MAX);
        f.allocation_unit_bytes = 0;
        assert!(budget(&f, None).is_err());
        f = facts(u64::MAX);
        f.deadline_unix_milliseconds = 0;
        assert!(budget(&f, None).is_err());
    }
    #[test]
    fn absent_length_is_distinct_from_malformed_supplied_metadata() {
        for raw in [
            json!({}),
            json!({"exifInfo":null}),
            json!({"exifInfo":{}}),
            json!({"exifInfo":{"fileSizeInByte":null}}),
        ] {
            assert_eq!(size(&raw).ok(), Some(None));
        }
        assert_eq!(
            size(&json!({"exifInfo":{"fileSizeInByte":123}})).ok(),
            Some(Some(123))
        );
        for value in [
            json!(0),
            json!(-1),
            json!(1.5),
            json!("123"),
            json!([]),
            json!({}),
            json!(true),
        ] {
            assert!(size(&json!({"exifInfo":{"fileSizeInByte":value}})).is_err());
        }
        assert!(size(&json!({"exifInfo":[]})).is_err());
    }
}
