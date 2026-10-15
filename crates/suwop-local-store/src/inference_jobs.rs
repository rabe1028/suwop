//! Durable per-photo failures and explicit, reversible analysis exclusion.
use crate::{Result, Store, error};
use rusqlite::{OptionalExtension, params};
use suwop_core::inference::{self, InferenceStatus};

impl Store {
    /// Obsolete jobs do not pause a newer source revision or generation.
    pub fn fail_inference_job(&mut self, key: &str, job: &str, reason: &str) -> Result<bool> {
        if reason.trim().is_empty() || reason.len() > 512 {
            return Err("A short failure reason is required".into());
        }
        let reason: String = reason
            .chars()
            .map(|ch| if ch.is_control() { ' ' } else { ch })
            .collect();
        let id = job.parse::<i64>().map_err(error)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let current: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM jobs j JOIN assets a ON a.id=j.asset AND a.revision=j.revision JOIN models m ON m.latest=j.generation JOIN generations g ON g.id=j.generation JOIN inference_runs i ON i.model=m.id WHERE j.id=?1 AND m.id=?2 AND j.state='awaiting' AND g.state='building' AND i.state='running')", params![id,key], |r|r.get(0)).map_err(error)?;
        if !current {
            return Ok(false);
        }
        tx.execute("UPDATE jobs SET reason=NULL WHERE state='awaiting' AND generation=(SELECT latest FROM models WHERE id=?1)", [key]).map_err(error)?;
        tx.execute("UPDATE jobs SET reason=?2 WHERE id=?1", params![id, reason])
            .map_err(error)?;
        tx.execute(
            "UPDATE inference_runs SET state='paused',error=?2 WHERE model=?1",
            params![key, reason],
        )
        .map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(true)
    }
    /// The UI must explicitly identify the failed job. Never exclude the next job by position.
    pub fn skip_failed_inference(
        &mut self,
        key: &str,
        job: &str,
        budget: u64,
    ) -> Result<InferenceStatus> {
        inference::validate_budget(budget)?;
        let id = job.parse::<i64>().map_err(error)?;
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let reason: Option<String> = tx.query_row("SELECT j.reason FROM jobs j JOIN models m ON m.latest=j.generation JOIN inference_runs i ON i.model=m.id WHERE j.id=?1 AND m.id=?2 AND j.state='awaiting' AND j.reason IS NOT NULL AND i.state='paused'",params![id,key],|r|r.get(0)).optional().map_err(error)?;
        let reason =
            reason.ok_or("The failed photo is no longer current; refresh or resume analysis")?;
        crate::jobs::exclude_job(&tx, key, id, &reason)?;
        tx.execute(
            "UPDATE inference_runs SET state='running',error=NULL,budget=?2 WHERE model=?1",
            params![key, i64::try_from(budget).map_err(error)?],
        )
        .map_err(error)?;
        tx.execute("UPDATE generations SET state='building',error=NULL WHERE id=(SELECT latest FROM models WHERE id=?1)",[key]).map_err(error)?;
        tx.commit().map_err(error)?;
        self.inference_status(key)?
            .ok_or_else(|| "Missing inference state".into())
    }
}
