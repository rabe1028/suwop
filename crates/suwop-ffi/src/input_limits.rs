//! Native catalog snapshots can exceed a network page. Only core-issued bulk
//! replies and local catalog persistence receive the larger, still finite budget.
use serde_json::Value;
use std::collections::BTreeSet;

const ORDINARY: usize = 16 * 1024 * 1024;
const CATALOG: usize = 256 * 1024 * 1024;
pub(crate) const ERROR: &str = "写真一覧のデータが受け渡し上限を超えました。処理を中止しました。";

fn require(accepted: bool) -> Result<(), String> {
    accepted.then_some(()).ok_or_else(|| ERROR.into())
}

pub(crate) fn admit_envelope(action: u32, bytes: usize) -> Result<(), String> {
    require(
        bytes
            <= if matches!(action, 1 | 15) {
                CATALOG
            } else {
                ORDINARY
            },
    )
}

pub(crate) fn admit_catalog(value: &Value, bytes: usize) -> Result<(), String> {
    require(bytes <= ORDINARY || value["command"]["type"] == "persist")
}

pub(crate) fn admit_reply(ids: &BTreeSet<u32>, id: u32, bytes: usize) -> Result<(), String> {
    require(bytes <= ORDINARY || ids.contains(&id))
}

pub(crate) fn remember_replies(ids: &mut BTreeSet<u32>, value: &Value) {
    if let Some(effects) = value.as_array() {
        for effect in effects {
            if matches!(
                effect["effect"]["Io"]["type"].as_str(),
                Some("appleScan" | "readState")
            ) && let Some(id) = effect["id"].as_u64().and_then(|id| u32::try_from(id).ok())
            {
                ids.insert(id);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn budgets_remain_bounded_and_network_replies_cannot_claim_bulk_authority() {
        let mut ids = BTreeSet::new();
        remember_replies(
            &mut ids,
            &json!([
                {"id":1,"effect":{"Io":{"type":"appleScan"}}},
                {"id":2,"effect":{"Io":{"type":"readState"}}},
                {"id":3,"effect":{"Io":{"type":"http"}}}
            ]),
        );
        assert!(admit_reply(&ids, 1, ORDINARY + 1).is_ok());
        assert!(admit_reply(&ids, 2, ORDINARY + 1).is_ok());
        assert!(admit_reply(&ids, 3, ORDINARY + 1).is_err());
        assert!(admit_reply(&ids, 4, ORDINARY + 1).is_err());
        assert!(admit_envelope(0, ORDINARY + 1).is_err());
        assert!(admit_envelope(1, CATALOG).is_ok());
        assert!(admit_envelope(1, CATALOG + 1).is_err());
        assert!(admit_envelope(15, CATALOG + 1).is_err());
        assert!(admit_catalog(&json!({"command":{"type":"persist"}}), ORDINARY + 1).is_ok());
        assert!(admit_catalog(&json!({"command":{"type":"search"}}), ORDINARY + 1).is_err());
    }
}
