use crate::{
    app::{Context, ShellOperation, io},
    domain::{AssetKey, PhotoResource, Provider, ResourceRole, StoredAsset, normalize_sha1},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use url::Url;
pub mod albums;
mod uploads;
pub use uploads::{PendingUpload, UploadMetadataPlan, UploadPhase, UploadResumePrompt};

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}
impl Version {
    #[must_use]
    pub fn uses_cursor(&self) -> bool {
        self.major == 3 && self.minor >= 2
    }
    #[must_use]
    pub fn uses_edited_previews(&self) -> bool {
        self.major == 3 || self.major == 2 && self.minor >= 6
    }
    #[must_use]
    pub fn description(&self) -> String {
        format!("{}.{}.{}", self.major, self.minor, self.patch)
    }
}
#[derive(Debug, Clone)]
pub struct Session {
    pub endpoint: String,
    pub key: String,
    pub user_id: String,
    pub scope: String,
    pub version: Version,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UploadPart {
    pub field: String,
    pub path: String,
    pub filename: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HttpRequest {
    pub url: String,
    pub method: String,
    pub headers: BTreeMap<String, String>,
    pub body: Option<Value>,
    pub fields: BTreeMap<String, String>,
    pub files: Vec<UploadPart>,
    pub download_path: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HttpResponse {
    pub status: u16,
    pub body: Value,
    pub path: Option<String>,
}
pub fn endpoint(address: &str, allow_http: bool) -> Result<String, String> {
    // Check segments before Url normalizes away dot segments.
    if address.split('/').any(|s| {
        matches!(
            s.to_ascii_lowercase().as_str(),
            "." | ".." | "%2e" | "%2e%2e" | ".%2e" | "%2e."
        )
    }) {
        return Err("接続先のパスが不正です。".into());
    }
    let mut url = Url::parse(address.trim()).map_err(|_| "URL が不正です。")?;
    if !(url.scheme() == "https" || url.scheme() == "http" && allow_http)
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("有効な HTTPS URL を入力してください。HTTP は明示的な許可が必要です。".into());
    }
    let mut path = url.path().trim_end_matches('/').to_owned();
    if !path.ends_with("/api") {
        path.push_str("/api");
    }
    url.set_path(&path);
    Ok(url.to_string())
}
#[must_use]
pub fn same_origin(a: &str, b: &str) -> bool {
    match (Url::parse(a), Url::parse(b)) {
        (Ok(a), Ok(b)) => {
            a.scheme() == b.scheme()
                && a.host_str() == b.host_str()
                && a.port_or_known_default() == b.port_or_known_default()
        }
        _ => false,
    }
}
pub fn valid_id(id: &str) -> Result<(), String> {
    let parts: Vec<_> = id.split('-').collect();
    if parts.len() == 5
        && parts
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(p, n)| p.len() == n && p.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        Ok(())
    } else {
        Err("Immich ID が不正です。".into())
    }
}
impl Session {
    pub fn preview_request(&self, id: &str, preview: bool) -> Result<HttpRequest, String> {
        valid_id(id)?;
        let size = if preview { "preview" } else { "thumbnail" };
        let edited = if self.version.uses_edited_previews() {
            "&edited=true"
        } else {
            ""
        };
        Ok(self.request(
            &format!("assets/{id}/thumbnail?size={size}{edited}"),
            "GET",
            None,
        ))
    }

