use super::{Asset, Session};
use crate::{app::Context, domain::StoredAsset, sharing::verify_current_asset};

#[derive(Debug, Clone)]
pub struct RemoteCurrentImageInput {
    pub asset: Asset,
    pub edits: Option<serde_json::Value>,
}

impl Session {
    pub async fn current_image_input(
        &self,
        ctx: &Context,
        expected: &StoredAsset,
        path: &str,
    ) -> Result<RemoteCurrentImageInput, String> {
        let asset = self.asset(ctx, &expected.key.asset_id).await?;
        verify_current_asset(expected, &asset.record(&self.scope, None, None))?;
        if asset.media_type != "IMAGE" || asset.live_photo_video_id.is_some() || asset.is_offline {
            return Err("現在の静止画の原本を確認できません。".into());
        }
        let edits = match asset.is_edited {
            Some(false) => None,
            Some(true) if self.version.major == 3 => Some(
                self.json(ctx, &format!("assets/{}/edits", asset.id), "GET", None)
                    .await?,
            ),
            _ => return Err("このImmich版の現在の編集を確認できません。".into()),
        };
        // Render from the verified original plus this exact edit series. Never
        // use an asynchronously generated fullsize file as a freshness proof.
        self.download(ctx, &asset.id, path).await?;
        Ok(RemoteCurrentImageInput { asset, edits })
    }

    pub async fn verify_current_image_input(
        &self,
        ctx: &Context,
        input: &RemoteCurrentImageInput,
    ) -> Result<StoredAsset, String> {
        if let Some(edits) = &input.edits {
            let fresh: serde_json::Value = self
                .json(
                    ctx,
                    &format!("assets/{}/edits", input.asset.id),
                    "GET",
                    None,
                )
                .await?;
            if *edits != fresh {
                return Err("書き出し中に現在の編集系列が変わりました。共有していません。".into());
            }
        }
        let fresh = self.asset(ctx, &input.asset.id).await?;
        if fresh.is_edited != input.asset.is_edited
            || fresh.live_photo_video_id != input.asset.live_photo_video_id
        {
            return Err("書き出し中に編集状態が変わりました。共有していません。".into());
        }
        let record = input.asset.record(&self.scope, None, None);
        let fresh = fresh.record(&self.scope, None, None);
        verify_current_asset(&record, &fresh)?;
        Ok(fresh)
    }
}
