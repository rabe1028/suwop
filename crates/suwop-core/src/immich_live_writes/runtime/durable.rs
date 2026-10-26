//! Versioned persistence of only the Live journal; runtime authority is checked by callers.
use crate::app::{Context, SavedLibrary, ShellOperation, io};
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone)]
pub(super) struct SaveFailure {
    pub(super) state: Option<SavedLibrary>,
    pub(super) uncertain: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Versioned {
    revision: String,
    state: Option<Value>,
}
fn same_journal(a: &SavedLibrary, b: &SavedLibrary) -> bool {
    a.immich_live_operations == b.immich_live_operations
        && a.immich_live_unstarted_closures == b.immich_live_unstarted_closures
        && a.immich_live_legacy_reconciliations == b.immich_live_legacy_reconciliations
}
async fn read(ctx: &Context) -> Result<(String, SavedLibrary), ()> {
    let versioned: Versioned = io(ctx, ShellOperation::ReadStateVersioned)
        .await
        .map_err(|_| ())?;
    let raw = versioned.state.ok_or(())?;
    if raw["schemaVersion"].as_u64() != Some(u64::from(super::super::CURRENT_SCHEMA_VERSION)) {
        return Err(());
    }
    let state = crate::workflow::migrate(raw).map_err(|_| ())?;
    Ok((versioned.revision, state))
}
async fn recover(
    ctx: &Context,
    before: &SavedLibrary,
    desired: &SavedLibrary,
) -> Result<SavedLibrary, SaveFailure> {
    match read(ctx).await {
        Ok((_, state)) if same_journal(&state, desired) => Ok(state),
        Ok((_, state)) => {
            let uncertain = !same_journal(&state, before);
            Err(SaveFailure {
                state: Some(state),
                uncertain,
            })
        }
        Err(()) => Err(SaveFailure {
            state: None,
            uncertain: true,
        }),
    }
}
pub(super) async fn save(
    ctx: &Context,
    before: &SavedLibrary,
    desired: &SavedLibrary,
) -> Result<SavedLibrary, SaveFailure> {
    // Initial attempt plus two retries for a competing, unrelated state writer.
    for attempt in 0..3 {
        let Ok((revision, current)) = read(ctx).await else {
            return recover(ctx, before, desired).await;
        };
        if same_journal(&current, desired) {
            return Ok(current);
        }
        if !same_journal(&current, before) {
            return Err(SaveFailure {
                state: Some(current),
                uncertain: true,
            });
        }
        let mut composed = current.clone();
        composed
            .immich_live_operations
            .clone_from(&desired.immich_live_operations);
        composed
            .immich_live_unstarted_closures
            .clone_from(&desired.immich_live_unstarted_closures);
        composed
            .immich_live_legacy_reconciliations
            .clone_from(&desired.immich_live_legacy_reconciliations);
        if super::super::validate_transition(&current, &composed).is_err() {
            return Err(SaveFailure {
                state: Some(current),
                uncertain: false,
            });
        }
        match io::<bool>(
            ctx,
            ShellOperation::PersistIfCurrent {
                revision,
                state: Box::new(composed.clone()),
            },
        )
        .await
        {
            Ok(true) => return Ok(composed),
            Ok(false) if attempt < 2 => {}
            Ok(false) | Err(_) => return recover(ctx, before, desired).await,
        }
    }
    unreachable!("bounded persistence loop returns on its final attempt")
}

#[cfg(test)]
mod tests;
