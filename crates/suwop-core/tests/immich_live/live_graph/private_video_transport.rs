//! Actual bounded file transport; not the Swift adapter or `AVPlayer` acceptance.
use super::*;
use std::io::{Read, Write};
use suwop_core::immich_locked::video::{ImmichLockedVideoResult, ImmichLockedVideoTicket};
pub(super) fn download(
    agent: &ureq::Agent,
    ticket: &ImmichLockedVideoTicket,
    path: &Path,
) -> Result<ImmichLockedVideoResult, String> {
    let spec = &ticket.request;
    assert_eq!(spec.method, "GET");
    assert!(spec.files.is_empty() && spec.download_path.is_none());
    assert!(
        spec.headers
            .iter()
            .any(|(k, v)| k.eq_ignore_ascii_case("Accept-Encoding") && v == "identity")
    );
    let mut builder = ureq::http::Request::builder().method("GET").uri(&spec.url);
    for (name, value) in &spec.headers {
        builder = builder.header(name, value);
    }
    let request = builder
        .body(Vec::<u8>::new())
        .map_err(|_| "video original request")?;
    let mut response = agent.run(request).map_err(|_| "video original transport")?;
    assert_eq!(response.status().as_u16(), 200);
    if let Some(encoding) = response.headers().get("Content-Encoding") {
        assert_eq!(encoding.to_str().map_err(|_| "video encoding")?, "identity");
    }
    let length = response
        .headers()
        .get("Content-Length")
        .map(|v| {
            v.to_str()
                .map_err(|_| "video length header")
                .and_then(|v| v.parse::<u64>().map_err(|_| "video length integer"))
        })
        .transpose()?;
    if let Some(length) = length {
        assert!(length > 0 && length <= ticket.max_received_bytes);
        if let Some(expected) = ticket.expected_bytes {
            assert_eq!(length, expected);
        }
    }
    let partial = path.with_extension("partial");
    let result = stream_to_file(response.body_mut().as_reader(), ticket, &partial, length);
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    let measured = result?;
    std::fs::rename(&partial, path).map_err(|_| "video same-directory rename")?;
    Ok(measured)
}
pub(super) fn stream_to_file(
    mut reader: impl Read,
    ticket: &ImmichLockedVideoTicket,
    path: &Path,
    length: Option<u64>,
) -> Result<ImmichLockedVideoResult, String> {
    let mut output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(|_| "video partial file")?;
    let mut sha1 = sha1::Sha1::new();
    let mut sha256 = sha2::Sha256::new();
    let mut count = 0_u64;
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let read = reader.read(&mut buffer).map_err(|_| "video body read")?;
        if read == 0 {
            break;
        }
        count = count
            .checked_add(u64::try_from(read).map_err(|_| "video chunk length")?)
            .ok_or("video byte overflow")?;
        if count > ticket.max_received_bytes
            || length.is_some_and(|declared| count > declared)
            || now_ms()? >= ticket.deadline_unix_milliseconds
        {
            return Err("video authorized budget/deadline exceeded".into());
        }
        output
            .write_all(&buffer[..read])
            .map_err(|_| "video stage write")?;
        sha1.update(&buffer[..read]);
        sha256.update(&buffer[..read]);
    }
    output.sync_all().map_err(|_| "video stage flush")?;
    assert!(count > 0);
    if let Some(expected) = ticket.expected_bytes {
        assert_eq!(count, expected);
    }
    if let Some(length) = length {
        assert_eq!(count, length);
    }
    let digest = format!("{:x}", sha1.finalize());
    assert_eq!(digest, ticket.expected_sha1);
    Ok(ImmichLockedVideoResult {
        request_id: ticket.pending.request_id.clone(),
        staged_id: ticket.storage.lease_id.clone(),
        sha1: digest,
        signature: FileSignature {
            sha256: format!("{:x}", sha256.finalize()),
            bytes: count,
        },
    })
}
pub(super) fn now_ms() -> Result<u64, String> {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "video fixture clock")?
            .as_millis(),
    )
    .map_err(|_| "video clock overflow".into())
}
