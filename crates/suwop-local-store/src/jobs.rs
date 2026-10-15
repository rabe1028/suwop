use crate::{Result, Store, digest, error};
use rusqlite::{OptionalExtension, Transaction, params};
use suwop_core::analysis::{
    AnalysisBudget, AnalysisModel, AnalysisStatus, EmbeddingInput, EmbeddingJob,
};

pub(crate) fn enqueue_latest(tx: &Transaction<'_>) -> Result<()> {
    tx.execute("INSERT OR IGNORE INTO jobs(generation,asset,revision,state) SELECT m.latest,a.id,a.revision,'awaiting' FROM models m CROSS JOIN assets a", []).map_err(error)?;
    // A source may return after becoming temporarily absent. Its result must be
    // supplied again; do not resurrect a stale/unpublished vector implicitly.
    tx.execute("UPDATE jobs SET state='awaiting',shard=NULL,reason=NULL WHERE state='obsolete' AND EXISTS (SELECT 1 FROM models m JOIN assets a ON a.id=jobs.asset AND a.revision=jobs.revision WHERE m.latest=jobs.generation)", []).map_err(error)?;
    tx.execute("UPDATE generations SET state='building' WHERE state='ready' AND EXISTS (SELECT 1 FROM jobs j WHERE j.generation=generations.id AND j.state IN ('awaiting','queued'))", []).map_err(error)?;
    Ok(())
}
impl Store {
    pub fn register(&mut self, model: &AnalysisModel, budget: &AnalysisBudget) -> Result<String> {
        model.validate()?;
        budget.rows(model.dimensions)?;
        let encoded = serde_json::to_string(model).map_err(error)?;
        let key = digest(&encoded);
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        if !tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM models WHERE id=?1)",
                [&key],
                |r| r.get::<_, bool>(0),
            )
            .map_err(error)?
        {
            tx.execute(
                "INSERT INTO models VALUES(?1,?2,NULL,0)",
                params![key, encoded],
            )
            .map_err(error)?;
            tx.execute(
                "INSERT INTO generations(model,budget,batch_rows,state) VALUES(?1,?2,?3,'building')",
                params![key, serde_json::to_string(budget).map_err(error)?, i64::try_from(budget.rows(model.dimensions)?).map_err(error)?],
            )
            .map_err(error)?;
            tx.execute(
                "UPDATE models SET latest=?2 WHERE id=?1",
                params![key, tx.last_insert_rowid()],
            )
            .map_err(error)?;
        }
        enqueue_latest(&tx)?;
        tx.commit().map_err(error)?;
        Ok(key)
    }
    pub fn rebuild(&mut self, key: &str, budget: &AnalysisBudget) -> Result<()> {
        let model = self.model(key)?;
        budget.rows(model.dimensions)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        tx.execute("UPDATE generations SET state='retired' WHERE model=?1 AND id NOT IN (SELECT active FROM models WHERE id=?1 AND active IS NOT NULL)", [key]).map_err(error)?;
        tx.execute(
            "INSERT INTO generations(model,budget,batch_rows,state) VALUES(?1,?2,?3,'building')",
            params![
                key,
                serde_json::to_string(budget).map_err(error)?,
                i64::try_from(budget.rows(model.dimensions)?).map_err(error)?
            ],
        )
        .map_err(error)?;
        tx.execute(
            "UPDATE models SET latest=?2 WHERE id=?1",
            params![key, tx.last_insert_rowid()],
        )
        .map_err(error)?;
        enqueue_latest(&tx)?;
        tx.commit().map_err(error)
    }
    pub(crate) fn model(&self, key: &str) -> Result<AnalysisModel> {
        let text: String = self
            .db
            .query_row("SELECT json FROM models WHERE id=?1", [key], |r| r.get(0))
            .map_err(error)?;
        serde_json::from_str(&text).map_err(error)
    }
    pub fn pause(&self, key: &str, paused: bool) -> Result<()> {
        let state = if paused { "paused" } else { "building" };
        let changed = self.db.execute("UPDATE generations SET state=?2,error=NULL WHERE id=(SELECT latest FROM models WHERE id=?1)", params![key,state]).map_err(error)?;
        if changed != 1 {
            return Err("Unknown analysis model".into());
        }
        Ok(())
    }
    pub fn pending(&self, key: &str, limit: u32) -> Result<Vec<EmbeddingJob>> {
        if !(1..=32).contains(&limit) {
            return Err("Embedding request limit must be 1..32".into());
        }
        let model = self.model(key)?;
        let rows: u32 = self.db.query_row("SELECT g.batch_rows FROM models m JOIN generations g ON g.id=m.latest WHERE m.id=?1",[key],|r|r.get(0)).map_err(error)?;
        let limit = limit.min(rows);
        let mut query = self.db.prepare("SELECT j.id,j.generation,a.json FROM jobs j JOIN assets a ON a.id=j.asset AND a.revision=j.revision JOIN models m ON m.latest=j.generation JOIN generations g ON g.id=j.generation WHERE m.id=?1 AND j.state='awaiting' AND g.state='building' ORDER BY j.id LIMIT ?2").map_err(error)?;
        let rows = query
            .query_map(params![key, limit], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(error)?;
        rows.map(|r| {
            let (id, generation, asset) = r.map_err(error)?;
            Ok(EmbeddingJob {
                id: id.to_string(),
                model_key: key.into(),
                generation,
                model: model.clone(),
                asset: serde_json::from_str(&asset).map_err(error)?,
            })
        })
        .collect()
    }
    /// Idempotent outbox delivery. Stale results cannot be attached to a new revision.
    pub fn submit(&mut self, key: &str, vectors: &[EmbeddingInput]) -> Result<()> {
        let model = self.model(key)?;
        let budget: String = self
            .db
            .query_row(
                "SELECT g.budget FROM generations g JOIN models m ON m.latest=g.id WHERE m.id=?1",
                [key],
                |r| r.get(0),
            )
            .map_err(error)?;
        let budget: AnalysisBudget = serde_json::from_str(&budget).map_err(error)?;
        if vectors.len() > budget.rows(model.dimensions)? {
            return Err("Embedding batch exceeds model memory budget".into());
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        for input in vectors {
            let id = input.job_id.parse::<i64>().map_err(error)?;
            let current: Option<String> = tx.query_row("SELECT j.state FROM jobs j JOIN assets a ON a.id=j.asset AND a.revision=j.revision JOIN models m ON m.latest=j.generation WHERE j.id=?1 AND m.id=?2",params![id,key],|r|r.get(0)).optional().map_err(error)?;
            let state = current.ok_or("Embedding result is stale")?;
            if state != "awaiting" {
                continue;
            }
            let vector = normalized(&input.vector, model.dimensions)?;
            let bytes = vector
                .iter()
                .flat_map(|v| v.to_le_bytes())
                .collect::<Vec<_>>();
            tx.execute(
                "INSERT INTO embedding_vectors(job,vector) VALUES(?1,?2)",
                params![id, bytes],
            )
            .map_err(error)?;
            tx.execute("UPDATE jobs SET state='queued' WHERE id=?1", [id])
                .map_err(error)?;
        }
        tx.commit().map_err(error)
    }
    /// Providers explicitly exclude unsupported or undecodable media from a generation.
    pub fn skip(&mut self, key: &str, job: &str, reason: &str) -> Result<()> {
        let id = job.parse::<i64>().map_err(error)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        exclude_job(&tx, key, id, reason)?;
        tx.commit().map_err(error)
    }
    pub fn status(&self) -> Result<Vec<AnalysisStatus>> {
        let mut query = self.db.prepare("SELECT m.id,m.json,m.latest,m.active,g.state,g.budget,g.error FROM models m JOIN generations g ON g.id=m.latest ORDER BY m.id").map_err(error)?;
        let rows = query
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, Option<String>>(6)?,
                ))
            })
            .map_err(error)?;
        rows.map(|r| {
            let (model_key, model, generation, active_generation, state, budget, error_message) =
                r.map_err(error)?;
            let count = |state: &str| {
                self.db
                    .query_row(
                        "SELECT count(*) FROM jobs WHERE generation=?1 AND state=?2",
                        params![generation, state],
                        |r| r.get::<_, i64>(0),
                    )
                    .map_err(error)
                    .and_then(|value| u64::try_from(value).map_err(error))
            };
            Ok(AnalysisStatus {
                model_key,
                model: serde_json::from_str(&model).map_err(error)?,
                generation,
                active_generation,
                state,
                awaiting_embeddings: count("awaiting")?,
                queued_vectors: count("queued")?,
                indexed: count("done")?,
                skipped: count("skipped")?,
                budget: serde_json::from_str(&budget).map_err(error)?,
                error: error_message,
            })
        })
        .collect()
    }
}
pub(crate) fn normalized(vector: &[f32], dimensions: u32) -> Result<Vec<f32>> {
    if vector.len() != dimensions as usize || vector.iter().any(|v| !v.is_finite()) {
        return Err("Invalid embedding shape or non-finite value".into());
    }
    let length = vector
        .iter()
        .map(|v| f64::from(*v).powi(2))
        .sum::<f64>()
        .sqrt();
    if length == 0.0 || !length.is_finite() {
        return Err("Embedding has no finite direction".into());
    }
    #[allow(clippy::cast_possible_truncation)] // Normalized components are finite in [-1, 1].
    Ok(vector
        .iter()
        .map(|v| (f64::from(*v) / length) as f32)
        .collect())
}

/// Common exclusion policy for providers and an explicit failed-photo recovery action.
pub(crate) fn exclude_job(tx: &Transaction<'_>, key: &str, id: i64, reason: &str) -> Result<()> {
    if reason.is_empty() || reason.len() > 512 || reason.chars().any(char::is_control) {
        return Err("A short exclusion reason is required".into());
    }
    let changed = tx.execute("UPDATE jobs SET state='skipped',reason=?3 WHERE id=?1 AND state IN ('awaiting','queued') AND generation=(SELECT latest FROM models WHERE id=?2) AND EXISTS(SELECT 1 FROM assets a WHERE a.id=jobs.asset AND a.revision=jobs.revision)", params![id,key,reason]).map_err(error)?;
    if changed != 1 {
        return Err("Job cannot be excluded in its current state".into());
    }
    tx.execute("DELETE FROM embedding_vectors WHERE job=?1", [id])
        .map_err(error)?;
    Ok(())
}
