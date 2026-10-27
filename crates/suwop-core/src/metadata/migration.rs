use serde_json::Value;
/// Schema11 introduces durable metadata intents. Missing current-schema journals
/// and records disguised as an older schema are rejected, never silently erased.
pub fn migrate_journal(raw: &mut Value, version: u64) -> Result<(), String> {
    if version < 11 {
        if raw
            .get("metadataOperations")
            .is_some_and(|value| !value.is_null())
        {
            return Err(
                "旧形式にメタデータ操作記録があります。既存ファイルは変更しません。".into(),
            );
        }
        raw["metadataOperations"] = serde_json::json!([]);
    } else if !raw.get("metadataOperations").is_some_and(Value::is_array) {
        return Err("メタデータ操作記録の構成が不正です。既存ファイルは変更しません。".into());
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn migrates_old_and_rejects_disguised_or_missing_journal() -> Result<(), String> {
        let mut old = serde_json::json!({"schemaVersion":10});
        migrate_journal(&mut old, 10)?;
        assert_eq!(old["metadataOperations"], serde_json::json!([]));
        assert!(migrate_journal(&mut old, 10).is_err());
        let mut current = serde_json::json!({"schemaVersion":11});
        assert!(migrate_journal(&mut current, 11).is_err());
        current["metadataOperations"] = Value::Null;
        assert!(migrate_journal(&mut current, 11).is_err());
        Ok(())
    }
}
