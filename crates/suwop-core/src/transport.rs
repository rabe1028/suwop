//! Provider-neutral transport and ordinary-access types. They used to live in
//! `immich`, which still re-exports them, so existing paths and the generated
//! Swift wire names are unchanged.
use crate::domain::AssetKey;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Whether a remote request only observes state. Each adapter classifies its
/// own routes: an HTTP method alone is not evidence, because some read-only
/// searches are POST requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Read,
    Mutation,
}

#[derive(Debug, Clone)]
pub struct OrdinarySessionGuard {
    pub generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub expected: u64,
}
impl OrdinarySessionGuard {
    #[must_use]
    pub fn current(&self) -> bool {
        self.generation.load(std::sync::atomic::Ordering::SeqCst) == self.expected
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UploadPart {
    pub field: String,
    pub path: String,
    pub filename: String,
}
#[derive(Debug, Clone, Copy, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum OrdinaryContentPurpose {
    Read,
    DestinationReadback,
    VisibilityReconciliation,
    SelectedPresentationMetadata,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinaryContentAuthorization {
    pub source_keys: Vec<AssetKey>,
    pub expected_revision: String,
    pub purpose: OrdinaryContentPurpose,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HttpRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub immich_archive_authorization: Option<crate::immich_archive::ImmichArchiveAuthorization>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub immich_visibility_authorization:
        Option<crate::immich_visibility::ImmichVisibilityAuthorization>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ordinary_content_authorization: Option<OrdinaryContentAuthorization>,
    pub url: String,
    pub method: String,
    pub headers: BTreeMap<String, String>,
    pub body: Option<Value>,
    pub fields: BTreeMap<String, String>,
    pub files: Vec<UploadPart>,
    pub download_path: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HttpResponse {
    pub status: u16,
    pub body: Value,
    pub path: Option<String>,
}
