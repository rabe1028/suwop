use super::*;

fn resource(role: ResourceRole, token: &str) -> StagedResource {
    StagedResource {
        token: token.into(),
        name: format!("{token}.jpg"),
        role,
        media_type: match role {
            ResourceRole::RawImage => "image/raw",
            ResourceRole::LiveVideo => "video/quicktime",
            _ => "image/jpeg",
        }
        .into(),
        sha256: "a".repeat(64),
        bytes: 10,
        content_identifier: None,
    }
}
fn journal() -> ImportJournal {
    ImportJournal {
        id: "item".into(),
        staging_operation: "operation".into(),
        created_at: 1.0,
        purpose: ImportPurpose::External,
        destination: Provider::Apple,
        destination_scope: "library".into(),
        source_keys: vec![],
        item: ImportItem {
            id: "item".into(),
            resources: vec![resource(ResourceRole::Image, "image")],
            metadata: ImportMetadata::default(),
        },
        phase: ImportPhase::Prepared,
        destination_keys: vec![],
        created: None,
    }
}
fn key(id: &str) -> AssetKey {
    AssetKey {
        provider: Provider::Apple,
        scope: "library".into(),
        asset_id: id.into(),
    }
}

#[test]
fn staged_files_are_not_fabricated_catalog_assets() {
    let mut input = journal();
    assert!(input.validate().is_ok());
    input.source_keys.push(key("source"));
    assert!(input.validate().is_err());
    input.purpose = ImportPurpose::DuplicateOriginal;
    assert!(input.validate().is_ok());
    input.source_keys.clear();
    assert!(input.validate().is_err());
}

#[test]
fn live_requires_exact_complete_pair_identifier() {
    let mut input = journal();
    input.item.resources[0].content_identifier = Some("live".into());
    assert!(input.validate().is_err());
    let mut video = resource(ResourceRole::LiveVideo, "video");
    video.content_identifier = Some("other".into());
    input.item.resources.push(video);
    assert!(input.validate().is_err());
    input.item.resources[1].content_identifier = Some("live".into());
    assert!(input.validate().is_ok());
    input.item.resources.remove(0);
    assert!(input.validate().is_err());
}

#[test]
fn raw_pair_and_multiple_unrelated_images_are_distinct() {
    let mut input = journal();
    input
        .item
        .resources
        .push(resource(ResourceRole::Image, "second"));
    assert!(input.validate().is_err());
    input.item.resources[1] = resource(ResourceRole::RawImage, "raw");
    assert!(input.validate().is_ok());
    input.item.resources[1].token = "../escape".into();
    assert!(input.validate().is_err());
}

#[test]
fn durable_submission_binds_exact_item_and_never_replays_after_restart() -> Result<(), String> {
    let input = journal();
    let mut saved = input.prepare_submission()?;
    saved.item.resources[0].sha256 = "b".repeat(64);
    assert!(input.submission_after_save(&saved).is_err());
    let submitted = input.prepare_submission()?;
    assert!(input.submission_after_save(&submitted).is_ok());
    assert!(submitted.prepare_submission().is_err());
    let recovered = submitted.recover();
    assert_eq!(recovered.phase, ImportPhase::Uncertain);
    assert!(recovered.retains_staged_bytes());
    assert!(recovered.prepare_submission().is_err());
    assert!(recovered.cancel_before_submission().is_err());
    Ok(())
}

#[test]
fn duplicate_requires_created_new_identity_and_exact_bytes() -> Result<(), String> {
    let mut input = journal();
    input.purpose = ImportPurpose::DuplicateOriginal;
    input.source_keys = vec![key("old")];
    let saved = input.prepare_submission()?;
    let permit = input.submission_after_save(&saved)?;
    assert!(
        permit
            .verified(vec![key("old")], vec!["a".repeat(64)], true)
            .is_err()
    );
    let permit = input.submission_after_save(&saved)?;
    let duplicate = permit.verified(vec![key("old")], vec!["a".repeat(64)], false)?;
    assert_eq!(duplicate.phase, ImportPhase::AlreadyPresent);
    let permit = input.submission_after_save(&saved)?;
    assert!(
        permit
            .verified(vec![key("new")], vec!["b".repeat(64)], true)
            .is_err()
    );
    let permit = input.submission_after_save(&saved)?;
    assert_eq!(
        permit
            .verified(vec![key("new")], vec!["a".repeat(64)], true)?
            .phase,
        ImportPhase::Verified
    );
    Ok(())
}

