use super::{Asset, HttpResponse, Session, check_status, valid_id};
use crate::{
    app::{Context, ShellOperation, io},
    domain::StoredAsset,
    sharing::verify_current_asset,
};
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EditedImageFile {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    is_edited: bool,
    path: String,
    updated_at: String,
}

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
            Some(true) => self.download_edited_image(ctx, &before, path).await?,
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

    async fn current_edited_file(
        &self,
        ctx: &Context,
        id: &str,
    ) -> Result<EditedImageFile, String> {
        // File-ID download avoids original/preview fallback entirely. The
        // file API's provenance fields are verified for the tested 3.x contract.
        if self.version.major != 3 {
            return Err("このImmich版の編集済み画像の取得は未対応です。".into());
        }
        let files: Vec<EditedImageFile> = self
            .json(
                ctx,
                &format!("asset-files?assetId={id}&type=fullsize&isEdited=true"),
                "GET",
                None,
            )
            .await?;
        let [file] = files.as_slice() else {
            return Err("編集後の全サイズ画像が未生成または重複しています。原本に置き換えず共有を停止しました。".into());
        };
        valid_id(&file.id)?;
        if file.kind != "fullsize"
            || !file.is_edited
            || file.path.is_empty()
            || chrono::DateTime::parse_from_rfc3339(&file.updated_at).is_err()
        {
            return Err("編集後の全サイズ画像の状態を確認できません。".into());
        }
        Ok(file.clone())
    }

    async fn download_edited_image(
        &self,
        ctx: &Context,
        asset: &Asset,
        path: &str,
    ) -> Result<(), String> {
        let file = self.current_edited_file(ctx, &asset.id).await?;
        let mut request = self.request(&format!("asset-files/{}/download", file.id), "GET", None);
        request.download_path = Some(path.into());
        let response: HttpResponse = io(ctx, ShellOperation::Http(request)).await?;
        check_status(response.status)?;
        if response.path.as_deref() != Some(path)
            || self.current_edited_file(ctx, &asset.id).await? != file
        {
            return Err("取得中に編集後の画像ファイルが変わりました。".into());
        }
        Ok(())
    }
}
