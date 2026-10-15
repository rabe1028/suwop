//! Equality for C2 durable readback only. Native JSON may encode an integral
//! f64 field as an integer, but must not change any field, shape, or value.
use serde_json::{Number, Value};

pub(crate) fn matches(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Number(left), Value::Number(right)) => {
            left == right
                || left.is_f64() != right.is_f64()
                    && integer(left)
                        .zip(integer(right))
                        .is_some_and(|(a, b)| a == b)
        }
        (Value::Array(left), Value::Array(right)) => {
            left.len() == right.len() && left.iter().zip(right).all(|(a, b)| matches(a, b))
        }
        (Value::Object(left), Value::Object(right)) => {
            left.len() == right.len()
                && left
                    .iter()
                    .all(|(key, value)| right.get(key).is_some_and(|v| matches(value, v)))
        }
        _ => expected == actual,
    }
}

fn integer(number: &Number) -> Option<i128> {
    if let Some(value) = number.as_i64() {
        return Some(i128::from(value));
    }
    if let Some(value) = number.as_u64() {
        return Some(i128::from(value));
    }
    let bits = number.as_f64()?.to_bits();
    // Both signed zeros represent integer zero. Nonfinite and nonzero
    // subnormal values cannot match a serde_json integer.
    if bits & !(1_u64 << 63) == 0 {
        return Some(0);
    }
    let encoded_exponent = (bits >> 52) & 0x7ff;
    if encoded_exponent == 0 || encoded_exponent == 0x7ff {
        return None;
    }
    let exponent = i32::try_from(encoded_exponent).ok()? - 1023;
    // JSON integers here are i64/u64. Values with their highest bit above
    // bit 63 cannot equal either. This also bounds the left shift to 11 bits.
    if !(0..=63).contains(&exponent) {
        return None;
    }
    let significand = (bits & ((1_u64 << 52) - 1)) | (1_u64 << 52);
    let magnitude = if exponent < 52 {
        let fractional_bits = u32::try_from(52 - exponent).ok()?;
        let mask = (1_u64 << fractional_bits) - 1;
        if significand & mask != 0 {
            return None;
        }
        u128::from(significand >> fractional_bits)
    } else {
        u128::from(significand).checked_shl(u32::try_from(exponent - 52).ok()?)?
    };
    let value = i128::try_from(magnitude).ok()?;
    if bits >> 63 == 1 {
        value.checked_neg()
    } else {
        Some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn float(value: &str) -> Result<Value, String> {
        let value = value.parse::<f64>().map_err(|e| e.to_string())?;
        Number::from_f64(value)
            .map(Value::Number)
            .ok_or("nonfinite test number".into())
    }

    #[test]
    fn typed_asset_dates_reproduce_native_integral_readback_kind_change() -> Result<(), String> {
        let asset: crate::immich::Asset = serde_json::from_value(json!({
            "id":"33333333-3333-4333-8333-333333333333","ownerId":"owner","type":"IMAGE",
            "originalFileName":"fixture.jpg","checksum":"a".repeat(40),
            "fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z",
            "updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,
            "visibility":"timeline","livePhotoVideoId":null,"stack":null
        }))
        .map_err(|e| e.to_string())?;
        let expected =
            serde_json::to_value(asset.record("scope", None, None)).map_err(|e| e.to_string())?;
        let encoded = serde_json::to_string(&expected).map_err(|e| e.to_string())?;
        assert!(encoded.contains("1767225600.0"));
        let actual: Value = serde_json::from_str(&encoded.replace("1767225600.0", "1767225600"))
            .map_err(|e| e.to_string())?;
        assert!(
            expected["capturedAt"]
                .as_number()
                .is_some_and(Number::is_f64)
        );
        assert!(!actual["capturedAt"].as_number().is_some_and(Number::is_f64));
        assert_ne!(expected, actual); // The former persist comparison fails.
        assert!(matches(&expected, &actual));
        assert!(matches(&actual, &expected));
        Ok(())
    }

    #[test]
    fn integer_float_boundaries_are_exact_without_f64_integer_aliases() -> Result<(), String> {
        for (integer, decimal, equal) in [
            (json!(1), "1.0", true),
            (json!(-1), "-1.0", true),
            (json!(0), "-0.0", true),
            (json!(0), "0.0", true),
            (json!(9_007_199_254_740_991_u64), "9007199254740991.0", true),
            (json!(9_007_199_254_740_992_u64), "9007199254740992.0", true),
            (
                json!(9_007_199_254_740_993_u64),
                "9007199254740992.0",
                false,
            ),
            (json!(9_007_199_254_740_994_u64), "9007199254740994.0", true),
            (json!(u64::MAX), "18446744073709551616.0", false),
            (json!(u64::MAX - 2047), "18446744073709549568.0", true),
            (json!(i64::MIN), "-9223372036854775808.0", true),
            (json!(i64::MIN + 1), "-9223372036854775808.0", false),
            (json!(-1), "-1.5", false),
            (json!(0), "5e-324", false),
            (json!(0), "1e100", false),
            (json!(0), "-1e100", false),
        ] {
            let decimal = float(decimal)?;
            assert_eq!(
                matches(&integer, &decimal),
                equal,
                "{integer} versus {decimal}"
            );
            assert_eq!(matches(&decimal, &integer), equal);
        }
        assert!(matches(&float("-0.0")?, &float("0.0")?));
        assert!(matches(&float("0.5")?, &float("0.5")?));
        assert!(!matches(&float("0.5")?, &float("0.5000000000000001")?));
        assert!(!matches(&json!(u64::MAX), &json!(u64::MAX - 1)));
        // Decimal parsing is outside this comparison. If an earlier codec has
        // already changed a numeric value, never repair it with a tolerance.
        let parsed: Value =
            serde_json::from_str("9007199254740991.0").map_err(|e| e.to_string())?;
        let intended = float("9007199254740991.0")?;
        assert_eq!(
            matches(&json!(9_007_199_254_740_991_u64), &parsed),
            parsed == intended
        );
        Ok(())
    }

    #[test]
    fn nested_readback_keeps_every_field_type_and_array_position_strict() -> Result<(), String> {
        let expected = json!({"schemaVersion":7,"snapshots":[{"assets":[{"capturedAt":1_767_225_600.0,"bytes":u64::MAX,"key":"exact","optional":null}]}]});
        let mut actual = expected.clone();
        actual["snapshots"][0]["assets"][0]["capturedAt"] = json!(1_767_225_600_u64);
        assert!(matches(&expected, &actual));
        for replacement in [
            json!("1767225600"),
            json!(true),
            Value::Null,
            json!([]),
            json!({}),
            json!(1_767_225_601_u64),
        ] {
            let mut changed = actual.clone();
            changed["snapshots"][0]["assets"][0]["capturedAt"] = replacement;
            assert!(!matches(&expected, &changed));
        }
        for key in ["unknown", "optional"] {
            let mut changed = actual.clone();
            let asset = changed["snapshots"][0]["assets"][0]
                .as_object_mut()
                .ok_or("asset")?;
            if key == "unknown" {
                asset.insert(key.into(), Value::Null);
            } else {
                asset.remove(key);
            }
            assert!(!matches(&expected, &changed));
        }
        let mut changed = actual.clone();
        changed["snapshots"][0]["assets"][0]["bytes"] = float("18446744073709551616.0")?;
        assert!(!matches(&expected, &changed));
        assert!(!matches(&json!([1, 2]), &json!([2.0, 1.0])));
        assert!(!matches(&json!([1]), &json!([1.0, 2.0])));
        assert!(!matches(&json!({"old":1}), &json!({"new":1.0})));
        Ok(())
    }
}
