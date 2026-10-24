//! App-local exact-key protection. Grants and native staging permits are ephemeral.
use crate::{
    app::{Context, Event, Model, SavedLibrary, ShellOperation, io},
    domain::{AppleVisibility, AssetKey, Provider, ScanAccess, StoredAsset},
    immich::{HttpRequest, Session},
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PersistentProtectedEntry {
    pub id: String,
    pub key: AssetKey,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ProtectedPurpose {
    View,
    Protect,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ProtectedAuthOutcome {
    Success,
    Cancelled,
    Unavailable,
    Failed,
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ProtectionScenePhase {
    #[default]
    Background,
    Active,
    Inactive,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedChallenge {
    #[serde(rename = "challengeID")]
    pub challenge_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub purpose: ProtectedPurpose,
    pub scope: String,
    pub generation: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedAuthResult {
    #[serde(rename = "challengeID")]
    pub challenge_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub scope: String,
    pub outcome: ProtectedAuthOutcome,
}
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ProtectedImageKind {
    Thumbnail,
    Preview,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedImageTicket {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "entryID")]
    pub entry_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub key: AssetKey,
    pub kind: ProtectedImageKind,
    pub expected_revision: String,
    pub remote_request: Option<HttpRequest>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedImageResult {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
    pub fresh_apple_asset: Option<StoredAsset>,
    pub full_access: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedImageAccess {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "entryID")]
    pub entry_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    pub kind: ProtectedImageKind,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedEntryView {
    pub id: String,
    pub asset: Option<StoredAsset>,
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ProtectedViewState {
    #[default]
    Locked,
    Authenticating,
    Open,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProtectedView {
    pub state: ProtectedViewState,
    pub generation: u64,
    pub persistence_uncertain: bool,
    pub can_recover: bool,
    #[serde(rename = "grantID", skip_serializing_if = "Option::is_none")]
    pub grant_id: Option<String>,
    #[serde(rename = "sceneID", skip_serializing_if = "Option::is_none")]
    pub scene_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub purpose: Option<ProtectedPurpose>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<ProtectedEntryView>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<ProtectedImageAccess>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
#[derive(Debug, Default)]
pub struct ProtectionModel {
    pub generation: Arc<AtomicU64>,
    pub scene_id: Option<String>,
    pub phase: ProtectionScenePhase,
    pub attempt: Option<ProtectedChallenge>,
    pub pending_success: bool,
    pub grant: Option<ProtectedChallenge>,
    pub image: Option<ProtectedImageAccess>,
    pub pending_image: Option<ProtectedImageTicket>,
    pub denied: BTreeSet<AssetKey>,
    pub used_ids: BTreeSet<String>,
    pub error: Option<String>,
    pub membership_uncertain: bool,
}

pub fn validate_membership(state: &SavedLibrary) -> Result<(), String> {
    let mut ids = BTreeSet::new();
    let mut keys = BTreeSet::new();
    for entry in &state.protected_entries {
        crate::apple_visibility::valid_operation_id(&entry.id)?;
        if entry.key.scope.is_empty()
            || entry.key.asset_id.is_empty()
            || !ids.insert(&entry.id)
            || !keys.insert(&entry.key)
        {
            return Err("保護する写真の記録が不正です。".into());
        }
    }
    Ok(())
}
fn scope(model: &Model) -> String {
    serde_json::to_string(&(
        &model.state.apple_scope,
        model.session.as_ref().map(|s| &s.scope),
    ))
    .unwrap_or_default()
}
fn generation(model: &Model) -> u64 {
    model.protection.generation.load(Ordering::Relaxed)
}
fn current_grant(model: &Model, id: &str, purpose: ProtectedPurpose) -> bool {
    model.protection.phase == ProtectionScenePhase::Active
        && model.protection.grant.as_ref().is_some_and(|g| {
            g.challenge_id == id
                && g.purpose == purpose
                && g.scope == scope(model)
                && g.generation == generation(model)
                && Some(&g.scene_id) == model.protection.scene_id.as_ref()
        })
}
fn current_asset<'a>(model: &'a Model, key: &AssetKey) -> Option<&'a StoredAsset> {
    let snapshots = model
        .state
        .snapshots
        .iter()
        .filter(|s| s.provider == key.provider && s.scope == key.scope)
        .collect::<Vec<_>>();
    let [snapshot] = snapshots.as_slice() else {
        return None;
    };
    let current = match key.provider {
        Provider::Apple => key.scope == model.state.apple_scope,
        Provider::Immich => model.session.as_ref().is_some_and(|s| s.scope == key.scope),
    };
    if !current || snapshot.access == ScanAccess::Unavailable {
        return None;
    }
    let assets = snapshot
        .assets
        .iter()
        .filter(|a| a.key == *key)
        .collect::<Vec<_>>();
    let [asset] = assets.as_slice() else {
        return None;
    };
    if crate::immich_visibility::fences(&model.state, key)
        || model.immich_visibility.denied.contains(key)
        || !asset.content_visible()
        || model
            .state
            .apple_visibility_operations
            .iter()
            .any(|o| o.fences(key))
    {
        return None;
    }
    Some(*asset)
}
#[must_use]
pub fn ordinary_state(model: &Model) -> SavedLibrary {
    ordinary_state_view(model).into_owned()
}

pub(crate) fn ordinary_state_view(model: &Model) -> std::borrow::Cow<'_, SavedLibrary> {
    // Most snapshots have no pending denial. Borrow the canonical state rather
    // than copying every asset for each read-only projection.
    let mut state = std::borrow::Cow::Borrowed(&model.state);
    for key in model
        .protection
        .denied
        .iter()
        .chain(&model.immich_visibility.denied)
        .chain(&model.live_placement.held)
    {
        if !state.protected_entries.iter().any(|e| e.key == *key) {
            state
                .to_mut()
                .protected_entries
                .push(PersistentProtectedEntry {
                    id: entry_id("pending-denial", key),
                    key: key.clone(),
                });
        }
    }
    state
}
#[must_use]
pub fn view(model: &Model) -> ProtectedView {
    let mut result = ProtectedView {
        generation: generation(model),
        persistence_uncertain: model.protection.membership_uncertain,
        can_recover: model.protection.membership_uncertain
            && !model.busy
            && model
                .protection
                .grant
                .as_ref()
                .is_some_and(|grant| current_grant(model, &grant.challenge_id, grant.purpose)),
        error: model.protection.error.clone(),
        ..ProtectedView::default()
    };
    if model.protection.attempt.is_some() {
        result.state = ProtectedViewState::Authenticating;
    }
    if let Some(grant) = &model.protection.grant
        && current_grant(model, &grant.challenge_id, grant.purpose)
    {
        result.state = ProtectedViewState::Open;
        result.grant_id = Some(grant.challenge_id.clone());
        result.scene_id = Some(grant.scene_id.clone());
        result.purpose = Some(grant.purpose);
        if grant.purpose == ProtectedPurpose::View {
            result.entries = Some(
                model
                    .state
                    .protected_entries
                    .iter()
                    .map(|entry| ProtectedEntryView {
                        id: entry.id.clone(),
                        asset: current_asset(model, &entry.key).cloned(),
                    })
                    .collect(),
            );
            result.image = model.protection.image.clone().filter(|image| {
                model
                    .protection
                    .pending_image
                    .as_ref()
                    .is_some_and(|ticket| {
                        ticket.request_id == image.request_id && ticket_matches(model, ticket)
                    })
            });
        }
    }
    result
}
fn release_image(staged_id: String) -> Command<crate::app::Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<serde_json::Value, _> =
            io(&ctx, ShellOperation::ReleaseProtectedImage { staged_id }).await;
    })
}
fn release(grant_id: Option<String>) -> Command<crate::app::Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<serde_json::Value, _> =
            io(&ctx, ShellOperation::ReleaseProtectedImages { grant_id }).await;
    })
}
fn lock(model: &mut Model, cancel_attempt: bool) -> Command<crate::app::Effect, Event> {
    let grant = model.protection.grant.take().map(|g| g.challenge_id);
    model.protection.image = None;
    model.protection.pending_image = None;
    if cancel_attempt {
        model.protection.attempt = None;
        model.protection.pending_success = false;
    }
    model.protection.generation.fetch_add(1, Ordering::Relaxed);
    release(grant)
}
fn accept_auth(model: &mut Model) -> Command<crate::app::Effect, Event> {
    let Some(mut attempt) = model.protection.attempt.take() else {
        return Command::done();
    };
    attempt.generation = generation(model);
    model.protection.pending_success = false;
    model.protection.grant = Some(attempt);
    Command::done()
}

