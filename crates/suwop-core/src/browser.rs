use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::domain::{Presence, ResourceRole, UnifiedPhoto};

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum PhotoFilter {
    #[default]
    All,
    Favorites,
    Photos,
    Videos,
    Live,
    Raw,
}
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum PhotoSort {
    #[default]
    Newest,
    Oldest,
    Name,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct BrowserOptions {
    pub query: String,
    pub filter: PhotoFilter,
    pub sort: PhotoSort,
    pub presence: Option<Presence>,
    pub time_zone: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct BrowserView {
    #[serde(rename = "photoIDs")]
    pub photo_ids: Vec<String>,
    pub total: usize,
    pub favorites: usize,
    pub videos: usize,
    pub live: usize,
    pub raw: usize,
}
#[must_use]
pub fn photo_id(photo: &UnifiedPhoto) -> String {
    let mut keys: Vec<_> = photo
        .assets
        .iter()
        .map(|a| {
            let provider = match a.key.provider {
                crate::domain::Provider::Apple => "apple",
                crate::domain::Provider::Immich => "immich",
            };
            format!("{provider}|{}|{}", a.key.scope, a.key.asset_id)
        })
        .collect();
    keys.sort();
    keys.join("+")
}
fn has_role(photo: &UnifiedPhoto, role: ResourceRole) -> bool {
    photo
        .assets
        .iter()
        .flat_map(|a| &a.resources)
        .any(|r| r.role == role)
}
fn favorite(photo: &UnifiedPhoto) -> bool {
    photo.assets.iter().any(|a| a.is_favorite)
}
fn date(photo: &UnifiedPhoto) -> Option<f64> {
    photo
        .assets
        .iter()
        .filter_map(|a| a.captured_at)
        .filter(|d| d.is_finite())
        .max_by(f64::total_cmp)
}
fn name(photo: &UnifiedPhoto) -> String {
    photo
        .assets
        .first()
        .map_or_else(String::new, |a| a.name.to_lowercase())
}
fn matches_query(photo: &UnifiedPhoto, tokens: &[String], time_zone: chrono_tz::Tz) -> bool {
    let mut haystack = photo
        .assets
        .iter()
        .flat_map(|a| {
            std::iter::once(a.name.clone()).chain(a.resources.iter().map(|r| r.name.clone()))
        })
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    if let Some(seconds) = date(photo) {
        // Date search also supports year and month without downloading originals.
        #[allow(clippy::cast_possible_truncation)]
        if let Some(date) = DateTime::<Utc>::from_timestamp(seconds as i64, 0) {
            haystack.push_str(
                &date
                    .with_timezone(&time_zone)
                    .format(" %Y-%m-%d %Y年%m月%d日")
                    .to_string(),
            );
        }
    }
    tokens.iter().all(|token| haystack.contains(token))
}
#[must_use]
pub fn browse(photos: &[UnifiedPhoto], options: &BrowserOptions) -> BrowserView {
    let tokens: Vec<_> = options
        .query
        .split_whitespace()
        .map(str::to_lowercase)
        .collect();
    let time_zone = options
        .time_zone
        .as_deref()
        .and_then(|zone| zone.parse().ok())
        .unwrap_or(chrono_tz::UTC);
    let mut visible: Vec<_> = photos
        .iter()
        .filter(|photo| {
            options.presence.is_none_or(|p| p == photo.presence)
                && match options.filter {
                    PhotoFilter::All => true,
                    PhotoFilter::Favorites => favorite(photo),
                    PhotoFilter::Photos => !has_role(photo, ResourceRole::Video),
                    PhotoFilter::Videos => has_role(photo, ResourceRole::Video),
                    PhotoFilter::Live => has_role(photo, ResourceRole::LiveVideo),
                    PhotoFilter::Raw => has_role(photo, ResourceRole::RawImage),
                }
                && matches_query(photo, &tokens, time_zone)
        })
        .collect();
    visible.sort_by(|a, b| {
        let order = match options.sort {
            PhotoSort::Name => name(a).cmp(&name(b)),
            PhotoSort::Newest | PhotoSort::Oldest => match (date(a), date(b)) {
                (Some(a), Some(b)) => {
                    if matches!(options.sort, PhotoSort::Newest) {
                        b.total_cmp(&a)
                    } else {
                        a.total_cmp(&b)
                    }
                }
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            },
        };
        order.then_with(|| photo_id(a).cmp(&photo_id(b)))
    });
    BrowserView {
        photo_ids: visible.into_iter().map(photo_id).collect(),
        total: photos.len(),
        favorites: photos.iter().filter(|p| favorite(p)).count(),
        videos: photos
            .iter()
            .filter(|p| has_role(p, ResourceRole::Video))
            .count(),
        live: photos
            .iter()
            .filter(|p| has_role(p, ResourceRole::LiveVideo))
            .count(),
        raw: photos
            .iter()
            .filter(|p| has_role(p, ResourceRole::RawImage))
            .count(),
    }
}
