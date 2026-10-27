use super::*;
use crate::app::{Context, Effect, Event, SavedLibrary, ShellResponse};
use crate::external_import::{ImportMetadata, StagedResource};
use crux_core::App;
use serde_json::json;
use std::sync::{Arc, Mutex};

fn runtime(ctx: &Context) -> Runtime<'_> {
    Runtime {
        refresh_persist_issued: false,
        ordinary_selected: vec![],
        denied_content: std::collections::BTreeSet::default(),
        ordinary_generation: Arc::default(),
        started_ordinary_generation: 0,
        ordinary_revision: "fixture".into(),
        session_published: false,
        apple_generation: Arc::default(),
        started_generation: 0,
        reversion_started: false,
        preferred_preview: None,
        ctx,
        state: SavedLibrary {
            schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
            apple_scope: "apple".into(),
            ..SavedLibrary::default()
        },
        session: None,
        workspace: None,
        editing_token: None,
        injected_registry: None,
    }
}
fn item() -> ImportItem {
    ImportItem {
        id: "item".into(),
        resources: vec![StagedResource {
            token: "token".into(),
            name: "photo.png".into(),
            role: crate::domain::ResourceRole::Image,
            media_type: "image/png".into(),
            sha256: "a".repeat(64),
            bytes: 4,
            content_identifier: None,
        }],
        metadata: ImportMetadata::default(),
    }
}

#[test]
fn failed_prepared_or_submitting_save_never_calls_provider_and_restores_memory()
-> Result<(), String> {
    for fail_at in [1, 2] {
        let observed = Arc::new(Mutex::new(None));
        let sink = observed.clone();
        let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
            let mut runtime = runtime(&ctx);
            let result = runtime
                .import_staged("operation", Provider::Apple, vec![item()], 1.0)
                .await;
            if let Ok(mut sink) = sink.lock() {
                *sink = Some((result, runtime.state.external_imports));
            }
        });
        let mut saves = 0;
        let mut submissions = 0;
        for _ in 0..30 {
            let effects: Vec<_> = command.effects().collect();
            if effects.is_empty() {
                break;
            }
            for Effect::Io(mut effect) in effects {
                let mut response = ShellResponse {
                    value: Some(serde_json::Value::Null),
                    error: None,
                };
                match &effect.operation {
                    ShellOperation::ResolveImportResource { .. } => {
                        response.value = Some(json!("/fixture"));
                    }
                    ShellOperation::Persist(_) => {
                        saves += 1;
                        if saves == fail_at {
                            response.value = None;
                            response.error = Some("disk unavailable".into());
                        }
                    }
                    ShellOperation::AppleImportStaged { .. }
                    | ShellOperation::ImportHttp { .. } => submissions += 1,
                    _ => return Err("unexpected native effect".into()),
                }
                effect.resolve(response).map_err(|_| "resolve")?;
            }
        }
        let (result, records) = observed
            .lock()
            .map_err(|_| "lock")?
            .take()
            .ok_or("not completed")?;
        assert!(result.is_err());
        assert_eq!(submissions, 0);
        if fail_at == 1 {
            assert!(records.is_empty());
        } else {
            assert_eq!(records[0].phase, ImportPhase::Prepared);
        }
    }
    Ok(())
}

#[test]
fn lost_native_response_leaves_durable_uncertainty_without_a_second_creation() -> Result<(), String>
{
    let observed = Arc::new(Mutex::new(None));
    let sink = observed.clone();
    let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
        let mut runtime = runtime(&ctx);
        let result = runtime
            .import_staged("operation", Provider::Apple, vec![item()], 1.0)
            .await;
        if let Ok(mut sink) = sink.lock() {
            *sink = Some((result, runtime.state.external_imports));
        }
    });
    let mut submissions = 0;
    let mut durable = vec![];
    for _ in 0..30 {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut effect) in effects {
            let mut response = ShellResponse {
                value: Some(serde_json::Value::Null),
                error: None,
            };
            match &effect.operation {
                ShellOperation::ResolveImportResource { .. } => {
                    response.value = Some(json!("/fixture"));
                }
                ShellOperation::Persist(state) => durable.clone_from(&state.external_imports),
                ShellOperation::AppleImportStaged { .. } => {
                    assert_eq!(durable[0].phase, ImportPhase::Submitting);
                    submissions += 1;
                    response.value = None;
                    response.error = Some("response lost".into());
                }
                _ => return Err("unexpected native effect".into()),
            }
            effect.resolve(response).map_err(|_| "resolve")?;
        }
    }
    let (result, records) = observed
        .lock()
        .map_err(|_| "lock")?
        .take()
        .ok_or("not completed")?;
    assert!(result.is_err());
    assert_eq!(submissions, 1);
    assert_eq!(records[0].phase, ImportPhase::Uncertain);
    assert_eq!(durable, records);
    assert!(records[0].retains_staged_bytes());
    assert!(records[0].prepare_submission().is_err());
    Ok(())
}