pub fn update(event: Event, model: &mut Model) -> Option<Command<crate::app::Effect, Event>> {
    let command = match event {
        Event::LockProtectedAccess => lock(model, true),
        Event::ProtectedSceneChanged { scene_id, phase } => scene_changed(model, scene_id, phase),

        Event::BeginProtectedAccess {
            challenge_id,
            scene_id,
            purpose,
        } => begin_auth(model, challenge_id, scene_id, purpose),

        Event::ProtectedAuthCompleted { challenge, result } => {
            auth_completed(model, &challenge, result.as_ref())
        }

        Event::ProtectPhotos {
            keys,
            operation_id,
            grant_id,
        } => mutate(model, keys, None, &operation_id, &grant_id),
        Event::UnprotectPhotos {
            ids,
            operation_id,
            grant_id,
        } => mutate(model, vec![], Some(ids), &operation_id, &grant_id),
        Event::ProtectedPersisted {
            state,
            keys,
            outcome,
        } => persisted(model, state, keys, outcome),

        Event::ReconcileProtectedState { grant_id } => reconcile_durable(model, &grant_id),
        Event::ProtectedReconciled { state } => {
            model.busy = false;
            if let Some(mut state) = state {
                for snapshot in &mut state.snapshots {
                    snapshot.access = ScanAccess::Unavailable;
                }
                for snapshot in &mut state.albums {
                    snapshot.access = ScanAccess::Unavailable;
                }
                model.state = state;
                model.protection.denied.clear();
                model.protection.membership_uncertain = false;
                model.protection.error = None;
                reconcile(model)
            } else {
                model.protection.error =
                    Some("保護の保存状態を確認できません。変更は開始しません。".into());
                Command::done()
            }
        }
        Event::RequestProtectedImage {
            entry_id,
            grant_id,
            request_id,
            kind,
        } => request_image(model, &entry_id, &grant_id, &request_id, kind),
        Event::ProtectedImageRead { ticket, result } => finish_image(model, ticket, result),
        Event::ProtectedImagePublished {
            ticket,
            staged_id,
            result,
        } => {
            if let Some(result) = result {
                if ticket_matches(model, &ticket) && valid_result(&ticket, &result) {
                    model.protection.image = Some(ProtectedImageAccess {
                        request_id: ticket.request_id,
                        entry_id: ticket.entry_id,
                        grant_id: ticket.grant_id,
                        staged_id: result.staged_id,
                        scene_id: ticket.scene_id,
                        generation: ticket.generation,
                        kind: ticket.kind,
                    });
                    Command::done()
                } else {
                    release_image(result.staged_id)
                }
            } else {
                release_image(staged_id)
            }
        }

        _ => return None,
    };
    Some(command)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectedPersistOutcome {
    Applied,
    NotApplied,
    Unknown,
}

fn entry_id(operation: &str, key: &AssetKey) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("{operation}|{}", key.id()).as_bytes());
    let hex = crate::domain::hex(&digest[..16]);
    format!(
        "{}-{}-4{}-8{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[13..16],
        &hex[17..20],
        &hex[20..32]
    )
}
fn mutate(
    model: &mut Model,
    keys: Vec<AssetKey>,
    ids: Option<Vec<String>>,
    operation: &str,
    grant: &str,
) -> Command<crate::app::Effect, Event> {
    let purpose = if ids.is_some() {
        ProtectedPurpose::View
    } else {
        ProtectedPurpose::Protect
    };
    if model.busy
        || model.protection.membership_uncertain
        || !current_grant(model, grant, purpose)
        || crate::apple_visibility::valid_operation_id(operation).is_err()
        || !model.protection.used_ids.insert(operation.into())
    {
        model.protection.error = Some("保護の変更には現在の認証が必要です。".into());
        return Command::done();
    }
    let before = model.state.clone();
    let mut changed = before.clone();
    let affected = if let Some(ids) = ids {
        if ids.is_empty() || ids.iter().collect::<BTreeSet<_>>().len() != ids.len() {
            model.protection.error = Some("保護する写真を確認してください。".into());
            return Command::done();
        }
        let selected = ids
            .iter()
            .filter_map(|id| model.state.protected_entries.iter().find(|e| e.id == *id))
            .collect::<Vec<_>>();
        if selected.len() != ids.len() {
            model.protection.error = Some("保護する写真を確認できません。".into());
            return Command::done();
        }
        let affected = selected.iter().map(|e| e.key.clone()).collect::<Vec<_>>();
        changed.protected_entries.retain(|e| !ids.contains(&e.id));
        affected
    } else {
        if keys.is_empty()
            || keys.iter().collect::<BTreeSet<_>>().len() != keys.len()
            || keys
                .iter()
                .any(|k| !model.state.apple_content_visible(k) || current_asset(model, k).is_none())
        {
            model.protection.error = Some("保護する写真を確認できません。".into());
            return Command::done();
        }
        for key in &keys {
            changed.protected_entries.push(PersistentProtectedEntry {
                id: entry_id(operation, key),
                key: key.clone(),
            });
        }
        keys
    };
    if validate_membership(&changed).is_err() {
        model.protection.error = Some("保護する写真の記録が不正です。".into());
        return Command::done();
    }
    model.status = "保護の変更を保存しています。".into();
    model.error = None;
    model.protection.denied.extend(affected.iter().cloned());
    model.protection.image = None;
    model.busy = true;
    model.changed_during_work = false;
    let epoch = model.protection.generation.clone();
    let started = generation(model);
    Command::new(move |ctx| async move {
        // A revoked grant cannot begin durable unprotection. Once persistence is
        // submitted, its acknowledgement must still be processed after relock.
        if epoch.load(Ordering::Relaxed) != started {
            ctx.send_event(Event::ProtectedPersisted {
                state: changed,
                keys: affected,
                outcome: ProtectedPersistOutcome::NotApplied,
            });
            return;
        }
        let written: Result<serde_json::Value, _> =
            io(&ctx, ShellOperation::Persist(changed.clone())).await;
        let outcome = if written.is_ok() {
            ProtectedPersistOutcome::Applied
        } else {
            let read: Result<serde_json::Value, _> = io(&ctx, ShellOperation::ReadState).await;
            match read
                .ok()
                .and_then(|value| crate::workflow::migrate(value).ok())
            {
                Some(saved)
                    if serde_json::to_value(&saved).ok() == serde_json::to_value(&changed).ok() =>
                {
                    ProtectedPersistOutcome::Applied
                }
                Some(saved)
                    if serde_json::to_value(&saved).ok() == serde_json::to_value(&before).ok() =>
                {
                    ProtectedPersistOutcome::NotApplied
                }
                _ => ProtectedPersistOutcome::Unknown,
            }
        };
        ctx.send_event(Event::ProtectedPersisted {
            state: changed,
            keys: affected,
            outcome,
        });
    })
}
fn ticket_matches(model: &Model, ticket: &ProtectedImageTicket) -> bool {
    model
        .protection
        .pending_image
        .as_ref()
        .is_some_and(|t| t.request_id == ticket.request_id)
        && current_grant(model, &ticket.grant_id, ProtectedPurpose::View)
        && ticket.generation == generation(model)
        && model
            .state
            .protected_entries
            .iter()
            .any(|e| e.id == ticket.entry_id && e.key == ticket.key)
        && current_asset(model, &ticket.key).is_some_and(|a| a.revision == ticket.expected_revision)
}
fn request_image(
    model: &mut Model,
    entry_id: &str,
    grant_id: &str,
    request_id: &str,
    kind: ProtectedImageKind,
) -> Command<crate::app::Effect, Event> {
    if !current_grant(model, grant_id, ProtectedPurpose::View)
        || crate::apple_visibility::valid_operation_id(request_id).is_err()
        || !model.protection.used_ids.insert(request_id.into())
    {
        return Command::done();
    }
    let Some(entry) = model
        .state
        .protected_entries
        .iter()
        .find(|e| e.id == entry_id)
    else {
        return Command::done();
    };
    let Some(asset) = current_asset(model, &entry.key) else {
        return Command::done();
    };
    let remote_request = if asset.key.provider == Provider::Immich {
        model.session.as_ref().and_then(|s| {
            s.preview_request(&asset.key.asset_id, kind == ProtectedImageKind::Preview)
                .ok()
        })
    } else {
        None
    };
    let Some(grant) = model.protection.grant.as_ref() else {
        return Command::done();
    };
    let ticket = ProtectedImageTicket {
        request_id: request_id.into(),
        entry_id: entry_id.into(),
        grant_id: grant_id.into(),
        scene_id: grant.scene_id.clone(),
        generation: generation(model),
        key: entry.key.clone(),
        kind,
        expected_revision: asset.revision.clone(),
        remote_request,
    };
    let expected = asset.clone();
    let session = model.session.clone();
    let epoch = model.protection.generation.clone();
    model.protection.image = None;
    model.protection.pending_image = Some(ticket.clone());
    Command::new(move |ctx| async move {
        let result = read_image(&ctx, &ticket, &expected, session.as_ref(), &epoch)
            .await
            .ok();
        ctx.send_event(Event::ProtectedImageRead { ticket, result });
    })
}
async fn read_image(
    ctx: &Context,
    ticket: &ProtectedImageTicket,
    expected: &StoredAsset,
    session: Option<&Session>,
    epoch: &AtomicU64,
) -> Result<ProtectedImageResult, String> {
    let before = if ticket.key.provider == Provider::Immich {
        Some(
            session
                .ok_or("保存先を確認してください。")?
                .asset(ctx, &ticket.key.asset_id)
                .await?,
        )
    } else {
        None
    };
    if epoch.load(Ordering::Relaxed) != ticket.generation {
        return Err("閲覧を終了しました。".into());
    }
    if let Some(asset) = &before
        && asset.record(&ticket.key.scope, None, None).revision != expected.revision
    {
        return Err("写真が変更されました。".into());
    }
    let result: ProtectedImageResult = io(
        ctx,
        ShellOperation::ReadProtectedImage {
            ticket: ticket.clone(),
        },
    )
    .await?;
    if let Some(before) = before {
        let after = match session {
            Some(session) => session.asset(ctx, &ticket.key.asset_id).await.ok(),
            None => None,
        };
        if !after.is_some_and(|after| {
            before.updated_at == after.updated_at && before.checksum == after.checksum
        }) {
            let _: Result<serde_json::Value, _> = io(
                ctx,
                ShellOperation::ReleaseProtectedImage {
                    staged_id: result.staged_id.clone(),
                },
            )
            .await;
            return Err("写真の現在の状態を確認できません。".into());
        }
    }
    Ok(result)
}
fn valid_result(ticket: &ProtectedImageTicket, result: &ProtectedImageResult) -> bool {
    result.request_id == ticket.request_id
        && !result.staged_id.is_empty()
        && result.full_access
        && (ticket.key.provider != Provider::Apple
            || result.fresh_apple_asset.as_ref().is_some_and(|a| {
                a.key == ticket.key
                    && a.revision == ticket.expected_revision
                    && a.apple_visibility == AppleVisibility::Visible
            }))
}
fn finish_image(
    model: &mut Model,
    ticket: ProtectedImageTicket,
    result: Option<ProtectedImageResult>,
) -> Command<crate::app::Effect, Event> {
    let Some(result) = result else {
        if ticket_matches(model, &ticket) {
            model.protection.error = Some("保護した写真を取得できません。".into());
        }
        return Command::done();
    };
    if !ticket_matches(model, &ticket) || !valid_result(&ticket, &result) {
        return release_image(result.staged_id);
    }
    Command::new(move |ctx| async move {
        let published: Result<ProtectedImageResult, _> = io(
            &ctx,
            ShellOperation::PublishProtectedImage {
                ticket: ticket.clone(),
                staged_id: result.staged_id.clone(),
            },
        )
        .await;
        ctx.send_event(Event::ProtectedImagePublished {
            ticket,
            staged_id: result.staged_id,
            result: published.ok(),
        });
    })
}

