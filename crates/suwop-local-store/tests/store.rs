use suwop_core::{
    analysis::{AnalysisBudget, AnalysisModel, EmbeddingInput},
    app::SavedLibrary,
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset},
};
use suwop_local_store::Store;
type Result = std::result::Result<(), Box<dyn std::error::Error>>;
fn model() -> AnalysisModel {
    AnalysisModel {
        name: "fixture".into(),
        version: "1".into(),
        preprocessing: "rgb/l2".into(),
        rendition: "original".into(),
        dimensions: 4,
    }
}
fn state(count: u32) -> SavedLibrary {
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "test".into(),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "test".into(),
            scanned_at: Some(0.0),
            access: ScanAccess::Full,
            assets: (0..count)
                .map(|i| StoredAsset {
                    immich_visibility: None,
                    immich_stack: suwop_core::domain::ImmichStackState::Unknown,
                    immich_stack_membership: None,
                    apple_visibility: suwop_core::domain::AppleVisibility::Visible,
                    key: AssetKey {
                        provider: Provider::Apple,
                        scope: "test".into(),
                        asset_id: i.to_string(),
                    },
                    name: format!("{i}.jpg"),
                    captured_at: None,
                    modified_at: None,
                    revision: "1".into(),
                    resources: vec![],
                    is_favorite: false,
                    latitude: None,
                    longitude: None,
                    inventory_complete: false,
                    is_offline: false,
                    deletion_blockers: vec![],
                })
                .collect(),
        }],
        ..SavedLibrary::default()
    }
}
fn supply(store: &mut Store, key: &str) -> std::result::Result<(), String> {
    loop {
        let jobs = store.pending(key, 32)?;
        if jobs.is_empty() {
            break;
        }
        let vectors = jobs
            .into_iter()
            .map(|j| EmbeddingInput {
                job_id: j.id,
                vector: vec![1.0, 0.1, 0.2, 0.3],
            })
            .collect::<Vec<_>>();
        store.submit(key, &vectors)?;
    }
    Ok(())
}
#[test]
fn metadata_does_not_touch_analysis_and_migration_retains_legacy() -> Result {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("analysis"), b"not a directory")?;
    let original = state(3);
    std::fs::write(
        root.path().join("library-v1.json"),
        serde_json::to_vec(&original)?,
    )?;
    let mut store = Store::open(root.path())?;
    let restored = store.read()?.ok_or("missing state")?;
    assert_eq!(restored.snapshots[0].assets.len(), 3);
    assert!(root.path().join("library-v1.json").exists());
    store.persist(&state(4))?;
    assert_eq!(
        store.read()?.ok_or("missing state")?.snapshots[0]
            .assets
            .len(),
        4
    );
    Ok(())
}
#[test]
fn model_identity_budget_and_stale_results() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    let mut other = model();
    other.version = "2".into();
    assert_ne!(key, store.register(&other, &AnalysisBudget::default())?);
    other = model();
    other.rendition = "edited".into();
    assert_ne!(key, store.register(&other, &AnalysisBudget::default())?);
    let budget = AnalysisBudget {
        working_bytes: 1,
        ..AnalysisBudget::default()
    };
    assert!(store.register(&model(), &budget).is_err());
    let jobs = store.pending(&key, 2)?;
    assert!(
        store
            .submit(
                &key,
                &[EmbeddingInput {
                    job_id: jobs[0].id.clone(),
                    vector: vec![f32::NAN; 4]
                }]
            )
            .is_err()
    );
    assert!(
        store
            .submit(
                &key,
                &[EmbeddingInput {
                    job_id: jobs[0].id.clone(),
                    vector: vec![0.0; 4]
                }]
            )
            .is_err()
    );
    let mut changed = state(2);
    changed.snapshots[0].assets[0].revision = "2".into();
    store.persist(&changed)?;
    let changed_id = jobs
        .iter()
        .find(|j| j.asset.key.asset_id == "0")
        .ok_or("missing job")?
        .id
        .clone();
    assert!(
        store
            .submit(
                &key,
                &[EmbeddingInput {
                    job_id: changed_id,
                    vector: vec![1.0; 4]
                }]
            )
            .is_err()
    );
    store.pause(&key, true)?;
    assert!(store.pending(&key, 2)?.is_empty());
    store.pause(&key, false)?;
    assert_eq!(store.pending(&key, 2)?.len(), 2);
    Ok(())
}
#[test]
fn index_resume_rebuild_publication_and_pruning() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(70))?;
    let budget = AnalysisBudget {
        max_batch_rows: 32,
        ..AnalysisBudget::default()
    };
    let key = store.register(&model(), &budget)?;
    supply(&mut store, &key)?;
    assert!(store.step()?);
    assert_eq!(store.status()?[0].indexed, 32);
    store.pause(&key, true)?;
    while store.step()? {}
    drop(store);
    let mut store = Store::open(root.path())?;
    assert_eq!(store.status()?[0].indexed, 32);
    store.pause(&key, false)?;
    while store.step()? {}
    let first = store.status()?[0].active_generation;
    assert!(first.is_some());
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5)?.len(), 5);
    store.rebuild(&key, &budget)?;
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5)?.len(), 5);
    assert_eq!(store.prune()?, 0);
    supply(&mut store, &key)?;
    // Three new shards, then publication plus exactly one cleanup checkpoint.
    for _ in 0..4 {
        assert!(store.step()?);
    }
    assert_ne!(store.status()?[0].active_generation, first);
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM shards WHERE generation=?1",
            [first],
            |r| r.get::<_, i64>(0)
        )?,
        2
    );
    drop(store);
    let mut store = Store::open(root.path())?;
    while store.step()? {}
    // Normal scheduling reclaims old tables/jobs without an explicit Prune command.
    assert_eq!(store.prune()?, 0);
    assert_eq!(
        db.query_row("SELECT count(*) FROM generations", [], |r| r
            .get::<_, i64>(0))?,
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM jobs WHERE generation=?1",
            [first],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5)?.len(), 5);
    store.persist(&state(71))?;
    while store.step()? {}
    assert_eq!(store.pending(&key, 32)?.len(), 1);
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.status()?[0].indexed, 71);
    store.persist(&state(0))?;
    assert!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5)?.is_empty());
    Ok(())
}

