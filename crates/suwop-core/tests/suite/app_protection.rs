use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AppleVisibility, AssetKey, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset,
    },
    immich::{Session, Version},
    protection::{
        PersistentProtectedEntry, ProtectedAuthOutcome, ProtectedAuthResult, ProtectedImageKind,
        ProtectedImageResult, ProtectedImageTicket, ProtectedPurpose, ProtectedViewState,
        ProtectionScenePhase,
    },
};

const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const CHALLENGE: &str = "22222222-2222-4222-8222-222222222222";
const OPERATION: &str = "33333333-3333-4333-8333-333333333333";
const ENTRY: &str = "44444444-4444-4444-8444-444444444444";

fn asset(provider: Provider, id: &str) -> StoredAsset {
    StoredAsset {
        immich_parent_revision: None,
        immich_visibility: None,
        immich_stack: suwop_core::domain::ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: if provider == Provider::Apple {
                "apple"
            } else {
                "remote"
            }
            .into(),
            asset_id: id.into(),
        },
        name: format!("PRIVATE-{id}.jpg"),
        captured_at: Some(123.0),
        modified_at: Some(456.0),
        revision: format!("PRIVATE-revision-{id}"),
        resources: vec![PhotoResource {
            id: "original".into(),
            name: format!("PRIVATE-resource-{id}.jpg"),
            role: ResourceRole::Image,
            sha1: Some("a".repeat(40)),
            bytes: Some(765_432),
        }],
        is_favorite: false,
        latitude: Some(37.12345),
        longitude: Some(139.12345),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

fn saved() -> SavedLibrary {
    SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        apple_scope: "apple".into(),
        snapshots: [Provider::Apple, Provider::Immich]
            .into_iter()
            .map(|provider| {
                let record = asset(
                    provider,
                    if provider == Provider::Apple {
                        "apple-photo"
                    } else {
                        "remote-photo"
                    },
                );
                LibrarySnapshot {
                    provider,
                    scope: record.key.scope.clone(),
                    assets: vec![record],
                    access: ScanAccess::Full,
                    scanned_at: Some(1.0),
                }
            })
            .collect(),
        ..SavedLibrary::default()
    }
}

fn core(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            session: Some(Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://fixture.example/api".into(),
                key: "fixture-key".into(),
                scope: "remote".into(),
                user_id: "owner".into(),
                version: Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            }),
            ..Model::default()
        },
    )
}

fn reply(result: Result<Value, String>) -> ShellResponse {
    match result {
        Ok(value) => ShellResponse {
            value: Some(value),
            error: None,
        },
        Err(error) => ShellResponse {
            value: None,
            error: Some(error),
        },
    }
}

#[derive(Debug, Clone, Copy)]
enum PersistenceFault {
    BeforeWrite,
    AfterWrite,
}

