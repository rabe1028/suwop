use super::{HashResult, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::StoredAsset,
    editing::ImageEncodingFacts,
    sharing::{
        CurrentImageExport, CurrentImageFacts, CurrentImageRenderPlan, CurrentImageRenderResult,
    },
};

impl Runtime<'_> {
    pub(super) async fn remote_current_image(
        &self,
        expected: &StoredAsset,
        directory: &str,
    ) -> Result<CurrentImageExport, String> {
        let original = format!("{directory}/current-original");
        let session = self.session.as_ref().ok_or("Immichに接続してください。")?;
        let input = session
            .current_image_input(self.ctx, expected, &original)
            .await?;
        let hash: HashResult = io(
            self.ctx,
            ShellOperation::HashFile {
                path: original.clone(),
            },
        )
        .await?;
        verify_original(expected, &hash)?;
        let (path, image) = if let Some(edits) = input.edits.clone() {
            let encoding: ImageEncodingFacts = io(
                self.ctx,
                ShellOperation::InspectImageEncoding {
                    path: original.clone(),
                },
            )
            .await?;
            let plan = CurrentImageRenderPlan::remote(expected, &encoding, edits)?;
            let path = format!("{directory}/current-rendered.png");
            let rendered: CurrentImageRenderResult = io(
                self.ctx,
                ShellOperation::RenderCurrentImage {
                    path: original,
                    destination: path.clone(),
                    plan: plan.clone(),
                },
            )
            .await?;
            plan.verify(&rendered)?;
            (path, rendered.image)
        } else {
            let image: CurrentImageFacts = io(
                self.ctx,
                ShellOperation::InspectCurrentImage {
                    path: original.clone(),
                },
            )
            .await?;
            (original, image)
        };
        let fresh = session.verify_current_image_input(self.ctx, &input).await?;
        Ok(CurrentImageExport {
            asset: input.asset.record(&session.scope, None, None),
            fresh_asset: fresh,
            path,
            image,
        })
    }
}

fn verify_original(expected: &StoredAsset, hash: &HashResult) -> Result<(), String> {
    let originals: Vec<_> = expected.originals().collect();
    let [original] = originals.as_slice() else {
        return Err("書き出す原本の構成を確認できません。".into());
    };
    if !hash.signature.valid()
        || original.sha1.as_deref() != Some(hash.sha1.as_str())
        || original
            .bytes
            .is_some_and(|bytes| bytes != hash.signature.bytes)
    {
        return Err("書き出す原本のバイト列がImmichの原本と一致しません。".into());
    }
    Ok(())
}
