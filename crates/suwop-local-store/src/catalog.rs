use crate::{Result, digest, error};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use suwop_core::{app::SavedLibrary, domain::StoredAsset};

#[derive(Debug)]
pub struct Store {
    pub(crate) root: PathBuf,
    pub(crate) db: Connection,
}
impl Store {
    pub fn open(root: &Path) -> Result<Self> {
        Self::open_impl(root, true)
    }
    pub(crate) fn open_existing(root: &Path) -> Result<Self> {
        Self::open_impl(root, false)
    }
    fn open_impl(root: &Path, create: bool) -> Result<Self> {
        if create {
            std::fs::create_dir_all(root).map_err(error)?;
        }
        let root = root.canonicalize().map_err(error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700))
                .map_err(error)?;
        }
        let mut flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE;
        if create {
            flags |= rusqlite::OpenFlags::SQLITE_OPEN_CREATE;
        }
        let mut db =
            Connection::open_with_flags(root.join("catalog.sqlite3"), flags).map_err(error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                root.join("catalog.sqlite3"),
                std::fs::Permissions::from_mode(0o600),
            )
            .map_err(error)?;
        }
        db.busy_timeout(Duration::from_secs(5)).map_err(error)?;
        let version: i64 = db
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(error)?;
        if version > 5 {
            return Err("Unsupported local catalog version".into());
        }
        if version == 0 {
            // Set this before WAL initializes the database header.
            db.execute_batch("PRAGMA auto_vacuum=INCREMENTAL;")
                .map_err(error)?;
        }
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-2048;").map_err(error)?;
        if version == 0 {
            let tx = db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(error)?;
            tx.execute_batch(include_str!("schema.sql"))
                .map_err(error)?;
            tx.commit().map_err(error)?;
        }
        // Each step re-reads the version inside its own write transaction, so a
        // concurrent opener that already migrated is not migrated twice.
        for (from, sql) in [
            (1, include_str!("migration-v2.sql")),
            (2, include_str!("migration-v3.sql")),
            (3, include_str!("migration-v4.sql")),
            (4, include_str!("migration-v5.sql")),
        ] {
            if version <= from {
                migrate(&mut db, from, sql)?;
            }
        }
        // Retried on every open until every former Lance file is gone.
        let pending: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM pending_cleanup WHERE name='lance-files')",
                [],
                |r| r.get(0),
            )
            .map_err(error)?;
        reclaim_litert_files(&root.join("models"));
        if pending && reclaim_lance_files(&root.join("analysis")) {
            db.execute("DELETE FROM pending_cleanup WHERE name='lance-files'", [])
                .map_err(error)?;
        }
        Ok(Self { root, db })
    }
    /// Reclaim at most 256 free pages between analysis checkpoints, without a full rebuild.
    pub(crate) fn compact(&self) -> Result<bool> {
        let mode: i64 = self
            .db
            .query_row("PRAGMA auto_vacuum", [], |r| r.get(0))
            .map_err(error)?;
        if mode != 2 {
            return Ok(false);
        }
        let before: i64 = self
            .db
            .query_row("PRAGMA freelist_count", [], |r| r.get(0))
            .map_err(error)?;
        if before == 0 {
            return Ok(false);
        }
        {
            let mut statement = self
                .db
                .prepare("PRAGMA incremental_vacuum(256)")
                .map_err(error)?;
            let mut rows = statement.query([]).map_err(error)?;
            while rows.next().map_err(error)?.is_some() {}
        }
        let after: i64 = self
            .db
            .query_row("PRAGMA freelist_count", [], |r| r.get(0))
            .map_err(error)?;
        Ok(after < before)
    }
    /// Import once, inside the new database transaction; keep the legacy file intact.
    pub fn read(&mut self) -> Result<Option<SavedLibrary>> {
        let text: Option<String> = self
            .db
            .query_row("SELECT json FROM library_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(error)?;
        if let Some(text) = text {
            return suwop_core::workflow::migrate(serde_json::from_str(&text).map_err(error)?)
                .map(Some);
        }
        let path = self.root.join("library-v1.json");
        if !path.try_exists().map_err(error)? {
            return Ok(None);
        }
        if path.metadata().map_err(error)?.len() > 16 << 20 {
            return Err("Legacy catalog exceeds bridge capacity".into());
        }
        let raw = serde_json::from_slice(&std::fs::read(path).map_err(error)?).map_err(error)?;
        let state = suwop_core::workflow::migrate(raw)?;
        self.save(&state, true, None)?;
        // A second process may have completed migration or persisted newer state.
        self.read()
    }
    /// Metadata and the analysis outbox commit together. Never takes the analysis lock.
    pub fn persist(&mut self, state: &SavedLibrary) -> Result<()> {
        self.save(state, false, None).map(|_| ())
    }
    /// Token fingerprints the exact durable row bytes, never a migrated encoding.
    /// State and token come from the same SELECT; reading does not rewrite that row.
    pub fn read_versioned(&mut self) -> Result<VersionedLibrary> {
        let mut text: Option<String> = self
            .db
            .query_row("SELECT json FROM library_state WHERE id=1", [], |row| {
                row.get(0)
            })
            .optional()
            .map_err(error)?;
        if text.is_none() {
            self.read()?; // Only the absent-row path can import a legacy file.
            text = self
                .db
                .query_row("SELECT json FROM library_state WHERE id=1", [], |row| {
                    row.get(0)
                })
                .optional()
                .map_err(error)?;
        }
        Ok(VersionedLibrary {
            revision: row_revision(text.as_deref()),
            state: text
                .map(|text| {
                    suwop_core::workflow::migrate(serde_json::from_str(&text).map_err(error)?)
                })
                .transpose()?,
        })
    }
    pub fn persist_if_current(&mut self, revision: &str, state: &SavedLibrary) -> Result<bool> {
        self.save(state, false, Some(revision))
    }
    fn save(
        &mut self,
        state: &SavedLibrary,
        import_only: bool,
        expected: Option<&str>,
    ) -> Result<bool> {
        let text = serde_json::to_string(state).map_err(error)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let current: Option<String> = tx
            .query_row("SELECT json FROM library_state WHERE id=1", [], |row| {
                row.get(0)
            })
            .optional()
            .map_err(error)?;
        if import_only && current.is_some() {
            return Ok(false);
        }
        if expected.is_some_and(|expected| expected != row_revision(current.as_deref())) {
            return Ok(false);
        }
        if state.schema_version != suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION {
            return Err("Catalog writes require the current schema".into());
        }
        // Every writer, including old non-CAS workflows, must preserve the
        // durable journal. Reject stale state rather than silently merging it.
        let before = current
            .as_deref()
            .map(|raw| suwop_core::workflow::migrate(serde_json::from_str(raw).map_err(error)?))
            .transpose()?
            .unwrap_or_else(|| SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                ..SavedLibrary::default()
            });
        if import_only {
            // Historical backup import is not a newly issued provider attempt.
            suwop_core::immich_live_writes::validate_library(state)?;
        } else {
            suwop_core::immich_live_writes::validate_transition(&before, state)?;
        }
        tx.execute("INSERT INTO library_state VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [&text]).map_err(error)?;
        tx.execute("DELETE FROM assets", []).map_err(error)?;
        {
            let mut insert = tx.prepare("INSERT INTO assets VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,json=excluded.json").map_err(error)?;
            for asset in suwop_core::analysis::visible_assets(state) {
                insert
                    .execute(params![
                        asset_id(asset)?,
                        asset.revision,
                        serde_json::to_string(asset).map_err(error)?
                    ])
                    .map_err(error)?;
            }
        }
        tx.execute("INSERT OR IGNORE INTO analysis_asset_keys SELECT id,json_extract(json,'$.key') FROM assets", []).map_err(error)?;
        // A changed/disappeared source cannot accept an old model result.
        // Explicit exclusions belong to this generation and revision, even while
        // visibility is unavailable. Only a new revision or rebuild retries them.
        tx.execute("UPDATE jobs SET state='obsolete' WHERE state!='skipped' AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.id=jobs.asset AND a.revision=jobs.revision)", []).map_err(error)?;
        tx.execute("DELETE FROM embedding_vectors WHERE job IN (SELECT id FROM jobs WHERE state='obsolete')",[]).map_err(error)?;
        super::presence::detach_confirmed_removed(&tx, state)?;
        super::jobs::enqueue_latest(&tx)?;
        tx.execute("DELETE FROM analysis_asset_keys WHERE NOT EXISTS (SELECT 1 FROM assets a WHERE a.id=analysis_asset_keys.id) AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.asset=analysis_asset_keys.id AND j.shard IS NOT NULL)", []).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(true)
    }
}
/// The former LiteRT-LM weights, partial download and XNNPACK caches. Their names are
/// fixed and never recreated, so each open removes only these files; others are kept.
fn reclaim_litert_files(directory: &Path) {
    const MODEL: &str = "embeddinggemma-2-text-vision-440m.litertlm";
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let owned = name == MODEL
            || name == "embeddinggemma-2.installing"
            || (name.starts_with(&format!("{MODEL}_")) && name.ends_with(".xnnpack_cache"));
        if owned && entry.file_type().is_ok_and(|kind| kind.is_file()) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}