pub(crate) fn reconcile(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if model
        .protection
        .attempt
        .as_ref()
        .is_some_and(|a| a.scope != scope(model))
        || model
            .protection
            .grant
            .as_ref()
            .is_some_and(|a| a.scope != scope(model))
    {
        return lock(model, true);
    }
    if model
        .protection
        .pending_image
        .as_ref()
        .is_some_and(|ticket| !ticket_matches(model, ticket))
    {
        model.protection.pending_image = None;
        if let Some(image) = model.protection.image.take() {
            return release_image(image.staged_id);
        }
    }
    Command::done()
}

fn scene_changed(
    model: &mut Model,
    scene_id: String,
    phase: ProtectionScenePhase,
) -> Command<crate::app::Effect, Event> {
    if model
        .protection
        .scene_id
        .as_ref()
        .is_some_and(|id| id != &scene_id)
    {
        let command = lock(model, true);
        model.protection.scene_id = Some(scene_id);
        model.protection.phase = phase;
        command
    } else {
        model.protection.scene_id = Some(scene_id);
        model.protection.phase = phase;
        match phase {
            ProtectionScenePhase::Background => lock(model, true),
            ProtectionScenePhase::Inactive => {
                if model.protection.grant.is_some() {
                    lock(model, false)
                } else {
                    model.protection.image = None;
                    release(None)
                }
            }
            ProtectionScenePhase::Active => {
                if model.protection.pending_success {
                    accept_auth(model)
                } else {
                    Command::done()
                }
            }
        }
    }
}

