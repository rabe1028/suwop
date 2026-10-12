use crux_core::{Command, capability::Operation, command::CommandContext, macros::effect};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    domain::{
        LibrarySnapshot, Provider, ScanAccess, TransferIntent, TransferReceipt, UnifiedPhoto,
        catalog,
    },
    immich::{HttpRequest, Session},
};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionSettings {
    pub address: String,
    #[serde(rename = "allowHTTP")]
    pub allow_http: bool,
    #[serde(rename = "credentialID")]
    pub credential_id: String,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SavedLibrary {
    pub schema_version: u32,
    pub apple_scope: String,
    pub connection: Option<ConnectionSettings>,
    #[serde(default)]
    pub snapshots: Vec<LibrarySnapshot>,
    #[serde(default)]
    pub receipts: Vec<TransferReceipt>,
    #[serde(default)]
    pub albums: Vec<crate::albums::AlbumSnapshot>,
    #[serde(default)]
    pub pending_uploads: Vec<crate::immich::PendingUpload>,
    #[serde(default)]
    pub upload_intents: Vec<crate::immich::UploadIntent>,
    #[serde(default)]
    pub trash: Option<crate::trash::TrashSnapshot>,
    #[serde(default)]
    pub pending_trash: Vec<crate::trash::TrashOperation>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", content = "data", rename_all = "camelCase")]
pub enum ShellOperation {
    ReadState,
    RandomId,
    Wait {
        milliseconds: u32,
    },
    ConfirmUploadResume {
        prompt: crate::immich::UploadResumePrompt,
    },
    ConfirmTrash {
        prompt: crate::trash::TrashPrompt,
    },
    ConfirmForgetUpload {
        prompt: crate::immich::UploadForgetPrompt,
    },
    ConfirmForgetUploadIntent {
        prompt: crate::immich::UploadIntentForgetPrompt,
    },
    Persist(SavedLibrary),
    ReadCredential {
        account: String,
    },
    SaveCredential {
        account: String,
        key: String,
    },
    RemoveCredential {
        account: String,
    },
    Workspace {
        id: String,
    },
    Cleanup {
        path: String,
    },
    CopyFile {
        source: String,
        destination: String,
    },
    ShareFiles {
        files: Vec<crate::sharing::ShareFile>,
    },
    PlayMedia {
        plan: crate::media::PlaybackPlan,
    },
    AppleScan {
        scope: String,
        permission: bool,
    },
    AppleExport {
        keys: Vec<crate::domain::AssetKey>,
        directory: String,
    },
    AppleCurrentImage {
        asset: crate::domain::StoredAsset,
        directory: String,
    },
    InspectCurrentImage {
        path: String,
    },
    InspectImageEncoding {
        path: String,
    },
    RenderCurrentImage {
        path: String,
        destination: String,
        plan: crate::sharing::CurrentImageRenderPlan,
    },
    AppleImport(crate::domain::AppleImportPlan),
    AppleTrash {
        assets: Vec<crate::domain::StoredAsset>,
    },
    AppleFavorite {
        keys: Vec<crate::domain::AssetKey>,
        value: bool,
    },
    AppleMetadata {
        keys: Vec<crate::domain::AssetKey>,
        change: crate::metadata::MetadataChange,
    },
    AppleEditOpen {
        asset: crate::domain::StoredAsset,
        directory: String,
    },
    EditImage {
        presentation: crate::editing::ImageEditPresentation,
    },
    AppleEditSave {
        token: String,
        asset: crate::domain::StoredAsset,
        plan: crate::editing::ImageRenderPlan,
    },
    AppleEditClose {
        token: String,
    },
    AppleReversionInspect {
        asset: crate::domain::StoredAsset,
    },
    ConfirmReversion {
        prompt: crate::editing::ReversionPrompt,
    },
    AppleRevert {
        asset: crate::domain::StoredAsset,
    },
    AppleAlbums {
        scope: String,
    },
    AppleAlbumCreate {
        scope: String,
        title: String,
    },
    AppleAlbumEdit {
        key: crate::albums::AlbumKey,
        edit: crate::albums::AlbumEdit,
    },
    Http(HttpRequest),
    HashFile {
        path: String,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ShellResponse {
    pub value: Option<Value>,
    pub error: Option<String>,
}
impl Operation for ShellOperation {
    type Output = ShellResponse;
}
#[effect(typegen)]
pub enum Effect {
    Io(ShellOperation),
}
pub type Context = CommandContext<Effect, Event>;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    ChoosePreview {
        anchor: crate::domain::AssetKey,
        key: crate::domain::AssetKey,
    },
    EditImage {
        key: crate::domain::AssetKey,
        id: String,
    },
    RevertImage {
        key: crate::domain::AssetKey,
        id: String,
    },
    SetMetadata {
        keys: Vec<crate::domain::AssetKey>,
        input: crate::metadata::MetadataInput,
    },
    Play {
        keys: Vec<crate::domain::AssetKey>,
        id: String,
    },
    Share {
        keys: Vec<crate::domain::AssetKey>,
        id: String,
    },
    ShareCurrentImage {
        key: crate::domain::AssetKey,
        id: String,
    },
    RefreshAlbums,
    RefreshTrash {
        now: f64,
    },
    ChangeTrash {
        keys: Vec<crate::domain::AssetKey>,
        action: crate::trash::TrashAction,
        id: String,
    },
    ResolveTrash {
        id: String,
    },
    CreateAlbum {
        provider: Provider,
        title: String,
    },
    EditAlbum {
        key: crate::albums::AlbumKey,
        edit: crate::albums::AlbumEdit,
    },
    Browse {
        options: crate::browser::BrowserOptions,
    },
    SetFavorite {
        keys: Vec<crate::domain::AssetKey>,
        value: bool,
    },
    Initialize {
        scope: String,
    },
    Refresh {
        permission: bool,
        now: f64,
    },
    Configure {
        address: String,
        key: String,
        #[serde(rename = "allowHTTP")]
        allow_http: bool,
        id: String,
        now: f64,
    },
    Disconnect,
    Index {
        id: String,
    },
    Copy {
        keys: Vec<crate::domain::AssetKey>,
        intent: TransferIntent,
        id: String,
        now: f64,
    },
    ForgetUploadRecord {
        key: crate::domain::AssetKey,
    },
    ForgetUploadIntent {
        scope: String,
        token: String,
    },
    CompleteMove {
        id: String,
        workspace: String,
    },
    AppleChanged,
    #[serde(skip)]
    Progress {
        state: SavedLibrary,
        status: String,
    },
    #[serde(skip)]
    Finished {
        state: SavedLibrary,
        session: Option<Session>,
        status: String,
        error: Option<String>,
        preview_to_select: Option<crate::domain::AssetKey>,
    },
}
#[derive(Debug, Default)]
pub struct Model {
    pub preview_preferences: Vec<crate::domain::AssetKey>,
    pub browser: crate::browser::BrowserOptions,
    pub state: SavedLibrary,
    pub session: Option<Session>,
    pub busy: bool,
    pub ready: bool,
    pub status: String,
    pub error: Option<String>,
    pub changed_during_work: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ViewModel {
    pub preview_choices: std::collections::BTreeMap<String, Vec<crate::media::PreviewChoice>>,
    pub remote_version: Option<crate::immich::Version>,
    pub editing_targets: std::collections::BTreeMap<String, Vec<crate::editing::EditingTarget>>,
    pub metadata_targets: std::collections::BTreeMap<String, Vec<crate::metadata::MetadataTarget>>,
    pub preview_sources: std::collections::BTreeMap<String, crate::domain::AssetKey>,
    pub media: std::collections::BTreeMap<String, crate::media::PlaybackKind>,
    pub albums: Vec<crate::albums::AlbumView>,
    pub browser: crate::browser::BrowserView,
    pub state: SavedLibrary,
    pub photos: Vec<UnifiedPhoto>,
    pub busy: bool,
    pub status: String,
    pub error: Option<String>,
    pub server_version: Option<String>,
    pub can_transfer: bool,
    pub pending_apple_count: usize,
    pub move_blockers: std::collections::BTreeMap<String, Vec<String>>,
}
#[derive(Debug, Default)]
pub struct Suwop;
impl crux_core::App for Suwop {
    type Event = Event;
    type Model = Model;
    type ViewModel = ViewModel;
    type Effect = Effect;
    fn update(&self, event: Event, model: &mut Model) -> Command<Effect, Event> {
        match event {
            Event::ChoosePreview { anchor, key } if !model.busy => {
                model.error = choose_preview(model, &anchor, key).err();
                Command::done()
            }
            Event::Browse { options } => {
                model.browser = options;
                Command::done()
            }
            Event::Progress { mut state, status } => {
                if model.changed_during_work {
                    invalidate_apple(&mut state);
                }
                model.state = state;
                model.status = status;
                Command::done()
            }
            Event::Finished {
                mut state,
                session,
                status,
                error,
                preview_to_select,
            } => {
                if model.changed_during_work {
                    invalidate_apple(&mut state);
                }
                model.state = state;
                model.session = session;
                model.status = status;
                model.error = error;
                model.busy = false;
                model.ready = model.state.schema_version == 2;
                update_preview_preferences(model, preview_to_select);
                Command::done()
            }
            Event::AppleChanged => {
                invalidate_apple(&mut model.state);
                model.changed_during_work = model.busy;
                Command::done()
            }
            _ if model.busy => Command::done(),
            event => {
                model.busy = true;
                model.error = None;
                model.changed_during_work = false;
                model.status = "処理中…".into();
                let state = model.state.clone();
                let session = model.session.clone();
                Command::new(move |ctx| async move {
                    let result = crate::workflow::run(&ctx, event, state, session).await;
                    ctx.send_event(Event::Finished {
                        state: result.state,
                        session: result.session,
                        status: result.status,
                        error: result.error,
                        preview_to_select: result.preview_to_select,
                    });
                })
            }
        }
    }
    fn view(&self, model: &Model) -> ViewModel {
        let mut move_blockers = std::collections::BTreeMap::new();
        let can_transfer = model.ready && model.session.is_some() && !model.busy;
        for receipt in &model.state.receipts {
            let mut blockers = receipt.move_blockers();
            if !can_transfer {
                blockers.push("接続または処理状態を確認してください".into());
            }
            if let Some(session) = &model.session {
                let immich_scope = if receipt.destination_provider == Provider::Immich {
                    Some(receipt.destination_scope.as_str())
                } else {
                    receipt
                        .source
                        .first()
                        .filter(|a| a.key.provider == Provider::Immich)
                        .map(|a| a.key.scope.as_str())
                };
                if immich_scope.is_some_and(|scope| scope != session.scope) {
                    blockers.push("転送時と Immich の接続先が異なります".into());
                }
            }
            move_blockers.insert(receipt.id.clone(), blockers);
        }
        let photos = catalog(&model.state.snapshots, &model.state.receipts);
        let preview_access = crate::media::PreviewAccess::new(
            &model.state.snapshots,
            &model.state.apple_scope,
            model.session.as_ref(),
        );
        let preview_choices: std::collections::BTreeMap<_, _> = photos
            .iter()
            .map(|p| {
                (
                    crate::browser::photo_id(p),
                    preview_access.choices(p, &model.preview_preferences),
                )
            })
            .collect();
        let displayed_dates = displayed_dates(&preview_choices);
        let editing_access =
            crate::editing::EditingAccess::new(&model.state.snapshots, &model.state.apple_scope);
        ViewModel {
            remote_version: model.session.as_ref().map(|s| s.version.clone()),
            editing_targets: photos
                .iter()
                .map(|p| (crate::browser::photo_id(p), editing_access.targets(p)))
                .collect(),
            metadata_targets: photos
                .iter()
                .map(|p| {
                    (
                        crate::browser::photo_id(p),
                        crate::metadata::targets(p, &model.state.snapshots),
                    )
                })
                .collect(),
            preview_sources: preview_choices
                .iter()
                .filter_map(|(id, choices)| {
                    crate::media::selected_preview(choices).map(|key| (id.clone(), key))
                })
                .collect(),
            preview_choices,
            media: photos
                .iter()
                .filter_map(|p| {
                    crate::media::kind(p).map(|kind| (crate::browser::photo_id(p), kind))
                })
                .collect(),
            albums: crate::albums::views(&model.state.albums, &photos, &model.state.snapshots),
            browser: crate::browser::browse_with_dates(&photos, &model.browser, &displayed_dates),
            photos,
            pending_apple_count: model
                .state
                .snapshots
                .iter()
                .filter(|s| s.provider == Provider::Apple)
                .flat_map(|s| &s.assets)
                .filter(|a| !a.fingerprints_complete())
                .count(),
            state: model.state.clone(),
            busy: model.busy,
            status: model.status.clone(),
            error: model.error.clone(),
            server_version: model.session.as_ref().map(|s| s.version.description()),
            can_transfer,
            move_blockers,
        }
    }
}
fn displayed_dates(
    previews: &std::collections::BTreeMap<String, Vec<crate::media::PreviewChoice>>,
) -> std::collections::BTreeMap<String, Option<f64>> {
    previews
        .iter()
        .map(|(id, choices)| {
            (
                id.clone(),
                choices
                    .iter()
                    .find(|c| c.selected)
                    .and_then(|c| c.captured_at),
            )
        })
        .collect()
}
fn choose_preview(
    model: &mut Model,
    anchor: &crate::domain::AssetKey,
    key: crate::domain::AssetKey,
) -> Result<(), String> {
    if !model.ready {
        return Err("写真ライブラリを読み込んでください。".into());
    }
    let photos = catalog(&model.state.snapshots, &model.state.receipts);
    let photo = photos
        .iter()
        .find(|p| p.assets.iter().any(|a| a.key == *anchor))
        .ok_or("表示する写真を確認できません。一覧を更新してください。")?;
    let choices = crate::media::PreviewAccess::new(
        &model.state.snapshots,
        &model.state.apple_scope,
        model.session.as_ref(),
    )
    .choices(photo, &model.preview_preferences);
    let choice = choices
        .iter()
        .find(|c| c.key == key)
        .ok_or("この写真に属する表示元を選んでください。")?;
    if let Some(reason) = &choice.disabled_reason {
        return Err(reason.clone());
    }
    crate::media::remember_preview(&mut model.preview_preferences, photo, key);
    Ok(())
}
fn update_preview_preferences(model: &mut Model, selected: Option<crate::domain::AssetKey>) {
    let photos = catalog(&model.state.snapshots, &model.state.receipts);
    model.preview_preferences.retain(|key| {
        photos
            .iter()
            .any(|p| p.assets.iter().any(|a| a.key == *key))
    });
    if let Some(key) = selected
        && let Some(photo) = photos
            .iter()
            .find(|p| p.assets.iter().any(|a| a.key == key))
    {
        crate::media::remember_preview(&mut model.preview_preferences, photo, key);
    }
}
fn invalidate_apple(state: &mut SavedLibrary) {
    for s in state
        .albums
        .iter_mut()
        .filter(|s| s.provider == Provider::Apple)
    {
        s.access = ScanAccess::Unavailable;
    }
    for s in state
        .snapshots
        .iter_mut()
        .filter(|s| s.provider == Provider::Apple)
    {
        s.access = ScanAccess::Unavailable;
    }
}

pub async fn io<T: serde::de::DeserializeOwned>(
    ctx: &Context,
    op: ShellOperation,
) -> Result<T, String> {
    let response = ctx.request_from_shell(op).await;
    if let Some(error) = response.error {
        return Err(error);
    }
    serde_json::from_value(response.value.unwrap_or(Value::Null))
        .map_err(|e| format!("入出力の形式が不正です: {e}"))
}

impl std::fmt::Debug for EffectFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("EffectFfi::Io")
    }
}
