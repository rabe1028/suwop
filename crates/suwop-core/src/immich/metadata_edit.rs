use super::{Asset, Session};
use crate::app::Context;
use serde_json::{Value, json};

impl Session {
    pub(crate) async fn metadata_observation(
        &self,
        ctx: &Context,
        id: &str,
    ) -> Result<(Asset, String, Option<String>), String> {
        super::valid_id(id)?;
        let value: Value = self.json(ctx, &format!("assets/{id}"), "GET", None).await?;
        let asset: Asset =
            serde_json::from_value(value.clone()).map_err(|_| "メタデータを読み取れません。")?;
        if asset.id != id
            || asset.owner_id != self.user_id
            || asset.is_trashed
            || asset.visibility.as_deref() == Some("locked")
        {
            return Err("写真の所有者または状態が変わりました。".into());
        }
        let description = value
            .get("exifInfo")
            .and_then(|exif| exif.get("description"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let zone = asset
            .exif_info
            .as_ref()
            .and_then(|exif| exif.time_zone.clone());
        Ok((asset, description, zone))
    }
    pub(crate) async fn write_description(
        &self,
        ctx: &Context,
        id: &str,
        text: &str,
    ) -> Result<(), String> {
        // The caller durably records SubmittedUnknown before this single-member write.
        super::valid_id(id)?;
        let _: Value = self
            .json(
                ctx,
                &format!("assets/{id}"),
                "PUT",
                Some(json!({"description":text})),
            )
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::metadata::{MetadataEdit, MetadataValues};

    fn before() -> MetadataValues {
        MetadataValues {
            captured_at: Some(1_730_615_400.125),
            time_zone: Some("UTC-5".into()),
            latitude: None,
            longitude: None,
            description: "preserved".into(),
        }
    }
    #[test]
    fn capture_date_undo_cannot_invent_missing_timezone() {
        let edit = MetadataEdit::CapturedAt {
            local: "2024-01-01T12:00:00".into(),
            zone: "UTC".into(),
            occurrence: None,
        };
        let mut original = before();
        assert!(edit.restoring(&original).is_ok());
        original.time_zone = None;
        assert!(edit.restoring(&original).is_err());
        assert!(original.time_zone.is_none());
    }
}
