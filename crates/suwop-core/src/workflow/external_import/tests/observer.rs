use super::*;

#[test]
fn creation_notification_completes_exact_item_but_cancels_unsubmitted_remainder()
-> Result<(), String> {
    for revoke in [false, true] {
        let observed = Arc::new(Mutex::new(None));
        let sink = observed.clone();
        let apple = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let ordinary = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let apple_runtime = apple.clone();
        let ordinary_runtime = ordinary.clone();
        let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
            let mut runtime = runtime(&ctx);
            runtime.apple_generation = apple_runtime;
            runtime.ordinary_generation = ordinary_runtime;
            runtime
                .state
                .snapshots
                .push(crate::domain::LibrarySnapshot {
                    provider: Provider::Apple,
                    scope: "apple".into(),
                    assets: vec![],
                    access: crate::domain::ScanAccess::Full,
                    scanned_at: Some(1.0),
                });
            let mut second = item();
            second.id = "second".into();
            second.resources[0].token = "second-token".into();
            let result = runtime
                .import_staged("operation", Provider::Apple, vec![item(), second], 1.0)
                .await;
            if let Ok(mut sink) = sink.lock() {
                *sink = Some((result, runtime.state));
            }
        });
        let key = AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "new".into(),
        };
        let mut submissions = 0;
        let mut readbacks = 0;
        for _ in 0..30 {
            let effects = command.effects().collect::<Vec<_>>();
            if effects.is_empty() {
                break;
            }
            for Effect::Io(mut effect) in effects {
                let value = match &effect.operation {
                    ShellOperation::ResolveImportResource { .. } => json!("/fixture"),
                    ShellOperation::Workspace { .. } => json!("/fixture-workspace"),
                    ShellOperation::Persist(_) | ShellOperation::ReleaseImportStaging { .. } => {
                        json!(null)
                    }
                    ShellOperation::AppleImportStaged { .. } => {
                        submissions += 1;
                        apple.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        json!([key])
                    }
                    ShellOperation::AppleImportReadback { keys, item_id, .. } => {
                        readbacks += 1;
                        assert_eq!(keys, std::slice::from_ref(&key));
                        assert_eq!(item_id, "item");
                        if revoke {
                            ordinary.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        }
                        completion_bundle(&key)
                    }
                    _ => return Err(format!("unexpected effect: {:?}", effect.operation)),
                };
                effect
                    .resolve(ShellResponse {
                        value: Some(value),
                        error: None,
                    })
                    .map_err(|_| "resolve")?;
            }
        }
        let (result, state) = observed
            .lock()
            .map_err(|_| "lock")?
            .take()
            .ok_or("not completed")?;
        assert!(
            result.is_err(),
            "old batch write authority must not be renewed"
        );
        assert_eq!(submissions, 1);
        assert_eq!(readbacks, 1);
        assert_completion(&state, &key, revoke);
    }
    Ok(())
}

fn completion_bundle(key: &AssetKey) -> serde_json::Value {
    let resource =
        json!({"id":"original","name":"photo.png","role":"image","sha1":"1".repeat(40),"bytes":4});
    json!({"assets":[{"key":key,"appleVisibility":"visible","name":"photo.png","revision":"new","resources":[resource],"isFavorite":false,"inventoryComplete":true,"isOffline":false,"deletionBlockers":[]}],"files":[{"resource":resource,"path":"/fixture","signature":{"sha256":"a".repeat(64),"bytes":4}}]})
}

fn assert_completion(state: &SavedLibrary, key: &AssetKey, revoke: bool) {
    assert_eq!(
        state.external_imports[0].phase,
        if revoke {
            ImportPhase::Uncertain
        } else {
            ImportPhase::Verified
        }
    );
    assert_eq!(
        state.external_imports[0].destination_keys.as_slice(),
        std::slice::from_ref(key)
    );
    assert_eq!(state.external_imports[1].phase, ImportPhase::Cancelled);
    assert!(
        state.snapshots[0].assets.is_empty(),
        "retired observations cannot republish catalog"
    );
    if !revoke {
        assert_eq!(
            state.snapshots[0].access,
            crate::domain::ScanAccess::Unavailable
        );
    }
}
