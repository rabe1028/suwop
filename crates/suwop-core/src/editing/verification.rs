use crate::domain::TransferBundle;

/// Edits may replace auxiliary/rendered resources, but every immutable original
/// must keep its role, filename, SHA-256 and length, including RAW/JPEG partners.
pub fn verify_edited_originals(
    before: &TransferBundle,
    after: &TransferBundle,
) -> Result<(), String> {
    before.validate()?;
    after.validate()?;
    let keys = |bundle: &TransferBundle| {
        bundle
            .assets
            .iter()
            .map(|a| a.key.clone())
            .collect::<std::collections::BTreeSet<_>>()
    };
    if before.assets.len() != after.assets.len() || keys(before) != keys(after) {
        return Err("編集した写真の保存先を確認できません。".into());
    }
    let mut expected: Vec<_> = before
        .files
        .iter()
        .filter(|f| f.resource.role.is_original())
        .map(|f| {
            (
                f.resource.role,
                f.resource.name.clone(),
                f.signature.clone(),
            )
        })
        .collect();
    if expected.is_empty() {
        return Err("編集前の原本を確認できません。".into());
    }
    for file in after.files.iter().filter(|f| f.resource.role.is_original()) {
        let value = (
            file.resource.role,
            file.resource.name.clone(),
            file.signature.clone(),
        );
        let index = expected
            .iter()
            .position(|old| *old == value)
            .ok_or("編集後の原本が一致しません。もう一度一覧を確認してください。")?;
        expected.remove(index);
    }
    if !expected.is_empty() {
        return Err("編集後の原本の組を確認できません。".into());
    }
    for source in &before.assets {
        let fresh = after
            .assets
            .iter()
            .find(|a| a.key == source.key)
            .ok_or("編集した写真を確認できません。")?;
        if source.captured_at != fresh.captured_at
            || source.is_favorite != fresh.is_favorite
            || source.latitude != fresh.latitude
            || source.longitude != fresh.longitude
        {
            return Err("編集後の日時・お気に入り・位置情報が一致しません。".into());
        }
    }
    Ok(())
}