#[test]
fn interrupted_publication_replays_only_unfinished_shard() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(70))?;
    let budget = AnalysisBudget {
        max_batch_rows: 32,
        ..AnalysisBudget::default()
    };
    let key = store.register(&model(), &budget)?;
    supply(&mut store, &key)?;
    assert!(store.step()?);
    assert!(store.step()?);
    // Simulate a journal rolled back to before the second publication while its
    // index rows remain: replay must overwrite them, never duplicate or lose them.
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let vector = [1.0_f32, 0.1, 0.2, 0.3]
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .collect::<Vec<_>>();
    db.execute(
        "INSERT INTO embedding_vectors SELECT id,?1 FROM jobs WHERE shard=2",
        [vector],
    )?;
    db.execute("UPDATE jobs SET state='queued' WHERE shard=2", [])?;
    db.execute("UPDATE shards SET state='pending' WHERE id=2", [])?;
    drop(store);
    let mut store = Store::open(root.path())?;
    while store.step()? {}
    assert_eq!(store.status()?[0].indexed, 70);
    let count: i64 = db.query_row("SELECT count(*) FROM shards", [], |r| r.get(0))?;
    assert_eq!(count, 3);
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 100)?.len(), 70);
    Ok(())
}
#[test]
fn metadata_commit_does_not_wait_for_analysis_lock() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let lock = std::fs::File::options()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.path().join("analysis.lock"))?;
    lock.lock()?;
    store.persist(&state(2))?;
    assert_eq!(
        store.read()?.ok_or("missing state")?.snapshots[0]
            .assets
            .len(),
        2
    );
    Ok(())
}

#[test]
fn index_write_failure_pauses_only_analysis_and_can_resume() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute_batch("CREATE TRIGGER fail_index BEFORE INSERT ON index_vectors BEGIN SELECT RAISE(ABORT,'injected'); END;")?;
    assert!(store.step().is_err());
    assert_eq!(
        db.query_row("SELECT count(*) FROM index_vectors", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    let status = store.status()?;
    assert_eq!(status[0].state, "paused");
    assert!(status[0].error.is_some());
    store.persist(&state(3))?;
    assert_eq!(
        store.read()?.ok_or("missing state")?.snapshots[0]
            .assets
            .len(),
        3
    );
    db.execute_batch("DROP TRIGGER fail_index;")?;
    store.pause(&key, false)?;
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.status()?[0].indexed, 3);
    Ok(())
}
#[test]
fn unsupported_legacy_version_never_becomes_canonical() -> Result {
    let root = tempfile::tempdir()?;
    let bytes = br#"{"schemaVersion":999,"appleScope":"future"}"#;
    std::fs::write(root.path().join("library-v1.json"), bytes)?;
    let mut store = Store::open(root.path())?;
    assert!(store.read().is_err());
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let count: i64 = db.query_row("SELECT count(*) FROM library_state", [], |r| r.get(0))?;
    assert_eq!(count, 0);
    assert_eq!(std::fs::read(root.path().join("library-v1.json"))?, bytes);
    Ok(())
}

#[test]
fn full_width_vectors_are_sharded_under_the_admission_limit() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(1025))?;
    let mut config = model();
    config.dimensions = 512;
    let budget = AnalysisBudget::default();
    let key = store.register(&config, &budget)?;
    loop {
        let jobs = store.pending(&key, 32)?;
        if jobs.is_empty() {
            break;
        }
        let vectors = jobs
            .into_iter()
            .map(|j| EmbeddingInput {
                job_id: j.id,
                vector: vec![0.5; 512],
            })
            .collect::<Vec<_>>();
        store.submit(&key, &vectors)?;
    }
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let before: i64 = db.query_row("PRAGMA page_count", [], |r| r.get(0))?;
    while store.step()? {}
    let after: i64 = db.query_row("PRAGMA page_count", [], |r| r.get(0))?;
    let remaining: i64 =
        db.query_row("SELECT count(*) FROM embedding_vectors", [], |r| r.get(0))?;
    let free: i64 = db.query_row("PRAGMA freelist_count", [], |r| r.get(0))?;
    assert_eq!(remaining, 0);
    assert_eq!(free, 0);
    assert!(
        after < before / 2,
        "Completed vectors must release their pages"
    );
    let sizes = db
        .prepare("SELECT count(*) FROM jobs GROUP BY shard ORDER BY count(*) DESC")?
        .query_map([], |r| r.get::<_, i64>(0))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    assert_eq!(sizes, vec![512, 512, 1]);
    assert_eq!(store.search(&key, &[0.5; 512], 10)?.len(), 10);
    Ok(())
}

#[test]
fn explicitly_skipped_media_does_not_block_publication() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    let jobs = store.pending(&key, 2)?;
    store.skip(&key, &jobs[0].id, "unsupported media")?;
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.status()?[0].skipped, 1);
    assert_eq!(store.status()?[0].indexed, 1);
    assert_eq!(store.status()?[0].state, "ready");
    Ok(())
}

#[test]
fn models_and_revisions_never_mix_in_search() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(3))?;
    let first = store.register(&model(), &AnalysisBudget::default())?;
    let mut second_model = model();
    second_model.version = "2".into();
    let second = store.register(&second_model, &AnalysisBudget::default())?;
    for (key, swap) in [(&first, false), (&second, true)] {
        let mut vectors = Vec::new();
        for job in store.pending(key, 32)? {
            let mut index = job.asset.key.asset_id.parse::<usize>()?;
            if swap && index < 2 {
                index = 1 - index;
            }
            let mut vector = vec![0.0; 4];
            vector[index] = 1.0;
            vectors.push(EmbeddingInput {
                job_id: job.id,
                vector,
            });
        }
        store.submit(key, &vectors)?;
    }
    while store.step()? {}
    assert_eq!(
        store.search(&first, &[1.0, 0.0, 0.0, 0.0], 1)?[0]
            .asset
            .asset_id,
        "0"
    );
    assert_eq!(
        store.search(&second, &[1.0, 0.0, 0.0, 0.0], 1)?[0]
            .asset
            .asset_id,
        "1"
    );
    let mut changed = state(3);
    changed.snapshots[0].assets[0].revision = "new".into();
    store.persist(&changed)?;
    let hits = store.search(&first, &[1.0, 0.0, 0.0, 0.0], 3)?;
    assert_eq!(hits.len(), 2);
    assert!(hits.iter().all(|h| h.asset.asset_id != "0"));
    Ok(())
}

