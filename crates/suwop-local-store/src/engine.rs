//! Bounded, immutable Lance shards. `SQLite` is the publication/recovery journal.
use crate::{Result, Store, error, jobs::normalized};
use arrow_array::{
    Array, FixedSizeListArray, Float32Array, Int64Array, RecordBatch, types::Float32Type,
};
use arrow_schema::{DataType, Field, Schema};
use futures::TryStreamExt;
use lancedb::{
    connect,
    index::{Index, vector::IvfHnswFlatIndexBuilder},
    query::{ExecutableQuery, QueryBase},
};
use rusqlite::{OptionalExtension, params};
use std::{fs::File, sync::Arc};
use suwop_core::{
    analysis::{AnalysisBudget, SimilarityHit},
    domain::StoredAsset,
};

#[derive(Debug)]
struct Chunk {
    id: i64,
    generation: i64,
    model: String,
    dimensions: u32,
    budget: AnalysisBudget,
    rows: Vec<(i64, Vec<f32>)>,
}
fn name(generation: i64, shard: i64) -> String {
    format!("g{generation}_s{shard}")
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
    async fn connection(&self, budget: &AnalysisBudget) -> Result<lancedb::Connection> {
        let cache = usize::try_from(budget.cache_bytes).map_err(error)?;
        let session = Arc::new(lancedb::Session::new(
            cache,
            cache,
            Arc::new(lancedb::ObjectStoreRegistry::default()),
        ));
        let path = self.root.join("analysis");
        connect(path.to_str().ok_or("Non-UTF8 analysis path")?)
            .session(session)
            .execute()
            .await
            .map_err(error)
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
            dimensions: config.dimensions,
            budget,
            rows,
        }))
    }
    /// Runs one bounded checkpoint. No `SQLite` transaction spans Lance work.
    /// Call on an I/O thread; the file lock serializes native engine working sets.
    pub async fn step(&mut self) -> Result<bool> {
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
            if self.prune_one().await?.is_some() {
                return Ok(true);
            }
            return self.compact();
        };
        if let Err(message) = self.write_chunk(&chunk).await {
            self.db.execute("UPDATE generations SET state='paused',error=?2 WHERE id=?1 AND state='building'",params![chunk.generation,message]).map_err(error)?;
            return Err(message);
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        let publish: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM models m JOIN generations g ON g.id=m.latest WHERE m.id=?1 AND g.id=?2 AND g.state='building')",params![chunk.model,chunk.generation],|r|r.get(0)).map_err(error)?;
        if publish {
            tx.execute("UPDATE shards SET state='ready' WHERE id=?1", [chunk.id])
                .map_err(error)?;
            tx.execute(
                "UPDATE jobs SET state='done' WHERE shard=?1 AND state='queued'",
                [chunk.id],
            )
            .map_err(error)?;
            tx.execute("DELETE FROM embedding_vectors WHERE job IN (SELECT id FROM jobs WHERE shard=?1 AND state='done')",[chunk.id]).map_err(error)?;
        }
        tx.commit().map_err(error)?;
        Ok(publish)
    }
    async fn write_chunk(&self, chunk: &Chunk) -> Result<()> {
        if chunk.rows.is_empty() {
            return Ok(());
        }
        let dimensions = i32::try_from(chunk.dimensions).map_err(error)?;
        let vectors = FixedSizeListArray::from_iter_primitive::<Float32Type, _, _>(
            chunk
                .rows
                .iter()
                .map(|(_, v)| Some(v.iter().copied().map(Some))),
            dimensions,
        );
        let schema = Arc::new(Schema::new(vec![
            Field::new("id", DataType::Int64, false),
            Field::new("vector", vectors.data_type().clone(), true),
        ]));
        let batch = RecordBatch::try_new(
            schema.clone(),
            vec![
                Arc::new(Int64Array::from(
                    chunk.rows.iter().map(|(id, _)| *id).collect::<Vec<_>>(),
                )),
                Arc::new(vectors),
            ],
        )
        .map_err(error)?;
        let connection = self.connection(&chunk.budget).await?;
        // This manifest entry is unpublished and protected by the analysis lock.
        // Recreate it so repeated interrupted writes cannot accumulate old versions.
        match connection
            .drop_table(&name(chunk.generation, chunk.id), &[])
            .await
        {
            Ok(()) | Err(lancedb::Error::TableNotFound { .. }) => {}
            Err(e) => return Err(error(e)),
        }
        let table = connection
            .create_table(name(chunk.generation, chunk.id), batch)
            .execute()
            .await
            .map_err(error)?;
        // Tiny shards use exact search; no global training matrix is ever built.
        if chunk.rows.len() >= 32 {
            table
                .create_index(
                    &["vector"],
                    Index::IvfHnswFlat(
                        IvfHnswFlatIndexBuilder::default()
                            .num_partitions(1)
                            .sample_rate(32)
                            .max_iterations(5)
                            .num_edges(16)
                            .ef_construction(64),
                    ),
                )
                .execute()
                .await
                .map_err(error)?;
        }
        Ok(())
    }
    /// Remove only manifest-owned retired generations, preserving active and latest.
    pub async fn prune(&mut self) -> Result<u64> {
        let _guard = self.analysis_lock()?;
        let mut removed = 0;
        while let Some(count) = self.prune_one().await? {
            removed += count;
        }
        Ok(removed)
    }
    /// Caller holds the analysis lock. Journal entries are removed only after
    /// their Lance table is gone, so an interrupted cleanup safely replays.
    async fn prune_one(&mut self) -> Result<Option<u64>> {
        let retired: Option<(i64, String)> = self.db.query_row("SELECT g.id,g.budget FROM generations g JOIN models m ON m.id=g.model WHERE g.id!=m.latest AND (m.active IS NULL OR g.id!=m.active) ORDER BY g.id LIMIT 1", [], |r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(error)?;
        let Some((generation, budget)) = retired else {
            return Ok(None);
        };
        let shard: Option<i64> = self
            .db
            .query_row(
                "SELECT id FROM shards WHERE generation=?1 ORDER BY id LIMIT 1",
                [generation],
                |r| r.get(0),
            )
            .optional()
            .map_err(error)?;
        if let Some(shard) = shard {
            let budget: AnalysisBudget = serde_json::from_str(&budget).map_err(error)?;
            let connection = self.connection(&budget).await?;
            match connection.drop_table(&name(generation, shard), &[]).await {
                Ok(()) | Err(lancedb::Error::TableNotFound { .. }) => {}
                Err(e) => return Err(error(e)),
            }
            self.db
                .execute("DELETE FROM shards WHERE id=?1", [shard])
                .map_err(error)?;
            return Ok(Some(1));
        }
        let tx = self
            .db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(error)?;
        tx.execute("DELETE FROM jobs WHERE generation=?1", [generation])
            .map_err(error)?;
        tx.execute("DELETE FROM generations WHERE id=?1", [generation])
            .map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(Some(0))
    }
    pub async fn search(
        &self,
        key: &str,
        vector: &[f32],
        limit: u32,
    ) -> Result<Vec<SimilarityHit>> {
        if !(1..=100).contains(&limit) {
            return Err("Search limit must be 1..100".into());
        }
        let model = self.model(key)?;
        let vector = normalized(vector, model.dimensions)?;
        let _guard = self.analysis_lock()?;
        let (generation,budget): (i64,String) = self.db.query_row("SELECT g.id,g.budget FROM models m JOIN generations g ON g.id=m.active WHERE m.id=?1",[key],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(error)?.ok_or("Model index is not ready")?;
        let budget = serde_json::from_str(&budget).map_err(error)?;
        let connection = self.connection(&budget).await?;
        let mut after = 0;
        let mut best: Vec<(i64, f32)> = Vec::new();
        loop {
            let shard: Option<i64> = self.db.query_row("SELECT id FROM shards WHERE generation=?1 AND state='ready' AND id>?2 ORDER BY id LIMIT 1",params![generation,after],|r|r.get(0)).optional().map_err(error)?;
            let Some(shard) = shard else {
                break;
            };
            after = shard;
            let ids = {
                let mut statement = self.db.prepare("SELECT j.id FROM jobs j JOIN assets a ON a.id=j.asset AND a.revision=j.revision WHERE j.shard=?1 AND j.state='done'").map_err(error)?;
                statement
                    .query_map([shard], |r| r.get::<_, i64>(0))
                    .map_err(error)?
                    .map(|r| r.map(|id| id.to_string()).map_err(error))
                    .collect::<Result<Vec<_>>>()?
            };
            if ids.is_empty() {
                continue;
            }
            let table = connection
                .open_table(name(generation, shard))
                .execute()
                .await
                .map_err(error)?;
            let mut batches = table
                .query()
                .nearest_to(vector.clone())
                .map_err(error)?
                .nprobes(1)
                .ef(usize::try_from(limit.max(64)).map_err(error)?)
                .limit(usize::try_from(limit).map_err(error)?)
                .only_if(format!("id IN ({})", ids.join(",")))
                .execute()
                .await
                .map_err(error)?;
            while let Some(batch) = batches.try_next().await.map_err(error)? {
                let ids = batch
                    .column_by_name("id")
                    .and_then(|v| v.as_any().downcast_ref::<Int64Array>())
                    .ok_or("Invalid Lance identifier column")?;
                let distances = batch
                    .column_by_name("_distance")
                    .and_then(|v| v.as_any().downcast_ref::<Float32Array>())
                    .ok_or("Invalid Lance distance column")?;
                best.extend((0..batch.num_rows()).map(|i| (ids.value(i), distances.value(i))));
                best.sort_by(|a, b| a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
                best.truncate(usize::try_from(limit).map_err(error)?);
            }
        }
        let mut hits = Vec::new();
        for (id, distance) in best {
            let asset: Option<String> = self.db.query_row("SELECT a.json FROM assets a JOIN jobs j ON j.asset=a.id AND j.revision=a.revision WHERE j.id=?1 AND j.state='done'",[id],|r|r.get(0)).optional().map_err(error)?;
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
