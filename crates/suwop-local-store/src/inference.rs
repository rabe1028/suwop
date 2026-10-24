use crate::{Result, Store, error};
use rusqlite::{OptionalExtension, params};
use suwop_core::{
    analysis::{AnalysisBudget, AnalysisStatus},
    app::ConnectionSettings,
    domain::{Provider, StoredAsset},
    inference::{self, InferenceSelection, InferenceStatus},
};

impl Store {
    /// Only this native provider's complete, current model identities are restorable.
    pub fn compatible_inference_statuses(&self) -> Result<Vec<AnalysisStatus>> {
        Ok(self
            .status()?
            .into_iter()
            .filter(|status| {
                inference::specification(status.model.dimensions)
                    .is_ok_and(|spec| spec.model == status.model)
            })
            .collect())
    }

    /// A selection is a preference, not permission to start or resume inference.
    pub fn select_inference(&self, dimensions: u32) -> Result<InferenceSelection> {
        let model = inference::specification(dimensions)?.model;
        self.db.execute("INSERT INTO inference_selection VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET model=excluded.model", [serde_json::to_string(&model).map_err(error)?]).map_err(error)?;
        self.selected_inference()?
            .ok_or_else(|| "Missing inference selection".into())
    }
    /// Read the selected identity and its journals from one `SQLite` snapshot.
    /// Pre-selection catalogs stay unselected rather than guessing from generation order.
    pub fn selected_inference(&self) -> Result<Option<InferenceSelection>> {
        let tx = self.db.unchecked_transaction().map_err(error)?;
        let json: Option<String> = tx
            .query_row(
                "SELECT model FROM inference_selection WHERE id=1",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(error)?;
        let Some(json) = json else {
            return Ok(None);
        };
        let model: suwop_core::analysis::AnalysisModel =
            serde_json::from_str(&json).map_err(error)?;
        if !inference::specification(model.dimensions).is_ok_and(|spec| spec.model == model) {
            return Ok(None);
        }
        let analysis = self
            .status()?
            .into_iter()
            .find(|status| status.model == model);
        let inference = match &analysis {
            Some(status) => self.inference_status(&status.model_key)?,
            None => None,
        };
        tx.commit().map_err(error)?;
        Ok(Some(InferenceSelection {
            model,
            analysis,
            inference,
        }))
    }

    pub fn validate_embedding_input(
        &self,
        expected: &StoredAsset,
        fresh: &StoredAsset,
        connection: Option<&ConnectionSettings>,
    ) -> Result<()> {
        // Source eligibility and connection are read in one SQLite snapshot. A UI
        // snapshot can lag a completed catalog commit during a server/account switch.
        let current: Option<Option<String>> = self.db.query_row(
            "SELECT json_extract(l.json,'$.connection') FROM assets a JOIN library_state l ON l.id=1 WHERE a.id=?1 AND a.revision=?2",
            params![crate::catalog::asset_id(expected)?, expected.revision], |row| row.get(0),
        ).optional().map_err(error)?;
        let Some(stored_connection) = current else {
            return Err("Photo is no longer available for inference".into());
        };
        if expected.key != fresh.key
            || expected.revision != fresh.revision
            || !fresh.content_visible()
        {
            return Err("Photo changed during inference input preparation".into());
        }
        if expected.key.provider == Provider::Immich {
            let actual = connection.ok_or("Inference requires the current connection")?;
            let stored: ConnectionSettings = serde_json::from_str(
                &stored_connection.ok_or("The inference destination was disconnected")?,
            )
            .map_err(error)?;
            if actual.address != stored.address
                || actual.credential_id != stored.credential_id
                || actual.allow_http != stored.allow_http
                || expected
                    .key
                    .scope
                    .strip_prefix(&format!("{}#", actual.address))
                    .is_none_or(str::is_empty)
            {
                return Err("The inference destination or account changed".into());
            }
        }
        Ok(())
    }
    pub fn configure_inference(&mut self, dimensions: u32, budget: u64) -> Result<InferenceStatus> {
        inference::validate_budget(budget)?;
        let model = inference::specification(dimensions)?.model;
        let key = self.register(&model, &AnalysisBudget::default())?;
        // Explicit configuration atomically selects and resumes the requested model.
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        tx.execute("INSERT INTO inference_runs VALUES(?1,'running',?2,NULL) ON CONFLICT(model) DO UPDATE SET budget=excluded.budget,state='running',error=NULL",params![key,i64::try_from(budget).map_err(error)?]).map_err(error)?;
        tx.execute("UPDATE generations SET state='building',error=NULL WHERE id=(SELECT latest FROM models WHERE id=?1)", [&key]).map_err(error)?;
        tx.execute("UPDATE jobs SET reason=NULL WHERE state='awaiting' AND generation=(SELECT latest FROM models WHERE id=?1)", [&key]).map_err(error)?;
        tx.execute("INSERT INTO inference_selection VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET model=excluded.model", [serde_json::to_string(&model).map_err(error)?]).map_err(error)?;
        tx.commit().map_err(error)?;
        self.inference_status(&key)?
            .ok_or_else(|| "Missing inference state".into())
    }
    pub fn set_inference_budget(&self, key: &str, budget: u64) -> Result<()> {
        inference::validate_budget(budget)?;
        let changed = self
            .db
            .execute(
                "UPDATE inference_runs SET budget=?2 WHERE model=?1",
                params![key, i64::try_from(budget).map_err(error)?],
            )
            .map_err(error)?;
        if changed != 1 {
            return Err("Inference is not configured".into());
        }
        Ok(())
    }
    pub fn inference_status(&self, key: &str) -> Result<Option<InferenceStatus>> {
        let mut status = self
            .db
            .query_row(
                "SELECT state,budget,error FROM inference_runs WHERE model=?1",
                [key],
                |row| {
                    Ok(InferenceStatus {
                        model_key: key.into(),
                        failed_job: None,
                        state: row.get(0)?,
                        budget_bytes: u64::from(row.get::<_, u32>(1)?),
                        error: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(error)?;
        if let Some(status) = &mut status
            && status.state == "paused"
        {
            status.failed_job = self.db.query_row("SELECT CAST(j.id AS TEXT) FROM jobs j JOIN models m ON m.latest=j.generation JOIN assets a ON a.id=j.asset AND a.revision=j.revision WHERE m.id=?1 AND j.state='awaiting' AND j.reason IS NOT NULL ORDER BY j.id LIMIT 1", [key], |r|r.get(0)).optional().map_err(error)?;
        }
        Ok(status)
    }
    pub fn pause_inference(&self, key: &str, reason: Option<&str>) -> Result<()> {
        if reason.is_some_and(|r| r.len() > 512) {
            return Err("Inference error is too long".into());
        }
        self.db
            .execute(
                "UPDATE inference_runs SET state='paused',error=?2 WHERE model=?1",
                params![key, reason],
            )
            .map_err(error)?;
        Ok(())
    }
    pub fn admit_inference(
        &self,
        key: &str,
        resident: u64,
        available: u64,
        loaded: bool,
        pressure: bool,
        query: bool,
    ) -> Result<bool> {
        let model = self.model(key)?;
        if inference::specification(model.dimensions)?.model != model {
            return Err("This model requires a different inference provider".into());
        }
        let status = self
            .inference_status(key)?
            .ok_or("Inference is not configured")?;
        if status.state != "running" && !query {
            return Ok(false);
        }
        if let Err(reason) =
            inference::admit(status.budget_bytes, resident, available, loaded, pressure)
        {
            self.pause_inference(key, Some(&reason))?;
            return Ok(false);
        }
        Ok(true)
    }
}
