use super::{HashResult, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider},
    sharing::{
        CurrentImageExport, ShareFile, SharePresentation, current_image_asset, current_image_name,
        verify_current_image,
    },
};

impl Runtime<'_> {
    pub(super) async fn share_current_image(
        &mut self,
        key: &AssetKey,
        id: &str,
    ) -> Result<String, String> {
        self.share_current_images(std::slice::from_ref(key), id, false)
            .await
    }

    pub(super) async fn share_current_images(
        &mut self,
        keys: &[AssetKey],
        id: &str,
        remove_location: bool,
    ) -> Result<String, String> {
        if keys.is_empty()
            || keys.len() > 500
            || keys.iter().collect::<std::collections::BTreeSet<_>>().len() != keys.len()
        {
            return Err("共有する表示元を重複なく1〜500件選択してください。".into());
        }
        if keys.iter().any(|key| key.provider == Provider::Amazon) {
            return Err("Amazon Photosでは原本の共有を選んでください。".into());
        }
        if keys.iter().any(|key| key.provider == Provider::Immich) {
            self.ensure_session().await?;
        }
        // Admit the entire selection before reading bytes. Never silently omit a failed item.
        self.check_content_keys(keys)?;
        for key in keys {
            self.check_keys(std::slice::from_ref(key))?;
            crate::sharing::current_media_source(
                &self.state.snapshots,
                &self.state.apple_scope,
                self.session.as_ref(),
                key,
            )?;
        }
        self.sharing_workspace(id).await?;
        let mut files = Vec::new();
        for (index, key) in keys.iter().enumerate() {
            self.progress(&format!("現在の内容を準備中… {}/{}", index + 1, keys.len()));
            files.extend(
                self.export_current_media(key, index, remove_location)
                    .await?,
            );
        }
        self.progress("共有先を選択してください。");
        self.check_content_generation(keys)?;
        let completed: bool = io(
            self.ctx,
            ShellOperation::ShareFiles(SharePresentation {
                files,
                source_keys: Some(keys.to_vec()),
            }),
        )
        .await?;
        Ok(if completed {
            "選んだ表示元の現在の内容を共有しました。"
        } else {
            "共有をキャンセルしました。"
        }
        .into())
    }

    pub(super) async fn export_current_image(
        &mut self,
        key: &AssetKey,
        index: usize,
        remove_location: bool,
    ) -> Result<ShareFile, String> {
        let expected = current_image_asset(
            &self.state.snapshots,
            &self.state.apple_scope,
            self.session.as_ref(),
            key,
        )?;
        self.check_keys(std::slice::from_ref(key))?;
        let directory = self.directory(&format!("share-current-{index}"))?;
        let mut export: CurrentImageExport = if key.provider == Provider::Apple {
            io(
                self.ctx,
                ShellOperation::AppleCurrentImage {
                    asset: expected.clone(),
                    directory: directory.clone(),
                },
            )
            .await?
        } else {
            self.remote_current_image(&expected, &directory).await?
        };
        verify_current_image(&expected, &export, &directory)?;
        if remove_location {
            let encoding = io(
                self.ctx,
                ShellOperation::InspectImageEncoding {
                    path: export.path.clone(),
                },
            )
            .await?;
            let plan =
                crate::sharing::CurrentImageRenderPlan::without_location(&expected, &encoding)?;
            let destination = format!("{directory}/without-location.png");
            let rendered: crate::sharing::CurrentImageRenderResult = io(
                self.ctx,
                ShellOperation::RenderCurrentImage {
                    path: export.path,
                    destination: destination.clone(),
                    plan: plan.clone(),
                },
            )
            .await?;
            plan.verify(&rendered)?;
            export.path = destination;
            export.image = rendered.image;
        }
        let before: HashResult = io(
            self.ctx,
            ShellOperation::HashFile {
                path: export.path.clone(),
            },
        )
        .await?;
        if !before.signature.valid() {
            return Err("現在の画像のバイト列を確認できません。".into());
        }
        let name = current_image_name(&expected, &export.image)?;
        let path = format!(
            "{}/{name}",
            self.directory(&format!("share-current-ready-{index}"))?
        );
        let _: serde_json::Value = io(
            self.ctx,
            ShellOperation::CopyFile {
                source: export.path,
                destination: path.clone(),
            },
        )
        .await?;
        let after: HashResult =
            io(self.ctx, ShellOperation::HashFile { path: path.clone() }).await?;
        if before.signature != after.signature || before.sha1 != after.sha1 {
            return Err("現在の共有画像のコピーが一致しません。".into());
        }
        self.check_content_generation(std::slice::from_ref(key))?;
        Ok(ShareFile { path, name })
    }
}
