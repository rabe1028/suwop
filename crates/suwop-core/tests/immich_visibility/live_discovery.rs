//! Real reducer/effect projection; no native media callbacks are substituted here.
use super::*;
use suwop_core::immich_locked::live::ImmichLockedLiveDiscovery;
const MOTION: &str = "66666666-6666-4666-8666-666666666666";

fn inventory(raw: &Value) -> std::collections::VecDeque<Value> {
    [json!({"assets":{"items":[raw],"nextCursor":null}})].into()
}

#[test]
fn live_discovery_projection_distinguishes_absence_and_updates_only_on_explicit_refresh()
-> Result<(), String> {
    let core = core(false);
    let mut raw = asset();
    raw["visibility"] = json!("locked");
    raw.as_object_mut()
        .ok_or("asset")?
        .remove("livePhotoVideoId");
    let mut shell = Shell {
        pages: Some(inventory(&raw)),
        ..Shell::default()
    };
    shell.run(&core, open(GRANT))?;
    let entry = core
        .view()
        .immich_locked_view
        .entries
        .ok_or("entries")?
        .remove(0);
    assert_eq!(entry.live_discovery, ImmichLockedLiveDiscovery::Unknown);
    let projected = serde_json::to_value(&entry).map_err(|e| e.to_string())?;
    let mut legacy = projected.clone();
    legacy
        .as_object_mut()
        .ok_or("entry")?
        .remove("liveDiscovery");
    let decoded: suwop_core::immich_locked::ImmichLockedEntry =
        serde_json::from_value(legacy).map_err(|e| e.to_string())?;
    assert_eq!(decoded.live_discovery, ImmichLockedLiveDiscovery::Unknown);
    for (forward, expected) in [
        (Value::Null, ImmichLockedLiveDiscovery::ObservedUnlinked),
        (json!(MOTION), ImmichLockedLiveDiscovery::ObservedLinked),
        (json!(ASSET), ImmichLockedLiveDiscovery::Unsupported),
    ] {
        raw["livePhotoVideoId"] = forward;
        shell.pages = Some(inventory(&raw));
        shell.run(
            &core,
            Event::RefreshImmichLocked {
                grant_id: GRANT.into(),
                scene_id: SCENE.into(),
            },
        )?;
        let view = core.view();
        let entry = view.immich_locked_view.entries.ok_or("entries")?.remove(0);
        assert_eq!(entry.live_discovery, expected);
        assert!(view.immich_locked_view.live_pending.is_none());
        assert!(view.immich_locked_view.live.is_none());
    }
    assert_eq!(shell.writes, 0);
    assert_eq!(shell.persist_calls, 0);
    assert_eq!(shell.confirmations, 0);
    assert_eq!(shell.stages, 0);
    assert_eq!(
        shell
            .paths
            .iter()
            .filter(|path| path.starts_with("assets/"))
            .count(),
        0
    );
    Ok(())
}

#[test]
fn linked_discovery_hint_does_not_grant_pair_or_original_read_authority() -> Result<(), String> {
    let core = core(false);
    let mut raw = asset();
    raw["visibility"] = json!("locked");
    raw["livePhotoVideoId"] = json!(MOTION);
    let mut shell = Shell {
        pages: Some(inventory(&raw)),
        ..Shell::default()
    };
    shell.run(&core, open(GRANT))?;
    let entry = core
        .view()
        .immich_locked_view
        .entries
        .ok_or("entries")?
        .remove(0);
    assert_eq!(
        entry.live_discovery,
        ImmichLockedLiveDiscovery::ObservedLinked
    );
    assert!(
        core.process_event(Event::InspectImmichLiveResources {
            parent_key: entry.asset.key,
            request_id: OP.into(),
            grant_id: NEXT.into(),
            scene_id: SCENE.into(),
        })
        .is_empty()
    );
    assert_eq!(shell.writes, 0);
    assert_eq!(shell.stages, 0);
    assert!(core.view().immich_live_resources.is_none());
    Ok(())
}
