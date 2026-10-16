use schemars::JsonSchema;
use std::io::Write;
use suwop_core::{
    app::{SavedLibrary, ViewModel},
    domain::{AppleFacts, AppleImportPlan, TransferBundle},
    immich::{HttpRequest, HttpResponse},
    workflow::HashResult,
};
#[derive(JsonSchema)]
#[allow(dead_code)]
struct Protocol {
    immich_locked_video_acquisition_renewed:
        suwop_core::immich_locked::video::ImmichLockedVideoAcquisitionRenewed,
    immich_locked_video_ticket: suwop_core::immich_locked::video::ImmichLockedVideoTicket,
    immich_locked_video_result: suwop_core::immich_locked::video::ImmichLockedVideoResult,
    immich_locked_video_prepared: suwop_core::immich_locked::video::ImmichLockedVideoPrepared,
    immich_locked_video_storage_facts:
        suwop_core::immich_locked::video::ImmichLockedVideoStorageFacts,
    inference_selection: suwop_core::inference::InferenceSelection,
    inference_status: suwop_core::inference::InferenceStatus,
    inference_spec: suwop_core::inference::InferenceSpec,
    analysis_model: suwop_core::analysis::AnalysisModel,
    analysis_budget: suwop_core::analysis::AnalysisBudget,
    embedding_input: suwop_core::analysis::EmbeddingInput,
    embedding_job: suwop_core::analysis::EmbeddingJob,
    analysis_status: suwop_core::analysis::AnalysisStatus,
    similarity_hit: suwop_core::analysis::SimilarityHit,
    ordinary_selected_image_ticket: suwop_core::ordinary_selected::OrdinarySelectedImageTicket,
    ordinary_selected_image_result: suwop_core::ordinary_selected::OrdinarySelectedImageResult,
    immich_archive_prompt: suwop_core::immich_archive::ImmichArchivePrompt,
    immich_visibility_prompt: suwop_core::immich_visibility::ImmichVisibilityPrompt,
    immich_locked_image_result: suwop_core::immich_locked::ImmichLockedImageResult,
    immich_locked_image_ticket: suwop_core::immich_locked::ImmichLockedImageTicket,
    protected_scene_phase: suwop_core::protection::ProtectionScenePhase,
    protected_auth_result: suwop_core::protection::ProtectedAuthResult,
    protected_image_result: suwop_core::protection::ProtectedImageResult,
    protected_image_ticket: suwop_core::protection::ProtectedImageTicket,
    protected_challenge: suwop_core::protection::ProtectedChallenge,

    apple_visibility_inspection: suwop_core::apple_visibility::AppleVisibilityInspection,
    apple_visibility_apply: suwop_core::apple_visibility::AppleVisibilityApply,
    apple_visibility_prompt: suwop_core::apple_visibility::AppleVisibilityPrompt,
    apple_visibility_result: suwop_core::apple_visibility::AppleVisibilityResult,
    state: SavedLibrary,
    view: ViewModel,
    apple: AppleFacts,
    import: AppleImportPlan,
    bundle: TransferBundle,
    http: HttpRequest,
    response: HttpResponse,
    hash: HashResult,
    browser: suwop_core::browser::BrowserOptions,
    album_edit: suwop_core::albums::AlbumEdit,
    share_file: suwop_core::sharing::ShareFile,
    share_presentation: suwop_core::sharing::SharePresentation,
    playback: suwop_core::media::PlaybackPlan,
    metadata_input: suwop_core::metadata::MetadataInput,
    metadata_change: suwop_core::metadata::MetadataChange,
    edit_draft_request: suwop_core::editing::EditDraftRequest,
    image_edit_state: suwop_core::editing::ImageEditState,
    editing_source_check: suwop_core::editing::EditingSourceCheck,
    apple_edit_input: suwop_core::editing::AppleEditInput,
    apple_edit_result: suwop_core::editing::AppleEditResult,
    image_edit_presentation: suwop_core::editing::ImageEditPresentation,
    image_render_plan: suwop_core::editing::ImageRenderPlan,
    native_color_plan: suwop_core::editing::NativeColorPlan,
    paste_edits_prompt: suwop_core::editing::PasteEditsPrompt,
    upload_resume_prompt: suwop_core::immich::UploadResumePrompt,
    upload_forget_prompt: suwop_core::immich::UploadForgetPrompt,
    upload_intent_forget_prompt: suwop_core::immich::UploadIntentForgetPrompt,

    apple_reversion_facts: suwop_core::editing::AppleReversionFacts,
    reversion_prompt: suwop_core::editing::ReversionPrompt,
    apple_trash_prompt: suwop_core::trash::AppleTrashPrompt,
    apple_trash_inspection: suwop_core::trash::AppleTrashInspection,
    apple_trash_result: suwop_core::trash::AppleTrashResult,
    trash_prompt: suwop_core::trash::TrashPrompt,
    current_image_export: suwop_core::sharing::CurrentImageExport,
    current_image_facts: suwop_core::sharing::CurrentImageFacts,
    current_image_render_plan: suwop_core::sharing::CurrentImageRenderPlan,
    current_image_render_result: suwop_core::sharing::CurrentImageRenderResult,
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let schema = schemars::schema_for!(Protocol);
    std::io::stdout().write_all(serde_json::to_string_pretty(&schema)?.as_bytes())?;
    Ok(())
}