#[test]
fn v1_migration_preserves_queued_vectors_and_library() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(3))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    drop(store);
    // Convert this populated fixture back to the original v1 layout.
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute_batch(
        "ALTER TABLE jobs ADD COLUMN vector BLOB;
        UPDATE jobs SET vector=(SELECT vector FROM embedding_vectors WHERE job=jobs.id);
        DROP TABLE embedding_vectors; PRAGMA user_version=1;",
    )?;
    let mut store = Store::open(root.path())?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    assert_eq!(version, 5);
    assert_eq!(
        store.read()?.ok_or("missing library")?.snapshots[0]
            .assets
            .len(),
        3
    );
    assert_eq!(store.status()?[0].queued_vectors, 3);
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 3)?.len(), 3);
    // Also exercise an untouched v1 catalog without incremental vacuum enabled.
    let empty = tempfile::tempdir()?;
    let legacy = rusqlite::Connection::open(empty.path().join("catalog.sqlite3"))?;
    legacy.execute_batch(include_str!("fixtures/schema-v1.sql"))?;
    let mut migrated = Store::open(empty.path())?;
    migrated.persist(&state(1))?;
    assert_eq!(
        migrated.read()?.ok_or("missing library")?.snapshots[0]
            .assets
            .len(),
        1
    );
    Ok(())
}

#[test]
fn missing_queued_payload_is_never_published() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute(
        "DELETE FROM embedding_vectors WHERE job=(SELECT min(id) FROM jobs)",
        [],
    )?;
    assert!(store.step().is_err());
    assert_eq!(store.status()?[0].indexed, 0);
    assert_eq!(store.status()?[0].state, "paused");
    assert!(store.status()?[0].error.is_some());
    assert!(store.status()?[0].active_generation.is_none());
    Ok(())
}

#[test]
fn inference_pauses_durably_and_restarts_only_unfinished_photos() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let initial = store.configure_inference(256, 1024 << 20)?;
    let key = initial.model_key;
    let jobs = store.pending(&key, 1)?;
    store.submit(
        &key,
        &[EmbeddingInput {
            job_id: jobs[0].id.clone(),
            vector: vec![1.0; 256],
        }],
    )?;
    store.pause_inference(&key, None)?;
    drop(store);
    let mut store = Store::open(root.path())?;
    assert!(!store.admit_inference(&key, 0, 2048 << 20, false, false, false)?);
    assert!(store.admit_inference(&key, 0, 2048 << 20, false, false, true)?);
    assert_eq!(store.pending(&key, 32)?.len(), 1);
    store.set_inference_budget(&key, 1536 << 20)?;
    let paused = store.inference_status(&key)?.ok_or("missing inference")?;
    assert_eq!(paused.state, "paused");
    assert_eq!(paused.budget_bytes, 1536 << 20);
    store.configure_inference(256, 1024 << 20)?;
    assert!(!store.admit_inference(&key, 100 << 20, 2048 << 20, false, true, false)?);
    assert_eq!(
        store
            .inference_status(&key)?
            .ok_or("missing inference")?
            .state,
        "paused"
    );
    assert_eq!(store.status()?[0].queued_vectors, 1);
    let second = store.configure_inference(512, 1024 << 20)?;
    assert_ne!(key, second.model_key);
    assert_eq!(store.pending(&second.model_key, 32)?.len(), 2);
    Ok(())
}

#[test]
fn protected_and_hidden_photos_never_enter_analysis_and_stale_results_fail() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let mut library = state(3);
    library.snapshots[0].assets[1].apple_visibility = suwop_core::domain::AppleVisibility::Hidden;
    library
        .protected_entries
        .push(suwop_core::protection::PersistentProtectedEntry {
            id: "abababab-0000-4000-8000-000000000000".into(),
            key: library.snapshots[0].assets[2].key.clone(),
        });
    store.persist(&library)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    let jobs = store.pending(&key, 32)?;
    assert_eq!(jobs.len(), 1);
    store.validate_embedding_input(&jobs[0].asset, &jobs[0].asset, None)?;
    let mut changed = jobs[0].asset.clone();
    changed.revision = "changed".into();
    assert!(
        store
            .validate_embedding_input(&jobs[0].asset, &changed, None)
            .is_err()
    );
    library.snapshots[0].assets[0].apple_visibility = suwop_core::domain::AppleVisibility::Hidden;
    store.persist(&library)?;
    assert!(
        store
            .submit(
                &key,
                &[EmbeddingInput {
                    job_id: jobs[0].id.clone(),
                    vector: vec![1.0; 4]
                }]
            )
            .is_err()
    );
    assert!(store.pending(&key, 32)?.is_empty());
    assert!(
        store
            .validate_embedding_input(&jobs[0].asset, &jobs[0].asset, None)
            .is_err()
    );
    Ok(())
}

