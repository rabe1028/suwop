use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, StoredAsset, TransferBundle, catalog},
    editing::{
        AppleEditInput, AppleEditResult, EditClipboard, EditCopyOptions, ImageRenderPlan,
        PasteEditsPrompt, PendingEditPaste, prepare_apple_edit, targets, verify_edit_source,
        verify_edited_originals,
    },
};
use serde_json::Value;

use super::Runtime;

struct PreparedPaste {
    before: TransferBundle,
    input: AppleEditInput,
    directory: String,
    plan: Option<ImageRenderPlan>,
}

impl Runtime<'_> {
    pub(super) fn selected_paste_keys(
        &self,
        anchors: &[AssetKey],
    ) -> Result<Vec<AssetKey>, String> {
        let photos = catalog(&self.state.snapshots, &self.state.receipts);
        let mut keys = std::collections::BTreeSet::new();
        for anchor in anchors {
            let photo = photos
                .iter()
                .find(|p| p.assets.iter().any(|a| a.key == *anchor))
                .ok_or("選んだ写真を確認できません。一覧を更新してください。")?;
            let apple: Vec<_> = photo
                .assets
                .iter()
                .filter(|a| a.key.provider == Provider::Apple)
                .collect();
            if apple.is_empty() {
                return Err(
                    "Apple Photos側にない写真が含まれています。選択から外してください。".into(),
                );
            }
            keys.extend(apple.iter().map(|a| a.key.clone()));
        }
        Ok(keys.into_iter().collect())
    }

    fn paste_asset(&self, key: &AssetKey) -> Result<StoredAsset, String> {
        let photos = catalog(&self.state.snapshots, &self.state.receipts);
        let photo = photos
            .iter()
            .find(|p| p.assets.iter().any(|a| a.key == *key))
            .ok_or("写真を確認できません。一覧を更新してください。")?;
        let target = targets(photo, &self.state.snapshots, &self.state.apple_scope)
            .into_iter()
            .find(|t| t.key == *key)
            .ok_or("編集する保存先を確認できません。")?;
        if let Some(reason) = target.disabled_reason {
            return Err(reason);
        }
        photo
            .assets
            .iter()
            .find(|a| a.key == *key)
            .cloned()
            .ok_or("写真が見つかりません。".into())
    }

    async fn paste_open(
        &mut self,
        source: &StoredAsset,
        directory: &str,
    ) -> Result<AppleEditInput, String> {
        let input: AppleEditInput = io(
            self.ctx,
            ShellOperation::AppleEditOpen {
                asset: source.clone(),
                directory: directory.into(),
            },
        )
        .await?;
        self.editing_token = Some(input.token.clone());
        Ok(input)
    }

    async fn paste_close(&mut self) -> Result<(), String> {
        if let Some(token) = self.editing_token.clone() {
            let _: Value = io(self.ctx, ShellOperation::AppleEditClose { token }).await?;
            self.editing_token = None;
        }
        Ok(())
    }

    pub(super) async fn copy_photo_edits(
        &mut self,
        key: &AssetKey,
        options: EditCopyOptions,
        id: &str,
    ) -> Result<String, String> {
        self.check_keys(std::slice::from_ref(key))?;
        options.validate()?;
        let expected = self.paste_asset(key)?;
        self.workspace(id).await?;
        let before = self.export(std::slice::from_ref(key), "copy-edits").await?;
        let source = single_asset(&before, key)?;
        verify_edit_source(&expected, source)?;
        let directory = self.directory("copy-editor")?;
        let input = self.paste_open(source, &directory).await?;
        let presentation = prepare_apple_edit(source, &input, &directory)?;
        let clipboard = EditClipboard::capture(&presentation, options)?;
        self.paste_close().await?;
        let old = self.state.edit_clipboard.replace(clipboard);
        if let Err(error) = self.persist().await {
            self.state.edit_clipboard = old;
            return Err(error);
        }
        Ok("選択した編集をコピーしました。写真は変更していません。".into())
    }

    async fn prepare_pastes(
        &mut self,
        keys: &[AssetKey],
        clipboard: &EditClipboard,
    ) -> Result<Vec<PreparedPaste>, String> {
        // Check the whole selection before downloading, then preflight every
        // original/edit payload before showing confirmation or issuing writes.
        let expected = keys
            .iter()
            .map(|k| self.paste_asset(k))
            .collect::<Result<Vec<_>, _>>()?;
        let mut prepared = Vec::new();
        for (index, asset) in expected.iter().enumerate() {
            let before = self
                .export(
                    std::slice::from_ref(&asset.key),
                    &format!("paste-before-{index}"),
                )
                .await?;
            let source = single_asset(&before, &asset.key)?;
            verify_edit_source(asset, source)?;
            let directory = self.directory(&format!("paste-editor-{index}"))?;
            let input = self.paste_open(source, &directory).await?;
            let presentation = prepare_apple_edit(source, &input, &directory)?;
            let plan = clipboard.plan(&presentation)?;
            self.paste_close().await?;
            prepared.push(PreparedPaste {
                before,
                input,
                directory,
                plan,
            });
        }
        Ok(prepared)
    }

    pub(super) async fn paste_photo_edits(
        &mut self,
        keys: &[AssetKey],
        id: &str,
    ) -> Result<String, String> {
        if keys.len() > 50 {
            return Err("編集の貼り付けは一度に50枚までです。選択を減らしてください。".into());
        }
        if self.check_keys(keys)? != Provider::Apple {
            return Err("Apple Photosの写真を選んでください。".into());
        }
        let clipboard = self
            .state
            .edit_clipboard
            .clone()
            .ok_or("先に写真の編集をコピーしてください。")?;
        self.workspace(id).await?;
        let prepared = self.prepare_pastes(keys, &clipboard).await?;
        let unchanged = prepared.iter().filter(|p| p.plan.is_none()).count();
        let prompt = PasteEditsPrompt {
            source_name: clipboard.source_name.clone(),
            options: clipboard.options,
            names: prepared
                .iter()
                .filter(|p| p.plan.is_some())
                .map(|p| p.input.asset.name.clone())
                .collect(),
            unchanged_count: unchanged,
        };
        if prompt.names.is_empty() {
            return Ok(format!(
                "{unchanged}枚は同じ編集です。写真は変更していません。"
            ));
        }
        let confirmed: bool = io(self.ctx, ShellOperation::ConfirmPasteEdits { prompt }).await?;
        if !confirmed {
            return Ok("編集の貼り付けをキャンセルしました。写真は変更していません。".into());
        }
        let mut completed = 0;
        for (index, prepared) in prepared
            .iter()
            .enumerate()
            .filter(|(_, p)| p.plan.is_some())
        {
            if let Err(error) = self.save_paste(prepared, &clipboard, index).await {
                self.invalidate(Provider::Apple);
                let persisted = self.persist().await;
                let suffix = persisted
                    .err()
                    .map_or(String::new(), |e| format!(" 記録の保存: {e}"));
                return Err(format!(
                    "{completed}枚の保存を確認しました。残りは停止しました。{error}{suffix}"
                ));
            }
            completed += 1;
        }
        Ok(format!(
            "{completed}枚に編集を貼り付けました。{unchanged}枚は同じ編集でした。原本は残っています。"
        ))
    }

    async fn save_paste(
        &mut self,
        prepared: &PreparedPaste,
        clipboard: &EditClipboard,
        index: usize,
    ) -> Result<(), String> {
        let source = &prepared.input.asset;
        let input = self.paste_open(source, &prepared.directory).await?;
        let presentation = prepare_apple_edit(source, &input, &prepared.directory)?;
        let plan = clipboard
            .plan(&presentation)?
            .ok_or("確認後に編集内容が変わりました。")?;
        if input.adjustment != prepared.input.adjustment || prepared.plan.as_ref() != Some(&plan) {
            return Err("確認後に写真の編集が変わりました。".into());
        }
        let mut before = prepared.before.clone();
        for file in &mut before.files {
            file.path.clear();
        }
        self.state.pending_edit_pastes.push(PendingEditPaste {
            key: source.key.clone(),
            name: source.name.clone(),
            before,
            initial_adjustment: input.adjustment.clone(),
            plan: plan.clone(),
        });
        // Persistence failure authorizes no native save, but retain the journal
        // in memory since the disk response itself can also be uncertain.
        self.persist().await?;
        let saved: AppleEditResult = io(
            self.ctx,
            ShellOperation::AppleEditSave {
                token: input.token,
                asset: source.clone(),
                plan: plan.clone(),
            },
        )
        .await?;
        verify_paste_result(&source.key, &plan, &saved)?;
        let after = self
            .paste_export(&source.key, &format!("paste-after-{index}"))
            .await?;
        verify_edited_originals(&prepared.before, &after)?;
        let fresh = single_asset(&after, &source.key)?;
        verify_edit_source(&saved.asset, fresh)?;
        self.paste_close().await?;
        self.finish_paste(fresh.clone()).await?;
        self.preferred_preview = Some(source.key.clone());
        Ok(())
    }

    async fn finish_paste(&mut self, fresh: StoredAsset) -> Result<(), String> {
        let old = self.state.pending_edit_pastes.clone();
        self.state
            .pending_edit_pastes
            .retain(|p| p.key != fresh.key);
        self.replace_records(vec![fresh]);
        if let Err(error) = self.persist().await {
            self.state.pending_edit_pastes = old;
            return Err(error);
        }
        Ok(())
    }

    async fn paste_export(&self, key: &AssetKey, name: &str) -> Result<TransferBundle, String> {
        // Read-only inspection must bypass the pending-write fence. No caller
        // of this helper is allowed to dispatch a mutation without a journal.
        let bundle: TransferBundle = io(
            self.ctx,
            ShellOperation::AppleExport {
                keys: vec![key.clone()],
                directory: self.directory(name)?,
            },
        )
        .await?;
        bundle.validate()?;
        single_asset(&bundle, key)?;
        Ok(bundle)
    }

    pub(super) async fn resolve_edit_paste(
        &mut self,
        key: &AssetKey,
        id: &str,
    ) -> Result<String, String> {
        let pending = self
            .state
            .pending_edit_pastes
            .iter()
            .find(|p| p.key == *key)
            .cloned()
            .ok_or("確認する編集の記録がありません。")?;
        let expected = self.paste_asset(key)?;
        self.workspace(id).await?;
        let after = self.paste_export(key, "paste-reconcile").await?;
        let fresh = single_asset(&after, key)?;
        verify_edit_source(&expected, fresh)?;
        verify_edited_originals(&pending.before, &after)?;
        let directory = self.directory("paste-inspect")?;
        let input = self.paste_open(fresh, &directory).await?;
        let presentation = prepare_apple_edit(fresh, &input, &directory)?;
        let applied = input.adjustment.as_ref() == Some(&pending.plan.adjustment);
        if applied {
            let saved: AppleEditResult = io(
                self.ctx,
                ShellOperation::AppleEditInspect {
                    asset: fresh.clone(),
                },
            )
            .await?;
            verify_paste_result(key, &pending.plan, &saved)?;
            verify_edit_source(fresh, &saved.asset)?;
        } else {
            let before = single_asset(&pending.before, key)?;
            verify_edit_source(before, fresh)?;
            if input.adjustment != pending.initial_adjustment
                || presentation.base != crate::editing::AdjustmentBase::Original
            {
                return Err("貼り付け結果が以前の状態とも一致しません。記録を保持し、書き込みは再送しません。".into());
            }
        }
        self.paste_close().await?;
        self.finish_paste(fresh.clone()).await?;
        Ok(if applied {
            "編集の貼り付け済みを確認しました。再送していません。"
        } else {
            "写真が貼り付け前の状態であることを確認しました。再送していません。"
        }
        .into())
    }
}

fn single_asset<'a>(bundle: &'a TransferBundle, key: &AssetKey) -> Result<&'a StoredAsset, String> {
    let [asset] = bundle.assets.as_slice() else {
        return Err("対象の写真を確認できません。".into());
    };
    if asset.key != *key {
        return Err("写真の保存先が一致しません。".into());
    }
    Ok(asset)
}

fn verify_paste_result(
    key: &AssetKey,
    plan: &ImageRenderPlan,
    saved: &AppleEditResult,
) -> Result<(), String> {
    if saved.asset.key != *key
        || saved.adjustment != plan.adjustment
        || saved.image.oriented_size()? != plan.transform.output_size(plan.dimensions)?
        || !saved.image.has_color_space
        || saved.image.hdr
        || saved.image.has_alpha
    {
        return Err(
            "保存した編集の貼り付け結果を確認できません。先に結果を確認してください。".into(),
        );
    }
    Ok(())
}