#[test]
fn duplicate_rejects_multiple_physical_sources_before_export_or_staging() -> Result<(), String> {
    for current in [false, true] {
        let result = Arc::new(Mutex::new(None));
        let observed = result.clone();
        let keys: Vec<_> = ["jpeg-photo", "unrelated-raw-photo"]
            .into_iter()
            .map(|id| AssetKey {
                provider: Provider::Apple,
                scope: "apple".into(),
                asset_id: id.into(),
            })
            .collect();
        let assets = keys.iter().enumerate().map(|(index,key)| serde_json::from_value(json!({
                "key": key, "appleVisibility":"visible", "name": if index == 0 {"photo.jpg"} else {"other.dng"},
                "revision":"one", "resources":[{"id":"resource","name":"original","role": if index == 0 {"image"} else {"rawImage"}}],
                "capturedAt":1_700_000_000.0 + if index == 0 {0.0} else {1.0}, "latitude":35.0 + if index == 0 {0.0} else {1.0},
                "longitude":139.0, "isFavorite":index == 0, "inventoryComplete":true,
                "isOffline":false,"deletionBlockers":[]
            }))).collect::<Result<Vec<crate::domain::StoredAsset>,_>>().map_err(|e|e.to_string())?;
        let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
            let mut runtime = runtime(&ctx);
            runtime
                .state
                .snapshots
                .push(crate::domain::LibrarySnapshot {
                    provider: Provider::Apple,
                    scope: "apple".into(),
                    assets,
                    access: crate::domain::ScanAccess::Full,
                    scanned_at: Some(1.0),
                });
            let output = runtime
                .duplicate(&keys, Provider::Apple, current, "operation", 1.0)
                .await;
            if let Ok(mut observed) = observed.lock() {
                *observed = Some(output);
            }
        });
        assert!(
            command.effects().next().is_none(),
            "rejected duplicate must not export/stage/write"
        );
        let failure = result
            .lock()
            .map_err(|_| "lock")?
            .take()
            .ok_or("not completed")?
            .err()
            .ok_or("multiple keys unexpectedly accepted")?;
        assert!(failure.contains("一つ選択"), "{failure}");
    }
    Ok(())
}

#[test]
fn verified_import_publishes_fresh_destination_with_its_journal_and_rolls_back_both_on_save_failure()
-> Result<(), String> {
    for fail in [false, true] {
        let observed = Arc::new(Mutex::new(None));
        let sink = observed.clone();
        let key = AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "fresh".into(),
        };
        let asset = serde_json::from_value(json!({"key":key,"appleVisibility":"visible","name":"fresh.png","revision":"r","resources":[],"isFavorite":false,"inventoryComplete":true,"isOffline":false,"deletionBlockers":[]})).map_err(|e|e.to_string())?;
        let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
            let mut runtime = runtime(&ctx);
            let mut record = ImportJournal {
                id: "item".into(),
                staging_operation: "op".into(),
                created_at: 1.0,
                purpose: ImportPurpose::External,
                destination: Provider::Apple,
                destination_scope: "apple".into(),
                source_keys: vec![],
                item: item(),
                phase: ImportPhase::Submitting,
                destination_keys: vec![key],
                created: Some(true),
            };
            runtime.state.external_imports.push(record.clone());
            record.phase = ImportPhase::Verified;
            let result = runtime.save_verified_import(record, &[asset]).await;
            if let Ok(mut sink) = sink.lock() {
                *sink = Some((result, runtime.state));
            }
        });
        for _ in 0..3 {
            let effects = command.effects().collect::<Vec<_>>();
            if effects.is_empty() {
                break;
            }
            for Effect::Io(mut request) in effects {
                let ShellOperation::Persist(state) = &request.operation else {
                    return Err("unexpected effect".into());
                };
                assert_eq!(state.external_imports[0].phase, ImportPhase::Verified);
                assert_eq!(state.snapshots[0].assets[0].key.asset_id, "fresh");
                request
                    .resolve(ShellResponse {
                        value: (!fail).then_some(serde_json::Value::Null),
                        error: fail.then(|| "disk failed".into()),
                    })
                    .map_err(|_| "resolve")?;
            }
        }
        let (result, state) = observed
            .lock()
            .map_err(|_| "lock")?
            .take()
            .ok_or("not completed")?;
        if fail {
            assert!(result.is_err());
            assert!(state.snapshots.is_empty());
            assert_eq!(state.external_imports[0].phase, ImportPhase::Submitting);
        } else {
            result?;
            let view = crate::app::Suwop.view(&crate::app::Model {
                state,
                ready: true,
                ..crate::app::Model::default()
            });
            assert_eq!(view.external_imports.len(), 1);
            assert!(view.import_notices.is_empty());
        }
    }
    Ok(())
}
