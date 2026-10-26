//! Pure classification only. No HTTP, native effect, replay or fence release.
use crate::app::SavedLibrary;
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DurableReadback {
    Desired,
    Before,
    Uncertain,
}

#[must_use]
pub fn classify(
    before: &SavedLibrary,
    desired: &SavedLibrary,
    raw: Option<&Value>,
) -> DurableReadback {
    let Some(raw) = raw else {
        return DurableReadback::Uncertain;
    };
    let version = super::CURRENT_SCHEMA_VERSION;
    if before.schema_version != version
        || desired.schema_version != version
        || super::validate_transition(before, desired).is_err()
        || raw["schemaVersion"].as_u64() != Some(u64::from(version))
        || crate::workflow::migrate(raw.clone()).is_err()
    {
        return DurableReadback::Uncertain;
    }
    let matches = |state: &SavedLibrary| {
        serde_json::to_value(state)
            .ok()
            .is_some_and(|value| crate::immich_visibility::workflow::readback::matches(&value, raw))
    };
    if matches(desired) {
        DurableReadback::Desired
    } else if matches(before) {
        DurableReadback::Before
    } else {
        DurableReadback::Uncertain
    }
}
