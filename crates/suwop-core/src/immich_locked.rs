//! Dedicated ephemeral password session. Never installed in the ordinary API-key session.
use crate::{
    app::{Context, Event, Model, ShellOperation, io},
    domain::{AssetKey, StoredAsset},
    immich::{Asset, HttpRequest, HttpResponse, Session},
    protection::ProtectionScenePhase,
};
use crux_core::Command;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(transparent)]
pub struct Secret(pub String);
impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("[redacted]")
    }
}
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum ImmichLockedState {
    #[default]
    Locked,
    Connecting,
    Open,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedEntry {
    pub id: String,
    pub asset: StoredAsset,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedImageAccess {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "entryID")]
    pub entry_id: String,
    #[serde(rename = "grantID")]
    pub grant_id: String,
    #[serde(rename = "sceneID")]
    pub scene_id: String,
    pub generation: u64,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedImageTicket {
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
    pub expected_revision: String,
    pub request: HttpRequest,
}
impl std::fmt::Debug for ImmichLockedImageTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ImmichLockedImageTicket([redacted])")
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedImageResult {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "stagedID")]
    pub staged_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichLockedView {
    pub state: ImmichLockedState,
    pub generation: u64,
    #[serde(rename = "leaseID")]
    pub lease_id: u64,
    #[serde(rename = "sceneID", skip_serializing_if = "Option::is_none")]
    pub scene_id: Option<String>,
    #[serde(rename = "grantID", skip_serializing_if = "Option::is_none")]
    pub grant_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entries: Option<Vec<ImmichLockedEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<ImmichLockedImageAccess>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_lock_confirmed: Option<bool>,
}
#[derive(Clone)]
pub struct DedicatedSession {
    ordinary: Session,
    token: Secret,
}
impl std::fmt::Debug for DedicatedSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DedicatedSession([redacted])")
    }
}
impl DedicatedSession {
    fn request(&self, path: &str, method: &str, body: Option<Value>) -> HttpRequest {
        let mut request = self.ordinary.request(path, method, body);
        request.headers.remove("x-api-key");
        request
            .headers
            .insert("Authorization".into(), format!("Bearer {}", self.token.0));
        request
    }
}
#[derive(Debug, Clone)]
pub struct OpenedSession {
    pub session: DedicatedSession,
    pub entries: Vec<ImmichLockedEntry>,
    pub lease_deadline: std::time::Instant,
    pub hard_deadline: std::time::Instant,
}
#[derive(Default)]
pub struct ImmichLockedModel {
    pub generation: Arc<AtomicU64>,
    phase: ProtectionScenePhase,
    active_scene: Option<String>,
    state: ImmichLockedState,
    scene_id: Option<String>,
    grant_id: Option<String>,
    session: Option<DedicatedSession>,
    entries: Vec<ImmichLockedEntry>,
    pending: Option<ImmichLockedImageTicket>,
    image: Option<ImmichLockedImageAccess>,
    lease_id: u64,
    hard_deadline: Option<std::time::Instant>,
    lease_deadline: Option<std::time::Instant>,
    error: Option<String>,
    remote_lock_confirmed: Option<bool>,
    used_ids: BTreeSet<String>,
}
impl std::fmt::Debug for ImmichLockedModel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ImmichLockedModel([redacted])")
    }
}
#[derive(Debug, Clone, Copy)]
pub enum LockedFailure {
    Authentication,
    PinNotSet,
    PasswordUnavailable,
}
impl LockedFailure {
    fn message(self) -> &'static str {
        match self {
            Self::Authentication => ERROR,
            Self::PinNotSet => {
                "Immich に PIN が設定されていません。Immich で設定してから開いてください。"
            }
            Self::PasswordUnavailable => {
                "この接続ではパスワード認証を利用できません。OAuth によるログインは未対応です。"
            }
        }
    }
}
impl From<String> for LockedFailure {
    fn from(_: String) -> Self {
        Self::Authentication
    }
}
impl From<&str> for LockedFailure {
    fn from(_: &str) -> Self {
        Self::Authentication
    }
}
const ERROR: &str =
    "ロックされた写真を確認できません。接続・パスワード認証・PIN を確認してください。";
