//! Ephemeral ordinary paired presentation. Historical outcomes remain untouched.
//! These proofs are deliberately distinct from runtime submission capabilities.
use super::{Fact, Forward, Media, Placement};
use crate::{
    app::{Context, Model, SavedLibrary, ShellOperation, io},
    domain::{AssetKey, StoredAsset},
    immich::{Asset, HttpResponse, OrdinaryContentAuthorization, OrdinaryContentPurpose, Session},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
const ERROR: &str = "Live Photo の現在の通常表示を確認できません。更新してください。";

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairPresentation {
    pub parent_key: AssetKey,
    pub motion_key: AssetKey,
    #[serde(rename = "proofID")]
    pub proof_id: String,
    pub generation: u64,
    pub parent_visibility: Placement,
    pub motion_visibility: Placement,
}

#[derive(Clone)]
pub(crate) struct Request {
    source: Arc<Source>,
    parent: AssetKey,
    motion: AssetKey,
    expected: BTreeMap<AssetKey, Fact>,
}
/// One immutable origin binds history/session/epochs together for a whole refresh.
/// Every pair retains this same allocation rather than a copy of the catalog.
pub(crate) struct Source {
    session: Session,
    connection: Value,
    history: Value,
    baseline: SavedLibrary,
    denied: std::collections::BTreeSet<AssetKey>,
    epoch: Arc<AtomicU64>,
    epoch_expected: u64,
    ordinary: Arc<AtomicU64>,
    generation: u64,
    protection: Arc<AtomicU64>,
    protection_expected: u64,
}
impl std::fmt::Debug for Request {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OrdinaryLivePairRequest([redacted])")
    }
}
/// Bound to this borrowed Model only; never cache across model revisions.
pub(crate) struct Evaluation<'a> {
    model: &'a Model,
    history: Option<Value>,
    connection: Option<Value>,
}
impl<'a> Evaluation<'a> {
    pub(crate) fn new(model: &'a Model) -> Self {
        Self {
            model,
            history: fingerprint(&model.state).ok(),
            connection: model
                .state
                .connection
                .as_ref()
                .and_then(|c| serde_json::to_value(c).ok()),
        }
    }
}
fn fingerprint(state: &SavedLibrary) -> Result<Value, String> {
    serde_json::to_value((
        state.schema_version,
        &state.immich_live_operations,
        &state.immich_live_unstarted_closures,
        &state.immich_live_legacy_reconciliations,
        &state.immich_visibility_operations,
        &state.protected_entries,
    ))
    .map_err(|_| ERROR.into())
}
fn blocked(model: &Model) -> bool {
    model.busy
        || !model.ready
        || !model.live_placement.held.is_empty()
        || model.live_placement.persistence_uncertain
        || model.immich_visibility.persistence_uncertain
        || model.protection.membership_uncertain
}
impl Source {
    pub(crate) fn capture(
        model: &Model,
        epoch: Arc<AtomicU64>,
        expected: u64,
    ) -> Result<Arc<Self>, String> {
        if blocked(model) {
            return Err(ERROR.into());
        }
        super::validate_library(&model.state)?;
        let session = model.session.as_ref().ok_or(ERROR)?.clone();
        session.check_content_guard()?;
        let configured = model.state.connection.as_ref().ok_or(ERROR)?;
        if crate::immich::endpoint(&configured.address, configured.allow_http)? != session.endpoint
            || session.scope != format!("{}#{}", session.endpoint, session.user_id)
        {
            return Err(ERROR.into());
        }
        let source = Arc::new(Self {
            session,
            connection: serde_json::to_value(configured).map_err(|_| ERROR)?,
            history: fingerprint(&model.state)?,
            baseline: model.state.clone(),
            denied: model
                .protection
                .denied
                .iter()
                .cloned()
                .chain(model.state.protected_entries.iter().map(|e| e.key.clone()))
                .collect(),
            epoch,
            epoch_expected: expected,
            ordinary: model.ordinary_generation.clone(),
            generation: crate::ordinary_selected::generation(model),
            protection: model.protection.generation.clone(),
            protection_expected: model.protection.generation.load(Ordering::SeqCst),
        });
        source.valid()?;
        Ok(source)
    }
    pub(crate) fn valid(&self) -> Result<(), String> {
        self.session.check_content_guard()?;
        if self.epoch.load(Ordering::SeqCst) != self.epoch_expected
            || self.ordinary.load(Ordering::SeqCst) != self.generation
            || self.protection.load(Ordering::SeqCst) != self.protection_expected
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
    pub(crate) fn request(self: &Arc<Self>, parent: &AssetKey) -> Result<Request, String> {
        self.valid()?;
        super::validate::key(parent, &self.session.scope)?;
        let mut facts: BTreeMap<AssetKey, Fact> = BTreeMap::new();
        // A batch may contain independent pairs, and a shared motion may have
        // other parents. Only the selected P/M are read or published. Every
        // historical claim about those physical IDs must agree on identity.
        let initial_parent = self
            .baseline
            .immich_live_operations
            .iter()
            .flat_map(|batch| &batch.intent.resources)
            .find(|resource| resource.initial.key == *parent)
            .ok_or(ERROR)?;
        let Forward::Linked(motion) = &initial_parent.initial.forward else {
            return Err(ERROR.into());
        };
        let keys = std::collections::BTreeSet::from([parent.clone(), motion.clone()]);
        for batch in &self.baseline.immich_live_operations {
            for resource in batch
                .intent
                .resources
                .iter()
                .filter(|r| keys.contains(&r.initial.key))
            {
                let fact = &resource.initial;
                if fact.owner_id != self.session.user_id
                    || fact.key.scope != self.session.scope
                    || facts
                        .get(&fact.key)
                        .is_some_and(|old| !super::validate::same_identity(old, fact))
                {
                    return Err(ERROR.into());
                }
                facts.insert(fact.key.clone(), fact.clone());
            }
        }
        let p = facts.get(parent).ok_or(ERROR)?;
        let Forward::Linked(motion) = &p.forward else {
            return Err(ERROR.into());
        };
        let motion = motion.clone();
        if p.media != Media::Image
            || facts
                .get(&motion)
                .is_none_or(|m| m.media != Media::Video || m.forward != Forward::Unlinked)
        {
            return Err(ERROR.into());
        }
        if keys.iter().any(|key| self.denied.contains(key)) {
            return Err(ERROR.into());
        }
        Ok(Request {
            source: self.clone(),
            parent: parent.clone(),
            motion,
            expected: facts,
        })
    }
}
impl Request {
    pub(crate) fn capture(
        model: &Model,
        parent: &AssetKey,
        epoch: Arc<AtomicU64>,
        expected: u64,
    ) -> Result<Self, String> {
        Source::capture(model, epoch, expected)?.request(parent)
    }
    fn valid(&self) -> Result<(), String> {
        self.source.valid()
    }
    fn current(&self, evaluation: &Evaluation<'_>) -> bool {
        let model = evaluation.model;
        !blocked(model)
            && Arc::ptr_eq(&model.ordinary_generation, &self.source.ordinary)
            && Arc::ptr_eq(&model.protection.generation, &self.source.protection)
            && self.valid().is_ok()
            && model.session.as_ref().is_some_and(|s| {
                s.endpoint == self.source.session.endpoint
                    && s.scope == self.source.session.scope
                    && s.user_id == self.source.session.user_id
                    && s.key == self.source.session.key
            })
            && evaluation.connection.as_ref() == Some(&self.source.connection)
            && evaluation.history.as_ref() == Some(&self.source.history)
            && !self
                .expected
                .keys()
                .any(|k| model.protection.denied.contains(k))
    }
    async fn observe(
        &self,
        ctx: &Context,
        key: &AssetKey,
        expected: &Fact,
    ) -> Result<(Fact, Asset), String> {
        self.valid()?;
        let mut request =
            self.source
                .session
                .request(&format!("assets/{}", key.asset_id), "GET", None);
        request.ordinary_content_authorization = Some(OrdinaryContentAuthorization {
            source_keys: vec![key.clone()],
            expected_revision: crate::app::ordinary_revision(
                Some(&self.source.session.scope),
                self.source.generation,
            ),
            purpose: OrdinaryContentPurpose::SelectedPresentationMetadata,
        });
        let response: HttpResponse = io(ctx, ShellOperation::Http(request)).await?;
        self.valid()?;
        crate::immich::check_status(response.status)?;
        let raw = response.body;
        let read = crate::immich_live_resources::fact(
            &raw,
            key,
            &self.source.session.user_id,
            if expected.media == Media::Image {
                crate::immich_live_resources::LiveResourceRole::Parent
            } else {
                crate::immich_live_resources::LiveResourceRole::Motion
            },
        )?;
        let forward = match expected.media {
            Media::Image => Forward::Linked(AssetKey {
                asset_id: crate::immich_live_resources::child(&raw)?.into(),
                ..key.clone()
            }),
            Media::Video if raw.get("livePhotoVideoId") == Some(&Value::Null) => Forward::Unlinked,
            Media::Video => return Err(ERROR.into()),
        };
        let placement = match read.visibility {
            crate::immich_live_resources::LiveObservedVisibility::Timeline => Placement::Timeline,
            crate::immich_live_resources::LiveObservedVisibility::Archive => Placement::Archive,
            crate::immich_live_resources::LiveObservedVisibility::Hidden
                if expected.media == Media::Video =>
            {
                Placement::Hidden
            }
            _ => return Err(ERROR.into()),
        };
        let fact = Fact {
            key: key.clone(),
            owner_id: self.source.session.user_id.clone(),
            media: expected.media,
            checksum: read.checksum,
            revision: read.revision,
            placement,
            forward,
            unstacked: true,
            offline: false,
            trashed: false,
        };
        if !super::validate::same_identity(expected, &fact) {
            return Err(ERROR.into());
        }
        for operation in self
            .source
            .baseline
            .immich_visibility_operations
            .iter()
            .filter(|o| o.key == *key)
        {
            let matches = if fact.media == Media::Video {
                operation.scope == self.source.session.scope
                    && operation.witness_digest
                        == crate::immich_visibility::original_video_identity_digest(
                            key,
                            &fact.checksum,
                        )
            } else {
                crate::immich_visibility::matches_original_image_identity(
                    &raw,
                    operation,
                    &self.source.session.scope,
                    &self.source.session.user_id,
                )?
            };
            if !matches {
                return Err(ERROR.into());
            }
        }
        let asset = serde_json::from_value(raw).map_err(|_| ERROR)?;
        Ok((fact, asset))
    }
}

#[derive(Debug, Clone)]
pub(crate) struct VerifiedPair {
    request: Request,
    presentation: PairPresentation,
    assets: Vec<StoredAsset>,
    facts: BTreeMap<AssetKey, Fact>,
}
impl VerifiedPair {
    pub(crate) fn current(&self, model: &Model) -> bool {
        self.request.current(&Evaluation::new(model))
    }
    pub(crate) fn current_with(&self, evaluation: &Evaluation<'_>) -> bool {
        self.request.current(evaluation)
    }
    pub(crate) fn presentation_with(
        &self,
        evaluation: &Evaluation<'_>,
    ) -> Option<PairPresentation> {
        self.current_with(evaluation)
            .then(|| self.presentation.clone())
    }
    pub(crate) fn assets_with(&self, evaluation: &Evaluation<'_>) -> Option<Vec<StoredAsset>> {
        self.current_with(evaluation).then(|| self.assets.clone())
    }
    pub(crate) fn presentation(&self, model: &Model) -> Option<PairPresentation> {
        self.presentation_with(&Evaluation::new(model))
    }
    pub(crate) fn assets(&self, model: &Model) -> Option<Vec<StoredAsset>> {
        self.assets_with(&Evaluation::new(model))
    }
    /// A native consumer must freshly revalidate both members around acquisition.
    /// The returned proof remains display-only and never changes journal outcomes.
    pub(crate) async fn revalidate(&self, ctx: &Context) -> Result<(), String> {
        for (key, expected) in &self.facts {
            if self.request.observe(ctx, key, expected).await?.0 != *expected {
                return Err(ERROR.into());
            }
        }
        self.request.valid()
    }
}

pub(crate) async fn fetch(ctx: &Context, request: Request) -> Result<VerifiedPair, String> {
    request.valid()?;
    let mut first = BTreeMap::new();
    for (key, expected) in &request.expected {
        first.insert(key.clone(), request.observe(ctx, key, expected).await?);
    }
    let mut second = BTreeMap::new();
    for (key, expected) in &request.expected {
        let value = request.observe(ctx, key, expected).await?;
        if first.get(key).is_none_or(|old| old.0 != value.0) {
            return Err(ERROR.into());
        }
        second.insert(key.clone(), value);
    }
    let (parent, parent_asset) = second.get(&request.parent).ok_or(ERROR)?;
    let (motion, motion_asset) = second.get(&request.motion).ok_or(ERROR)?;
    let mut nonce = [0u8; 16];
    getrandom::getrandom(&mut nonce).map_err(|_| ERROR)?;
    let presentation = PairPresentation {
        parent_key: request.parent.clone(),
        motion_key: request.motion.clone(),
        proof_id: crate::domain::hex(&nonce),
        generation: request.source.generation,
        parent_visibility: parent.placement,
        motion_visibility: motion.placement,
    };
    let mut asset = parent_asset.record(&request.source.session.scope, Some(motion_asset), None);
    // Presentation inventory is never evidence for transfer or source deletion.
    asset.inventory_complete = false;
    let facts = second
        .into_iter()
        .map(|(key, (fact, _))| (key, fact))
        .collect();
    request.valid()?;
    Ok(VerifiedPair {
        request,
        presentation,
        assets: vec![asset],
        facts,
    })
}

#[cfg(test)]
mod tests;
