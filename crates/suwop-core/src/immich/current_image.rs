use super::Session;
use crate::{app::Context, domain::StoredAsset, sharing::verify_current_asset};

impl Session {
    pub async fn download_current_image(
        &self,
        ctx: &Context,
        expected: &StoredAsset,
        path: &str,
    ) -> Result<StoredAsset, String> {
        let before = self.asset(ctx, &expected.key.asset_id).await?;
        let record = before.record(&self.scope, None, None);
        verify_current_asset(expected, &record)?;
        if before.media_type != "IMAGE" || before.live_photo_video_id.is_some() || before.is_offline
        {
            return Err("この保存先の現在の静止画を取得できません。".into());
        }
        match before.is_edited {
            Some(false) => self.download(ctx, &before.id, path).await?,
            // A stable edited file ID does not bind the generated image to the
            // latest edits. Immich can retain a previous render while its next
            // editor job is pending. Never share it as the current edit result.
            Some(true) => {
                return Err("Immichの最新の編集と生成画像の対応を確認できません。編集後の共有は準備中です。".into());
            }
            None => return Err("この保存先の編集状態を確認できません。".into()),
        }
        let fresh = self.asset(ctx, &before.id).await?;
        if fresh.is_edited != before.is_edited
            || fresh.live_photo_video_id != before.live_photo_video_id
        {
            return Err("取得中にこの保存先の編集状態が変わりました。".into());
        }
        let fresh = fresh.record(&self.scope, None, None);
        verify_current_asset(&record, &fresh)?;
        Ok(fresh)
    }
}
