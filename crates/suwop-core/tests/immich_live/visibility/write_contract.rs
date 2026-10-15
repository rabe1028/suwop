//! Actual-release write denial/acceptance on the same native-CID null-forward IMAGE fixture.
use super::*;

#[test]
#[ignore = "requires the isolated dual-version Immich harness"]
fn real_exact_release_native_image_write_gate_preserves_related_resources() -> Result<(), String> {
    let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "CID URL")?;
    let api_key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "CID API key")?;
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("CID evidence root")?,
    )
    .join("write-contract");
    std::fs::create_dir_all(&root).map_err(|_| "CID evidence directory")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let share_key = std::sync::Arc::new(std::sync::Mutex::new(None::<String>));
    let mut setup = setup_command(address, api_key, &root, share_key.clone());
    drain_fixture(&agent, &mut setup)?;
    let Event::Finished {
        session: Some(session),
        status: id,
        error: None,
        ..
    } = setup.events().last().ok_or("CID setup result")?
    else {
        return Err("CID setup failed".into());
    };
    let key = AssetKey {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        asset_id: id,
    };
    let core = live_locked_core(session.clone());
    let mut shell = LiveVisibilityShell {
        agent: &agent,
        directory: &root,
        writes: 0,
        confirmations: 0,
        persists: 0,
        elevated_memberships: vec![],
        fresh_observations: vec![],
        fact_requests: BTreeMap::new(),
    };
    shell.run(
        &core,
        Event::Refresh {
            permission: false,
            now: scan_now()?,
        },
    )?;
    let supported = match (
        session.version.major,
        session.version.minor,
        session.version.patch,
    ) {
        (3, 2, 4) => false,
        (3, 3, 3) => true,
        _ => return Err("write-contract acceptance requires actual 3.2.4 or stable 3.3.3".into()),
    };
    let hint = core
        .view()
        .immich_visibility_actions
        .into_iter()
        .find(|h| h.key == key)
        .ok_or("normal native hint")?;
    assert!(!hint.can_lock);
    assert_eq!(
        hint.write_availability,
        if supported {
            suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::VerificationRequired
        } else {
            suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Unsupported
        }
    );
    let open = cid_open();
    shell.run(&core, open)?;
    super::super::live_graph::native_cid_before_product(&root)?;
    if !supported {
        return denied(&mut shell, &core, &agent, &session, &key, &root, &share_key);
    }
    accepted(&mut shell, &core, &agent, session, &key, &root, &share_key)
}
fn accepted(
    shell: &mut LiveVisibilityShell<'_>,
    core: &Core<Suwop>,
    agent: &ureq::Agent,
    session: Session,
    key: &AssetKey,
    root: &Path,
    share_key: &std::sync::Mutex<Option<String>>,
) -> Result<(), String> {
    assert!(
        core.view()
            .immich_visibility_actions
            .iter()
            .any(|h| h.key == *key
                && h.can_lock
                && h.write_availability
                    == suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Supported)
    );
    shell.run(
        core,
        prepare(
            key,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ImmichVisibility::Locked,
            GRANT,
        ),
    )?;
    assert_eq!(shell.writes, 1);
    let operations = journal(root)?.immich_visibility_operations;
    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].key, *key);
    assert_eq!(
        operations[0].outcome,
        suwop_core::apple_visibility::VisibilityOutcome::Applied
    );
    std::fs::write(
        root.join("product-journal-result.json"),
        serde_json::to_vec_pretty(&journal(root)?.immich_visibility_operations)
            .map_err(|_| "CID journal encode")?,
    )
    .map_err(|_| "CID journal evidence")?;
    let access_key = share_key
        .lock()
        .map_err(|_| "share key lock")?
        .take()
        .ok_or("share key")?;
    observe(agent, session.clone(), root, access_key.clone(), "locked")?;
    shell.run(
        core,
        prepare(
            key,
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            ImmichVisibility::Timeline,
            GRANT,
        ),
    )?;
    assert_eq!(shell.writes, 2);
    assert_eq!(shell.confirmations, 2);
    assert!(
        journal(root)?
            .immich_visibility_operations
            .iter()
            .all(|o| o.outcome == suwop_core::apple_visibility::VisibilityOutcome::Applied)
    );
    observe(agent, session, root, access_key, "unlocked")?;
    shell.run(core, Event::CloseImmichLocked)?;
    assert_eq!(shell.writes, 2);
    Ok(())
}
fn denied(
    shell: &mut LiveVisibilityShell<'_>,
    core: &Core<Suwop>,
    agent: &ureq::Agent,
    session: &Session,
    key: &AssetKey,
    root: &Path,
    share_key: &std::sync::Mutex<Option<String>>,
) -> Result<(), String> {
    let hint = core
        .view()
        .immich_visibility_actions
        .into_iter()
        .find(|h| h.key == *key)
        .ok_or("unsupported native hint")?;
    assert!(!hint.can_lock && !hint.can_show_archive && !hint.can_show_timeline);
    assert_eq!(
        hint.write_availability,
        suwop_core::immich_visibility::ImmichVisibilityWriteAvailability::Unsupported
    );
    assert_eq!(
        core.view().immich_locked_view.grant_id.as_deref(),
        Some(GRANT)
    );
    let before = serde_json::to_value(journal(root)?).map_err(|_| "before encode")?;
    let persists = shell.persists;
    shell.drain(
        core,
        core.process_event(prepare(
            key,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ImmichVisibility::Locked,
            GRANT,
        )),
    )?;
    assert_eq!(shell.persists, persists);
    assert_eq!(shell.confirmations, 0);
    assert_eq!(shell.writes, 0);
    assert_eq!(
        serde_json::to_value(journal(root)?).map_err(|_| "after encode")?,
        before
    );
    assert!(journal(root)?.immich_visibility_operations.is_empty());
    std::fs::write(root.join("old-version-write-denial.json"), serde_json::to_vec_pretty(&json!({
        "confirmedVersion":"3.2.4", "confirmations":shell.confirmations, "persistsDuringPrepare":shell.persists-persists,
        "providerPUTs":shell.writes, "journalUnchanged":true, "dedicatedReadGrantPresent":true
    })).map_err(|_| "denial evidence encode")?).map_err(|_| "denial evidence write")?;
    let access_key = share_key
        .lock()
        .map_err(|_| "share key lock")?
        .take()
        .ok_or("share key")?;
    observe(agent, session.clone(), root, access_key, "denied")?;
    shell.run(core, Event::CloseImmichLocked)?;
    Ok(())
}
fn observe(
    agent: &ureq::Agent,
    session: Session,
    root: &Path,
    share_key: String,
    phase: &'static str,
) -> Result<(), String> {
    let work = root.to_path_buf();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = match phase {
            "locked" => {
                super::super::live_graph::native_cid_observe(&ctx, session, &work, share_key).await
            }
            "unlocked" => {
                super::super::live_graph::native_cid_after_unlock(&ctx, session, &work, share_key)
                    .await
            }
            "denied" => {
                super::super::live_graph::native_cid_denied(&ctx, session, &work, share_key).await
            }
            _ => Err("unknown observer phase".into()),
        };
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
            preview_to_select: None,
        });
    });
    drain_fixture(agent, &mut command)?;
    match command.events().last() {
        Some(Event::Finished { error: None, .. }) => Ok(()),
        Some(Event::Finished {
            error: Some(error), ..
        }) => Err(error),
        _ => Err("observer completion".into()),
    }
}