struct Shell {
    auth: ProtectedAuthOutcome,
    persistence_fault: Option<PersistenceFault>,
    durable: Option<SavedLibrary>,
    effects: Vec<&'static str>,
}
impl Default for Shell {
    fn default() -> Self {
        Self {
            auth: ProtectedAuthOutcome::Success,
            persistence_fault: None,
            durable: None,
            effects: vec![],
        }
    }
}
impl Shell {
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut requests = core.process_event(event);
        while !requests.is_empty() {
            let Effect::Io(mut request) = requests.remove(0);
            let response = self.respond(&request.operation);
            requests.extend(
                core.resolve(&mut request, reply(response))
                    .map_err(|e| e.to_string())?,
            );
        }
        Ok(())
    }

    fn respond(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::ReleaseProtectedImages { .. } => {
                self.effects.push("release");
                Ok(Value::Null)
            }
            ShellOperation::AuthenticateProtected { challenge } => {
                self.effects.push("authenticate");
                serde_json::to_value(ProtectedAuthResult {
                    challenge_id: challenge.challenge_id.clone(),
                    scene_id: challenge.scene_id.clone(),
                    scope: challenge.scope.clone(),
                    outcome: self.auth,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::Persist(state) => {
                self.effects.push("persist");
                if !matches!(self.persistence_fault, Some(PersistenceFault::BeforeWrite)) {
                    self.durable = Some(state.clone());
                }
                if self.persistence_fault.is_some() {
                    Err("persistence response unavailable".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::ReadState => {
                self.effects.push("read-state");
                Err("durable readback unavailable".into())
            }
            other => Err(format!("Unexpected protected test effect: {other:?}")),
        }
    }

    fn activate(&mut self, core: &Core<Suwop>) -> Result<(), String> {
        self.run(
            core,
            Event::ProtectedSceneChanged {
                scene_id: SCENE.into(),
                phase: ProtectionScenePhase::Active,
            },
        )
    }

    fn authenticate(
        &mut self,
        core: &Core<Suwop>,
        purpose: ProtectedPurpose,
    ) -> Result<(), String> {
        self.run(
            core,
            Event::BeginProtectedAccess {
                challenge_id: CHALLENGE.into(),
                scene_id: SCENE.into(),
                purpose,
            },
        )
    }
}

#[test]
fn locked_serialized_view_never_contains_protected_members_or_counts_and_restart_relocks()
-> Result<(), String> {
    let mut initial = saved();
    initial.protected_entries = initial
        .snapshots
        .iter()
        .enumerate()
        .map(|(index, snapshot)| PersistentProtectedEntry {
            id: if index == 0 { ENTRY } else { OPERATION }.into(),
            key: snapshot.assets[0].key.clone(),
        })
        .collect();
    let c = core(initial.clone());
    assert_locked_projection(&c)?;
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::View)?;
    let open = c.view();
    assert_eq!(open.protected_view.state, ProtectedViewState::Open);
    assert_eq!(
        open.protected_view
            .entries
            .as_ref()
            .ok_or("missing authorized entries")?
            .len(),
        2
    );
    assert!(
        open.photos.is_empty(),
        "An open grant must not authorize the ordinary gallery"
    );
    shell.run(&c, Event::LockProtectedAccess)?;
    assert_locked_projection(&c)?;
    assert_locked_projection(&core(initial))?;
    Ok(())
}

fn assert_locked_projection(core: &Core<Suwop>) -> Result<(), String> {
    let view = core.view();
    let encoded = serde_json::to_string(&view).map_err(|e| e.to_string())?;
    for secret in [
        "PRIVATE-",
        "apple-photo",
        "remote-photo",
        "37.12345",
        "139.12345",
    ] {
        assert!(
            !encoded.contains(secret),
            "locked projection leaked {secret}: {encoded}"
        );
    }
    let value = serde_json::to_value(&view).map_err(|e| e.to_string())?;
    assert_eq!(view.protected_view.state, ProtectedViewState::Locked);
    let protected = value["protectedView"].as_object().ok_or("protected view")?;
    for forbidden in ["entries", "count", "image", "grantID"] {
        assert!(!protected.contains_key(forbidden));
    }
    assert!(value["state"].get("protectedEntries").is_none());
    assert!(view.photos.is_empty());
    Ok(())
}

#[test]
fn authentication_is_required_before_either_provider_membership_can_be_persisted()
-> Result<(), String> {
    for outcome in [
        ProtectedAuthOutcome::Cancelled,
        ProtectedAuthOutcome::Unavailable,
        ProtectedAuthOutcome::Failed,
    ] {
        let initial = saved();
        let keys = initial
            .snapshots
            .iter()
            .flat_map(|s| &s.assets)
            .map(|a| a.key.clone())
            .collect();
        let c = core(initial);
        let mut shell = Shell {
            auth: outcome,
            ..Shell::default()
        };
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::Protect)?;
        shell.run(
            &c,
            Event::ProtectPhotos {
                keys,
                operation_id: OPERATION.into(),
                grant_id: CHALLENGE.into(),
            },
        )?;
        assert!(!shell.effects.contains(&"persist"));
        assert!(shell.durable.is_none());
        assert_eq!(c.view().photos.len(), 1);
        assert_eq!(c.view().protected_view.state, ProtectedViewState::Locked);
    }
    Ok(())
}

#[test]
fn successful_protection_preserves_canonical_sources_but_ordinary_operations_stay_blocked()
-> Result<(), String> {
    let initial = saved();
    let sources = serde_json::to_value(&initial.snapshots).map_err(|e| e.to_string())?;
    let keys = initial
        .snapshots
        .iter()
        .flat_map(|s| &s.assets)
        .map(|a| a.key.clone())
        .collect::<Vec<_>>();
    let c = core(initial);
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::Protect)?;
    shell.run(
        &c,
        Event::ProtectPhotos {
            keys: keys.clone(),
            operation_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
        },
    )?;
    let durable = shell
        .durable
        .as_ref()
        .ok_or("missing protected membership")?;
    assert_eq!(durable.protected_entries.len(), 2);
    assert_eq!(
        serde_json::to_value(&durable.snapshots).map_err(|e| e.to_string())?,
        sources
    );
    assert!(c.view().photos.is_empty());
    for key in keys {
        let effects = c.process_event(Event::Share {
            keys: vec![key],
            id: "ordinary-share".into(),
        });
        assert!(effects.is_empty());
        assert!(c.view().error.is_some());
    }
    Ok(())
}

#[test]
fn background_invalidates_pending_authentication_even_when_its_late_response_succeeds()
-> Result<(), String> {
    let mut initial = saved();
    initial.protected_entries.push(PersistentProtectedEntry {
        id: ENTRY.into(),
        key: initial.snapshots[0].assets[0].key.clone(),
    });
    let c = core(initial);
    let mut shell = Shell::default();
    shell.activate(&c)?;
    let requests = c.process_event(Event::BeginProtectedAccess {
        challenge_id: CHALLENGE.into(),
        scene_id: SCENE.into(),
        purpose: ProtectedPurpose::View,
    });
    let mut authentication = None;
    for Effect::Io(mut request) in requests {
        if matches!(
            request.operation,
            ShellOperation::AuthenticateProtected { .. }
        ) {
            authentication = Some(request);
        } else {
            let response = shell.respond(&request.operation);
            assert!(
                c.resolve(&mut request, reply(response))
                    .map_err(|e| e.to_string())?
                    .is_empty()
            );
        }
    }
    assert_eq!(
        c.view().protected_view.state,
        ProtectedViewState::Authenticating
    );
    shell.run(
        &c,
        Event::ProtectedSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Background,
        },
    )?;
    let mut request = authentication.ok_or("missing authentication effect")?;
    let response = shell.respond(&request.operation);
    assert!(
        c.resolve(&mut request, reply(response))
            .map_err(|e| e.to_string())?
            .is_empty()
    );
    assert_eq!(c.view().protected_view.state, ProtectedViewState::Locked);
    assert!(c.view().protected_view.entries.is_none());
    assert!(c.view().protected_view.grant_id.is_none());
    Ok(())
}