#[test]
fn inference_input_binds_the_current_server_and_credential_snapshot() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let mut library = state(1);
    let connection = suwop_core::app::ConnectionSettings {
        address: "https://photos.example/api".into(),
        credential_id: "first-account".into(),
        allow_http: false,
    };
    library.connection = Some(connection.clone());
    library.snapshots[0].provider = Provider::Immich;
    library.snapshots[0].scope = "https://photos.example/api#user".into();
    library.snapshots[0].assets[0].key.provider = Provider::Immich;
    library.snapshots[0].assets[0].key.scope = "https://photos.example/api#user".into();
    let asset = library.snapshots[0].assets[0].clone();
    store.persist(&library)?;
    assert!(
        store
            .validate_embedding_input(&asset, &asset, None)
            .is_err()
    );
    store.validate_embedding_input(&asset, &asset, Some(&connection))?;
    let mut replacement = connection.clone();
    replacement.credential_id = "new-account".into();
    library.connection = Some(replacement.clone());
    store.persist(&library)?;
    assert!(
        store
            .validate_embedding_input(&asset, &asset, Some(&connection))
            .is_err()
    );
    replacement.address = "https://other.example/api".into();
    library.connection = Some(replacement.clone());
    store.persist(&library)?;
    assert!(
        store
            .validate_embedding_input(&asset, &asset, Some(&replacement))
            .is_err()
    );
    Ok(())
}

#[test]
fn inference_restoration_requires_the_complete_current_provider_identity() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let first = store.configure_inference(256, 1536 << 20)?;
    let second = store.configure_inference(512, 1536 << 20)?;
    let original = suwop_core::inference::specification(256)?.model;
    for field in 0..5 {
        let mut incompatible = original.clone();
        match field {
            0 => incompatible.name.push_str("-other"),
            1 => incompatible.version.push_str("-old"),
            2 => incompatible.preprocessing.push_str("-other"),
            3 => incompatible.rendition.push_str("-original"),
            _ => incompatible.dimensions = 768,
        }
        store.register(&incompatible, &AnalysisBudget::default())?;
    }
    assert_eq!(store.status()?.len(), 7);
    drop(store);
    let reopened = Store::open(root.path())?;
    let statuses = reopened.compatible_inference_statuses()?;
    assert_eq!(statuses.len(), 2);
    assert!(statuses.iter().any(|s| s.model_key == first.model_key));
    assert!(statuses.iter().any(|s| s.model_key == second.model_key));
    Ok(())
}

#[test]
fn unavailable_immich_snapshot_revokes_analysis_until_freshly_available() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let mut library = state(1);
    library.snapshots[0].provider = Provider::Immich;
    library.snapshots[0].assets[0].key.provider = Provider::Immich;
    store.persist(&library)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    let job = store.pending(&key, 1)?.remove(0);
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1)?.len(), 1);
    library.snapshots[0].access = ScanAccess::Unavailable;
    store.persist(&library)?;
    assert!(store.pending(&key, 1)?.is_empty());
    assert!(
        store
            .submit(
                &key,
                &[EmbeddingInput {
                    job_id: job.id,
                    vector: vec![1.0; 4]
                }]
            )
            .is_err()
    );
    assert!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1)?.is_empty());
    assert!(
        store
            .validate_embedding_input(&job.asset, &job.asset, None)
            .is_err()
    );
    library.snapshots[0].access = ScanAccess::Full;
    store.persist(&library)?;
    assert_eq!(store.pending(&key, 1)?.len(), 1);
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1)?.len(), 1);
    Ok(())
}

#[test]
fn selected_inference_survives_reopen_without_generation_guessing_or_resuming() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let first = store.configure_inference(256, 1536 << 20)?;
    store.configure_inference(512, 1536 << 20)?;
    store.configure_inference(256, 1536 << 20)?;
    store.pause_inference(&first.model_key, None)?;
    drop(store);
    let store = Store::open(root.path())?;
    let selected = store.selected_inference()?.ok_or("missing selection")?;
    assert_eq!(selected.model.dimensions, 256);
    assert_eq!(selected.inference.ok_or("missing journal")?.state, "paused");
    store.select_inference(512)?;
    let selected = store.select_inference(256)?;
    assert_eq!(selected.inference.ok_or("missing journal")?.state, "paused");
    drop(store);
    // Upgrade an older catalog with multiple journals without guessing its preference.
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute_batch("DROP TABLE inference_selection; PRAGMA user_version=2;")?;
    drop(db);
    let store = Store::open(root.path())?;
    assert!(store.selected_inference()?.is_none());
    assert_eq!(
        store
            .inference_status(&first.model_key)?
            .ok_or("missing journal")?
            .state,
        "paused"
    );
    Ok(())
}

#[test]
fn selecting_unconfigured_model_does_not_enqueue_or_resume_work() -> Result {
    let root = tempfile::tempdir()?;
    let store = Store::open(root.path())?;
    let selected = store.select_inference(512)?;
    assert_eq!(selected.model.dimensions, 512);
    assert!(selected.analysis.is_none());
    assert!(selected.inference.is_none());
    assert!(store.status()?.is_empty());
    drop(store);
    let store = Store::open(root.path())?;
    assert_eq!(
        store
            .selected_inference()?
            .ok_or("missing selection")?
            .model
            .dimensions,
        512
    );
    assert!(store.select_inference(768).is_err());
    assert_eq!(
        store
            .selected_inference()?
            .ok_or("missing selection")?
            .model
            .dimensions,
        512
    );
    Ok(())
}

#[test]
fn failed_photo_recovery_survives_restart_and_preserves_originals() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.configure_inference(256, 1536 << 20)?.model_key;
    let failed = store.pending(&key, 1)?[0].id.clone();
    assert!(store.fail_inference_job(&key, &failed, "Cannot decode")?);
    drop(store);
    let mut store = Store::open(root.path())?;
    let paused = store.inference_status(&key)?.ok_or("missing inference")?;
    assert_eq!(paused.state, "paused");
    assert_eq!(paused.failed_job.as_deref(), Some(failed.as_str()));
    let resumed = store.skip_failed_inference(&key, &failed, 1536 << 20)?;
    assert_eq!(resumed.state, "running");
    assert!(resumed.failed_job.is_none());
    let pending = store.pending(&key, 32)?;
    assert_eq!(pending.len(), 1);
    assert_ne!(pending[0].id, failed);
    store.submit(
        &key,
        &[EmbeddingInput {
            job_id: pending[0].id.clone(),
            vector: vec![1.0; 256],
        }],
    )?;
    while store.step()? {}
    let status = &store.status()?[0];
    assert_eq!(status.state, "ready");
    assert_eq!(status.indexed, 1);
    assert_eq!(status.skipped, 1);
    assert!(status.active_generation.is_some());
    assert_eq!(
        store.read()?.ok_or("missing catalog")?.snapshots[0]
            .assets
            .len(),
        2
    );
    store.rebuild(&key, &AnalysisBudget::default())?;
    assert_eq!(store.pending(&key, 32)?.len(), 2);
    Ok(())
}

