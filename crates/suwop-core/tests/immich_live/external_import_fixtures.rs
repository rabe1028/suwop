//! Entirely generated pixels and a checked-in synthetic Live pair. No camera
//! originals or personal media are fixtures. DNG is uncompressed linear RGB16.
use super::*;

pub(super) fn items(root: &Path) -> Result<Vec<ImportItem>, String> {
    let single = png("PP03 single")?;
    let raw_still = png("PP03 raw companion")?;
    let raw = dng()?;
    let (mut still, mut motion) = super::super::live_graph::native_pair_bytes()?;
    let old = b"B18D9CC0-335C-4B73-880D-627A3A78D9C3";
    let new = b"D337C6E8-9042-42E7-B8D6-7A0DF16EFA73";
    replace(&mut still, old, new)?;
    replace(&mut motion, old, new)?;
    let cid = String::from_utf8(new.to_vec()).map_err(|e| e.to_string())?;
    let entries = [
        (
            "single",
            vec![("single.png", single, ResourceRole::Image, "image/png", None)],
        ),
        (
            "raw-pair",
            vec![
                (
                    "raw-companion.png",
                    raw_still,
                    ResourceRole::Image,
                    "image/png",
                    None,
                ),
                (
                    "synthetic.dng",
                    raw,
                    ResourceRole::RawImage,
                    "image/raw",
                    None,
                ),
            ],
        ),
        (
            "live-pair",
            vec![
                (
                    "synthetic-still.jpg",
                    still,
                    ResourceRole::Image,
                    "image/jpeg",
                    Some(cid.clone()),
                ),
                (
                    "synthetic-motion.mov",
                    motion,
                    ResourceRole::LiveVideo,
                    "video/quicktime",
                    Some(cid),
                ),
            ],
        ),
    ];
    let mut items = vec![];
    for (id, files) in entries {
        let mut resources = vec![];
        for (index, (name, bytes, role, media_type, content_identifier)) in
            files.into_iter().enumerate()
        {
            let token = format!("{id}-{index}");
            std::fs::write(root.join(&token), &bytes).map_err(|e| e.to_string())?;
            resources.push(StagedResource {
                token,
                name: name.into(),
                role,
                media_type: media_type.into(),
                sha256: format!("{:x}", Sha256::digest(&bytes)),
                bytes: bytes.len() as u64,
                content_identifier,
            });
        }
        items.push(ImportItem {
            id: id.into(),
            resources,
            metadata: ImportMetadata::default(),
        });
    }
    Ok(items)
}
pub(super) fn lost_item(root: &Path) -> Result<ImportItem, String> {
    let bytes = png("PP03 lost response unique generated fixture")?;
    let token = "lost-response";
    std::fs::write(root.join(token), &bytes).map_err(|e| e.to_string())?;
    Ok(ImportItem {
        id: token.into(),
        resources: vec![StagedResource {
            token: token.into(),
            name: "lost-response.png".into(),
            role: ResourceRole::Image,
            media_type: "image/png".into(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
            bytes: bytes.len() as u64,
            content_identifier: None,
        }],
        metadata: ImportMetadata::default(),
    })
}

fn replace(bytes: &mut [u8], old: &[u8], new: &[u8]) -> Result<(), String> {
    let positions: Vec<_> = bytes
        .windows(old.len())
        .enumerate()
        .filter_map(|(index, part)| (part == old).then_some(index))
        .collect();
    if positions.is_empty() {
        return Err("synthetic Live identifier not found".into());
    }
    for index in positions {
        bytes[index..index + old.len()].copy_from_slice(new);
    }
    Ok(())
}
fn png(label: &str) -> Result<Vec<u8>, String> {
    let mut bytes = base64::engine::general_purpose::STANDARD
        .decode(super::super::PIXELS[0])
        .map_err(|e| e.to_string())?;
    let mut chunk = b"tEXtComment\0".to_vec();
    chunk.extend_from_slice(label.as_bytes());
    let mut encoded = u32::try_from(chunk.len() - 4)
        .map_err(|e| e.to_string())?
        .to_be_bytes()
        .to_vec();
    encoded.extend_from_slice(&chunk);
    let mut crc = u32::MAX;
    for byte in chunk {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & (0u32.wrapping_sub(crc & 1)));
        }
    }
    encoded.extend_from_slice(&(!crc).to_be_bytes());
    let offset = bytes.len() - 12;
    bytes.splice(offset..offset, encoded);
    Ok(bytes)
}

