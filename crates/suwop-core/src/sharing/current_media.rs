//! Current rendered movies / complete Live pairs. No original substitution on ambiguity.
use crate::{
    domain::{AssetKey, LibrarySnapshot, ResourceRole, StoredAsset},
    immich::Session,
    media::{PlaybackKind, PreviewAccess},
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentMediaFile {
    pub path: String,
    pub role: ResourceRole,
    pub content_identifier: Option<String>,
    pub has_location: bool,
    pub has_still_image_time: bool,
    pub duration_ms: u64,
    pub video_tracks: u32,
    pub audio_tracks: u32,
    pub metadata_tracks: u32,
    #[serde(default)]
    pub only_pair_metadata: bool,
    pub image: Option<super::CurrentImageFacts>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentMediaExport {
    pub asset: StoredAsset,
    pub fresh_asset: StoredAsset,
    pub kind: PlaybackKind,
    pub files: Vec<CurrentMediaFile>,
    pub input_duration_ms: u64,
    pub input_video_tracks: u32,
    pub input_audio_tracks: u32,
    pub location_removed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CurrentMovieOutput {
    pub file: CurrentMediaFile,
    pub input_duration_ms: u64,
    pub input_video_tracks: u32,
    pub input_audio_tracks: u32,
}

pub fn current_media_source(
    snapshots: &[LibrarySnapshot],
    apple_scope: &str,
    session: Option<&Session>,
    key: &AssetKey,
) -> Result<StoredAsset, String> {
    let photo = crate::domain::catalog(snapshots, &[])
        .into_iter()
        .find(|p| p.assets.iter().any(|a| a.key == *key))
        .ok_or("共有する表示元がありません。")?;
    let access = PreviewAccess::new(snapshots, apple_scope, session);
    if !access
        .choices(&photo, std::slice::from_ref(key))
        .iter()
        .any(|c| c.key == *key && c.selected && c.disabled_reason.is_none())
    {
        return Err("現在の内容を取得できません。一覧を更新してください。".into());
    }
    let live = crate::media::kind(&photo) == Some(PlaybackKind::Live);
    let asset = photo
        .assets
        .into_iter()
        .find(|a| a.key == *key)
        .ok_or("共有する表示元がありません。")?;
    if live && current_media_kind(&asset) != Some(PlaybackKind::Live) {
        return Err(
            "Live の一部だけでは共有しません。完全なペアを持つ表示元を選んでください。".into(),
        );
    }
    if current_media_kind(&asset).is_none()
        && (asset
            .resources
            .iter()
            .any(|r| matches!(r.role, ResourceRole::Video | ResourceRole::LiveVideo))
            || !asset
                .originals()
                .any(|r| matches!(r.role, ResourceRole::Image | ResourceRole::RawImage)))
    {
        return Err(
            "現在のメディアの完全な構成を確認できません。原本の共有を選んでください。".into(),
        );
    }
    Ok(asset)
}

#[must_use]
pub fn current_media_kind(asset: &StoredAsset) -> Option<PlaybackKind> {
    let count = |role| asset.resources.iter().filter(|r| r.role == role).count();
    match (count(ResourceRole::Video), count(ResourceRole::LiveVideo)) {
        (1, 0) => Some(PlaybackKind::Video),
        (0, 1) if count(ResourceRole::Image) == 1 => Some(PlaybackKind::Live),
        _ => None,
    }
}

pub fn verify_current_media(
    expected: &StoredAsset,
    export: &CurrentMediaExport,
    directory: &str,
    remove_location: bool,
) -> Result<(), String> {
    super::verify_current_asset(expected, &export.asset)?;
    super::verify_current_asset(expected, &export.fresh_asset)?;
    if current_media_kind(expected) != Some(export.kind)
        || export.location_removed != remove_location
        || export
            .files
            .iter()
            .any(|f| !super::contains_file(directory, &f.path))
        || export
            .files
            .iter()
            .map(|f| &f.path)
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            != export.files.len()
    {
        return Err("現在のメディアの表示元・構成・出力先が一致しません。".into());
    }
    let video = export
        .files
        .iter()
        .filter(|f| matches!(f.role, ResourceRole::Video | ResourceRole::LiveVideo))
        .collect::<Vec<_>>();
    let [video] = video.as_slice() else {
        return Err("現在の動画資源を一つ確認できません。".into());
    };
    if video.duration_ms == 0
        || export.input_duration_ms.abs_diff(video.duration_ms) > 2
        || video.video_tracks != export.input_video_tracks
        || video.audio_tracks != export.input_audio_tracks
        || video.video_tracks == 0
    {
        return Err("現在の動画の長さまたは音声・映像trackが一致しません。".into());
    }
    if remove_location
        && export.files.iter().any(|f| {
            f.has_location
                || f.metadata_tracks != 0
                    && !(export.kind == PlaybackKind::Live
                        && f.role == ResourceRole::LiveVideo
                        && f.only_pair_metadata
                        && f.has_still_image_time)
        })
    {
        return Err("位置情報なしの出力を確認できません。共有していません。".into());
    }
    match export.kind {
        PlaybackKind::Video if export.files.len() == 1 && video.role == ResourceRole::Video => {
            Ok(())
        }
        PlaybackKind::Live if export.files.len() == 2 && video.role == ResourceRole::LiveVideo => {
            let image = export
                .files
                .iter()
                .find(|f| f.role == ResourceRole::Image)
                .ok_or("Liveの静止画がありません。")?;
            let facts = image.image.as_ref().ok_or("Live静止画を検査できません。")?;
            if image
                .content_identifier
                .as_ref()
                .is_none_or(String::is_empty)
                || image.content_identifier != video.content_identifier
                || !video.has_still_image_time
                || facts.frames != 1
                || facts.width == 0
                || facts.height == 0
            {
                return Err("Liveの関連ID・静止画時刻・完全なペアを確認できません。".into());
            }
            Ok(())
        }
        _ => Err("現在のメディアが不完全です。原本の共有を選んでください。".into()),
    }
}
