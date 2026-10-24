//! Int8 vectors in the catalog. Publication and vector writes share one transaction.
use crate::{Result, Store, error, jobs::normalized};
use rusqlite::{OptionalExtension, Transaction, params};
use std::fs::File;
use suwop_core::{
    analysis::{AnalysisBudget, SimilarityHit},
    domain::StoredAsset,
};

#[derive(Debug)]
struct Chunk {
    id: i64,
    generation: i64,
    model: String,
    rows: Vec<(i64, Vec<f32>)>,
}
/// Symmetric per-vector int8 codes. Components of a normalized vector lie in [-1, 1].
fn quantize(vector: &[f32]) -> (f32, Vec<u8>) {
    let peak = vector.iter().fold(0.0_f32, |m, v| m.max(v.abs()));
    let scale = if peak > 0.0 { peak / 127.0 } else { 1.0 };
    #[allow(clippy::cast_possible_truncation)] // Rounded values are within [-127, 127].
    let codes = vector
        .iter()
        .map(|v| (v / scale).round().clamp(-127.0, 127.0) as i8)
        .map(i8::cast_unsigned)
        .collect();
    (scale, codes)
}
/// Squared L2 distance between unit vectors, matching the previous index ordering.
fn distance(query: &[f32], scale: f32, codes: &[u8]) -> f32 {
    let dot: f32 = query
        .iter()
        .zip(codes)
        .map(|(q, c)| q * f32::from(c.cast_signed()))
        .sum();
    2.0 - 2.0 * dot * scale
}
fn drop_shard(tx: &Transaction<'_>, shard: i64) -> Result<()> {
    tx.execute("DELETE FROM index_vectors WHERE shard=?1", [shard])
        .map_err(error)?;
    tx.execute("DELETE FROM shards WHERE id=?1", [shard])
        .map_err(error)?;
    Ok(())
}
impl Store {
    pub(crate) fn analysis_lock(&self) -> Result<File> {
        let file = File::options()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.root.join("analysis.lock"))
            .map_err(error)?;
        file.lock().map_err(error)?;
        Ok(file)
    }
    fn claim(&mut self) -> Result<Option<Chunk>> {
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let candidate: Option<(i64,String,String,String)> = tx.query_row("SELECT g.id,m.id,m.json,g.budget FROM generations g JOIN models m ON m.latest=g.id WHERE g.state='building' AND EXISTS(SELECT 1 FROM jobs j WHERE j.generation=g.id AND j.state='queued') AND (EXISTS(SELECT 1 FROM shards s WHERE s.generation=g.id AND s.state='pending') OR (SELECT count(*) FROM jobs j WHERE j.generation=g.id AND j.state='queued')>=g.batch_rows OR NOT EXISTS(SELECT 1 FROM jobs j WHERE j.generation=g.id AND j.state='awaiting')) ORDER BY g.id LIMIT 1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(error)?;
        let Some((generation, model, config, budget)) = candidate else {
            return Ok(None);
        };
        let config: suwop_core::analysis::AnalysisModel =
            serde_json::from_str(&config).map_err(error)?;
        let budget: AnalysisBudget = serde_json::from_str(&budget).map_err(error)?;
        let limit = i64::try_from(budget.rows(config.dimensions)?).map_err(error)?;
        let pending: Option<i64> = tx
            .query_row(
                "SELECT id FROM shards WHERE generation=?1 AND state='pending' ORDER BY id LIMIT 1",
                [generation],
                |r| r.get(0),
            )
            .optional()
            .map_err(error)?;
        let id = if let Some(id) = pending {
            id
        } else {
            tx.execute(
                "INSERT INTO shards(generation,state) VALUES(?1,'pending')",
                [generation],
            )
            .map_err(error)?;
            let id = tx.last_insert_rowid();
            tx.execute("UPDATE jobs SET shard=?3 WHERE id IN (SELECT id FROM jobs WHERE generation=?1 AND state='queued' AND shard IS NULL ORDER BY id LIMIT ?2)",params![generation,limit,id]).map_err(error)?;
            id
        };
        let rows = (|| {
            let mut statement = tx.prepare("SELECT j.id,v.vector FROM jobs j LEFT JOIN embedding_vectors v ON v.job=j.id WHERE j.shard=?1 AND j.state='queued' ORDER BY j.id LIMIT ?2").map_err(error)?;
            let rows = statement
                .query_map(params![id, limit], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
                })
                .map_err(error)?;
            rows.map(|row| {
                let (id, bytes) = row.map_err(error)?;
                if bytes.len() != usize::try_from(config.dimensions).map_err(error)? * 4 {
                    return Err("Invalid queued vector".into());
                }
                let vector = bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    .collect();
                Ok((id, vector))
            })
            .collect::<Result<Vec<_>>>()
        })();
        let rows = match rows {
            Ok(rows) => rows,
            Err(message) => {
                tx.execute(
                    "UPDATE generations SET state='paused',error=?2 WHERE id=?1",
                    params![generation, message],
                )
                .map_err(error)?;
                tx.commit().map_err(error)?;
                return Err(message);
            }
        };
        tx.commit().map_err(error)?;
        Ok(Some(Chunk {
            id,
            generation,
            model,
            rows,
        }))
    }
    /// Runs one bounded checkpoint. Vectors become searchable in the publishing transaction.
    pub fn step(&mut self) -> Result<bool> {
        let _guard = self.analysis_lock()?;
        let Some(chunk) = self.claim()? else {
            let tx = self
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(error)?;
            tx.execute("UPDATE models SET active=latest WHERE EXISTS(SELECT 1 FROM generations g WHERE g.id=models.latest AND g.state='building') AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.generation=models.latest AND j.state IN ('awaiting','queued'))",[]).map_err(error)?;
            tx.execute("UPDATE generations SET state='ready' WHERE state='building' AND id IN (SELECT active FROM models WHERE active=latest) AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.generation=generations.id AND j.state IN ('awaiting','queued'))",[]).map_err(error)?;
            tx.commit().map_err(error)?;
            // Publication is durable before cleanup. Each checkpoint drops at most
            // one retired shard so searches and newly queued work can interleave.
            if self.prune_one()?.is_some() {
                return Ok(true);
            }
            return self.compact();
        };
        match self.publish(&chunk) {
            Ok(published) => Ok(published),
            Err(message) => {
                self.db.execute("UPDATE generations SET state='paused',error=?2 WHERE id=?1 AND state='building'",params![chunk.generation,message]).map_err(error)?;
                Err(message)
            }
        }
    }
    /// An unpublished (paused or superseded) shard keeps its staged vectors for replay.
    fn publish(&mut self, chunk: &Chunk) -> Result<bool> {
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let publish: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM models m JOIN generations g ON g.id=m.latest WHERE m.id=?1 AND g.id=?2 AND g.state='building')",params![chunk.model,chunk.generation],|r|r.get(0)).map_err(error)?;
        if !publish {
            return Ok(false);
        }
        {
            let mut insert = tx
                .prepare("INSERT OR REPLACE INTO index_vectors(job,shard,scale,codes) VALUES(?1,?2,?3,?4)")
                .map_err(error)?;
            for (job, vector) in &chunk.rows {
                let (scale, codes) = quantize(vector);
                insert
                    .execute(params![job, chunk.id, f64::from(scale), codes])
                    .map_err(error)?;
            }
        }
        tx.execute("UPDATE shards SET state='ready' WHERE id=?1", [chunk.id])
            .map_err(error)?;
        tx.execute(
            "UPDATE jobs SET state='done' WHERE shard=?1 AND state='queued'",
            [chunk.id],
        )
        .map_err(error)?;
        tx.execute("DELETE FROM embedding_vectors WHERE job IN (SELECT id FROM jobs WHERE shard=?1 AND state='done')",[chunk.id]).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(true)
    }
    /// Remove retired generations and unreferenced shards, preserving live jobs.
    pub fn prune(&mut self) -> Result<u64> {
        let _guard = self.analysis_lock()?;
        let mut removed = 0;
        while let Some(count) = self.prune_one()? {
            removed += count;
        }
        Ok(removed)
    }
    /// Caller holds the analysis lock. Each removal commits with its journal entry.
    fn prune_one(&mut self) -> Result<Option<u64>> {
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let retired: Option<i64> = tx.query_row("SELECT g.id FROM generations g JOIN models m ON m.id=g.model WHERE g.id!=m.latest AND (m.active IS NULL OR g.id!=m.active) ORDER BY g.id LIMIT 1", [], |r|r.get(0)).optional().map_err(error)?;
        let removed = if let Some(generation) = retired {
            let shard: Option<i64> = tx
                .query_row(
                    "SELECT id FROM shards WHERE generation=?1 ORDER BY id LIMIT 1",
                    [generation],
                    |r| r.get(0),
                )
                .optional()
                .map_err(error)?;
            if let Some(shard) = shard {
                drop_shard(&tx, shard)?;
                Some(1)
            } else {
                tx.execute("DELETE FROM jobs WHERE generation=?1", [generation])
                    .map_err(error)?;
                tx.execute("DELETE FROM generations WHERE id=?1", [generation])
                    .map_err(error)?;
                Some(0)
            }
        } else {
            // Metadata may detach references, but never attaches jobs to an existing shard.
            let shard: Option<i64> = tx.query_row(
                "SELECT s.id FROM shards s WHERE NOT EXISTS (SELECT 1 FROM jobs j WHERE j.shard=s.id) ORDER BY s.id LIMIT 1",
                [], |r| r.get(0),
            ).optional().map_err(error)?;
            if let Some(shard) = shard {
                drop_shard(&tx, shard)?;
                Some(1)
            } else {
                None
            }
        };
        tx.commit().map_err(error)?;
        Ok(removed)
    }
    /// Exact search over the active generation's current revisions.
    pub fn search(&self, key: &str, vector: &[f32], limit: u32) -> Result<Vec<SimilarityHit>> {
        if !(1..=100).contains(&limit) {
            return Err("Search limit must be 1..100".into());
        }
        let model = self.model(key)?;
        let vector = normalized(vector, model.dimensions)?;
        let limit = usize::try_from(limit).map_err(error)?;
        // One read snapshot spans generation selection, the scan and hit lookup, so a
        // concurrent publication or prune cannot leave this search on a removed generation.
        let tx = self.db.unchecked_transaction().map_err(error)?;
        let generation: i64 = tx
            .query_row(
                "SELECT g.id FROM models m JOIN generations g ON g.id=m.active WHERE m.id=?1",
                [key],
                |r| r.get(0),
            )
            .optional()
            .map_err(error)?
            .ok_or("Model index is not ready")?;
        // Catalog commits mark jobs for replaced or removed revisions obsolete in the
        // same transaction, so a done job is current; winners are rechecked below.
        let mut best: Vec<(f32, i64)> = Vec::with_capacity(limit + 1);
        let mut query = tx.prepare("SELECT v.job,v.scale,v.codes FROM jobs j JOIN index_vectors v ON v.job=j.id AND v.shard=j.shard WHERE j.generation=?1 AND j.state='done'").map_err(error)?;
        let mut rows = query.query([generation]).map_err(error)?;
        while let Some(row) = rows.next().map_err(error)? {
            let codes = row.get_ref(2).map_err(error)?.as_blob().map_err(error)?;
            if codes.len() != vector.len() {
                return Err("Invalid stored vector".into());
            }
            #[allow(clippy::cast_possible_truncation)] // Stored from an f32 scale.
            let scale = row.get::<_, f64>(1).map_err(error)? as f32;
            let candidate = (distance(&vector, scale, codes), row.get(0).map_err(error)?);
            if best.len() == limit && best.last().is_some_and(|last| candidate >= *last) {
                continue;
            }
            let at = best.partition_point(|entry| *entry < candidate);
            best.insert(at, candidate);
            best.truncate(limit);
        }
        let mut hits = Vec::with_capacity(best.len());
        for (distance, job) in best {
            let asset: Option<String> = tx.query_row("SELECT a.json FROM jobs j JOIN assets a ON a.id=j.asset AND a.revision=j.revision JOIN shards s ON s.id=j.shard WHERE j.id=?1 AND j.state='done' AND s.state='ready'",[job],|r|r.get(0)).optional().map_err(error)?;
            if let Some(asset) = asset {
                let asset: StoredAsset = serde_json::from_str(&asset).map_err(error)?;
                hits.push(SimilarityHit {
                    asset: asset.key,
                    revision: asset.revision,
                    distance,
                });
            }
        }
        Ok(hits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn int8_distance_tracks_exact_unit_distance() -> Result<()> {
        let a = normalized(&[0.9, -0.3, 0.2, 0.05, -0.7, 0.4], 6)?;
        let b = normalized(&[0.8, -0.1, 0.3, 0.0, -0.6, 0.5], 6)?;
        let exact: f32 = 2.0 - 2.0 * a.iter().zip(&b).map(|(x, y)| x * y).sum::<f32>();
        let (scale, codes) = quantize(&b);
        assert!((distance(&a, scale, &codes) - exact).abs() < 0.01);
        let (scale, codes) = quantize(&a);
        assert!(distance(&a, scale, &codes).abs() < 0.01);
        assert!(distance(&a, scale, &codes) < distance(&b, scale, &codes));
        Ok(())
    }
}
