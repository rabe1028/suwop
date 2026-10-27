use chrono::{DateTime, LocalResult, NaiveDateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Occurrence {
    Earlier,
    Later,
}
pub fn resolve(local: &str, zone: &str, occurrence: Option<Occurrence>) -> Result<f64, String> {
    let wall = NaiveDateTime::parse_from_str(local, "%Y-%m-%dT%H:%M:%S%.f")
        .map_err(|_| "日時は YYYY-MM-DDTHH:MM:SS で入力してください。")?;
    if let Some(offset) = super::fixed_zone::parse(zone) {
        if occurrence.is_some() {
            return Err("固定オフセットに夏時間の重複はありません。".into());
        }
        let date = offset
            .from_local_datetime(&wall)
            .single()
            .ok_or("日時が不正です。")?;
        let value = date
            .timestamp()
            .to_string()
            .parse::<f64>()
            .map_err(|_| "日時が不正です。")?
            + f64::from(date.timestamp_subsec_nanos()) / 1_000_000_000.0;
        if !(-62_135_596_800.0..253_402_300_800.0).contains(&value) {
            return Err("日時は1年から9999年の範囲で指定してください。".into());
        }
        return Ok(value);
    }
    let tz: chrono_tz::Tz = zone
        .parse()
        .map_err(|_| "IANAタイムゾーン名を確認してください。")?;
    let date = match tz.from_local_datetime(&wall) {
        LocalResult::None => {
            return Err("夏時間の切替で存在しない現地日時です。別の日時を選んでください。".into());
        }
        LocalResult::Single(date) => {
            if occurrence.is_some() {
                return Err("この日時には夏時間の重複がありません。".into());
            }
            date
        }
        LocalResult::Ambiguous(a, b) => match occurrence {
            Some(Occurrence::Earlier) => a.min(b),
            Some(Occurrence::Later) => a.max(b),
            None => {
                return Err(
                    "夏時間で二度ある日時です。先の時刻か後の時刻を明示してください。".into(),
                );
            }
        },
    };
    let value = date
        .timestamp()
        .to_string()
        .parse::<f64>()
        .map_err(|_| "日時が不正です。")?
        + f64::from(date.timestamp_subsec_nanos()) / 1_000_000_000.0;
    if !(-62_135_596_800.0..253_402_300_800.0).contains(&value) {
        return Err("日時は1年から9999年の範囲で指定してください。".into());
    }
    Ok(value)
}
pub fn local(instant: f64, zone: &str) -> Result<(String, Option<Occurrence>), String> {
    if !instant.is_finite() {
        return Err("元の日時が不正です。".into());
    }
    let date: DateTime<Utc> = DateTime::parse_from_rfc3339(&crate::immich::date_string(instant))
        .map_err(|_| "元の日時が不正です。")?
        .with_timezone(&Utc);
    if let Some(offset) = super::fixed_zone::parse(zone) {
        return Ok((
            date.with_timezone(&offset)
                .format("%Y-%m-%dT%H:%M:%S%.f")
                .to_string(),
            None,
        ));
    }
    let tz: chrono_tz::Tz = zone.parse().map_err(|_| "元のタイムゾーンが不正です。")?;
    let wall = date.with_timezone(&tz).naive_local();
    let occurrence = match tz.from_local_datetime(&wall) {
        LocalResult::Ambiguous(a, b) => Some(if date == a.min(b).with_timezone(&Utc) {
            Occurrence::Earlier
        } else {
            Occurrence::Later
        }),
        _ => None,
    };
    Ok((wall.format("%Y-%m-%dT%H:%M:%S%.f").to_string(), occurrence))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_dst_and_fractional_offsets() -> Result<(), String> {
        assert!(resolve("2024-03-10T02:30:00", "America/New_York", None).is_err());
        assert!(resolve("2024-11-03T01:30:00", "America/New_York", None).is_err());
        let a = resolve(
            "2024-11-03T01:30:00",
            "America/New_York",
            Some(Occurrence::Earlier),
        )?;
        let b = resolve(
            "2024-11-03T01:30:00",
            "America/New_York",
            Some(Occurrence::Later),
        )?;
        assert!((b - a - 3600.0).abs() < f64::EPSILON);
        assert!(resolve("2024-01-01T12:00:00", "Asia/Kathmandu", None).is_ok());
        assert!(resolve("2024-02-30T12:00:00", "UTC", None).is_err());
        assert!(resolve("2024-01-01T12:00:00", "not/a-zone", None).is_err());
        Ok(())
    }
}

#[cfg(test)]
mod fixed_tests {
    #[test]
    fn observed_fixed_zone_round_trips_for_undo_without_inventing_an_iana_name()
    -> Result<(), String> {
        let instant = super::resolve("2024-11-03T01:30:00.125", "UTC-4", None)?;
        let (local, occurrence) = super::local(instant, "UTC-4")?;
        assert_eq!(local, "2024-11-03T01:30:00.125");
        assert!(occurrence.is_none());
        assert!(super::resolve(&local, "UTC-4", Some(super::Occurrence::Earlier)).is_err());
        assert!((super::resolve(&local, "UTC-5", None)? - instant - 3600.0).abs() < f64::EPSILON);
        Ok(())
    }
}
