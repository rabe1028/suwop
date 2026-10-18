//! Bounded actual original transport; never serializes the request or credentials.
use super::*;
use std::io::{Read, Write};
pub(super) fn download(host: &mut Shell<'_>, read: &ImmichLockedLiveRead) -> Result<Value, String> {
    let index = usize::from(read.role == ImmichLockedLiveRole::Motion);
    let member = &read.ticket.members[index];
    let expected = native_pair_bytes()?;
    let bytes = if index == 0 { expected.0 } else { expected.1 };
    assert_eq!(member.role, read.role);
    assert_eq!(member.key.scope, host.fixture.elevated.ordinary.scope);
    assert_eq!(
        member.key.asset_id,
        if index == 0 {
            &host.fixture.parent
        } else {
            &host.fixture.motion
        }
        .as_str()
    );
    let observed = &host.expected[index];
    assert_eq!(observed["type"], if index == 0 { "IMAGE" } else { "VIDEO" });
    assert_eq!(
        observed["updatedAt"].as_str(),
        Some(member.expected_revision.as_str())
    );
    assert_eq!(
        suwop_core::domain::normalize_sha1(observed["checksum"].as_str()).as_deref(),
        Some(member.expected_sha1.as_str())
    );
    let request = &read.request;
    assert_eq!(request.method, "GET");
    assert_eq!(
        request.url,
        format!(
            "{}/assets/{}/original?edited=false",
            host.fixture.elevated.ordinary.endpoint, member.key.asset_id
        )
    );
    assert!(
        request
            .headers
            .get("Authorization")
            .is_some_and(|v| v.starts_with("Bearer "))
    );
    assert!(!request.headers.contains_key("x-api-key"));
    assert!(
        request
            .headers
            .iter()
            .any(|(k, v)| k.eq_ignore_ascii_case("Accept-Encoding") && v == "identity")
    );
    assert!(request.files.is_empty() && request.download_path.is_none());
    let mut builder = ureq::http::Request::builder()
        .method("GET")
        .uri(&request.url);
    for (k, v) in &request.headers {
        builder = builder.header(k, v);
    }
    let mut response = host
        .agent
        .run(
            builder
                .body(Vec::<u8>::new())
                .map_err(|_| "pair HTTP request")?,
        )
        .map_err(|_| "pair original transport")?;
    assert_eq!(response.status().as_u16(), 200);
    if let Some(v) = response.headers().get("Content-Encoding") {
        assert_eq!(v.to_str().map_err(|_| "pair encoding")?, "identity");
    }
    let length = response
        .headers()
        .get("Content-Length")
        .map(|v| {
            v.to_str()
                .map_err(|_| "pair length")
                .and_then(|v| v.parse::<u64>().map_err(|_| "pair length integer"))
        })
        .transpose()?;
    if let Some(n) = length {
        assert!(n > 0 && n <= member.max_received_bytes);
        assert!(
            host.received
                .checked_add(n)
                .is_some_and(|v| v <= read.ticket.total_max_received_bytes)
        );
        if let Some(expected) = member.expected_bytes {
            assert_eq!(n, expected);
        }
    }
    stream(host, read, response.body_mut().as_reader(), length, &bytes)
}
fn stream(
    host: &mut Shell<'_>,
    read: &ImmichLockedLiveRead,
    mut reader: impl Read,
    length: Option<u64>,
    bytes: &[u8],
) -> Result<Value, String> {
    let index = usize::from(read.role == ImmichLockedLiveRole::Motion);
    let member = &read.ticket.members[index];
    let path = host.directory.join(format!("product-original-{index}.bin"));
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)
        .map_err(|_| "pair exclusive stage")?;
    host.stages.push(path.clone());
    let mut sha1 = sha1::Sha1::new();
    let mut sha256 = sha2::Sha256::new();
    let mut count = 0_u64;
    let mut buffer = [0_u8; 16384];
    loop {
        let size = reader.read(&mut buffer).map_err(|_| "pair stream")?;
        if size == 0 {
            break;
        }
        count = count
            .checked_add(u64::try_from(size).map_err(|_| "pair chunk")?)
            .ok_or("pair count overflow")?;
        let total = host
            .received
            .checked_add(count)
            .ok_or("pair aggregate overflow")?;
        if count > member.max_received_bytes
            || total > read.ticket.total_max_received_bytes
            || member.expected_bytes.is_some_and(|v| count > v)
            || length.is_some_and(|v| count > v)
        {
            return Err("pair immutable byte budget exceeded".into());
        }
        file.write_all(&buffer[..size])
            .map_err(|_| "pair stage write")?;
        sha1.update(&buffer[..size]);
        sha256.update(&buffer[..size]);
    }
    file.sync_all().map_err(|_| "pair sync")?;
    assert!(count > 0);
    if let Some(v) = length {
        assert_eq!(count, v);
    }
    if let Some(v) = member.expected_bytes {
        assert_eq!(count, v);
    }
    assert_eq!(
        std::fs::read(&path).map_err(|_| "pair independent bytes")?,
        bytes
    );
    let digest = format!("{:x}", sha1.finalize());
    assert_eq!(digest, member.expected_sha1);
    host.received += count;
    host.roles.push(read.role);
    host.trace
        .push(format!("real original {index}:200:{count}:{digest}"));

    Ok(
        json!({"requestID":read.ticket.pending.request_id,"pairLeaseID":read.ticket.storage.lease_id,"role":read.role,"acquisitionLeaseID":read.ticket.acquisition_lease.lease_id,"sha1":digest,"signature":{"sha256":format!("{:x}",sha256.finalize()),"bytes":count}}),
    )
}
