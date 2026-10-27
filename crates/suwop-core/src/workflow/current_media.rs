use super::{HashResult, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, ResourceRole},
    sharing::{
        CurrentMediaExport, ShareFile, current_media_kind, current_media_source,
        verify_current_media,
    },
};

impl Runtime<'_> {
    pub(super) async fn export_current_media(
        &mut self,
        key: &AssetKey,
        index: usize,
        remove_location: bool,
    ) -> Result<Vec<ShareFile>, String> {
        self.check_keys(std::slice::from_ref(key))?;
        let expected = current_media_source(
            &self.state.snapshots,
            &self.state.apple_scope,
            self.session.as_ref(),
            key,
        )?;
        let Some(kind) = current_media_kind(&expected) else {
            return Ok(vec![
                self.export_current_image(key, index, remove_location)
                    .await?,
            ]);
        };
        let directory = self.directory(&format!("share-current-media-{index}"))?;
        let export: CurrentMediaExport = if key.provider == Provider::Apple {
            io(
                self.ctx,
                ShellOperation::AppleCurrentMedia {
                    asset: expected.clone(),
                    directory: directory.clone(),
                    remove_location,
                },
            )
            .await?
        } else {
            self.remote_current_media(&expected, index, &directory, remove_location)
                .await?
        };
        verify_current_media(&expected, &export, &directory, remove_location)?;
        if export.kind != kind {
            return Err("メディアの種類が変わっています。".into());
        }
        let safe = crate::sharing::filename(&expected.name)?;
        let stem = safe
            .rsplit_once('.')
            .map_or(safe.as_str(), |(stem, _)| stem);
        let mut result = vec![];
        for (part, file) in export.files.into_iter().enumerate() {
            let before: HashResult = io(
                self.ctx,
                ShellOperation::HashFile {
                    path: file.path.clone(),
                },
            )
            .await?;
            if !before.signature.valid() {
                return Err("現在のメディアのバイト列を確認できません。".into());
            }
            let extension = if matches!(file.role, ResourceRole::Video | ResourceRole::LiveVideo) {
                "mov"
            } else {
                match file.image.as_ref().map(|i| i.content_type.as_str()) {
                    Some("public.jpeg" | "image/jpeg") => "jpg",
                    Some("public.heic" | "image/heic" | "public.heif" | "image/heif") => "heic",
                    _ => return Err("Live静止画の形式を共有できません。".into()),
                }
            };
            let name = crate::sharing::filename(&format!("{stem}-current.{extension}"))?;
            let path = format!(
                "{}/{name}",
                self.directory(&format!("share-current-media-ready-{index}-{part}"))?
            );
            let _: serde_json::Value = io(
                self.ctx,
                ShellOperation::CopyFile {
                    source: file.path,
                    destination: path.clone(),
                },
            )
            .await?;
            let after: HashResult =
                io(self.ctx, ShellOperation::HashFile { path: path.clone() }).await?;
            if before.signature != after.signature || before.sha1 != after.sha1 {
                return Err("共有用メディアのコピーが一致しません。".into());
            }
            result.push(ShareFile { path, name });
        }
        self.check_content_generation(std::slice::from_ref(key))?;
        Ok(result)
    }

    async fn remote_current_media(
        &mut self,
        expected: &crate::domain::StoredAsset,
        index: usize,
        directory: &str,
        remove_location: bool,
    ) -> Result<CurrentMediaExport, String> {
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        let before = session.asset(self.ctx, &expected.key.asset_id).await?;
        if before.is_edited != Some(false) {
            return Err("編集済み・編集状態不明の動画/Liveの現在内容は確認できません。原本の共有を選んでください。".into());
        }
        let kind = current_media_kind(expected).ok_or("動画/Liveではありません。")?;
        let companion = if let Some(id) = &before.live_photo_video_id {
            let asset: crate::immich::Asset = session
                .json(self.ctx, &format!("assets/{id}"), "GET", None)
                .await?;
            if asset.id != *id
                || asset.owner_id != session.user_id
                || asset.is_edited != Some(false)
                || asset.media_type != "VIDEO"
                || asset.is_trashed
                || asset.visibility.as_deref() == Some("locked")
            {
                return Err("Live関連動画の無編集・所有権を確認できません。".into());
            }
            Some(asset)
        } else {
            None
        };
        crate::sharing::verify_current_asset(
            expected,
            &before.record(&session.scope, companion.as_ref(), None),
        )?;
        let bundle = self
            .export(
                std::slice::from_ref(&expected.key),
                &format!("current-media-original-{index}"),
            )
            .await?;
        let (mut files, duration, video_tracks, audio_tracks) = self
            .remote_current_files(&bundle, kind, directory, remove_location)
            .await?;
        if kind == crate::media::PlaybackKind::Live && remove_location {
            files = io(
                self.ctx,
                ShellOperation::PrepareCurrentLive {
                    files,
                    directory: format!("{directory}/without-location"),
                },
            )
            .await?;
        }
        let after = session.asset(self.ctx, &expected.key.asset_id).await?;
        if after.is_edited != Some(false) || after.live_photo_video_id != before.live_photo_video_id
        {
            return Err("取得中に現在の編集が変わりました。".into());
        }
        let fresh_companion = if let Some(old) = &companion {
            let fresh: crate::immich::Asset = session
                .json(self.ctx, &format!("assets/{}", old.id), "GET", None)
                .await?;
            if fresh.id != old.id
                || fresh.owner_id != old.owner_id
                || fresh.updated_at != old.updated_at
                || fresh.checksum != old.checksum
                || fresh.is_edited != Some(false)
                || fresh.is_trashed
                || fresh.visibility != old.visibility
            {
                return Err("取得中にLive関連動画が変わりました。".into());
            }
            Some(fresh)
        } else {
            None
        };
        Ok(CurrentMediaExport {
            asset: before.record(&session.scope, companion.as_ref(), None),
            fresh_asset: after.record(&session.scope, fresh_companion.as_ref(), None),
            kind,
            files,
            input_duration_ms: duration,
            input_video_tracks: video_tracks,
            input_audio_tracks: audio_tracks,
            location_removed: remove_location,
        })
    }
    async fn remote_current_files(
        &self,
        bundle: &crate::domain::TransferBundle,
        kind: crate::media::PlaybackKind,
        directory: &str,
        remove_location: bool,
    ) -> Result<(Vec<crate::sharing::CurrentMediaFile>, u64, u32, u32), String> {
        Ok(if kind == crate::media::PlaybackKind::Video {
            let [file] = bundle.files.as_slice() else {
                return Err("現在動画の単一原本を確認できません。".into());
            };
            let output: crate::sharing::CurrentMovieOutput = io(
                self.ctx,
                ShellOperation::PrepareCurrentMovie {
                    path: file.path.clone(),
                    directory: directory.into(),
                    remove_location,
                },
            )
            .await?;
            (
                vec![output.file],
                output.input_duration_ms,
                output.input_video_tracks,
                output.input_audio_tracks,
            )
        } else {
            let mut files = vec![];
            for file in &bundle.files {
                let facts: crate::sharing::CurrentMediaFile = io(
                    self.ctx,
                    ShellOperation::InspectCurrentMediaFile {
                        path: file.path.clone(),
                        role: file.resource.role,
                    },
                )
                .await?;
                // Move immutable verified originals into this export's scoped directory.
                let path = format!("{directory}/current-live-{}", files.len());
                let _: serde_json::Value = io(
                    self.ctx,
                    ShellOperation::CopyFile {
                        source: facts.path.clone(),
                        destination: path.clone(),
                    },
                )
                .await?;
                let copied: HashResult =
                    io(self.ctx, ShellOperation::HashFile { path: path.clone() }).await?;
                if copied.signature != file.signature
                    || Some(&copied.sha1) != file.resource.sha1.as_ref()
                {
                    return Err("Live原本のコピーが一致しません。".into());
                }
                files.push(crate::sharing::CurrentMediaFile { path, ..facts });
            }
            let movie = files
                .iter()
                .find(|f| f.role == ResourceRole::LiveVideo)
                .ok_or("Live動画がありません。")?;
            let values = (movie.duration_ms, movie.video_tracks, movie.audio_tracks);
            (files, values.0, values.1, values.2)
        })
    }
}
