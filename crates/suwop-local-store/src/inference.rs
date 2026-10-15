use crate::{Result, Store, error};
use rusqlite::{OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::Path};
use suwop_core::{
    analysis::{AnalysisBudget, AnalysisStatus},
    app::ConnectionSettings,
    domain::{Provider, StoredAsset},
    inference::{self, InferenceStatus},
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
        let key = self.register(
            &inference::specification(dimensions)?.model,
            &AnalysisBudget::default(),
        )?;
        // Explicit configuration resumes work; simply opening the app does not unpause it.
        self.db.execute("INSERT INTO inference_runs VALUES(?1,'running',?2,NULL) ON CONFLICT(model) DO UPDATE SET budget=excluded.budget,state='running',error=NULL",params![key,i64::try_from(budget).map_err(error)?]).map_err(error)?;
        self.pause(&key, false)?;
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
        self.db
            .query_row(
                "SELECT state,budget,error FROM inference_runs WHERE model=?1",
                [key],
                |row| {
                    Ok(InferenceStatus {
                        model_key: key.into(),
                        state: row.get(0)?,
                        budget_bytes: u64::from(row.get::<_, u32>(1)?),
                        error: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(error)
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
    pub fn model_path(&self) -> Result<String> {
        let path = self.root.join("models").join(inference::MODEL_FILE);
        verify_model(&path)?;
        Ok(path.to_string_lossy().into_owned())
    }
    pub fn install_model(&self, source: &Path) -> Result<String> {
        verify_model(source)?;
        let directory = self.root.join("models");
        std::fs::create_dir_all(&directory).map_err(error)?;
        // Share the native runtime's lease: never replace weights/caches under a live engine.
        let lease = File::options()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(directory.join("inference.lock"))
            .map_err(error)?;
        lease.try_lock().map_err(error)?;
        if let Ok(path) = self.model_path() {
            return Ok(path);
        }
        // Temp file and atomic rename prevent a partial download being loaded.
        let stage = directory.join("embeddinggemma-2.installing");
        std::fs::copy(source, &stage).map_err(error)?;
        verify_model(&stage)?;
        File::open(&stage)
            .and_then(|file| file.sync_all())
            .map_err(error)?;
        std::fs::rename(stage, directory.join(inference::MODEL_FILE)).map_err(error)?;
        remove_replaced_model_caches(&directory)?;
        File::open(&directory)
            .and_then(|file| file.sync_all())
            .map_err(error)?;
        self.model_path()
    }
}
fn verify_model(path: &Path) -> Result<()> {
    let mut file = File::open(path).map_err(error)?;
    if file.metadata().map_err(error)?.len() != inference::MODEL_BYTES {
        return Err("Model download is incomplete or incompatible".into());
    }
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(error)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    if suwop_core::domain::hex(&hash.finalize()) != inference::MODEL_SHA256 {
        return Err("Model checksum mismatch".into());
    }
    Ok(())
}

/// Only this provider's generated caches; never arbitrary files or linked directories.
fn remove_replaced_model_caches(directory: &Path) -> Result<()> {
    let prefix = format!("{}_", inference::MODEL_FILE);
    for entry in std::fs::read_dir(directory).map_err(error)? {
        let entry = entry.map_err(error)?;
        let filename = entry.file_name();
        let Some(name) = filename.to_str() else {
            continue;
        };
        if name.starts_with(&prefix)
            && [
                ".text_encoder.xnnpack_cache",
                ".vision_adapter.xnnpack_cache",
                ".vision_encoder.xnnpack_cache",
            ]
            .iter()
            .any(|suffix| name.ends_with(suffix))
            && entry.file_type().map_err(error)?.is_file()
        {
            std::fs::remove_file(entry.path()).map_err(error)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn model_cache_cleanup_is_provider_owned_and_keeps_other_data() -> Result<()> {
        let root = tempfile::tempdir().map_err(error)?;
        let owned = root.path().join(format!(
            "{}_1_387710976.text_encoder.xnnpack_cache",
            inference::MODEL_FILE
        ));
        let unrelated = root.path().join("other-model.text_encoder.xnnpack_cache");
        let weights = root.path().join(inference::MODEL_FILE);
        for path in [&owned, &unrelated, &weights] {
            std::fs::write(path, b"fixture").map_err(error)?;
        }
        remove_replaced_model_caches(root.path())?;
        assert!(!owned.exists());
        assert!(unrelated.exists());
        assert!(weights.exists());
        Ok(())
    }
}
