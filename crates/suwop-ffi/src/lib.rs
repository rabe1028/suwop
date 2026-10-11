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
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};
use suwop_core::{
    app::Suwop,
    domain::{AppleFacts, FileSignature, StoredAsset, describe_apple, hex},
    workflow::HashResult,
};

type Runtime = Bridge<Suwop, JsonFfiFormat>;
static CORES: OnceLock<Mutex<BTreeMap<u64, Runtime>>> = OnceLock::new();
static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
type Cancellations = BTreeMap<u64, Arc<AtomicBool>>;
static CANCELLATIONS: OnceLock<Mutex<Cancellations>> = OnceLock::new();
fn cancellations() -> &'static Mutex<Cancellations> {
    CANCELLATIONS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[unsafe(no_mangle)]
pub extern "C" fn suwop_hash_new() -> u64 {
    let Ok(mut registry) = cancellations().lock() else {
        return 0;
    };
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    registry.insert(id, Arc::new(AtomicBool::new(false)));
    id
}
#[unsafe(no_mangle)]
pub extern "C" fn suwop_hash_cancel(handle: u64) {
    if let Ok(registry) = cancellations().lock()
        && let Some(flag) = registry.get(&handle)
    {
        flag.store(true, Ordering::Release);
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn suwop_hash_drop(handle: u64) {
    if let Ok(mut registry) = cancellations().lock() {
        registry.remove(&handle);
    }
}
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
            return hash_input(input);
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
        7 => return thumbnail_request(input),
        8 => {
            let request: suwop_core::editing::EditDraftRequest =
                serde_json::from_str(input).map_err(|e| e.to_string())?;
            let draft = match request.command {
                Some(command) => request.draft.apply(command)?,
                None => request.draft,
            };
            return serde_json::to_value(draft.view()?).map_err(|e| e.to_string());
        }
        9 => {
            let payload: suwop_core::editing::AppleAdjustment =
                serde_json::from_str(input).map_err(|e| e.to_string())?;
            return Ok(Value::Bool(
                suwop_core::editing::decode_original_adjustment(&payload).is_some(),
            ));
        }
        10 => {
            let request: suwop_core::editing::EditingSourceCheck =
                serde_json::from_str(input).map_err(|e| e.to_string())?;
            suwop_core::editing::verify_edit_source(&request.expected, &request.fresh)?;
            return Ok(Value::Null);
        }
        11 => {
            let dimensions: suwop_core::editing::PixelSize =
                serde_json::from_str(input).map_err(|e| e.to_string())?;
            dimensions.validate()?;
            return Ok(Value::Null);
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
fn thumbnail_request(input: &str) -> Result<Value, String> {
    #[derive(serde::Deserialize)]
    struct Thumbnail {
        address: String,
        key: String,
        #[serde(rename = "assetID")]
        asset_id: String,
        #[serde(default)]
        preview: bool,
        #[serde(default)]
        version: Option<suwop_core::immich::Version>,
    }
    let request: Thumbnail = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let session = suwop_core::immich::Session {
        endpoint: request.address,
        key: request.key,
        user_id: String::new(),
        scope: String::new(),
        version: request.version.unwrap_or(suwop_core::immich::Version {
            major: 2,
            minor: 0,
            patch: 0,
        }),
    };
    serde_json::to_value(session.preview_request(&request.asset_id, request.preview)?)
        .map_err(|e| e.to_string())
}
fn hash_input(input: &str) -> Result<Value, String> {
    #[derive(serde::Deserialize)]
    struct Input {
        path: String,
        cancellation: String,
    }
    let input: Input = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let id = input
        .cancellation
        .parse::<u64>()
        .map_err(|e| e.to_string())?;
    let flag = cancellations()
        .lock()
        .map_err(|_| "Cancellation lock failed")?
        .get(&id)
        .cloned()
        .ok_or("Invalid cancellation handle")?;
    check_cancelled(&flag)?;
    let file = std::fs::File::open(input.path).map_err(|_| "原本を読み出せません。".to_owned())?;
    serde_json::to_value(hash_reader(file, &flag)?).map_err(|e| e.to_string())
}
fn check_cancelled(flag: &AtomicBool) -> Result<(), String> {
    if flag.load(Ordering::Acquire) {
        Err("cancelled".into())
    } else {
        Ok(())
    }
}
fn hash_reader(mut file: impl Read, flag: &AtomicBool) -> Result<HashResult, String> {
    let mut sha1 = sha1::Sha1::new();
    let mut sha256 = sha2::Sha256::new();
    let mut count = 0;
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        check_cancelled(flag)?;
        let n = file
            .read(&mut buffer)
            .map_err(|_| "原本を読み出せません。".to_owned())?;
        check_cancelled(flag)?;
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

#[cfg(test)]
mod tests {
    use super::{AtomicBool, Ordering, check_cancelled, hash_reader};
    use std::io::{self, Read};

    #[test]
    fn stream_hashes_have_the_expected_signatures() -> Result<(), String> {
        let result = hash_reader(io::Cursor::new(b"abc"), &AtomicBool::new(false))?;
        assert_eq!(result.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            result.signature.sha256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(result.signature.bytes, 3);
        Ok(())
    }

    #[test]
    fn cancellation_stops_streaming_before_the_next_read() {
        struct Reader<'a> {
            flag: &'a AtomicBool,
            reads: usize,
        }
        impl Read for Reader<'_> {
            fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
                self.reads += 1;
                bytes[0] = b'x';
                self.flag.store(true, Ordering::Release);
                Ok(1)
            }
        }
        let flag = AtomicBool::new(false);
        let mut reader = Reader {
            flag: &flag,
            reads: 0,
        };
        assert_eq!(
            hash_reader(&mut reader, &flag).err().as_deref(),
            Some("cancelled")
        );
        assert_eq!(reader.reads, 1);
        assert!(check_cancelled(&flag).is_err());
    }
}