#[test]
fn ambiguous_unprotect_never_publishes_protected_content_from_optimistic_state()
-> Result<(), String> {
    for fault in [PersistenceFault::BeforeWrite, PersistenceFault::AfterWrite] {
        let mut initial = saved();
        for (index, snapshot) in initial.snapshots.iter().enumerate() {
            initial.protected_entries.push(PersistentProtectedEntry {
                id: if index == 0 { ENTRY } else { OPERATION }.into(),
                key: snapshot.assets[0].key.clone(),
            });
        }
        let c = core(initial.clone());
        let mut shell = Shell {
            persistence_fault: Some(fault),
            durable: Some(initial),
            ..Shell::default()
        };
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::View)?;
        shell.run(
            &c,
            Event::UnprotectPhotos {
                ids: vec![ENTRY.into()],
                operation_id: "55555555-5555-4555-8555-555555555555".into(),
                grant_id: CHALLENGE.into(),
            },
        )?;
        assert!(shell.effects.contains(&"persist"));
        assert!(c.view().photos.is_empty());
        assert!(c.view().protected_view.error.is_some());
        assert!(c.view().protected_view.image.is_none());
        let projection = serde_json::to_value(c.view()).map_err(|e| e.to_string())?;
        assert_eq!(projection["photos"], json!([]));
    }
    Ok(())
}

fn protected_apple_core() -> Core<Suwop> {
    let mut state = saved();
    state.protected_entries.push(PersistentProtectedEntry {
        id: ENTRY.into(),
        key: state.snapshots[0].assets[0].key.clone(),
    });
    core(state)
}

fn image_result(ticket: &ProtectedImageTicket) -> Result<Value, String> {
    serde_json::to_value(ProtectedImageResult {
        request_id: ticket.request_id.clone(),
        staged_id: format!("stage-{}", ticket.request_id),
        fresh_apple_asset: Some(asset(Provider::Apple, &ticket.key.asset_id)),
        full_access: true,
    })
    .map_err(|e| e.to_string())
}

fn image_event(request: &str) -> Event {
    Event::RequestProtectedImage {
        entry_id: ENTRY.into(),
        grant_id: CHALLENGE.into(),
        request_id: request.into(),
        kind: ProtectedImageKind::Preview,
    }
}

#[test]
fn membership_persist_ack_does_not_resurrect_apple_content_invalidated_while_pending()
-> Result<(), String> {
    let initial = saved();
    let key = initial.snapshots[0].assets[0].key.clone();
    let c = core(initial);
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::Protect)?;
    let mut requests = c.process_event(Event::ProtectPhotos {
        keys: vec![key.clone()],
        operation_id: OPERATION.into(),
        grant_id: CHALLENGE.into(),
    });
    let Effect::Io(mut persist) = requests.pop().ok_or("missing pending persistence")?;
    assert!(matches!(persist.operation, ShellOperation::Persist(_)));
    shell.run(&c, Event::AppleChanged)?;
    let response = shell.respond(&persist.operation);
    assert!(
        c.resolve(&mut persist, reply(response))
            .map_err(|e| e.to_string())?
            .is_empty()
    );
    let durable = shell
        .durable
        .as_ref()
        .ok_or("missing persisted membership")?;
    assert_eq!(durable.protected_entries[0].key, key);
    shell.run(
        &c,
        Event::BeginProtectedAccess {
            challenge_id: "66666666-6666-4666-8666-666666666666".into(),
            scene_id: SCENE.into(),
            purpose: ProtectedPurpose::View,
        },
    )?;
    assert!(
        c.view()
            .protected_view
            .entries
            .as_ref()
            .is_some_and(|entries| entries.len() == 1 && entries[0].asset.is_none())
    );
    assert!(
        c.view()
            .photos
            .iter()
            .flat_map(|p| &p.assets)
            .all(|a| a.key.provider == Provider::Immich)
    );
    Ok(())
}

