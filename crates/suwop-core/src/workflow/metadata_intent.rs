//! Initial intent persistence has not granted provider submission authority.
//! Never let an unacknowledged append become a false Unknown on a later save.
use super::Runtime;
use crate::{
    app::{ShellOperation, io},
    metadata::{MetadataOutcome, MetadataRecord},
};
use serde_json::Value;

impl Runtime<'_> {
    pub(super) async fn metadata_failed_intent_save(&mut self, intent: &MetadataRecord) {
        // Retire this private cursor before any recovery await. It has never
        // emitted a provider request and cannot be resumed by this readback.
        self.state
            .metadata_operations
            .retain(|record| record.id != intent.id);
        let result: Result<Value, String> = io(self.ctx, ShellOperation::ReadStateVersioned).await;
        let Ok(read) = result else {
            self.hold_metadata_intent(intent);
            return;
        };
        if read
            .get("revision")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            self.hold_metadata_intent(intent);
            return;
        }
        let Some(raw) = read.get("state") else {
            self.hold_metadata_intent(intent);
            return;
        };
        if raw.is_null() {
            // A confirmed empty store did not accept this intent. Prior
            // in-memory catalogs are kept; there is no new journal to export.
            return;
        }
        let Ok(state) = crate::workflow::migrate(raw.clone()) else {
            self.hold_metadata_intent(intent);
            return;
        };
        let owned = state
            .metadata_operations
            .iter()
            .any(|record| same_intent(intent, record));
        // Preserve every durable field/journal from the fresh row, not a stale
        // baseline merge. Process-local holds are not present in that row.
        let holds = std::mem::take(&mut self.state.metadata_intent_holds);
        self.state = state;
        self.state.metadata_intent_holds = holds;
        self.session = None;
        if owned {
            // Only the exact acknowledged initial intent may be closed by this
            // cursor's no-submission proof. A failed close retains durable
            // Unknown; a lost close ACK is independently read back.
            self.metadata_not_applied(&intent.id).await;
        }
    }

    fn hold_metadata_intent(&mut self, intent: &MetadataRecord) {
        for key in &intent.keys {
            if !self.state.metadata_intent_holds.contains(key) {
                self.state.metadata_intent_holds.push(key.clone());
            }
        }
    }
}

fn same_intent(expected: &MetadataRecord, actual: &MetadataRecord) -> bool {
    if actual.outcome != MetadataOutcome::SubmittedUnknown {
        return false;
    }
    let mut expected = expected.clone();
    expected.current.clone_from(&actual.current);
    match (serde_json::to_value(expected), serde_json::to_value(actual)) {
        (Ok(expected), Ok(actual)) => expected == actual,
        _ => false,
    }
}
