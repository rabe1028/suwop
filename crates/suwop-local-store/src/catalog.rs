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
            return serde_json::from_str(&text).map(Some).map_err(error);
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
        self.save(&state, true)?;
        // A second process may have completed migration or persisted newer state.
        self.read()
    }
    /// Metadata and the analysis outbox commit together. Never takes the analysis lock.
    pub fn persist(&mut self, state: &SavedLibrary) -> Result<()> {
        self.save(state, false)
    }
    fn save(&mut self, state: &SavedLibrary, import_only: bool) -> Result<()> {
        let text = serde_json::to_string(state).map_err(error)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        if import_only
            && tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM library_state WHERE id=1)",
                    [],
                    |r| r.get::<_, bool>(0),
                )
                .map_err(error)?
        {
            return Ok(());
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
        tx.commit().map_err(error)
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
            schema_version: 2,
            apple_scope: "newer".into(),
            ..SavedLibrary::default()
        };
        store.persist(&current)?;
        let old = SavedLibrary {
            apple_scope: "legacy".into(),
            ..current
        };
        store.save(&old, true)?;
        assert_eq!(store.read()?.ok_or("missing library")?.apple_scope, "newer");
        Ok(())
    }
}