/// Former Lance index files are unreadable derived data. Keep the directory itself:
/// the native adapter owns its backup exclusion attribute. Returns whether nothing
/// remains to reclaim.
fn reclaim_lance_files(directory: &Path) -> bool {
    let entries = match std::fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(e) => return e.kind() == std::io::ErrorKind::NotFound,
    };
    let mut complete = true;
    for entry in entries {
        let Ok(entry) = entry else {
            complete = false;
            continue;
        };
        let path = entry.path();
        let removed = if path.is_dir() {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        };
        complete &= removed.is_ok();
    }
    complete
}
fn migrate(db: &mut Connection, from: i64, sql: &str) -> Result<()> {
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(error)?;
    let current: i64 = tx
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(error)?;
    if current == from {
        tx.execute_batch(sql).map_err(error)?;
    }
    tx.commit().map_err(error)
}
pub(crate) fn asset_id(asset: &StoredAsset) -> Result<String> {
    Ok(digest(serde_json::to_vec(&asset.key).map_err(error)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn late_legacy_import_does_not_replace_a_committed_catalog() -> Result<()> {
        let root = tempfile::tempdir().map_err(error)?;
        let mut store = Store::open(root.path())?;
        let current = SavedLibrary {
            schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
            apple_scope: "newer".into(),
            ..SavedLibrary::default()
        };
        store.persist(&current)?;
        let old = SavedLibrary {
            apple_scope: "legacy".into(),
            ..current
        };
        store.save(&old, true, None)?;
        assert_eq!(store.read()?.ok_or("missing library")?.apple_scope, "newer");
        Ok(())
    }

    /// Analysis jobs are the cross product of models and `assets` rows. With no
    /// native embedding source for Amazon, its photos must never become rows.
    #[test]
    fn amazon_assets_never_enter_the_analysis_queue() -> Result<()> {
        use suwop_core::domain::{
            AppleVisibility, AssetKey, LibrarySnapshot, Provider, ScanAccess,
        };
        let root = tempfile::tempdir().map_err(error)?;
        let mut store = Store::open(root.path())?;
        let mut connection = suwop_core::amazon::Connection::provisional("credential")?;
        connection.owner_id = "owner".into();
        connection.scope = "amazon.co.jp|owner".into();
        connection.root_id = "root".into();
        let node: suwop_core::amazon::Node = serde_json::from_value(serde_json::json!({
            "id":"photo","name":"photo.jpg","ownerId":"owner",
            "modifiedDate":"2026-10-23T00:00:00Z","status":"AVAILABLE",
            "contentProperties":{"size":3,"md5":"900150983cd24fb0d6963f7d28e17f72",
                "contentType":"image/jpeg"}
        }))
        .map_err(error)?;
        let amazon = node.record(&connection);
        let mut apple = amazon.clone();
        apple.key = AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "source".into(),
        };
        apple.apple_visibility = AppleVisibility::Visible;
        let snapshot = |provider, scope: &str, asset| LibrarySnapshot {
            provider,
            scope: scope.into(),
            assets: vec![asset],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        };
        let state = SavedLibrary {
            schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
            apple_scope: "apple".into(),
            snapshots: vec![
                snapshot(Provider::Apple, "apple", apple),
                snapshot(Provider::Amazon, &connection.scope, amazon),
            ],
            amazon_connection: Some(connection),
            ..SavedLibrary::default()
        };
        store.persist(&state)?;
        let providers: Vec<String> = store
            .db
            .prepare("SELECT json_extract(json,'$.key.provider') FROM assets")
            .map_err(error)?
            .query_map([], |r| r.get(0))
            .map_err(error)?
            .collect::<std::result::Result<_, _>>()
            .map_err(error)?;
        assert_eq!(providers, ["apple"]);
        Ok(())
    }
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionedLibrary {
    pub revision: String,
    pub state: Option<SavedLibrary>,
}
fn row_revision(raw: Option<&str>) -> String {
    match raw {
        Some(raw) => format!("row:{}", digest(raw)),
        None => "absent:v1".into(),
    }
}