#[test]
fn failed_photo_actions_reject_other_models_and_stale_revisions() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(1))?;
    let first = store.configure_inference(256, 1536 << 20)?.model_key;
    let second = store.configure_inference(512, 1536 << 20)?.model_key;
    let job = store.pending(&first, 1)?[0].id.clone();
    assert!(!store.fail_inference_job(&second, &job, "Wrong model")?);
    assert!(
        store
            .skip_failed_inference(&first, &job, 1536 << 20)
            .is_err()
    );
    assert!(store.fail_inference_job(&first, &job, "Cannot decode")?);
    assert!(store.skip_failed_inference(&first, &job, 1).is_err());
    let mut revised = state(1);
    revised.snapshots[0].assets[0].revision = "2".into();
    store.persist(&revised)?;
    assert!(
        store
            .inference_status(&first)?
            .ok_or("missing")?
            .failed_job
            .is_none()
    );
    assert!(
        store
            .skip_failed_inference(&first, &job, 1536 << 20)
            .is_err()
    );
    store.configure_inference(256, 1536 << 20)?;
    assert!(!store.fail_inference_job(&first, &job, "Obsolete failure")?);
    assert_eq!(
        store.inference_status(&first)?.ok_or("missing")?.state,
        "running"
    );
    assert_eq!(
        store.inference_status(&second)?.ok_or("missing")?.state,
        "running"
    );
    assert_eq!(store.pending(&first, 32)?.len(), 1);
    assert_eq!(store.status()?.iter().map(|s| s.skipped).sum::<u64>(), 0);
    Ok(())
}

#[test]
fn immich_lock_intent_revokes_analysis_jobs_and_published_hits() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let mut catalog = state(1);
    catalog.snapshots[0].provider = Provider::Immich;
    catalog.snapshots[0].assets[0].key.provider = Provider::Immich;
    catalog.snapshots[0].assets[0].key.asset_id = "cccccccc-0000-4000-8000-000000000000".into();
    store.persist(&catalog)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.len(), 1);
    let asset = catalog.snapshots[0].assets[0].clone();
    catalog
        .immich_visibility_operations
        .push(serde_json::from_value(serde_json::json!({
            "id":"dddddddd-0000-4000-8000-000000000000", "scope":"test", "key":asset.key, "witnessDigest":"a".repeat(64),
            "from":"timeline", "to":"locked", "outcome":"unknown"
        }))?);
    store.persist(&catalog)?;
    assert!(store.pending(&key, 32)?.is_empty());
    assert!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.is_empty());
    assert!(
        store
            .validate_embedding_input(&asset, &asset, None)
            .is_err()
    );
    Ok(())
}

#[test]
fn returning_assets_reclaim_detached_active_shards_one_at_a_time() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let library = state(65);
    store.persist(&library)?;
    let budget = AnalysisBudget {
        max_batch_rows: 32,
        ..AnalysisBudget::default()
    };
    let key = store.register(&model(), &budget)?;
    supply(&mut store, &key)?;
    while store.step()? {}
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let count = || db.query_row("SELECT count(*) FROM shards", [], |r| r.get::<_, i64>(0));
    let generation = store.status()?[0].active_generation;
    assert_eq!(count()?, 3);
    for _ in 0..3 {
        let mut absent = library.clone();
        absent.snapshots[0].access = ScanAccess::Unavailable;
        store.persist(&absent)?;
        store.persist(&library)?;
        let old = db
            .prepare("SELECT id,generation FROM shards ORDER BY id")?
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        assert_eq!(store.status()?[0].awaiting_embeddings, 65);
        // No new vectors are required for reclamation. Each idle checkpoint drops one table.
        for remaining in (0..3).rev() {
            assert!(store.step()?);
            assert_eq!(count()?, remaining);
        }
        for (id, generation) in old {
            assert!(
                !root
                    .path()
                    .join("analysis")
                    .join(format!("g{generation}_s{id}.lance"))
                    .exists()
            );
        }
        drop(store);
        store = Store::open(root.path())?;
        supply(&mut store, &key)?;
        while store.step()? {}
        assert_eq!(store.status()?[0].active_generation, generation);
        assert_eq!(count()?, 3);
        assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 100)?.len(), 65);
    }
    Ok(())
}

#[test]
fn detached_cleanup_preserves_shared_shards_and_reclaims_detached_vectors() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let library = state(2);
    store.persist(&library)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    while store.step()? {}
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let mut partial = library.clone();
    partial.snapshots[0].assets.remove(0);
    store.persist(&partial)?;
    store.persist(&library)?;
    while store.step()? {}
    assert_eq!(store.prune()?, 0);
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.len(), 1);
    let mut absent = library.clone();
    absent.snapshots[0].access = ScanAccess::Unavailable;
    store.persist(&absent)?;
    store.persist(&library)?;
    drop(store);
    let mut store = Store::open(root.path())?;
    assert_eq!(store.prune()?, 1);
    assert_eq!(store.prune()?, 0);
    // The detached shard's vectors leave with its journal entry.
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM index_vectors v WHERE NOT EXISTS (SELECT 1 FROM shards s WHERE s.id=v.shard)",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.len(), 2);
    Ok(())
}

