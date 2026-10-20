//! Ephemeral selected-original still presentation; never operation authority.
use crate::{domain::AssetKey, immich::HttpRequest};
use serde::{Deserialize, Serialize};
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum OrdinarySelectedImageKind {
    Thumbnail,
    Preview,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum OrdinarySelectedVisibility {
    Timeline,
    Archive,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinarySelectedPresentation {
    pub key: AssetKey,
    #[serde(rename = "proofID")]
    pub proof_id: String,
    pub generation: u64,
    pub current_visibility: OrdinarySelectedVisibility,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinarySelectedImageAccess {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub key: AssetKey,
    pub kind: OrdinarySelectedImageKind,
    #[serde(rename = "proofID")]
    pub proof_id: String,
    pub generation: u64,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinarySelectedImageTicket {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub key: AssetKey,
    pub kind: OrdinarySelectedImageKind,
    #[serde(rename = "proofID")]
    pub proof_id: String,
    pub generation: u64,
    pub expected_revision: String,
    pub request: HttpRequest,
}
impl std::fmt::Debug for OrdinarySelectedImageTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OrdinarySelectedImageTicket([redacted])")
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinarySelectedImageResult {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OrdinarySelectedImageRequest {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub key: AssetKey,
    pub kind: OrdinarySelectedImageKind,
    #[serde(rename = "proofID")]
    pub proof_id: String,
    pub generation: u64,
}
mod images;
mod proof;
pub(crate) use proof::VerifiedPresentation;
#[derive(Debug, Default)]
pub struct OrdinarySelectedModel {
    pub(crate) active_refresh: Option<u64>,
    pub(crate) refresh_sequence: u64,
    proofs: std::collections::BTreeMap<AssetKey, VerifiedPresentation>,
    pending: std::collections::BTreeMap<
        (String, AssetKey, OrdinarySelectedImageKind),
        OrdinarySelectedImageTicket,
    >,
    images: Vec<OrdinarySelectedImageAccess>,
    used_requests: std::collections::BTreeSet<String>,
}
pub(crate) fn proof_id(proof: &VerifiedPresentation) -> String {
    proof.proof_id.clone()
}
pub(crate) fn presentations(model: &crate::app::Model) -> Vec<OrdinarySelectedPresentation> {
    model
        .ordinary_selected
        .proofs
        .values()
        .filter(|p| p.current(model))
        .map(|p| OrdinarySelectedPresentation {
            key: p.asset.key.clone(),
            proof_id: proof_id(p),
            generation: p.generation,
            current_visibility: if p.observation.visibility
                == crate::immich_visibility::ImmichVisibility::Timeline
            {
                OrdinarySelectedVisibility::Timeline
            } else {
                OrdinarySelectedVisibility::Archive
            },
        })
        .collect()
}
pub(crate) fn images(model: &crate::app::Model) -> Vec<OrdinarySelectedImageAccess> {
    model
        .ordinary_selected
        .images
        .iter()
        .filter(|image| {
            model
                .ordinary_selected
                .proofs
                .get(&image.key)
                .is_some_and(|p| p.current(model) && proof_id(p) == image.proof_id)
        })
        .cloned()
        .collect()
}
pub(crate) fn public_library(model: &crate::app::Model) -> crate::privacy::PublishedLibrary {
    let ordinary = crate::protection::ordinary_state(model);
    let access = crate::privacy::ContentAccess::new(&ordinary);
    let allowed = model
        .ordinary_selected
        .proofs
        .values()
        .filter(|p| p.current(model))
        .map(|p| p.asset.key.clone())
        .collect::<std::collections::BTreeSet<_>>();
    let mut public = crate::privacy::PublishedLibrary::from_canonical(&ordinary);
    for proof in model
        .ordinary_selected
        .proofs
        .values()
        .filter(|p| p.current(model) && access.can_present(&p.asset.key, &allowed))
    {
        if let Some(snapshot) = public.snapshots.iter_mut().find(|s| {
            s.provider == crate::domain::Provider::Immich
                && s.scope == proof.scope
                && s.access == crate::domain::ScanAccess::Full
        }) {
            snapshot.assets.retain(|a| a.key != proof.asset.key);
            snapshot.assets.push(proof.asset.clone());
        }
    }
    public
}
pub(crate) fn install(model: &mut crate::app::Model, proofs: Vec<VerifiedPresentation>) {
    for mut proof in proofs {
        if model
            .ordinary_generation
            .load(std::sync::atomic::Ordering::SeqCst)
            != proof.generation.wrapping_add(1)
        {
            continue;
        }
        proof.generation = proof.generation.wrapping_add(1);
        if proof.current(model) {
            model
                .ordinary_selected
                .proofs
                .insert(proof.asset.key.clone(), proof);
        }
    }
}

pub(crate) fn pending(model: &crate::app::Model) -> Vec<OrdinarySelectedImageRequest> {
    model
        .ordinary_selected
        .pending
        .values()
        .filter(|t| {
            model
                .ordinary_selected
                .proofs
                .get(&t.key)
                .is_some_and(|p| p.current(model) && proof_id(p) == t.proof_id)
        })
        .map(|t| OrdinarySelectedImageRequest {
            request_id: t.request_id.clone(),
            scene_id: t.scene_id.clone(),
            key: t.key.clone(),
            kind: t.kind,
            proof_id: t.proof_id.clone(),
            generation: t.generation,
        })
        .collect()
}

pub(crate) use images::{reconcile, reconcile_current, update};

pub(crate) fn security_differs(
    before: &crate::app::SavedLibrary,
    after: &crate::app::SavedLibrary,
) -> bool {
    serde_json::to_value(&before.protected_entries).ok()
        != serde_json::to_value(&after.protected_entries).ok()
        || serde_json::to_value(&before.immich_visibility_operations).ok()
            != serde_json::to_value(&after.immich_visibility_operations).ok()
}
pub(crate) fn security_progress_changed(
    event: &crate::app::Event,
    model: &crate::app::Model,
) -> bool {
    matches!(event,crate::app::Event::Progress{state,..} if security_differs(&model.state,state))
}
#[derive(Clone, Debug)]
pub struct RefreshOrigin {
    session: Option<(String, String, String)>,
    connection: Option<serde_json::Value>,
    apple_scope: String,
}
impl RefreshOrigin {
    pub(crate) fn capture(model: &crate::app::Model) -> Self {
        Self {
            session: Self::identity(model.session.as_ref()),
            connection: model
                .state
                .connection
                .as_ref()
                .and_then(|c| serde_json::to_value(c).ok()),
            apple_scope: model.state.apple_scope.clone(),
        }
    }
    fn identity(session: Option<&crate::immich::Session>) -> Option<(String, String, String)> {
        session.map(|s| (s.endpoint.clone(), s.scope.clone(), s.user_id.clone()))
    }
    fn accepts(&self, model: &crate::app::Model, result: &crate::workflow::Outcome) -> bool {
        // A refresh may publish its authenticated session with a Limited subset
        // before completion. The refresh id/generation still fence stale work;
        // initial connections must additionally match the configured endpoint below.
        let current = Self::identity(model.session.as_ref());
        let published_initial =
            self.session.is_none() && current == Self::identity(result.session.as_ref());
        if (self.session != current && !published_initial)
            || self.connection
                != model
                    .state
                    .connection
                    .as_ref()
                    .and_then(|c| serde_json::to_value(c).ok())
            || self.apple_scope != model.state.apple_scope
        {
            return false;
        }
        if self.session.is_some() {
            return self.session == Self::identity(result.session.as_ref());
        }
        let Some(session) = result.session.as_ref() else {
            return true;
        };
        model.state.connection.as_ref().is_some_and(|c| {
            crate::immich::endpoint(&c.address, c.allow_http).is_ok_and(|endpoint| {
                session.endpoint == endpoint
                    && !session.user_id.is_empty()
                    && session.scope == format!("{}#{}", endpoint, session.user_id)
            })
        })
    }
}
pub(crate) fn finish_refresh(
    model: &mut crate::app::Model,
    mut result: Box<crate::workflow::Outcome>,
    expected_generation: u64,
    refresh_id: u64,
    origin: &RefreshOrigin,
) -> crux_core::Command<crate::app::Effect, crate::app::Event> {
    let owns = model.ordinary_selected.active_refresh == Some(refresh_id);
    let admitted = owns
        && model
            .ordinary_generation
            .load(std::sync::atomic::Ordering::SeqCst)
            == expected_generation
        && origin.accepts(model, &result)
        && !model.protection.membership_uncertain
        && !model.immich_visibility.persistence_uncertain;
    if !admitted {
        if result.refresh_persist_issued && security_differs(&model.state, &result.state) {
            model.immich_visibility.persistence_uncertain = true;
            model
                .protection
                .denied
                .extend(model.state.protected_entries.iter().map(|e| e.key.clone()));
        }
        if owns {
            model.ordinary_selected.active_refresh = None;
            model.busy = false;
            model.error = Some(
                "更新中に写真へのアクセスが変わりました。保存状態を確認してから更新してください。"
                    .into(),
            );
        }
        return reconcile_current(model);
    }
    model.ordinary_selected.active_refresh = None;
    if result.error.is_some() {
        result.ordinary_selected.clear();
    }
    let proofs = std::mem::take(&mut result.ordinary_selected)
        .into_iter()
        .filter(|p| p.same_records(&model.state))
        .collect();
    let command = crux_core::App::update(
        &crate::app::Suwop,
        crate::app::Event::Finished {
            state: result.state,
            session: result.session,
            status: result.status,
            error: result.error,
            preview_to_select: result.preview_to_select,
        },
        model,
    );
    install(model, proofs);
    command
}

pub(crate) fn generation(model: &crate::app::Model) -> u64 {
    model
        .ordinary_generation
        .load(std::sync::atomic::Ordering::SeqCst)
}
