use crate::{
    domain::{AssetKey, LibrarySnapshot, ResourceRole, StoredAsset},
    immich::Session,
    media::PreviewAccess,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentImageFacts {
    pub content_type: String,
    pub width: u32,
    pub height: u32,
    pub orientation: u32,
    pub frames: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentImageExport {
    pub asset: StoredAsset,
    pub fresh_asset: StoredAsset,
    pub path: String,
    pub image: CurrentImageFacts,
}

/// An explicit physical source is a read. Unique current membership is still
/// required; neither an unavailable source nor a different account is substituted.
pub fn current_image_asset(
    snapshots: &[LibrarySnapshot],
    apple_scope: &str,
    session: Option<&Session>,
    key: &AssetKey,
) -> Result<StoredAsset, String> {
    let photo = crate::domain::catalog(snapshots, &[])
        .into_iter()
        .find(|p| p.assets.iter().any(|a| a.key == *key))
        .ok_or("共有する表示元を確認できません。")?;
    let access = PreviewAccess::new(snapshots, apple_scope, session);
    let choice = access
        .choices(&photo, std::slice::from_ref(key))
        .into_iter()
        .find(|c| c.key == *key && c.selected && c.disabled_reason.is_none())
        .ok_or("共有する表示元にアクセスできません。一覧を更新してください。")?;
    let asset = photo
        .assets
        .into_iter()
        .find(|a| a.key == choice.key)
        .ok_or("共有する写真がありません。")?;
    if asset
        .resources
        .iter()
        .any(|r| matches!(r.role, ResourceRole::Video | ResourceRole::LiveVideo))
        || !asset
            .originals()
            .any(|r| matches!(r.role, ResourceRole::Image | ResourceRole::RawImage))
    {
        return Err("現在の画像の共有は静止画に対応しています。動画・Live Photoは原本の共有を選んでください。".into());
    }
    Ok(asset)
}

pub fn verify_current_image(
    expected: &StoredAsset,
    export: &CurrentImageExport,
    directory: &str,
) -> Result<(), String> {
    verify_current_asset(expected, &export.asset)?;
    verify_current_asset(expected, &export.fresh_asset)?;
    if !super::contains_file(directory, &export.path) {
        return Err(
            "取得中に写真の表示元・状態・保存場所が変わりました。共有していません。".into(),
        );
    }
    let image = &export.image;
    if image.frames != 1
        || !(1..=131_072).contains(&image.width)
        || !(1..=131_072).contains(&image.height)
        || !(1..=8).contains(&image.orientation)
    {
        return Err("共有する静止画の画像情報を確認できません。".into());
    }
    current_image_name(expected, image)?;
    Ok(())
}

pub fn verify_current_asset(expected: &StoredAsset, fresh: &StoredAsset) -> Result<(), String> {
    let manifest = |asset: &StoredAsset| {
        asset
            .originals()
            .map(|r| (r.id.clone(), r.name.clone(), r.role))
            .collect::<Vec<_>>()
    };
    if expected.key != fresh.key
        || expected.revision != fresh.revision
        || expected.name != fresh.name
        || expected.captured_at != fresh.captured_at
        || expected.modified_at != fresh.modified_at
        || expected.is_favorite != fresh.is_favorite
        || expected.latitude != fresh.latitude
        || expected.longitude != fresh.longitude
        || manifest(expected) != manifest(fresh)
    {
        return Err("現在の画像の取得中に写真が変わりました。共有していません。".into());
    }
    Ok(())
}

pub fn current_image_name(
    asset: &StoredAsset,
    image: &CurrentImageFacts,
) -> Result<String, String> {
    let extension = match image.content_type.as_str() {
        "public.jpeg" | "image/jpeg" => "jpg",
        "public.heic" | "image/heic" => "heic",
        "public.heif" | "image/heif" => "heif",
        "public.png" | "image/png" => "png",
        "public.tiff" | "image/tiff" => "tiff",
        "com.adobe.raw-image" | "image/x-adobe-dng" => "dng",
        _ => {
            return Err(
                "この現在の画像の形式を共有できません。原本の共有を選んでください。".into(),
            );
        }
    };
    let safe = super::filename(&asset.name)?;
    let stem = safe.rsplit_once('.').map_or(safe.as_str(), |(s, _)| s);
    super::filename(&format!("{stem}-current.{extension}"))
}
