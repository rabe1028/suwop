//! A small JSON C ABI, isolated from the safe, effect-driven domain crate.
//! Handles are registry IDs, never native pointers. Calls are serialized by a mutex.
#![allow(unsafe_code)]

use crux_core::{
    Core,
    bridge::{Bridge, JsonFfiFormat},
};
use serde_json::{Value, json};
use sha1::Digest;
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString, c_char},
    io::Read,
    sync::{Mutex, OnceLock},
};
use suwop_core::{
    app::Suwop,
    domain::{AppleFacts, FileSignature, StoredAsset, describe_apple, hex},
    workflow::HashResult,
};

type Runtime = Bridge<Suwop, JsonFfiFormat>;
static CORES: OnceLock<Mutex<BTreeMap<u64, Runtime>>> = OnceLock::new();
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
fn cores() -> &'static Mutex<BTreeMap<u64, Runtime>> {
    CORES.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[unsafe(no_mangle)]
pub extern "C" fn suwop_new() -> u64 {
    let Ok(mut registry) = cores().lock() else {
        return 0;
    };
    let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    registry.insert(id, Bridge::new(Core::new()));
    id
}
#[unsafe(no_mangle)]
pub extern "C" fn suwop_drop(handle: u64) {
    if let Ok(mut registry) = cores().lock() {
        registry.remove(&handle);
    }
}

/// # Safety
/// `input` is null or a valid, NUL-terminated UTF-8 C string for the duration of the call.
/// The returned allocation belongs to the caller and must be freed once with `suwop_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn suwop_call(handle: u64, action: u32, input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let text = if input.is_null() {
            ""
        } else {
            // SAFETY: the C ABI caller supplies the valid string specified above.
            unsafe { CStr::from_ptr(input) }
                .to_str()
                .map_err(|_| "Invalid UTF-8".to_owned())?
        };
        if text.len() > 16 * 1024 * 1024 {
            return Err("Bridge input exceeds 16 MiB".into());
        }
        execute(handle, action, text)
    });
    let envelope = match result {
        Ok(Ok(value)) => json!({"value":value}),
        Ok(Err(error)) => json!({"error":error}),
        Err(_) => {
            json!({"error":"Rust bridge failed. No operation will be retried automatically."})
        }
    };
    CString::new(envelope.to_string()).map_or(std::ptr::null_mut(), CString::into_raw)
}
/// # Safety
/// `value` is null or a live allocation returned by `suwop_call`; call exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn suwop_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: ownership is returned once by the caller according to the ABI contract.
        drop(unsafe { CString::from_raw(value) });
    }
}
fn execute(handle: u64, action: u32, input: &str) -> Result<Value, String> {
    match action {
        3 => {
            let facts: AppleFacts = serde_json::from_str(input).map_err(|e| e.to_string())?;
            return serde_json::to_value(describe_apple(facts)).map_err(|e| e.to_string());
        }
        4 => {
            let path: String = serde_json::from_str(input).map_err(|e| e.to_string())?;
            return serde_json::to_value(hash_file(&path)?).map_err(|e| e.to_string());
        }
        5 => {
            #[derive(serde::Deserialize)]
            struct Check {
                saved: Vec<StoredAsset>,
                fresh: Vec<StoredAsset>,
            }
            let check: Check = serde_json::from_str(input).map_err(|e| e.to_string())?;
            suwop_core::domain::allow_deletion(&check.fresh)?;
            let revisions = |a: &[StoredAsset]| {
                a.iter()
                    .map(|a| (a.key.clone(), a.revision.clone()))
                    .collect::<BTreeMap<_, _>>()
            };
            if revisions(&check.saved) != revisions(&check.fresh) {
                return Err("削除直前に写真の状態が変わりました。元データは残します。".into());
            }
            return Ok(Value::Null);
        }
        6 => {
            #[derive(serde::Deserialize)]
            struct Origins {
                first: String,
                second: String,
            }
            let urls: Origins = serde_json::from_str(input).map_err(|e| e.to_string())?;
            return Ok(Value::Bool(suwop_core::immich::same_origin(
                &urls.first,
                &urls.second,
            )));
        }
        7 => {
            #[derive(serde::Deserialize)]
            struct Thumbnail {
                address: String,
                key: String,
                #[serde(rename = "assetID")]
                asset_id: String,
            }
            let request: Thumbnail = serde_json::from_str(input).map_err(|e| e.to_string())?;
            suwop_core::immich::valid_id(&request.asset_id)?;
            let session = suwop_core::immich::Session {
                endpoint: request.address,
                key: request.key,
                user_id: String::new(),
                scope: String::new(),
                version: suwop_core::immich::Version {
                    major: 3,
                    minor: 2,
                    patch: 4,
                },
            };
            return serde_json::to_value(session.request(
                &format!("assets/{}/thumbnail?size=thumbnail", request.asset_id),
                "GET",
                None,
            ))
            .map_err(|e| e.to_string());
        }
        _ => {}
    }
    let registry = cores()
        .lock()
        .map_err(|_| "Rust bridge lock failed".to_owned())?;
    let bridge = registry.get(&handle).ok_or("Invalid core handle")?;
    let mut output = Vec::new();
    match action {
        0 => bridge
            .update(input.as_bytes(), &mut output)
            .map_err(|e| e.to_string())?,
        1 => {
            #[derive(serde::Deserialize)]
            struct Response {
                id: u32,
                response: Value,
            }
            let response: Response = serde_json::from_str(input).map_err(|e| e.to_string())?;
            bridge
                .resolve(
                    crux_core::bridge::EffectId(response.id),
                    &serde_json::to_vec(&response.response).map_err(|e| e.to_string())?,
                    &mut output,
                )
                .map_err(|e| e.to_string())?;
        }
        2 => bridge.view(&mut output).map_err(|e| e.to_string())?,
        _ => return Err("Unknown bridge action".into()),
    }
    serde_json::from_slice(&output).map_err(|e| e.to_string())
}
fn hash_file(path: &str) -> Result<HashResult, String> {
    let mut file = std::fs::File::open(path).map_err(|_| "原本を読み出せません。".to_owned())?;
    let mut sha1 = sha1::Sha1::new();
    let mut sha256 = sha2::Sha256::new();
    let mut count = 0;
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|_| "原本を読み出せません。".to_owned())?;
        if n == 0 {
            break;
        }
        sha1.update(&buffer[..n]);
        sha256.update(&buffer[..n]);
        count += n as u64;
    }
    Ok(HashResult {
        sha1: hex(&sha1.finalize()),
        signature: FileSignature {
            sha256: hex(&sha256.finalize()),
            bytes: count,
        },
    })
}
