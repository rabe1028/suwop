use suwop_core::{
    app::SavedLibrary,
    domain::{AppleVisibility, AssetKey, Provider, StoredAsset},
    metadata::{MetadataEdit, MetadataOutcome, MetadataRecord, MetadataValues, MetadataWitness},
};
use suwop_local_store::Store;
type Result = std::result::Result<(), Box<dyn std::error::Error>>;
fn record() -> MetadataRecord {
    let asset = StoredAsset {
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "fixture".into(),
            asset_id: "generated".into(),
        },
        name: "generated.JPG".into(),
        captured_at: Some(10.0),
        modified_at: None,
        revision: "r1".into(),
        resources: vec![],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
        immich_stack: suwop_core::domain::ImmichStackState::default(),
        immich_stack_membership: None,
        immich_parent_revision: None,
        immich_visibility: None,
    };
    MetadataRecord {
        id: "11111111-1111-4111-8111-111111111111".into(),
        keys: vec![asset.key.clone()],
        edit: MetadataEdit::Description {
            text: "new description".into(),
        },
        member_edits: vec![MetadataEdit::Description {
            text: "new description".into(),
        }],
        before: vec![MetadataWitness {
            asset,
            values: MetadataValues {
                captured_at: Some(10.0),
                time_zone: None,
                latitude: None,
                longitude: None,
                description: "original".into(),
            },
        }],
        after: vec![],
        outcome: MetadataOutcome::SubmittedUnknown,
        restores: None,
        current: vec![],
    }
}
fn empty() -> SavedLibrary {
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "fixture".into(),
        ..SavedLibrary::default()
    }
}
#[test]
fn independent_writers_preserve_unknown_and_applied_metadata_journal() -> Result {
    let directory = tempfile::tempdir()?;
    let mut writer = Store::open(directory.path())?;
    let mut other = Store::open(directory.path())?;
    let base = empty();
    writer.persist(&base)?;
    let stale = other.read_versioned()?;
    let mut pending = base.clone();
    pending.metadata_operations.push(record());
    writer.persist(&pending)?;
    assert!(other.persist(&base).is_err());
    assert!(!other.persist_if_current(&stale.revision, &base)?);
    let fresh = writer.read_versioned()?;
    let mut applied = pending.clone();
    let operation = &mut applied.metadata_operations[0];
    operation.after = operation.before.clone();
    operation.after[0].values.description = "new description".into();
    operation.outcome = MetadataOutcome::VerifiedApplied;
    assert!(writer.persist_if_current(&fresh.revision, &applied)?);
    assert!(other.persist(&pending).is_err());
    let current = other.read_versioned()?;
    let mut corrupted = applied.clone();
    corrupted.metadata_operations[0].before[0]
        .values
        .description = "forged".into();
    assert!(
        other
            .persist_if_current(&current.revision, &corrupted)
            .is_err()
    );
    let after = writer.read_versioned()?;
    assert_eq!(current.revision, after.revision);
    assert_eq!(
        after.state.ok_or("missing library")?.metadata_operations[0].outcome,
        MetadataOutcome::VerifiedApplied
    );
    Ok(())
}
#[test]
fn schema_ten_sqlite_read_migrate_cas_and_restart_preserves_schema_eleven() -> Result {
    let directory = tempfile::tempdir()?;
    let mut store = Store::open(directory.path())?;
    let mut raw = serde_json::to_value(empty())?;
    raw["schemaVersion"] = 10.into();
    raw.as_object_mut()
        .ok_or("library")?
        .remove("metadataOperations");
    raw.as_object_mut()
        .ok_or("library")?
        .remove("externalImports");
    let db = rusqlite::Connection::open(directory.path().join("catalog.sqlite3"))?;
    db.execute("INSERT INTO library_state VALUES(1,?1)", [raw.to_string()])?;
    let read = store.read_versioned()?;
    let mut state = read.state.ok_or("missing migrated state")?;
    assert_eq!(state.schema_version, 11);
    state.metadata_operations.push(record());
    assert!(store.persist_if_current(&read.revision, &state)?);
    drop(store);
    let mut restarted = Store::open(directory.path())?;
    assert_eq!(
        restarted
            .read()?
            .ok_or("missing restart")?
            .metadata_operations
            .len(),
        1
    );
    let raw: String = db.query_row("SELECT json FROM library_state WHERE id=1", [], |row| {
        row.get(0)
    })?;
    let mut disguised: serde_json::Value = serde_json::from_str(&raw)?;
    disguised["schemaVersion"] = 10.into();
    assert!(suwop_core::workflow::migrate(disguised).is_err());
    Ok(())
}

#[test]
fn parent_lookup_token_and_legacy_absence_survive_sqlite_reopen() -> Result {
    let directory = tempfile::tempdir()?;
    let mut library = empty();
    let mut witness = record().before.remove(0);
    witness.asset.key.provider = Provider::Immich;
    witness.asset.immich_parent_revision = Some("opaque-parent-observation".into());
    let token = witness.asset.immich_parent_revision.clone();
    let full_revision = witness.asset.revision.clone();
    library.snapshots.push(suwop_core::domain::LibrarySnapshot {
        provider: Provider::Immich,
        scope: witness.asset.key.scope.clone(),
        assets: vec![witness.asset],
        access: suwop_core::domain::ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    let mut writer = Store::open(directory.path())?;
    writer.persist(&library)?;
    drop(writer);
    let mut reopened = Store::open(directory.path())?;
    let read = reopened.read_versioned()?;
    let restored = read.state.ok_or("stored library")?;
    assert_eq!(
        restored.snapshots[0].assets[0].immich_parent_revision,
        token
    );
    assert_eq!(restored.snapshots[0].assets[0].revision, full_revision);
    let mut legacy = serde_json::to_value(restored)?;
    legacy["snapshots"][0]["assets"][0]
        .as_object_mut()
        .ok_or("legacy asset")?
        .remove("immichParentRevision");
    let legacy: SavedLibrary = serde_json::from_value(legacy)?;
    assert!(
        legacy.snapshots[0].assets[0]
            .immich_parent_revision
            .is_none()
    );
    assert!(reopened.persist_if_current(&read.revision, &legacy)?);
    drop(reopened);
    let mut reopened = Store::open(directory.path())?;
    let restored = reopened
        .read_versioned()?
        .state
        .ok_or("legacy stored library")?;
    assert!(
        restored.snapshots[0].assets[0]
            .immich_parent_revision
            .is_none()
    );
    assert_eq!(restored.snapshots[0].assets[0].revision, full_revision);
    Ok(())
}
