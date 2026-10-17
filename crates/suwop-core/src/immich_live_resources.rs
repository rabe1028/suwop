//! Ephemeral, dedicated metadata observation. No write or original-read authority.
use crate::{
    app::{Context, Event, Model},
    domain::{AssetKey, Provider, normalize_sha1},
    immich_locked::VisibilitySession,
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
mod inspect;
const ERROR: &str = "Live Photo の関連原本を確認できません。";
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum LiveObservedVisibility {
    Timeline,
    Archive,
    Hidden,
    Locked,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum LiveResourceRole {
    Parent,
    Motion,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveResourceReadFact {
    pub key: AssetKey,
    pub role: LiveResourceRole,
    pub checksum: String,
    pub revision: String,
    pub visibility: LiveObservedVisibility,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum LiveDiscoveryTermination {
    ExhaustedPages,
    PageBudget,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveAdditionalParent {
    pub key: AssetKey,
    pub revision: String,
    pub visibility: Option<LiveObservedVisibility>,
    pub is_offline: Option<bool>,
    pub is_trashed: Option<bool>,
    pub has_stack: Option<bool>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LiveParentObservation {
    pub parents: Vec<LiveAdditionalParent>,
    pub malformed_candidates: u32,
    pub protected_candidates: u32,
    pub pages_observed: u32,
    pub observations: u32,
    pub termination: LiveDiscoveryTermination,
    /// Offset traversal cannot establish a complete reverse graph.
    pub graph_complete: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLiveResourcePlan {
    #[serde(rename = "planID")]
    pub plan_id: String,
    pub read_targets: Vec<LiveResourceReadFact>,
    pub additional_parents: LiveParentObservation,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLiveResourcesView {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub pending: bool,
    pub plan: Option<ImmichLiveResourcePlan>,
    pub error: Option<String>,
}
#[derive(Debug, Clone)]
pub(crate) struct Authority {
    session: VisibilitySession,
    epoch: Arc<AtomicU64>,
    expected: u64,
    ordinary: Arc<AtomicU64>,
    ordinary_expected: u64,
    protection: Arc<AtomicU64>,
    protection_expected: u64,
    blocked: std::collections::BTreeSet<AssetKey>,
}
impl Authority {
    fn valid(&self) -> Result<(), String> {
        self.session.valid()?;
        if self.epoch.load(Ordering::SeqCst) != self.expected
            || self.ordinary.load(Ordering::SeqCst) != self.ordinary_expected
            || self.protection.load(Ordering::SeqCst) != self.protection_expected
        {
            return Err(ERROR.into());
        }
        Ok(())
    }
    async fn json(&self, ctx: &Context, path: &str, body: Option<Value>) -> Result<Value, String> {
        self.valid()?;
        let method = if body.is_some() { "POST" } else { "GET" };
        let raw = self.session.json(ctx, path, method, body).await?;
        self.valid()?;
        Ok(raw)
    }
}
#[derive(Debug, Default)]
pub struct LiveResourcesModel {
    epoch: Arc<AtomicU64>,
    authority: Option<Authority>,
    view: Option<ImmichLiveResourcesView>,
}
#[derive(Debug, Clone)]
pub struct Completion {
    authority: Authority,
    request_id: String,
    result: Result<ImmichLiveResourcePlan, String>,
}
pub(crate) fn view(model: &Model) -> Option<ImmichLiveResourcesView> {
    let a = model.immich_live_resources.authority.as_ref()?;
    a.valid().ok()?;
    crate::immich_locked::visibility_session(model, &a.session.grant_id, &a.session.scene_id)?;
    if model.protection.membership_uncertain || model.immich_visibility.persistence_uncertain {
        return None;
    }
    let mut view = model.immich_live_resources.view.clone()?;
    if let Some(plan) = &mut view.plan {
        if plan.read_targets.iter().any(|r| read_denied(model, &r.key)) {
            return None;
        }
        plan.additional_parents
            .parents
            .retain(|p| !read_denied(model, &p.key));
    }
    Some(view)
}
pub(crate) fn update(
    event: &Event,
    model: &mut Model,
) -> Option<Command<crate::app::Effect, Event>> {
    if model
        .immich_live_resources
        .authority
        .as_ref()
        .is_some_and(|a| a.valid().is_err())
    {
        model
            .immich_live_resources
            .epoch
            .fetch_add(1, Ordering::SeqCst);
        model.immich_live_resources.authority = None;
        model.immich_live_resources.view = None;
    }
    match event {
        Event::InspectImmichLiveResources {
            parent_key,
            request_id,
            grant_id,
            scene_id,
        } => Some(inspect::begin(
            model,
            parent_key.clone(),
            request_id.clone(),
            grant_id,
            scene_id,
        )),
        Event::ImmichLiveResourcesInspected { completion } => {
            let admitted = completion.authority.valid().is_ok()
                && !model.immich_visibility.persistence_uncertain
                && !model.protection.membership_uncertain
                && crate::immich_locked::visibility_session(
                    model,
                    &completion.authority.session.grant_id,
                    &completion.authority.session.scene_id,
                )
                .is_some()
                && completion.result.as_ref().map_or(true, |p| {
                    p.read_targets.iter().all(|r| !read_denied(model, &r.key))
                });
            let state = &mut model.immich_live_resources;
            if state
                .authority
                .as_ref()
                .is_some_and(|a| a.expected == completion.authority.expected)
                && state
                    .view
                    .as_ref()
                    .is_some_and(|v| v.request_id == completion.request_id)
            {
                if !admitted {
                    state.view = None;
                    state.authority = None;
                    return Some(Command::done());
                }
                state.view = Some(ImmichLiveResourcesView {
                    request_id: completion.request_id.clone(),
                    pending: false,
                    plan: completion.result.clone().ok(),
                    error: completion.result.as_ref().err().map(|_| ERROR.into()),
                });
            }
            Some(Command::done())
        }
        _ => None,
    }
}
fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn fact(
    raw: &Value,
    key: &AssetKey,
    owner: &str,
    role: LiveResourceRole,
) -> Result<LiveResourceReadFact, String> {
    let kind = match role {
        LiveResourceRole::Parent => "IMAGE",
        LiveResourceRole::Motion => "VIDEO",
    };
    if key.provider != Provider::Immich
        || !uuid(&key.asset_id)
        || raw["id"].as_str() != Some(&key.asset_id)
        || raw["ownerId"].as_str() != Some(owner)
        || raw["type"].as_str() != Some(kind)
        || raw.get("stack") != Some(&Value::Null)
        || raw["isTrashed"].as_bool() != Some(false)
        || raw["isOffline"].as_bool() != Some(false)
    {
        return Err(ERROR.into());
    }
    let revision = raw["updatedAt"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or(ERROR)?
        .to_owned();
    let checksum = normalize_sha1(raw["checksum"].as_str()).ok_or(ERROR)?;
    let visibility = match raw["visibility"].as_str() {
        Some("timeline") => LiveObservedVisibility::Timeline,
        Some("archive") => LiveObservedVisibility::Archive,
        Some("hidden") => LiveObservedVisibility::Hidden,
        Some("locked") => LiveObservedVisibility::Locked,
        _ => return Err(ERROR.into()),
    };
    Ok(LiveResourceReadFact {
        key: key.clone(),
        role,
        checksum,
        revision,
        visibility,
    })
}
fn child(raw: &Value) -> Result<&str, String> {
    raw.get("livePhotoVideoId")
        .and_then(Value::as_str)
        .filter(|id| uuid(id))
        .ok_or_else(|| ERROR.into())
}

fn read_denied(model: &Model, key: &AssetKey) -> bool {
    crate::immich_locked::live_metadata_denied(model, key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const P: &str = "11111111-1111-4111-8111-111111111111";
    const M: &str = "22222222-2222-4222-8222-222222222222";
    fn key() -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: "fixture-owner".into(),
            asset_id: P.into(),
        }
    }
    fn parent() -> Value {
        json!({"id":P,"ownerId":"owner","type":"IMAGE","checksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","updatedAt":"2026-10-16T00:00:00Z","visibility":"locked","stack":null,"isOffline":false,"isTrashed":false,"livePhotoVideoId":M})
    }
    #[test]
    fn strict_parent_requires_exact_own_identity_and_explicit_relation() -> Result<(), String> {
        let raw = parent();
        assert!(fact(&raw, &key(), "owner", LiveResourceRole::Parent).is_ok());
        assert_eq!(child(&raw)?, M);
        for field in ["id", "ownerId", "type", "checksum", "visibility"] {
            let mut changed = raw.clone();
            changed[field] = json!("invalid");
            assert!(
                fact(&changed, &key(), "owner", LiveResourceRole::Parent).is_err(),
                "{field}"
            );
        }
        for value in [Value::Null, json!("bad-id"), json!(42)] {
            let mut changed = raw.clone();
            changed["livePhotoVideoId"] = value;
            assert!(child(&changed).is_err());
        }
        let mut absent = raw;
        absent
            .as_object_mut()
            .ok_or("fixture object")?
            .remove("livePhotoVideoId");
        assert!(child(&absent).is_err());
        Ok(())
    }
    #[test]
    fn revision_is_required_but_opaque_and_compared_exactly() -> Result<(), String> {
        let raw = parent();
        for value in [Value::Null, json!(7), json!("")] {
            let mut changed = raw.clone();
            changed["updatedAt"] = value;
            assert!(fact(&changed, &key(), "owner", LiveResourceRole::Parent).is_err());
        }
        let mut absent = raw.clone();
        absent
            .as_object_mut()
            .ok_or("fixture object")?
            .remove("updatedAt");
        assert!(fact(&absent, &key(), "owner", LiveResourceRole::Parent).is_err());
        let mut opaque = raw.clone();
        opaque["updatedAt"] = json!("opaque-revision");
        let observed = fact(&opaque, &key(), "owner", LiveResourceRole::Parent)?;
        assert_eq!(observed.revision, "opaque-revision");
        assert_ne!(
            observed,
            fact(&raw, &key(), "owner", LiveResourceRole::Parent)?
        );
        Ok(())
    }
    #[test]
    fn observed_hidden_is_not_a_restore_destination_or_locked_equivalence() -> Result<(), String> {
        let mut raw = parent();
        raw["visibility"] = json!("hidden");
        let hidden = fact(&raw, &key(), "owner", LiveResourceRole::Parent)?;
        raw["visibility"] = json!("locked");
        let locked = fact(&raw, &key(), "owner", LiveResourceRole::Parent)?;
        assert_ne!(hidden.visibility, locked.visibility);
        let encoded = serde_json::to_value(hidden).map_err(|e| e.to_string())?;
        assert!(encoded.get("destination").is_none());
        assert!(encoded.get("url").is_none());
        Ok(())
    }
    #[test]
    fn motion_requires_video_type_and_never_accepts_parent_facts() -> Result<(), String> {
        let mut raw = parent();
        let key = key();
        assert!(fact(&raw, &key, "owner", LiveResourceRole::Motion).is_err());
        raw["type"] = json!("VIDEO");
        raw["livePhotoVideoId"] = Value::Null;
        assert!(fact(&raw, &key, "owner", LiveResourceRole::Motion).is_ok());
        raw.as_object_mut().ok_or("fixture object")?.remove("stack");
        assert!(fact(&raw, &key, "owner", LiveResourceRole::Motion).is_err());
        Ok(())
    }
}
