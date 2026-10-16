//! Test-harness stream accounting only; no native storage/protocol acceptance claim.
use super::*;
use suwop_core::immich_locked::video::ImmichLockedVideoTicket;
fn ticket(expected: Option<u64>, maximum: u64) -> Result<ImmichLockedVideoTicket, String> {
    serde_json::from_value(json!({
        "pending":{"requestID":id(90),"entryID":"video","grantID":id(91),"sceneID":SCENE,"generation":1,"key":{"provider":"immich","scope":"http://fixture.invalid/api#owner","assetID":id(92)},"phase":"acquiring"},
        "initialAcquisitionLease":{"leaseID":1,"deadlineUnixMilliseconds":u64::MAX,"remainingMilliseconds":30_000,"extensionMilliseconds":0},"acquisitionLease":{"leaseID":1,"deadlineUnixMilliseconds":u64::MAX,"remainingMilliseconds":30_000,"extensionMilliseconds":0},"displayLeaseID":1,"deadlineUnixMilliseconds":transport::now_ms()?.checked_add(30_000).ok_or("test deadline")?,"expectedRevision":"revision","expectedSha1":format!("{:x}",sha1::Sha1::digest(V)),"expectedBytes":expected,
        "storage":{"leaseID":id(90),"measurementNonce":id(93),"deadlineUnixMilliseconds":transport::now_ms()?.checked_add(30_000).ok_or("test storage deadline")?,"availableBytes":2_147_483_648_u64,"otherUnallocatedBytes":0,"allocationUnitBytes":4096,"capacityClass":"importantUsage"},
        "maxReceivedBytes":maximum,"minimumRemainingBytes":268_435_456,"request":{"url":"http://fixture.invalid/api/original","method":"GET","headers":{},"body":null,"fields":{},"files":[],"downloadPath":null}
    })).map_err(|error| format!("test video ticket: {error}"))
}
#[test]
fn harness_known_and_absent_size_streams_hash_complete_original() -> Result<(), String> {
    let root =
        std::env::temp_dir().join(format!("suwop-video-known-absent-{}", std::process::id()));
    std::fs::create_dir(&root).map_err(|_| "video stream test root")?;
    let length = u64::try_from(V.len()).map_err(|_| "video fixture length")?;
    for (label, expected, maximum, header) in [
        ("known", Some(length), length, None),
        ("absent", None, 1_879_048_192, None),
        ("header", None, 1_879_048_192, Some(length)),
    ] {
        let result =
            transport::stream_to_file(V, &ticket(expected, maximum)?, &root.join(label), header)?;
        assert_eq!(result.signature.bytes, length);
        assert_eq!(result.sha1, format!("{:x}", sha1::Sha1::digest(V)));
        assert_eq!(
            result.signature.sha256,
            format!("{:x}", sha2::Sha256::digest(V))
        );
        assert_eq!(
            std::fs::read(root.join(label)).map_err(|_| "stream test bytes")?,
            V
        );
    }
    std::fs::remove_dir_all(root).map_err(|_| "video stream test cleanup".into())
}
#[test]
fn harness_header_and_budget_stop_before_excess_chunk_write() -> Result<(), String> {
    let root =
        std::env::temp_dir().join(format!("suwop-video-stream-bounds-{}", std::process::id()));
    std::fs::create_dir(&root).map_err(|_| "video bounds test root")?;
    let limit = u64::try_from(V.len())
        .map_err(|_| "video fixture length")?
        .checked_sub(1)
        .ok_or("nonempty video")?;
    for (label, maximum, header) in [
        ("header", limit + 4096, Some(limit)),
        ("budget", limit, None),
    ] {
        let path = root.join(label);
        assert!(transport::stream_to_file(V, &ticket(None, maximum)?, &path, header).is_err());
        assert!(
            std::fs::metadata(path)
                .map_err(|_| "stream bounds file")?
                .len()
                <= limit
        );
    }
    std::fs::remove_dir_all(root).map_err(|_| "video bounds cleanup".into())
}
