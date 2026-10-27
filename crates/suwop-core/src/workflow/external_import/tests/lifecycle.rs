use super::{item, runtime};
use crate::app::{Effect, Event, SavedLibrary, ShellResponse};
use crate::domain::Provider;
use crate::external_import::{ImportJournal, ImportPhase, ImportPurpose};
use crate::workflow::ShellOperation;
use serde_json::json;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};

fn records() -> Vec<ImportJournal> {
    (0..3)
        .map(|index| {
            let mut item = item();
            item.id = format!("00000000-0000-4000-8000-{index:012}");
            item.resources[0].token = format!("token-{index}");
            ImportJournal {
                id: item.id.clone(),
                staging_operation: "operation".into(),
                created_at: 1.0,
                purpose: ImportPurpose::External,
                destination: Provider::Apple,
                destination_scope: "apple".into(),
                source_keys: vec![],
                item,
                phase: ImportPhase::Prepared,
                destination_keys: vec![],
                created: None,
            }
        })
        .collect()
}

#[derive(Default)]
struct Driver {
    durable: Vec<ImportJournal>,
    saves: usize,
    fail_save: Option<usize>,
    submitted: usize,
    released: usize,
    cancel_after_prepared: Option<Arc<AtomicU64>>,
    startup: Option<SavedLibrary>,
}
impl Driver {
    fn finish(&mut self, command: &mut crux_core::Command<Effect, Event>) -> Result<(), String> {
        for _ in 0..60 {
            let effects: Vec<_> = command.effects().collect();
            if effects.is_empty() {
                return Ok(());
            }
            for Effect::Io(mut effect) in effects {
                let response = self.response(&effect.operation)?;
                effect.resolve(response).map_err(|_| "resolve")?;
            }
        }
        Err("import fixture did not settle".into())
    }
    fn response(&mut self, operation: &ShellOperation) -> Result<ShellResponse, String> {
        let mut response = ShellResponse {
            value: Some(json!(null)),
            error: None,
        };
        match operation {
            ShellOperation::ReadState => {
                response.value = Some(
                    serde_json::to_value(self.startup.as_ref().ok_or("missing startup state")?)
                        .map_err(|e| e.to_string())?,
                );
            }
            ShellOperation::ResolveImportResource { .. } => {
                response.value = Some(json!("/fixture"));
            }
            ShellOperation::Persist(state) => {
                self.saves += 1;
                if self.fail_save == Some(self.saves) {
                    response.value = None;
                    response.error = Some("disk unavailable".into());
                } else {
                    crate::external_import::validate_transition(
                        &self.durable,
                        &state.external_imports,
                    )?;
                    self.durable.clone_from(&state.external_imports);
                    if let Some(generation) = self.cancel_after_prepared.take() {
                        generation.store(1, Ordering::SeqCst);
                    }
                }
            }
            ShellOperation::AppleImportStaged { .. } => {
                self.submitted += 1;
                assert_eq!(self.durable[0].phase, ImportPhase::Submitting);
                response.value = None;
                response.error = Some("native callback lost or cancelled".into());
            }
            ShellOperation::ReleaseImportStaging { .. } => {
                assert!(self.durable.iter().all(|r| !r.retains_staged_bytes()));
                self.released += 1;
            }
            _ => return Err(format!("unexpected fixture operation: {operation:?}")),
        }
        Ok(response)
    }
}

type Observed = Arc<Mutex<Option<(Result<(), String>, Vec<ImportJournal>)>>>;

fn batch(driver: &mut Driver) -> Result<(Result<(), String>, Vec<ImportJournal>), String> {
    let observed: Observed = Arc::default();
    let sink = observed.clone();
    let generation = driver.cancel_after_prepared.clone().unwrap_or_default();
    let mut command = crux_core::Command::new(move |ctx| async move {
        let mut runtime = runtime(&ctx);
        runtime.ordinary_generation = generation;
        let result = runtime
            .import_staged(
                "operation",
                Provider::Apple,
                records().into_iter().map(|r| r.item).collect(),
                1.0,
            )
            .await;
        if let Ok(mut sink) = sink.lock() {
            *sink = Some((result, runtime.state.external_imports));
        }
    });
    driver.finish(&mut command)?;
    let result = observed
        .lock()
        .map_err(|_| "lock")?
        .take()
        .ok_or("batch not completed")?;
    Ok(result)
}