#[test]
fn confirmed_removal_detaches_shards_after_unavailable_and_limited_scans() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let library = state(2);
    store.persist(&library)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    while store.step()? {}
    for access in [ScanAccess::Unavailable, ScanAccess::Limited] {
        let mut uncertain = library.clone();
        uncertain.snapshots[0].access = access;
        uncertain.snapshots[0].assets.clear();
        store.persist(&uncertain)?;
        assert_eq!(store.prune()?, 0);
        drop(store);
        store = Store::open(root.path())?;
    }
    let mut missing = library.clone();
    missing.snapshots[0].assets.clear();
    let mut unstamped = missing.clone();
    unstamped.snapshots[0].scanned_at = None;
    store.persist(&unstamped)?;
    assert_eq!(store.prune()?, 0);
    let mut other = missing.clone();
    other.snapshots[0].scope = "different-source".into();
    store.persist(&other)?;
    assert_eq!(store.prune()?, 0);
    let mut ambiguous = missing.clone();
    ambiguous.snapshots.push(missing.snapshots[0].clone());
    store.persist(&ambiguous)?;
    assert_eq!(store.prune()?, 0);
    store.persist(&missing)?;
    assert!(store.step()?);
    assert_eq!(store.prune()?, 0);
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM shards", [], |r| r.get::<_, i64>(0))?,
        0
    );
    assert_eq!(
        db.query_row("SELECT count(*) FROM analysis_asset_keys", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM jobs WHERE shard IS NOT NULL",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.is_empty());
    Ok(())
}

#[test]
fn v3_migration_retains_identity_for_later_confirmed_revision_removal() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    let mut library = state(1);
    store.persist(&library)?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    while store.step()? {}
    drop(store);
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute_batch(
        "DROP TABLE analysis_asset_keys; DROP INDEX jobs_asset_revision; PRAGMA user_version=3;",
    )?;
    let mut store = Store::open(root.path())?;
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?,
        5
    );
    assert_eq!(
        db.query_row("SELECT count(*) FROM analysis_asset_keys", [], |r| r
            .get::<_, i64>(0))?,
        1
    );
    // The v5 step requires published vectors to be supplied again.
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?.len(), 1);
    library.snapshots[0].assets[0].revision = "new".into();
    store.persist(&library)?;
    assert_eq!(store.prune()?, 1);
    supply(&mut store, &key)?;
    while store.step()? {}
    let hits = store.search(&key, &[1.0, 0.1, 0.2, 0.3], 10)?;
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].revision, "new");
    Ok(())
}

#[test]
fn explicit_exclusions_survive_visibility_refresh_until_revision_or_rebuild() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(1))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    let job = store.pending(&key, 1)?.remove(0);
    store.skip(&key, &job.id, "unsupported media")?;
    for access in [ScanAccess::Unavailable, ScanAccess::Limited] {
        let mut hidden = state(0);
        hidden.snapshots[0].access = access;
        store.persist(&hidden)?;
        drop(store);
        store = Store::open(root.path())?;
        store.persist(&state(1))?;
        assert!(store.pending(&key, 1)?.is_empty());
        assert_eq!(store.status()?[0].skipped, 1);
    }
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let reason: String = db.query_row("SELECT reason FROM jobs WHERE id=?1", [&job.id], |r| {
        r.get(0)
    })?;
    assert_eq!(reason, "unsupported media");
    let mut changed = state(1);
    changed.snapshots[0].assets[0].revision = "2".into();
    store.persist(&changed)?;
    assert_eq!(store.pending(&key, 1)?[0].asset.revision, "2");
    store.rebuild(&key, &AnalysisBudget::default())?;
    assert_eq!(store.pending(&key, 1)?.len(), 1);
    assert_eq!(store.status()?[0].skipped, 0);
    Ok(())
}

fn live_wire_library(
    index: usize,
) -> std::result::Result<SavedLibrary, Box<dyn std::error::Error>> {
    let corpus: serde_json::Value = serde_json::from_str(include_str!(
        "../../suwop-core/tests/fixtures/live-journal-wire.json"
    ))?;
    Ok(serde_json::from_value(
        corpus["validStates"][index]["library"].clone(),
    )?)
}

#[test]
fn old_sqlite_row_versioned_read_cas_and_restart_preserve_raw_token() -> Result {
    let root = tempfile::tempdir()?;
    let mut first = Store::open(root.path())?;
    first.persist(&state(2))?;
    let mut legacy = serde_json::to_value(state(2))?;
    legacy["schemaVersion"] = serde_json::json!(8);
    for field in [
        "immichLiveOperations",
        "immichLiveUnstartedClosures",
        "immichLiveLegacyReconciliations",
    ] {
        legacy.as_object_mut().ok_or("object")?.remove(field);
    }
    let raw = serde_json::to_string(&legacy)?;
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute("UPDATE library_state SET json=?1 WHERE id=1", [&raw])?;
    let mut second = Store::open(root.path())?;
    let versioned = second.read_versioned()?;
    let mut migrated = versioned.state.ok_or("state")?;
    assert_eq!(
        migrated.schema_version,
        suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION
    );
    let untouched: String =
        db.query_row("SELECT json FROM library_state WHERE id=1", [], |row| {
            row.get(0)
        })?;
    assert_eq!(untouched, raw);
    migrated.snapshots[0].scanned_at = Some(123.0);
    assert!(second.persist_if_current(&versioned.revision, &migrated)?);
    assert!(!second.persist_if_current(&versioned.revision, &migrated)?);
    drop(second);
    let mut restarted = Store::open(root.path())?;
    assert_eq!(
        restarted.read()?.ok_or("state")?.snapshots[0].scanned_at,
        Some(123.0)
    );
    Ok(())
}

#[test]
fn v4_migration_requests_vectors_again_and_reclaims_lance_files() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(3))?;
    let budget = AnalysisBudget {
        max_batch_rows: 2,
        ..AnalysisBudget::default()
    };
    let key = store.register(&model(), &budget)?;
    supply(&mut store, &key)?;
    while store.step()? {}
    assert!(store.status()?[0].active_generation.is_some());
    drop(store);
    // Rebuild the v4 layout: published vectors existed only in former Lance files.
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute_batch("DROP TABLE index_vectors; PRAGMA user_version=4;")?;
    std::fs::create_dir_all(root.path().join("analysis").join("g1_s1.lance"))?;
    let mut store = Store::open(root.path())?;
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?,
        5
    );
    assert_eq!(std::fs::read_dir(root.path().join("analysis"))?.count(), 0);
    let status = &store.status()?[0];
    assert_eq!(status.indexed, 0);
    assert_eq!(status.awaiting_embeddings, 3);
    assert!(status.active_generation.is_none());
    assert!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 3).is_err());
    supply(&mut store, &key)?;
    while store.step()? {}
    assert_eq!(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 3)?.len(), 3);
    assert_eq!(store.prune()?, 0);
    Ok(())
}