fn begin_auth(
    model: &mut Model,
    challenge_id: String,
    scene_id: String,
    purpose: ProtectedPurpose,
) -> Command<crate::app::Effect, Event> {
    if model.busy
        || !model.ready
        || model.protection.phase != ProtectionScenePhase::Active
        || model.protection.scene_id.as_ref() != Some(&scene_id)
        || crate::apple_visibility::valid_operation_id(&challenge_id).is_err()
        || !model.protection.used_ids.insert(challenge_id.clone())
    {
        model.protection.error = Some("認証を開始できません。".into());
        Command::done()
    } else {
        let release = lock(model, true);
        model.protection.error = None;
        let challenge = ProtectedChallenge {
            challenge_id,
            scene_id,
            purpose,
            scope: scope(model),
            generation: generation(model),
        };
        model.protection.attempt = Some(challenge.clone());
        release.and(Command::new(move |ctx| async move {
            let result: Result<ProtectedAuthResult, _> = io(
                &ctx,
                ShellOperation::AuthenticateProtected {
                    challenge: challenge.clone(),
                },
            )
            .await;
            ctx.send_event(Event::ProtectedAuthCompleted {
                challenge,
                result: result.ok(),
            });
        }))
    }
}

fn auth_completed(
    model: &mut Model,
    challenge: &ProtectedChallenge,
    result: Option<&ProtectedAuthResult>,
) -> Command<crate::app::Effect, Event> {
    let matches = model.protection.attempt.as_ref().is_some_and(|a| {
        a.challenge_id == challenge.challenge_id
            && a.generation == challenge.generation
            && a.scope == scope(model)
            && a.scene_id == challenge.scene_id
    }) && generation(model) == challenge.generation;
    if !matches {
        Command::done()
    } else if result.as_ref().is_some_and(|r| {
        r.challenge_id == challenge.challenge_id
            && r.scene_id == challenge.scene_id
            && r.scope == challenge.scope
            && r.outcome == ProtectedAuthOutcome::Success
    }) {
        if model.protection.phase == ProtectionScenePhase::Active {
            accept_auth(model)
        } else if model.protection.phase == ProtectionScenePhase::Inactive {
            model.protection.pending_success = true;
            Command::done()
        } else {
            lock(model, true)
        }
    } else {
        model.protection.attempt = None;
        model.protection.pending_success = false;
        model.protection.error = Some("認証を完了できませんでした。".into());
        Command::done()
    }
}