#[test]
fn latest_image_request_survives_an_older_success_or_failure_and_lock_clears_it()
-> Result<(), String> {
    for old_success in [true, false] {
        let mut state = saved();
        let second = asset(Provider::Apple, "apple-second");
        state.protected_entries = vec![
            PersistentProtectedEntry {
                id: ENTRY.into(),
                key: state.snapshots[0].assets[0].key.clone(),
            },
            PersistentProtectedEntry {
                id: OPERATION.into(),
                key: second.key.clone(),
            },
        ];
        state.snapshots[0].assets.push(second);
        let c = core(state);
        let mut shell = Shell::default();
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::View)?;
        let mut old_requests = c.process_event(image_event("77777777-7777-4777-8777-777777777777"));
        let Effect::Io(mut old) = old_requests.pop().ok_or("missing first image read")?;
        let old_ticket = match &old.operation {
            ShellOperation::ReadProtectedImage { ticket } => ticket.clone(),
            _ => return Err("first request must stage an Apple image".into()),
        };
        let mut next = c.process_event(Event::RequestProtectedImage {
            entry_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
            request_id: "88888888-8888-4888-8888-888888888888".into(),
            kind: ProtectedImageKind::Preview,
        });
        while let Some(Effect::Io(mut request)) = next.pop() {
            let result = match &request.operation {
                ShellOperation::ReadProtectedImage { ticket }
                | ShellOperation::PublishProtectedImage { ticket, .. } => image_result(ticket),
                _ => shell.respond(&request.operation),
            };
            next.extend(
                c.resolve(&mut request, reply(result))
                    .map_err(|e| e.to_string())?,
            );
        }
        let current = c
            .view()
            .protected_view
            .image
            .ok_or("missing latest approved image")?;
        assert_eq!(current.request_id, "88888888-8888-4888-8888-888888888888");
        let result = if old_success {
            image_result(&old_ticket)
        } else {
            Err("late old read failed".into())
        };
        let late_completion = c
            .resolve(&mut old, reply(result))
            .map_err(|e| e.to_string())?;
        for Effect::Io(mut release) in late_completion {
            assert!(
                matches!(&release.operation, ShellOperation::ReleaseProtectedImage { staged_id }
                if staged_id == &format!("stage-{}", old_ticket.request_id))
            );
            assert!(
                c.resolve(&mut release, reply(Ok(Value::Null)))
                    .map_err(|e| e.to_string())?
                    .is_empty()
            );
        }
        let retained = c.view().protected_view.image.ok_or("latest image erased")?;
        assert_eq!(retained.request_id, current.request_id);
        assert_eq!(retained.staged_id, current.staged_id);
        assert!(c.view().protected_view.error.is_none());
        shell.run(&c, Event::LockProtectedAccess)?;
        assert!(c.view().protected_view.image.is_none());
    }
    Ok(())
}

#[test]
fn failed_final_native_publish_releases_exact_staged_image_without_whole_grant_cleanup()
-> Result<(), String> {
    let c = protected_apple_core();
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::View)?;
    let mut requests = c.process_event(image_event("99999999-9999-4999-8999-999999999999"));
    let Effect::Io(mut read) = requests.pop().ok_or("missing read")?;
    let ticket = match &read.operation {
        ShellOperation::ReadProtectedImage { ticket } => ticket.clone(),
        _ => return Err("expected read".into()),
    };
    let mut requests = c
        .resolve(&mut read, reply(image_result(&ticket)))
        .map_err(|e| e.to_string())?;
    let Effect::Io(mut publish) = requests.pop().ok_or("missing publish")?;
    assert!(matches!(
        publish.operation,
        ShellOperation::PublishProtectedImage { .. }
    ));
    let mut cleanup = c
        .resolve(&mut publish, reply(Err("publication unavailable".into())))
        .map_err(|e| e.to_string())?;
    let Effect::Io(mut release) = cleanup.pop().ok_or("stage leaked after failed publish")?;
    assert!(
        matches!(&release.operation, ShellOperation::ReleaseProtectedImage { staged_id }
        if staged_id == &format!("stage-{}", ticket.request_id))
    );
    assert!(
        c.resolve(&mut release, reply(Ok(Value::Null)))
            .map_err(|e| e.to_string())?
            .is_empty()
    );
    assert!(c.view().protected_view.image.is_none());
    assert_eq!(c.view().protected_view.state, ProtectedViewState::Open);
    Ok(())
}

#[test]
fn unavailable_or_hidden_source_can_be_unprotected_without_granting_provider_read_access()
-> Result<(), String> {
    for hidden in [false, true] {
        let mut state = saved();
        state.protected_entries.push(PersistentProtectedEntry {
            id: ENTRY.into(),
            key: state.snapshots[0].assets[0].key.clone(),
        });
        if hidden {
            state.snapshots[0].assets[0].apple_visibility = AppleVisibility::Hidden;
        } else {
            state.snapshots[0].access = ScanAccess::Unavailable;
        }
        let c = core(state);
        let mut shell = Shell::default();
        assert!(c.view().protected_view.entries.is_none());
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::View)?;
        let entries = c
            .view()
            .protected_view
            .entries
            .ok_or("missing local entries")?;
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].id, ENTRY);
        assert!(
            entries[0].asset.is_none(),
            "Local record removal must not reveal provider-private facts"
        );
        assert!(
            c.process_event(image_event("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
                .is_empty()
        );
        shell.run(
            &c,
            Event::UnprotectPhotos {
                ids: vec![ENTRY.into()],
                operation_id: OPERATION.into(),
                grant_id: CHALLENGE.into(),
            },
        )?;
        assert!(
            shell
                .durable
                .as_ref()
                .ok_or("missing unprotect persistence")?
                .protected_entries
                .is_empty()
        );
        assert!(
            c.view()
                .photos
                .iter()
                .flat_map(|p| &p.assets)
                .all(|a| a.key.provider == Provider::Immich)
        );
        assert!(!shell.effects.iter().any(|effect| effect == &"read-image"));
    }
    Ok(())
}

