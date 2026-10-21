//! Envelope equivalence for raw view serialization, and a synthetic snapshot benchmark.
use super::*;
use std::time::{Duration, Instant};
use suwop_core::{
    app::Model,
    domain::{
        AppleVisibility, AssetKey, ImmichStackState, LibrarySnapshot, Provider, ScanAccess,
        StoredAsset,
    },
};

fn asset(index: u32) -> StoredAsset {
    StoredAsset {
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: format!("photo-{index:06}"),
        },
        name: format!("IMG_{index:06}.HEIC \"quoted\" \u{65e5}\u{672c}"),
        revision: format!("r{index}"),
        apple_visibility: AppleVisibility::Visible,
        immich_visibility: None,
        immich_stack: ImmichStackState::Unknown,
        captured_at: None,
        modified_at: None,
        resources: vec![],
        is_favorite: index.is_multiple_of(7),
        latitude: Some(35.0 + f64::from(index) / 3.0e4),
        longitude: Some(139.0 - f64::from(index) / 7.0e4),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

fn model(count: u32) -> Model {
    let mut model = Model::default();
    model.state.apple_scope = "apple".into();
    model.state.snapshots = vec![LibrarySnapshot {
        provider: Provider::Apple,
        scope: "apple".into(),
        assets: (0..count).map(asset).collect(),
        access: ScanAccess::Full,
        scanned_at: None,
    }];
    model
}

fn install(model: Model) -> Result<u64, String> {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    cores()
        .lock()
        .map_err(|_| "registry lock")?
        .insert(id, Runtime::new(model));
    Ok(id)
}

fn call(handle: u64, action: u32, input: &str) -> Result<String, String> {
    let input = CString::new(input).map_err(|e| e.to_string())?;
    // SAFETY: a live NUL-terminated string is passed and the result is freed once below.
    let pointer = unsafe { suwop_call(handle, action, input.as_ptr()) };
    if pointer.is_null() {
        return Err("null envelope".into());
    }
    // SAFETY: `pointer` is the live allocation returned above.
    let text = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|e| e.to_string());
    // SAFETY: freed exactly once.
    unsafe { suwop_free(pointer) };
    text
}

/// The envelope as produced before raw splicing: parse into `Value`, wrap, re-serialize.
fn legacy_envelope(output: &[u8]) -> Result<String, String> {
    let value: Value = serde_json::from_slice(output).map_err(|e| e.to_string())?;
    Ok(json!({"value":value}).to_string())
}

fn bridge_bytes(handle: u64, action: u32, input: &str) -> Result<Vec<u8>, String> {
    let mut registry = cores().lock().map_err(|_| "registry lock")?;
    let runtime = registry.get_mut(&handle).ok_or("missing handle")?;
    let mut output = Vec::new();
    match action {
        2 => runtime.bridge.view(&mut output),
        _ => runtime.bridge.update(input.as_bytes(), &mut output),
    }
    .map_err(|e| e.to_string())?;
    Ok(output)
}

fn parse(text: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|e| e.to_string())
}