#[test]
fn invalid_metadata_and_duplicate_tokens_fail_before_submission() {
    let mut input = journal();
    input.item.metadata.latitude = Some(0.0);
    assert!(input.prepare_submission().is_err());
    input.item.metadata.longitude = Some(f64::NAN);
    assert!(input.prepare_submission().is_err());
    input.item.metadata = ImportMetadata::default();
    input.item.metadata.captured_at = Some("2026-10-27 12:00".into());
    assert!(input.prepare_submission().is_err());
}

#[test]
fn stale_catalog_writer_cannot_erase_or_rewind_import_journal() -> Result<(), String> {
    let prepared = journal();
    let submitting = prepared.prepare_submission()?;
    assert!(validate_transition(&[], std::slice::from_ref(&prepared)).is_ok());
    assert!(
        validate_transition(
            std::slice::from_ref(&prepared),
            std::slice::from_ref(&submitting)
        )
        .is_ok()
    );
    assert!(
        validate_transition(
            std::slice::from_ref(&submitting),
            std::slice::from_ref(&prepared)
        )
        .is_err()
    );
    assert!(validate_transition(std::slice::from_ref(&submitting), &[]).is_err());
    assert!(validate_transition(&[], &[submitting]).is_err());
    Ok(())
}

#[test]
fn unknown_response_is_not_recovered_by_guessing_an_existing_checksum() -> Result<(), String> {
    let uncertain = journal().prepare_submission()?.recover();
    assert!(uncertain.reconcile(vec!["a".repeat(64)]).is_err());
    let mut known = uncertain;
    known.created = Some(true);
    known.destination_keys = vec![key("new")];
    assert_eq!(
        known.reconcile(vec!["a".repeat(64)])?.phase,
        ImportPhase::Verified
    );
    Ok(())
}

#[test]
fn partial_unknown_history_is_opaque_current_account_bound_and_source_fenced() -> Result<(), String>
{
    use crate::app::{Model, SavedLibrary, Suwop};
    use crux_core::App;
    let mut record = journal();
    record.phase = ImportPhase::Uncertain;
    record.destination_keys = vec![key("unscanned-new-id")];
    record.created = Some(true);
    let mut model = Model {
        ready: true,
        state: SavedLibrary {
            apple_scope: "library".into(),
            external_imports: vec![record],
            ..SavedLibrary::default()
        },
        ..Model::default()
    };
    let view = Suwop.view(&model);
    assert!(view.external_imports.is_empty());
    assert_eq!(view.import_notices.len(), 1);
    assert!(view.import_notices[0].can_inspect);
    let notice = serde_json::to_value(&view.import_notices[0]).map_err(|e| e.to_string())?;
    assert_eq!(notice.as_object().ok_or("notice object")?.len(), 3);
    assert!(notice.get("item").is_none());
    assert!(notice.get("destinationKeys").is_none());
    model.state.apple_scope = "other-account".into();
    assert!(Suwop.view(&model).import_notices.is_empty());
    model.state.apple_scope = "library".into();
    model.state.external_imports[0].purpose = ImportPurpose::DuplicateOriginal;
    model.state.external_imports[0].source_keys = vec![key("not-ordinary-source")];
    assert!(Suwop.view(&model).import_notices.is_empty());
    Ok(())
}

#[test]
fn import_names_reject_header_controls_but_preserve_literal_quotes() {
    for name in [
        "evil\rname.jpg",
        "evil\nname.jpg",
        "evil\0name.jpg",
        "evil\tname.jpg",
    ] {
        let mut input = journal();
        input.item.resources[0].name = name.into();
        assert!(input.validate().is_err());
    }
    let mut input = journal();
    input.item.resources[0].name = "literal\"quote.jpg".into();
    assert!(input.validate().is_ok());
}
