use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{
        ConnectionSettings, Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse,
        Suwop,
    },
    domain::{AssetKey, LibrarySnapshot, Provider, ScanAccess},
    immich::{Asset, Session, Version},
    immich_archive::ImmichArchiveDestination,
    immich_visibility::{ImmichVisibility, ImmichVisibilityOperationKind},
    protection::ProtectionScenePhase,
};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const ID: &str = "22222222-2222-4222-8222-222222222222";
const ASSET: &str = "33333333-3333-4333-8333-333333333333";
fn asset() -> Value {
    json!({"id":ASSET,"ownerId":"owner","type":"IMAGE","originalFileName":"ordinary.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"timeline","livePhotoVideoId":null,"stack":null})
}
fn key() -> AssetKey {
    AssetKey {
        provider: Provider::Immich,
        scope: "scope".into(),
        asset_id: ASSET.into(),
    }
}
fn model() -> Result<Model, String> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.example/api".into(),
        key: "api-key".into(),
        user_id: "owner".into(),
        scope: "scope".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let a: Asset = serde_json::from_value(asset()).map_err(|e| e.to_string())?;
    Ok(Model {
        session: Some(session),
        ready: true,
        state: SavedLibrary {
            schema_version: 7,
            connection: Some(ConnectionSettings {
                address: "https://fixture.example/api".into(),
                allow_http: false,
                credential_id: "credential".into(),
            }),
            snapshots: vec![LibrarySnapshot {
                provider: Provider::Immich,
                scope: "scope".into(),
                access: ScanAccess::Full,
                scanned_at: Some(1.0),
                assets: vec![a.record("scope", None, None)],
            }],
            ..SavedLibrary::default()
        },
        ..Model::default()
    })
}
fn prepare(id: &str, to: ImmichArchiveDestination) -> Event {
    Event::PrepareImmichArchive {
        key: key(),
        to,
        operation_id: id.into(),
        scene_id: SCENE.into(),
    }
}
fn inspect() -> Event {
    Event::InspectImmichArchive {
        record_id: ID.into(),
        scene_id: SCENE.into(),
    }
}
#[derive(Default)]
struct PersistenceFaults {
    lost: bool,
    after_write: bool,
    read_fail: bool,
}
#[derive(Default)]
struct Shell {
    faults: PersistenceFaults,
    disk: Option<Value>,
    writes: usize,
    confirms: usize,
    persists: usize,
    gets: usize,
    confirm: bool,
    visibility: Option<String>,
    fail_persist: Option<usize>,
    revoke_confirm: bool,
    confirmation_events: Vec<Event>,
    close_after_write: bool,
    patch: Option<Value>,
    scan_revision: Option<String>,
}
impl Shell {
    fn run(&mut self, c: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.drain(c, c.process_event(event))
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut effect) = effects.remove(0);
            let result = self.respond(c, &effect.operation);
            effects.extend(
                c.resolve(
                    &mut effect,
                    match result {
                        Ok(v) => ShellResponse {
                            value: Some(v),
                            error: None,
                        },
                        Err(e) => ShellResponse {
                            value: None,
                            error: Some(e),
                        },
                    },
                )
                .map_err(|_| "resolve")?,
            );
        }
        Ok(())
    }
    fn respond(&mut self, c: &Core<Suwop>, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::ConfirmImmichArchive { prompt } => {
                self.confirms += 1;
                assert_eq!(prompt.from, ImmichArchiveDestination::Timeline);
                assert_eq!(prompt.to, ImmichArchiveDestination::Archive);
                assert_eq!(
                    c.view()
                        .immich_archive_view
                        .active_operation
                        .as_ref()
                        .map(|p| p.operation_id.as_str()),
                    Some(ID)
                );
                if self.revoke_confirm {
                    assert!(
                        c.process_event(Event::CloseImmichArchive {
                            scene_id: SCENE.into()
                        })
                        .is_empty()
                    );
                }
                for event in std::mem::take(&mut self.confirmation_events) {
                    assert!(c.process_event(event).is_empty());
                }
                Ok(json!(self.confirm))
            }
            ShellOperation::Persist(state) => {
                self.persists += 1;
                let value = serde_json::to_value(state).map_err(|e| e.to_string())?;
                if self.fail_persist == Some(self.persists) {
                    if self.faults.after_write {
                        self.disk = Some(value);
                    }
                    Err("persist unavailable".into())
                } else {
                    self.disk = Some(value);
                    Ok(Value::Null)
                }
            }
            ShellOperation::ReadState => {
                if self.faults.read_fail {
                    Err("read unavailable".into())
                } else {
                    self.disk.clone().ok_or("missing".into())
                }
            }
            ShellOperation::AppleScan { scope, .. } => Ok(
                json!({"provider":"apple","scope":scope,"access":"full","assets":[],"scannedAt":1}),
            ),
            ShellOperation::Http(request) => self.respond_http(c, request),
            _ => Err("unexpected effect".into()),
        }
    }
    fn respond_http(
        &mut self,
        c: &Core<Suwop>,
        request: &suwop_core::immich::HttpRequest,
    ) -> Result<Value, String> {
        assert_eq!(
            request.headers.get("x-api-key").map(String::as_str),
            Some("api-key")
        );
        assert!(!request.headers.contains_key("Authorization"));
        if request.url.ends_with("/search/metadata") {
            let mut item = asset();
            item["visibility"] = json!(self.visibility.as_deref().unwrap_or("timeline"));
            item.as_object_mut().ok_or("search asset")?.remove("stack");
            return Ok(json!({"status":200,"body":{"assets":{"items":[item],"nextCursor":null}}}));
        }
        if request.url.contains("/asset-files?") {
            return Ok(json!({"status":200,"body":[]}));
        }
        if request.method == "PUT" {
            self.writes += 1;
            let permit = request
                .immich_archive_authorization
                .as_ref()
                .ok_or("ordinary permit")?;
            assert_eq!(permit.operation_id, ID);
            assert_eq!(permit.url, request.url);
            assert_eq!(
                request.body.as_ref().ok_or("body")?["visibility"],
                "archive"
            );
            assert_eq!(
                self.disk.as_ref().ok_or("persist before write")?["immichVisibilityOperations"][0]
                    ["outcome"],
                "unknown"
            );
            self.visibility = Some("archive".into());
            if self.close_after_write {
                assert!(
                    c.process_event(Event::CloseImmichArchive {
                        scene_id: SCENE.into()
                    })
                    .is_empty()
                );
            }
            if self.faults.lost {
                return Err("lost response".into());
            }
            return Ok(json!({"status":200,"body":null}));
        }
        self.gets += 1;
        assert_eq!(
            request.url,
            format!("https://fixture.example/api/assets/{ASSET}")
        );
        let mut a = asset();
        if let Some(v) = &self.visibility {
            a["visibility"] = json!(v);
        }
        if let Some(revision) = &self.scan_revision {
            a["updatedAt"] = json!(revision);
        }
        if let Some(Value::Object(patch)) = &self.patch {
            for (k, v) in patch {
                a[k] = v.clone();
            }
        }
        Ok(json!({"status":200,"body":a}))
    }
}
fn started(m: Model) -> Result<(Core<Suwop>, Shell), String> {
    let c = Core::new_with(Suwop, m);
    let mut s = Shell {
        confirm: true,
        ..Shell::default()
    };
    s.run(
        &c,
        Event::ImmichArchiveSceneChanged {
            scene_id: SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )?;
    Ok((c, s))
}
#[test]
fn ordinary_roundtrip_is_pin_free_durable_and_fenced_until_fresh_scan() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    assert_eq!(
        c.view().immich_archive_actions[0].to,
        Some(ImmichArchiveDestination::Archive)
    );
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    assert_eq!(s.persists, 2);
    let state: SavedLibrary =
        serde_json::from_value(s.disk.ok_or("disk")?).map_err(|e| e.to_string())?;
    assert_eq!(
        state.immich_visibility_operations[0].kind,
        ImmichVisibilityOperationKind::OrdinaryArchive
    );
    assert!(suwop_core::immich_visibility::fences(&state, &key()));
    assert!(
        c.view().immich_archive_view.history.ok_or("history")?[0].outcome
            == suwop_core::apple_visibility::VisibilityOutcome::Applied
    );
    Ok(())
}
#[test]
fn cancelled_or_revoked_confirmation_never_persists_or_writes() -> Result<(), String> {
    for revoke in [false, true] {
        let (c, mut s) = started(model()?)?;
        s.confirm = revoke;
        s.revoke_confirm = revoke;
        s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
        assert_eq!(s.writes, 0);
        assert_eq!(s.persists, 0);
    }
    Ok(())
}
#[test]
fn lost_response_is_unknown_and_new_uuid_cannot_replay_before_inspect() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    s.faults.lost = true;
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    assert_eq!(
        s.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["observation"],
        Value::Null
    );
    let gets = s.gets;
    s.run(
        &c,
        prepare(
            "44444444-4444-4444-8444-444444444444",
            ImmichArchiveDestination::Timeline,
        ),
    )?;
    assert_eq!(s.gets, gets);
    s.run(
        &c,
        Event::CloseImmichArchive {
            scene_id: SCENE.into(),
        },
    )?;
    assert!(c.view().immich_archive_view.scene_id.is_none());
    s.run(&c, inspect())?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(SCENE)
    );
    assert_eq!(s.writes, 1);
    assert_eq!(
        s.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["observation"],
        "archive"
    );
    Ok(())
}
#[test]
fn prewrite_and_final_persist_failure_never_replay_mutation() -> Result<(), String> {
    for call in [1, 2] {
        let (c, mut s) = started(model()?)?;
        s.fail_persist = Some(call);
        s.faults.read_fail = true;
        s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
        assert_eq!(s.writes, usize::from(call == 2));
        assert!(c.view().immich_archive_view.persistence_uncertain);
        let writes = s.writes;
        s.run(
            &c,
            prepare(
                "44444444-4444-4444-8444-444444444444",
                ImmichArchiveDestination::Timeline,
            ),
        )?;
        assert_eq!(s.writes, writes);
    }
    Ok(())
}
#[test]
fn late_close_keeps_unknown_and_handles_native_outcome() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    s.close_after_write = true;
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    assert_eq!(
        s.disk.as_ref().ok_or("disk")?["immichVisibilityOperations"][0]["outcome"],
        "unknown"
    );
    assert!(c.view().immich_archive_view.history.is_none());
    Ok(())
}
#[test]
fn protected_and_wrong_scope_are_denied_before_io() -> Result<(), String> {
    for other in [false, true] {
        let mut m = model()?;
        if other {
            m.session.as_mut().ok_or("session")?.scope = "other".into();
        } else {
            m.protection.denied.insert(key());
        }
        let (c, mut s) = started(m)?;
        s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
        assert_eq!(s.gets, 0);
        assert_eq!(s.writes, 0);
    }
    Ok(())
}
#[test]
fn linked_video_stack_locked_and_unknown_facts_never_confirm() -> Result<(), String> {
    for patch in [
        json!({"type":"VIDEO"}),
        json!({"livePhotoVideoId":ASSET}),
        json!({"stack":{}}),
        json!({"visibility":"locked"}),
        json!({"stack":false}),
    ] {
        let (c, mut s) = started(model()?)?;
        s.patch = Some(patch);
        s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
        assert_eq!(s.confirms, 0);
        assert_eq!(s.writes, 0);
    }
    Ok(())
}
#[test]
fn legacy_locked_journal_migration_preserves_digest_and_cannot_be_ordinary() -> Result<(), String> {
    let mut raw = serde_json::to_value(model()?.state).map_err(|e| e.to_string())?;
    raw["schemaVersion"] = json!(6);
    raw["immichVisibilityOperations"] = json!([{"id":ID,"scope":"scope","key":key(),"witnessDigest":"a".repeat(64),"from":"timeline","to":"locked","outcome":"unknown"}]);
    let migrated = suwop_core::workflow::migrate(raw.clone())?;
    assert_eq!(migrated.schema_version, 7);
    assert_eq!(
        migrated.immich_visibility_operations[0].kind,
        ImmichVisibilityOperationKind::LockedTransition
    );
    raw["immichVisibilityOperations"][0]["witnessDigest"] = json!("a".repeat(74));
    assert!(suwop_core::workflow::migrate(raw.clone()).is_err());
    raw["immichVisibilityOperations"][0]["witnessDigest"] = json!("a".repeat(64));
    raw["immichVisibilityOperations"][0]["kind"] = json!("ordinaryArchive");
    assert!(suwop_core::workflow::migrate(raw.clone()).is_err());
    raw["schemaVersion"] = json!(7);
    assert!(suwop_core::workflow::migrate(raw).is_err());
    Ok(())
}
#[test]
fn ordinary_history_inspect_and_recovery_cannot_change_locked_journal() -> Result<(), String> {
    let mut m = model()?;
    let op = suwop_core::immich_visibility::ImmichVisibilityOperation {
        kind: ImmichVisibilityOperationKind::LockedTransition,
        id: ID.into(),
        scope: "scope".into(),
        key: key(),
        witness_digest: "a".repeat(64),
        from: ImmichVisibility::Timeline,
        to: ImmichVisibility::Locked,
        outcome: suwop_core::apple_visibility::VisibilityOutcome::Unknown,
        observation: None,
        album_membership_observation:
            suwop_core::immich_visibility::AlbumMembershipObservation::default(),
    };
    m.state.immich_visibility_operations.push(op);
    m.immich_archive.uncertain = true;
    m.immich_visibility.persistence_uncertain = true;
    m.immich_visibility.message = Some("PIN-only-status".into());
    let before = serde_json::to_value(&m.state).map_err(|e| e.to_string())?;
    let (c, mut s) = started(m)?;
    assert_eq!(
        c.view().immich_archive_view.history.ok_or("history")?.len(),
        0
    );
    assert!(c.view().immich_archive_view.status.is_none());
    s.run(&c, inspect())?;
    assert_eq!(s.gets, 0);
    let mut changed = before.clone();
    changed["immichVisibilityOperations"][0]["observation"] = json!("timeline");
    s.disk = Some(changed);
    s.run(
        &c,
        Event::RecoverImmichArchiveState {
            scene_id: SCENE.into(),
        },
    )?;
    assert!(c.view().immich_archive_view.persistence_uncertain);
    s.disk = Some(before.clone());
    s.run(
        &c,
        Event::RecoverImmichArchiveState {
            scene_id: SCENE.into(),
        },
    )?;
    assert!(c.view().immich_archive_view.persistence_uncertain);
    assert!(
        !serde_json::to_string(&c.view())
            .map_err(|e| e.to_string())?
            .contains(ID)
    );
    assert_eq!(s.persists, 0);
    Ok(())
}

