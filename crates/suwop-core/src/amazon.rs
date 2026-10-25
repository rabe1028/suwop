//! Japanese Amazon Photos protocol. Cookie material stays in the native Keychain
//! adapter; Rust receives only opaque credential references and remote facts.
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use url::Url;

use crate::{
    app::{Context, ShellOperation, io},
    domain::{
        AppleVisibility, AssetKey, FileSignature, ImmichStackState, PhotoResource, Provider,
        ResourceRole, StoredAsset,
    },
    transport::{HttpRequest, OrdinaryContentAuthorization, OrdinarySessionGuard, UploadPart},
};

pub mod formats;
const BASE: &str = "https://www.amazon.co.jp/drive/v1";
pub const PAGE_SIZE: usize = 200;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonConnection")]
pub struct Connection {
    #[serde(skip)]
    #[schemars(skip)]
    pub(crate) content_authorization: Option<OrdinaryContentAuthorization>,
    #[serde(skip)]
    #[schemars(skip)]
    pub(crate) ordinary_guard: Option<OrdinarySessionGuard>,
    #[serde(rename = "credentialID")]
    pub credential_id: String,
    pub owner_id: String,
    pub scope: String,
    pub root_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonUploadRecord")]
pub struct UploadRecord {
    pub receipt_id: String,
    pub scope: String,
    pub name: String,
    pub signature: FileSignature,
    pub md5: String,
    pub node_id: Option<String>,
    pub verified: bool,
}

/// The explicit journal phase of one upload, derived from the saved fields
/// so the persisted format is unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UploadRecordPhase {
    /// Saved before the POST; the outcome may be unknown. A fence.
    Submitting,
    /// The POST returned this node ID; its original is not yet read back.
    Created,
    /// The returned original was read back and matched.
    Verified,
}

