use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, ScanAccess, StoredAsset},
    immich::valid_id,
    trash::{
        AppleTrashInspection, AppleTrashOperation, AppleTrashOutcome, AppleTrashPrompt,
        AppleTrashResult, AppleTrashVisibility, validate_apple_trash,
        validate_apple_trash_operation, validate_ordinary_apple_trash,
    },
};
use std::collections::BTreeSet;

impl Runtime<'_> {
    async fn inspect_apple_trash(&self, keys: &[AssetKey]) -> Result<AppleTrashInspection, String> {
        let snapshot: AppleTrashInspection = io(
            self.ctx,
            ShellOperation::AppleTrashInspect {
                scope: self.state.apple_scope.clone(),
                keys: keys.to_vec(),
            },
        )
        .await?;
        if snapshot.scope != self.state.apple_scope
            || !snapshot.full_access
            || snapshot
                .assets
                .iter()
                .any(|a| !keys.contains(&a.asset.key) || !a.full_access)
            || snapshot
                .assets
                .iter()
                .map(|a| &a.asset.key)
                .collect::<BTreeSet<_>>()
                .len()
                != snapshot.assets.len()
        {
            return Err(
                "写真 ID とフルアクセスを確認できません。見えない写真を削除済みとは扱いません。"
                    .into(),
            );
        }
        Ok(snapshot)
    }
    pub(super) async fn trash_apple(
        &mut self,
        keys: &[AssetKey],
        id: &str,
    ) -> Result<String, String> {
        valid_id(id)?;
        if self.check_keys(keys)? != Provider::Apple {
            return Err("Apple Photos の写真を選択してください。".into());
        }
        if self.state.pending_apple_trash.iter().any(|o| o.id == id) {
            return Err("この操作の記録がすでにあります。削除は再送しません。".into());
        }
        let expected = keys
            .iter()
            .map(|key| {
                self.state
                    .snapshots
                    .iter()
                    .filter(|s| {
                        s.provider == Provider::Apple
                            && s.scope == self.state.apple_scope
                            && s.access == ScanAccess::Full
                    })
                    .flat_map(|s| &s.assets)
                    .find(|a| a.key == *key)
                    .cloned()
                    .ok_or("選択した写真をフルアクセスの一覧で確認してください。")
            })
            .collect::<Result<Vec<_>, _>>()?;
        let first = self.inspect_apple_trash(keys).await?;
        validate_ordinary_apple_trash(&expected, &first.assets)?;
        let confirmed: bool = io(
            self.ctx,
            ShellOperation::ConfirmAppleTrash {
                prompt: AppleTrashPrompt {
                    scope: self.state.apple_scope.clone(),
                    names: expected.iter().map(|a| a.name.clone()).collect(),
                },
            },
        )
        .await?;
        if !confirmed {
            return Ok("Apple Photos の削除をキャンセルしました。".into());
        }
        let fresh = self.inspect_apple_trash(keys).await?;
        validate_ordinary_apple_trash(&expected, &fresh.assets)?;
        self.progress(
            "削除前に原本を照合しています。iCloud の原本はダウンロードされる場合があります。",
        );
        self.workspace(id).await?;
        let bundle = self.export(keys, "trash-originals").await?;
        validate_apple_trash(&expected, &bundle.assets)?;
        if bundle.assets.iter().any(|a| !a.fingerprints_complete()) {
            return Err("原本の識別情報を取得できません。削除は開始しません。".into());
        }
        let expected = bundle.assets;
        let operation = AppleTrashOperation {
            id: id.into(),
            scope: self.state.apple_scope.clone(),
            assets: expected.clone(),
            outcome: AppleTrashOutcome::Unknown,
            visibility: None,
        };
        let before = self.state.clone();
        self.state.pending_apple_trash.push(operation);
        self.invalidate(Provider::Apple);
        if let Err(e) = self.persist().await {
            self.state = before;
            return Err(e);
        }
        // Any error/cancellation from this point is ambiguous and retains the fence.
        let result: AppleTrashResult = io(
            self.ctx,
            ShellOperation::AppleTrashApply {
                assets: expected.clone(),
            },
        )
        .await?;
        let uncertain = self.state.clone();
        let pending = self
            .state
            .pending_apple_trash
            .last_mut()
            .ok_or("削除記録がありません。")?;
        pending.outcome = if result.applied {
            AppleTrashOutcome::Applied
        } else {
            AppleTrashOutcome::NotApplied
        };
        // Never promote an outcome whose durable write failed through a later persist.
        if let Err(e) = self.persist().await {
            self.state = uncertain;
            return Err(e);
        }
        self.finish_apple_trash(id).await?;
        if !result.applied {
            return Err(result
                .error
                .unwrap_or("PhotoKit は削除を適用しませんでした。".into()));
        }
        Ok(format!(
            "Apple Photos が {} 件の削除を受け付けました。復元は Apple Photos の「最近削除した項目」で確認してください。",
            keys.len()
        ))
    }
    async fn finish_apple_trash(&mut self, id: &str) -> Result<(), String> {
        let operation = self
            .state
            .pending_apple_trash
            .iter()
            .find(|o| o.id == id && (o.outcome != AppleTrashOutcome::Unknown))
            .cloned()
            .ok_or("削除の成功応答が保存されていません。")?;
        self.validate_apple_trash_journal(&operation)?;
        let before = self.state.clone();
        let keys: BTreeSet<_> = operation.assets.iter().map(|a| &a.key).collect();
        // Touch only selected Apple records, never counterpart originals or receipts.
        for s in &mut self.state.snapshots {
            if s.provider == Provider::Apple && s.scope == operation.scope {
                if operation.outcome == AppleTrashOutcome::Applied {
                    s.assets.retain(|a| !keys.contains(&a.key));
                }
                s.access = ScanAccess::Unavailable;
            }
        }
        for s in &mut self.state.albums {
            if s.provider == Provider::Apple && s.scope == operation.scope {
                s.access = ScanAccess::Unavailable;
            }
        }
        self.state.pending_apple_trash.retain(|o| o.id != id);
        if let Err(e) = self.persist().await {
            self.state = before;
            return Err(e);
        }
        Ok(())
    }
    pub(super) async fn resolve_apple_trash(&mut self, id: &str) -> Result<String, String> {
        let operation = self
            .state
            .pending_apple_trash
            .iter()
            .find(|o| o.id == id)
            .cloned()
            .ok_or("確認する削除記録がありません。")?;
        self.validate_apple_trash_journal(&operation)?;
        if operation.outcome != AppleTrashOutcome::Unknown {
            self.finish_apple_trash(id).await?;
            return Ok(
                "保存された PhotoKit の応答から削除記録を完了しました。一覧を更新してください。"
                    .into(),
            );
        }
        let keys: Vec<_> = operation.assets.iter().map(|a| a.key.clone()).collect();
        let snapshot = self.inspect_apple_trash(&keys).await?;
        let (visibility, description) = match snapshot.assets.len() {
            0 => (
                AppleTrashVisibility::Absent,
                "対象は通常のライブラリで見つかりませんでした。",
            ),
            n if n == keys.len() => (
                AppleTrashVisibility::Present,
                "対象は通常のライブラリに見えています。",
            ),
            _ => (
                AppleTrashVisibility::Mixed,
                "対象の一部だけが通常のライブラリに見えています。",
            ),
        };
        let before = self.state.clone();
        self.state
            .pending_apple_trash
            .iter_mut()
            .find(|o| o.id == id)
            .ok_or("削除記録がありません。")?
            .visibility = Some(visibility);
        if let Err(e) = self.persist().await {
            self.state = before;
            return Err(e);
        }
        Ok(format!(
            "{description}削除の成功・最近削除した項目への所属・復元可能性は確認できません。削除は再送せず記録を保持します。Apple Photos で確認してください。"
        ))
    }
    fn validate_apple_trash_journal(&self, operation: &AppleTrashOperation) -> Result<(), String> {
        if self
            .state
            .pending_apple_trash
            .iter()
            .filter(|o| o.id == operation.id)
            .count()
            != 1
        {
            return Err("削除記録の操作 ID が重複しています。".into());
        }
        validate_apple_trash_operation(operation, &self.state.apple_scope)
    }
    pub(super) fn check_apple_trash_keys(&self, keys: &[AssetKey]) -> Result<(), String> {
        let records: Vec<_> = self
            .state
            .snapshots
            .iter()
            .flat_map(|s| &s.assets)
            .filter(|a| keys.contains(&a.key))
            .collect();
        for o in &self.state.pending_apple_trash {
            self.validate_apple_trash_journal(o)?;
            if o.assets.iter().any(|pending| {
                keys.contains(&pending.key)
                    || records
                        .iter()
                        .any(|a| !a.checksums().is_disjoint(&pending.checksums()))
            }) {
                return Err("Apple Photos の削除結果が不明です。書き込みは再送しません。Apple Photos で確認してください。".into());
            }
        }
        Ok(())
    }
    pub(super) fn check_transfer_apple_trash(&self, assets: &[StoredAsset]) -> Result<(), String> {
        for o in &self.state.pending_apple_trash {
            self.validate_apple_trash_journal(o)?;
            if o.assets.iter().any(|pending| {
                assets.iter().any(|a| {
                    a.key == pending.key || !a.checksums().is_disjoint(&pending.checksums())
                })
            }) {
                return Err(
                    "Apple Photos の削除結果が不明です。同じ原本の転送は開始しません。".into(),
                );
            }
        }
        Ok(())
    }
}