// Keep these entirely generated sensor pixels byte-identical to the native
// NativeImportRawFixture, whose ImageIO/Core Image decoding is acceptance-tested.
fn dng() -> Result<Vec<u8>, String> {
    let mut tags = dng_tags();
    // Encode variable-sized values after the IFD, then one contiguous strip.
    let extra_start = 8 + 2 + 12 * tags.len() + 4;
    let pixel_start = extra_start
        + tags
            .iter()
            .filter(|tag| tag.3.len() > 4)
            .map(|tag| (tag.3.len() + 1) & !1)
            .sum::<usize>();
    for tag in &mut tags {
        if tag.0 == 273 {
            tag.3 = u32::try_from(pixel_start)
                .map_err(|e| e.to_string())?
                .to_le_bytes()
                .to_vec();
        }
        if tag.1 == 2 {
            tag.2 = u32::try_from(tag.3.len()).map_err(|e| e.to_string())?;
        }
    }
    let mut bytes = b"II\x2a\x00\x08\x00\x00\x00".to_vec();
    bytes.extend_from_slice(
        &u16::try_from(tags.len())
            .map_err(|e| e.to_string())?
            .to_le_bytes(),
    );
    let mut extra = vec![];
    for (id, kind, count, data) in tags {
        bytes.extend_from_slice(&id.to_le_bytes());
        bytes.extend_from_slice(&kind.to_le_bytes());
        bytes.extend_from_slice(&count.to_le_bytes());
        if data.len() <= 4 {
            bytes.extend_from_slice(&data);
            bytes.resize(bytes.len() + 4 - data.len(), 0);
        } else {
            bytes.extend_from_slice(
                &u32::try_from(extra_start + extra.len())
                    .map_err(|e| e.to_string())?
                    .to_le_bytes(),
            );
            extra.extend_from_slice(&data);
            if extra.len() % 2 != 0 {
                extra.push(0);
            }
        }
    }
    bytes.extend_from_slice(&0u32.to_le_bytes());
    bytes.extend(extra);
    for pixel in 0usize..(256 * 256) {
        let gradient = u16::try_from(pixel % 256).map_err(|e| e.to_string())? * 128;
        for channel in [gradient, 20000, 30000] {
            bytes.extend_from_slice(&channel.to_le_bytes());
        }
    }
    Ok(bytes)
}

fn dng_tags() -> Vec<(u16, u16, u32, Vec<u8>)> {
    fn short(value: u16) -> Vec<u8> {
        value.to_le_bytes().to_vec()
    }
    fn long(value: u32) -> Vec<u8> {
        value.to_le_bytes().to_vec()
    }
    let mut matrix = vec![];
    for index in 0..9 {
        matrix.extend_from_slice(&(if index % 4 == 0 { 100i32 } else { 0i32 }).to_le_bytes());
        matrix.extend_from_slice(&100i32.to_le_bytes());
    }
    let mut neutral = vec![];
    for _ in 0..3 {
        neutral.extend_from_slice(&1u32.to_le_bytes());
        neutral.extend_from_slice(&1u32.to_le_bytes());
    }
    vec![
        (254, 4, 1, long(0)),
        (256, 4, 1, long(256)),
        (257, 4, 1, long(256)),
        (
            258,
            3,
            3,
            [16u16, 16, 16]
                .into_iter()
                .flat_map(u16::to_le_bytes)
                .collect(),
        ),
        (259, 3, 1, short(1)),
        (262, 3, 1, short(34892)),
        (271, 2, 6, b"Suwop\0".to_vec()),
        (272, 2, 10, b"Synthetic\0".to_vec()),
        (273, 4, 1, long(0)),
        (274, 3, 1, short(1)),
        (277, 3, 1, short(3)),
        (278, 4, 1, long(256)),
        (279, 4, 1, long(393_216)),
        (284, 3, 1, short(1)),
        (50706, 1, 4, vec![1, 4, 0, 0]),
        (50707, 1, 4, vec![1, 1, 0, 0]),
        (50708, 2, 27, b"Suwop Synthetic Linear Raw\0".to_vec()),
        (50710, 1, 3, vec![0, 1, 2]),
        (
            50713,
            3,
            2,
            [1u16, 1].into_iter().flat_map(u16::to_le_bytes).collect(),
        ),
        (50714, 3, 1, short(0)),
        (50717, 4, 1, long(65535)),
        (
            50718,
            5,
            2,
            [1u32, 1, 1, 1]
                .into_iter()
                .flat_map(u32::to_le_bytes)
                .collect(),
        ),
        (
            50719,
            4,
            2,
            [0u32, 0].into_iter().flat_map(u32::to_le_bytes).collect(),
        ),
        (
            50720,
            4,
            2,
            [256u32, 256]
                .into_iter()
                .flat_map(u32::to_le_bytes)
                .collect(),
        ),
        (50721, 10, 9, matrix),
        (50728, 5, 3, neutral),
        (50778, 3, 1, short(21)),
    ]
}
