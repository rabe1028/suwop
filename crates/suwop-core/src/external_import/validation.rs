use super::{ImportItem, ImportJournal, ImportPhase, ImportPurpose};
use crate::domain::ResourceRole;
use std::collections::BTreeSet;

fn token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub(super) fn validate(journal: &ImportJournal) -> Result<(), String> {
    let item = &journal.item;
    if !token(&journal.id)
        || !token(&journal.staging_operation)
        || !token(&item.id)
        || !journal.created_at.is_finite()
        || !(-62_135_596_800.0..253_402_300_800.0).contains(&journal.created_at)
        || journal.destination_scope.is_empty()
        || journal.destination_scope.len() > 1024
    {
        return Err("取り込みの識別情報が不正です。".into());
    }
    if (journal.purpose == ImportPurpose::External) != journal.source_keys.is_empty() {
        return Err("外部取り込みと複製の元写真を混同できません。".into());
    }
    if journal.source_keys.iter().collect::<BTreeSet<_>>().len() != journal.source_keys.len() {
        return Err("複製元のIDが重複しています。".into());
    }
    let metadata = &item.metadata;
    match (metadata.latitude, metadata.longitude) {
        (None, None) => {}
        (Some(lat), Some(lon))
            if lat.is_finite()
                && lon.is_finite()
                && (-90.0..=90.0).contains(&lat)
                && (-180.0..=180.0).contains(&lon) => {}
        _ => return Err("位置情報が不正です。".into()),
    }
    if metadata
        .captured_at
        .as_ref()
        .is_some_and(|date| chrono::DateTime::parse_from_rfc3339(date).is_err())
    {
        return Err("撮影日時には有効な日時とタイムゾーンが必要です。".into());
    }
    validate_resources(item)?;
    if matches!(
        journal.phase,
        ImportPhase::Prepared | ImportPhase::Cancelled
    ) && !journal.destination_keys.is_empty()
    {
        return Err("未完了の取り込みに保存先IDを指定できません。".into());
    }
    if journal.destination_keys.iter().any(|key| {
        key.provider != journal.destination
            || key.scope != journal.destination_scope
            || key.asset_id.is_empty()
    }) {
        return Err("取り込み先の識別情報が一致しません。".into());
    }
    if matches!(
        journal.phase,
        ImportPhase::Verified | ImportPhase::AlreadyPresent
    ) && journal.destination_keys.is_empty()
    {
        return Err("完了した取り込みには保存先IDが必要です。".into());
    }
    if (journal.phase == ImportPhase::Verified && journal.created != Some(true))
        || (journal.phase == ImportPhase::AlreadyPresent && journal.created != Some(false))
        || (journal.phase == ImportPhase::Prepared && journal.created.is_some())
    {
        return Err("取り込みの作成結果と記録が一致しません。".into());
    }
    Ok(())
}

fn validate_resources(item: &ImportItem) -> Result<(), String> {
    if item.resources.is_empty() || item.resources.len() > 2 {
        return Err("写真ごとに原本の構成を選択してください。".into());
    }
    let mut tokens = BTreeSet::new();
    for resource in &item.resources {
        if !token(&resource.token)
            || !tokens.insert(&resource.token)
            || resource.name.is_empty()
            || resource.name.len() > 1024
            || resource.name.contains(['/', '\\'])
            || resource.name.chars().any(char::is_control)
            || resource.name == "."
            || resource.name == ".."
            || resource.bytes == 0
            || resource.sha256.len() != 64
            || !resource
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("取り込み原本の検査情報が不正です。".into());
        }
        let valid_type = match resource.role {
            ResourceRole::Image => matches!(
                resource.media_type.as_str(),
                "image/jpeg" | "image/heic" | "image/png"
            ),
            ResourceRole::RawImage => resource.media_type == "image/raw",
            ResourceRole::Video | ResourceRole::LiveVideo => matches!(
                resource.media_type.as_str(),
                "video/quicktime" | "video/mp4"
            ),
            ResourceRole::Auxiliary => false,
        };
        if !valid_type {
            return Err("検査したファイル形式と原本の役割が一致しません。".into());
        }
    }
    let images = item
        .resources
        .iter()
        .filter(|r| r.role == ResourceRole::Image)
        .count();
    let raws = item
        .resources
        .iter()
        .filter(|r| r.role == ResourceRole::RawImage)
        .count();
    let lives = item
        .resources
        .iter()
        .filter(|r| r.role == ResourceRole::LiveVideo)
        .count();
    if item.resources.len() == 2 && !(images == 1 && (raws == 1 || lives == 1)) {
        return Err("RAW＋JPEG または Live Photo の完全な組を選択してください。".into());
    }
    let identifiers: Vec<_> = item
        .resources
        .iter()
        .filter_map(|r| r.content_identifier.as_deref())
        .collect();
    if lives > 0 {
        if images != 1
            || identifiers.len() != 2
            || identifiers[0].is_empty()
            || identifiers[0] != identifiers[1]
        {
            return Err("Live Photo の静止画と動画の関連IDを確認できません。".into());
        }
    } else if !identifiers.is_empty() {
        return Err("Live Photo の関連ファイルが不足しています。".into());
    }
    Ok(())
}
