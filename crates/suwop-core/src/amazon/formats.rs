//! Conservative upload admission. A supported extension is not proof that a
//! particular codec/RAW variant will be accepted; server rejection remains final.
use crate::domain::{PhotoResource, ResourceRole};

#[must_use]
pub fn is_raw(extension: &str) -> bool {
    matches!(
        extension,
        "nef" | "cr2" | "cr3" | "arw" | "crw" | "orf" | "dng" | "erf" | "mrw" | "kdc"
    )
}

pub fn check_resource(resource: &PhotoResource) -> Result<(), String> {
    let name = &resource.name;
    let extension = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    let fail = |reason: &str| {
        format!(
            "Amazon Photosに「{name}」を保存できません: {reason}。原本は残します。Apple PhotosまたはImmichを保存先に選んでください。"
        )
    };
    if name.is_empty()
        || name.chars().count() >= 255
        || name.ends_with([' ', '.'])
        || name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
        || name.contains("$$")
    {
        return Err(fail("ファイル名がAmazon Photosの制限に該当します"));
    }
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ["COM", "LPT"].iter().any(|prefix| {
            stem.strip_prefix(prefix)
                .is_some_and(|tail| tail.len() == 1 && matches!(tail.as_bytes()[0], b'1'..=b'9'))
        })
    {
        return Err(fail("予約されたファイル名です"));
    }
    if matches!(
        resource.role,
        ResourceRole::Auxiliary | ResourceRole::LiveVideo
    ) {
        return Err(fail(
            "補助データ・Live Photoの組を原本のまま保持できることを確認できません",
        ));
    }
    let supported = is_raw(&extension)
        || matches!(
            extension.as_str(),
            "jpg"
                | "jpeg"
                | "jxl"
                | "bmp"
                | "png"
                | "gif"
                | "tif"
                | "tiff"
                | "avif"
                | "heif"
                | "heic"
                | "jp2"
                | "webp"
                | "mp4"
                | "mov"
                | "avi"
                | "mts"
                | "mpg"
                | "mpeg"
                | "asf"
                | "wmv"
                | "flv"
                | "ogg"
        );
    if !supported {
        return Err(fail("この形式の受入れを確認できません"));
    }
    if resource.bytes == Some(0) {
        return Err(fail("空のファイルです"));
    }
    Ok(())
}
