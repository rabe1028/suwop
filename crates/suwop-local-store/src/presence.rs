//! Durable identity survives temporary catalog projection removal.
use crate::{Result, error};
use rusqlite::{Transaction, params};
use suwop_core::{analysis::AnalysisPresence, app::SavedLibrary, domain::AssetKey};

pub(crate) fn detach_confirmed_removed(tx: &Transaction<'_>, state: &SavedLibrary) -> Result<()> {
    let presence = AnalysisPresence::new(state);
    let mut query = tx.prepare("SELECT j.asset,j.revision,k.json FROM jobs j JOIN analysis_asset_keys k ON k.id=j.asset WHERE j.state='obsolete' AND j.shard IS NOT NULL GROUP BY j.asset,j.revision").map_err(error)?;
    let mut rows = query.query([]).map_err(error)?;
    while let Some(row) = rows.next().map_err(error)? {
        let asset: String = row.get(0).map_err(error)?;
        let revision: String = row.get(1).map_err(error)?;
        let key: AssetKey =
            serde_json::from_str(&row.get::<_, String>(2).map_err(error)?).map_err(error)?;
        if presence.confirms_removed_revision(&key, &revision) {
            tx.execute(
                "UPDATE jobs SET shard=NULL WHERE asset=?1 AND revision=?2 AND state='obsolete'",
                params![asset, revision],
            )
            .map_err(error)?;
        }
    }
    Ok(())
}
