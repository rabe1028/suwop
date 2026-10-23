use super::*;
use suwop_core::ordinary_selected::{
    OrdinarySelectedImageKind as Kind, OrdinarySelectedImageTicket,
};
const CHILD: &str = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
fn seed() -> Result<SavedLibrary, String> {
    let (c, mut shell) = opened(false)?;
    shell.run(
        &c,
        prepare(OP, suwop_core::immich_visibility::ImmichVisibility::Locked),
    )?;
    shell.relationship = Some(json!(CHILD));
    shell.run(&c, inspect())?;
    suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)
}
fn ordinary(state: SavedLibrary) -> Core<Suwop> {
    ordinary_version(
        state,
        Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    )
}
fn ordinary_version(state: SavedLibrary, version: Version) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(Session {
                ordinary_content_guard: None,
                ordinary_content_context: None,
                endpoint: "https://fixture.example/api".into(),
                key: "ordinary-secret".into(),
                user_id: OWNER.into(),
                scope: key().scope,
                version,
            }),
            ready: true,
            ..Model::default()
        },
    )
}
struct ReadShell {
    fail_apple: bool,
    apple_assets: Vec<suwop_core::domain::StoredAsset>,
    raw: Value,
    extra: Vec<Value>,
    pin: Shell,
    failure: Option<u16>,
    listed: Vec<Value>,
    disk: Option<Value>,
    persists: usize,
    unexpected: usize,
    paths: Vec<String>,
    staged: usize,
    released: Vec<String>,
    drift_read: Option<Value>,
    drift_publish: Option<Value>,
    fail_publish: bool,
    stale_authorizations: usize,
}
impl Default for ReadShell {
    fn default() -> Self {
        let mut raw = asset();
        raw["livePhotoVideoId"] = json!(CHILD);
        Self {
            fail_apple: false,
            apple_assets: Vec::new(),
            extra: Vec::new(),
            pin: Shell {
                confirmed: true,
                ..Shell::default()
            },
            failure: None,
            listed: vec![raw.clone()],
            raw,
            disk: None,
            persists: 0,
            unexpected: 0,
            paths: vec![],
            staged: 0,
            released: vec![],
            drift_read: None,
            drift_publish: None,
            fail_publish: false,
            stale_authorizations: 0,
        }
    }
}
impl ReadShell {
    fn http(
        &mut self,
        c: &Core<Suwop>,
        request: &suwop_core::immich::HttpRequest,
    ) -> Result<Value, String> {
        if request.headers.contains_key("Authorization")
            || request.url.ends_with("/server/features")
            || request.url.ends_with("/auth/login")
        {
            return self.pin.respond(&ShellOperation::Http(request.clone()));
        }
        assert!(request.headers.contains_key("x-api-key"));
        assert!(!request.headers.contains_key("Authorization"));
        let path = request
            .url
            .strip_prefix("https://fixture.example/api/")
            .ok_or("scope")?;
        self.paths.push(path.into());
        let body = if path == "server/version" {
            json!({"major":3,"minor":2,"patch":4})
        } else if path == "users/me" {
            json!({"id":OWNER})
        } else if path == "search/metadata" {
            json!({"assets":{"items":self.listed,"nextCursor":null}})
        } else if let Some(id) = path.strip_prefix("assets/").filter(|id| !id.contains('/')) {
            let auth = request
                .ordinary_content_authorization
                .as_ref()
                .ok_or("metadata authorization")?;
            let mut expected = key();
            expected.asset_id = id.into();
            assert_eq!(auth.source_keys, vec![expected]);
            assert!(!auth.expected_revision.is_empty());
            assert!(matches!(
                auth.purpose,
                suwop_core::immich::OrdinaryContentPurpose::SelectedPresentationMetadata
            ));
            // Native access rejects a revision other than the current projection's.
            if auth.expected_revision != c.view().private_content_revision {
                self.stale_authorizations += 1;
            }
            if let Some(status) = self.failure {
                return Ok(json!({"status":status,"body":null}));
            }
            if id == ASSET {
                self.raw.clone()
            } else {
                self.extra
                    .iter()
                    .find(|a| a["id"] == id)
                    .cloned()
                    .ok_or("unexpected ID")?
            }
        } else {
            return Err("unexpected ordinary route".into());
        };
        Ok(json!({"status":200,"body":body}))
    }
    fn respond(&mut self, c: &Core<Suwop>, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::ReadState => Ok(self.disk.clone().unwrap_or(Value::Null)),
            ShellOperation::ReadCredential { .. } => Ok(json!("ordinary-secret")),
            ShellOperation::AppleScan { .. } if self.fail_apple => {
                Err("fixture scan failure".into())
            }
            ShellOperation::AuthenticateProtected { challenge } => Ok(
                json!({"challengeID":challenge.challenge_id,"sceneID":challenge.scene_id,"scope":challenge.scope,"outcome":"success"}),
            ),
            ShellOperation::ReleaseProtectedImages { .. }
            | ShellOperation::ReleaseOrdinarySelectedImages { .. } => Ok(Value::Null),
            ShellOperation::AppleScan { scope, .. } => Ok(
                json!({"provider":"apple","scope":scope,"access":"full","assets":self.apple_assets,"scannedAt":1}),
            ),
            ShellOperation::Persist(state) => {
                self.persists += 1;
                self.disk = Some(serde_json::to_value(state).map_err(|_| "encode")?);
                Ok(Value::Null)
            }
            ShellOperation::Http(request) => self.http(c, request),
            ShellOperation::ReadOrdinarySelectedImage { ticket } => {
                Self::pending(c, ticket);
                assert!(
                    ticket
                        .request
                        .url
                        .contains(&format!("assets/{}/thumbnail?", ticket.key.asset_id))
                );
                assert!(!ticket.request.url.contains("original"));
                self.staged += 1;
                if let Some(raw) = self.drift_read.take() {
                    self.raw = raw;
                }
                Ok(
                    json!({"requestID":ticket.request_id,"stagedID":format!("raster{}",self.staged)}),
                )
            }
            ShellOperation::PublishOrdinarySelectedImage { ticket, staged_id } => {
                Self::pending(c, ticket);
                if let Some(raw) = self.drift_publish.take() {
                    self.raw = raw;
                }
                if self.fail_publish {
                    return Err("fixture publish failure".into());
                }
                Ok(json!({"requestID":ticket.request_id,"stagedID":staged_id}))
            }
            ShellOperation::ReleaseOrdinarySelectedImage { staged_id } => {
                self.released.push(staged_id.clone());
                Ok(Value::Null)
            }
            ShellOperation::ScheduleImmichLockedExpiry { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ReleaseImmichLockedImage { .. } => self.pin.respond(op),
            _ => {
                self.unexpected += 1;
                Err("unexpected privileged effect".into())
            }
        }
    }
    fn pending(c: &Core<Suwop>, ticket: &OrdinarySelectedImageTicket) {
        assert!(
            c.view()
                .ordinary_selected_pending
                .iter()
                .any(|p| p.request_id == ticket.request_id
                    && p.scene_id == ticket.scene_id
                    && p.key == ticket.key
                    && p.kind == ticket.kind
                    && p.proof_id == ticket.proof_id
                    && p.generation == ticket.generation)
        );
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.respond(c, &request.operation) {
                Ok(v) => ShellResponse {
                    value: Some(v),
                    error: None,
                },
                Err(e) => ShellResponse {
                    value: None,
                    error: Some(e),
                },
            };
            effects.extend(c.resolve(&mut request, response).map_err(|_| "resolve")?);
        }
        Ok(())
    }
    fn run(&mut self, c: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.drain(c, c.process_event(event))
    }
    fn refresh(&mut self, c: &Core<Suwop>) -> Result<(), String> {
        self.run(
            c,
            Event::Refresh {
                permission: false,
                now: 1_800_000_000.0,
            },
        )
    }
}
fn image(id: &str, kind: Kind) -> Event {
    Event::RequestOrdinarySelectedImage {
        key: key(),
        scene_id: SCENE.into(),
        request_id: id.into(),
        kind,
    }
}
#[test]
fn explicit_ordinary_refresh_restores_only_current_own_still_without_pin_or_journal_changes()
-> Result<(), String> {
    let state = seed()?;
    let journal =
        serde_json::to_value(&state.immich_visibility_operations).map_err(|_| "journal")?;
    assert_eq!(
        state.immich_visibility_operations[0]
            .selected_observation
            .as_ref()
            .ok_or("observation")?
            .visibility,
        suwop_core::immich_visibility::ImmichVisibility::Locked
    );
    let c = ordinary(state);
    let mut shell = ReadShell::default();
    assert!(c.view().ordinary_selected_presentation.is_empty());
    shell.refresh(&c)?;
    let view = c.view();
    assert_eq!(view.ordinary_selected_presentation.len(), 1);
    assert!(!view.ordinary_content_keys.contains(&key()));
    assert!(
        view.photos
            .iter()
            .any(|p| p.assets.iter().any(|a| a.key == key()))
    );
    assert!(
        view.immich_archive_actions
            .iter()
            .all(|h| h.key != key() || h.to.is_none())
    );
    assert!(
        view.immich_visibility_actions
            .iter()
            .all(|h| h.key != key() || !h.can_lock)
    );
    let disk = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
    assert_eq!(
        serde_json::to_value(disk.immich_visibility_operations).map_err(|_| "journal")?,
        journal
    );
    shell.run(&c, image(NEXT, Kind::Preview))?;
    assert_eq!(c.view().ordinary_selected_images.len(), 1);
    assert_eq!(shell.staged, 1);
    assert!(
        shell
            .paths
            .iter()
            .all(|p| p == "search/metadata" || p == &format!("assets/{ASSET}"))
    );
    let restarted = ordinary(suwop_core::workflow::migrate(shell.disk.ok_or("disk")?)?);
    assert!(restarted.view().ordinary_selected_presentation.is_empty());
    Ok(())
}
#[test]
fn first_refresh_publishes_its_session_before_authorizing_metadata() -> Result<(), String> {
    let c = Core::new_with(
        Suwop,
        Model {
            state: seed()?,
            ready: true,
            ..Model::default()
        },
    );
    let mut shell = ReadShell::default();
    // Hydrate the selected photo last (IDs sort before it): its metadata read
    // is answered only after the first partial publication.
    let extras = (0..40).map(|i| {
        let mut extra = asset();
        extra["id"] = json!(format!("11111111-1111-4111-8111-{i:012}"));
        extra
    });
    shell.listed.splice(0..0, extras);
    shell.refresh(&c)?;
    assert!(shell.paths.contains(&format!("assets/{ASSET}")));
    assert_eq!(shell.stale_authorizations, 0);
    assert_eq!(c.view().ordinary_selected_presentation.len(), 1);
    Ok(())
}
#[test]
fn staged_read_and_final_publish_drift_release_exact_raster() -> Result<(), String> {
    for publish in [false, true] {
        let c = ordinary(seed()?);
        let mut shell = ReadShell::default();
        shell.refresh(&c)?;
        let mut changed = shell.raw.clone();
        changed["visibility"] = json!("locked");
        if publish {
            shell.drift_publish = Some(changed);
        } else {
            shell.drift_read = Some(changed);
        }
        shell.run(&c, image(NEXT, Kind::Preview))?;
        assert!(c.view().ordinary_selected_images.is_empty());
        assert!(c.view().ordinary_selected_presentation.is_empty());
        assert_eq!(shell.released, vec!["raster1"]);
    }
    Ok(())
}
#[test]
fn forged_operation_events_remain_denied_while_photo_is_present() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    let before = shell.paths.len();
    shell.run(
        &c,
        Event::SetFavorite {
            keys: vec![key()],
            value: true,
        },
    )?;
    shell.run(
        &c,
        Event::Share {
            keys: vec![key()],
            id: NEXT.into(),
        },
    )?;
    shell.run(
        &c,
        Event::Play {
            keys: vec![key()],
            id: NEXT.into(),
        },
    )?;
    shell.run(
        &c,
        Event::EditImage {
            key: key(),
            id: NEXT.into(),
        },
    )?;
    assert_eq!(shell.paths.len(), before);
    assert_eq!(shell.staged, 0);
    Ok(())
}
fn hold_read(
    c: &Core<Suwop>,
    shell: &mut ReadShell,
    event: Event,
) -> Result<crux_core::Request<ShellOperation>, String> {
    let mut effects = c.process_event(event);
    loop {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(
            request.operation,
            ShellOperation::ReadOrdinarySelectedImage { .. }
        ) {
            return Ok(request);
        }
        let value = shell.respond(c, &request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    }
}
#[test]
fn cancellation_and_cross_scene_concurrency_preserve_other_approved_image() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    let mut held = hold_read(&c, &mut shell, image(NEXT, Kind::Thumbnail))?;
    let other_scene = "99999999-9999-4999-8999-999999999999";
    let other_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    shell.run(
        &c,
        Event::RequestOrdinarySelectedImage {
            key: key(),
            scene_id: other_scene.into(),
            request_id: other_id.into(),
            kind: Kind::Thumbnail,
        },
    )?;
    assert_eq!(c.view().ordinary_selected_images.len(), 1);
    shell.run(
        &c,
        Event::CloseOrdinarySelectedScene {
            scene_id: SCENE.into(),
        },
    )?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!({"requestID":NEXT,"stagedID":"lateRaster"})),
                error: None,
            },
        )
        .map_err(|_| "late")?;
    shell.drain(&c, effects)?;
    assert_eq!(c.view().ordinary_selected_images.len(), 1);
    assert_eq!(c.view().ordinary_selected_images[0].scene_id, other_scene);
    assert!(shell.released.iter().any(|s| s == "lateRaster"));
    Ok(())
}
#[test]
fn repeated_refresh_has_fresh_nonce_and_rejects_old_stage_aba() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    let old = c.view().ordinary_selected_presentation[0].proof_id.clone();
    let mut held = hold_read(&c, &mut shell, image(NEXT, Kind::Preview))?;
    shell.refresh(&c)?;
    let new = c.view().ordinary_selected_presentation[0].proof_id.clone();
    assert_ne!(old, new);
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!({"requestID":NEXT,"stagedID":"oldRaster"})),
                error: None,
            },
        )
        .map_err(|_| "old")?;
    shell.drain(&c, effects)?;
    assert!(c.view().ordinary_selected_images.is_empty());
    assert!(shell.released.iter().any(|s| s == "oldRaster"));
    Ok(())
}
#[test]
fn same_key_history_must_all_prove_same_selected_identity() -> Result<(), String> {
    let base = seed()?;
    for changed in [false, true] {
        let mut state = base.clone();
        let mut other = state.immich_visibility_operations[0].clone();
        other.id = NEXT.into();
        if changed {
            other.witness_digest = "b".repeat(64);
        }
        state.immich_visibility_operations.push(other);
        let c = ordinary(state);
        let mut shell = ReadShell::default();
        shell.refresh(&c)?;
        assert_eq!(
            c.view().ordinary_selected_presentation.len(),
            usize::from(!changed)
        );
    }
    Ok(())
}
#[test]
fn unknown_current_configuration_and_b_membership_never_admit_readproof() -> Result<(), String> {
    for protected in [false, true] {
        let mut state = seed()?;
        if protected {
            state.protected_entries.push(PersistentProtectedEntry {
                id: NEXT.into(),
                key: key(),
            });
        }
        let c = ordinary(state);
        let mut shell = ReadShell::default();
        if !protected {
            shell.raw.as_object_mut().ok_or("raw")?.remove("stack");
        }
        shell.refresh(&c)?;
        assert!(c.view().ordinary_selected_presentation.is_empty());
        shell.run(&c, image(NEXT, Kind::Preview))?;
        assert_eq!(shell.staged, 0);
    }
    Ok(())
}
#[test]
fn native_publish_failure_releases_stage_without_publishing_access() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    shell.fail_publish = true;
    shell.run(&c, image(NEXT, Kind::Preview))?;
    assert!(c.view().ordinary_selected_images.is_empty());
    assert_eq!(shell.released, vec!["raster1"]);
    Ok(())
}
#[test]
fn mismatched_metadata_id_cannot_publish_another_tracked_but_unlisted_key() -> Result<(), String> {
    use sha2::Digest;
    let mut state = seed()?;
    let mut other = state.immich_visibility_operations[0].clone();
    other.id = NEXT.into();
    other.key.asset_id = CHILD.into();
    other.witness_digest = suwop_core::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&(&other.key, "IMAGE", "a".repeat(40), "unlinked", "unstacked"))
            .map_err(|_| "witness")?,
    ));
    other
        .selected_observation
        .as_mut()
        .ok_or("selected")?
        .selected_identity_digest = suwop_core::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&json!([
            "selectedImage/v1",
            other.key,
            OWNER,
            "a".repeat(40)
        ]))
        .map_err(|_| "identity")?,
    ));
    state.immich_visibility_operations.push(other);
    let c = ordinary(state);
    let mut shell = ReadShell::default();
    shell.raw["id"] = json!(CHILD);
    shell.raw["livePhotoVideoId"] = json!("ffffffff-ffff-4fff-8fff-ffffffffffff");
    shell.refresh(&c)?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    assert!(c.view().photos.is_empty());
    Ok(())
}
#[test]
fn older_known_original_identity_without_selected_observation_admits_current_readproof()
-> Result<(), String> {
    let mut state = seed()?;
    let mut other = state.immich_visibility_operations[0].clone();
    other.id = NEXT.into();
    other.selected_observation = None;
    state.immich_visibility_operations.push(other);
    let c = ordinary(state);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    assert_eq!(c.view().ordinary_selected_presentation.len(), 1);
    Ok(())
}
fn uuid(index: usize) -> String {
    format!("00000000-0000-4000-8000-{index:012}")
}
#[test]
fn active_slot_capacity_allows_replacement_without_evicting_unrelated_preview() -> Result<(), String>
{
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    for index in 0..256 {
        shell.run(
            &c,
            Event::RequestOrdinarySelectedImage {
                key: key(),
                scene_id: uuid(index),
                request_id: uuid(index + 1000),
                kind: if index == 255 {
                    Kind::Preview
                } else {
                    Kind::Thumbnail
                },
            },
        )?;
    }
    assert_eq!(c.view().ordinary_selected_images.len(), 256);
    let preview = c
        .view()
        .ordinary_selected_images
        .iter()
        .find(|i| i.kind == Kind::Preview)
        .cloned()
        .ok_or("preview")?;
    shell.run(
        &c,
        Event::RequestOrdinarySelectedImage {
            key: key(),
            scene_id: uuid(256),
            request_id: uuid(2000),
            kind: Kind::Thumbnail,
        },
    )?;
    assert_eq!(shell.staged, 256);
    shell.run(
        &c,
        Event::RequestOrdinarySelectedImage {
            key: key(),
            scene_id: uuid(0),
            request_id: uuid(2001),
            kind: Kind::Thumbnail,
        },
    )?;
    assert_eq!(shell.staged, 257);
    assert_eq!(c.view().ordinary_selected_images.len(), 256);
    assert!(c.view().ordinary_selected_images.contains(&preview));
    assert!(shell.released.iter().any(|id| id == "raster1"));
    Ok(())
}
#[test]
fn readonly_and_operational_same_hash_sources_can_both_be_selected_without_granting_operations()
-> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    let native: suwop_core::immich::Asset = serde_json::from_value(asset()).map_err(|_| "asset")?;
    let mut apple = native.record("apple", None, None);
    apple.key = AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: "apple-physical".into(),
    };
    apple.apple_visibility = suwop_core::domain::AppleVisibility::Visible;
    shell.apple_assets.push(apple.clone());
    shell.refresh(&c)?;
    let photo = c
        .view()
        .photos
        .into_iter()
        .find(|p| p.assets.iter().any(|a| a.key == key()))
        .ok_or("photo")?;
    assert_eq!(photo.assets.len(), 2);
    let photo_id = suwop_core::browser::photo_id(&photo);
    shell.run(
        &c,
        Event::ChoosePreview {
            anchor: key(),
            key: apple.key.clone(),
        },
    )?;
    assert_eq!(c.view().preview_sources[&photo_id], apple.key);
    shell.run(
        &c,
        Event::ChoosePreview {
            anchor: apple.key.clone(),
            key: key(),
        },
    )?;
    assert_eq!(c.view().preview_sources[&photo_id], key());
    assert!(!c.view().ordinary_content_keys.contains(&key()));
    assert!(c.view().ordinary_content_keys.contains(&apple.key));
    let mut changed = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
    for snapshot in &mut changed.snapshots {
        if snapshot.provider == Provider::Immich {
            snapshot.access = suwop_core::domain::ScanAccess::Unavailable;
        }
    }
    shell.run(
        &c,
        Event::Progress {
            session: None,
            state: changed,
            status: "fixture change".into(),
        },
    )?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    shell.run(
        &c,
        Event::ChoosePreview {
            anchor: apple.key,
            key: key(),
        },
    )?;
    assert!(c.view().error.is_some());
    Ok(())
}
#[test]
fn explicitly_unverified_same_key_selected_evidence_blocks_presentation() -> Result<(), String> {
    let mut state = seed()?;
    let mut old = state.immich_visibility_operations[0].clone();
    old.id = NEXT.into();
    let selected = old.selected_observation.as_mut().ok_or("selected")?;
    selected.configuration = suwop_core::immich_visibility::SelectedConfiguration::Unverified;
    selected.configuration_digest = None;
    state.immich_visibility_operations.push(old);
    let c = ordinary(state);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    Ok(())
}
#[test]
fn same_scene_new_preview_supersedes_late_previous_request_only() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    let mut held = hold_read(&c, &mut shell, image(NEXT, Kind::Preview))?;
    let new = uuid(4000);
    shell.run(&c, image(&new, Kind::Preview))?;
    let approved = c.view().ordinary_selected_images[0].clone();
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!({"requestID":NEXT,"stagedID":"superseded"})),
                error: None,
            },
        )
        .map_err(|_| "late")?;
    shell.drain(&c, effects)?;
    assert_eq!(c.view().ordinary_selected_images, vec![approved]);
    assert!(shell.released.iter().any(|id| id == "superseded"));
    Ok(())
}
#[test]
fn security_change_while_scan_persist_pending_cannot_adopt_own_finished_epoch() -> Result<(), String>
{
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    let mut effects = c.process_event(Event::Refresh {
        permission: false,
        now: 1_800_000_000.0,
    });
    let mut held = loop {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(request.operation, ShellOperation::Persist(_)) {
            break request;
        }
        let value = shell.respond(&c, &request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    };
    shell.run(&c, Event::Disconnect)?;
    let value = shell.respond(&c, &held.operation)?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "persist")?;
    shell.drain(&c, effects)?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    Ok(())
}
#[test]
fn completed_request_tombstones_are_bounded_and_reset_only_after_proof_revocation()
-> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    for index in 0..4096 {
        shell.run(&c, image(&uuid(index + 10000), Kind::Thumbnail))?;
    }
    assert_eq!(shell.staged, 4096);
    assert_eq!(c.view().ordinary_selected_images.len(), 1);
    shell.run(
        &c,
        Event::CloseOrdinarySelectedScene {
            scene_id: SCENE.into(),
        },
    )?;
    shell.run(&c, image(&uuid(20000), Kind::Thumbnail))?;
    assert_eq!(shell.staged, 4096);
    shell.refresh(&c)?;
    shell.run(&c, image(&uuid(20000), Kind::Thumbnail))?;
    assert_eq!(shell.staged, 4097);
    Ok(())
}
fn duplicate_for(state: &mut SavedLibrary, id: &str) -> Result<(), String> {
    use sha2::Digest;
    let mut other = state.immich_visibility_operations[0].clone();
    other.id = uuid(9000);
    other.key.asset_id = id.into();
    other.witness_digest = suwop_core::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&(&other.key, "IMAGE", "a".repeat(40), "unlinked", "unstacked"))
            .map_err(|_| "witness")?,
    ));
    other
        .selected_observation
        .as_mut()
        .ok_or("selected")?
        .selected_identity_digest = suwop_core::domain::hex(&sha2::Sha256::digest(
        serde_json::to_vec(&json!([
            "selectedImage/v1",
            other.key,
            OWNER,
            "a".repeat(40)
        ]))
        .map_err(|_| "identity")?,
    ));
    state.immich_visibility_operations.push(other);
    Ok(())
}
#[test]
fn thumbnail_requests_for_distinct_keys_complete_independently() -> Result<(), String> {
    let mut state = seed()?;
    duplicate_for(&mut state, CHILD)?;
    let c = ordinary(state);
    let mut shell = ReadShell::default();
    let mut extra = shell.raw.clone();
    extra["id"] = json!(CHILD);
    extra["livePhotoVideoId"] = json!(uuid(8000));
    extra["originalFileName"] = json!("other.jpg");
    shell.listed.push(extra.clone());
    shell.extra.push(extra);
    shell.refresh(&c)?;
    assert_eq!(c.view().ordinary_selected_presentation.len(), 2);
    let mut held = hold_read(&c, &mut shell, image(NEXT, Kind::Thumbnail))?;
    let mut other = key();
    other.asset_id = CHILD.into();
    shell.run(
        &c,
        Event::RequestOrdinarySelectedImage {
            key: other,
            scene_id: SCENE.into(),
            request_id: uuid(4000),
            kind: Kind::Thumbnail,
        },
    )?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(json!({"requestID":NEXT,"stagedID":"firstKey"})),
                error: None,
            },
        )
        .map_err(|_| "read")?;
    shell.drain(&c, effects)?;
    assert_eq!(c.view().ordinary_selected_images.len(), 2);
    Ok(())
}
#[test]
fn precheck_denial_and_reused_request_never_reach_native_read() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    shell.run(&c, image(NEXT, Kind::Thumbnail))?;
    assert_eq!(shell.staged, 1);
    shell.run(&c, image(NEXT, Kind::Thumbnail))?;
    assert_eq!(shell.staged, 1);
    shell.failure = Some(403);
    shell.run(&c, image(&uuid(4000), Kind::Preview))?;
    assert_eq!(shell.staged, 1);
    assert!(c.view().ordinary_selected_images.is_empty());
    assert!(shell.released.iter().any(|s| s == "raster1"));
    Ok(())
}
#[test]
fn old_ordinary_image_identity_is_compatible_but_changed_parent_witness_is_not()
-> Result<(), String> {
    use sha2::Digest;
    for linked in [false, true] {
        let mut state = seed()?;
        let mut old = state.immich_visibility_operations[0].clone();
        old.id = NEXT.into();
        old.kind = suwop_core::immich_visibility::ImmichVisibilityOperationKind::OrdinaryArchive;
        old.from = suwop_core::immich_visibility::ImmichVisibility::Timeline;
        old.to = suwop_core::immich_visibility::ImmichVisibility::Archive;
        old.observation = Some(old.to);
        old.selected_observation = None;
        if linked {
            old.witness_digest = suwop_core::domain::hex(&sha2::Sha256::digest(
                serde_json::to_vec(&(
                    &old.key,
                    "IMAGE",
                    "a".repeat(40),
                    "selectedLiveParent/v1",
                    uuid(5000),
                    "unstacked",
                ))
                .map_err(|_| "witness")?,
            ));
        }
        state.immich_visibility_operations.insert(0, old);
        let c = ordinary(state);
        let mut shell = ReadShell::default();
        shell.refresh(&c)?;
        assert_eq!(
            c.view().ordinary_selected_presentation.len(),
            usize::from(!linked)
        );
    }
    Ok(())
}
fn prohibited_events() -> Vec<Event> {
    vec![
        Event::SetFavorite {
            keys: vec![key()],
            value: true,
        },
        Event::Share {
            keys: vec![key()],
            id: uuid(6000),
        },
        Event::ShareCurrentImage {
            key: key(),
            id: uuid(6000),
        },
        Event::Play {
            keys: vec![key()],
            id: uuid(6000),
        },
        Event::EditImage {
            key: key(),
            id: uuid(6000),
        },
        Event::RevertImage {
            key: key(),
            id: uuid(6000),
        },
        Event::CopyPhotoEdits {
            key: key(),
            id: uuid(6000),
            options: suwop_core::editing::EditCopyOptions {
                adjustments: true,
                filter: true,
                geometry: true,
            },
        },
        Event::PastePhotoEdits {
            keys: vec![key()],
            id: uuid(6000),
        },
        Event::Copy {
            keys: vec![key()],
            intent: suwop_core::domain::TransferIntent::Copy,
            id: uuid(6000),
            now: 1_800_000_000.0,
        },
        Event::Copy {
            keys: vec![key()],
            intent: suwop_core::domain::TransferIntent::Move,
            id: uuid(6000),
            now: 1_800_000_000.0,
        },
        Event::ChangeTrash {
            keys: vec![key()],
            action: suwop_core::trash::TrashAction::Trash,
            id: uuid(6000),
        },
        Event::EditAlbum {
            key: suwop_core::albums::AlbumKey {
                provider: Provider::Immich,
                scope: key().scope,
                album_id: uuid(6001),
            },
            edit: suwop_core::albums::AlbumEdit {
                action: suwop_core::albums::AlbumAction::Add,
                title: None,
                keys: vec![key()],
            },
        },
        Event::SetMetadata {
            keys: vec![key()],
            input: suwop_core::metadata::MetadataInput {
                action: suwop_core::metadata::MetadataAction::RemoveLocation,
                captured_at: None,
                time_zone: None,
                latitude: None,
                longitude: None,
            },
        },
        Event::PrepareImmichArchive {
            key: key(),
            to: suwop_core::immich_archive::ImmichArchiveDestination::Archive,
            operation_id: uuid(6000),
            scene_id: SCENE.into(),
        },
        Event::PrepareImmichVisibility {
            key: key(),
            to: suwop_core::immich_visibility::ImmichVisibility::Locked,
            operation_id: uuid(6000),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    ]
}
fn readonly_with_write_state(mode: u8) -> Result<(Core<Suwop>, ReadShell), String> {
    let c = ordinary_version(
        seed()?,
        Version {
            major: 3,
            minor: 3,
            patch: 3,
        },
    );
    let mut shell = ReadShell::default();
    shell.refresh(&c)?;
    if mode != 0 {
        let mut row = asset();
        row["id"] = json!(CHILD);
        row["visibility"] = json!("locked");
        shell.pin.pages = Some(std::collections::VecDeque::from([
            json!({"assets":{"items":[row],"nextCursor":null}}),
        ]));
        if mode == 2 {
            shell
                .pin
                .versions
                .push_back(json!({"major":3,"minor":2,"patch":4,"prerelease":null}));
        }
        shell.run(
            &c,
            Event::ImmichLockedSceneChanged {
                scene_id: SCENE.into(),
                phase: suwop_core::protection::ProtectionScenePhase::Active,
            },
        )?;
        shell.run(&c, open(GRANT))?;
        let entries = c
            .view()
            .immich_locked_view
            .entries
            .ok_or("authenticated entries")?;
        let hint = &entries
            .iter()
            .find(|e| e.id == CHILD)
            .ok_or("other physical entry")?
            .visibility_action;
        assert_eq!(
            hint.write_availability,
            if mode == 1 {
                suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Supported
            } else {
                suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Unsupported
            }
        );
    } else {
        assert!(c.view().immich_locked_view.grant_id.is_none());
    }
    shell.run(
        &c,
        Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
    )?;
    assert_eq!(c.view().ordinary_selected_presentation.len(), 1);
    Ok((c, shell))
}
#[test]
fn every_selected_source_operation_stays_denied_across_write_contract_states() -> Result<(), String>
{
    for mode in 0..3 {
        for event in prohibited_events() {
            let (c, mut shell) = readonly_with_write_state(mode)?;
            let paths = shell.paths.len();
            let persists = shell.persists;
            let pin_paths = shell.pin.paths.len();
            shell.run(&c, event)?;
            assert_eq!(shell.paths.len(), paths);
            assert!(
                shell.pin.paths[pin_paths..]
                    .iter()
                    .all(|path| matches!(path.as_str(), "auth/session/lock" | "auth/logout"))
            );
            assert_eq!(shell.persists, persists);
            assert_eq!(shell.pin.writes, 0);
            assert_eq!(shell.pin.confirmations, 0);
            assert_eq!(shell.unexpected, 0);
            assert_eq!(shell.staged, 0);
        }
    }
    Ok(())
}
#[test]
fn canonical_protection_and_revision_progress_revoke_only_current_read_authority()
-> Result<(), String> {
    for protect in [false, true] {
        let c = ordinary(seed()?);
        let mut shell = ReadShell::default();
        shell.refresh(&c)?;
        shell.run(&c, image(NEXT, Kind::Preview))?;
        let mut changed = suwop_core::workflow::migrate(shell.disk.clone().ok_or("disk")?)?;
        if protect {
            changed.protected_entries.push(PersistentProtectedEntry {
                id: uuid(5000),
                key: key(),
            });
        } else {
            for snapshot in &mut changed.snapshots {
                for asset in &mut snapshot.assets {
                    if asset.key == key() {
                        asset.revision = "changed".into();
                    }
                }
            }
        }
        shell.run(
            &c,
            Event::Progress {
                session: None,
                state: changed,
                status: "fixture update".into(),
            },
        )?;
        assert!(c.view().ordinary_selected_presentation.is_empty());
        assert!(c.view().ordinary_selected_images.is_empty());
        assert_eq!(shell.released, vec!["raster1"]);
    }
    Ok(())
}
#[test]
fn held_scan_metadata_cannot_admit_after_new_canonical_b_membership() -> Result<(), String> {
    let state = seed()?;
    let c = ordinary(state.clone());
    let mut shell = ReadShell::default();
    let mut effects = c.process_event(Event::Refresh {
        permission: false,
        now: 1_800_000_000.0,
    });
    let mut held = loop {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(&request.operation,ShellOperation::Http(r) if r.url.ends_with(&format!("/assets/{ASSET}")))
        {
            break request;
        }
        let value = shell.respond(&c, &request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    };
    let mut protected = state;
    protected.protected_entries.push(PersistentProtectedEntry {
        id: uuid(5000),
        key: key(),
    });
    shell.run(
        &c,
        Event::Progress {
            session: None,
            state: protected,
            status: "fixture protection".into(),
        },
    )?;
    let value = shell.respond(&c, &held.operation)?;
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "read")?;
    shell.drain(&c, effects)?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    assert_eq!(shell.persists, 0);
    verify_b_record(&c, &mut shell)?;
    Ok(())
}
fn verify_b_record(c: &Core<Suwop>, shell: &mut ReadShell) -> Result<(), String> {
    shell.run(
        c,
        Event::ProtectedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
    )?;
    shell.run(
        c,
        Event::BeginProtectedAccess {
            challenge_id: uuid(7777),
            scene_id: SCENE.into(),
            purpose: suwop_core::protection::ProtectedPurpose::View,
        },
    )?;
    let entries = c
        .view()
        .protected_view
        .entries
        .ok_or("authenticated protected entries")?;
    assert!(entries.iter().any(|e| e.id == uuid(5000)));
    Ok(())
}
#[test]
fn already_issued_refresh_persist_conflict_is_not_published_as_current_or_claimed_prevented()
-> Result<(), String> {
    let state = seed()?;
    let c = ordinary(state.clone());
    let mut shell = ReadShell::default();
    let mut effects = c.process_event(Event::Refresh {
        permission: false,
        now: 1_800_000_000.0,
    });
    let mut held = loop {
        let Effect::Io(mut request) = effects.remove(0);
        if matches!(request.operation, ShellOperation::Persist(_)) {
            break request;
        }
        let value = shell.respond(&c, &request.operation)?;
        effects.extend(
            c.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|_| "resolve")?,
        );
    };
    let mut changed = state;
    changed.protected_entries.push(PersistentProtectedEntry {
        id: uuid(5000),
        key: key(),
    });
    shell.run(
        &c,
        Event::Progress {
            session: None,
            state: changed,
            status: "trusted internal protection update".into(),
        },
    )?;
    let value = shell.respond(&c, &held.operation)?;
    assert_eq!(shell.persists, 1);
    assert!(
        shell.disk.as_ref().ok_or("acknowledged disk")?["protectedEntries"]
            .as_array()
            .ok_or("members")?
            .is_empty()
    );
    let effects = c
        .resolve(
            &mut held,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "persist ack")?;
    shell.drain(&c, effects)?;
    assert!(c.view().ordinary_selected_presentation.is_empty());
    assert!(c.view().immich_visibility_view.persistence_uncertain);
    assert!(!c.view().can_transfer);
    assert!(!c.view().busy);
    verify_b_record(&c, &mut shell)?;
    Ok(())
}

#[test]
fn initialized_saved_connection_bootstraps_ordinary_refresh_without_pin() -> Result<(), String> {
    let mut state = seed()?;
    state.connection = Some(suwop_core::app::ConnectionSettings {
        address: "https://fixture.example".into(),
        allow_http: false,
        credential_id: "fixture".into(),
    });
    let c = Core::new();
    let mut shell = ReadShell {
        disk: Some(serde_json::to_value(state).map_err(|_| "encode")?),
        ..ReadShell::default()
    };
    shell.run(
        &c,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    shell.refresh(&c)?;
    assert!(!c.view().busy);
    assert_eq!(c.view().ordinary_selected_presentation.len(), 1);
    assert!(shell.paths.iter().any(|p| p == "users/me"));
    assert_eq!(shell.unexpected, 0);
    Ok(())
}
#[test]
fn partial_refresh_error_never_grants_new_selected_presentation() -> Result<(), String> {
    let c = ordinary(seed()?);
    let mut shell = ReadShell {
        fail_apple: true,
        ..ReadShell::default()
    };
    shell.refresh(&c)?;
    assert!(c.view().error.is_some());
    assert!(c.view().ordinary_selected_presentation.is_empty());
    assert_eq!(shell.staged, 0);
    Ok(())
}
