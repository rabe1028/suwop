//! Actual C ABI resolution and local CAS for oversized, core-issued catalog I/O.
use super::{NEXT, Runtime, cores, input_limits, suwop_call, suwop_drop, suwop_free};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    ffi::{CStr, CString},
    sync::atomic::Ordering,
};
use suwop_core::{
    app::{ConnectionSettings, Model, SavedLibrary},
    domain::{
        AppleVisibility, AssetKey, ImmichStackState, LibrarySnapshot, Provider, ScanAccess,
        StoredAsset,
    },
    immich::{Session, Version},
};
const ORDINARY: usize = 16 * 1024 * 1024;
const CATALOG: usize = 256 * 1024 * 1024;
const SCENE: &str = "11111111-1111-4111-8111-111111111111";
const GRANT: &str = "22222222-2222-4222-8222-222222222222";
struct Handle(u64);
impl Drop for Handle {
    fn drop(&mut self) {
        suwop_drop(self.0);
    }
}
fn fixture() -> Result<SavedLibrary, String> {
    let corpus: Value = serde_json::from_str(include_str!(
        "../../suwop-core/tests/fixtures/live-journal-wire.json"
    ))
    .map_err(|e| e.to_string())?;
    serde_json::from_value(corpus["validStates"][0]["library"].clone()).map_err(|e| e.to_string())
}
fn install(state: SavedLibrary) -> Result<Handle, String> {
    let batch = state
        .immich_live_operations
        .first()
        .ok_or("fixture batch")?;
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://fixture.invalid/api".into(),
        key: "synthetic-only".into(),
        user_id: batch.intent.owner_id.clone(),
        scope: batch.intent.scope.clone(),
        version: Version {
            major: 3,
            minor: 3,
            patch: 3,
        },
    };
    let mut state = state;
    state.connection = Some(ConnectionSettings {
        address: "https://fixture.invalid/api".into(),
        allow_http: false,
        credential_id: "synthetic-only".into(),
    });
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    cores().lock().map_err(|_| "core registry lock")?.insert(
        id,
        Runtime::new(Model {
            state,
            session: Some(session),
            ready: true,
            ..Model::default()
        }),
    );
    Ok(Handle(id))
}
fn call(handle: u64, action: u32, input: &str) -> Result<Value, String> {
    let input = CString::new(input).map_err(|e| e.to_string())?;
    // SAFETY: this live CString supplies the NUL-terminated ABI input. The returned allocation is read and freed once.
    let pointer = unsafe { suwop_call(handle, action, input.as_ptr()) };
    if pointer.is_null() {
        return Err("null ABI envelope".into());
    }
    // SAFETY: pointer is the live allocation returned by suwop_call above.
    let decoded = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|e| e.to_string())
        .and_then(|text| serde_json::from_str(text).map_err(|e| e.to_string()));
    // SAFETY: the allocation is freed exactly once after the read, including decoding failure.
    unsafe { suwop_free(pointer) };
    decoded
}
fn value(envelope: Value) -> Result<Value, String> {
    let Value::Object(mut fields) = envelope else {
        return Err("ABI envelope is not an object".into());
    };
    if let Some(error) = fields.remove("error") {
        return Err(format!("ABI error: {error}"));
    }
    fields
        .remove("value")
        .ok_or_else(|| "missing ABI value".into())
}
fn effect_list(value: Value) -> Result<Vec<Value>, String> {
    let Value::Array(effects) = value else {
        return Err("effects are not an array".into());
    };
    Ok(effects)
}