#[test]
fn first_item_failure_cancels_unsubmitted_remainder_but_retains_unknown_bytes() -> Result<(), String>
{
    let mut driver = Driver::default();
    let (result, state) = batch(&mut driver)?;
    assert!(result.is_err());
    assert_eq!(driver.submitted, 1);
    assert_eq!(driver.released, 0);
    assert_eq!(state, driver.durable);
    assert_eq!(
        state.iter().map(|r| r.phase).collect::<Vec<_>>(),
        vec![
            ImportPhase::Uncertain,
            ImportPhase::Cancelled,
            ImportPhase::Cancelled
        ]
    );
    Ok(())
}

#[test]
fn cancellation_before_first_submit_is_durable_before_releasing_entire_batch() -> Result<(), String>
{
    let mut driver = Driver {
        cancel_after_prepared: Some(Arc::default()),
        ..Driver::default()
    };
    let (result, state) = batch(&mut driver)?;
    assert!(result.is_err());
    assert_eq!(driver.submitted, 0);
    assert_eq!(driver.released, 1);
    assert!(state.iter().all(|r| r.phase == ImportPhase::Cancelled));
    assert_eq!(state, driver.durable);
    Ok(())
}

#[test]
fn cancelled_remainder_save_failure_rolls_back_and_never_releases_bytes() -> Result<(), String> {
    let mut driver = Driver {
        cancel_after_prepared: Some(Arc::default()),
        fail_save: Some(2),
        ..Driver::default()
    };
    let (result, state) = batch(&mut driver)?;
    assert!(result.is_err());
    assert_eq!(driver.submitted, 0);
    assert_eq!(driver.released, 0);
    assert!(state.iter().all(|r| r.phase == ImportPhase::Prepared));
    assert_eq!(state, driver.durable);
    Ok(())
}

#[test]
fn startup_after_interrupted_batch_cancels_prepared_without_resending_uncertain()
-> Result<(), String> {
    for (submitted, fail_save) in [(false, None), (true, None), (false, Some(1))] {
        let mut persisted = records();
        if submitted {
            persisted[0].phase = ImportPhase::Submitting;
            persisted[0].created = Some(true);
            persisted[0].destination_keys = vec![crate::domain::AssetKey {
                provider: Provider::Apple,
                scope: "apple".into(),
                asset_id: "known-created-id".into(),
            }];
        }
        let mut driver = Driver {
            durable: persisted.clone(),
            fail_save,
            startup: Some(SavedLibrary {
                schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                external_imports: persisted.clone(),
                ..SavedLibrary::default()
            }),
            ..Driver::default()
        };
        let observed: Observed = Arc::default();
        let sink = observed.clone();
        let mut command = crux_core::Command::new(move |ctx| async move {
            let mut runtime = runtime(&ctx);
            let result = runtime.initialize("apple".into()).await.map(|_| ());
            if let Ok(mut sink) = sink.lock() {
                *sink = Some((result, runtime.state.external_imports));
            }
        });
        driver.finish(&mut command)?;
        let (result, state) = observed
            .lock()
            .map_err(|_| "lock")?
            .take()
            .ok_or("startup not completed")?;
        assert_eq!(driver.submitted, 0);
        if fail_save.is_none() {
            assert!(result.is_ok(), "startup error: {result:?}");
        }
        assert_eq!(state, driver.durable);
        if fail_save.is_some() {
            assert!(result.is_err());
            assert_eq!(state, persisted);
            assert_eq!(driver.released, 0);
        } else {
            assert!(result.is_ok());
            assert!(state[1..].iter().all(|r| r.phase == ImportPhase::Cancelled));
            assert_eq!(state[0].destination_keys, persisted[0].destination_keys);
            assert_eq!(
                state[0].phase,
                if submitted {
                    ImportPhase::Uncertain
                } else {
                    ImportPhase::Cancelled
                }
            );
            assert_eq!(driver.released, usize::from(!submitted));
        }
    }
    Ok(())
}
