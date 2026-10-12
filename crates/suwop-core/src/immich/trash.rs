use super::{Asset, Session};
use crate::{
    app::Context,
    trash::{TrashIdentity, TrashItem},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Deserialize)]
struct Config {
    trash: Policy,
}
#[derive(Deserialize)]
struct Policy {
    enabled: bool,
    days: u32,
}
#[derive(Deserialize)]
struct Restored {
    count: usize,
}

impl Session {
    pub fn supports_trash(&self) -> Result<(), String> {
        if !self.version.uses_cursor() {
            return Err("この操作には Immich 3.2 以降の 3.x が必要です。".into());
        }
        Ok(())
    }
    pub async fn trash_retention(&self, ctx: &Context) -> Result<u32, String> {
        self.supports_trash()?;
        let config: Config = self.json(ctx, "config", "GET", None).await?;
        if !config.trash.enabled || config.trash.days == 0 {
            return Err("ゴミ箱が無効、または保持日数が0日のため削除を開始しません。".into());
        }
        Ok(config.trash.days)
    }
    pub(crate) async fn owned_asset(&self, ctx: &Context, id: &str) -> Result<Asset, String> {
        super::valid_id(id)?;
        let asset: Asset = self.json(ctx, &format!("assets/{id}"), "GET", None).await?;
        if asset.id != id || asset.owner_id != self.user_id {
            return Err("写真の保存先または所有者を確認できません。".into());
        }
        Ok(asset)
    }
    pub async fn list_trash(&self, ctx: &Context, now: f64) -> Result<Vec<TrashItem>, String> {
        self.supports_trash()?;
        if !now.is_finite() || super::date_string(now).is_empty() {
            return Err("一覧の日時が不正です。".into());
        }
        let mut items = BTreeMap::new();
        let mut seen = BTreeSet::new();
        let mut cursor: Option<String> = None;
        for _ in 0..10_000 {
            let mut body = json!({"size":500,"withExif":true,"filter":{"trashedAt":{"ne":null},"createdAt":{"lte":super::date_string(now)}},"orderBy":{"field":"fileCreatedAt","direction":"desc"}});
            if let Some(token) = &cursor {
                body["cursor"] = json!(token);
            }
            let response: Value = self
                .json(ctx, "search/metadata", "POST", Some(body))
                .await?;
            let envelope = response
                .get("assets")
                .ok_or("ゴミ箱一覧の形式が不正です。")?;
            let page: Vec<Asset> = serde_json::from_value(
                envelope
                    .get("items")
                    .cloned()
                    .ok_or("ゴミ箱一覧がありません。")?,
            )
            .map_err(|_| "ゴミ箱一覧を読み取れません。")?;
            for asset in page {
                // Metadata searches also include timeline partners. Only our own
                // rows are actionable, but partner rows must not end pagination.
                if asset.owner_id != self.user_id {
                    continue;
                }
                if !asset.is_trashed {
                    return Err("ゴミ箱の状態が一致しません。".into());
                }
                super::valid_id(&asset.id)?;
                let identity = TrashIdentity::from_asset(&self.scope, &asset)?;
                let record = asset.record(&self.scope, None, None);
                if items
                    .insert(
                        asset.id.clone(),
                        TrashItem {
                            asset: record,
                            identity,
                        },
                    )
                    .is_some()
                {
                    return Err("ゴミ箱一覧に重複した写真があります。".into());
                }
            }
            let next = envelope
                .get("nextCursor")
                .ok_or("ゴミ箱のページ情報がありません。")?;
            if next.is_null() {
                return Ok(items.into_values().collect());
            }
            let token = next
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("ゴミ箱のページ情報が不正です。")?;
            if !seen.insert(token.to_string()) {
                return Err("ゴミ箱のページ情報が循環しています。".into());
            }
            cursor = Some(token.into());
        }
        Err("ゴミ箱のページ上限に達しました。一覧は未完了です。".into())
    }
    pub(crate) async fn restore_selected(
        &self,
        ctx: &Context,
        ids: &[String],
    ) -> Result<(), String> {
        self.supports_trash()?;
        if ids.is_empty() || ids.iter().collect::<BTreeSet<_>>().len() != ids.len() {
            return Err("復元対象が不正です。".into());
        }
        for id in ids {
            super::valid_id(id)?;
        }
        let result: Restored = self
            .json(
                ctx,
                "trash/restore/assets",
                "POST",
                Some(json!({"ids":ids})),
            )
            .await?;
        if result.count != ids.len() {
            return Err("復元件数の応答が一致しません。再送せず結果を確認してください。".into());
        }
        Ok(())
    }
}