#[test]
fn independent_writers_cas_and_stale_plain_persist_never_erase_live_history_or_outbox() -> Result {
    for cas_first in [false, true] {
        let root = tempfile::tempdir()?;
        let mut first = Store::open(root.path())?;
        let mut second = Store::open(root.path())?;
        first.persist(&state(2))?;
        let model_key = first.register(&model(), &AnalysisBudget::default())?;
        let versioned = first.read_versioned()?;
        let mut desired = versioned.state.ok_or("state")?;
        desired.immich_live_operations = live_wire_library(0)?.immich_live_operations;
        if cas_first {
            assert!(first.persist_if_current(&versioned.revision, &desired)?);
            let before = serde_json::to_value(first.pending(&model_key, 32)?)?;
            assert!(second.persist(&state(0)).is_err());
            assert_eq!(
                serde_json::to_value(first.pending(&model_key, 32)?)?,
                before
            );
            assert_eq!(
                first.read()?.ok_or("state")?.immich_live_operations,
                desired.immich_live_operations
            );
        } else {
            second.persist(&state(3))?;
            let before = serde_json::to_value(second.pending(&model_key, 32)?)?;
            assert!(!first.persist_if_current(&versioned.revision, &desired)?);
            assert_eq!(
                serde_json::to_value(second.pending(&model_key, 32)?)?,
                before
            );
            assert!(
                second
                    .read()?
                    .ok_or("state")?
                    .immich_live_operations
                    .is_empty()
            );
            assert_eq!(second.read()?.ok_or("state")?.snapshots[0].assets.len(), 3);
        }
    }
    Ok(())
}

#[test]
fn all_storage_writers_preserve_applied_and_unstarted_closure_history() -> Result {
    use suwop_core::immich_live_writes as live;
    let root = tempfile::tempdir()?;
    let mut first = Store::open(root.path())?;
    let mut second = Store::open(root.path())?;
    let unknown = live_wire_library(0)?;
    first.persist(&unknown)?;
    let applied = live_wire_library(3)?;
    first.persist(&applied)?;
    assert!(second.persist(&unknown).is_err());
    let mut closed = applied.clone();
    let batch = &closed.immich_live_operations[0];
    let live::Outcome::Applied { verified_post, .. } = &batch.steps[0].outcome else {
        return Err("applied".into());
    };
    let mut closure = live::UnstartedClosure {
        format_version: 1,
        id: "abcdefab-0000-4000-8000-000000000000".into(),
        references: vec![live::StepRef {
            batch_id: batch.id.clone(),
            step_id: batch.steps[1].id.clone(),
            intent_digest: batch.intent.digest.clone(),
            retired_outcomes_digest: live::retired_outcomes_digest(batch)?,
        }],
        current_graph: verified_post.resources.clone(),
        digest: String::new(),
    };
    closure.digest = live::closure_digest(&closure)?;
    closed.immich_live_unstarted_closures.push(closure);
    let current = first.read_versioned()?;
    assert!(first.persist_if_current(&current.revision, &closed)?);
    assert!(second.persist(&applied).is_err());
    let durable = second.read()?.ok_or("state")?;
    assert_eq!(
        durable.immich_live_operations,
        applied.immich_live_operations
    );
    assert_eq!(
        durable.immich_live_unstarted_closures,
        closed.immich_live_unstarted_closures
    );
    let imported_root = tempfile::tempdir()?;
    let legacy_file = imported_root.path().join("library-v1.json");
    let original = serde_json::to_vec(&closed)?;
    std::fs::write(&legacy_file, &original)?;
    let mut imported = Store::open(imported_root.path())?;
    let restored = imported.read()?.ok_or("imported state")?;
    assert_eq!(
        restored.immich_live_operations,
        closed.immich_live_operations
    );
    assert_eq!(
        restored.immich_live_unstarted_closures,
        closed.immich_live_unstarted_closures
    );
    assert_eq!(std::fs::read(legacy_file)?, original);
    Ok(())
}

#[test]
fn lance_file_cleanup_is_retried_until_it_completes() -> Result {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir()?;
    drop(Store::open(root.path())?);
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    let pending = |db: &rusqlite::Connection| -> rusqlite::Result<i64> {
        db.query_row("SELECT count(*) FROM pending_cleanup", [], |r| r.get(0))
    };
    // A fresh catalog never touches `analysis/`, which the native adapter owns.
    let analysis = root.path().join("analysis");
    std::fs::create_dir_all(analysis.join("fresh"))?;
    drop(Store::open(root.path())?);
    assert!(analysis.join("fresh").exists());
    // Simulate termination after the schema-5 commit but before reclamation, with
    // one entry that cannot be removed yet.
    db.execute("INSERT INTO pending_cleanup VALUES('lance-files')", [])?;
    let locked = analysis.join("g1_s1.lance");
    std::fs::create_dir_all(&locked)?;
    std::fs::write(locked.join("data"), b"vectors")?;
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500))?;
    drop(Store::open(root.path())?);
    assert_eq!(pending(&db)?, 1);
    assert!(locked.exists());
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700))?;
    drop(Store::open(root.path())?);
    assert_eq!(pending(&db)?, 0);
    assert_eq!(std::fs::read_dir(&analysis)?.count(), 0);
    Ok(())
}

