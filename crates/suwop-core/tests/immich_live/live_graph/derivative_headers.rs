//! Fixture-only encoded dimensions, not full pixel decoding/native rendering proof.
//! Immich's configured thumbnail can be WebP while preview is JPEG.
pub(super) fn dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if let Some((width, height)) = crate::jpeg_dimensions(bytes) {
        return Some((u32::from(width), u32::from(height)));
    }
    webp_dimensions(bytes)
}
fn webp_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(..4)? != b"RIFF" || bytes.get(8..12)? != b"WEBP" {
        return None;
    }
    let declared = usize::try_from(u32::from_le_bytes(bytes.get(4..8)?.try_into().ok()?)).ok()?;
    if declared.checked_add(8)? != bytes.len() {
        return None;
    }
    let mut cursor = 12_usize;
    let mut canvas = None;
    let mut frame = None;
    while cursor < bytes.len() {
        let header_end = cursor.checked_add(8)?;
        let header = bytes.get(cursor..header_end)?;
        let length = usize::try_from(u32::from_le_bytes(header[4..8].try_into().ok()?)).ok()?;
        let end = header_end.checked_add(length)?;
        let chunk = bytes.get(header_end..end)?;
        match &header[..4] {
            b"VP8X" => {
                if canvas.is_some() || frame.is_some() || chunk.len() != 10 || chunk[0] & 0x02 != 0
                {
                    return None;
                }
                canvas = Some((1 + little24(&chunk[4..7]), 1 + little24(&chunk[7..10])));
            }
            b"VP8 " | b"VP8L" => {
                if frame.is_some() {
                    return None;
                }
                frame = Some(frame_dimensions(&header[..4], chunk)?);
            }
            b"ANIM" | b"ANMF" => return None,
            _ => {}
        }
        cursor = end.checked_add(length % 2)?;
        // Odd chunks require their RIFF padding byte as well.
        bytes.get(end..cursor)?;
    }
    let frame = frame?;
    if frame.0 == 0 || frame.1 == 0 || canvas.is_some_and(|size| size != frame) {
        return None;
    }
    Some(frame)
}
fn little24(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}
fn frame_dimensions(kind: &[u8], chunk: &[u8]) -> Option<(u32, u32)> {
    if kind == b"VP8 " {
        // Key-frame signature and dimensions, with at least some encoded payload.
        if chunk.len() <= 10 || chunk[0] & 1 != 0 || chunk.get(3..6)? != [0x9d, 0x01, 0x2a] {
            return None;
        }
        let width = u16::from_le_bytes(chunk.get(6..8)?.try_into().ok()?) & 0x3fff;
        let height = u16::from_le_bytes(chunk.get(8..10)?.try_into().ok()?) & 0x3fff;
        Some((u32::from(width), u32::from(height)))
    } else {
        if chunk.len() <= 5 || chunk[0] != 0x2f {
            return None;
        }
        let packed = u32::from_le_bytes(chunk.get(1..5)?.try_into().ok()?);
        if packed >> 29 != 0 {
            return None;
        }
        Some((1 + (packed & 0x3fff), 1 + ((packed >> 14) & 0x3fff)))
    }
}
#[test]
fn actual_webp_thumbnail_header_and_truncation_bounds() {
    let actual = include_bytes!("../../fixtures/live_graph/derivative-thumbnail.webp");
    assert_eq!(dimensions(actual), Some((64, 64)));
    for length in 0..actual.len() {
        assert_eq!(
            dimensions(&actual[..length]),
            None,
            "truncated length {length}"
        );
    }
    let mut malformed = actual.to_vec();
    malformed[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
    assert_eq!(dimensions(&malformed), None);
    malformed = actual.to_vec();
    malformed[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
    assert_eq!(dimensions(&malformed), None);
    malformed = actual.to_vec();
    malformed[24] = 0; // VP8X canvas width no longer agrees with the coded key frame.
    assert_eq!(dimensions(&malformed), None);
    assert_eq!(dimensions(b"not an image"), None);
}
#[test]
fn webp_frame_headers_require_complete_container_and_matching_canvas() -> Result<(), String> {
    let actual = include_bytes!("../../fixtures/live_graph/derivative-thumbnail.webp");
    let frame_offset = actual
        .windows(4)
        .position(|bytes| bytes == b"VP8 ")
        .ok_or("actual frame")?;
    let mut simple = b"RIFF\0\0\0\0WEBP".to_vec();
    simple.extend_from_slice(&actual[frame_offset..]);
    let length = u32::try_from(simple.len() - 8).map_err(|_| "small fixture")?;
    simple[4..8].copy_from_slice(&length.to_le_bytes());
    assert_eq!(dimensions(&simple), Some((64, 64)));
    let mut metadata_only = actual[..30].to_vec();
    metadata_only[4..8].copy_from_slice(&22_u32.to_le_bytes());
    assert_eq!(dimensions(&metadata_only), None);
    let mut wrong_signature = simple.clone();
    wrong_signature[23] = 0;
    assert_eq!(dimensions(&wrong_signature), None);
    // A lossless frame header declares dimensions; no full pixel decoding is claimed.
    let mut lossless = b"RIFF\x12\0\0\0WEBPVP8L\x06\0\0\0\x2f\x3f\xc0\x0f\0\0".to_vec();
    assert_eq!(dimensions(&lossless), Some((64, 64)));
    lossless[24] = 0xe0; // Invalid VP8L version.
    assert_eq!(dimensions(&lossless), None);
    Ok(())
}