fn reconcile_durable(model: &mut Model, grant_id: &str) -> Command<crate::app::Effect, Event> {
    if model.busy
        || !model.protection.membership_uncertain
        || !(current_grant(model, grant_id, ProtectedPurpose::View)
            || current_grant(model, grant_id, ProtectedPurpose::Protect))
    {
        return Command::done();
    }
    model.busy = true;
    let expected_scope = model.state.apple_scope.clone();
    let expected_connection = serde_json::to_value(&model.state.connection).ok();
    Command::new(move |ctx| async move {
        let read: Result<serde_json::Value, _> = io(&ctx, ShellOperation::ReadState).await;
        let state = read
            .ok()
            .filter(|value| {
                value["schemaVersion"].as_u64()
                    == Some(u64::from(crate::immich_live_writes::CURRENT_SCHEMA_VERSION))
            })
            .and_then(|value| crate::workflow::migrate(value).ok())
            .filter(|state| {
                state.apple_scope == expected_scope
                    && serde_json::to_value(&state.connection).ok() == expected_connection
            });
        ctx.send_event(Event::ProtectedReconciled { state });
    })
}

fn persisted(
    model: &mut Model,
    mut state: SavedLibrary,
    keys: Vec<AssetKey>,
    outcome: ProtectedPersistOutcome,
) -> Command<crate::app::Effect, Event> {
    model.busy = false;
    if model.changed_during_work {
        for snapshot in state
            .snapshots
            .iter_mut()
            .filter(|s| s.provider == Provider::Apple)
        {
            snapshot.access = ScanAccess::Unavailable;
        }
    }
    if outcome == ProtectedPersistOutcome::Applied {
        model.state = state;
        for key in keys {
            model.protection.denied.remove(&key);
        }
        model.protection.membership_uncertain = false;
        model.protection.error = None;
    } else if outcome == ProtectedPersistOutcome::NotApplied {
        for key in keys {
            model.protection.denied.remove(&key);
        }
        model.protection.membership_uncertain = false;
        model.protection.error = Some("保護の変更は保存されませんでした。".into());
    } else {
        model.protection.membership_uncertain = true;
        model.protection.error = Some(
            "保護の変更を保存できません。写真は公開せず、現在の記録を確認してください。".into(),
        );
    }
    model.protection.image = None;
    Command::done()
}

#[cfg(test)]
mod snapshot_borrow_tests {
    use super::*;

    #[test]
    fn ordinary_state_borrows_until_a_new_denial_requires_an_overlay() {
        let mut model = Model::default();
        assert!(matches!(
            ordinary_state_view(&model),
            std::borrow::Cow::Borrowed(_)
        ));
        let key = AssetKey {
            provider: Provider::Immich,
            scope: "test-scope".into(),
            asset_id: "test-asset".into(),
        };
        model.protection.denied.insert(key.clone());
        model.immich_visibility.denied.insert(key.clone());
        let overlay = ordinary_state_view(&model);
        assert!(matches!(overlay, std::borrow::Cow::Owned(_)));
        assert_eq!(overlay.protected_entries.len(), 1);
        assert_eq!(overlay.protected_entries[0].key, key);
        assert!(model.state.protected_entries.is_empty());
        model
            .state
            .protected_entries
            .push(PersistentProtectedEntry {
                id: "persisted".into(),
                key,
            });
        let persisted = ordinary_state_view(&model);
        assert!(matches!(persisted, std::borrow::Cow::Borrowed(_)));
        assert_eq!(persisted.protected_entries[0].id, "persisted");
    }
}