fn epoch(model: &ImmichLockedModel) -> u64 {
    model.generation.load(Ordering::SeqCst)
}
fn check(generation: &AtomicU64, expected: u64) -> Result<(), String> {
    if generation.load(Ordering::SeqCst) == expected {
        Ok(())
    } else {
        Err(ERROR.into())
    }
}
async fn http(ctx: &Context, request: HttpRequest) -> Result<HttpResponse, String> {
    let response: HttpResponse = io(ctx, ShellOperation::Http(request))
        .await
        .map_err(|_| ERROR)?;
    if (200..300).contains(&response.status) {
        Ok(response)
    } else {
        Err(ERROR.into())
    }
}
async fn guarded(
    ctx: &Context,
    generation: &AtomicU64,
    expected: u64,
    request: HttpRequest,
) -> Result<Value, String> {
    check(generation, expected)?;
    let response = http(ctx, request).await?;
    check(generation, expected)?;
    Ok(response.body)
}
async fn status(
    ctx: &Context,
    generation: &AtomicU64,
    expected: u64,
    session: &DedicatedSession,
) -> Result<std::time::Instant, String> {
    let value = guarded(
        ctx,
        generation,
        expected,
        session.request("auth/status", "GET", None),
    )
    .await?;
    if value["isElevated"] != true || value["pinCode"] != true {
        return Err(ERROR.into());
    }
    let now = i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| ERROR)?
            .as_millis(),
    )
    .map_err(|_| ERROR)?;
    let mut lease = 30_000_i64;
    for field in ["pinExpiresAt", "expiresAt"] {
        if let Some(raw) = value[field].as_str() {
            let expiry = chrono::DateTime::parse_from_rfc3339(raw)
                .map_err(|_| ERROR)?
                .timestamp_millis();
            lease = lease.min(expiry.saturating_sub(now).saturating_sub(5_000));
        }
    }
    let milliseconds = u64::try_from(lease).ok().filter(|n| *n > 0).ok_or(ERROR)?;
    Ok(std::time::Instant::now() + std::time::Duration::from_millis(milliseconds))
}
async fn cleanup(ctx: &Context, session: &DedicatedSession) -> bool {
    let locked = http(ctx, session.request("auth/session/lock", "POST", None))
        .await
        .is_ok();
    let logout = http(ctx, session.request("auth/logout", "POST", None))
        .await
        .is_ok_and(|r| r.body["successful"] == true);
    locked || logout
}
fn denied(model: &Model, key: &AssetKey) -> bool {
    model.protection.membership_uncertain
        || model.protection.denied.contains(key)
        || model
            .state
            .protected_entries
            .iter()
            .any(|entry| &entry.key == key)
}
fn bound(model: &Model, session: &DedicatedSession) -> bool {
    model.session.as_ref().is_some_and(|s| {
        s.endpoint == session.ordinary.endpoint
            && s.user_id == session.ordinary.user_id
            && s.scope == session.ordinary.scope
    }) && model
        .state
        .connection
        .as_ref()
        .is_some_and(|c| c.address == session.ordinary.endpoint)
        && !model.protection.membership_uncertain
}
#[must_use]
pub fn view(model: &Model) -> ImmichLockedView {
    let locked = &model.immich_locked;
    let open = current(model);
    ImmichLockedView {
        state: if open {
            ImmichLockedState::Open
        } else if locked.state == ImmichLockedState::Connecting {
            ImmichLockedState::Connecting
        } else {
            ImmichLockedState::Locked
        },
        generation: epoch(locked),
        lease_id: locked.lease_id,
        scene_id: open.then(|| locked.scene_id.clone()).flatten(),
        grant_id: open.then(|| locked.grant_id.clone()).flatten(),
        entries: open.then(|| {
            locked
                .entries
                .iter()
                .filter(|e| !denied(model, &e.asset.key))
                .cloned()
                .collect()
        }),
        image: open
            .then(|| locked.image.clone())
            .flatten()
            .filter(|image| {
                locked
                    .entries
                    .iter()
                    .any(|e| e.id == image.entry_id && !denied(model, &e.asset.key))
            }),
        error: locked.error.clone(),
        remote_lock_confirmed: locked.remote_lock_confirmed,
    }
}
fn release(staged_id: String) -> Command<crate::app::Effect, Event> {
    Command::new(move |ctx| async move {
        let _: Result<Value, _> =
            io(&ctx, ShellOperation::ReleaseImmichLockedImage { staged_id }).await;
    })
}
/// Local revocation is synchronous; cleanup never restores capabilities.
pub fn close(model: &mut Model) -> Command<crate::app::Effect, Event> {
    if model.immich_locked.state == ImmichLockedState::Locked
        && model.immich_locked.session.is_none()
    {
        return Command::done();
    }
    let locked = &mut model.immich_locked;
    locked.generation.fetch_add(1, Ordering::SeqCst);
    let revoked_generation = epoch(locked);
    let generation = revoked_generation;
    let session = locked.session.take();
    locked.state = ImmichLockedState::Locked;
    locked.scene_id = None;
    locked.grant_id = None;
    locked.entries.clear();
    locked.pending = None;
    locked.image = None;
    locked.remote_lock_confirmed = None;
    locked.hard_deadline = None;
    locked.lease_deadline = None;
    Command::new(move |ctx| async move {
        let _: Result<Value, _> = io(
            &ctx,
            ShellOperation::ReleaseImmichLockedImages {
                generation: revoked_generation.saturating_sub(1),
            },
        )
        .await;
        if let Some(session) = session {
            let confirmed = cleanup(&ctx, &session).await;
            ctx.send_event(Event::ImmichLockedClosed {
                generation,
                confirmed,
            });
        }
    })
}

