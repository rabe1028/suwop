//! Real generated fixture HTTP; prompt-independent metadata uses actual Core events.
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{Model, Suwop},
    domain::{LibrarySnapshot, Provider, ScanAccess},
    metadata::{MetadataEdit, MetadataOutcome},
};

pub(super) async fn exercise(ctx: &Context, session: &Session, id: &str) -> Result<(), String> {
    let asset = prepare_metadata_fixture(ctx, session, id).await?;
    let files = session.files(ctx, id).await?;
    let stored = asset.record(&session.scope, None, Some(&files));
    let key = stored.key.clone();
    let state = metadata_state(stored, session);
    let core = metadata_core(state.clone(), session);
    let mut journal = state;
    let operation = "b1111111-1111-4111-8111-111111111111";
    let caption = "Generated PP06 description 東京 — timezone/undo fixture";
    let writes = drive(
        ctx,
        &core,
        &mut journal,
        Event::EditMetadata {
            keys: vec![key.clone()],
            edit: MetadataEdit::Description {
                text: caption.into(),
            },
            id: operation.into(),
        },
    )
    .await?;
    assert_eq!(writes, 1);
    assert!(core.view().error.is_none());
    assert_eq!(
        journal.metadata_operations[0].outcome,
        MetadataOutcome::VerifiedApplied
    );
    assert_eq!(
        journal.metadata_operations[0].after[0].values.description,
        caption
    );
    super::wait_metadata_queues(ctx, session).await?;
    let recorded =
        serde_json::to_value(&journal.metadata_operations[0]).map_err(|error| error.to_string())?;
    let restarted = metadata_core(journal.clone(), session);
    let reads = drive(
        ctx,
        &restarted,
        &mut journal,
        Event::InspectMetadata {
            operation_id: operation.into(),
        },
    )
    .await?;
    assert_eq!(reads, 0);
    let unchanged =
        serde_json::to_value(&journal.metadata_operations[0]).map_err(|error| error.to_string())?;
    assert_eq!(recorded["before"], unchanged["before"]);
    assert_eq!(recorded["after"], unchanged["after"]);
    assert_eq!(recorded["outcome"], unchanged["outcome"]);
    verify_inspected_witness(&unchanged)?;
    let writes = drive(
        ctx,
        &restarted,
        &mut journal,
        Event::RestoreMetadata {
            id: "b2222222-2222-4222-8222-222222222222".into(),
            operation_id: operation.into(),
            original: false,
        },
    )
    .await?;
    assert_eq!(writes, 1);
    assert!(restarted.view().error.is_none());
    assert_eq!(journal.metadata_operations.len(), 2);
    assert_eq!(
        journal.metadata_operations[1].outcome,
        MetadataOutcome::VerifiedApplied
    );
    assert_eq!(
        journal.metadata_operations[1].after[0].values.description,
        journal.metadata_operations[0].before[0].values.description
    );
    Box::pin(exercise_date_location(ctx, &mut journal, &key, session)).await?;
    let observed = session.asset(ctx, id).await?;
    assert_eq!(asset.id, observed.id);
    assert_eq!(asset.checksum, observed.checksum);
    assert_eq!(asset.original_file_name, observed.original_file_name);
    Ok(())
}
async fn prepare_metadata_fixture(
    ctx: &Context,
    session: &Session,
    id: &str,
) -> Result<suwop_core::immich::Asset, String> {
    super::wait_metadata_queues(ctx, session).await?;
    // Null GPS is not accepted by the public DTO. Supported undo starts with a known point.
    let edit = MetadataEdit::Location {
        latitude: "40.7128".into(),
        longitude: "-74.0060".into(),
    };
    let change = edit.change()?.ok_or("missing setup location")?;
    session.metadata(ctx, &[id.into()], &change).await?;
    super::wait_metadata_queues(ctx, session).await?;
    let asset = session.asset(ctx, id).await?;
    let stored = asset.record(&session.scope, None, None);
    let values = suwop_core::metadata::MetadataValues {
        captured_at: stored.captured_at,
        time_zone: None,
        latitude: stored.latitude,
        longitude: stored.longitude,
        description: String::new(),
    };
    if !edit.matches(&values)? {
        return Err("fixture initial GPS did not survive completed server queues".into());
    }
    Ok(asset)
}
fn metadata_core(state: SavedLibrary, session: &Session) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            session: Some(session.clone()),
            ..Model::default()
        },
    )
}
fn metadata_state(stored: suwop_core::domain::StoredAsset, session: &Session) -> SavedLibrary {
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            assets: vec![stored],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        }],
        ..SavedLibrary::default()
    }
}
async fn drive(
    ctx: &Context,
    core: &Core<Suwop>,
    journal: &mut SavedLibrary,
    event: Event,
) -> Result<usize, String> {
    let event_kind = match &event {
        Event::EditMetadata {
            edit: MetadataEdit::CapturedAt { local, .. },
            ..
        } if local.starts_with("2024-07") => "date-after-location",
        Event::EditMetadata { edit, .. } => edit.field(),
        Event::InspectMetadata { .. } => "inspect",
        Event::RestoreMetadata { .. } => "restore",
        _ => "other",
    };
    let mut requests = core.process_event(event);
    let mut puts = 0;
    while !requests.is_empty() {
        let Effect::Io(mut request) = requests.remove(0);
        let value = match &request.operation {
            ShellOperation::Http(http) => {
                if http.method == "PUT" {
                    assert_eq!(
                        journal
                            .metadata_operations
                            .last()
                            .map(|record| record.outcome),
                        Some(MetadataOutcome::SubmittedUnknown)
                    );
                    puts += 1;
                }
                suwop_core::app::io::<Value>(ctx, ShellOperation::Http(http.clone())).await
            }
            ShellOperation::Persist(state) => {
                suwop_core::immich_live_writes::validate_transition(journal, state)?;
                *journal = state.clone();
                Ok(Value::Null)
            }
            ShellOperation::Wait { milliseconds } => {
                suwop_core::app::io::<Value>(
                    ctx,
                    ShellOperation::Wait {
                        milliseconds: *milliseconds,
                    },
                )
                .await
            }
            _ => Err("unexpected metadata fixture operation".into()),
        };
        let response = match value {
            Ok(value) => ShellResponse {
                value: Some(value),
                error: None,
            },
            Err(error) => ShellResponse {
                value: None,
                error: Some(error),
            },
        };
        requests.extend(
            core.resolve(&mut request, response)
                .map_err(|error| error.to_string())?,
        );
    }
    if let Some(error) = core.view().error {
        return Err(format!("metadata fixture {event_kind:?} refused: {error}"));
    }
    Ok(puts)
}