fn histories(state: &mut SavedLibrary) -> Result<(), String> {
    use suwop_core::domain::{FileSignature, TransferIntent, TransferPhase, TransferReceipt};
    use suwop_core::immich::{PendingUpload, UploadIntent, UploadPhase};
    let private = state.snapshots[0].assets[0].clone();
    let public = state.snapshots[1].assets[0].clone();
    let signature = FileSignature {
        sha256: "b".repeat(64),
        bytes: 987_654,
    };
    let mut receipt = TransferReceipt {
        id: "PRIVATE-receipt".into(),
        created_at: 1.0,
        phase: TransferPhase::Copied,
        intent: TransferIntent::Copy,
        source: vec![private.clone()],
        destination: vec![public.clone()],
        destination_provider: Provider::Immich,
        destination_scope: "remote".into(),
        signatures: [signature.clone()].into(),
    };
    state.receipts.push(receipt.clone());
    receipt.id = "public-independent-history".into();
    receipt.source = vec![public.clone()];
    receipt.signatures = [FileSignature {
        sha256: "c".repeat(64),
        bytes: 4321,
    }]
    .into();
    state.receipts.push(receipt);
    state.pending_uploads.push(PendingUpload {
        key: public.key.clone(),
        source: private.clone(),
        resource: private.resources[0].clone(),
        signature: signature.clone(),
        live_id: Some("PRIVATE-live-id".into()),
        phase: UploadPhase::MetadataStarted,
    });
    state.upload_intents.push(UploadIntent {
        scope: "remote".into(),
        token: "PRIVATE-intent".into(),
        source: private.clone(),
        resource: private.resources[0].clone(),
        signature,
        live_id: None,
    });
    state
        .pending_apple_trash
        .push(suwop_core::trash::AppleTrashOperation {
            id: "PRIVATE-trash-operation".into(),
            scope: "apple".into(),
            assets: vec![private.clone()],
            outcome: suwop_core::trash::AppleTrashOutcome::NotApplied,
            visibility: None,
        });
    state.apple_visibility_operations = serde_json::from_value(json!([{
        "id":"PRIVATE-visibility-operation", "scope":"apple", "action":"hide", "outcome":"notApplied",
        "targets":[{"key":private.key,"witnessDigest":"PRIVATE-witness","observation":null}]
    }])).map_err(|e| e.to_string())?;
    add_edit_and_trash_histories(state, &private)
}

fn add_edit_and_trash_histories(
    state: &mut SavedLibrary,
    private: &StoredAsset,
) -> Result<(), String> {
    use suwop_core::editing::{
        AppleAdjustment, EditClipboard, EditCopyOptions, ImageTransform, PixelSize,
    };
    let dimensions = PixelSize {
        width: 20,
        height: 30,
    };
    let transform = ImageTransform::original(dimensions)?;
    state.edit_clipboard = Some(EditClipboard {
        source_key: Some(private.key.clone()),
        source_name: private.name.clone(),
        dimensions,
        transform,
        options: EditCopyOptions {
            adjustments: true,
            filter: false,
            geometry: false,
        },
    });
    state.pending_edit_pastes = serde_json::from_value(json!([{
        "key": private.key, "name": "PRIVATE-paste",
        "before":{"assets":[private],"files":[]},"initialAdjustment":null,
        "plan":{"dimensions":dimensions,"orientation":1,"transform":transform,"outputFormat":"jpeg",
            "adjustment":AppleAdjustment { format_identifier:"PRIVATE-format".into(), format_version:"1".into(), data:"PRIVATE-data".into() }}
    }])).map_err(|e| e.to_string())?;
    let identity = json!({"key": private.key, "name":private.name,"checksum":"PRIVATE-checksum",
        "mediaType":"IMAGE","createdAt":"PRIVATE-date","modifiedAt":"PRIVATE-date","livePhotoVideoID":null});
    state.pending_trash = serde_json::from_value(json!([{
        "id":"PRIVATE-remote-trash", "scope":"apple", "action":"trash", "assets":[identity.clone()]
    }]))
    .map_err(|e| e.to_string())?;
    state.trash = serde_json::from_value(json!({"scope":"apple", "verified":true,
        "items":[{"asset":private,"identity":identity}]}))
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[test]
fn protected_related_history_disappears_from_ordinary_projection_even_with_an_open_grant()
-> Result<(), String> {
    let mut state = saved();
    histories(&mut state)?;
    state.protected_entries.push(PersistentProtectedEntry {
        id: ENTRY.into(),
        key: state.snapshots[0].assets[0].key.clone(),
    });
    let canonical = serde_json::to_value(&state).map_err(|e| e.to_string())?;
    let c = core(state);
    assert_private_histories(&c)?;
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::View)?;
    assert_private_histories(&c)?;
    shell.run(
        &c,
        Event::UnprotectPhotos {
            ids: vec![ENTRY.into()],
            operation_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
        },
    )?;
    let durable = serde_json::to_value(shell.durable.ok_or("missing canonical save")?)
        .map_err(|e| e.to_string())?;
    for field in [
        "receipts",
        "pendingUploads",
        "uploadIntents",
        "pendingAppleTrash",
        "appleVisibilityOperations",
        "pendingEditPastes",
        "editClipboard",
        "pendingTrash",
        "trash",
        "snapshots",
    ] {
        assert_eq!(
            durable[field], canonical[field],
            "Projection must never overwrite canonical {field}"
        );
    }
    Ok(())
}

