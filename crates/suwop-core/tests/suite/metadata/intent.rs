use super::*;
use suwop_core::metadata::{MetadataEdit, MetadataOutcome};

#[derive(Clone, Copy)]
enum IntentFault {
    ConcurrentReject,
    ConflictingRecord,
    Reject,
    LostAck,
    RejectReadFail,
    LostAckReadFail,
    LostAckCloseReject,
    LostAckCloseAck,
    LostAckCloseReadFail,
}
struct IntentNative {
    disk: SavedLibrary,
    fault: IntentFault,
    provider_requests: usize,
    saves: usize,
}
impl IntentNative {
    fn reply(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::AppleMetadataObserve { .. } => {
                serde_json::to_value(&self.disk.snapshots[0].assets).map_err(|e| e.to_string())
            }
            ShellOperation::AppleScan { .. } => {
                let mut fresh = self.disk.snapshots[0].clone();
                fresh.access = ScanAccess::Full;
                serde_json::to_value(fresh).map_err(|e| e.to_string())
            }
            ShellOperation::Persist(state) => self.save(state),
            ShellOperation::ReadState => {
                Ok(serde_json::to_value(&self.disk).map_err(|e| e.to_string())?)
            }
            ShellOperation::ReadStateVersioned => {
                if matches!(
                    self.fault,
                    IntentFault::RejectReadFail | IntentFault::LostAckReadFail
                ) || (self.saves > 1 && matches!(self.fault, IntentFault::LostAckCloseReadFail))
                {
                    return Err("readback unavailable".into());
                }
                Ok(json!({"revision":"actual-test-row","state":self.disk}))
            }
            _ => {
                self.provider_requests += 1;
                Err("unexpected provider request".into())
            }
        }
    }
    fn save(&mut self, state: &SavedLibrary) -> Result<Value, String> {
        self.saves += 1;
        let initial = self.saves == 1;
        if initial && matches!(self.fault, IntentFault::ConcurrentReject) {
            self.disk
                .metadata_operations
                .push(known_date_baseline(&self.disk.snapshots[0].assets)?);
            self.disk.snapshots[0].scanned_at = Some(4321.0);
            return Err("concurrent durable catalog won".into());
        }
        if initial && matches!(self.fault, IntentFault::ConflictingRecord) {
            let mut other = state
                .metadata_operations
                .last()
                .ok_or("missing requested record")?
                .clone();
            other.edit = MetadataEdit::Description {
                text: "other writer intent".into(),
            };
            other.member_edits = vec![other.edit.clone()];
            self.disk.metadata_operations.push(other);
            return Err("same operation ID has a different durable owner".into());
        }
        if initial
            && matches!(
                self.fault,
                IntentFault::Reject | IntentFault::RejectReadFail
            )
        {
            return Err("intent definitely rejected".into());
        }
        if !initial && matches!(self.fault, IntentFault::LostAckCloseReject) {
            return Err("cannot save no-submission proof".into());
        }
        suwop_core::metadata::validate_record_transition(
            &self.disk.metadata_operations,
            &state.metadata_operations,
        )?;
        self.disk = serde_json::from_value(serde_json::to_value(state).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        if initial
            || matches!(
                self.fault,
                IntentFault::LostAckCloseAck | IntentFault::LostAckCloseReadFail
            )
        {
            return Err("lost save acknowledgement".into());
        }
        Ok(Value::Null)
    }
    fn drive(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        while !effects.is_empty() {
            let Effect::Io(mut effect) = effects.remove(0);
            let response = match self.reply(&effect.operation) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(
                core.resolve(&mut effect, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        Ok(())
    }
}
fn attempt(core: &Core<Suwop>, native: &mut IntentNative) -> Result<(), String> {
    native.drive(
        core,
        Event::EditMetadata {
            keys: vec![native.disk.snapshots[0].assets[0].key.clone()],
            edit: MetadataEdit::Location {
                latitude: "35".into(),
                longitude: "139".into(),
            },
            id: "bbbbcccc-dddd-4eee-8fff-111122223333".into(),
        },
    )
}
fn fixture(fault: IntentFault) -> (Core<Suwop>, IntentNative) {
    let mut disk = fixture_state(Provider::Apple, ScanAccess::Full);
    disk.receipts.clear();
    // Another journal/catalog field must survive a fresh-disk adoption.
    disk.snapshots[0].scanned_at = Some(1234.0);
    let core = Core::new_with(
        Suwop,
        Model {
            ready: true,
            state: disk.clone(),
            ..Model::default()
        },
    );
    (
        core,
        IntentNative {
            disk,
            fault,
            provider_requests: 0,
            saves: 0,
        },
    )
}
#[test]
fn rejected_initial_intent_never_becomes_a_later_durable_unknown() -> Result<(), String> {
    for fault in [IntentFault::Reject, IntentFault::RejectReadFail] {
        let (core, mut native) = fixture(fault);
        attempt(&core, &mut native)?;
        assert_eq!(native.provider_requests, 0);
        assert!(core.view().error.is_some());
        assert!(native.disk.metadata_operations.is_empty());
        // A later ordinary refresh persists this in-memory state. It must not
        // smuggle the unacknowledged append into the journal.
        native.drive(
            &core,
            Event::Refresh {
                permission: false,
                now: 9.0,
            },
        )?;
        assert!(native.disk.metadata_operations.is_empty());
        let serialized = serde_json::to_value(&native.disk).map_err(|e| e.to_string())?;
        assert!(serialized.get("metadataIntentHolds").is_none());
        assert_eq!(native.provider_requests, 0);
    }
    Ok(())
}
#[test]
fn lost_initial_ack_closes_only_confirmed_owned_intent_without_provider_calls() -> Result<(), String>
{
    for fault in [
        IntentFault::LostAck,
        IntentFault::LostAckCloseAck,
        IntentFault::LostAckCloseReject,
        IntentFault::LostAckCloseReadFail,
    ] {
        let (core, mut native) = fixture(fault);
        attempt(&core, &mut native)?;
        assert_eq!(native.provider_requests, 0);
        let expected = if matches!(fault, IntentFault::LostAckCloseReject) {
            MetadataOutcome::SubmittedUnknown
        } else {
            MetadataOutcome::NotApplied
        };
        assert_eq!(native.disk.metadata_operations[0].outcome, expected);
        assert_eq!(native.disk.snapshots[0].scanned_at, Some(1234.0));
        if matches!(fault, IntentFault::LostAckCloseReadFail) {
            assert_eq!(
                core.view().metadata_operations.last().map(|r| r.outcome),
                Some(MetadataOutcome::SubmittedUnknown)
            );
            native.drive(
                &core,
                Event::Refresh {
                    permission: false,
                    now: 13.0,
                },
            )?;
            assert_eq!(
                native.disk.metadata_operations[0].outcome,
                MetadataOutcome::NotApplied,
                "stale volatile uncertainty cannot roll back the acknowledged durable no-write closure"
            );
        }
        // Restart derives fences from the actual durable outcome, not an
        // unacknowledged in-memory record or a resumed provider command.
        let restarted = Core::new_with(Suwop, Model::default());
        native.drive(
            &restarted,
            Event::Initialize {
                scope: "apple".into(),
            },
        )?;
        native.drive(
            &restarted,
            Event::Refresh {
                permission: false,
                now: 14.0,
            },
        )?;
        assert_eq!(
            restarted
                .view()
                .metadata_operations
                .last()
                .map(|r| r.outcome),
            Some(expected)
        );
        assert!(native.disk.metadata_intent_holds.is_empty());
        assert_eq!(native.provider_requests, 0);
    }
    Ok(())
}
#[test]
fn unreadable_initial_save_keeps_nonpersistent_holds_across_refresh_and_mutators()
-> Result<(), String> {
    for fault in [IntentFault::RejectReadFail, IntentFault::LostAckReadFail] {
        let (core, mut native) = fixture(fault);
        let key = native.disk.snapshots[0].assets[0].key.clone();
        attempt(&core, &mut native)?;
        assert!(core.view().ordinary_content_keys.is_empty());
        native.drive(
            &core,
            Event::Refresh {
                permission: false,
                now: 11.0,
            },
        )?;
        assert!(core.view().ordinary_content_keys.is_empty());
        let saved = native.saves;
        for event in [
            Event::SetFavorite {
                keys: vec![key.clone()],
                value: true,
            },
            Event::SetMetadata {
                keys: vec![key.clone()],
                input: MetadataInput {
                    action: MetadataAction::SetLocation,
                    captured_at: None,
                    time_zone: None,
                    latitude: Some("1".into()),
                    longitude: Some("2".into()),
                },
            },
            Event::TrashApple {
                keys: vec![key.clone()],
                id: "00000000-0000-4000-8000-000000000001".into(),
            },
        ] {
            native.drive(&core, event)?;
            assert_eq!(native.provider_requests, 0);
            assert_eq!(
                native.saves, saved,
                "a later write must stop before native I/O or persistence"
            );
        }
        assert!(
            native.disk.metadata_intent_holds.is_empty(),
            "native persistence never receives a hold authority through serialization"
        );
    }
    Ok(())
}

#[test]
fn failed_intent_readback_preserves_fresh_other_journal_and_never_closes_a_conflict()
-> Result<(), String> {
    for fault in [
        IntentFault::ConcurrentReject,
        IntentFault::ConflictingRecord,
    ] {
        let (core, mut native) = fixture(fault);
        attempt(&core, &mut native)?;
        assert_eq!(native.provider_requests, 0);
        assert_eq!(
            native.saves, 1,
            "non-owned durable records must never be settled"
        );
        assert_eq!(native.disk.metadata_operations.len(), 1);
        if matches!(fault, IntentFault::ConcurrentReject) {
            assert_eq!(native.disk.snapshots[0].scanned_at, Some(4321.0));
            native.drive(
                &core,
                Event::Refresh {
                    permission: false,
                    now: 12.0,
                },
            )?;
            assert_eq!(native.disk.metadata_operations.len(), 1);
            assert_eq!(
                native.disk.metadata_operations[0].id,
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
            );
            assert_eq!(
                native.disk.metadata_operations[0].outcome,
                MetadataOutcome::VerifiedApplied
            );
        } else {
            assert!(
                matches!(&native.disk.metadata_operations[0].edit, MetadataEdit::Description { text } if text == "other writer intent")
            );
            assert_eq!(
                native.disk.metadata_operations[0].outcome,
                MetadataOutcome::SubmittedUnknown
            );
        }
    }
    Ok(())
}
