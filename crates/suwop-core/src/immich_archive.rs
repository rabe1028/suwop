//! Ordinary archive authority is distinct from PIN elevation and never authorizes locked assets.
use crate::{
    app::{Context, Event, Model, ShellOperation},
    domain::AssetKey,
    immich_visibility::{
        ImmichVisibility, ImmichVisibilityOperation, ImmichVisibilityOperationKind,
    },
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
const ERROR: &str = "写真の状態を確認できません。変更は再送せず状態を確認してください。";
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichArchiveDestination {
    Timeline,
    Archive,
}
impl From<ImmichArchiveDestination> for ImmichVisibility {
    fn from(value: ImmichArchiveDestination) -> Self {
        match value {
            ImmichArchiveDestination::Timeline => Self::Timeline,
            ImmichArchiveDestination::Archive => Self::Archive,
        }
    }
}
impl TryFrom<ImmichVisibility> for ImmichArchiveDestination {
    type Error = String;
    fn try_from(value: ImmichVisibility) -> Result<Self, String> {
        match value {
            ImmichVisibility::Timeline => Ok(Self::Timeline),
            ImmichVisibility::Archive => Ok(Self::Archive),
            ImmichVisibility::Locked => Err(ERROR.into()),
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichArchiveAuthorization {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub scope: String,
    pub key: AssetKey,
    pub to: ImmichArchiveDestination,
    pub url: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichArchivePrompt {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub from: ImmichArchiveDestination,
    pub to: ImmichArchiveDestination,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichArchiveActionHint {
    pub key: AssetKey,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<ImmichArchiveDestination>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<crate::immich_visibility::ImmichVisibilityUnsupportedReason>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichArchiveSummary {
    #[serde(rename = "recordID")]
    pub record_id: String,
    pub from: ImmichArchiveDestination,
    pub to: ImmichArchiveDestination,
    pub outcome: crate::apple_visibility::VisibilityOutcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observation: Option<ImmichArchiveDestination>,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichArchiveView {
    #[serde(rename = "sceneID", skip_serializing_if = "Option::is_none")]
    pub scene_id: Option<String>,
    pub generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_operation: Option<ImmichArchiveAuthorization>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history: Option<Vec<ImmichArchiveSummary>>,
    pub persistence_uncertain: bool,
    pub can_recover: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}
#[derive(Debug, Default)]
pub struct ImmichArchiveModel {
    pub(crate) recovery_proof: Option<Box<RecoveryProof>>,
    pub scene_id: Option<String>,
    pub generation: Arc<AtomicU64>,
    pub active_operation: Option<ImmichArchiveAuthorization>,
    pub uncertain: bool,
    pub working: bool,
    pub message: Option<String>,
}
fn allowed(model: &Model, key: &AssetKey) -> bool {
    model.session.as_ref().is_some_and(|s| s.scope == key.scope)
        && key.provider == crate::domain::Provider::Immich
        && !model.state.protected_entries.iter().any(|e| e.key == *key)
        && !model.protection.denied.contains(key)
}
#[must_use]
pub fn view(model: &Model) -> ImmichArchiveView {
    let active = model.immich_archive.scene_id.is_some() && model.session.is_some();
    ImmichArchiveView {
        scene_id: if active {
            model.immich_archive.scene_id.clone()
        } else {
            None
        },
        generation: model.immich_archive.generation.load(Ordering::SeqCst),
        active_operation: if active {
            model.immich_archive.active_operation.clone()
        } else {
            None
        },
        history: active.then(|| {
            model
                .state
                .immich_visibility_operations
                .iter()
                .filter(|o| {
                    o.kind == ImmichVisibilityOperationKind::OrdinaryArchive
                        && allowed(model, &o.key)
                })
                .filter_map(|o| {
                    Some(ImmichArchiveSummary {
                        record_id: o.id.clone(),
                        from: o.from.try_into().ok()?,
                        to: o.to.try_into().ok()?,
                        outcome: o.outcome,
                        observation: o.observation.and_then(|v| v.try_into().ok()),
                    })
                })
                .collect()
        }),
        persistence_uncertain: model.immich_archive.uncertain,
        can_recover: active && model.immich_archive.uncertain && !model.busy,
        status: active
            .then(|| model.immich_archive.message.clone())
            .flatten(),
    }
}
// Shared durable prerequisites for the advisory destination and mutation entry.
// Busy/scene ownership and operation IDs remain request-specific.
fn durable_state_available(model: &Model) -> bool {
    model.ready
        && model.state.schema_version == 7
        && !model.immich_visibility.persistence_uncertain
        && !model.protection.membership_uncertain
}
#[must_use]
pub fn actions(model: &Model) -> Vec<ImmichArchiveActionHint> {
    let state =
        crate::privacy::PublishedLibrary::from_canonical(&crate::protection::ordinary_state(model));
    state
        .snapshots
        .iter()
        .filter(|s| s.access != crate::domain::ScanAccess::Unavailable)
        .flat_map(|s| &s.assets)
        .filter(|a| allowed(model, &a.key))
        .map(|a| {
            let mut reason = crate::immich_visibility::hint(a, false).reason;
            let to = match a.immich_visibility {
                Some(ImmichVisibility::Timeline) => Some(ImmichArchiveDestination::Archive),
                Some(ImmichVisibility::Archive) => Some(ImmichArchiveDestination::Timeline),
                _ => None,
            };
            if !durable_state_available(model) {
                reason =
                    Some(crate::immich_visibility::ImmichVisibilityUnsupportedReason::Unavailable);
            }
            if to.is_none() && reason.is_none() {
                reason = Some(crate::immich_visibility::ImmichVisibilityUnsupportedReason::Unknown);
            }
            ImmichArchiveActionHint {
                key: a.key.clone(),
                to: if reason.is_none() { to } else { None },
                reason,
            }
        })
        .collect()
}
#[derive(Debug, Clone)]
pub(crate) struct OrdinaryArchiveAuthority {
    session: crate::immich::Session,
    permit: ImmichArchiveAuthorization,
    epoch: Arc<AtomicU64>,
    ordinary: Arc<AtomicU64>,
    expected_ordinary: u64,
    binding: Option<(String, String, ImmichVisibility, ImmichVisibility)>,
}
impl OrdinaryArchiveAuthority {
    fn valid(&self) -> Result<(), String> {
        if self.epoch.load(Ordering::SeqCst) != self.permit.generation
            || self.ordinary.load(Ordering::SeqCst) != self.expected_ordinary
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
    async fn json(&self, ctx: &Context, path: &str) -> Result<serde_json::Value, String> {
        self.valid()?;
        if path != format!("assets/{}", self.permit.key.asset_id) {
            return Err(ERROR.into());
        }
        let mut request = self.session.request(path, "GET", None);
        // Exact metadata for an already-authorized operation remains available through its own fence.
        request.ordinary_content_authorization = None;
        let result: crate::immich::HttpResponse =
            crate::app::io(ctx, ShellOperation::Http(request)).await?;
        self.valid()?;
        crate::immich::check_status(result.status)?;
        if result.body["visibility"] == "locked" {
            return Err(ERROR.into());
        }
        Ok(result.body)
    }
    async fn mutate(
        &self,
        ctx: &Context,
        operation: &ImmichVisibilityOperation,
    ) -> Result<serde_json::Value, String> {
        self.valid()?;
        let Some((witness, _, from, to)) = &self.binding else {
            return Err(ERROR.into());
        };
        if operation.id != self.permit.operation_id
            || operation.key != self.permit.key
            || operation.scope != self.session.scope
            || operation.kind != ImmichVisibilityOperationKind::OrdinaryArchive
            || operation.witness_digest != *witness
            || operation.from != *from
            || operation.to != *to
        {
            return Err(ERROR.into());
        }
        crate::immich_visibility::validate_operation(operation)?;
        let mut request = self.session.request(
            "assets",
            "PUT",
            Some(serde_json::json!({"ids":[operation.key.asset_id],"visibility":operation.to})),
        );
        request.immich_archive_authorization = Some(self.permit.clone());
        let response: crate::immich::HttpResponse =
            crate::app::io(ctx, ShellOperation::Http(request)).await?;
        self.valid()?;
        crate::immich::check_status(response.status)?;
        Ok(response.body)
    }
}
#[derive(Debug, Clone)]
pub(crate) enum VisibilityAuthority {
    Locked(crate::immich_locked::VisibilitySession),
    Ordinary(OrdinaryArchiveAuthority),
}
impl From<crate::immich_locked::VisibilitySession> for VisibilityAuthority {
    fn from(c: crate::immich_locked::VisibilitySession) -> Self {
        Self::Locked(c)
    }
}
impl VisibilityAuthority {
    // Ordinary API-key authority may remove stale display state, but can never
    // mint a PIN-session locked entry, even from an authenticated readback.
    pub(crate) fn projection(
        self,
        operation_id: String,
        facts: crate::immich_visibility::VisibilityFacts,
    ) -> Option<Box<crate::immich_visibility::VerifiedVisibilityProjection>> {
        match self {
            Self::Locked(capability) => Some(Box::new(
                crate::immich_visibility::VerifiedVisibilityProjection {
                    capability,
                    operation_id,
                    facts,
                },
            )),
            Self::Ordinary(_) => None,
        }
    }

    pub(crate) fn kind(&self) -> ImmichVisibilityOperationKind {
        match self {
            Self::Locked(_) => ImmichVisibilityOperationKind::LockedTransition,
            Self::Ordinary(_) => ImmichVisibilityOperationKind::OrdinaryArchive,
        }
    }
    pub(crate) fn scope(&self) -> &str {
        match self {
            Self::Locked(c) => c.scope(),
            Self::Ordinary(c) => &c.session.scope,
        }
    }
    pub(crate) fn owner(&self) -> &str {
        match self {
            Self::Locked(c) => c.owner(),
            Self::Ordinary(c) => &c.session.user_id,
        }
    }
    pub(crate) fn valid(&self) -> Result<(), String> {
        match self {
            Self::Locked(c) => c.valid(),
            Self::Ordinary(c) => c.valid(),
        }
    }
    pub(crate) fn bind(
        mut self,
        operation: &ImmichVisibilityOperation,
        revision: &str,
    ) -> Result<Self, String> {
        if self.kind() != operation.kind {
            return Err(ERROR.into());
        }
        if let Self::Ordinary(c) = &mut self {
            if operation.key != c.permit.key
                || operation.id != c.permit.operation_id
                || ImmichVisibility::from(c.permit.to) != operation.to
            {
                return Err(ERROR.into());
            }
            c.binding = Some((
                operation.witness_digest.clone(),
                revision.into(),
                operation.from,
                operation.to,
            ));
        }
        Ok(self)
    }
    pub(crate) fn advance_own_fence(&mut self, previous: u64) -> Result<(), String> {
        if let Self::Ordinary(c) = self {
            if c.expected_ordinary != previous
                || c.epoch.load(Ordering::SeqCst) != c.permit.generation
            {
                return Err(ERROR.into());
            }
            c.expected_ordinary = previous + 1;
        }
        Ok(())
    }
    pub(crate) async fn status(&self, ctx: &Context) -> Result<(), String> {
        match self {
            Self::Locked(c) => c.status(ctx).await,
            Self::Ordinary(c) => c.valid(),
        }
    }
    pub(crate) async fn json(
        &self,
        ctx: &Context,
        path: &str,
        method: &str,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, String> {
        match self {
            Self::Locked(c) => c.json(ctx, path, method, body).await,
            Self::Ordinary(c) => {
                if method != "GET" || body.is_some() {
                    return Err(ERROR.into());
                }
                c.json(ctx, path).await
            }
        }
    }
    pub(crate) async fn mutate_visibility(
        &self,
        ctx: &Context,
        operation: &ImmichVisibilityOperation,
    ) -> Result<serde_json::Value, String> {
        match self {
            Self::Locked(c) => {
                if operation.kind != ImmichVisibilityOperationKind::LockedTransition {
                    return Err(ERROR.into());
                }
                c.mutate_visibility(ctx, operation).await
            }
            Self::Ordinary(c) => c.mutate(ctx, operation).await,
        }
    }
    pub(crate) async fn confirm(
        &self,
        ctx: &Context,
        operation: &ImmichVisibilityOperation,
    ) -> Result<bool, String> {
        self.valid()?;
        let effect = match self {
            Self::Locked(c) => ShellOperation::ConfirmImmichVisibility {
                prompt: crate::immich_visibility::ImmichVisibilityPrompt {
                    operation_id: operation.id.clone(),
                    grant_id: c.grant_id.clone(),
                    generation: c.expected,
                    scene_id: c.scene_id.clone(),
                    from: operation.from,
                    to: operation.to,
                    removes_all_album_membership: operation.to == ImmichVisibility::Locked,
                    no_automatic_album_restore: true,
                },
            },
            Self::Ordinary(c) => ShellOperation::ConfirmImmichArchive {
                prompt: ImmichArchivePrompt {
                    operation_id: operation.id.clone(),
                    scene_id: c.permit.scene_id.clone(),
                    generation: c.permit.generation,
                    from: operation.from.try_into()?,
                    to: operation.to.try_into()?,
                },
            },
        };
        let confirmed = crate::app::io(ctx, effect).await?;
        self.valid()?;
        Ok(confirmed)
    }
}
pub(crate) fn invalidate(model: &mut Model) {
    model
        .immich_archive
        .generation
        .fetch_add(1, Ordering::SeqCst);
    model.immich_archive.active_operation = None;
}
fn authority(
    model: &Model,
    scene: &str,
    key: AssetKey,
    to: ImmichArchiveDestination,
    id: String,
) -> Option<VisibilityAuthority> {
    if model.immich_archive.scene_id.as_deref() != Some(scene) || !allowed(model, &key) {
        return None;
    }
    let session = model.session.clone()?;
    let permit = ImmichArchiveAuthorization {
        operation_id: id,
        scene_id: scene.into(),
        generation: model.immich_archive.generation.load(Ordering::SeqCst),
        scope: session.scope.clone(),
        key,
        to,
        url: format!("{}/assets", session.endpoint),
    };
    Some(VisibilityAuthority::Ordinary(OrdinaryArchiveAuthority {
        session,
        permit,
        epoch: model.immich_archive.generation.clone(),
        ordinary: model.ordinary_generation.clone(),
        expected_ordinary: model.ordinary_generation.load(Ordering::SeqCst),
        binding: None,
    }))
}
pub(crate) fn update(
    event: Event,
    model: &mut Model,
) -> Option<Command<crate::app::Effect, Event>> {
    match event {
        Event::ImmichArchiveSceneChanged { scene_id, phase } => {
            if crate::apple_visibility::valid_operation_id(&scene_id).is_err() {
                return Some(Command::done());
            }
            if phase == crate::protection::ProtectionScenePhase::Active {
                if model.immich_archive.scene_id.as_deref() != Some(&scene_id) {
                    invalidate(model);
                    model.immich_archive.scene_id = Some(scene_id);
                }
            } else if model.immich_archive.scene_id.as_deref() == Some(&scene_id) {
                invalidate(model);
                model.immich_archive.scene_id = None;
            }
            Some(Command::done())
        }
        Event::CloseImmichArchive { scene_id } => {
            if model.immich_archive.scene_id.as_deref() == Some(&scene_id) {
                invalidate(model);
                model.immich_archive.scene_id = None;
            }
            Some(Command::done())
        }
        Event::PrepareImmichArchive {
            key,
            to,
            operation_id,
            scene_id,
        } => Some(begin(model, key, to, operation_id, &scene_id)),
        Event::InspectImmichArchive {
            record_id,
            scene_id,
        } => Some(inspect(model, &record_id, &scene_id)),
        Event::RecoverImmichArchiveState { scene_id } => Some(recover(model, &scene_id)),
        _ => None,
    }
}
fn begin(
    model: &mut Model,
    key: AssetKey,
    to: ImmichArchiveDestination,
    id: String,
    scene: &str,
) -> Command<crate::app::Effect, Event> {
    if model.busy || !durable_state_available(model) {
        return Command::done();
    }
    if crate::immich_visibility::fences(&model.state, &key)
        || crate::apple_visibility::valid_operation_id(&id).is_err()
        || model.state.immich_visibility_operations.iter().any(|o| {
            o.id == id
                || (o.key == key
                    && o.outcome == crate::apple_visibility::VisibilityOutcome::Unknown
                    && o.observation.is_none())
        })
        || !model.immich_visibility.used_ids.insert(id.clone())
    {
        return Command::done();
    }
    let Some(capability) = authority(model, scene, key.clone(), to, id.clone()) else {
        return Command::done();
    };
    if let VisibilityAuthority::Ordinary(c) = &capability {
        model.immich_archive.active_operation = Some(c.permit.clone());
    }
    model.immich_archive.working = true;
    model.busy = true;
    Command::new(move |ctx| async move {
        let result =
            crate::immich_visibility::workflow::prepare(&ctx, capability, key, to.into(), id).await;
        ctx.send_event(Event::ImmichVisibilityPrepared { result });
    })
}
fn inspect(model: &mut Model, id: &str, scene: &str) -> Command<crate::app::Effect, Event> {
    if model.busy
        || model.immich_visibility.persistence_uncertain
        || model.protection.membership_uncertain
    {
        return Command::done();
    }
    let Some(operation) = model
        .state
        .immich_visibility_operations
        .iter()
        .find(|o| {
            o.id == id
                && o.kind == ImmichVisibilityOperationKind::OrdinaryArchive
                && allowed(model, &o.key)
        })
        .cloned()
    else {
        return Command::done();
    };
    let Ok(to) = operation.to.try_into() else {
        return Command::done();
    };
    let Some(capability) = authority(
        model,
        scene,
        operation.key.clone(),
        to,
        operation.id.clone(),
    ) else {
        return Command::done();
    };
    model.immich_archive.working = true;
    model.busy = true;
    let before = model.state.clone();
    Command::new(move |ctx| async move {
        let result =
            crate::immich_visibility::workflow::inspect(&ctx, before, capability, operation).await;
        ctx.send_event(Event::ImmichVisibilityFinished { result });
    })
}
fn recover(model: &mut Model, scene: &str) -> Command<crate::app::Effect, Event> {
    if model.busy
        || !model.immich_archive.uncertain
        || model.immich_archive.scene_id.as_deref() != Some(scene)
        || model.session.is_none()
    {
        return Command::done();
    }
    let generation = model.immich_archive.generation.clone();
    let expected = generation.load(Ordering::SeqCst);
    let before = model.state.clone();
    let proof = model.immich_archive.recovery_proof.clone();
    let scope = model.session.as_ref().map(|s| s.scope.clone());
    model.immich_archive.working = true;
    model.busy = true;
    Command::new(move |ctx| async move {
        let raw: Result<serde_json::Value, _> =
            crate::app::io(&ctx, ShellOperation::ReadState).await;
        let recovered = raw.ok().and_then(|raw| {
            (generation.load(Ordering::SeqCst) == expected).then_some(())?;
            let proof = proof.as_ref()?;
            if scope.as_deref() != Some(&proof.scope) {
                return None;
            }
            proof.recover(&raw, &before)
        });
        let uncertain = recovered.is_none();
        let mut state = recovered.unwrap_or(before);
        if !uncertain {
            crate::immich_visibility::workflow::invalidate_remote(&mut state);
        }
        ctx.send_event(Event::ImmichVisibilityFinished {
            result: crate::immich_visibility::VisibilityCompletion {
                recovery_proof: None,
                projection: None,
                state,
                uncertain,
                status: if uncertain {
                    "保存状態を確認できません。変更せず再度確認してください。"
                } else {
                    "保存状態を確認しました。写真一覧を更新してください。"
                }
                .into(),
            },
        });
    })
}

#[derive(Debug, Clone)]
pub(crate) struct RecoveryProof {
    pub scope: String,
    pub before: crate::app::SavedLibrary,
    pub desired: crate::app::SavedLibrary,
}
impl RecoveryProof {
    fn recover(
        &self,
        raw: &serde_json::Value,
        current: &crate::app::SavedLibrary,
    ) -> Option<crate::app::SavedLibrary> {
        if serde_json::to_value(&current.connection).ok()
            != serde_json::to_value(&self.before.connection).ok()
            || current.apple_scope != self.before.apple_scope
        {
            return None;
        }
        [&self.before, &self.desired]
            .into_iter()
            .find(|candidate| {
                serde_json::to_value(candidate)
                    .ok()
                    .is_some_and(|expected| {
                        crate::immich_visibility::workflow::readback::matches(&expected, raw)
                    })
            })
            .cloned()
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    #[test]
    fn recovery_accepts_only_exact_transaction_candidates() -> Result<(), serde_json::Error> {
        let before = crate::app::SavedLibrary::default();
        let mut desired = before.clone();
        desired.schema_version = 7;
        assert_ne!(
            serde_json::to_value(&before)?,
            serde_json::to_value(&desired)?
        );
        let proof = RecoveryProof {
            scope: "current".into(),
            before: before.clone(),
            desired: desired.clone(),
        };
        for state in [&before, &desired] {
            assert!(
                proof
                    .recover(&serde_json::to_value(state)?, &before)
                    .is_some()
            );
        }
        let raw = serde_json::to_value(&desired)?;
        for field in [
            "protectedEntries",
            "receipts",
            "pendingAppleTrash",
            "pendingTrash",
            "pendingUploads",
            "uploadIntents",
            "pendingEditPastes",
            "appleVisibilityOperations",
            "immichVisibilityOperations",
        ] {
            let mut altered = raw.clone();
            altered[field] = serde_json::json!([{"unexpected":true}]);
            assert!(proof.recover(&altered, &before).is_none(), "{field}");
            let mut missing = raw.clone();
            if let Some(object) = missing.as_object_mut() {
                object.remove(field);
            }
            assert!(
                proof.recover(&missing, &before).is_none(),
                "missing {field}"
            );
        }
        assert!(proof.recover(&raw, &before).is_some());
        Ok(())
    }
}

#[cfg(test)]
mod authority_races {
    use super::*;
    #[test]
    fn own_fence_advance_cannot_absorb_an_unrelated_revocation() -> Result<(), String> {
        for unrelated in [false, true] {
            let ordinary = Arc::new(AtomicU64::new(0));
            let epoch = Arc::new(AtomicU64::new(0));
            let mut capability = VisibilityAuthority::Ordinary(OrdinaryArchiveAuthority {
                session: crate::immich::Session {
                    ordinary_content_guard: None,
                    ordinary_content_context: None,
                    endpoint: "https://fixture/api".into(),
                    key: "key".into(),
                    user_id: "owner".into(),
                    scope: "scope".into(),
                    version: crate::immich::Version {
                        major: 3,
                        minor: 2,
                        patch: 4,
                    },
                },
                permit: ImmichArchiveAuthorization {
                    operation_id: "operation".into(),
                    scene_id: "scene".into(),
                    generation: 0,
                    scope: "scope".into(),
                    key: AssetKey {
                        provider: crate::domain::Provider::Immich,
                        scope: "scope".into(),
                        asset_id: "asset".into(),
                    },
                    to: ImmichArchiveDestination::Archive,
                    url: "https://fixture/api/assets".into(),
                },
                epoch: epoch.clone(),
                ordinary: ordinary.clone(),
                expected_ordinary: 0,
                binding: None,
            });
            capability.valid()?;
            let facts = crate::immich_visibility::facts(
                &serde_json::json!({
                    "id":"33333333-3333-4333-8333-333333333333","ownerId":"owner","type":"IMAGE",
                    "originalFileName":"locked.jpg","checksum":"a".repeat(40),
                    "fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z",
                    "updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,
                    "visibility":"locked","livePhotoVideoId":null,"stack":null
                }),
                "scope",
                "owner",
            )?;
            assert!(
                capability
                    .clone()
                    .projection("operation".into(), facts)
                    .is_none()
            );
            if unrelated {
                ordinary.fetch_add(1, Ordering::SeqCst);
            }
            let previous = ordinary.fetch_add(1, Ordering::SeqCst);
            assert_eq!(capability.advance_own_fence(previous).is_ok(), !unrelated);
            assert_eq!(capability.valid().is_ok(), !unrelated);
            epoch.fetch_add(1, Ordering::SeqCst);
            assert!(capability.valid().is_err());
        }
        Ok(())
    }
}
