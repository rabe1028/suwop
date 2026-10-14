use super::Runtime;
use crate::domain::StoredAsset;

impl Runtime<'_> {
    pub(super) fn check_transfer_trash(&self, assets: &[StoredAsset]) -> Result<(), String> {
        self.check_transfer_apple_trash(assets)?;
        self.check_visibility_keys(&assets.iter().map(|a| a.key.clone()).collect::<Vec<_>>())?;
        let Some(session) = &self.session else {
            return Ok(());
        };
        for operation in &self.state.pending_trash {
            if operation.scope != session.scope {
                continue;
            }
            for asset in assets {
                let checksums = asset.checksums();
                if operation.assets.iter().any(|pending| {
                    pending.key == asset.key || checksums.contains(&pending.checksum)
                }) {
                    return Err(
                        "同じ原本のゴミ箱操作の結果を先に確認してください。転送は開始しません。"
                            .into(),
                    );
                }
            }
        }
        Ok(())
    }
}
