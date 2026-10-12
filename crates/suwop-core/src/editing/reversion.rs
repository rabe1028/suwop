use serde::{Deserialize, Serialize};

use crate::domain::{AssetKey, Provider, StoredAsset};

/// Native facts only: no pixel decoding, render plan or adjustment parser is
/// needed to explicitly discard all edits, including edits made by other apps.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppleReversionFacts {
    pub asset: StoredAsset,
    pub can_edit: bool,
    pub has_adjustments: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReversionPrompt {
    pub key: AssetKey,
    pub name: String,
}

pub fn verify_reversion_input(
    expected: &StoredAsset,
    facts: &AppleReversionFacts,
) -> Result<ReversionPrompt, String> {
    if expected.key.provider != Provider::Apple {
        return Err("この保存先の原本への復元は準備中です。".into());
    }
    super::verify_edit_source(expected, &facts.asset)?;
    if !facts.can_edit {
        return Err("この写真の編集を変更できません。".into());
    }
    if !facts.has_adjustments {
        return Err("この写真には戻す編集がありません。".into());
    }
    Ok(ReversionPrompt {
        key: expected.key.clone(),
        name: expected.name.clone(),
    })
}
