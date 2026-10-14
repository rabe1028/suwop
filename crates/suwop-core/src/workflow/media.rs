use super::{HashResult, Runtime, ShellOperation, io};
use crate::{
    domain::{AssetKey, Provider},
    media::{PlaybackPlan, files, source},
    sharing::{contains_file, filename},
};

impl Runtime<'_> {
    pub(super) async fn play(&mut self, keys: &[AssetKey], id: &str) -> Result<String, String> {
        self.check_content_keys(keys)?;
        let (key, kind) = source(
            &self.state.presentation_snapshots(),
            &self.state.receipts,
            keys,
        )?;
        if key.provider == Provider::Immich {
            self.ensure_session().await?;
        }
        self.check_keys(std::slice::from_ref(&key))?;
        self.workspace(id).await?;
        self.progress("再生用の原本を取得中…");
        let bundle = self
            .export(std::slice::from_ref(&key), "playback-source")
            .await?;
        let directory = self.directory("playback-source")?;
        let mut paths = Vec::new();
        for (index, file) in files(&bundle, kind)?.iter().enumerate() {
            if !contains_file(&directory, &file.path) {
                return Err("再生用ファイルが作業領域の外にあります。".into());
            }
            let path = format!(
                "{}/{index}/{}",
                self.directory("playback")?,
                filename(&file.resource.name)?
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
                return Err("再生用ファイルと原本の内容が一致しません。".into());
            }
            paths.push(path);
        }
        self.progress("原本を再生中。閉じると作業ファイルを片付けます。");
        self.check_content_generation(std::slice::from_ref(&key))?;
        let _: serde_json::Value = io(
            self.ctx,
            ShellOperation::PlayMedia {
                plan: PlaybackPlan {
                    source_keys: vec![key],
                    kind,
                    name: bundle.assets[0].name.clone(),
                    files: paths,
                },
            },
        )
        .await?;
        Ok("再生を終了しました。".into())
    }
}