fn assert_private_histories(c: &Core<Suwop>) -> Result<(), String> {
    let view = c.view();
    let mut encoded = serde_json::to_value(&view).map_err(|e| e.to_string())?;
    encoded
        .as_object_mut()
        .ok_or("view object")?
        .remove("protectedView");
    let text = encoded.to_string();
    for secret in [
        "PRIVATE-receipt",
        "PRIVATE-intent",
        "PRIVATE-trash-operation",
        "PRIVATE-visibility-operation",
        "PRIVATE-paste",
        "PRIVATE-remote-trash",
        "apple-photo",
        "PRIVATE-checksum",
        "987654",
    ] {
        assert!(
            !text.contains(secret),
            "Protected history leaked {secret}: {text}"
        );
    }
    assert_eq!(view.state.receipts.len(), 1);
    assert_eq!(view.state.receipts[0].id, "public-independent-history");
    assert_eq!(
        view.state.receipts[0].source[0],
        asset(Provider::Immich, "remote-photo")
    );
    assert!(view.state.pending_uploads.is_empty() && view.state.upload_intents.is_empty());
    assert!(
        view.state.pending_apple_trash.is_empty()
            && view.state.apple_visibility_operations.is_empty()
    );
    assert!(view.state.pending_edit_pastes.is_empty() && view.state.edit_clipboard.is_none());
    assert!(view.state.pending_trash.is_empty());
    Ok(())
}

#[test]
fn immich_post_stage_unavailable_or_locked_readback_releases_only_the_acquired_stage()
-> Result<(), String> {
    use suwop_core::immich::Asset;
    for locked in [false, true] {
        let original: Asset = serde_json::from_value(json!({
            "id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "ownerId":"owner", "type":"IMAGE",
            "originalFileName":"protected-remote.jpg", "checksum":"a".repeat(40),
            "fileCreatedAt":"2026-01-01T00:00:00.000Z", "fileModifiedAt":"2026-01-01T00:00:00.000Z",
            "updatedAt":"2026-01-01T00:00:00.000Z", "isFavorite":false, "isOffline":false,
            "isTrashed":false,"visibility":"timeline","isExternal":false,"libraryId":null
        }))
        .map_err(|e| e.to_string())?;
        let remote = original.record("remote", None, None);
        let mut state = saved();
        state.snapshots[1].assets = vec![remote.clone()];
        state.protected_entries.push(PersistentProtectedEntry {
            id: ENTRY.into(),
            key: remote.key,
        });
        let c = core(state);
        let mut shell = Shell::default();
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::View)?;
        let mut requests = c.process_event(image_event("cccccccc-cccc-4ccc-8ccc-cccccccccccc"));
        let mut reads = 0;
        let mut releases = 0;
        let mut stages = 0;
        while let Some(Effect::Io(mut request)) = requests.pop() {
            let result = match &request.operation {
                ShellOperation::Http(http) => {
                    assert_eq!(http.method, "GET");
                    assert!(http.url.ends_with(&original.id));
                    reads += 1;
                    if reads == 1 {
                        Ok(json!({"status":200,"body":original}))
                    } else if locked {
                        let mut changed = original.clone();
                        changed.visibility = Some("locked".into());
                        Ok(json!({"status":200,"body":changed}))
                    } else {
                        Err("fresh provider read unavailable".into())
                    }
                }
                ShellOperation::ReadProtectedImage { ticket } => {
                    stages += 1;
                    Ok(
                        json!({"requestID":ticket.request_id,"stagedID":"held-remote-stage",
                        "freshAppleAsset":null,"fullAccess":true}),
                    )
                }
                ShellOperation::ReleaseProtectedImage { staged_id } => {
                    assert_eq!(staged_id, "held-remote-stage");
                    releases += 1;
                    Ok(Value::Null)
                }
                other => return Err(format!("Unexpected image effect: {other:?}")),
            };
            requests.extend(
                c.resolve(&mut request, reply(result))
                    .map_err(|e| e.to_string())?,
            );
        }
        assert_eq!((reads, stages, releases), (2, 1, 1));
        assert!(c.view().protected_view.image.is_none());
        assert!(c.view().protected_view.error.is_some());
    }
    Ok(())
}

#[test]
fn ambiguous_actual_protect_write_cannot_be_overwritten_by_unrelated_work_before_read_only_recovery()
-> Result<(), String> {
    use suwop_core::domain::TransferIntent;
    let initial = saved();
    let protected_key = initial.snapshots[0].assets[0].key.clone();
    let unrelated_key = initial.snapshots[1].assets[0].key.clone();
    let c = core(initial);
    let mut shell = Shell {
        persistence_fault: Some(PersistenceFault::AfterWrite),
        ..Shell::default()
    };
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::Protect)?;
    shell.run(
        &c,
        Event::ProtectPhotos {
            keys: vec![protected_key.clone()],
            operation_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
        },
    )?;
    assert!(c.view().protected_view.persistence_uncertain);
    let durable = shell
        .durable
        .as_ref()
        .ok_or("fixture must have actually written membership")?
        .clone();
    assert_eq!(durable.protected_entries[0].key, protected_key);
    let before = shell.effects.clone();
    for event in [
        Event::Refresh {
            permission: false,
            now: 2.0,
        },
        Event::SetFavorite {
            keys: vec![unrelated_key.clone()],
            value: true,
        },
        Event::Copy {
            keys: vec![unrelated_key],
            intent: TransferIntent::Copy,
            id: "unrelated-copy".into(),
            now: 2.0,
        },
    ] {
        assert!(
            c.process_event(event).is_empty(),
            "No mutation or stale Persist is allowed during uncertainty"
        );
    }
    assert_eq!(shell.effects, before);
    assert!(!c.view().can_transfer);
    let mut requests = c.process_event(Event::ReconcileProtectedState {
        grant_id: CHALLENGE.into(),
    });
    let Effect::Io(mut read) = requests.pop().ok_or("missing explicit recovery read")?;
    assert!(matches!(read.operation, ShellOperation::ReadState));
    assert!(
        c.resolve(
            &mut read,
            reply(serde_json::to_value(&durable).map_err(|e| e.to_string()))
        )
        .map_err(|e| e.to_string())?
        .is_empty()
    );
    assert!(!c.view().protected_view.persistence_uncertain);
    assert!(
        c.view()
            .state
            .snapshots
            .iter()
            .all(|s| s.access == ScanAccess::Unavailable),
        "Recovery must invalidate cached provider visibility"
    );
    assert!(
        c.view()
            .state
            .snapshots
            .iter()
            .filter(|s| s.provider == Provider::Apple)
            .all(|s| s.assets.is_empty())
    );
    assert!(c.view().protected_view.image.is_none());
    assert_eq!(
        shell
            .effects
            .iter()
            .filter(|effect| effect == &&"persist")
            .count(),
        1
    );
    assert_eq!(
        shell
            .durable
            .as_ref()
            .ok_or("durable state")?
            .protected_entries[0]
            .key,
        protected_key
    );
    Ok(())
}