async fn open_session(
    ctx: &Context,
    ordinary: Session,
    generation: Arc<AtomicU64>,
    expected: u64,
    email: Secret,
    password: Secret,
    pin: Secret,
) -> Result<OpenedSession, LockedFailure> {
    let mut features_request = ordinary.request("server/features", "GET", None);
    features_request.headers.remove("x-api-key");
    let features = guarded(ctx, &generation, expected, features_request).await?;
    if features["passwordLogin"] != true {
        return Err(LockedFailure::PasswordUnavailable);
    }
    let mut login = ordinary.request(
        "auth/login",
        "POST",
        Some(json!({"email":email.0,"password":password.0})),
    );
    login.headers.remove("x-api-key");
    check(&generation, expected)?;
    // Parse the token even after local cancellation, so a late login can be cleaned up.
    let response = http(ctx, login).await?;
    let token = response.body["accessToken"]
        .as_str()
        .filter(|s| !s.is_empty() && !s.contains(['\r', '\n']))
        .ok_or(ERROR)?
        .to_owned();
    let session = DedicatedSession {
        ordinary,
        token: Secret(token),
    };
    let hard_deadline = std::time::Instant::now() + std::time::Duration::from_mins(15);
    let result =
        open_authenticated(ctx, &session, &generation, expected, &response.body, pin).await;
    match result {
        Ok((entries, lease_deadline)) => Ok(OpenedSession {
            session,
            entries,
            lease_deadline,
            hard_deadline,
        }),
        Err(failure) => {
            cleanup(ctx, &session).await;
            Err(failure)
        }
    }
}
async fn open_authenticated(
    ctx: &Context,
    session: &DedicatedSession,
    generation: &AtomicU64,
    expected: u64,
    login: &Value,
    pin: Secret,
) -> Result<(Vec<ImmichLockedEntry>, std::time::Instant), LockedFailure> {
    check(generation, expected)?;
    if login["userId"].as_str() != Some(&session.ordinary.user_id) {
        return Err(ERROR.into());
    }
    let user = guarded(
        ctx,
        generation,
        expected,
        session.request("users/me", "GET", None),
    )
    .await?;
    if user["id"].as_str() != Some(&session.ordinary.user_id) {
        return Err(ERROR.into());
    }
    let auth = guarded(
        ctx,
        generation,
        expected,
        session.request("auth/status", "GET", None),
    )
    .await?;
    if auth["password"] != true {
        return Err(LockedFailure::PasswordUnavailable);
    }
    if auth["pinCode"] != true {
        return Err(LockedFailure::PinNotSet);
    }
    guarded(
        ctx,
        generation,
        expected,
        session.request(
            "auth/session/unlock",
            "POST",
            Some(json!({"pinCode":pin.0})),
        ),
    )
    .await?;
    status(ctx, generation, expected, session).await?;
    let mut entries = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen = BTreeSet::new();
    for _ in 0..100 {
        let mut body = json!({"size":100,"withExif":true,"filter":{"visibility":{"in":["locked"]},"trashedAt":{"eq":null}},"orderBy":{"field":"fileCreatedAt","direction":"desc"}});
        if let Some(c) = &cursor {
            body["cursor"] = json!(c);
        }
        let page = guarded(
            ctx,
            generation,
            expected,
            session.request("search/metadata", "POST", Some(body)),
        )
        .await?;
        let assets: Vec<Asset> =
            serde_json::from_value(page["assets"]["items"].clone()).map_err(|_| ERROR)?;
        for asset in assets {
            crate::immich::valid_id(&asset.id).map_err(|_| ERROR)?;
            if asset.owner_id != session.ordinary.user_id
                || asset.is_trashed
                || asset.visibility.as_deref() != Some("locked")
            {
                return Err(ERROR.into());
            }
            if !seen.insert(asset.id.clone()) {
                return Err(ERROR.into());
            }
            entries.push(ImmichLockedEntry {
                id: asset.id.clone(),
                asset: asset.record(&session.ordinary.scope, None, None),
            });
        }
        cursor = page["assets"]["nextCursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            return Ok((entries, status(ctx, generation, expected, session).await?));
        }
    }
    Err(ERROR.into())
}
fn current(model: &Model) -> bool {
    let locked = &model.immich_locked;
    locked.state == ImmichLockedState::Open
        && locked.phase == ProtectionScenePhase::Active
        && locked.scene_id == locked.active_scene
        && locked.session.as_ref().is_some_and(|s| bound(model, s))
        && locked
            .hard_deadline
            .is_some_and(|deadline| std::time::Instant::now() < deadline)
        && locked
            .lease_deadline
            .is_some_and(|deadline| std::time::Instant::now() < deadline)
}
fn timers(
    model: &mut Model,
    lease_deadline: std::time::Instant,
) -> Command<crate::app::Effect, Event> {
    let locked = &mut model.immich_locked;
    let remaining = locked.hard_deadline.map_or(0, |deadline| {
        u32::try_from(
            deadline
                .saturating_duration_since(std::time::Instant::now())
                .as_millis(),
        )
        .unwrap_or(u32::MAX)
    });
    let lease_ms = u32::try_from(
        lease_deadline
            .saturating_duration_since(std::time::Instant::now())
            .as_millis(),
    )
    .unwrap_or(u32::MAX);
    let milliseconds = lease_ms.min(remaining).min(30_000);
    if milliseconds == 0 {
        return close(model);
    }
    locked.lease_id = locked.lease_id.wrapping_add(1);
    locked.lease_deadline =
        Some(std::time::Instant::now() + std::time::Duration::from_millis(u64::from(milliseconds)));
    let grant_id = locked.grant_id.clone().unwrap_or_default();
    let generation = epoch(locked);
    let lease_id = locked.lease_id;
    let now_ms = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(u64::MAX);
    let deadline_unix_milliseconds = now_ms.saturating_add(u64::from(milliseconds));
    Command::new(move |ctx| async move {
        let _: Result<Value, _> = io(
            &ctx,
            ShellOperation::ScheduleImmichLockedExpiry {
                grant_id: grant_id.clone(),
                generation,
                lease_id,
                milliseconds,
                deadline_unix_milliseconds,
            },
        )
        .await;
        let _: Result<Value, _> = io(
            &ctx,
            ShellOperation::ScheduleImmichLockedCheck {
                grant_id,
                generation,
                lease_id,
                milliseconds: milliseconds.saturating_mul(2) / 3,
                deadline_unix_milliseconds: now_ms
                    .saturating_add(u64::from(milliseconds.saturating_mul(2) / 3)),
            },
        )
        .await;
    })
}
fn ticket_current(model: &Model, ticket: &ImmichLockedImageTicket) -> bool {
    current(model)
        && epoch(&model.immich_locked) == ticket.generation
        && model.immich_locked.grant_id.as_ref() == Some(&ticket.grant_id)
        && model.immich_locked.scene_id.as_ref() == Some(&ticket.scene_id)
        && model
            .immich_locked
            .pending
            .as_ref()
            .is_some_and(|p| p.request_id == ticket.request_id)
        && !denied(model, &ticket.key)
        && model.immich_locked.entries.iter().any(|e| {
            e.id == ticket.entry_id
                && e.asset.key == ticket.key
                && e.asset.revision == ticket.expected_revision
        })
}
async fn fresh(
    ctx: &Context,
    generation: &AtomicU64,
    ticket: &ImmichLockedImageTicket,
    session: &DedicatedSession,
) -> Result<(), String> {
    let value = guarded(
        ctx,
        generation,
        ticket.generation,
        session.request(&format!("assets/{}", ticket.key.asset_id), "GET", None),
    )
    .await?;
    let asset: Asset = serde_json::from_value(value).map_err(|_| ERROR)?;
    if asset.id != ticket.key.asset_id
        || asset.owner_id != session.ordinary.user_id
        || asset.is_trashed
        || asset.visibility.as_deref() != Some("locked")
        || asset.record(&session.ordinary.scope, None, None).revision != ticket.expected_revision
    {
        return Err(ERROR.into());
    }
    Ok(())
}
async fn read_image(
    ctx: &Context,
    generation: &AtomicU64,
    ticket: &ImmichLockedImageTicket,
    session: &DedicatedSession,
) -> Result<ImmichLockedImageResult, String> {
    status(ctx, generation, ticket.generation, session).await?;
    fresh(ctx, generation, ticket, session).await?;
    let result: ImmichLockedImageResult = io(
        ctx,
        ShellOperation::ReadImmichLockedImage {
            ticket: ticket.clone(),
        },
    )
    .await
    .map_err(|_| ERROR)?;
    let verified = async {
        check(generation, ticket.generation)?;
        if result.request_id != ticket.request_id || result.staged_id.is_empty() {
            return Err(ERROR.into());
        }
        fresh(ctx, generation, ticket, session).await?;
        status(ctx, generation, ticket.generation, session).await?;
        Ok::<(), String>(())
    }
    .await;
    if verified.is_err() {
        let _: Result<Value, _> = io(
            ctx,
            ShellOperation::ReleaseImmichLockedImage {
                staged_id: result.staged_id.clone(),
            },
        )
        .await;
    }
    verified.map(|()| result)
}

