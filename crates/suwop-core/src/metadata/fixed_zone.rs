//! Validate IANA or fixed-offset observations and compare fixed-offset forms.
//! Equivalent offsets are checked at the captured instant; different IANA names
//! remain distinct. Immich provider-zone observation is a separate contract.
use chrono::{DateTime, FixedOffset, Offset, Utc};

#[must_use]
pub fn valid(zone: &str) -> bool {
    zone.parse::<chrono_tz::Tz>().is_ok() || parse(zone).is_some()
}

#[must_use]
pub fn parse(value: &str) -> Option<FixedOffset> {
    let value = value.strip_prefix("UTC")?;
    let (sign, value) = if let Some(value) = value.strip_prefix('+') {
        (1, value)
    } else {
        (-1, value.strip_prefix('-')?)
    };
    let parts = value.split(':').collect::<Vec<_>>();
    if parts.is_empty()
        || parts.len() > 3
        || parts[0].is_empty()
        || parts[0].len() > 2
        || !parts
            .iter()
            .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()))
        || parts.iter().skip(1).any(|part| part.len() != 2)
    {
        return None;
    }
    let hours: i32 = parts[0].parse().ok()?;
    let minutes: i32 = parts.get(1).map_or(Some(0), |part| part.parse().ok())?;
    let seconds: i32 = parts.get(2).map_or(Some(0), |part| part.parse().ok())?;
    if hours > 23 || minutes > 59 || seconds > 59 {
        return None;
    }
    FixedOffset::east_opt(sign * (hours * 3600 + minutes * 60 + seconds))
}

#[must_use]
pub fn equivalent(requested: &str, actual: &str, instant: f64) -> bool {
    if requested == actual {
        return true;
    }
    let Some(actual) = parse(actual) else {
        return false;
    };
    let Ok(requested) = requested.parse::<chrono_tz::Tz>() else {
        return false;
    };
    let Ok(date) = DateTime::parse_from_rfc3339(&crate::immich::date_string(instant)) else {
        return false;
    };
    date.with_timezone(&requested).offset().fix() == actual
}

pub fn format_instant(instant: f64, offset: FixedOffset) -> Result<String, String> {
    let date: DateTime<Utc> = DateTime::parse_from_rfc3339(&crate::immich::date_string(instant))
        .map_err(|_| "日時が不正です。")?
        .with_timezone(&Utc);
    Ok(date
        .with_timezone(&offset)
        .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, false))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn equivalence_is_bound_to_instant_and_only_provider_fixed_representation() {
        assert!(equivalent("America/New_York", "UTC-5", 1_704_067_200.0));
        assert!(!equivalent("America/New_York", "UTC-5", 1_719_792_000.0));
        assert!(equivalent("America/New_York", "UTC-4", 1_719_792_000.0));
        assert!(!equivalent("Asia/Tokyo", "Asia/Seoul", 1_704_067_200.0));
        for invalid in [
            "UTC+24",
            "UTC+9:60",
            "UTC+9:0",
            "UTC9",
            "UTC+",
            "UTC+09:00x",
        ] {
            assert!(parse(invalid).is_none());
            assert!(!equivalent("Asia/Tokyo", invalid, 1_704_067_200.0));
        }
    }
    #[test]
    fn immich_date_contract_preserves_instant_and_records_valid_observed_zone() -> Result<(), String>
    {
        use crate::metadata::{MetadataEdit, MetadataValues};
        let edit = MetadataEdit::CapturedAt {
            local: "2024-11-03T12:30:00.125".into(),
            zone: "Asia/Tokyo".into(),
            occurrence: None,
        };
        let mut actual = MetadataValues {
            captured_at: edit.change()?.and_then(|change| change.captured_at),
            time_zone: Some("America/New_York".into()),
            latitude: None,
            longitude: None,
            description: String::new(),
        };
        assert!(!edit.matches(&actual)?);
        assert!(edit.matches_provider(crate::domain::Provider::Immich, &actual)?);
        assert!(!edit.matches_provider(crate::domain::Provider::Apple, &actual)?);
        actual.captured_at = actual.captured_at.map(|value| value + 1.0);
        assert!(!edit.matches_provider(crate::domain::Provider::Immich, &actual)?);
        actual.captured_at = edit.change()?.and_then(|change| change.captured_at);
        actual.time_zone = Some("invalid/zone".into());
        assert!(!edit.matches_provider(crate::domain::Provider::Immich, &actual)?);
        actual.time_zone = None;
        assert!(!edit.matches_provider(crate::domain::Provider::Immich, &actual)?);
        Ok(())
    }
}
