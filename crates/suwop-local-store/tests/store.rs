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
        schema_version: 2,
        apple_scope: "test".into(),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "test".into(),
            scanned_at: Some(0.0),
            access: ScanAccess::Full,
            assets: (0..count)
                .map(|i| StoredAsset {
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
fn runtime() -> std::result::Result<tokio::runtime::Runtime, std::io::Error> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
}
#[test]
fn metadata_does_not_open_lance_and_migration_retains_legacy() -> Result {
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
fn lance_resume_rebuild_publication_and_pruning() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(70))?;
    let budget = AnalysisBudget {
        max_batch_rows: 32,
        ..AnalysisBudget::default()
    };
    let key = store.register(&model(), &budget)?;
    supply(&mut store, &key)?;
    let rt = runtime()?;
    assert!(rt.block_on(store.step())?);
    assert_eq!(store.status()?[0].indexed, 32);
    store.pause(&key, true)?;
    while rt.block_on(store.step())? {}
    drop(store);
    let mut store = Store::open(root.path())?;
    assert_eq!(store.status()?[0].indexed, 32);
    store.pause(&key, false)?;
    while rt.block_on(store.step())? {}
    let first = store.status()?[0].active_generation;
    assert!(first.is_some());
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5))?
            .len(),
        5
    );
    store.rebuild(&key, &budget)?;
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5))?
            .len(),
        5
    );
    assert_eq!(rt.block_on(store.prune())?, 0);
    supply(&mut store, &key)?;
    // Three new shards, then publication plus exactly one cleanup checkpoint.
    for _ in 0..4 {
        assert!(rt.block_on(store.step())?);
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
    while rt.block_on(store.step())? {}
    // Normal scheduling reclaims old tables/jobs without an explicit Prune command.
    assert_eq!(rt.block_on(store.prune())?, 0);
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
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5))?
            .len(),
        5
    );
    store.persist(&state(71))?;
    while rt.block_on(store.step())? {}
    assert_eq!(store.pending(&key, 32)?.len(), 1);
    supply(&mut store, &key)?;
    while rt.block_on(store.step())? {}
    assert_eq!(store.status()?[0].indexed, 71);
    store.persist(&state(0))?;
    assert!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 5))?
            .is_empty()
    );
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
    let rt = runtime()?;
    assert!(rt.block_on(store.step())?);
    assert!(rt.block_on(store.step())?);
    // Simulate loss after the second Lance write but before its journal commit:
    // the first published shard remains immutable, second retains queued vectors.
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
    while rt.block_on(store.step())? {}
    assert_eq!(store.status()?[0].indexed, 70);
    let count: i64 = db.query_row("SELECT count(*) FROM shards", [], |r| r.get(0))?;
    assert_eq!(count, 3);
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 100))?
            .len(),
        70
    );
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
fn lance_failure_pauses_only_analysis_and_can_resume() -> Result {
    let root = tempfile::tempdir()?;
    let mut store = Store::open(root.path())?;
    store.persist(&state(2))?;
    let key = store.register(&model(), &AnalysisBudget::default())?;
    supply(&mut store, &key)?;
    std::fs::write(root.path().join("analysis"), b"not a directory")?;
    let rt = runtime()?;
    assert!(rt.block_on(store.step()).is_err());
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
    std::fs::remove_file(root.path().join("analysis"))?;
    store.pause(&key, false)?;
    supply(&mut store, &key)?;
    while rt.block_on(store.step())? {}
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
    let rt = runtime()?;
    while rt.block_on(store.step())? {}
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
    assert_eq!(rt.block_on(store.search(&key, &[0.5; 512], 10))?.len(), 10);
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
    let rt = runtime()?;
    while rt.block_on(store.step())? {}
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
    let rt = runtime()?;
    while rt.block_on(store.step())? {}
    assert_eq!(
        rt.block_on(store.search(&first, &[1.0, 0.0, 0.0, 0.0], 1))?[0]
            .asset
            .asset_id,
        "0"
    );
    assert_eq!(
        rt.block_on(store.search(&second, &[1.0, 0.0, 0.0, 0.0], 1))?[0]
            .asset
            .asset_id,
        "1"
    );
    let mut changed = state(3);
    changed.snapshots[0].assets[0].revision = "new".into();
    store.persist(&changed)?;
    let hits = rt.block_on(store.search(&first, &[1.0, 0.0, 0.0, 0.0], 3))?;
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
    assert_eq!(version, 3);
    assert_eq!(
        store.read()?.ok_or("missing library")?.snapshots[0]
            .assets
            .len(),
        3
    );
    assert_eq!(store.status()?[0].queued_vectors, 3);
    let rt = runtime()?;
    while rt.block_on(store.step())? {}
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 3))?
            .len(),
        3
    );
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
    assert!(runtime()?.block_on(store.step()).is_err());
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
            id: "protected".into(),
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
    let rt = runtime()?;
    while rt.block_on(store.step())? {}
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1))?
            .len(),
        1
    );
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
    assert!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1))?
            .is_empty()
    );
    assert!(
        store
            .validate_embedding_input(&job.asset, &job.asset, None)
            .is_err()
    );
    library.snapshots[0].access = ScanAccess::Full;
    store.persist(&library)?;
    assert_eq!(store.pending(&key, 1)?.len(), 1);
    supply(&mut store, &key)?;
    while rt.block_on(store.step())? {}
    assert_eq!(
        rt.block_on(store.search(&key, &[1.0, 0.1, 0.2, 0.3], 1))?
            .len(),
        1
    );
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
