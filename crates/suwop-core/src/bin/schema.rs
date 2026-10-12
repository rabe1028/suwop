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
    upload_resume_prompt: suwop_core::immich::UploadResumePrompt,
    upload_forget_prompt: suwop_core::immich::UploadForgetPrompt,
    upload_intent_forget_prompt: suwop_core::immich::UploadIntentForgetPrompt,

    apple_reversion_facts: suwop_core::editing::AppleReversionFacts,
    reversion_prompt: suwop_core::editing::ReversionPrompt,
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
