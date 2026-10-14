use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    apple_visibility::{
        AppleVisibilityApply, AppleVisibilityInspection, AppleVisibilityOperation,
        AppleVisibilityPrompt, AppleVisibilityResult, VisibilityAction, VisibilityApplyTarget,
        VisibilityObservation, VisibilityOutcome, VisibilityTarget, valid_operation_id,
        validate_apply, validate_operation, witness,
    },
    domain::{AssetKey, Provider, ScanAccess},
};
use std::collections::BTreeSet;
impl Runtime<'_> {
    pub(super) fn check_visibility_keys(&self, keys: &[AssetKey]) -> Result<(), String> {
        let mut ids = BTreeSet::new();
        for op in &self.state.apple_visibility_operations {
            validate_operation(op, &self.state.apple_scope)?;
            if !ids.insert(&op.id) {
                return Err("非表示の操作 UUID が重複しています。".into());
            }
            if keys.iter().any(|k| op.fences(k)) {
                return Err("非表示変更の結果を先に確認してください。変更は再送しません。".into());
            }
        }
        Ok(())
    }
    async fn visibility_facts(
        &self,
        keys: &[AssetKey],
    ) -> Result<AppleVisibilityInspection, String> {
        let facts: AppleVisibilityInspection = io(
            self.ctx,
            ShellOperation::AppleVisibilityInspect {
                scope: self.state.apple_scope.clone(),
                keys: keys.to_vec(),
            },
        )
        .await
        .map_err(|_| {
            "写真を検査できません。記録を保持し Apple Photos で確認してください。".to_owned()
        })?;
        if facts.scope != self.state.apple_scope
            || facts.assets.iter().any(|f| !keys.contains(&f.key))
            || facts
                .assets
                .iter()
                .map(|f| &f.key)
                .collect::<BTreeSet<_>>()
                .len()
                != facts.assets.len()
        {
            return Err("非表示の検査 ID が不正です。".into());
        }
        Ok(facts)
    }
    fn fresh_visibility_id(&self, id: &str) -> Result<(), String> {
        valid_operation_id(id)?;
        if self
            .state
            .apple_visibility_operations
            .iter()
            .any(|o| o.id == id)
            || self.state.pending_apple_trash.iter().any(|o| o.id == id)
        {
            return Err("この操作 UUID は使用済みです。変更は再送しません。".into());
        }
        Ok(())
    }
    pub(super) async fn hide_apple(
        &mut self,
        keys: &[AssetKey],
        id: &str,
    ) -> Result<String, String> {
        self.fresh_visibility_id(id)?;
        if self.check_keys(keys)? != Provider::Apple
            || !self.state.snapshots.iter().any(|s| {
                s.provider == Provider::Apple
                    && s.scope == self.state.apple_scope
                    && s.access == ScanAccess::Full
            })
        {
            return Err("フルアクセスの Apple Photos から選択してください。".into());
        }
        let first = self.visibility_facts(keys).await?;
        let targets = first
            .assets
            .iter()
            .map(|f| {
                Ok(VisibilityTarget {
                    key: f.key.clone(),
                    witness_digest: witness(f)?,
                    observation: None,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        if targets.len() != keys.len() {
            return Err("写真を取得できません。Apple Photos で確認してください。".into());
        }
        self.change_visibility(targets, id, VisibilityAction::Hide)
            .await
    }
    pub(super) async fn unhide_apple(
        &mut self,
        record_id: &str,
        id: &str,
    ) -> Result<String, String> {
        self.fresh_visibility_id(id)?;
        self.check_visibility_keys(&[])?;
        let op = self
            .state
            .apple_visibility_operations
            .iter()
            .find(|o| o.id == record_id)
            .cloned()
            .ok_or("非表示の操作記録がありません。")?;
        if !op
            .summary_with_history(&self.state.apple_visibility_operations)
            .can_unhide
        {
            return Err("非表示を確認してください。Apple Photos で確認することもできます。".into());
        }
        let keys = op.targets.iter().map(|t| t.key.clone()).collect::<Vec<_>>();
        self.check_identity_keys(&keys)?;
        let targets = op
            .targets
            .into_iter()
            .map(|mut t| {
                t.observation = None;
                t
            })
            .collect();
        self.change_visibility(targets, id, VisibilityAction::Unhide)
            .await
    }
    async fn change_visibility(
        &mut self,
        targets: Vec<VisibilityTarget>,
        id: &str,
        action: VisibilityAction,
    ) -> Result<String, String> {
        let keys = targets.iter().map(|t| t.key.clone()).collect::<Vec<_>>();
        let first = self.visibility_facts(&keys).await?;
        let request = self.visibility_request(&targets, id, action, &first)?;
        validate_apply(&request, &first)?;
        let confirmed: bool = io(
            self.ctx,
            ShellOperation::ConfirmAppleVisibility {
                prompt: AppleVisibilityPrompt {
                    id: id.into(),
                    action,
                    count: targets.len(),
                },
            },
        )
        .await
        .map_err(|_| "非表示変更の確認を完了できませんでした。".to_owned())?;
        if !confirmed {
            return Ok("非表示変更をキャンセルしました。".into());
        }
        let fresh = self.visibility_facts(&keys).await?;
        let request = self.visibility_request(&targets, id, action, &fresh)?;
        validate_apply(&request, &fresh)?;
        self.check_identity_keys(&keys)?;
        let before = self.state.clone();
        self.state
            .apple_visibility_operations
            .push(AppleVisibilityOperation {
                id: id.into(),
                scope: self.state.apple_scope.clone(),
                action,
                outcome: VisibilityOutcome::Unknown,
                targets,
            });
        self.invalidate(Provider::Apple);
        if let Err(e) = self.persist().await {
            self.state = before;
            return Err(e);
        }
        // The durable Unknown intent precedes native submission. No path replays it.
        let result: AppleVisibilityResult =
            io(self.ctx, ShellOperation::AppleVisibilityApply { request })
                .await
                .map_err(|_| {
                    "非表示変更の応答を確認できません。記録を保持し変更は再送しません。".to_owned()
                })?;
        let unknown = self.state.clone();
        self.state
            .apple_visibility_operations
            .iter_mut()
            .find(|o| o.id == id)
            .ok_or("操作記録がありません。")?
            .outcome = result.outcome;
        if let Err(e) = self.persist().await {
            self.state = unknown;
            return Err(e);
        }
        Ok(match (result.outcome, action) {
            (VisibilityOutcome::Applied, VisibilityAction::Hide) => "非表示にしました。一覧を更新してください。",
            (VisibilityOutcome::Applied, VisibilityAction::Unhide) => "再表示しました。一覧を更新してください。",
            (VisibilityOutcome::NotApplied, _) => "変更されませんでした。",
            (VisibilityOutcome::Unknown, _) => "変更結果を確認できません。再実行せず、現在の状態を確認するか Apple Photos で確認してください。",
        }.into())
    }
    fn visibility_request(
        &self,
        targets: &[VisibilityTarget],
        id: &str,
        action: VisibilityAction,
        facts: &AppleVisibilityInspection,
    ) -> Result<AppleVisibilityApply, String> {
        Ok(AppleVisibilityApply {
            id: id.into(),
            scope: self.state.apple_scope.clone(),
            action,
            targets: targets
                .iter()
                .map(|t| {
                    Ok(VisibilityApplyTarget {
                        key: t.key.clone(),
                        expected_witness: t.witness_digest.clone(),
                        fresh_revision: facts
                            .assets
                            .iter()
                            .find(|f| f.key == t.key)
                            .ok_or("写真を取得できません。Apple Photos で確認してください。")?
                            .fresh_revision
                            .clone(),
                    })
                })
                .collect::<Result<_, String>>()?,
        })
    }
    pub(super) async fn inspect_visibility_record(&mut self, id: &str) -> Result<String, String> {
        self.check_visibility_keys(&[])?;
        let op = self
            .state
            .apple_visibility_operations
            .iter()
            .find(|o| o.id == id)
            .cloned()
            .ok_or("操作記録がありません。")?;
        let keys = op.targets.iter().map(|t| t.key.clone()).collect::<Vec<_>>();
        let facts = self.visibility_facts(&keys).await?;
        if !facts.full_access {
            return Ok(
                "写真を取得できません。記録を保持します。Apple Photos で認証・確認してください。"
                    .into(),
            );
        }
        let before = self.state.clone();
        let mut observed = Vec::new();
        for mut t in op.targets {
            if let Some(f) = facts.assets.iter().find(|f| f.key == t.key)
                && f.full_access
                && witness(f)? == t.witness_digest
            {
                t.observation = match f.visibility {
                    crate::domain::AppleVisibility::Visible => {
                        Some(VisibilityObservation::ObservedVisible)
                    }
                    crate::domain::AppleVisibility::Hidden => {
                        Some(VisibilityObservation::ObservedHidden)
                    }
                    crate::domain::AppleVisibility::Unknown => None,
                };
                if t.observation.is_some() {
                    observed.push(t);
                }
            }
        }
        for operation in &mut self.state.apple_visibility_operations {
            for target in &mut operation.targets {
                if let Some(fresh) = observed.iter().find(|candidate| {
                    candidate.key == target.key && candidate.witness_digest == target.witness_digest
                }) {
                    target.observation = fresh.observation;
                }
            }
        }
        // Observations settle individual fences; they never rewrite native outcome.
        self.invalidate(Provider::Apple);
        if let Err(e) = self.persist().await {
            self.state = before;
            return Err(e);
        }
        Ok("取得できた写真の現在の可視性を記録しました。取得できない写真は Apple Photos で確認してください。一覧の表示には更新が必要です。".into())
    }
}
