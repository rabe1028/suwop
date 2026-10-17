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
    #[serde(default)]
    pub immich_visibility_operations: Vec<crate::immich_visibility::ImmichVisibilityOperation>,
    #[serde(default)]
    pub protected_entries: Vec<crate::protection::PersistentProtectedEntry>,
    #[serde(default)]
    pub apple_visibility_operations: Vec<crate::apple_visibility::AppleVisibilityOperation>,
    #[serde(default)]
    pub edit_clipboard: Option<crate::editing::EditClipboard>,
    #[serde(default)]
    pub pending_edit_pastes: Vec<crate::editing::PendingEditPaste>,
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
    #[serde(default)]
    pub pending_apple_trash: Vec<crate::trash::AppleTrashOperation>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(tag = "type", content = "data", rename_all = "camelCase")]
pub enum ShellOperation {
    ConfirmImmichArchive {
        prompt: crate::immich_archive::ImmichArchivePrompt,
    },
    ConfirmImmichVisibility {
        prompt: crate::immich_visibility::ImmichVisibilityPrompt,
    },
    ReadOrdinarySelectedImage {
        ticket: crate::ordinary_selected::OrdinarySelectedImageTicket,
    },
    PublishOrdinarySelectedImage {
        ticket: crate::ordinary_selected::OrdinarySelectedImageTicket,
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseOrdinarySelectedImage {
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseOrdinarySelectedImages {
        generation: u64,
    },
    InspectImmichLockedVideoStorage {
        pending: crate::immich_locked::video::ImmichLockedVideoPending,
    },
    ReadImmichLockedVideo {
        ticket: crate::immich_locked::video::ImmichLockedVideoTicket,
    },
    PrepareImmichLockedVideo {
        ticket: crate::immich_locked::video::ImmichLockedVideoTicket,
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    RenewImmichLockedVideoAcquisition {
        ticket: crate::immich_locked::video::ImmichLockedVideoTicket,
        #[serde(rename = "previousLeaseID")]
        previous_lease_id: u64,
        lease: crate::immich_locked::video::ImmichLockedVideoAcquisitionLease,
    },
    ScheduleImmichLockedVideoAcquisitionExpiry {
        pending: crate::immich_locked::video::ImmichLockedVideoPending,
        lease: crate::immich_locked::video::ImmichLockedVideoAcquisitionLease,
    },
    QuiesceImmichLockedVideo {
        key: crate::domain::AssetKey,
        pending: Option<crate::immich_locked::video::ImmichLockedVideoPending>,
    },
    ReleaseImmichLockedVideo {
        pending: crate::immich_locked::video::ImmichLockedVideoPending,
        #[serde(rename = "leaseID")]
        lease_id: String,
    },
    ReleaseImmichLockedVideos {
        generation: u64,
    },
    ReadImmichLockedImage {
        ticket: crate::immich_locked::ImmichLockedImageTicket,
    },
    PublishImmichLockedImage {
        ticket: crate::immich_locked::ImmichLockedImageTicket,
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseImmichLockedImage {
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseImmichLockedImages {
        generation: u64,
    },
    ScheduleImmichLockedExpiry {
        #[serde(rename = "grantID")]
        grant_id: String,
        generation: u64,
        #[serde(rename = "leaseID")]
        lease_id: u64,
        milliseconds: u32,
        #[serde(rename = "deadlineUnixMilliseconds")]
        deadline_unix_milliseconds: u64,
    },
    ScheduleImmichLockedCheck {
        #[serde(rename = "grantID")]
        grant_id: String,
        generation: u64,
        #[serde(rename = "leaseID")]
        lease_id: u64,
        milliseconds: u32,
        #[serde(rename = "deadlineUnixMilliseconds")]
        deadline_unix_milliseconds: u64,
    },
    AuthenticateProtected {
        challenge: crate::protection::ProtectedChallenge,
    },
    ReadProtectedImage {
        ticket: crate::protection::ProtectedImageTicket,
    },
    PublishProtectedImage {
        ticket: crate::protection::ProtectedImageTicket,
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseProtectedImage {
        #[serde(rename = "stagedID")]
        staged_id: String,
    },
    ReleaseProtectedImages {
        #[serde(rename = "grantID")]
        grant_id: Option<String>,
    },

    AppleVisibilityInspect {
        scope: String,
        keys: Vec<crate::domain::AssetKey>,
    },
    ConfirmAppleVisibility {
        prompt: crate::apple_visibility::AppleVisibilityPrompt,
    },
    AppleVisibilityApply {
        request: crate::apple_visibility::AppleVisibilityApply,
    },
    ConfirmPasteEdits {
        prompt: crate::editing::PasteEditsPrompt,
    },
    AppleEditInspect {
        asset: crate::domain::StoredAsset,
    },
    ReadState,
    RandomId,
    Wait {
        milliseconds: u32,
    },
    ConfirmUploadResume {
        prompt: crate::immich::UploadResumePrompt,
    },
    ConfirmAppleTrash {
        prompt: crate::trash::AppleTrashPrompt,
    },
    AppleTrashApply {
        assets: Vec<crate::domain::StoredAsset>,
    },
    AppleTrashInspect {
        scope: String,
        keys: Vec<crate::domain::AssetKey>,
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
    ShareFiles(crate::sharing::SharePresentation),
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
        key: crate::domain::AssetKey,
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
    InspectImmichLiveResources {
        #[serde(rename = "parentKey")]
        parent_key: crate::domain::AssetKey,
        #[serde(rename = "requestID")]
        request_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    #[serde(skip)]
    ImmichLiveResourcesInspected {
        completion: crate::immich_live_resources::Completion,
    },
    RefreshImmichLocked {
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    #[serde(skip)]
    ImmichLockedRefreshed {
        generation: u64,
        refresh_id: u64,
        result: Result<
            (
                Vec<crate::immich_locked::ImmichLockedEntry>,
                std::time::Instant,
            ),
            String,
        >,
    },
    PrepareImmichArchive {
        key: crate::domain::AssetKey,
        to: crate::immich_archive::ImmichArchiveDestination,
        #[serde(rename = "operationID")]
        operation_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    InspectImmichArchive {
        #[serde(rename = "recordID")]
        record_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    RecoverImmichArchiveState {
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    ImmichArchiveSceneChanged {
        #[serde(rename = "sceneID")]
        scene_id: String,
        phase: crate::protection::ProtectionScenePhase,
    },
    OpenImmichArchive {
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    CloseImmichArchive {
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    PrepareImmichVisibility {
        key: crate::domain::AssetKey,
        to: crate::immich_visibility::ImmichVisibility,
        #[serde(rename = "operationID")]
        operation_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    InspectImmichVisibility {
        #[serde(rename = "recordID")]
        record_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    RecoverImmichVisibilityState {
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    OpenImmichLocked {
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
        email: crate::immich_locked::Secret,
        password: crate::immich_locked::Secret,
        #[serde(rename = "pinCode")]
        pin_code: crate::immich_locked::Secret,
    },
    CloseImmichLocked,
    ImmichLockedSceneChanged {
        #[serde(rename = "sceneID")]
        scene_id: String,
        phase: crate::protection::ProtectionScenePhase,
    },
    RequestOrdinarySelectedImage {
        key: crate::domain::AssetKey,
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
        kind: crate::ordinary_selected::OrdinarySelectedImageKind,
    },
    CancelOrdinarySelectedImage {
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
    },
    CloseOrdinarySelectedScene {
        #[serde(rename = "sceneID")]
        scene_id: String,
    },
    #[serde(skip)]
    OrdinarySelectedRefreshFinished {
        result: Box<crate::workflow::Outcome>,
        expected_generation: u64,
        refresh_id: u64,
        origin: crate::ordinary_selected::RefreshOrigin,
    },
    #[serde(skip)]
    OrdinarySelectedImageRead {
        ticket: crate::ordinary_selected::OrdinarySelectedImageTicket,
        result: Option<crate::ordinary_selected::OrdinarySelectedImageResult>,
    },
    #[serde(skip)]
    OrdinarySelectedImagePublished {
        ticket: crate::ordinary_selected::OrdinarySelectedImageTicket,
        #[serde(rename = "stagedID")]
        staged_id: String,
        approved: bool,
    },
    RequestImmichLockedVideo {
        #[serde(rename = "entryID")]
        entry_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
    },
    ExpireImmichLockedVideoAcquisition {
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
        generation: u64,
        #[serde(rename = "leaseID")]
        lease_id: u64,
    },
    #[serde(skip)]
    ImmichLockedVideoRenewalAcknowledged {
        pending: crate::immich_locked::video::ImmichLockedVideoPending,
        #[serde(rename = "stagedID")]
        staged_id: String,
        previous_lease_id: u64,
        lease_id: u64,
        result: Result<crate::immich_locked::video::ImmichLockedVideoAcquisitionRenewed, String>,
    },
    StopImmichLockedVideo {
        #[serde(rename = "sceneID")]
        scene_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
    },
    #[serde(skip)]
    ImmichLockedVideoPlanned {
        acquisition: crate::immich_locked::video::VideoAcquisition,
        storage: Result<
            (
                crate::immich_locked::video::ImmichLockedVideoStorageFacts,
                Option<u64>,
            ),
            String,
        >,
    },
    #[serde(skip)]
    ImmichLockedVideoRead {
        acquisition: crate::immich_locked::video::VideoAcquisition,
        ticket: Box<crate::immich_locked::video::ImmichLockedVideoTicket>,
        result: Result<crate::immich_locked::video::ImmichLockedVideoResult, String>,
    },
    #[serde(skip)]
    ImmichLockedVideoPrepared {
        acquisition_lease_id: u64,
        ticket: crate::immich_locked::video::ImmichLockedVideoTicket,
        approved: bool,
    },
    RequestImmichLockedImage {
        #[serde(rename = "entryID")]
        entry_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
    },
    ExpireImmichLocked {
        #[serde(rename = "grantID")]
        grant_id: String,
        generation: u64,
        #[serde(rename = "leaseID")]
        lease_id: u64,
    },
    CheckImmichLockedSession {
        #[serde(rename = "grantID")]
        grant_id: String,
        generation: u64,
        #[serde(rename = "leaseID")]
        lease_id: u64,
    },
    #[serde(skip)]
    ImmichLockedOpened {
        generation: u64,
        result: Result<crate::immich_locked::OpenedSession, crate::immich_locked::OpenFailure>,
    },
    #[serde(skip)]
    ImmichLockedClosed {
        generation: u64,
        confirmed: bool,
    },
    #[serde(skip)]
    ImmichLockedChecked {
        grant_id: String,
        generation: u64,
        lease_id: u64,
        result: Option<std::time::Instant>,
        video: Option<crate::immich_locked::video::VideoHeartbeat>,
    },
    #[serde(skip)]
    ImmichLockedImageRead {
        ticket: crate::immich_locked::ImmichLockedImageTicket,
        result: Option<crate::immich_locked::ImmichLockedImageResult>,
    },
    #[serde(skip)]
    ImmichLockedImagePublished {
        ticket: crate::immich_locked::ImmichLockedImageTicket,
        staged_id: String,
        approved: bool,
    },
    BeginProtectedAccess {
        #[serde(rename = "challengeID")]
        challenge_id: String,
        #[serde(rename = "sceneID")]
        scene_id: String,
        purpose: crate::protection::ProtectedPurpose,
    },
    LockProtectedAccess,
    ReconcileProtectedState {
        #[serde(rename = "grantID")]
        grant_id: String,
    },
    #[serde(skip)]
    ProtectedReconciled {
        state: Option<SavedLibrary>,
    },
    ProtectedSceneChanged {
        #[serde(rename = "sceneID")]
        scene_id: String,
        phase: crate::protection::ProtectionScenePhase,
    },
    ProtectPhotos {
        keys: Vec<crate::domain::AssetKey>,
        #[serde(rename = "operationID")]
        operation_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
    },
    UnprotectPhotos {
        ids: Vec<String>,
        #[serde(rename = "operationID")]
        operation_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
    },
    RequestProtectedImage {
        #[serde(rename = "entryID")]
        entry_id: String,
        #[serde(rename = "grantID")]
        grant_id: String,
        #[serde(rename = "requestID")]
        request_id: String,
        kind: crate::protection::ProtectedImageKind,
    },
    #[serde(skip)]
    ProtectedAuthCompleted {
        challenge: crate::protection::ProtectedChallenge,
        result: Option<crate::protection::ProtectedAuthResult>,
    },
    #[serde(skip)]
    ProtectedPersisted {
        state: SavedLibrary,
        keys: Vec<crate::domain::AssetKey>,
        outcome: crate::protection::ProtectedPersistOutcome,
    },
    #[serde(skip)]
    ProtectedImageRead {
        ticket: crate::protection::ProtectedImageTicket,
        result: Option<crate::protection::ProtectedImageResult>,
    },
    #[serde(skip)]
    ProtectedImagePublished {
        staged_id: String,
        ticket: crate::protection::ProtectedImageTicket,
        result: Option<crate::protection::ProtectedImageResult>,
    },

    HideApple {
        keys: Vec<crate::domain::AssetKey>,
        id: String,
    },
    UnhideApple {
        #[serde(rename = "recordID")]
        record_id: String,
        id: String,
    },
    InspectAppleVisibility {
        #[serde(rename = "recordID")]
        record_id: String,
    },
    CopyPhotoEdits {
        key: crate::domain::AssetKey,
        options: crate::editing::EditCopyOptions,
        id: String,
    },
    PastePhotoEdits {
        keys: Vec<crate::domain::AssetKey>,
        id: String,
    },
    PasteSelectedPhotoEdits {
        anchors: Vec<crate::domain::AssetKey>,
        id: String,
    },
    ResolveEditPaste {
        key: crate::domain::AssetKey,
        id: String,
    },
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
    TrashApple {
        keys: Vec<crate::domain::AssetKey>,
        id: String,
    },
    ResolveAppleTrash {
        id: String,
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
    ImmichVisibilityPrepared {
        result: Result<crate::immich_visibility::PreparedVisibility, String>,
    },
    #[serde(skip)]
    ImmichVisibilityFinished {
        result: crate::immich_visibility::VisibilityCompletion,
    },
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
    pub immich_live_resources: crate::immich_live_resources::LiveResourcesModel,
    pub ordinary_selected: crate::ordinary_selected::OrdinarySelectedModel,
    pub immich_archive: crate::immich_archive::ImmichArchiveModel,
    pub immich_visibility: crate::immich_visibility::ImmichVisibilityModel,
    pub ordinary_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub immich_locked: crate::immich_locked::ImmichLockedModel,
    pub protection: crate::protection::ProtectionModel,
    /// Observation-only token shared with in-flight workflows; never persisted.
    pub apple_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
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
    pub immich_live_resources: Option<crate::immich_live_resources::ImmichLiveResourcesView>,
    pub ordinary_selected_presentation: Vec<crate::ordinary_selected::OrdinarySelectedPresentation>,
    pub ordinary_selected_pending: Vec<crate::ordinary_selected::OrdinarySelectedImageRequest>,
    pub ordinary_selected_images: Vec<crate::ordinary_selected::OrdinarySelectedImageAccess>,
    pub ordinary_selected_generation: u64,
    pub immich_archive_view: crate::immich_archive::ImmichArchiveView,
    pub immich_archive_actions: Vec<crate::immich_archive::ImmichArchiveActionHint>,
    pub ordinary_content_keys: Vec<crate::domain::AssetKey>,
    pub private_content_revision: String,
    pub immich_visibility_actions: Vec<crate::immich_visibility::ImmichVisibilityActionHint>,
    pub immich_visibility_view: crate::immich_visibility::ImmichVisibilityView,
    pub immich_locked_view: crate::immich_locked::ImmichLockedView,
    pub protected_view: crate::protection::ProtectedView,
    pub apple_visibility_hide_keys: Vec<crate::domain::AssetKey>,
    pub preview_choices: std::collections::BTreeMap<String, Vec<crate::media::PreviewChoice>>,
    pub remote_version: Option<crate::immich::Version>,
    pub editing_targets: std::collections::BTreeMap<String, Vec<crate::editing::EditingTarget>>,
    pub metadata_targets: std::collections::BTreeMap<String, Vec<crate::metadata::MetadataTarget>>,
    pub preview_sources: std::collections::BTreeMap<String, crate::domain::AssetKey>,
    pub media: std::collections::BTreeMap<String, crate::media::PlaybackKind>,
    pub albums: Vec<crate::albums::AlbumView>,
    pub browser: crate::browser::BrowserView,
    pub state: crate::privacy::PublishedLibrary,
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
        if let Some(command) = crate::immich_live_resources::update(&event, model) {
            return command;
        }
        if crate::ordinary_selected::security_progress_changed(&event, model)
            || matches!(
                event,
                Event::Disconnect
                    | Event::Configure { .. }
                    | Event::ProtectedPersisted { .. }
                    | Event::ProtectedReconciled { .. }
                    | Event::Finished { .. }
            )
        {
            model
                .ordinary_generation
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let connection_changed = matches!(event, Event::Disconnect | Event::Configure { .. })
                || matches!(&event, Event::Finished { session, .. }
                    if model.session.as_ref().map(|s| &s.scope) != session.as_ref().map(|s| &s.scope));
            if connection_changed {
                model.immich_archive.scene_id = None;
            }
            crate::immich_archive::invalidate(model);
        }
        let selected_cleanup = crate::ordinary_selected::reconcile(&event, model);
        if let Some(command) = crate::ordinary_selected::update(&event, model) {
            return selected_cleanup
                .and(command)
                .and(crate::ordinary_selected::reconcile_current(model))
                .and(crate::immich_locked::video::reconcile(model));
        }
        if let Event::OrdinarySelectedRefreshFinished {
            result,
            expected_generation,
            refresh_id,
            origin,
        } = event.clone()
        {
            return selected_cleanup
                .and(crate::ordinary_selected::finish_refresh(
                    model,
                    result,
                    expected_generation,
                    refresh_id,
                    &origin,
                ))
                .and(crate::immich_locked::video::reconcile(model));
        }
        if let Some(command) = crate::immich_archive::update(event.clone(), model) {
            return selected_cleanup
                .and(command)
                .and(crate::ordinary_selected::reconcile_current(model))
                .and(crate::immich_locked::video::reconcile(model));
        }
        if let Some(command) = crate::immich_visibility::update(event.clone(), model) {
            return selected_cleanup
                .and(command)
                .and(crate::ordinary_selected::reconcile_current(model))
                .and(crate::immich_locked::video::reconcile(model));
        }
        if let Some(command) = crate::immich_locked::update(event.clone(), model) {
            return selected_cleanup
                .and(command)
                .and(crate::ordinary_selected::reconcile_current(model))
                .and(crate::immich_locked::video::reconcile(model));
        }
        let cleanup = if crate::immich_locked::invalidates(&event) {
            crate::immich_locked::close(model)
        } else {
            Command::done()
        };
        let library = Self::update_library(event, model);
        selected_cleanup
            .and(cleanup)
            .and(library)
            .and(crate::ordinary_selected::reconcile_current(model))
            .and(crate::immich_locked::video::reconcile(model))
    }
    fn view(&self, model: &Model) -> ViewModel {
        Self::library_view(model)
    }
}
impl Suwop {
    fn update_library(event: Event, model: &mut Model) -> Command<Effect, Event> {
        if model.immich_visibility.persistence_uncertain
            && matches!(
                event,
                Event::ProtectPhotos { .. } | Event::UnprotectPhotos { .. }
            )
        {
            model.error = Some("非表示変更の保存状態を先に確認してください。".into());
            return Command::done();
        }
        if let Some(command) = crate::protection::update(event.clone(), model) {
            return command;
        }
        if ordinary_event_denied(model, &event) {
            model.error = Some("保存状態を先に確認してください。変更は開始しません。".into());
            return Command::done();
        }
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
                crate::protection::reconcile(model)
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
                model.ready = model.state.schema_version == 8;
                update_preview_preferences(model, preview_to_select);
                crate::protection::reconcile(model)
            }
            Event::AppleChanged => {
                model
                    .apple_generation
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                invalidate_apple(&mut model.state);
                model.changed_during_work = model.busy;
                crate::protection::reconcile(model)
            }
            _ if model.busy => Command::done(),
            event => Self::start_workflow(event, model),
        }
    }
    fn start_workflow(event: Event, model: &mut Model) -> Command<Effect, Event> {
        model.busy = true;
        model.error = None;
        model.changed_during_work = false;
        model.status = "処理中…".into();
        let origin = crate::ordinary_selected::RefreshOrigin::capture(model);
        let state = model.state.clone();
        let session = model.session.clone();
        let apple_generation = model.apple_generation.clone();
        let denied_content = model
            .protection
            .denied
            .union(&model.immich_visibility.denied)
            .cloned()
            .collect();
        let ordinary_generation = model.ordinary_generation.clone();
        let expected_generation = ordinary_generation.load(std::sync::atomic::Ordering::SeqCst);
        let is_refresh = matches!(event, Event::Refresh { .. });
        let refresh_id = if is_refresh {
            model.ordinary_selected.refresh_sequence =
                model.ordinary_selected.refresh_sequence.wrapping_add(1);
            let id = model.ordinary_selected.refresh_sequence;
            model.ordinary_selected.active_refresh = Some(id);
            id
        } else {
            model.ordinary_selected.active_refresh = None;
            0
        };
        Command::new(move |ctx| async move {
            let result = crate::workflow::run_guarded(
                &ctx,
                event,
                state,
                session,
                apple_generation,
                denied_content,
                ordinary_generation,
            )
            .await;
            if is_refresh {
                ctx.send_event(Event::OrdinarySelectedRefreshFinished {
                    result: Box::new(result),
                    expected_generation,
                    refresh_id,
                    origin,
                });
                return;
            }
            ctx.send_event(Event::Finished {
                state: result.state,
                session: result.session,
                status: result.status,
                error: result.error,
                preview_to_select: result.preview_to_select,
            });
        })
    }
    fn library_view(model: &Model) -> ViewModel {
        let can_transfer = can_transfer(model);
        let move_blockers = public_move_blockers(model, can_transfer);
        let operation_public = crate::privacy::PublishedLibrary::from_canonical(
            &crate::protection::ordinary_state(model),
        );
        let public = crate::ordinary_selected::public_library(model);
        let photos = catalog(&public.snapshots, &public.receipts);
        let preview_access = crate::media::PreviewAccess::new(
            &public.snapshots,
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
        let editing_access = crate::editing::EditingAccess::new(
            &operation_public.snapshots,
            &model.state.apple_scope,
        );
        let (ordinary_content_keys, private_content_revision) =
            ordinary_projection(model, &operation_public);
        ViewModel {
            ordinary_selected_presentation: crate::ordinary_selected::presentations(model),
            ordinary_selected_images: crate::ordinary_selected::images(model),
            ordinary_selected_pending: crate::ordinary_selected::pending(model),
            ordinary_selected_generation: crate::ordinary_selected::generation(model),
            ordinary_content_keys,
            private_content_revision,
            immich_archive_view: crate::immich_archive::view(model),
            immich_archive_actions: crate::immich_archive::actions(model),
            immich_visibility_actions: crate::immich_visibility::actions(model),
            immich_visibility_view: crate::immich_visibility::view(model),
            immich_live_resources: crate::immich_live_resources::view(model),
            immich_locked_view: crate::immich_locked::view(model),
            protected_view: crate::protection::view(model),
            apple_visibility_hide_keys: if model.ready
                && !model.busy
                && !model.protection.membership_uncertain
            {
                crate::apple_visibility::hide_keys(&crate::protection::ordinary_state(model))
            } else {
                vec![]
            },
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
                        crate::metadata::targets(p, &operation_public.snapshots),
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
            albums: crate::albums::views(&public.albums, &photos, &public.snapshots),
            browser: crate::browser::browse_with_dates(&photos, &model.browser, &displayed_dates),
            photos,
            pending_apple_count: public
                .snapshots
                .iter()
                .filter(|s| s.provider == Provider::Apple)
                .flat_map(|s| &s.assets)
                .filter(|a| !a.fingerprints_complete())
                .count(),
            state: public,
            busy: model.busy,
            status: crate::privacy::public_text(
                &crate::protection::ordinary_state(model),
                &model.status,
            ),
            error: model.error.as_ref().map(|error| {
                crate::privacy::public_text(&crate::protection::ordinary_state(model), error)
            }),
            server_version: model.session.as_ref().map(|s| s.version.description()),
            can_transfer,
            move_blockers,
        }
    }
}
fn public_move_blockers(
    model: &Model,
    can_transfer: bool,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let mut move_blockers = std::collections::BTreeMap::new();
    let ordinary = crate::protection::ordinary_state(model);
    let content_access = crate::privacy::ContentAccess::new(&ordinary);
    for receipt in &model.state.receipts {
        if receipt
            .source
            .iter()
            .chain(&receipt.destination)
            .any(|asset| content_access.protected(&asset.key))
        {
            continue;
        }
        if !content_access.receipt_visible(receipt) {
            move_blockers.insert(
                receipt.id.clone(),
                vec!["写真の可視性を確認して一覧を更新してください。".into()],
            );
            continue;
        }
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
    move_blockers
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
    if model.protection.denied.contains(anchor) || model.protection.denied.contains(&key) {
        return Err("保護した写真を通常の一覧から表示できません。".into());
    }
    let public = crate::ordinary_selected::public_library(model);
    let present = |key: &crate::domain::AssetKey| {
        public
            .snapshots
            .iter()
            .filter(|s| s.access != crate::domain::ScanAccess::Unavailable)
            .flat_map(|s| &s.assets)
            .any(|a| a.key == *key)
    };
    if !present(anchor) || !present(&key) {
        return Err("写真の可視性を確認してください。".into());
    }
    let photos = catalog(&public.snapshots, &public.receipts);
    let photo = photos
        .iter()
        .find(|p| p.assets.iter().any(|a| a.key == *anchor))
        .ok_or("表示する写真を確認できません。一覧を更新してください。")?;
    let choices = crate::media::PreviewAccess::new(
        &public.snapshots,
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
pub(crate) fn invalidate_apple(state: &mut SavedLibrary) {
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

pub(crate) fn ordinary_revision(scope: Option<&str>, generation: u64) -> String {
    use sha2::Digest;
    crate::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&(generation, scope)).unwrap_or_default(),
    ))
}

fn ordinary_projection(
    model: &Model,
    public: &crate::privacy::PublishedLibrary,
) -> (Vec<crate::domain::AssetKey>, String) {
    (
        ordinary_keys(public),
        ordinary_revision(
            model.session.as_ref().map(|s| s.scope.as_str()),
            model
                .ordinary_generation
                .load(std::sync::atomic::Ordering::SeqCst),
        ),
    )
}
fn ordinary_keys(public: &crate::privacy::PublishedLibrary) -> Vec<crate::domain::AssetKey> {
    let keys: Vec<_> = public
        .snapshots
        .iter()
        .filter(|snapshot| snapshot.access != crate::domain::ScanAccess::Unavailable)
        .flat_map(|snapshot| {
            snapshot
                .assets
                .iter()
                .filter(|asset| asset.content_visible())
                .map(|asset| asset.key.clone())
        })
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();

    keys
}

fn ordinary_event_denied(model: &Model, event: &Event) -> bool {
    (model.protection.membership_uncertain || model.immich_visibility.persistence_uncertain)
        && !matches!(
            event,
            Event::AppleChanged
                | Event::Progress { .. }
                | Event::Finished { .. }
                | Event::Browse { .. }
                | Event::ChoosePreview { .. }
        )
}

fn can_transfer(model: &Model) -> bool {
    model.ready
        && model.session.is_some()
        && !model.busy
        && !model.protection.membership_uncertain
        && !model.immich_visibility.persistence_uncertain
}