#[test]
fn former_litert_files_are_removed_and_other_model_files_kept() -> Result {
    let root = tempfile::tempdir()?;
    let models = root.path().join("models");
    std::fs::create_dir_all(&models)?;
    let model = "embeddinggemma-2-text-vision-440m.litertlm";
    let owned = [
        model.to_owned(),
        "embeddinggemma-2.installing".to_owned(),
        format!("{model}_1792777662_387710976.vision_encoder.xnnpack_cache"),
    ];
    for name in owned.iter().chain(
        [
            "inference.lock".to_owned(),
            "other.xnnpack_cache".to_owned(),
        ]
        .iter(),
    ) {
        std::fs::write(models.join(name), b"fixture")?;
    }
    drop(Store::open(root.path())?);
    for name in &owned {
        assert!(!models.join(name).exists(), "{name} kept");
    }
    assert!(models.join("inference.lock").exists());
    assert!(models.join("other.xnnpack_cache").exists());
    Ok(())
}

/// An upstream Amazon (schema 9) row: Amazon fields, no Live journal fields.
fn amazon_v9_row(
    library: &SavedLibrary,
) -> std::result::Result<String, Box<dyn std::error::Error>> {
    let mut raw = serde_json::to_value(library)?;
    raw["schemaVersion"] = serde_json::json!(9);
    let object = raw.as_object_mut().ok_or("object")?;
    for field in [
        "immichLiveOperations",
        "immichLiveUnstartedClosures",
        "immichLiveLegacyReconciliations",
    ] {
        object.remove(field).ok_or("live field")?;
    }
    Ok(serde_json::to_string(&raw)?)
}
fn with_amazon(mut library: SavedLibrary) -> std::result::Result<SavedLibrary, String> {
    let mut connection = suwop_core::amazon::Connection::provisional("amazon-credential")?;
    connection.owner_id = "owner".into();
    connection.scope = "amazon.co.jp|owner".into();
    connection.root_id = "root".into();
    library.amazon_connection = Some(connection);
    Ok(library)
}

#[test]
fn amazon_schema_nine_row_reads_as_schema_ten_and_cas_upgrades_it() -> Result {
    let root = tempfile::tempdir()?;
    let mut first = Store::open(root.path())?;
    first.persist(&state(2))?;
    let amazon = with_amazon(state(2))?;
    let raw = amazon_v9_row(&amazon)?;
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute("UPDATE library_state SET json=?1 WHERE id=1", [&raw])?;
    let mut second = Store::open(root.path())?;
    let versioned = second.read_versioned()?;
    let mut migrated = versioned.state.ok_or("state")?;
    assert_eq!(migrated.schema_version, 10);
    assert_eq!(
        serde_json::to_value(&migrated.amazon_connection)?,
        serde_json::to_value(&amazon.amazon_connection)?
    );
    assert!(migrated.immich_live_operations.is_empty());
    let row = |db: &rusqlite::Connection| -> rusqlite::Result<String> {
        db.query_row("SELECT json FROM library_state WHERE id=1", [], |r| {
            r.get(0)
        })
    };
    // Reading never rewrites the upstream row.
    assert_eq!(row(&db)?, raw);
    migrated.immich_live_operations = live_wire_library(0)?.immich_live_operations;
    assert!(second.persist_if_current(&versioned.revision, &migrated)?);
    let stored: serde_json::Value = serde_json::from_str(&row(&db)?)?;
    assert_eq!(stored["schemaVersion"], 10);
    assert_eq!(
        stored["amazonConnection"],
        serde_json::to_value(&amazon.amazon_connection)?
    );
    assert!(
        !stored["immichLiveOperations"]
            .as_array()
            .ok_or("ops")?
            .is_empty()
    );
    // The schema-9 token is stale now; it cannot overwrite the Live journal.
    assert!(!second.persist_if_current(&versioned.revision, &with_amazon(state(2))?)?);
    Ok(())
}

#[test]
fn schema_nine_row_with_live_fields_is_rejected_and_left_unchanged() -> Result {
    let root = tempfile::tempdir()?;
    let mut first = Store::open(root.path())?;
    first.persist(&state(2))?;
    let mut raw: serde_json::Value =
        serde_json::from_str(&amazon_v9_row(&with_amazon(state(2))?)?)?;
    raw["immichLiveOperations"] =
        serde_json::to_value(live_wire_library(0)?.immich_live_operations)?;
    let raw = serde_json::to_string(&raw)?;
    let db = rusqlite::Connection::open(root.path().join("catalog.sqlite3"))?;
    db.execute("UPDATE library_state SET json=?1 WHERE id=1", [&raw])?;
    let mut second = Store::open(root.path())?;
    assert!(second.read_versioned().is_err());
    assert!(second.persist(&state(3)).is_err());
    let untouched: String = db.query_row("SELECT json FROM library_state WHERE id=1", [], |r| {
        r.get(0)
    })?;
    assert_eq!(untouched, raw);
    Ok(())
}

#[test]
fn live_held_immich_original_never_enters_analysis() -> Result {
    let held = live_wire_library(0)?.immich_live_operations[0]
        .intent
        .resources[0]
        .initial
        .key
        .clone();
    let analysed = |journal: bool| -> std::result::Result<Vec<String>, Box<dyn std::error::Error>> {
        let root = tempfile::tempdir()?;
        let mut store = Store::open(root.path())?;
        let mut library = state(2);
        let mut immich = library.snapshots[0].clone();
        immich.provider = Provider::Immich;
        immich.scope = held.scope.clone();
        immich.assets[0].key = held.clone();
        immich.assets[1].key = AssetKey {
            provider: Provider::Immich,
            scope: held.scope.clone(),
            asset_id: "0000ffff-0000-4000-8000-000000000000".into(),
        };
        library.snapshots.push(immich);
        if journal {
            library.immich_live_operations = live_wire_library(0)?.immich_live_operations;
        }
        store.persist(&library)?;
        let key = store.register(&model(), &AnalysisBudget::default())?;
        Ok(store
            .pending(&key, 32)?
            .into_iter()
            .map(|job| job.asset.key.asset_id)
            .collect())
    };
    let with_journal = analysed(true)?;
    assert!(!with_journal.contains(&held.asset_id));
    assert!(with_journal.contains(&"0000ffff-0000-4000-8000-000000000000".to_string()));
    // Control: the same original is analysed once no Live record holds it.
    assert!(analysed(false)?.contains(&held.asset_id));
    Ok(())
}
