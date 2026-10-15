use crate::{Result, Store, error};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use suwop_core::{
    analysis::{AnalysisBudget, AnalysisModel, EmbeddingInput},
    app::SavedLibrary,
};
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub root: String,
    pub command: Command,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Command {
    CompatibleInferenceStatuses,
    SelectedInference,
    SelectInference {
        dimensions: u32,
    },
    InferenceSpec {
        dimensions: u32,
    },
    ConfigureInference {
        dimensions: u32,
        budget: u64,
    },
    SetInferenceBudget {
        model_key: String,
        budget: u64,
    },
    InferenceStatus {
        model_key: String,
    },
    PauseInference {
        model_key: String,
        reason: Option<String>,
    },
    AdmitInference {
        model_key: String,
        resident: u64,
        available: u64,
        loaded: bool,
        pressure: bool,
        query: bool,
    },
    ProjectEmbedding {
        vector: Vec<f32>,
        dimensions: u32,
    },
    QueryText {
        text: String,
    },
    ValidateEmbeddingInput {
        expected: Box<suwop_core::domain::StoredAsset>,
        fresh: Box<suwop_core::domain::StoredAsset>,
        connection: Option<suwop_core::app::ConnectionSettings>,
    },
    ModelPath,
    InstallModel {
        source: String,
    },
    Read,
    Persist {
        state: Box<SavedLibrary>,
    },
    Register {
        model: AnalysisModel,
        budget: AnalysisBudget,
    },
    Rebuild {
        model_key: String,
        budget: AnalysisBudget,
    },
    Pause {
        model_key: String,
    },
    Resume {
        model_key: String,
    },
    Pending {
        model_key: String,
        limit: u32,
    },
    Submit {
        model_key: String,
        embeddings: Vec<EmbeddingInput>,
    },
    Skip {
        model_key: String,
        job_id: String,
        reason: String,
    },
    Status,
    Prune,
    Search {
        model_key: String,
        vector: Vec<f32>,
        limit: u32,
    },
}
pub fn dispatch(request: Request) -> Result<Value> {
    let mut store = Store::open(Path::new(&request.root))?;
    let value = execute(&mut store, request.command)?;
    // A worker-start failure must not misreport a durable metadata commit as failed.
    // Subsequent calls/startup retry. Job state remains durable in SQLite.
    let _worker = crate::wake(&store.root);
    Ok(value)
}
fn execute(store: &mut Store, command: Command) -> Result<Value> {
    let value = match command {
        Command::SelectedInference => json(store.selected_inference()?)?,
        Command::SelectInference { dimensions } => json(store.select_inference(dimensions)?)?,
        Command::CompatibleInferenceStatuses => json(store.compatible_inference_statuses()?)?,
        Command::InferenceSpec { dimensions } => {
            json(suwop_core::inference::specification(dimensions)?)?
        }
        Command::ConfigureInference { dimensions, budget } => {
            json(store.configure_inference(dimensions, budget)?)?
        }
        Command::SetInferenceBudget { model_key, budget } => {
            store.set_inference_budget(&model_key, budget)?;
            Value::Null
        }
        Command::InferenceStatus { model_key } => json(store.inference_status(&model_key)?)?,
        Command::PauseInference { model_key, reason } => {
            store.pause_inference(&model_key, reason.as_deref())?;
            Value::Null
        }
        Command::AdmitInference {
            model_key,
            resident,
            available,
            loaded,
            pressure,
            query,
        } => Value::Bool(
            store.admit_inference(&model_key, resident, available, loaded, pressure, query)?,
        ),
        Command::ProjectEmbedding { vector, dimensions } => {
            json(suwop_core::inference::project(&vector, dimensions)?)?
        }
        Command::QueryText { text } => Value::String(suwop_core::inference::query(&text)?),
        Command::ValidateEmbeddingInput {
            expected,
            fresh,
            connection,
        } => {
            store.validate_embedding_input(&expected, &fresh, connection.as_ref())?;
            Value::Null
        }
        Command::ModelPath => Value::String(store.model_path()?),
        Command::InstallModel { source } => Value::String(store.install_model(Path::new(&source))?),
        Command::Read => json(store.read()?)?,
        Command::Persist { state } => {
            store.persist(&state)?;
            Value::Null
        }
        Command::Register { model, budget } => Value::String(store.register(&model, &budget)?),
        Command::Rebuild { model_key, budget } => {
            store.rebuild(&model_key, &budget)?;
            Value::Null
        }
        Command::Pause { model_key } => {
            store.pause(&model_key, true)?;
            Value::Null
        }
        Command::Resume { model_key } => {
            store.pause(&model_key, false)?;
            Value::Null
        }
        Command::Pending { model_key, limit } => json(store.pending(&model_key, limit)?)?,
        Command::Submit {
            model_key,
            embeddings,
        } => {
            store.submit(&model_key, &embeddings)?;
            Value::Null
        }
        Command::Prune => json(crate::worker::runtime()?.block_on(store.prune())?)?,
        Command::Skip {
            model_key,
            job_id,
            reason,
        } => {
            store.skip(&model_key, &job_id, &reason)?;
            Value::Null
        }
        Command::Status => json(store.status()?)?,
        Command::Search {
            model_key,
            vector,
            limit,
        } => json(crate::worker::runtime()?.block_on(store.search(&model_key, &vector, limit))?)?,
    };
    Ok(value)
}

fn json(value: impl Serialize) -> Result<Value> {
    serde_json::to_value(value).map_err(error)
}