fn drain_fixture(agent: &ureq::Agent, command: &mut Command<Effect, Event>) -> Result<(), String> {
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            return Ok(());
        }
        for Effect::Io(mut effect) in effects {
            let result = match &effect.operation {
                ShellOperation::Http(request) => execute(agent, request),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected CID fixture effect".into()),
            };
            effect
                .resolve(live_response(result))
                .map_err(|_| "CID fixture resolve")?;
        }
    }
}

fn setup_command(
    address: String,
    api_key: String,
    root: &Path,
    share_key: std::sync::Arc<std::sync::Mutex<Option<String>>>,
) -> Command<Effect, Event> {
    let work = root.to_path_buf();
    Command::<Effect, Event>::new(move |ctx| async move {
        let result =
            super::super::live_graph::native_cid_setup(&ctx, &address, &api_key, &work).await;
        let (session, status, error) = match result {
            Ok((s, id, key)) => match share_key.lock() {
                Ok(mut slot) => {
                    *slot = Some(key);
                    (Some(s), id, None)
                }
                Err(_) => (None, String::new(), Some("CID share key lock".into())),
            },
            Err(e) => (None, String::new(), Some(e)),
        };
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session,
            status,
            error,
            preview_to_select: None,
        });
    })
}

fn cid_open() -> Event {
    let mut open = open(GRANT);
    if let Event::OpenImmichLocked {
        email,
        password,
        pin_code,
        ..
    } = &mut open
    {
        *email = Secret(format!(
            "native-cid-image-{}@example.invalid",
            std::process::id()
        ));
        *password = Secret("GraphFixtureOnly123!".into());
        *pin_code = Secret("123456".into());
    }
    open
}
