use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{
        ConnectionSettings, Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse,
        Suwop,
    },
    domain::{AssetKey, Provider},
    immich::{Session, Version},
    immich_locked::{ImmichLockedState, Secret},
    protection::PersistentProtectedEntry,
};
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const ASSET: &str = "33333333-3333-4333-8333-333333333333";
const OWNER: &str = "44444444-4444-4444-8444-444444444444";
fn asset() -> Value {
    json!({"id":ASSET,"ownerId":OWNER,"type":"IMAGE","originalFileName":"PRIVATE-LOCKED.jpg","checksum":"a".repeat(40),"fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"revision1","isFavorite":false,"isOffline":false,"isTrashed":false,"visibility":"locked","isExternal":false})
}
fn core(protected: bool) -> Core<Suwop> {
    let session = Session {
        endpoint: "https://fixture.example/api".into(),
        key: "ordinary-api-secret".into(),
        user_id: OWNER.into(),
        scope: format!("https://fixture.example/api#{OWNER}"),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let state = SavedLibrary {
        schema_version: 5,
        apple_scope: "apple".into(),
        connection: Some(ConnectionSettings {
            address: session.endpoint.clone(),
            allow_http: false,
            credential_id: "ordinary-credential".into(),
        }),
        protected_entries: if protected {
            vec![PersistentProtectedEntry {
                id: "55555555-5555-4555-8555-555555555555".into(),
                key: AssetKey {
                    provider: Provider::Immich,
                    scope: session.scope.clone(),
                    asset_id: ASSET.into(),
                },
            }]
        } else {
            vec![]
        },
        ..SavedLibrary::default()
    };
    Core::new_with(
        Suwop,
        Model {
            state,
            session: Some(session),
            ready: true,
            ..Model::default()
        },
    )
}
fn open(id: &str) -> Event {
    Event::OpenImmichLocked {
        scene_id: SCENE.into(),
        request_id: id.into(),
        email: Secret("private@example.invalid".into()),
        password: Secret("private-password".into()),
        pin_code: Secret("123456".into()),
    }
}
#[derive(Default)]
enum AuthFault {
    #[default]
    None,
    WrongOwner,
    WrongPin,
    NoPin,
    PasswordDisabled,
}
#[derive(Default)]
struct Shell {
    paths: Vec<String>,
    status_reads: usize,
    fail_status: Option<usize>,
    fault: AuthFault,
    lock_fail: bool,
    logout_fail: bool,
    stages: usize,
    releases: Vec<String>,
}
impl Shell {
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(request) => {
                let path = request
                    .url
                    .strip_prefix("https://fixture.example/api/")
                    .ok_or("unexpected endpoint")?;
                self.paths.push(path.into());
                assert!(!request.headers.contains_key("Cookie"));
                if path == "server/features" {
                    return Ok(
                        json!({"status":200,"body":{"passwordLogin":!matches!(self.fault,AuthFault::PasswordDisabled)}}),
                    );
                }
                if path == "auth/login" {
                    assert!(!request.headers.contains_key("x-api-key"));
                    assert!(!request.headers.contains_key("Authorization"));
                    return Ok(
                        json!({"status":200,"body":{"accessToken":"dedicated-token-secret","userId":if matches!(self.fault,AuthFault::WrongOwner){"66666666-6666-4666-8666-666666666666"}else{OWNER}}}),
                    );
                }
                assert_eq!(
                    request.headers.get("Authorization").map(String::as_str),
                    Some("Bearer dedicated-token-secret")
                );
                assert!(!request.headers.contains_key("x-api-key"));
                let body = match path {
                    "users/me" => json!({"id":OWNER}),
                    "auth/status" => {
                        self.status_reads += 1;
                        if self.fail_status == Some(self.status_reads) {
                            json!({"pinCode":true,"password":true,"isElevated":false})
                        } else {
                            json!({"pinCode":!matches!(self.fault,AuthFault::NoPin),"password":true,"isElevated":true})
                        }
                    }
                    "auth/session/unlock" => {
                        assert_eq!(
                            request.body.as_ref().ok_or("no PIN body")?["pinCode"],
                            "123456"
                        );
                        if matches!(self.fault, AuthFault::WrongPin) {
                            return Ok(
                                json!({"status":400,"body":{"error":"123456 private-password dedicated-token-secret"}}),
                            );
                        }
                        Value::Null
                    }
                    "search/metadata" => {
                        assert_eq!(
                            request.body.as_ref().ok_or("no search body")?["filter"]["visibility"]
                                ["in"],
                            json!(["locked"])
                        );
                        json!({"assets":{"items":[asset()],"nextCursor":null}})
                    }
                    "auth/session/lock" => {
                        if self.lock_fail {
                            return Err("token diagnostic must never publish".into());
                        }
                        Value::Null
                    }
                    "auth/logout" => {
                        if self.logout_fail {
                            return Err("logout unavailable".into());
                        }
                        json!({"successful":true})
                    }
                    _ if path == format!("assets/{ASSET}") => asset(),
                    _ => return Err("unexpected route".into()),
                };
                Ok(json!({"status":200,"body":body}))
            }
            ShellOperation::ReadImmichLockedImage { ticket } => {
                self.stages += 1;
                Ok(json!({"requestID":ticket.request_id,"stagedID":format!("stage{}",self.stages)}))
            }
            ShellOperation::PublishImmichLockedImage { ticket, staged_id } => {
                Ok(json!({"requestID":ticket.request_id,"stagedID":staged_id}))
            }
            ShellOperation::ReleaseImmichLockedImage { staged_id } => {
                self.releases.push(staged_id.clone());
                Ok(Value::Null)
            }
            ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. } => Ok(Value::Null),
            _ => Err("unexpected ordinary/native mutation".into()),
        }
    }
    fn run(&mut self, c: &Core<Suwop>, event: Event) -> Result<(), String> {
        if matches!(event, Event::OpenImmichLocked { .. }) {
            self.drain(
                c,
                c.process_event(Event::ImmichLockedSceneChanged {
                    scene_id: SCENE.into(),
                    phase: suwop_core::protection::ProtectionScenePhase::Active,
                }),
            )?;
        }
        self.drain(c, c.process_event(event))
    }
    fn drain(&mut self, c: &Core<Suwop>, mut effects: Vec<Effect>) -> Result<(), String> {
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.respond(&request.operation) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(
                c.resolve(&mut request, response)
                    .map_err(|_| "resolve failed")?,
            );
        }
        Ok(())
    }
}
fn image() -> Event {
    Event::RequestImmichLockedImage {
        entry_id: ASSET.into(),
        grant_id: GRANT.into(),
        request_id: "77777777-7777-4777-8777-777777777777".into(),
    }
}
#[test]
fn dedicated_session_never_enters_ordinary_projection_or_persistence() -> Result<(), String> {
    let c = core(false);
    let mut s = Shell::default();
    let before = serde_json::to_value(c.view().state).map_err(|_| "serialize")?;
    s.run(&c, open(GRANT))?;
    assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Open);
    assert_eq!(
        c.view()
            .immich_locked_view
            .entries
            .as_ref()
            .ok_or("no entries")?
            .len(),
        1
    );
    assert_eq!(
        serde_json::to_value(c.view().state).map_err(|_| "serialize")?,
        before
    );
    let view = serde_json::to_string(&c.view()).map_err(|_| "serialize")?;
    for secret in [
        "dedicated-token-secret",
        "ordinary-api-secret",
        "private-password",
        "private@example.invalid",
        "123456",
    ] {
        assert!(!view.contains(secret));
    }
    s.run(&c, image())?;
    assert!(c.view().immich_locked_view.image.is_some());
    s.run(&c, Event::CloseImmichLocked)?;
    let view = serde_json::to_string(&c.view()).map_err(|_| "serialize")?;
    assert!(!view.contains("PRIVATE-LOCKED"));
    assert!(!view.contains(ASSET));
    assert_eq!(
        c.view().immich_locked_view.remote_lock_confirmed,
        Some(true)
    );
    Ok(())
}
#[test]
fn wrong_pin_wrong_account_and_unset_pin_never_publish_private_entries() -> Result<(), String> {
    for fault in 0..4 {
        let c = core(false);
        let mut s = Shell {
            fault: match fault {
                0 => AuthFault::WrongPin,
                1 => AuthFault::WrongOwner,
                2 => AuthFault::NoPin,
                _ => AuthFault::PasswordDisabled,
            },
            ..Shell::default()
        };
        s.run(&c, open(GRANT))?;
        assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Locked);
        let view = serde_json::to_string(&c.view()).map_err(|_| "serialize")?;
        for private in [
            "PRIVATE-LOCKED",
            ASSET,
            "123456",
            "private-password",
            "dedicated-token-secret",
        ] {
            assert!(!view.contains(private));
        }
        if fault == 3 {
            assert!(!s.paths.contains(&"auth/login".into()));
        } else {
            assert!(s.paths.contains(&"auth/logout".into()));
        }
    }
    Ok(())
}
#[test]
fn app_protection_still_denies_locked_source_after_server_pin() -> Result<(), String> {
    let c = core(true);
    let mut s = Shell::default();
    s.run(&c, open(GRANT))?;
    assert!(
        c.view()
            .immich_locked_view
            .entries
            .as_ref()
            .ok_or("no entries")?
            .is_empty()
    );
    s.run(&c, image())?;
    assert_eq!(s.stages, 0);
    Ok(())
}
#[test]
fn lost_elevation_before_and_after_staging_never_publishes_and_releases_exact_stage()
-> Result<(), String> {
    for read in [4, 5, 6] {
        let c = core(false);
        let mut s = Shell {
            fail_status: Some(read),
            ..Shell::default()
        };
        s.run(&c, open(GRANT))?;
        s.run(&c, image())?;
        assert!(c.view().immich_locked_view.image.is_none());
        if read > 4 {
            assert_eq!(s.releases, vec!["stage1"]);
        } else {
            assert_eq!(s.stages, 0);
        }
    }
    Ok(())
}
#[test]
fn stale_login_response_is_cleaned_up_and_cannot_reopen_closed_surface() -> Result<(), String> {
    let c = core(false);
    let mut s = Shell::default();
    s.run(
        &c,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Active,
        },
    )?;
    let mut effects = c.process_event(open(GRANT));
    let Effect::Io(mut preflight) = effects.remove(0);
    let value = s.respond(&preflight.operation)?;
    effects.extend(
        c.resolve(
            &mut preflight,
            ShellResponse {
                value: Some(value),
                error: None,
            },
        )
        .map_err(|_| "preflight resolve")?,
    );
    let index = effects
        .iter()
        .position(|e| matches!(e,Effect::Io(r) if matches!(r.operation,ShellOperation::Http(_))))
        .ok_or("no login")?;
    let Effect::Io(mut request) = effects.remove(index);
    s.run(
        &c,
        Event::ImmichLockedSceneChanged {
            scene_id: SCENE.into(),
            phase: suwop_core::protection::ProtectionScenePhase::Background,
        },
    )?;
    let value = s.respond(&request.operation)?;
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
    s.drain(&c, effects)?;
    assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Locked);
    assert!(s.paths.contains(&"auth/session/lock".into()));
    assert!(s.paths.contains(&"auth/logout".into()));
    Ok(())
}
#[test]
fn lease_renewal_ignores_old_timer_and_current_expiry_revokes_locally_even_if_lock_fails()
-> Result<(), String> {
    let c = core(false);
    let mut s = Shell {
        lock_fail: true,
        logout_fail: true,
        ..Shell::default()
    };
    s.run(&c, open(GRANT))?;
    let old = c.view().immich_locked_view;
    s.run(
        &c,
        Event::CheckImmichLockedSession {
            grant_id: GRANT.into(),
            generation: old.generation,
            lease_id: old.lease_id,
        },
    )?;
    let new = c.view().immich_locked_view;
    assert!(new.lease_id > old.lease_id);
    s.run(
        &c,
        Event::ExpireImmichLocked {
            grant_id: GRANT.into(),
            generation: old.generation,
            lease_id: old.lease_id,
        },
    )?;
    assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Open);
    s.run(
        &c,
        Event::ExpireImmichLocked {
            grant_id: GRANT.into(),
            generation: new.generation,
            lease_id: new.lease_id,
        },
    )?;
    assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Locked);
    assert_eq!(
        c.view().immich_locked_view.remote_lock_confirmed,
        Some(false)
    );
    assert!(s.paths.contains(&"auth/logout".into()));
    Ok(())
}

#[test]
fn inactive_scene_rejects_queued_open_without_credentials_or_server_side_session()
-> Result<(), String> {
    for phase in [
        suwop_core::protection::ProtectionScenePhase::Inactive,
        suwop_core::protection::ProtectionScenePhase::Background,
    ] {
        let c = core(false);
        let mut s = Shell::default();
        s.run(
            &c,
            Event::ImmichLockedSceneChanged {
                scene_id: SCENE.into(),
                phase: suwop_core::protection::ProtectionScenePhase::Active,
            },
        )?;
        s.run(
            &c,
            Event::ImmichLockedSceneChanged {
                scene_id: SCENE.into(),
                phase,
            },
        )?;
        s.drain(&c, c.process_event(open(GRANT)))?;
        assert_eq!(c.view().immich_locked_view.state, ImmichLockedState::Locked);
        assert!(s.paths.is_empty());
        assert!(c.view().immich_locked_view.entries.is_none());
    }
    Ok(())
}