fn event(handle: u64, event: &Value) -> Result<Vec<Value>, String> {
    effect_list(value(call(handle, 0, &event.to_string())?)?)
}
fn reply_text(id: u32, response: &Value) -> String {
    json!({"id":id,"response":{"value":response,"error":null}}).to_string()
}
fn resolve(handle: u64, id: u32, response: &Value) -> Result<Vec<Value>, String> {
    effect_list(value(call(handle, 1, &reply_text(id, response))?)?)
}
fn effect_id(effect: &Value) -> Result<u32, String> {
    effect["id"]
        .as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| "effect ID".into())
}
fn io(effect: &Value) -> &Value {
    &effect["effect"]["Io"]
}
fn synthetic_http(request: &Value, owner: &str) -> Result<Value, String> {
    let path = request["url"]
        .as_str()
        .and_then(|u| u.strip_prefix("https://fixture.invalid/api/"))
        .ok_or("synthetic endpoint")?;
    let method = request["method"].as_str().ok_or("method")?;
    assert!(!path.contains("original"));
    assert_ne!(method, "PUT");
    assert_ne!(method, "DELETE");
    let body = match path {
        "server/features" => json!({"passwordLogin":true}),
        "auth/login" => json!({"accessToken":"synthetic-dedicated-token","userId":owner}),
        "users/me" => json!({"id":owner}),
        "auth/status" => json!({"password":true,"pinCode":true,"isElevated":true}),
        "auth/session/unlock" | "auth/session/lock" => Value::Null,
        "auth/logout" => json!({"successful":true}),
        "server/version" => json!({"major":3,"minor":3,"patch":3,"prerelease":null}),
        "search/metadata" => json!({"assets":{"items":[],"nextCursor":null}}),
        p if p.starts_with("assets/") => return Ok(json!({"status":403,"body":null,"path":null})),
        other => return Err(format!("unexpected synthetic path {other}")),
    };
    Ok(json!({"status":200,"body":body,"path":null}))
}
fn drain(
    handle: u64,
    effects: Vec<Value>,
    owner: &str,
    stop: &str,
) -> Result<Option<Value>, String> {
    let mut queue: VecDeque<_> = effects.into();
    while let Some(effect) = queue.pop_front() {
        let op = io(&effect);
        let kind = op["type"].as_str().ok_or("effect type")?;
        if kind == stop {
            return Ok(Some(effect));
        }
        let response = match kind {
            "http" => synthetic_http(&op["data"], owner)?,
            "wait" | "scheduleImmichLockedExpiry" => continue, // Leave expiry timers pending; never synthesize elapsed time.
            "releaseImmichLockedImages"
            | "releaseImmichLockedVideos"
            | "releaseImmichLockedLives" => Value::Null,
            other => return Err(format!("unexpected bridge effect {other}")),
        };
        queue.extend(resolve(handle, effect_id(&effect)?, &response)?);
    }
    Ok(None)
}
fn large(state: &SavedLibrary) -> SavedLibrary {
    let mut state = state.clone();
    let asset = StoredAsset {
        key: AssetKey {
            provider: Provider::Apple,
            scope: state.apple_scope.clone(),
            asset_id: "synthetic-large-apple".into(),
        },
        name: "x".repeat(18 * 1024 * 1024),
        revision: "fixture".into(),
        apple_visibility: AppleVisibility::Visible,
        immich_visibility: None,
        immich_stack: ImmichStackState::Unknown,
        immich_stack_membership: None,
        captured_at: None,
        modified_at: None,
        resources: vec![],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: false,
        is_offline: false,
        deletion_blockers: vec![],
    };
    state.snapshots.push(LibrarySnapshot {
        provider: Provider::Apple,
        scope: state.apple_scope.clone(),
        assets: vec![asset],
        access: ScanAccess::Full,
        scanned_at: None,
    });
    state
}
fn local(root: &str, command: &Value) -> Result<Value, String> {
    value(call(
        0,
        15,
        &json!({"root":root,"command":command}).to_string(),
    )?)
}
fn open(handle: u64, owner: &str) -> Result<(), String> {
    drain(
        handle,
        event(
            handle,
            &json!({"type":"immichLockedSceneChanged","sceneID":SCENE,"phase":"active"}),
        )?,
        owner,
        "",
    )?;
    let effects = event(
        handle,
        &json!({"type":"openImmichLocked","sceneID":SCENE,"requestID":GRANT,"email":"synthetic@example.invalid","password":"synthetic-password","pinCode":"123456"}),
    )?;
    let network = effects
        .iter()
        .find(|effect| io(effect)["type"] == "http")
        .ok_or("issued network effect")?;
    let oversized = json!({"padding":"x".repeat(ORDINARY+1)});
    let denied = call(handle, 1, &reply_text(effect_id(network)?, &oversized))?;
    assert_eq!(denied["error"], input_limits::ERROR);
    assert_eq!(
        call(handle, 1, &reply_text(u32::MAX, &oversized))?["error"],
        input_limits::ERROR
    );
    drop(oversized);
    drain(handle, effects, owner, "")?;
    Ok(())
}
#[test]
fn actual_core_bulk_reply_consumes_id_and_emits_large_actual_local_cas() -> Result<(), String> {
    let state = fixture()?;
    let batch = state.immich_live_operations.first().ok_or("batch")?;
    let batch_id = batch.id.clone();
    let owner = batch.intent.owner_id.clone();
    let handle = install(state.clone())?;
    let large = large(&state);
    let root = std::env::temp_dir().join(format!(
        "suwop-ffi-live-journal-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let root = root.to_str().ok_or("UTF8 temporary root")?;
    local(root, &json!({"type":"persist","state":large}))?;
    let versioned = local(root, &json!({"type":"readVersioned"}))?;
    open(handle.0, &owner)?;
    let effects = event(
        handle.0,
        &json!({"type":"inspectImmichLivePlacement","batchID":batch_id,"requestID":"33333333-3333-4333-8333-333333333333","grantID":GRANT,"sceneID":SCENE}),
    )?;
    let read = drain(handle.0, effects, &owner, "readStateVersioned")?
        .ok_or("core did not issue versioned read")?;
    let read_id = effect_id(&read)?;
    let text = reply_text(read_id, &versioned);
    assert!(text.len() > ORDINARY);
    let effects = effect_list(value(call(handle.0, 1, &text)?)?)?;
    assert_eq!(
        call(handle.0, 1, &text)?["error"],
        input_limits::ERROR,
        "consumed read ID cannot retain bulk authority"
    );
    let cas = effects
        .iter()
        .find(|e| io(e)["type"] == "persistIfCurrent")
        .ok_or("large versioned reply did not emit CAS")?;
    let command = json!({"type":"persistIfCurrent","revision":io(cas)["data"]["revision"],"state":io(cas)["data"]["state"]});
    assert!(command.to_string().len() > ORDINARY);
    assert_eq!(
        command["state"]["snapshots"][0]["assets"][0]["name"]
            .as_str()
            .map(str::len),
        Some(18 * 1024 * 1024)
    );
    let accepted = local(root, &command)?;
    assert_eq!(accepted, true);
    drain(
        handle.0,
        resolve(handle.0, effect_id(cas)?, &accepted)?,
        &owner,
        "",
    )?;
    assert_eq!(
        local(root, &command)?,
        false,
        "stale local CAS revision is rejected by actual storage"
    );
    let saved = local(root, &json!({"type":"read"}))?;
    assert_eq!(
        saved["snapshots"][0]["assets"][0]["name"]
            .as_str()
            .map(str::len),
        Some(18 * 1024 * 1024)
    );
    assert!(
        !saved["immichLiveOperations"][0]["latestObservations"]
            .as_array()
            .ok_or("observations")?
            .is_empty()
    );
    Ok(())
}
#[test]
fn actual_abi_rejects_over_256_mib_before_json_or_handle_dispatch() -> Result<(), String> {
    // Single allocation, reused across both ABI actions; no giant JSON tree or catalog copy.
    let mut bytes = vec![b' '; CATALOG + 2];
    let last = bytes.last_mut().ok_or("buffer")?;
    *last = 0;
    let input = CString::from_vec_with_nul(bytes).map_err(|e| e.to_string())?;
    for action in [1, 15] {
        // SAFETY: the owned CString remains live throughout the ABI call.
        let pointer = unsafe { suwop_call(0, action, input.as_ptr()) };
        if pointer.is_null() {
            return Err("null envelope".into());
        }
        // SAFETY: returned allocation remains live until the single free below.
        let decoded: Result<Value, String> = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .map_err(|e| e.to_string())
            .and_then(|text| serde_json::from_str(text).map_err(|e| e.to_string()));
        // SAFETY: free exactly once even if decoding failed.
        unsafe { suwop_free(pointer) };
        assert_eq!(decoded?["error"], input_limits::ERROR);
    }
    Ok(())
}
