use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

use super::{Asset, Session, valid_id};
use crate::app::Context;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AlbumInfo {
    pub id: String,
    pub album_name: String,
    #[serde(default)]
    pub owner_id: Option<String>,
    #[serde(default)]
    pub album_users: Vec<AlbumUser>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AlbumUser {
    pub role: String,
    pub user: AlbumOwner,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AlbumOwner {
    pub id: String,
}

impl AlbumInfo {
    #[must_use]
    pub fn owned_by(&self, id: &str) -> bool {
        let owners: Vec<_> = self
            .album_users
            .iter()
            .filter(|u| u.role == "owner")
            .collect();
        match self.owner_id.as_deref() {
            Some(owner) => {
                owner == id
                    && (owners.is_empty() || owners.len() == 1 && owners[0].user.id == owner)
            }
            None => owners.len() == 1 && owners[0].user.id == id,
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct MemberResult {
    id: String,
    success: bool,
    error: Option<String>,
}

impl Session {
    pub async fn albums(&self, ctx: &Context) -> Result<Vec<AlbumInfo>, String> {
        let albums: Vec<AlbumInfo> = self.json(ctx, "albums", "GET", None).await?;
        for album in &albums {
            valid_id(&album.id)?;
        }
        Ok(albums)
    }

    pub async fn album(&self, ctx: &Context, id: &str) -> Result<AlbumInfo, String> {
        valid_id(id)?;
        let album: AlbumInfo = self.json(ctx, &format!("albums/{id}"), "GET", None).await?;
        if album.id != id || !album.owned_by(&self.user_id) {
            return Err("アルバムの所有者または保存先が変わっています。".into());
        }
        Ok(album)
    }

    pub async fn create_album(&self, ctx: &Context, title: &str) -> Result<AlbumInfo, String> {
        crate::albums::validate_title(title)?;
        let created: AlbumInfo = self
            .json(ctx, "albums", "POST", Some(json!({"albumName":title})))
            .await?;
        let fresh = self.album(ctx, &created.id).await?;
        if fresh.album_name != title {
            return Err("アルバムの作成結果を確認できません。一覧を更新してください。".into());
        }
        Ok(fresh)
    }

    pub async fn rename_album(&self, ctx: &Context, id: &str, title: &str) -> Result<(), String> {
        crate::albums::validate_title(title)?;
        self.album(ctx, id).await?;
        let _: Value = self
            .json(
                ctx,
                &format!("albums/{id}"),
                "PATCH",
                Some(json!({"albumName":title})),
            )
            .await?;
        if self.album(ctx, id).await?.album_name != title {
            return Err("アルバムの名前を保存した結果を確認できません。".into());
        }
        Ok(())
    }

    pub async fn album_members(&self, ctx: &Context, id: &str) -> Result<Vec<Asset>, String> {
        self.album(ctx, id).await?;
        let mut assets = BTreeMap::new();
        let mut cursor = None;
        let mut page = 1_u32;
        let mut seen = BTreeSet::new();
        loop {
            if page > 10_000 {
                return Err("アルバムのページ上限に達しました。".into());
            }
            let mut body = json!({"size":500,"withExif":true,"withStacked":true});
            if self.version.uses_cursor() {
                body["filter"] = json!({"albumIds":{"any":[id]},"trashedAt":{"eq":null}});
                if let Some(token) = &cursor {
                    body["cursor"] = json!(token);
                }
            } else {
                body["albumIds"] = json!([id]);
                body["page"] = json!(page);
                body["withDeleted"] = json!(false);
            }
            let response: Value = self
                .json(ctx, "search/metadata", "POST", Some(body))
                .await?;
            let envelope = response
                .get("assets")
                .ok_or("アルバムの assets がありません。")?;
            let items: Vec<Asset> = serde_json::from_value(
                envelope
                    .get("items")
                    .cloned()
                    .ok_or("アルバムの items がありません。")?,
            )
            .map_err(|_| "アルバムの写真一覧が不正です。")?;
            for item in items {
                if !item.is_trashed {
                    assets.insert(item.id.clone(), item);
                }
            }
            let field = if self.version.uses_cursor() {
                "nextCursor"
            } else {
                "nextPage"
            };
            let token = envelope
                .get(field)
                .ok_or("アルバムのページ情報が欠落しています。")?;
            if token.is_null() {
                break;
            }
            let next = token
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("ページ情報が不正です。")?;
            if !seen.insert(next.to_owned()) {
                return Err("アルバムのページ情報が循環しています。".into());
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
        Ok(assets.into_values().collect())
    }

    pub async fn change_album_members(
        &self,
        ctx: &Context,
        id: &str,
        ids: &[String],
        add: bool,
    ) -> Result<(), String> {
        self.album(ctx, id).await?;
        let unique: BTreeSet<_> = ids.iter().cloned().collect();
        for key in &unique {
            if self.asset(ctx, key).await?.id != *key {
                return Err("写真の取得結果が異なります。".into());
            }
        }
        let results: Vec<MemberResult> = self
            .json(
                ctx,
                &format!("albums/{id}/assets"),
                if add { "PUT" } else { "DELETE" },
                Some(json!({"ids":unique})),
            )
            .await?;
        if results.len() != unique.len()
            || results
                .iter()
                .map(|r| r.id.clone())
                .collect::<BTreeSet<_>>()
                != unique
            || results
                .iter()
                .any(|r| !(r.success || add && r.error.as_deref() == Some("duplicate")))
        {
            return Err(
                "アルバムの一部の写真を変更できませんでした。一覧を更新してください。".into(),
            );
        }
        let members: BTreeSet<_> = self
            .album_members(ctx, id)
            .await?
            .into_iter()
            .map(|a| a.id)
            .collect();
        if unique.iter().any(|key| members.contains(key) != add) {
            return Err("アルバムの写真を変更した結果を確認できません。".into());
        }
        Ok(())
    }

    pub async fn delete_album(&self, ctx: &Context, id: &str) -> Result<(), String> {
        self.album(ctx, id).await?;
        // Delete the collection only. This route never deletes its photos.
        let _: Value = self
            .json(ctx, &format!("albums/{id}"), "DELETE", None)
            .await?;
        if self.albums(ctx).await?.iter().any(|album| album.id == id) {
            return Err("アルバムの削除結果を確認できません。一覧を更新してください。".into());
        }
        Ok(())
    }
}