    #[must_use]
    pub fn request(&self, path: &str, method: &str, body: Option<Value>) -> HttpRequest {
        HttpRequest {
            url: format!("{}/{path}", self.endpoint),
            method: method.into(),
            headers: BTreeMap::from([
                ("x-api-key".into(), self.key.clone()),
                ("Accept".into(), "application/json".into()),
            ]),
            body,
            fields: BTreeMap::new(),
            files: Vec::new(),
            download_path: None,
        }
    }
    pub async fn json<T: serde::de::DeserializeOwned>(
        &self,
        ctx: &Context,
        path: &str,
        method: &str,
        body: Option<Value>,
    ) -> Result<T, String> {
        let response: HttpResponse =
            io(ctx, ShellOperation::Http(self.request(path, method, body))).await?;
        check_status(response.status)?;
        serde_json::from_value(response.body)
            .map_err(|e| format!("Immich の応答形式が不正です: {e}"))
    }
    pub async fn asset(&self, ctx: &Context, id: &str) -> Result<Asset, String> {
        valid_id(id)?;
        let a: Asset = self.json(ctx, &format!("assets/{id}"), "GET", None).await?;
        if a.id != id || a.owner_id != self.user_id || a.is_trashed {
            return Err("写真の所有者または状態が変わりました。".into());
        }
        Ok(a)
    }
    pub async fn files(&self, ctx: &Context, id: &str) -> Result<Vec<AssetFile>, String> {
        valid_id(id)?;
        self.json(ctx, &format!("asset-files?assetId={id}"), "GET", None)
            .await
    }
    pub async fn favorite(&self, ctx: &Context, id: &str, value: bool) -> Result<Asset, String> {
        // Validate ownership before changing an asset, then confirm the saved value.
        self.asset(ctx, id).await?;
        let _: Value = self
            .json(
                ctx,
                &format!("assets/{id}"),
                "PUT",
                Some(json!({"isFavorite":value})),
            )
            .await?;
        let current = self.asset(ctx, id).await?;
        if current.is_favorite != value {
            return Err("お気に入りの保存結果を確認できません。一覧を更新してください。".into());
        }
        Ok(current)
    }
    pub async fn metadata(
        &self,
        ctx: &Context,
        ids: &[String],
        change: &crate::metadata::MetadataChange,
    ) -> Result<Vec<Asset>, String> {
        // Confirm every selected ID and owner before the single bulk write.
        if ids.is_empty() {
            return Err("変更する写真を選択してください。".into());
        }
        for id in ids {
            self.asset(ctx, id).await?;
        }
        let mut body = change.immich_fields()?;
        body["ids"] = json!(ids);
        let _: Value = self.json(ctx, "assets", "PUT", Some(body)).await?;
        let mut fresh = Vec::new();
        for id in ids {
            let asset = self.asset(ctx, id).await?;
            if change.action == crate::metadata::MetadataAction::SetCapturedAt
                && asset.exif_info.as_ref().and_then(|e| e.time_zone.as_ref())
                    != change.time_zone.as_ref()
            {
                return Err("日時のタイムゾーンの保存結果を確認できません。".into());
            }
            fresh.push(asset);
        }
        Ok(fresh)
    }
    pub async fn list(&self, ctx: &Context, now: f64) -> Result<Vec<Asset>, String> {
        let mut assets = BTreeMap::new();
        for view in if self.version.uses_cursor() {
            vec!["all"]
        } else {
            vec!["timeline", "archive"]
        } {
            let mut page = 1_u32;
            let mut cursor = None;
            let mut seen = BTreeSet::new();
            loop {
                if page > 10_000 {
                    return Err("ページ上限に達しました。一覧は未完了です。".into());
                }
                let mut body = json!({"size":500,"withExif":true,"withStacked":true});
                if self.version.uses_cursor() {
                    body["filter"] = json!({"visibility":{"in":["timeline","archive"]},"trashedAt":{"eq":null},"createdAt":{"lte":date_string(now)}});
                    body["orderBy"] = json!({"field":"fileCreatedAt","direction":"desc"});
                    if let Some(c) = &cursor {
                        body["cursor"] = json!(c);
                    }
                } else {
                    body["page"] = json!(page);
                    body["order"] = json!("desc");
                    body["visibility"] = json!(view);
                    body["withDeleted"] = json!(false);
                    body["createdBefore"] = json!(date_string(now));
                }
                let response: Value = self
                    .json(ctx, "search/metadata", "POST", Some(body))
                    .await?;
                let envelope = response
                    .get("assets")
                    .ok_or("一覧の assets がありません。")?;
                let items: Vec<Asset> = serde_json::from_value(
                    envelope
                        .get("items")
                        .cloned()
                        .ok_or("一覧の items がありません。")?,
                )
                .map_err(|_| "写真一覧の形式が不正です。")?;
                for a in items {
                    if a.owner_id == self.user_id && !a.is_trashed {
                        assets.insert(a.id.clone(), a);
                    }
                }
                let field = if self.version.uses_cursor() {
                    "nextCursor"
                } else {
                    "nextPage"
                };
                let token = envelope
                    .get(field)
                    .ok_or("ページ情報が欠落しています。完全な一覧として扱いません。")?;
                if token.is_null() {
                    break;
                }
                let next = token
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or("ページ情報が不正です。")?;
                if !seen.insert(next.to_owned()) {
                    return Err("ページ情報が循環しています。".into());
                }
                if self.version.uses_cursor() {
                    cursor = Some(next.to_owned());
                    page += 1;
                } else {
                    let number = next.parse::<u32>().map_err(|_| "ページ番号が不正です。")?;
                    if number <= page {
                        return Err("ページ番号が不正です。".into());
                    }
                    page = number;
                }
            }
        }
        Ok(assets.into_values().collect())
    }
    pub async fn download(&self, ctx: &Context, id: &str, path: &str) -> Result<(), String> {
        valid_id(id)?;
        let mut request = self.request(&format!("assets/{id}/original?edited=false"), "GET", None);
        request.download_path = Some(path.into());
        let response: HttpResponse = io(ctx, ShellOperation::Http(request)).await?;
        check_status(response.status)
    }
    pub async fn trash(&self, ctx: &Context, ids: &[String]) -> Result<(), String> {
        if ids.is_empty() {
            return Err("削除対象がありません。".into());
        }
        for id in ids {
            valid_id(id)?;
        }
        let _: Value = self
            .json(
                ctx,
                "assets",
                "DELETE",
                Some(json!({"ids":ids,"force":false})),
            )
            .await?;
        Ok(())
    }
}
pub async fn connect(
    ctx: &Context,
    address: &str,
    key: &str,
    allow_http: bool,
) -> Result<Session, String> {
    if key.is_empty() || key.contains(['\r', '\n']) {
        return Err("API キーが不正です。".into());
    }
    let mut session = Session {
        endpoint: endpoint(address, allow_http)?,
        key: key.into(),
        user_id: String::new(),
        scope: String::new(),
        version: Version {
            major: 0,
            minor: 0,
            patch: 0,
        },
    };
    session.version = session.json(ctx, "server/version", "GET", None).await?;
    if ![2, 3].contains(&session.version.major) {
        return Err("未対応の Immich メジャーバージョンです。".into());
    }
    let user: Value = session.json(ctx, "users/me", "GET", None).await?;
    session.user_id = user["id"]
        .as_str()
        .ok_or("利用者を確認できません。")?
        .into();
    valid_id(&session.user_id)?;
    session.scope = format!("{}#{}", session.endpoint, session.user_id);
    Ok(session)
}
pub fn check_status(status: u16) -> Result<(), String> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(format!(
            "Immich が HTTP {status} を返しました。URL・権限・接続を確認してください。"
        ))
    }
}
#[must_use]
// Chrono takes integer seconds/nanoseconds; the fractional part is bounded by floor.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub fn date_string(seconds: f64) -> String {
    if !seconds.is_finite() {
        return String::new();
    }
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1_000_000_000.0).round() as u32;
    let (whole, nanos) = if nanos == 1_000_000_000 {
        (whole + 1.0, 0)
    } else {
        (whole, nanos)
    };
    chrono::DateTime::from_timestamp(whole as i64, nanos).map_or_else(String::new, |d| {
        d.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true)
    })
}
fn upload_date(seconds: f64) -> Result<String, String> {
    if !seconds.is_finite() || !(-62_135_596_800.0..253_402_300_800.0).contains(&seconds) {
        return Err("転送元の日時を確認できません。アップロードを開始していません。".into());
    }
    Ok(date_string(seconds))
}
fn parse_date(value: &str) -> Option<f64> {
    chrono::DateTime::parse_from_rfc3339(value).ok().map(|d| {
        #[allow(clippy::cast_precision_loss)]
        {
            d.timestamp() as f64 + f64::from(d.timestamp_subsec_nanos()) / 1_000_000_000.0
        }
    })
}
#[must_use]
pub fn safe_name(name: &str) -> String {
    let base = name
        .rsplit('/')
        .next()
        .unwrap_or("original")
        .replace(['\\', '"', '\r', '\n'], "_");
    if base.is_empty() {
        "original".into()
    } else {
        base
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub id: String,
    pub owner_id: String,
    #[serde(rename = "type")]
    pub media_type: String,
    pub original_file_name: String,
    pub checksum: String,
    pub file_created_at: String,
    pub file_modified_at: String,
    pub updated_at: String,
    pub is_favorite: bool,
    pub is_offline: bool,
    pub is_trashed: bool,
    pub is_edited: Option<bool>,
    pub is_external: Option<bool>,
    #[serde(default, deserialize_with = "nullable_library")]
    pub library_id: LibraryStorage,
    pub live_photo_video_id: Option<String>,
    pub exif_info: Option<Exif>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Exif {
    pub file_size_in_byte: Option<u64>,
    pub date_time_original: Option<String>,
    pub time_zone: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AssetFile {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub path: String,
}
impl Asset {
    #[must_use]
    pub fn record(
        &self,
        scope: &str,
        companion: Option<&Self>,
        files: Option<&[AssetFile]>,
    ) -> StoredAsset {
        let ext = self
            .original_file_name
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        let raw = [
            "dng", "rw2", "raw", "arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "pef", "srw",
            "rwl", "3fr", "iiq",
        ];
        let role = if self.media_type == "VIDEO" {
            ResourceRole::Video
        } else if raw.contains(&ext.as_str()) {
            ResourceRole::RawImage
        } else {
            ResourceRole::Image
        };
        let mut resources = vec![PhotoResource {
            id: self.id.clone(),
            name: self.original_file_name.clone(),
            role,
            sha1: normalize_sha1(Some(&self.checksum)),
            bytes: self.exif_info.as_ref().and_then(|e| e.file_size_in_byte),
        }];
        let mut blockers = Vec::new();
        let external = self.is_external.or(match self.library_id {
            LibraryStorage::Unknown => None,
            LibraryStorage::Internal => Some(false),
            LibraryStorage::External => Some(true),
        });
        for (blocked, text) in [
            (
                external != Some(false),
                "External Library または保存種別未確認",
            ),
            (
                self.is_edited != Some(false),
                "編集あり、または編集状態未確認",
            ),
            (
                self.is_offline || self.is_trashed,
                "オフラインまたはゴミ箱内",
            ),
            (
                !["IMAGE", "VIDEO"].contains(&self.media_type.as_str()),
                "未対応のメディア形式",
            ),
        ] {
            if blocked {
                blockers.push(text.into());
            }
        }
        if let Some(video) = &self.live_photo_video_id {
            resources.push(PhotoResource {
                id: video.clone(),
                name: companion
                    .map_or("Live Photo 動画", |c| &c.original_file_name)
                    .into(),
                role: ResourceRole::LiveVideo,
                sha1: companion.and_then(|c| normalize_sha1(Some(&c.checksum))),
                bytes: companion.and_then(|c| c.exif_info.as_ref()?.file_size_in_byte),
            });
            blockers.push("Live Photo は関連情報保護のためコピーのみ".into());
        }
        inventory_sidecars(files, &mut resources, &mut blockers);
        StoredAsset {
            key: AssetKey {
                provider: Provider::Immich,
                scope: scope.into(),
                asset_id: self.id.clone(),
            },
            name: self.original_file_name.clone(),
            captured_at: self.capture_date(),
            modified_at: parse_date(&self.file_modified_at),
            revision: self.revision(companion),
            resources,
            is_favorite: self.is_favorite,
            latitude: self.exif_info.as_ref().and_then(|e| e.latitude),
            longitude: self.exif_info.as_ref().and_then(|e| e.longitude),
            inventory_complete: self.live_photo_video_id.is_none()
                || companion.is_some_and(|c| {
                    Some(&c.id) == self.live_photo_video_id.as_ref()
                        && c.owner_id == self.owner_id
                        && !c.is_trashed
                }),
            is_offline: self.is_offline || companion.is_some_and(|c| c.is_offline),
            deletion_blockers: blockers,
        }
    }
    fn capture_date(&self) -> Option<f64> {
        // Date adjustments update EXIF independently of the original file's
        // timestamp. An invalid advertised adjustment must remain unknown.
        self.exif_info
            .as_ref()
            .and_then(|e| e.date_time_original.as_deref())
            .map_or_else(|| parse_date(&self.file_created_at), parse_date)
    }
    fn revision(&self, companion: Option<&Self>) -> String {
        format!(
            "{}|{}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}",
            self.updated_at,
            self.checksum,
            self.live_photo_video_id,
            companion.map(|c| &c.updated_at),
            self.exif_info.as_ref().and_then(|e| e.latitude),
            self.exif_info.as_ref().and_then(|e| e.longitude),
            self.exif_info
                .as_ref()
                .and_then(|e| e.date_time_original.as_ref()),
            self.exif_info.as_ref().and_then(|e| e.time_zone.as_ref())
        )
    }
}

fn inventory_sidecars(
    files: Option<&[AssetFile]>,
    resources: &mut Vec<PhotoResource>,
    blockers: &mut Vec<String>,
) {
    match files {
        None => blockers.push("XMP sidecar の有無を確認できないためコピーのみ".into()),
        Some(files) => {
            for f in files.iter().filter(|f| f.kind == "sidecar") {
                resources.push(PhotoResource {
                    id: f.id.clone(),
                    name: safe_name(&f.path),
                    role: ResourceRole::Auxiliary,
                    sha1: None,
                    bytes: None,
                });
                blockers.push("XMP sidecar があるためコピーのみ".into());
            }
        }
    }
}

/// Missing storage evidence must remain distinct from an explicit internal-library null.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub enum LibraryStorage {
    #[default]
    Unknown,
    Internal,
    External,
}

fn nullable_library<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<LibraryStorage, D::Error> {
    Option::<String>::deserialize(deserializer).map(|id| {
        if id.is_some() {
            LibraryStorage::External
        } else {
            LibraryStorage::Internal
        }
    })
}