#[test]
fn uncertain_archive_recovery_accepts_before_or_desired_and_retains_proof_on_failure()
-> Result<(), String> {
    for after_write in [false, true] {
        let mut m = model()?;
        let mut old_key = key();
        old_key.asset_id = "old-unrelated-asset".into();
        m.state.immich_visibility_operations.push(
            suwop_core::immich_visibility::ImmichVisibilityOperation {
                kind: ImmichVisibilityOperationKind::OrdinaryArchive,
                id: "55555555-5555-4555-8555-555555555555".into(),
                scope: "scope".into(),
                key: old_key,
                witness_digest: "b".repeat(64),
                from: ImmichVisibility::Timeline,
                to: ImmichVisibility::Archive,
                outcome: suwop_core::apple_visibility::VisibilityOutcome::Unknown,
                observation: None,
                album_membership_observation:
                    suwop_core::immich_visibility::AlbumMembershipObservation::NotChecked,
            },
        );
        let before = serde_json::to_value(&m.state).map_err(|e| e.to_string())?;
        let (c, mut s) = started(m)?;
        s.disk = Some(before.clone());
        s.fail_persist = Some(1);
        s.faults.after_write = after_write;
        s.faults.read_fail = true;
        s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
        assert!(c.view().immich_archive_view.persistence_uncertain);
        let valid = s.disk.clone().ok_or("durable state")?;
        let mut corrupt = valid.clone();
        corrupt["protectedEntries"] = json!([{"id":ID,"key":key()}]);
        s.disk = Some(corrupt);
        s.faults.read_fail = false;
        s.run(
            &c,
            Event::CloseImmichArchive {
                scene_id: SCENE.into(),
            },
        )?;
        s.run(
            &c,
            Event::ImmichArchiveSceneChanged {
                scene_id: OTHER_SCENE.into(),
                phase: ProtectionScenePhase::Active,
            },
        )?;
        assert!(c.view().immich_archive_view.scene_id.is_none());
        s.run(
            &c,
            Event::RecoverImmichArchiveState {
                scene_id: OTHER_SCENE.into(),
            },
        )?;
        assert!(c.view().immich_archive_view.persistence_uncertain);
        let mut missing_history = valid.clone();
        missing_history["immichVisibilityOperations"]
            .as_array_mut()
            .ok_or("operations")?
            .remove(0);
        s.disk = Some(missing_history);
        s.run(
            &c,
            Event::RecoverImmichArchiveState {
                scene_id: OTHER_SCENE.into(),
            },
        )?;
        assert!(c.view().immich_archive_view.persistence_uncertain);
        s.disk = Some(valid);
        s.run(
            &c,
            Event::RecoverImmichArchiveState {
                scene_id: OTHER_SCENE.into(),
            },
        )?;
        assert!(!c.view().immich_archive_view.persistence_uncertain);
        assert_eq!(
            c.view().immich_archive_view.scene_id.as_deref(),
            Some(OTHER_SCENE)
        );
        assert_eq!(s.writes, 0);
        assert_eq!(s.persists, 1);
    }
    Ok(())
}

