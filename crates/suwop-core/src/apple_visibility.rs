//! Durable physical Apple visibility decisions. Witnesses are identity inventories,
//! never original byte checksums or deletion receipts.
use crate::domain::{AppleVisibility, AssetKey, Provider, ResourceRole};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum VisibilityAction {
    Hide,
    Unhide,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum VisibilityOutcome {
    Unknown,
    Applied,
    NotApplied,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum VisibilityObservation {
    ObservedVisible,
    ObservedHidden,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct VisibilityResource {
    pub id: String,
    pub role: ResourceRole,
    pub original_filename: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct VisibilityIdentity {
    pub creation_date: Option<f64>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub media_type: u32,
    pub media_subtypes: u64,
    pub resources: Vec<VisibilityResource>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityFacts {
    pub key: AssetKey,
    pub full_access: bool,
    pub can_edit_properties: bool,
    pub visibility: AppleVisibility,
    pub fresh_revision: String,
    pub identity: VisibilityIdentity,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityInspection {
    pub scope: String,
    pub full_access: bool,
    pub assets: Vec<AppleVisibilityFacts>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct VisibilityTarget {
    pub key: AssetKey,
    pub witness_digest: String,
    pub observation: Option<VisibilityObservation>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityOperation {
    pub id: String,
    pub scope: String,
    pub action: VisibilityAction,
    pub outcome: VisibilityOutcome,
    pub targets: Vec<VisibilityTarget>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct VisibilityApplyTarget {
    pub key: AssetKey,
    pub expected_witness: String,
    pub fresh_revision: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityApply {
    pub id: String,
    pub scope: String,
    pub action: VisibilityAction,
    pub targets: Vec<VisibilityApplyTarget>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityPrompt {
    pub id: String,
    pub action: VisibilityAction,
    pub count: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilityResult {
    pub outcome: VisibilityOutcome,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleVisibilitySummary {
    pub id: String,
    pub action: VisibilityAction,
    pub count: usize,
    pub outcome: VisibilityOutcome,
    pub observations: Vec<Option<VisibilityObservation>>,
    pub can_inspect: bool,
    pub can_unhide: bool,
    pub photos_handoff: bool,
}

pub fn valid_operation_id(id: &str) -> Result<(), String> {
    let bytes = id.as_bytes();
    if bytes.len() != 36
        || bytes.iter().enumerate().any(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                *b != b'-'
            } else {
                !b.is_ascii_hexdigit()
            }
        })
    {
        return Err("操作 UUID が不正です。".into());
    }
    Ok(())
}
pub fn witness(facts: &AppleVisibilityFacts) -> Result<String, String> {
    if facts.key.provider != Provider::Apple
        || facts.key.scope.is_empty()
        || facts.key.asset_id.is_empty()
        || facts.identity.pixel_width == 0
        || facts.identity.pixel_height == 0
        || facts.identity.resources.is_empty()
        || facts.identity.creation_date.is_some_and(|v| !v.is_finite())
    {
        return Err("写真の同一性を確認できません。".into());
    }
    let mut resources = facts.identity.resources.clone();
    resources.sort_by(|a, b| a.id.cmp(&b.id));
    if resources
        .iter()
        .any(|r| r.id.is_empty() || r.original_filename.is_empty())
        || resources
            .iter()
            .map(|r| &r.id)
            .collect::<BTreeSet<_>>()
            .len()
            != resources.len()
    {
        return Err("写真の資源情報を確認できません。".into());
    }
    let mut identity = facts.identity.clone();
    identity.resources = resources;
    let bytes = serde_json::to_vec(&(&facts.key, identity)).map_err(|e| e.to_string())?;
    Ok(crate::domain::hex(&Sha256::digest(bytes)))
}
pub fn validate_operation(op: &AppleVisibilityOperation, scope: &str) -> Result<(), String> {
    valid_operation_id(&op.id)?;
    if op.scope != scope
        || op.targets.is_empty()
        || op.targets.iter().any(|t| {
            t.key.provider != Provider::Apple
                || t.key.scope != scope
                || t.key.asset_id.is_empty()
                || t.witness_digest.len() != 64
                || !t.witness_digest.bytes().all(|b| b.is_ascii_hexdigit())
        })
        || op
            .targets
            .iter()
            .map(|t| &t.key)
            .collect::<BTreeSet<_>>()
            .len()
            != op.targets.len()
    {
        return Err("非表示の操作記録が不正です。".into());
    }
    Ok(())
}
impl AppleVisibilityOperation {
    #[must_use]
    pub fn fences(&self, key: &AssetKey) -> bool {
        self.outcome == VisibilityOutcome::Unknown
            && self
                .targets
                .iter()
                .any(|t| &t.key == key && t.observation.is_none())
    }
    #[must_use]
    pub fn summary(&self) -> AppleVisibilitySummary {
        self.summary_with_history(std::slice::from_ref(self))
    }

    /// Receipts describe past changes. Recovery availability follows the latest
    /// exact physical identity evidence, without rewriting any native outcome.
    #[must_use]
    pub fn summary_with_history(&self, history: &[Self]) -> AppleVisibilitySummary {
        let later = history
            .iter()
            .position(|operation| operation.id == self.id)
            .map_or(&[][..], |index| &history[index + 1..]);
        let can_unhide = self.action == VisibilityAction::Hide
            && !self.targets.is_empty()
            && self.targets.iter().all(|target| {
                let mut observation = self.target_observation(target);
                for operation in later {
                    if let Some(matching) = operation
                        .targets
                        .iter()
                        .find(|candidate| candidate.key == target.key)
                    {
                        if matching.witness_digest != target.witness_digest {
                            // A reused physical ID cannot borrow visibility from
                            // the replacement identity or retain old authority.
                            observation = None;
                        } else if operation.outcome != VisibilityOutcome::NotApplied
                            || matching.observation.is_some()
                        {
                            observation = operation.target_observation(matching);
                        }
                    }
                }
                observation == Some(VisibilityObservation::ObservedHidden)
                    && !history
                        .iter()
                        .any(|operation| operation.fences(&target.key))
            });
        AppleVisibilitySummary {
            id: self.id.clone(),
            action: self.action,
            count: self.targets.len(),
            outcome: self.outcome,
            observations: self.targets.iter().map(|t| t.observation).collect(),
            can_inspect: true,
            can_unhide,
            photos_handoff: self.targets.iter().any(|t| t.observation.is_none()),
        }
    }

    fn target_observation(&self, target: &VisibilityTarget) -> Option<VisibilityObservation> {
        target.observation.or_else(|| {
            (self.outcome == VisibilityOutcome::Applied).then_some(match self.action {
                VisibilityAction::Hide => VisibilityObservation::ObservedHidden,
                VisibilityAction::Unhide => VisibilityObservation::ObservedVisible,
            })
        })
    }
}
pub fn validate_apply(
    apply: &AppleVisibilityApply,
    fresh: &AppleVisibilityInspection,
) -> Result<(), String> {
    valid_operation_id(&apply.id)?;
    if apply.scope != fresh.scope
        || !fresh.full_access
        || apply.targets.is_empty()
        || fresh.assets.len() != apply.targets.len()
        || apply
            .targets
            .iter()
            .map(|t| &t.key)
            .collect::<BTreeSet<_>>()
            .len()
            != apply.targets.len()
        || fresh
            .assets
            .iter()
            .map(|t| &t.key)
            .collect::<BTreeSet<_>>()
            .len()
            != fresh.assets.len()
    {
        return Err("写真の ID とフルアクセスを確認してください。".into());
    }
    for target in &apply.targets {
        let fact = fresh
            .assets
            .iter()
            .find(|f| f.key == target.key)
            .ok_or("写真を取得できません。Apple Photos で確認してください。")?;
        let required = match apply.action {
            VisibilityAction::Hide => AppleVisibility::Visible,
            VisibilityAction::Unhide => AppleVisibility::Hidden,
        };
        if target.key.scope != apply.scope
            || !fact.full_access
            || !fact.can_edit_properties
            || fact.visibility != required
            || fact.fresh_revision.is_empty()
            || fact.fresh_revision != target.fresh_revision
            || witness(fact)? != target.expected_witness
        {
            return Err("変更直前に写真の状態または権限が変わりました。".into());
        }
    }
    Ok(())
}

/// Known preflight constraints only: native properties capability is freshly checked later.
#[must_use]
pub fn hide_keys(state: &crate::app::SavedLibrary) -> Vec<AssetKey> {
    use crate::domain::ScanAccess;
    let access = crate::privacy::ContentAccess::new(state);
    let mut ids = BTreeSet::new();
    if state
        .apple_visibility_operations
        .iter()
        .any(|o| validate_operation(o, &state.apple_scope).is_err() || !ids.insert(&o.id))
    {
        return vec![];
    }
    let mut ids = BTreeSet::new();
    if state.pending_apple_trash.iter().any(|o| {
        crate::trash::validate_apple_trash_operation(o, &state.apple_scope).is_err()
            || !ids.insert(&o.id)
    }) {
        return vec![];
    }
    state
        .snapshots
        .iter()
        .filter(|s| {
            s.provider == Provider::Apple
                && s.scope == state.apple_scope
                && s.access == ScanAccess::Full
        })
        .flat_map(|s| &s.assets)
        .filter(|a| {
            access.visible(&a.key)
                && !state.pending_edit_pastes.iter().any(|p| p.key == a.key)
                && !state
                    .pending_trash
                    .iter()
                    .flat_map(|o| &o.assets)
                    .any(|p| p.key == a.key)
                && !state
                    .pending_apple_trash
                    .iter()
                    .flat_map(|o| &o.assets)
                    .any(|p| p.key == a.key || !p.checksums().is_disjoint(&a.checksums()))
        })
        .map(|a| a.key.clone())
        .collect()
}