#[test]
fn disconnected_protection_records_remain_anonymous_and_locally_removable_after_fresh_auth()
-> Result<(), String> {
    let mut initial = saved();
    let remote = initial.snapshots[1].assets[0].clone();
    initial.protected_entries.push(PersistentProtectedEntry {
        id: ENTRY.into(),
        key: remote.key.clone(),
    });
    let c = core(initial);
    let mut shell = Shell::default();
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::View)?;
    shell.run(&c, Event::Disconnect)?;
    assert_eq!(c.view().protected_view.state, ProtectedViewState::Locked);
    let writes = shell.effects.iter().filter(|e| **e == "persist").count();
    shell.run(
        &c,
        Event::UnprotectPhotos {
            ids: vec![ENTRY.into()],
            operation_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
        },
    )?;
    assert_eq!(
        shell.effects.iter().filter(|e| **e == "persist").count(),
        writes
    );
    let fresh = "55555555-5555-4555-8555-555555555555";
    shell.run(
        &c,
        Event::BeginProtectedAccess {
            challenge_id: fresh.into(),
            scene_id: SCENE.into(),
            purpose: ProtectedPurpose::View,
        },
    )?;
    let view = c.view();
    let entries = view
        .protected_view
        .entries
        .as_ref()
        .ok_or("missing local records")?;
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].id, ENTRY);
    assert!(entries[0].asset.is_none());
    let serialized = serde_json::to_string(&view).map_err(|e| e.to_string())?;
    assert!(!serialized.contains(&remote.name));
    assert!(!serialized.contains(&remote.revision));
    assert!(!serialized.contains(&remote.key.asset_id));
    assert!(
        serde_json::to_string(&view.protected_view)
            .map_err(|e| e.to_string())?
            .contains("\"asset\":null")
    );
    shell.run(
        &c,
        Event::RequestProtectedImage {
            entry_id: ENTRY.into(),
            grant_id: fresh.into(),
            request_id: "66666666-6666-4666-8666-666666666666".into(),
            kind: ProtectedImageKind::Preview,
        },
    )?;
    assert!(c.view().protected_view.image.is_none());
    shell.run(
        &c,
        Event::UnprotectPhotos {
            ids: vec![ENTRY.into()],
            operation_id: "77777777-7777-4777-8777-777777777777".into(),
            grant_id: fresh.into(),
        },
    )?;
    assert!(
        shell
            .durable
            .as_ref()
            .ok_or("no durable local unprotect")?
            .protected_entries
            .is_empty()
    );
    assert!(
        c.view()
            .state
            .snapshots
            .iter()
            .all(|s| s.provider != Provider::Immich)
    );
    Ok(())
}

#[test]
fn other_account_auth_can_remove_only_local_record_without_exposing_old_provider_content()
-> Result<(), String> {
    for connected in [false, true] {
        let mut initial = saved();
        let remote = initial.snapshots[1].assets[0].clone();
        initial.protected_entries.push(PersistentProtectedEntry {
            id: ENTRY.into(),
            key: remote.key.clone(),
        });
        let c = Core::new_with(
            Suwop,
            Model {
                ready: true,
                state: initial,
                session: connected.then(|| Session {
                    ordinary_content_guard: None,
                    ordinary_content_context: None,
                    endpoint: "https://other.example/api".into(),
                    key: "other-key".into(),
                    scope: "other-account".into(),
                    user_id: "other-owner".into(),
                    version: Version {
                        major: 3,
                        minor: 2,
                        patch: 4,
                    },
                }),
                ..Model::default()
            },
        );
        let mut shell = Shell::default();
        shell.activate(&c)?;
        shell.authenticate(&c, ProtectedPurpose::View)?;
        let entries = c
            .view()
            .protected_view
            .entries
            .ok_or("local record hidden")?;
        assert_eq!(entries.len(), 1);
        assert!(entries[0].asset.is_none());
        let serialized =
            serde_json::to_string(&c.view().protected_view).map_err(|e| e.to_string())?;
        for private in [
            &remote.name,
            &remote.key.scope,
            &remote.key.asset_id,
            &remote.revision,
        ] {
            assert!(!serialized.contains(private));
        }
        shell.run(&c, image_event("66666666-6666-4666-8666-666666666666"))?;
        assert!(c.view().protected_view.image.is_none());
        shell.run(
            &c,
            Event::UnprotectPhotos {
                ids: vec![ENTRY.into()],
                operation_id: OPERATION.into(),
                grant_id: CHALLENGE.into(),
            },
        )?;
        let durable = shell.durable.as_ref().ok_or("no durable local change")?;
        assert!(durable.protected_entries.is_empty());
        assert_eq!(durable.snapshots[1].assets[0].revision, remote.revision);
        assert_eq!(
            durable.snapshots[1].assets[0].resources[0].name,
            remote.resources[0].name
        );
        assert!(!shell.effects.contains(&"http"));
    }
    Ok(())
}

