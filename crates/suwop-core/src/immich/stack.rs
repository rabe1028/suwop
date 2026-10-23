use crate::domain::{ImmichStackMembership, ImmichStackState};
use serde::{Deserialize, Serialize};

/// Keep unknown/stacked safety knowledge even if the server omits membership fields.
#[derive(Debug, Clone, Default, schemars::JsonSchema)]
pub struct StackInventory {
    pub state: ImmichStackState,
    pub membership: Option<ImmichStackMembership>,
}
impl StackInventory {
    #[must_use]
    pub fn is_unknown(&self) -> bool {
        self.state == ImmichStackState::Unknown
    }
}
impl PartialEq<ImmichStackState> for StackInventory {
    fn eq(&self, other: &ImmichStackState) -> bool {
        self.state == *other
    }
}
impl<'de> Deserialize<'de> for StackInventory {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(d)?;
        let state = if value.is_null() {
            ImmichStackState::Unstacked
        } else if value.is_object() {
            ImmichStackState::Stacked
        } else {
            ImmichStackState::Unknown
        };
        let membership = serde_json::from_value::<ImmichStackMembership>(value)
            .ok()
            .filter(|s| {
                super::valid_id(&s.id).is_ok()
                    && super::valid_id(&s.primary_asset_id).is_ok()
                    && s.asset_count > 1
            });
        Ok(Self { state, membership })
    }
}
impl Serialize for StackInventory {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        if let Some(membership) = &self.membership {
            membership.serialize(s)
        } else if self.state == ImmichStackState::Stacked {
            serde_json::json!({}).serialize(s)
        } else {
            s.serialize_none()
        }
    }
}
