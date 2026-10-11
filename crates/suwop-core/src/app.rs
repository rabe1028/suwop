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
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", content = "data", rename_all = "camelCase")]
pub enum ShellOperation {
    ReadState,
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
    EditImage {
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
    RefreshAlbums,
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
    },
}
#[derive(Debug, Default)]
pub struct Model {
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
        ViewModel {
            editing_targets: photos
                .iter()
                .map(|p| {
                    (
                        crate::browser::photo_id(p),
                        crate::editing::targets(
                            p,
                            &model.state.snapshots,
                            &model.state.apple_scope,
                        ),
                    )
                })
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
            preview_sources: photos
                .iter()
                .filter_map(|p| {
                    crate::media::preview_source(p, &model.state.snapshots)
                        .map(|key| (crate::browser::photo_id(p), key))
                })
                .collect(),
            media: photos
                .iter()
                .filter_map(|p| {
                    crate::media::kind(p).map(|kind| (crate::browser::photo_id(p), kind))
                })
                .collect(),
            albums: crate::albums::views(&model.state.albums, &photos, &model.state.snapshots),
            browser: crate::browser::browse(&photos, &model.browser),
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