#[test]
fn ambiguous_protection_save_disables_unrelated_archive_hint_until_validated_recovery()
-> Result<(), String> {
    use suwop_core::{
        immich_archive::ImmichArchiveDestination, immich_visibility::ImmichVisibility,
    };
    let mut initial = saved();
    initial.snapshots[1].assets[0].immich_visibility = Some(ImmichVisibility::Timeline);
    initial.snapshots[1].assets[0].immich_stack = suwop_core::domain::ImmichStackState::Unstacked;
    let a = initial.snapshots[0].assets[0].key.clone();
    let b = initial.snapshots[1].assets[0].key.clone();
    let c = core(initial);
    assert_eq!(
        c.view().immich_archive_actions[0].to,
        Some(ImmichArchiveDestination::Archive)
    );
    let mut shell = Shell {
        persistence_fault: Some(PersistenceFault::AfterWrite),
        ..Shell::default()
    };
    shell.run(
        &c,
        Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    shell.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(SCENE)
    );
    shell.activate(&c)?;
    shell.authenticate(&c, ProtectedPurpose::Protect)?;
    shell.run(
        &c,
        Event::ProtectPhotos {
            keys: vec![a],
            operation_id: OPERATION.into(),
            grant_id: CHALLENGE.into(),
        },
    )?;
    assert!(c.view().protected_view.persistence_uncertain);
    let hint = c
        .view()
        .immich_archive_actions
        .into_iter()
        .find(|h| h.key == b)
        .ok_or("unrelated retained hint")?;
    assert_eq!(hint.to, None);
    assert_eq!(
        hint.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unavailable)
    );
    let effects = shell.effects.clone();
    assert!(
        c.process_event(Event::PrepareImmichArchive {
            key: b,
            to: ImmichArchiveDestination::Archive,
            operation_id: "55555555-5555-4555-8555-555555555555".into(),
            scene_id: SCENE.into()
        })
        .is_empty()
    );
    assert_eq!(shell.effects, effects);
    let durable = shell.durable.as_ref().ok_or("actual write")?;
    let mut requests = c.process_event(Event::ReconcileProtectedState {
        grant_id: CHALLENGE.into(),
    });
    let Effect::Io(mut read) = requests.pop().ok_or("recovery read")?;
    assert!(matches!(read.operation, ShellOperation::ReadState));
    assert!(
        c.resolve(
            &mut read,
            reply(serde_json::to_value(durable).map_err(|e| e.to_string()))
        )
        .map_err(|e| e.to_string())?
        .is_empty()
    );
    assert!(!c.view().protected_view.persistence_uncertain);
    assert!(
        c.view().immich_archive_actions.is_empty(),
        "Recovery invalidates snapshots; only a fresh scan can restore actions"
    );
    Ok(())
}

#[test]
fn shared_snapshot_action_hints_match_fresh_projection_with_pending_denials() -> Result<(), String>
{
    use crux_core::App;
    let mut model = Model {
        state: saved(),
        ready: true,
        ..Model::default()
    };
    model.session = Some(Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "fixture-key".into(),
        scope: "remote".into(),
        user_id: "owner".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    });
    let denied = asset(Provider::Immich, "remote-photo").key;
    let baseline = Suwop.view(&model);
    assert!(
        baseline
            .immich_visibility_actions
            .iter()
            .any(|hint| hint.key == denied)
    );
    assert!(
        baseline
            .immich_archive_actions
            .iter()
            .any(|hint| hint.key == denied)
    );
    for visibility_denial in [false, true] {
        model.protection.denied.clear();
        model.immich_visibility.denied.clear();
        if visibility_denial {
            model.immich_visibility.denied.insert(denied.clone());
        } else {
            model.protection.denied.insert(denied.clone());
        }
        let view = Suwop.view(&model);
        assert_eq!(
            serde_json::to_value(&view.immich_archive_actions).map_err(|e| e.to_string())?,
            serde_json::to_value(suwop_core::immich_archive::actions(&model))
                .map_err(|e| e.to_string())?
        );
        assert_eq!(
            serde_json::to_value(&view.immich_visibility_actions).map_err(|e| e.to_string())?,
            serde_json::to_value(suwop_core::immich_visibility::actions(&model))
                .map_err(|e| e.to_string())?
        );
        assert!(
            view.immich_archive_actions
                .iter()
                .all(|hint| hint.key != denied)
        );
        assert!(
            view.immich_visibility_actions
                .iter()
                .all(|hint| hint.key != denied)
        );
        assert!(model.state.protected_entries.is_empty());
    }
    Ok(())
}