pub fn update(event: Event, model: &mut Model) -> Option<Command<crate::app::Effect, Event>> {
    Some(match event {
        Event::OpenImmichLocked {
            scene_id,
            request_id,
            email,
            password,
            pin_code,
        } => begin(model, scene_id, request_id, email, password, pin_code),
        Event::CloseImmichLocked => close(model),
        Event::ImmichLockedSceneChanged { scene_id, phase } => {
            scene_changed(model, scene_id, phase)
        }
        Event::ImmichLockedOpened { generation, result } => opened(model, generation, result),
        Event::ImmichLockedClosed {
            generation,
            confirmed,
        } => {
            if epoch(&model.immich_locked) == generation {
                model.immich_locked.remote_lock_confirmed = Some(confirmed);
            }
            Command::done()
        }
        Event::ExpireImmichLocked {
            grant_id,
            generation,
            lease_id,
        } => {
            if matching_lease(model, &grant_id, generation, lease_id) {
                close(model)
            } else {
                Command::done()
            }
        }
        Event::CheckImmichLockedSession {
            grant_id,
            generation,
            lease_id,
        } => check_session(model, grant_id, generation, lease_id),
        Event::ImmichLockedChecked {
            grant_id,
            generation,
            lease_id,
            result,
        } => {
            if !matching_lease(model, &grant_id, generation, lease_id) {
                Command::done()
            } else if !current(model) {
                close(model)
            } else if let Some(lease) = result {
                timers(model, lease)
            } else {
                model.immich_locked.error = Some(ERROR.into());
                close(model)
            }
        }
        Event::RequestImmichLockedImage {
            entry_id,
            grant_id,
            request_id,
        } => request_image(model, entry_id, grant_id, request_id),
        Event::ImmichLockedImageRead { ticket, result } => image_read(model, ticket, result),
        Event::ImmichLockedImagePublished {
            ticket,
            staged_id,
            approved,
        } => {
            if approved && ticket_current(model, &ticket) {
                model.immich_locked.image = Some(ImmichLockedImageAccess {
                    request_id: ticket.request_id,
                    entry_id: ticket.entry_id,
                    grant_id: ticket.grant_id,
                    scene_id: ticket.scene_id,
                    generation: ticket.generation,
                    staged_id,
                });
                Command::done()
            } else if ticket_current(model, &ticket) {
                release(staged_id).and(close(model))
            } else {
                release(staged_id)
            }
        }
        _ => return None,
    })
}
fn scene_changed(
    model: &mut Model,
    scene_id: String,
    phase: ProtectionScenePhase,
) -> Command<crate::app::Effect, Event> {
    if crate::immich::valid_id(&scene_id).is_err() {
        return Command::done();
    }
    if phase == ProtectionScenePhase::Active {
        let cleanup = if model
            .immich_locked
            .active_scene
            .as_ref()
            .is_some_and(|owner| owner != &scene_id)
        {
            close(model)
        } else {
            Command::done()
        };
        model.immich_locked.active_scene = Some(scene_id);
        model.immich_locked.phase = phase;
        cleanup
    } else if model.immich_locked.active_scene.as_ref() == Some(&scene_id) {
        model.immich_locked.phase = phase;
        close(model)
    } else {
        Command::done()
    }
}
fn matching_lease(model: &Model, grant_id: &str, generation: u64, lease_id: u64) -> bool {
    epoch(&model.immich_locked) == generation
        && model.immich_locked.grant_id.as_deref() == Some(grant_id)
        && model.immich_locked.lease_id == lease_id
}
fn begin(
    model: &mut Model,
    scene_id: String,
    request_id: String,
    email: Secret,
    password: Secret,
    pin_code: Secret,
) -> Command<crate::app::Effect, Event> {
    let released = close(model);
    if model.immich_locked.phase != ProtectionScenePhase::Active
        || model.immich_locked.active_scene.as_ref() != Some(&scene_id)
        || model.busy
        || model.protection.membership_uncertain
        || crate::immich::valid_id(&scene_id).is_err()
        || crate::immich::valid_id(&request_id).is_err()
        || !model.immich_locked.used_ids.insert(request_id.clone())
        || email.0.trim().is_empty()
        || password.0.is_empty()
        || pin_code.0.len() != 6
        || !pin_code.0.bytes().all(|b| b.is_ascii_digit())
    {
        model.immich_locked.error = Some(ERROR.into());
        return released;
    }
    let Some(ordinary) = model
        .session
        .clone()
        .filter(|s| s.version.major == 3 && s.version.minor >= 2)
    else {
        model.immich_locked.error = Some(ERROR.into());
        return released;
    };
    model
        .immich_locked
        .generation
        .fetch_add(1, Ordering::SeqCst);
    model.immich_locked.state = ImmichLockedState::Connecting;
    model.immich_locked.scene_id = Some(scene_id);
    model.immich_locked.grant_id = Some(request_id);
    model.immich_locked.error = None;
    model.immich_locked.remote_lock_confirmed = None;
    let generation = epoch(&model.immich_locked);
    let shared = model.immich_locked.generation.clone();
    released.and(Command::new(move |ctx| async move {
        let result = open_session(
            &ctx, ordinary, shared, generation, email, password, pin_code,
        )
        .await;
        ctx.send_event(Event::ImmichLockedOpened { generation, result });
    }))
}
fn opened(
    model: &mut Model,
    generation: u64,
    result: Result<OpenedSession, LockedFailure>,
) -> Command<crate::app::Effect, Event> {
    let mut result = match result {
        Ok(result) => result,
        Err(failure) => {
            if epoch(&model.immich_locked) == generation {
                model.immich_locked.error = Some(failure.message().into());
                let command = close(model);
                model.immich_locked.remote_lock_confirmed = Some(false);
                return command;
            }
            return Command::done();
        }
    };
    if epoch(&model.immich_locked) != generation
        || model.immich_locked.phase != ProtectionScenePhase::Active
        || model.immich_locked.scene_id != model.immich_locked.active_scene
        || !bound(model, &result.session)
    {
        return Command::new(move |ctx| async move {
            cleanup(&ctx, &result.session).await;
        });
    }
    result
        .entries
        .retain(|entry| !denied(model, &entry.asset.key));
    model.immich_locked.entries = result.entries;
    model.immich_locked.session = Some(result.session);
    model.immich_locked.state = ImmichLockedState::Open;
    model.immich_locked.hard_deadline = Some(result.hard_deadline);
    timers(model, result.lease_deadline)
}
fn check_session(
    model: &mut Model,
    grant_id: String,
    generation: u64,
    lease_id: u64,
) -> Command<crate::app::Effect, Event> {
    if !matching_lease(model, &grant_id, generation, lease_id) {
        return Command::done();
    }
    if !current(model) {
        return close(model);
    }
    let Some(session) = model.immich_locked.session.clone() else {
        return close(model);
    };
    let shared = model.immich_locked.generation.clone();
    let pending = model.immich_locked.pending.clone();
    Command::new(move |ctx| async move {
        let result = async {
            if let Some(ticket) = &pending {
                fresh(&ctx, &shared, ticket, &session).await?;
            }
            status(&ctx, &shared, generation, &session).await
        }
        .await
        .ok();
        ctx.send_event(Event::ImmichLockedChecked {
            grant_id,
            generation,
            lease_id,
            result,
        });
    })
}
fn request_image(
    model: &mut Model,
    entry_id: String,
    grant_id: String,
    request_id: String,
) -> Command<crate::app::Effect, Event> {
    if !current(model) {
        return close(model);
    }
    if model.immich_locked.grant_id.as_ref() != Some(&grant_id)
        || crate::immich::valid_id(&request_id).is_err()
        || !model.immich_locked.used_ids.insert(request_id.clone())
    {
        return Command::done();
    }
    let Some(entry) = model
        .immich_locked
        .entries
        .iter()
        .find(|e| e.id == entry_id && !denied(model, &e.asset.key))
        .cloned()
    else {
        return Command::done();
    };
    let Some(session) = model.immich_locked.session.clone() else {
        return close(model);
    };
    let Ok(mut request) = session
        .ordinary
        .preview_request(&entry.asset.key.asset_id, true)
    else {
        return Command::done();
    };
    request.headers.remove("x-api-key");
    request.headers.insert(
        "Authorization".into(),
        format!("Bearer {}", session.token.0),
    );
    let ticket = ImmichLockedImageTicket {
        request_id,
        entry_id,
        grant_id,
        scene_id: model.immich_locked.scene_id.clone().unwrap_or_default(),
        generation: epoch(&model.immich_locked),
        key: entry.asset.key,
        expected_revision: entry.asset.revision,
        request,
    };
    let old = model.immich_locked.image.take();
    model.immich_locked.pending = Some(ticket.clone());
    let shared = model.immich_locked.generation.clone();
    let command = Command::new(move |ctx| async move {
        let result = read_image(&ctx, &shared, &ticket, &session).await.ok();
        ctx.send_event(Event::ImmichLockedImageRead { ticket, result });
    });
    if let Some(old) = old {
        release(old.staged_id).and(command)
    } else {
        command
    }
}
fn image_read(
    model: &mut Model,
    ticket: ImmichLockedImageTicket,
    result: Option<ImmichLockedImageResult>,
) -> Command<crate::app::Effect, Event> {
    let Some(result) = result else {
        if ticket_current(model, &ticket) {
            model.immich_locked.error = Some(ERROR.into());
            return close(model);
        }
        return Command::done();
    };
    if !ticket_current(model, &ticket) || result.request_id != ticket.request_id {
        return release(result.staged_id);
    }
    let Some(session) = model.immich_locked.session.clone() else {
        return release(result.staged_id);
    };
    let shared = model.immich_locked.generation.clone();
    let staged_id = result.staged_id;
    Command::new(move |ctx| async move {
        let native: Result<ImmichLockedImageResult, _> = io(
            &ctx,
            ShellOperation::PublishImmichLockedImage {
                ticket: ticket.clone(),
                staged_id: staged_id.clone(),
            },
        )
        .await;
        let approved = native
            .is_ok_and(|r| r.request_id == ticket.request_id && r.staged_id == staged_id)
            && fresh(&ctx, &shared, &ticket, &session).await.is_ok()
            && status(&ctx, &shared, ticket.generation, &session)
                .await
                .is_ok();
        ctx.send_event(Event::ImmichLockedImagePublished {
            ticket,
            staged_id,
            approved,
        });
    })
}
/// Every canonical mutation/provider update revokes the isolated surface before async work.
#[must_use]
pub fn invalidates(event: &Event) -> bool {
    !matches!(
        event,
        Event::Browse { .. }
            | Event::ChoosePreview { .. }
            | Event::BeginProtectedAccess { .. }
            | Event::LockProtectedAccess
            | Event::ProtectedSceneChanged { .. }
            | Event::ProtectedAuthCompleted { .. }
            | Event::RequestProtectedImage { .. }
            | Event::ProtectedImageRead { .. }
            | Event::ProtectedImagePublished { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn open_model() -> Model {
        let ordinary = Session {
            endpoint: "https://fixture.example/api".into(),
            key: "key".into(),
            user_id: "owner".into(),
            scope: "scope".into(),
            version: crate::immich::Version {
                major: 3,
                minor: 2,
                patch: 4,
            },
        };
        let mut model = Model::default();
        model.state.connection = Some(crate::app::ConnectionSettings {
            address: ordinary.endpoint.clone(),
            allow_http: false,
            credential_id: "credential".into(),
        });
        model.session = Some(ordinary.clone());
        model.immich_locked.phase = ProtectionScenePhase::Active;
        model.immich_locked.session = Some(DedicatedSession {
            ordinary,
            token: Secret("secret".into()),
        });
        model.immich_locked.state = ImmichLockedState::Open;
        model.immich_locked.grant_id = Some("grant".into());
        model.immich_locked.hard_deadline =
            Some(std::time::Instant::now() + std::time::Duration::from_mins(15));
        model.immich_locked.lease_deadline = Some(std::time::Instant::now());
        model
    }
    #[test]
    fn expired_display_lease_cannot_be_renewed_by_delayed_refresh_response() {
        let mut model = open_model();
        let _ = update(
            Event::ImmichLockedChecked {
                grant_id: "grant".into(),
                generation: 0,
                lease_id: 0,
                result: Some(std::time::Instant::now() + std::time::Duration::from_secs(30)),
            },
            &mut model,
        );
        assert_eq!(model.immich_locked.state, ImmichLockedState::Locked);
        assert!(model.immich_locked.session.is_none());
    }
    #[test]
    fn hard_deadline_and_delayed_open_evidence_never_start_new_display_lease() {
        let mut model = open_model();
        model.immich_locked.hard_deadline = Some(std::time::Instant::now());
        let _ = timers(
            &mut model,
            std::time::Instant::now() + std::time::Duration::from_secs(30),
        );
        assert_eq!(model.immich_locked.state, ImmichLockedState::Locked);
        let mut model = open_model();
        let _ = timers(&mut model, std::time::Instant::now());
        assert_eq!(model.immich_locked.state, ImmichLockedState::Locked);
    }
}