impl UploadRecord {
    #[must_use]
    pub fn phase(&self) -> UploadRecordPhase {
        match (&self.node_id, self.verified) {
            (_, true) => UploadRecordPhase::Verified,
            (Some(_), false) => UploadRecordPhase::Created,
            (None, false) => UploadRecordPhase::Submitting,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonRequest")]
pub struct Request {
    #[serde(rename = "credentialID")]
    pub credential_id: String,
    pub http: HttpRequest,
    pub byte_limit: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonResponse")]
pub struct Response {
    pub status: u16,
    pub body: Value,
    pub path: Option<String>,
    pub location: Option<String>,
}

/// Native upload evidence. `submitted` is false only when the native adapter
/// never invoked `URLSession` task resume; every later failure is an error.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonUploadSubmission")]
pub struct UploadSubmission {
    pub submitted: bool,
    pub response: Option<Response>,
    pub failure: Option<String>,
}

/// One upload attempt. An `Err` from [`Connection::submit_upload`] is ambiguous:
/// the original may still arrive, so its journal record must remain a fence.
#[derive(Debug)]
pub enum UploadOutcome {
    /// Definitely not stored: never submitted, or explicitly rejected.
    Refused(String),
    Accepted(Response),
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(rename = "AmazonHash")]
pub struct Hash {
    pub sha1: String,
    pub md5: String,
    pub signature: FileSignature,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Content {
    pub size: u64,
    pub md5: String,
    #[serde(default)]
    pub content_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: String,
    pub name: String,
    pub owner_id: String,
    pub modified_date: String,
    pub content_properties: Content,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub restricted: bool,
    #[serde(default)]
    pub protected_folder: bool,
    #[serde(default)]
    pub image_properties: Value,
    #[serde(default)]
    pub video_properties: Value,
    #[serde(default)]
    pub labels: Vec<String>,
    #[serde(default)]
    pub settings: Value,
}

impl Node {
    pub fn validate(&self, connection: &Connection) -> Result<(), String> {
        valid_id(&self.id)?;
        if self.restricted
            || self.protected_folder
            || self.status != "AVAILABLE"
            || self.owner_id != connection.owner_id
            || self.modified_date.is_empty()
            || self.name.is_empty()
            || self.content_properties.size == 0
            || self.content_properties.md5.len() != 32
            || !self
                .content_properties
                .md5
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
        {
            return Err("Amazon Photos の原本・所有者・ハッシュを確認できません。".into());
        }
        Ok(())
    }

    #[must_use]
    pub fn record(&self, connection: &Connection) -> StoredAsset {
        let extension = self
            .name
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        let role = if self.content_properties.content_type.starts_with("video/") {
            ResourceRole::Video
        } else if formats::is_raw(&extension) {
            ResourceRole::RawImage
        } else {
            ResourceRole::Image
        };
        let date = |value: &Value| value.as_str().and_then(crate::immich::parse_date);
        StoredAsset {
            key: AssetKey {provider:Provider::Amazon,scope:connection.scope.clone(),asset_id:self.id.clone()},
            name:self.name.clone(),
            captured_at:date(&self.image_properties["dateTimeOriginal"]),
            modified_at:date(&json!(self.modified_date)),
            revision:format!("{}|{}|{}",self.modified_date,self.content_properties.md5,self.content_properties.size),
            resources:vec![PhotoResource {id:self.id.clone(),name:self.name.clone(),role,sha1:None,bytes:Some(self.content_properties.size)}],
            is_favorite:self.settings["favorite"].as_bool().unwrap_or(false),
            latitude:self.image_properties["location"]["latitude"].as_f64(),
            longitude:self.image_properties["location"]["longitude"].as_f64(),
            inventory_complete:true,is_offline:false,
            deletion_blockers:vec!["Amazon Photos は原本のコピーに対応します。移動による元の削除には対応していません。".into()],
            immich_visibility:None,immich_stack:ImmichStackState::Unknown,
            immich_stack_membership:None,apple_visibility:AppleVisibility::Unknown,
        }
    }
}

/// Reuse a verified fingerprint only when the full remote revision and inventory
/// still match. Receipt evidence survives catalog refreshes and app restarts.
pub(crate) fn preserve_fingerprints(old: &StoredAsset, fresh: &mut StoredAsset) {
    if old.key != fresh.key
        || old.revision != fresh.revision
        || old.is_offline
        || fresh.is_offline
        || !old.inventory_complete
        || !fresh.inventory_complete
        || old.resources.len() != fresh.resources.len()
    {
        return;
    }
    for resource in &mut fresh.resources {
        if resource.sha1.is_none()
            && let Some(previous) = old.resources.iter().find(|r| {
                r.id == resource.id
                    && r.name == resource.name
                    && r.role == resource.role
                    && r.bytes == resource.bytes
            })
        {
            resource.sha1.clone_from(&previous.sha1);
        }
    }
}

pub fn valid_id(id: &str) -> Result<(), String> {
    if !id.is_empty()
        && id.len() <= 256
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        Ok(())
    } else {
        Err("Amazon Photos のIDが不正です。".into())
    }
}

pub fn admit_url(raw: &str, method: &str) -> Result<bool, String> {
    let url = Url::parse(raw).map_err(|_| "Amazon Photos のURLが不正です。")?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err("Amazon Photos の安全な接続先を確認できません。".into());
    }
    let host = url.host_str().ok_or("接続先がありません。")?;
    let path = url.path();
    let node = path.strip_prefix("/drive/v1/nodes/");
    let read_node = node.is_some_and(|tail| {
        valid_id(tail).is_ok()
            || tail
                .strip_suffix("/contentRedirection")
                .is_some_and(|id| valid_id(id).is_ok())
            || tail
                .strip_suffix("/content")
                .is_some_and(|id| valid_id(id).is_ok())
    });
    let api = host == "www.amazon.co.jp"
        && match method {
            "GET" => {
                matches!(
                    path,
                    "/drive/v1/nodes"
                        | "/drive/v1/search"
                        | "/drive/v1/account/usage"
                        | "/drive/v1/account/quota"
                        | "/drive/v1/account/endpoint"
                ) || read_node
            }
            "PATCH" => node.is_some_and(|id| valid_id(id).is_ok()),
            _ => false,
        };
    let thumbnail = host == "thumbnails-photos.amazon.co.jp"
        && method == "GET"
        && path
            .strip_prefix("/v1/thumbnail/")
            .is_some_and(|id| valid_id(id).is_ok());
    let upload = host == "upload-photos.amazon.co.jp" && path == "/v2/upload" && method == "POST";
    let cdn =
        method == "GET" && (host.ends_with(".cloudfront.net") || host.ends_with(".amazonaws.com"));
    if api || thumbnail || upload {
        Ok(true)
    } else if cdn {
        Ok(false)
    } else {
        Err("許可していないAmazon Photosの操作・転送先です。".into())
    }
}

impl Connection {
    pub fn provisional(credential_id: &str) -> Result<Self, String> {
        if credential_id.is_empty() || credential_id.len() > 128 {
            return Err("認証情報を確認できません。".into());
        }
        Ok(Self {
            content_authorization: None,
            ordinary_guard: None,
            credential_id: credential_id.into(),
            owner_id: String::new(),
            scope: String::new(),
            root_id: String::new(),
        })
    }

    pub fn request(
        &self,
        path: &str,
        method: &str,
        body: Option<Value>,
    ) -> Result<Request, String> {
        let url = if path.starts_with("https://") {
            path.into()
        } else {
            format!("{BASE}/{path}")
        };
        admit_url(&url, method)?;
        Ok(Request {
            credential_id: self.credential_id.clone(),
            byte_limit: 16 * 1024 * 1024,
            http: HttpRequest {
                url,
                method: method.into(),
                headers: BTreeMap::new(),
                body,
                fields: BTreeMap::new(),
                files: vec![],
                download_path: None,
                ordinary_content_authorization: self.content_authorization.clone(),
                immich_visibility_authorization: None,
                immich_archive_authorization: None,
            },
        })
    }

    pub async fn execute(&self, ctx: &Context, mut request: Request) -> Result<Response, String> {
        for hop in 0..=5 {
            self.check_guard()?;
            let response: Response = io(
                ctx,
                ShellOperation::AmazonHttp {
                    request: request.clone(),
                },
            )
            .await?;
            self.check_guard()?;
            if matches!(response.status, 301 | 302 | 303 | 307 | 308) {
                if request.http.method != "GET" || hop == 5 {
                    return Err(
                        "Amazon Photosの書込み・転送先を確認できません。再送しません。".into(),
                    );
                }
                let location = response
                    .location
                    .ok_or("Amazon Photosの転送先がありません。")?;
                let next = Url::parse(&request.http.url)
                    .and_then(|url| url.join(&location))
                    .map_err(|_| "転送先が不正です。")?;
                admit_url(next.as_str(), "GET")?;
                request.http.url = next.into();
                continue;
            }
            return match response.status {
                200..=299 => Ok(response),
                status => Err(status_error(status)),
            };
        }
        Err("転送回数を超えました。".into())
    }

    /// Submit one upload exactly once. Only a native proof that the task never
    /// resumed, or an explicit 400/413/415 rejection, is `Refused`. Transport
    /// errors, other statuses and malformed evidence remain ambiguous `Err`s.
    pub async fn submit_upload(
        &self,
        ctx: &Context,
        request: Request,
    ) -> Result<UploadOutcome, String> {
        if let Err(error) = self.check_guard() {
            return Ok(UploadOutcome::Refused(error));
        }
        let submission: UploadSubmission =
            io(ctx, ShellOperation::AmazonUpload { request }).await?;
        match submission {
            UploadSubmission {
                submitted: false,
                response: None,
                failure,
            } => Ok(UploadOutcome::Refused(format!(
                "Amazon Photosへ送信する前に中止しました。原本は送信していません。{}",
                failure.unwrap_or_default()
            ))),
            UploadSubmission {
                submitted: true,
                response: Some(response),
                failure: None,
            } => {
                // A generation change after submission cannot recall the POST.
                self.check_guard()?;
                match response.status {
                    200..=299 => Ok(UploadOutcome::Accepted(response)),
                    status @ (400 | 413 | 415) => Ok(UploadOutcome::Refused(status_error(status))),
                    status => Err(status_error(status)),
                }
            }
            _ => Err("Amazon Photosの送信結果が不正です。書込みは再送しません。".into()),
        }
    }

    pub async fn connect(&mut self, ctx: &Context) -> Result<(), String> {
        let request = self.request(
            "nodes?filters=isRoot%3Atrue&resourceVersion=V2&ContentType=JSON",
            "GET",
            None,
        )?;
        let body = self.execute(ctx, request).await?.body;
        let roots = body["data"]
            .as_array()
            .ok_or("Amazon Photosの所有者を確認できません。")?;
        if roots.len() != 1 {
            return Err("Amazon Photosの所有者が一意ではありません。".into());
        }
        self.owner_id = roots[0]["ownerId"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("Amazon Photosの所有者がありません。")?
            .into();
        self.root_id = roots[0]["id"]
            .as_str()
            .ok_or("Amazon Photosのルートがありません。")?
            .into();
        valid_id(&self.root_id)?;
        self.scope = format!("amazon.co.jp|{}", self.owner_id);
        Ok(())
    }

    fn check_guard(&self) -> Result<(), String> {
        if self.ordinary_guard.as_ref().is_some_and(|g| !g.current()) {
            Err("写真へのアクセスが変わりました。Amazon Photosの処理を止めました。".into())
        } else {
            Ok(())
        }
    }

    pub async fn node(&self, ctx: &Context, id: &str) -> Result<Node, String> {
        valid_id(id)?;
        let response = self
            .execute(
                ctx,
                self.request(
                    &format!("nodes/{id}?resourceVersion=V2&tempLink=false"),
                    "GET",
                    None,
                )?,
            )
            .await?;
        let node: Node = serde_json::from_value(response.body)
            .map_err(|_| "Amazon Photosの写真データが不正です。")?;
        node.validate(self)?;
        if node.id != id {
            return Err("Amazon Photosの写真IDが変わりました。".into());
        }
        Ok(node)
    }

    pub async fn page(&self, ctx: &Context, offset: usize) -> Result<(usize, Vec<Node>), String> {
        let mut url = Url::parse(&format!("{BASE}/search")).map_err(|_| "一覧URLが不正です。")?;
        url.query_pairs_mut().extend_pairs([
            ("filters", "type:(PHOTOS OR VIDEOS)"),
            ("searchContext", "customer"),
            ("asset", "ALL"),
            ("resourceVersion", "V2"),
            ("tempLink", "false"),
            ("lowResThumbnail", "true"),
            ("sort", "['createdDate DESC']"),
            (
                "limit",
                &PAGE_SIZE.min(9999usize.saturating_sub(offset)).to_string(),
            ),
            ("offset", &offset.to_string()),
        ]);
        let response = self
            .execute(ctx, self.request(url.as_str(), "GET", None)?)
            .await?;
        let total = response.body["count"]
            .as_u64()
            .and_then(|n| usize::try_from(n).ok())
            .ok_or("Amazon Photosの一覧件数がありません。")?;
        let nodes: Vec<Node> = serde_json::from_value(response.body["data"].clone())
            .map_err(|_| "Amazon Photosの一覧形式が不正です。")?;
        if nodes.len() > PAGE_SIZE {
            return Err("Amazon Photosのページ件数が不正です。".into());
        }
        for node in &nodes {
            node.validate(self)?;
        }
        Ok((total, nodes))
    }

    pub fn preview(&self, id: &str) -> Result<Request, String> {
        valid_id(id)?;
        let mut url = Url::parse(&format!(
            "https://thumbnails-photos.amazon.co.jp/v1/thumbnail/{id}"
        ))
        .map_err(|_| "画像URLが不正です。")?;
        url.query_pairs_mut().extend_pairs([
            ("ownerId", self.owner_id.as_str()),
            ("viewBox", "1024"),
            ("contentType", "JPEG"),
        ]);
        self.request(url.as_str(), "GET", None)
    }

    pub async fn download(&self, ctx: &Context, node: &Node, path: &str) -> Result<Hash, String> {
        node.validate(self)?;
        let mut request = self.request(
            &format!("nodes/{}/contentRedirection", node.id),
            "GET",
            None,
        )?;
        let mut url = Url::parse(&request.http.url).map_err(|_| "原本URLが不正です。")?;
        url.query_pairs_mut().extend_pairs([
            ("ownerId", self.owner_id.as_str()),
            ("querySuffix", "?download=true"),
        ]);
        request.http.url = url.into();
        request.http.download_path = Some(path.into());
        request.byte_limit = node.content_properties.size;
        let response = self.execute(ctx, request).await?;
        if response.path.as_deref() != Some(path) {
            return Err("Amazon Photosの原本取得結果が不正です。".into());
        }
        let hash: Hash = io(ctx, ShellOperation::AmazonHashFile { path: path.into() }).await?;
        let fresh = self.node(ctx, &node.id).await?;
        if fresh.modified_date != node.modified_date
            || fresh.content_properties != node.content_properties
            || hash.signature.bytes != node.content_properties.size
            || !hash.md5.eq_ignore_ascii_case(&node.content_properties.md5)
        {
            return Err(
                "Amazon Photosの原本とハッシュ・サイズが一致しません。原本は削除しません。".into(),
            );
        }
        Ok(hash)
    }

    pub async fn upload_request(
        &self,
        ctx: &Context,
        file: &crate::domain::TransferFile,
        md5: &str,
        captured_at: Option<f64>,
    ) -> Result<Request, String> {
        formats::check_resource(&file.resource)?;
        let endpoint = self
            .execute(ctx, self.request("account/endpoint", "GET", None)?)
            .await?;
        let mut url = upload_target(&endpoint.body)?;
        let mut request = self.request(url.as_str(), "POST", None)?;
        url.query_pairs_mut().extend_pairs([
            ("name", file.resource.name.as_str()),
            ("fileSize", &file.signature.bytes.to_string()),
            ("parentNodeId", self.root_id.as_str()),
            ("conflictResolution", "RENAME"),
        ]);
        if let Some(captured_at) = captured_at.filter(|date| date.is_finite()) {
            url.query_pairs_mut()
                .append_pair("contentDate", &crate::immich::date_string(captured_at));
        }
        request.http.url = url.into();
        request
            .http
            .headers
            .insert("x-amzn-file-md5".into(), md5.into());
        request.http.headers.insert(
            "Content-Type".into(),
            "application/x-www-form-urlencoded".into(),
        );
        request.http.files.push(UploadPart {
            field: "content".into(),
            path: file.path.clone(),
            filename: file.resource.name.clone(),
        });
        Ok(request)
    }

    pub async fn favorite(
        &self,
        ctx: &Context,
        id: &str,
        value: bool,
    ) -> Result<StoredAsset, String> {
        let _ = self.node(ctx, id).await?;
        let request = self.request(
            &format!("nodes/{id}"),
            "PATCH",
            Some(
                json!({"settings":{"favorite":value},"resourceVersion":"V2","ContentType":"JSON"}),
            ),
        )?;
        self.execute(ctx, request).await?;
        let node = self.node(ctx, id).await?;
        if node.settings["favorite"].as_bool() != Some(value) {
            return Err("Amazon Photosのお気に入りの保存結果を確認できません。".into());
        }
        Ok(node.record(self))
    }
}

fn status_error(status: u16) -> String {
    match status {
        401|403 => "Amazon Photosの認証が切れたか、操作が拒否されました。接続設定からログインし直してください。".into(),
        400 => "Amazon Photosが原本を受け付けませんでした（HTTP 400）。形式・ファイル名・容量を確認するか、Apple PhotosまたはImmichを選んでください。原本は残し、書込みは再送しません。".into(),
        409 => "Amazon Photosで同名・同内容のファイルが見つかりました。再送せず、一覧を更新して確認してください。".into(),
        413 => "Amazon Photosのファイルサイズ上限を超えています。Apple PhotosまたはImmichを選んでください。".into(),
        415 => "Amazon Photosがこのファイル形式を受け付けません。原本は残しています。Apple PhotosまたはImmichを選んでください。".into(),
        429 => "Amazon Photosの利用制限に達しました。時間を置いて一覧を更新してください。書込みは自動再送しません。".into(),
        status => format!("Amazon Photosの操作結果を確認できません（HTTP {status}）。書込みは自動再送しません。"),
    }
}

/// Only the JP upload service advertised by the authenticated account endpoint
/// may receive originals. Do not infer a geographic AWS hostname from retail TLD.
pub fn upload_target(endpoint: &Value) -> Result<Url, String> {
    let invalid = || {
        "Amazon Photosのアップロード先を確認できません。原本は送信していません。Apple PhotosまたはImmichを選んでください。".to_owned()
    };
    let mut url = endpoint["uploadServiceUrl"]
        .as_str()
        .and_then(|raw| Url::parse(raw).ok())
        .ok_or_else(invalid)?;
    if url.scheme() != "https"
        || url.host_str() != Some("upload-photos.amazon.co.jp")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "/" | "/v2/upload")
    {
        return Err(invalid());
    }
    url.set_path("/v2/upload");
    Ok(url)
}

pub fn utility(value: &Value) -> Result<Value, String> {
    match value["type"].as_str() {
        Some("admit") => serde_json::to_value(admit_url(
            value["url"].as_str().ok_or("URLがありません。")?,
            value["method"].as_str().ok_or("methodがありません。")?,
        )?)
        .map_err(|e| e.to_string()),
        Some("preview") => {
            let connection: Connection = serde_json::from_value(value["connection"].clone())
                .map_err(|_| "Amazon Photosの接続設定が不正です。")?;
            let key: AssetKey =
                serde_json::from_value(value["key"].clone()).map_err(|_| "写真IDが不正です。")?;
            if key.provider != Provider::Amazon || key.scope != connection.scope {
                return Err("Amazon Photosのアカウントが一致しません。".into());
            }
            serde_json::to_value(connection.preview(&key.asset_id)?).map_err(|e| e.to_string())
        }
        Some("uploadEndpoint") => {
            let connection: Connection = serde_json::from_value(value["connection"].clone())
                .map_err(|_| "Amazon Photosの接続設定が不正です。")?;
            serde_json::to_value(connection.request("account/endpoint", "GET", None)?)
                .map_err(|e| e.to_string())
        }
        _ => Err("不明なAmazon Photos要求です。".into()),
    }
}
