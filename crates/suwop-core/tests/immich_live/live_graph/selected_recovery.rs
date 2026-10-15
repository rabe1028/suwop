//! Seeded legacy recovery on a real server, not a native-metadata causation test.
use super::*;
use crux_core::Core;
use suwop_core::{
    app::{ConnectionSettings, Model, Suwop},
    domain::{AssetKey, Provider},
    immich_locked::Secret,
    immich_visibility::{ImmichVisibility, ImmichVisibilityUnsupportedReason},
};
#[path = "selected_recovery_fixture.rs"]
mod fixture;
#[path = "selected_recovery_shell.rs"]
mod shell;
pub(super) use fixture::Fixture;
use shell::RecoveryShell;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
const OP: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

#[test]
#[ignore = "requires the isolated Docker Immich harness"]
fn real_legacy_image_inspect_records_linked_selected_state_without_replay() -> Result<(), String> {
    let root = std::env::temp_dir().join(format!("suwop-selected-recovery-{}", std::process::id()));
    std::fs::create_dir_all(&root).map_err(|_| "recovery directory")?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let fixture = Fixture::setup(&agent, &root)?;
    let baseline = fixture.observe(&agent, &root)?;
    evidence("observer-before", &baseline)?;
    for outcome in ["applied", "unknown"] {
        let directory = root.join(outcome);
        std::fs::create_dir_all(&directory).map_err(|_| "branch directory")?;
        exercise(&agent, &fixture, &directory, outcome)?;
        let after = fixture.observe(&agent, &root)?;
        assert_eq!(after, baseline);
        evidence(&format!("observer-after-{outcome}"), &after)?;
    }
    fixture.close(&agent)?;
    std::fs::remove_dir_all(root).map_err(|_| "recovery cleanup")?;
    Ok(())
}
fn fresh_core(session: &Session) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            session: Some(session.clone()),
            ..Model::default()
        },
    )
}
fn legacy_witness(key: &AssetKey) -> Result<String, String> {
    let bytes = serde_json::to_vec(&(key, "IMAGE", fixture::STILL_SHA1, "unlinked", "unstacked"))
        .map_err(|_| "legacy witness encode")?;
    Ok(format!("{:x}", sha2::Sha256::digest(bytes)))
}
#[test]
fn seeded_image_witness_matches_retained_schema_seven_codec() -> Result<(), String> {
    let key = AssetKey {
        provider: Provider::Immich,
        scope: "http://127.0.0.1:22875/api#7c8f099a-a489-4872-92a6-a2fee56a6a9e".into(),
        asset_id: "59e552ca-12c2-44a3-b47d-16372fc06cc2".into(),
    };
    assert_eq!(
        legacy_witness(&key)?,
        "9c478763f2b84ae21f3592c1943903999b57bfe4d9aa4cb9340785a869df6285"
    );
    Ok(())
}
fn evidence(label: &str, value: &Value) -> Result<(), String> {
    use std::io::Write;
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("recovery evidence root")?,
    )
    .join("selected-recovery");
    std::fs::create_dir_all(&root).map_err(|_| "recovery evidence directory")?;
    let encoded = serde_json::to_vec_pretty(value).map_err(|_| "recovery evidence encode")?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(root.join(format!("{label}.json")))
        .and_then(|mut f| f.write_all(&encoded))
        .map_err(|_| "recovery evidence write".into())
}
pub(super) fn legacy(key: &AssetKey, session: &Session, outcome: &str) -> Result<Value, String> {
    // Frozen schema-7 IMAGE identity codec; no current relationship authority is invented.
    let witness = legacy_witness(key)?;
    let operation = json!({"kind":"lockedTransition","id":OP,"scope":key.scope,"key":key,
        "witnessDigest":witness,"from":"timeline","to":"locked","outcome":outcome,
        "observation":if outcome == "applied" {json!("locked")} else {Value::Null},
        "albumMembershipObservation":if outcome == "applied" {"noAccessibleMemberships"} else {"notChecked"}});
    let state = SavedLibrary {
        schema_version: 7,
        apple_scope: "apple".into(),
        connection: Some(ConnectionSettings {
            address: session.endpoint.clone(),
            allow_http: true,
            credential_id: "fixture".into(),
        }),
        ..SavedLibrary::default()
    };
    let mut raw = serde_json::to_value(state).map_err(|_| "legacy state encode")?;
    raw["immichVisibilityOperations"] = json!([operation]);
    Ok(raw)
}
fn open(email: &str, grant: &str) -> Event {
    Event::OpenImmichLocked {
        scene_id: SCENE.into(),
        request_id: grant.into(),
        email: Secret(email.into()),
        password: Secret("GraphFixtureOnly123!".into()),
        pin_code: Secret(super::PIN.into()),
    }
}
fn inspect(grant: &str) -> Event {
    Event::InspectImmichVisibility {
        record_id: OP.into(),
        grant_id: grant.into(),
        scene_id: SCENE.into(),
    }
}
fn old_fields(mut operation: Value) -> Value {
    operation
        .as_object_mut()
        .map(|o| o.remove("selectedObservation"));
    operation
}
fn exercise(
    agent: &ureq::Agent,
    fixture: &Fixture,
    directory: &Path,
    outcome: &str,
) -> Result<(), String> {
    let key = fixture.key();
    let input = legacy(&key, &fixture.elevated.ordinary, outcome)?;
    let old = input["immichVisibilityOperations"][0].clone();
    evidence(&format!("{outcome}-legacy-input"), &input)?;
    let mut host = RecoveryShell::new(agent, directory, &fixture.elevated.ordinary, &input)?;
    let core = fresh_core(&fixture.elevated.ordinary);
    host.run(
        &core,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    assert_eq!(host.raw()?["schemaVersion"], 8);
    assert_eq!(host.operation()?, old);
    evidence(&format!("{outcome}-migrated-before"), &host.raw()?)?;
    host.authenticate(&core, &fixture.email, GRANT)?;
    if outcome == "unknown" {
        assert_no_selected_row(&core, &key);
    }
    host.reset_trace();
    host.inspect_only = Some(key.asset_id.clone());
    host.run(&core, inspect(GRANT))?;
    host.assert_inspect_trace();
    let observed = host.operation()?;
    evidence(&format!("{outcome}-after-inspect"), &host.raw()?)?;
    evidence(&format!("{outcome}-inspect-effects"), &json!(host.trace))?;
    assert_eq!(old_fields(observed.clone()), old);
    let proof = &observed["selectedObservation"];
    assert_eq!(proof["visibility"], "locked");
    assert_eq!(proof["configuration"], "linked");
    for field in ["selectedIdentityDigest", "configurationDigest"] {
        let digest = proof[field].as_str().ok_or("observation digest")?;
        assert_eq!(digest.len(), 64);
        assert!(digest.bytes().all(|c| c.is_ascii_hexdigit()));
    }
    assert_ne!(proof["selectedIdentityDigest"], observed["witnessDigest"]);
    assert_projection(&core, &key, &fixture.motion, outcome)?;
    assert_fenced(&core, &host, &key)?;
    host.reset_trace();
    host.run(
        &core,
        Event::PrepareImmichVisibility {
            key: key.clone(),
            to: ImmichVisibility::Archive,
            operation_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into(),
            grant_id: GRANT.into(),
            scene_id: SCENE.into(),
        },
    )?;
    assert!(host.trace.is_empty());
    assert_eq!(host.operation()?, observed);
    host.inspect_only = None;
    host.run(&core, Event::CloseImmichLocked)?;
    reload(&mut host, fixture, outcome, &key, &old, &observed)
}
fn assert_projection(
    core: &Core<Suwop>,
    key: &AssetKey,
    motion: &str,
    outcome: &str,
) -> Result<(), String> {
    let view = core.view();
    let entries = view
        .immich_locked_view
        .entries
        .ok_or("authenticated rows")?;
    let row = entries
        .iter()
        .find(|e| e.asset.key == *key)
        .ok_or("fresh selected row")?;
    let hint = &row.visibility_action;
    assert!(!hint.can_lock && !hint.can_show_timeline && !hint.can_show_archive);
    assert_eq!(hint.reason, Some(ImmichVisibilityUnsupportedReason::Live));
    let history = view
        .immich_visibility_view
        .history
        .ok_or("authenticated history")?;
    let summary = history
        .iter()
        .find(|r| r.record_id == OP)
        .ok_or("selected summary")?;
    let raw = serde_json::to_value(summary).map_err(|_| "summary encode")?;
    assert_eq!(
        raw["selectedObservation"],
        json!({"visibility":"locked","configuration":"linked"})
    );
    assert_eq!(raw["outcome"], outcome);
    assert_eq!(
        raw["observation"],
        if outcome == "applied" {
            json!("locked")
        } else {
            Value::Null
        }
    );
    let text = raw.to_string();
    assert!(!text.contains(motion) && !text.contains("Digest"));
    assert!(view.immich_locked_view.image.is_none());
    Ok(())
}
fn assert_no_selected_row(core: &Core<Suwop>, key: &AssetKey) {
    assert!(
        core.view()
            .immich_locked_view
            .entries
            .unwrap_or_default()
            .iter()
            .all(|e| e.asset.key != *key)
    );
}
fn assert_fenced(
    core: &Core<Suwop>,
    host: &RecoveryShell<'_>,
    key: &AssetKey,
) -> Result<(), String> {
    let state: SavedLibrary =
        serde_json::from_value(host.raw()?).map_err(|_| "canonical decode")?;
    assert!(suwop_core::immich_visibility::fences(&state, key));
    assert!(!core.view().ordinary_content_keys.contains(key));
    Ok(())
}
fn reload(
    host: &mut RecoveryShell<'_>,
    fixture: &Fixture,
    outcome: &str,
    key: &AssetKey,
    old: &Value,
    observed: &Value,
) -> Result<(), String> {
    let core = fresh_core(&fixture.elevated.ordinary);
    host.reset_trace();
    host.run(
        &core,
        Event::Initialize {
            scope: "apple".into(),
        },
    )?;
    assert_eq!(host.trace, ["readState", "persist"]);
    assert_eq!(&host.operation()?, observed);
    evidence(&format!("{outcome}-durable-reload"), &host.raw()?)?;
    assert_eq!(&old_fields(host.operation()?), old);
    assert_fenced(&core, host, key)?;
    let view = core.view();
    assert!(view.immich_locked_view.grant_id.is_none());
    assert!(view.immich_locked_view.entries.is_none() && view.immich_locked_view.image.is_none());
    assert!(view.immich_visibility_view.history.is_none());
    host.reset_trace();
    host.run(&core, inspect(GRANT))?;
    assert!(host.trace.is_empty());
    if outcome == "unknown" {
        let next = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
        host.authenticate(&core, &fixture.email, next)?;
        assert_no_selected_row(&core, key);
        host.reset_trace();
        host.inspect_only = Some(key.asset_id.clone());
        host.run(&core, inspect(next))?;
        host.assert_inspect_trace();
        assert_projection(&core, key, &fixture.motion, outcome)?;
        assert_eq!(&host.operation()?, observed);
        host.inspect_only = None;
        host.run(&core, Event::CloseImmichLocked)?;
    }
    Ok(())
}