#[test]
fn raw_view_envelope_is_json_equivalent_to_the_value_roundtrip() -> Result<(), String> {
    let handle = install(model(257))?;
    let envelope = call(handle, 2, "")?;
    let raw = bridge_bytes(handle, 2, "")?;
    assert_eq!(envelope.as_bytes(), value_envelope(&raw).as_slice());
    let decoded = parse(&envelope)?;
    assert_eq!(decoded, parse(&legacy_envelope(&raw)?)?);
    assert_eq!(decoded.as_object().map(serde_json::Map::len), Some(1));
    assert!(
        decoded["value"].is_object(),
        "library view must stay an object"
    );
    // The synthetic catalog reaches the serialized view (escapes and non-ASCII included).
    assert!(envelope.contains(r#"IMG_000256.HEIC \"quoted\" 日本"#));
    suwop_drop(handle);
    Ok(())
}

#[test]
fn raw_view_keeps_exact_floats_that_the_value_roundtrip_perturbed() -> Result<(), String> {
    // serde_json's default (non float_roundtrip) parser is not correctly rounded, so the
    // former parse/re-serialize moved some coordinates by one ULP before Swift saw them.
    let handle = install(model(18))?;
    let raw = bridge_bytes(handle, 2, "")?;
    let exact = "138.99975714285713";
    assert_eq!(
        asset(17).longitude.map(|v| v.to_string()).as_deref(),
        Some(exact)
    );
    assert!(call(handle, 2, "")?.contains(exact));
    assert!(
        std::str::from_utf8(&raw)
            .map_err(|e| e.to_string())?
            .contains(exact)
    );
    suwop_drop(handle);
    Ok(())
}

#[test]
fn authority_projections_keep_contract_and_reset_the_query() -> Result<(), String> {
    let handle = install(model(3))?;
    let keys = json!([
        {"provider":"apple","scope":"apple","assetID":"photo-000001"},
        {"provider":"apple","scope":"apple","assetID":"missing"}
    ]);
    let ordinary = parse(&call(handle, 16, &keys.to_string())?)?;
    let progress = parse(&call(handle, 17, "")?)?;
    let query_cleared = cores()
        .lock()
        .map_err(|_| "registry lock")?
        .get(&handle)
        .ok_or("missing handle")?
        .query
        .lock()
        .map_err(|_| "query lock")?
        .is_none();
    assert!(query_cleared, "selection must not leak into the next view");
    assert!(ordinary["value"]["revision"].is_string());
    assert!(ordinary["value"]["keys"].is_array());
    assert_eq!(progress["value"]["version"], "0:0:0:0:0:0");
    assert!(progress["value"]["progress"].is_null());
    // After the selections, the default view is the library again.
    assert!(
        parse(&call(handle, 2, "")?)?["value"]
            .get("version")
            .is_none()
    );
    suwop_drop(handle);
    Ok(())
}

#[test]
fn errors_and_utilities_keep_their_exact_envelopes() -> Result<(), String> {
    let handle = install(model(1))?;
    assert_eq!(
        call(u64::MAX, 2, "")?,
        r#"{"error":"Invalid core handle","inputRejected":false}"#
    );
    assert_eq!(
        call(handle, 99, "")?,
        r#"{"error":"Unknown bridge action","inputRejected":false}"#
    );
    assert_eq!(
        call(u64::MAX, 99, "")?,
        r#"{"error":"Invalid core handle","inputRejected":false}"#
    );
    let rejected = parse(&call(handle, 16, "not json")?)?;
    assert_eq!(rejected["inputRejected"], false);
    assert!(rejected["error"].is_string());
    let oversized = "x".repeat(16 * 1024 * 1024 + 1);
    assert_eq!(
        parse(&call(handle, 2, &oversized)?)?,
        json!({"inputRejected": true, "error": input_limits::ERROR})
    );
    let same = json!({"first":"https://a.example/x","second":"https://a.example/y"});
    assert_eq!(call(0, 6, &same.to_string())?, r#"{"value":true}"#);
    assert_eq!(
        call(0, 11, r#"{"width":4,"height":3}"#)?,
        r#"{"value":null}"#
    );
    suwop_drop(handle);
    Ok(())
}

#[test]
fn update_effects_still_record_bulk_replies() -> Result<(), String> {
    let handle = install(Model::default())?;
    let effects = parse(&call(
        handle,
        0,
        r#"{"type":"initialize","scope":"apple"}"#,
    )?)?;
    let issued = |kind: &str| {
        effects["value"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|effect| effect["effect"]["Io"]["type"] == kind)
    };
    let recorded = cores()
        .lock()
        .map_err(|_| "registry lock")?
        .get(&handle)
        .ok_or("missing handle")?
        .bulk_replies
        .clone();
    assert!(
        issued("readState"),
        "initialize must issue the bulk state read"
    );
    assert!(!recorded.is_empty(), "bulk reply ids must be remembered");
    let mut expected = BTreeSet::new();
    input_limits::remember_replies(&mut expected, &effects["value"]);
    assert_eq!(recorded, expected);
    suwop_drop(handle);
    Ok(())
}

/// Deterministic synthetic comparison; run with
/// Set `SUWOP_BENCH_REPORT` to an absolute JSON output path, then run
/// `cargo test -p suwop-ffi --release snapshot_serialization -- --ignored`.
#[test]
#[ignore = "microbenchmark"]
fn snapshot_serialization_benchmark() -> Result<(), String> {
    let count = std::env::var("SUWOP_BENCH_ASSETS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(88_000);
    let handle = install(model(count))?;
    let best = |f: &mut dyn FnMut() -> Result<usize, String>| -> Result<(Duration, usize), String> {
        let mut best = Duration::MAX;
        let mut bytes = 0;
        for _ in 0..5 {
            let start = Instant::now();
            bytes = f()?;
            best = best.min(start.elapsed());
        }
        Ok((best, bytes))
    };
    let (view, view_bytes) = best(&mut || Ok(bridge_bytes(handle, 2, "")?.len()))?;
    let (legacy, legacy_bytes) =
        best(&mut || Ok(legacy_envelope(&bridge_bytes(handle, 2, "")?)?.len()))?;
    let (raw, raw_bytes) = best(&mut || Ok(call(handle, 2, "")?.len()))?;
    let report = json!({
        "assets": count, "repetitions": 5, "statistic": "minimum",
        "view_bytes": view_bytes, "legacy_bytes": legacy_bytes, "raw_bytes": raw_bytes,
        "view_seconds": view.as_secs_f64(), "legacy_seconds": legacy.as_secs_f64(),
        "raw_seconds": raw.as_secs_f64(),
        "scope": "Same current core: legacy JSON envelope roundtrip versus direct envelope. Not whole sync."
    });
    let path = std::env::var_os("SUWOP_BENCH_REPORT").map_or_else(
        || {
            std::env::temp_dir().join(format!(
                "suwop-snapshot-benchmark-{}.json",
                std::process::id()
            ))
        },
        std::path::PathBuf::from,
    );
    std::fs::write(
        path,
        serde_json::to_vec_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    suwop_drop(handle);
    Ok(())
}

#[test]
fn mixed_provider_snapshot_preserves_denial_projection_and_nested_metadata() -> Result<(), String> {
    let mut state = model(3);
    let mut remote = state.state.snapshots[0].clone();
    remote.provider = Provider::Immich;
    remote.scope = "remote".into();
    for asset in &mut remote.assets {
        asset.key.provider = Provider::Immich;
        asset.key.scope = "remote".into();
        asset.immich_visibility = Some(suwop_core::immich_visibility::ImmichVisibility::Timeline);
    }
    state.protection.denied.insert(remote.assets[0].key.clone());
    state
        .state
        .protected_entries
        .push(suwop_core::protection::PersistentProtectedEntry {
            id: "persisted-denial".into(),
            key: remote.assets[1].key.clone(),
        });
    state.state.snapshots.push(remote);
    let handle = install(state)?;
    let raw = bridge_bytes(handle, 2, "")?;
    let current = parse(&call(handle, 2, "")?)?;
    assert_eq!(current, parse(&legacy_envelope(&raw)?)?);
    let assets = current["value"]["state"]["snapshots"][1]["assets"]
        .as_array()
        .ok_or("remote assets")?;
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0]["key"]["assetID"], "photo-000002");
    assert!(current["value"]["previewChoices"].is_object());
    assert!(current["value"]["metadataTargets"].is_object());
    suwop_drop(handle);
    Ok(())
}
