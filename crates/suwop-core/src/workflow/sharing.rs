use super::{HashResult, Runtime, ShellOperation, io};
use crate::{
    domain::Provider,
    sharing::{ShareFile, contains_file, filename, sources},
};

impl Runtime<'_> {
    pub(super) async fn share(
        &mut self,
        keys: &[crate::domain::AssetKey],
        id: &str,
    ) -> Result<String, String> {
        let keys = sources(&self.state.snapshots, &self.state.receipts, keys)?;
        if keys.iter().any(|k| k.provider == Provider::Immich) {
            self.ensure_session().await?;
        }
        // Validate every scope before exporting anything.
        for key in &keys {
            self.check_keys(std::slice::from_ref(key))?;
        }
        self.workspace(id).await?;
        let mut files = Vec::new();
        for (index, key) in keys.iter().enumerate() {
            self.progress(&format!(
                "原本を共有する準備中… {}/{}",
                index + 1,
                keys.len()
            ));
            let name = format!("share-source-{index}");
            let bundle = self.export(std::slice::from_ref(key), &name).await?;
            let directory = self.directory(&name)?;
            for (resource_index, file) in bundle.files.iter().enumerate() {
                if !contains_file(&directory, &file.path) {
                    return Err("共有ファイルが作業領域の外にあります。".into());
                }
                let name = filename(&file.resource.name)?;
                let path = format!(
                    "{}/{index}/{resource_index}/{name}",
                    self.directory("share")?
                );
                let _: serde_json::Value = io(
                    self.ctx,
                    ShellOperation::CopyFile {
                        source: file.path.clone(),
                        destination: path.clone(),
                    },
                )
                .await?;
                let hash: HashResult =
                    io(self.ctx, ShellOperation::HashFile { path: path.clone() }).await?;
                if hash.signature != file.signature || Some(hash.sha1) != file.resource.sha1 {
                    return Err("共有ファイルと原本の内容が一致しません。".into());
                }
                files.push(ShareFile { path, name });
            }
        }
        self.progress("共有先を選択してください。");
        // This effect resolves only when the native service finishes or cancels.
        // run() retains the workspace until that response, including cancellation.
        let completed: bool = io(self.ctx, ShellOperation::ShareFiles { files }).await?;
        Ok(if completed {
            "原本ファイルを共有しました。"
        } else {
            "共有をキャンセルしました。"
        }
        .into())
    }
}