#[test]
fn revision_race_disables_archive_until_explicit_fresh_scan_without_replay() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    s.scan_revision = Some("changed-after-search".into());
    s.run(
        &c,
        Event::Refresh {
            permission: false,
            now: 1_800_000_000.0,
        },
    )?;
    let hint = c
        .view()
        .immich_archive_actions
        .into_iter()
        .find(|h| h.key == key())
        .ok_or("hint")?;
    assert_eq!(hint.to, None);
    assert_eq!(
        hint.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unknown)
    );
    assert_eq!(s.writes, 1);
    s.scan_revision = None;
    s.run(
        &c,
        Event::Refresh {
            permission: false,
            now: 1_800_000_000.0,
        },
    )?;
    let hint = c
        .view()
        .immich_archive_actions
        .into_iter()
        .find(|h| h.key == key())
        .ok_or("fresh hint")?;
    assert_eq!(hint.to, Some(ImmichArchiveDestination::Timeline));
    assert_eq!(s.writes, 1);
    assert_eq!(s.confirms, 1);
    Ok(())
}

#[test]
fn indeterminate_intent_disables_hint_until_exact_state_recovery() -> Result<(), String> {
    let mut m = model()?;
    let mut other = m.state.snapshots[0].assets[0].clone();
    other.key.asset_id = "66666666-6666-4666-8666-666666666666".into();
    let retained = other.key.clone();
    m.state.snapshots[0].assets.push(other);
    let before = serde_json::to_value(&m.state).map_err(|e| e.to_string())?;
    let (c, mut s) = started(m)?;
    s.disk = Some(before);
    s.fail_persist = Some(1);
    s.faults.read_fail = true;
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    let view = c.view();
    assert!(view.immich_archive_view.persistence_uncertain);
    assert!(view.immich_archive_view.can_recover);
    let hint = view
        .immich_archive_actions
        .into_iter()
        .find(|h| h.key == retained)
        .ok_or("retained snapshot hint")?;
    assert_eq!(hint.to, None);
    assert_eq!(
        hint.reason,
        Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unavailable)
    );
    let gets = s.gets;
    s.run(
        &c,
        Event::PrepareImmichArchive {
            key: retained,
            to: ImmichArchiveDestination::Archive,
            operation_id: "44444444-4444-4444-8444-444444444444".into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(s.gets, gets);
    assert_eq!(s.persists, 1);
    assert_eq!(s.writes, 0);
    s.faults.read_fail = false;
    s.run(
        &c,
        Event::RecoverImmichArchiveState {
            scene_id: SCENE.into(),
        },
    )?;
    assert!(!c.view().immich_archive_view.persistence_uncertain);
    assert_eq!(s.persists, 1);
    assert!(c.view().immich_archive_actions.is_empty());
    s.run(
        &c,
        Event::Refresh {
            permission: false,
            now: 1_800_000_000.0,
        },
    )?;
    let hint = c
        .view()
        .immich_archive_actions
        .into_iter()
        .find(|h| h.key == key())
        .ok_or("recovered hint")?;
    assert_eq!(hint.to, Some(ImmichArchiveDestination::Archive));
    assert_eq!(s.persists, 2);
    assert_eq!(s.writes, 0);
    Ok(())
}

#[test]
fn retained_snapshots_do_not_advertise_archive_before_readiness_or_schema_validation()
-> Result<(), String> {
    for ready in [false, true] {
        let mut m = model()?;
        m.ready = ready;
        if ready {
            m.state.schema_version = 6;
        }
        let c = Core::new_with(Suwop, m);
        assert!(
            c.process_event(Event::ImmichArchiveSceneChanged {
                scene_id: SCENE.into(),
                phase: ProtectionScenePhase::Active,
            })
            .is_empty()
        );
        assert!(
            c.process_event(Event::OpenImmichArchive {
                scene_id: SCENE.into()
            })
            .is_empty()
        );
        assert_eq!(
            c.view().immich_archive_view.scene_id.as_deref(),
            Some(SCENE)
        );
        let hint = c
            .view()
            .immich_archive_actions
            .into_iter()
            .find(|h| h.key == key())
            .ok_or("retained snapshot")?;
        assert_eq!(hint.to, None);
        assert_eq!(
            hint.reason,
            Some(suwop_core::immich_visibility::ImmichVisibilityUnsupportedReason::Unavailable)
        );
        assert!(
            c.process_event(prepare(ID, ImmichArchiveDestination::Archive))
                .is_empty()
        );
    }
    Ok(())
}

#[test]
fn durable_unknown_omits_old_snapshot_archive_hint_even_after_restart() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    s.faults.lost = true;
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    assert!(
        !c.view()
            .immich_archive_actions
            .iter()
            .any(|h| h.key == key())
    );
    let disk: SavedLibrary =
        serde_json::from_value(s.disk.ok_or("durable state")?).map_err(|e| e.to_string())?;
    assert_eq!(
        disk.snapshots[0].assets[0].immich_visibility,
        Some(ImmichVisibility::Timeline)
    );
    assert_eq!(
        disk.immich_visibility_operations[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Unknown
    );
    assert!(disk.immich_visibility_operations[0].observation.is_none());
    let mut restarted = model()?;
    restarted.state = disk;
    let (c, mut shell) = started(restarted)?;
    assert!(
        !c.view()
            .immich_archive_actions
            .iter()
            .any(|h| h.key == key())
    );
    shell.run(
        &c,
        prepare(
            "44444444-4444-4444-8444-444444444444",
            ImmichArchiveDestination::Archive,
        ),
    )?;
    assert_eq!(shell.gets, 0);
    assert_eq!(shell.confirms, 0);
    assert_eq!(shell.persists, 0);
    assert_eq!(shell.writes, 0);
    Ok(())
}

const OTHER_SCENE: &str = "77777777-7777-4777-8777-777777777777";
#[test]
fn other_scene_lifecycle_and_busy_open_cannot_revoke_held_confirmation() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    let generation = c.view().immich_archive_view.generation;
    s.confirmation_events = vec![
        Event::ImmichArchiveSceneChanged {
            scene_id: OTHER_SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
        Event::OpenImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
        Event::PrepareImmichArchive {
            key: key(),
            to: ImmichArchiveDestination::Archive,
            operation_id: "88888888-8888-4888-8888-888888888888".into(),
            scene_id: OTHER_SCENE.into(),
        },
        Event::ImmichArchiveSceneChanged {
            scene_id: OTHER_SCENE.into(),
            phase: ProtectionScenePhase::Inactive,
        },
        Event::CloseImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    ];
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 1);
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(SCENE)
    );
    assert_eq!(c.view().immich_archive_view.generation, generation);
    Ok(())
}
#[test]
fn owner_background_revokes_confirmation_and_rejects_late_open() -> Result<(), String> {
    let (c, mut s) = started(model()?)?;
    s.confirmation_events = vec![Event::ImmichArchiveSceneChanged {
        scene_id: SCENE.into(),
        phase: ProtectionScenePhase::Background,
    }];
    s.run(&c, prepare(ID, ImmichArchiveDestination::Archive))?;
    assert_eq!(s.writes, 0);
    assert_eq!(s.persists, 0);
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )?;
    assert!(c.view().immich_archive_view.scene_id.is_none());
    Ok(())
}
#[test]
fn explicit_idle_claim_and_close_require_fresh_open_without_faking_lifecycle() -> Result<(), String>
{
    let (c, mut s) = started(model()?)?;
    s.run(
        &c,
        Event::ImmichArchiveSceneChanged {
            scene_id: OTHER_SCENE.into(),
            phase: ProtectionScenePhase::Active,
        },
    )?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(SCENE)
    );
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(OTHER_SCENE)
    );
    let generation = c.view().immich_archive_view.generation;
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    assert_eq!(c.view().immich_archive_view.generation, generation);
    s.run(
        &c,
        Event::CloseImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    assert!(c.view().immich_archive_view.scene_id.is_none());
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(OTHER_SCENE)
    );
    s.run(
        &c,
        Event::CloseImmichArchive {
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    s.run(
        &c,
        Event::PrepareImmichArchive {
            key: key(),
            to: ImmichArchiveDestination::Archive,
            operation_id: ID.into(),
            scene_id: OTHER_SCENE.into(),
        },
    )?;
    assert_eq!(
        s.writes, 1,
        "direct action atomically acquires the active scene"
    );
    Ok(())
}

#[test]
fn account_change_revokes_owner_but_retains_actual_active_scene_registration() -> Result<(), String>
{
    let m = model()?;
    let state = m.state.clone();
    let mut next = m.session.clone().ok_or("session")?;
    next.scope = "another-account".into();
    next.user_id = "another-owner".into();
    let (c, mut s) = started(m)?;
    let generation = c.view().immich_archive_view.generation;
    s.run(
        &c,
        Event::Finished {
            state,
            session: Some(next),
            status: String::new(),
            error: None,
            preview_to_select: None,
        },
    )?;
    assert!(c.view().immich_archive_view.scene_id.is_none());
    assert!(c.view().immich_archive_view.generation > generation);
    s.run(
        &c,
        Event::OpenImmichArchive {
            scene_id: SCENE.into(),
        },
    )?;
    assert_eq!(
        c.view().immich_archive_view.scene_id.as_deref(),
        Some(SCENE)
    );
    assert_eq!(s.writes, 0);
    Ok(())
}