fn verify_inspected_witness(record: &Value) -> Result<(), String> {
    let after = &record["after"][0];
    let current = &record["current"][0]["witness"];
    if after == current {
        return Ok(());
    }
    let mut changed = Vec::new();
    for section in ["asset", "values"] {
        if let Some(fields) = after[section].as_object() {
            for (field, expected) in fields {
                if current[section].get(field) != Some(expected) {
                    changed.push(format!("{section}.{field}"));
                }
            }
        }
    }
    Err(format!(
        "metadata inspection differs from verified witness; unavailable={}; changed fields={}",
        record["current"][0]["unavailable"],
        changed.join(",")
    ))
}

async fn exercise_date_location(
    ctx: &Context,
    journal: &mut SavedLibrary,
    key: &AssetKey,
    session: &Session,
) -> Result<(), String> {
    let changes = [
        (
            "b3333333-3333-4333-8333-333333333333",
            MetadataEdit::CapturedAt {
                local: "2024-11-03T12:30:00.125".into(),
                zone: "Asia/Tokyo".into(),
                occurrence: None,
            },
        ),
        (
            "b4444444-4444-4444-8444-444444444444",
            MetadataEdit::Location {
                latitude: "37.7749".into(),
                longitude: "-122.4194".into(),
            },
        ),
        (
            "b7777777-7777-4777-8777-777777777777",
            MetadataEdit::CapturedAt {
                local: "2024-07-03T12:30:00.125".into(),
                zone: "Asia/Tokyo".into(),
                occurrence: None,
            },
        ),
    ];
    for (id, edit) in changes {
        let active = metadata_core(journal.clone(), session);
        let core = &active;
        let writes = drive(
            ctx,
            core,
            journal,
            Event::EditMetadata {
                keys: vec![key.clone()],
                edit: edit.clone(),
                id: id.into(),
            },
        )
        .await?;
        assert_eq!(writes, 1);
        let record = journal
            .metadata_operations
            .last()
            .ok_or("missing date/location operation")?;
        assert_eq!(record.outcome, MetadataOutcome::VerifiedApplied);
        assert!(edit.matches_provider(Provider::Immich, &record.after[0].values)?);
        let prior = &record.before[0].values;
        let after = &record.after[0].values;
        assert_eq!(prior.description, after.description);
        match edit {
            MetadataEdit::CapturedAt { .. } => {
                assert_eq!(prior.latitude, after.latitude);
                assert_eq!(prior.longitude, after.longitude);
                assert_eq!(after.time_zone.as_deref(), Some("America/New_York"));
            }
            MetadataEdit::Location { .. } => {
                assert_eq!(prior.captured_at, after.captured_at);
                assert_eq!(after.time_zone.as_deref(), Some("America/Los_Angeles"));
            }
            _ => return Err("unexpected acceptance edit".into()),
        }
        super::wait_metadata_queues(ctx, session).await?;
        assert_eq!(
            drive(
                ctx,
                core,
                journal,
                Event::InspectMetadata {
                    operation_id: id.into()
                }
            )
            .await?,
            0
        );
        let record = serde_json::to_value(
            journal
                .metadata_operations
                .last()
                .ok_or("missing inspected operation")?,
        )
        .map_err(|error| error.to_string())?;
        verify_inspected_witness(&record)?;
        let restarted = metadata_core(journal.clone(), session);
        verify_undo(ctx, &restarted, journal, session, id).await?;
    }
    Ok(())
}

async fn verify_undo(
    ctx: &Context,
    core: &Core<Suwop>,
    journal: &mut SavedLibrary,
    session: &Session,
    operation: &str,
) -> Result<(), String> {
    let id = if operation.starts_with("b333") {
        "b5555555-5555-4555-8555-555555555555"
    } else if operation.starts_with("b444") {
        "b6666666-6666-4666-8666-666666666666"
    } else {
        "b8888888-8888-4888-8888-888888888888"
    };
    assert_eq!(
        drive(
            ctx,
            core,
            journal,
            Event::RestoreMetadata {
                id: id.into(),
                operation_id: operation.into(),
                original: false
            }
        )
        .await?,
        1
    );
    super::wait_metadata_queues(ctx, session).await?;
    assert_eq!(
        drive(
            ctx,
            core,
            journal,
            Event::InspectMetadata {
                operation_id: id.into()
            }
        )
        .await?,
        0
    );
    let record = journal
        .metadata_operations
        .last()
        .ok_or("missing undo record")?;
    assert_eq!(record.outcome, MetadataOutcome::VerifiedApplied);
    verify_inspected_witness(&serde_json::to_value(record).map_err(|error| error.to_string())?)
}
