use super::{HashResult, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider},
    sharing::{
        CurrentImageExport, ShareFile, current_image_asset, current_image_name,
        verify_current_image,
    },
};

impl Runtime<'_> {
    pub(super) async fn share_current_image(
        &mut self,
        key: &AssetKey,
        id: &str,
    ) -> Result<String, String> {
        if key.provider == Provider::Immich {
            self.ensure_session().await?;
        }
        let expected = current_image_asset(
            &self.state.snapshots,
            &self.state.apple_scope,
            self.session.as_ref(),
            key,
        )?;
        self.check_keys(std::slice::from_ref(key))?;
        self.workspace(id).await?;
        let directory = self.directory("share-current")?;
        let export: CurrentImageExport = if key.provider == Provider::Apple {
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
        let path = format!("{}/{name}", self.directory("share-current-ready")?);
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
        self.progress("現在の静止画の共有先を選択してください。");
        let completed: bool = io(
            self.ctx,
            ShellOperation::ShareFiles {
                files: vec![ShareFile { path, name }],
            },
        )
        .await?;
        Ok(if completed {
            "この保存先の現在の静止画を共有しました。"
        } else {
            "現在の静止画の共有をキャンセルしました。"
        }
        .into())
    }
}
