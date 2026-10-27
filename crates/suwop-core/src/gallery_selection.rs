//! Ephemeral gallery selection follows exact physical members, never row overlap.
//! Search/sort are presentation only. Catalog regrouping cannot select new keys.
use std::collections::BTreeSet;

use crate::{
    app::{Event, Model, Suwop},
    browser::photo_id,
    domain::{AssetKey, UnifiedPhoto},
};

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct GallerySelection {
    pub keys: Vec<AssetKey>,
    #[serde(rename = "photoIDs")]
    pub photo_ids: Vec<String>,
}

/// Only fully selected, currently authorized groups survive. In particular A
/// selected before A+B merges becomes empty, rather than acquiring B.
#[must_use]
pub fn reconcile(
    photos: &[UnifiedPhoto],
    authorized: &[AssetKey],
    selected: &BTreeSet<AssetKey>,
) -> GallerySelection {
    if selected.is_empty() {
        return GallerySelection::default();
    }
    let authorized: BTreeSet<_> = authorized.iter().collect();
    let mut keys = BTreeSet::new();
    let mut photo_ids = Vec::new();
    for photo in photos {
        if !photo.assets.is_empty()
            && photo
                .assets
                .iter()
                .all(|asset| selected.contains(&asset.key) && authorized.contains(&asset.key))
        {
            keys.extend(photo.assets.iter().map(|asset| asset.key.clone()));
            photo_ids.push(photo_id(photo));
        }
    }
    GallerySelection {
        keys: keys.into_iter().collect(),
        photo_ids,
    }
}

/// Called after reduction, before a later split event could resurrect a key
/// retired by an earlier merge. Selection never enters `SavedLibrary`.
pub(crate) fn reconcile_model(model: &mut Model) {
    if model.gallery_selection_keys.is_empty() {
        return;
    }
    let (photos, authorized) = Suwop::gallery_selection_catalog(model);
    model.gallery_selection_keys = reconcile(&photos, &authorized, &model.gallery_selection_keys)
        .keys
        .into_iter()
        .collect();
}

/// Explicit clicks carry the displayed IDs at click time, including select-all.
/// Do not reinterpret a delayed select-all as a wildcard over a newer catalog.
pub(crate) fn update(event: &Event, model: &mut Model) -> bool {
    match event {
        Event::Configure { .. }
        | Event::ConfigureAmazon { .. }
        | Event::Disconnect
        | Event::DisconnectAmazon => {
            model.gallery_selection_keys.clear();
            false
        }
        Event::ClearGallerySelection => {
            model.gallery_selection_keys.clear();
            true
        }
        Event::SelectGalleryPhotos {
            photo_ids,
            selected,
        } => {
            apply_selection(model, photo_ids, Some(*selected));
            true
        }
        Event::ToggleGalleryPhoto { photo_id } => {
            apply_selection(model, std::slice::from_ref(photo_id), None);
            true
        }
        _ => false,
    }
}

fn apply_selection(model: &mut Model, photo_ids: &[String], explicit: Option<bool>) {
    // A click can arrive after authority changed without a Swift publication.
    reconcile_model(model);
    let (photos, authorized) = Suwop::gallery_selection_catalog(model);
    let authorized: BTreeSet<_> = authorized.into_iter().collect();
    let requested: BTreeSet<_> = photo_ids.iter().collect();
    for photo in photos {
        if !requested.contains(&photo_id(&photo)) {
            continue;
        }
        let selected = explicit.unwrap_or_else(|| {
            !photo
                .assets
                .iter()
                .all(|a| model.gallery_selection_keys.contains(&a.key))
        });
        if selected {
            if photo.assets.iter().all(|a| authorized.contains(&a.key)) {
                model
                    .gallery_selection_keys
                    .extend(photo.assets.into_iter().map(|a| a.key));
            }
        } else {
            for asset in photo.assets {
                model.gallery_selection_keys.remove(&asset.key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AppleVisibility, Presence, Provider, StoredAsset};

    fn key(id: &str) -> AssetKey {
        AssetKey {
            provider: Provider::Apple,
            scope: "generated".into(),
            asset_id: id.into(),
        }
    }

    fn photo(ids: &[&str]) -> UnifiedPhoto {
        UnifiedPhoto {
            presence: Presence::AppleOnly,
            assets: ids
                .iter()
                .map(|id| StoredAsset {
                    key: key(id),
                    name: format!("{id}.jpg"),
                    revision: "1".into(),
                    apple_visibility: AppleVisibility::Visible,
                    immich_visibility: None,
                    immich_stack: crate::domain::ImmichStackState::Unknown,
                    immich_stack_membership: None,
                    captured_at: None,
                    modified_at: None,
                    resources: vec![],
                    is_favorite: false,
                    latitude: None,
                    longitude: None,
                    inventory_complete: true,
                    is_offline: false,
                    deletion_blockers: vec![],
                })
                .collect(),
        }
    }

    #[test]
    fn partial_merge_retires_keys_and_later_split_cannot_resurrect_them() {
        let mut selected = BTreeSet::from([key("A")]);
        let authorized = vec![key("A"), key("B")];
        let initial = reconcile(&[photo(&["A"]), photo(&["B"])], &authorized, &selected);
        assert_eq!(initial.keys, vec![key("A")]);
        selected = reconcile(&[photo(&["A", "B"])], &authorized, &selected)
            .keys
            .into_iter()
            .collect();
        assert!(selected.is_empty());
        assert!(
            reconcile(&[photo(&["A"]), photo(&["B"])], &authorized, &selected)
                .keys
                .is_empty()
        );
    }

    #[test]
    fn fully_selected_merge_and_split_keep_only_previously_selected_authorized_members() {
        let selected = BTreeSet::from([key("A"), key("B"), key("removed")]);
        let authorized = vec![key("A"), key("B"), key("new")];
        assert_eq!(
            reconcile(&[photo(&["A", "B"])], &authorized, &selected).keys,
            vec![key("A"), key("B")]
        );
        assert_eq!(
            reconcile(
                &[photo(&["B"]), photo(&["new"]), photo(&["A"])],
                &authorized,
                &selected
            )
            .keys,
            vec![key("A"), key("B")]
        );
        assert!(
            reconcile(&[photo(&["A", "new"])], &authorized, &selected)
                .keys
                .is_empty()
        );
    }

    #[test]
    fn revoked_member_retires_whole_group_and_disappeared_members_are_removed() {
        let selected = BTreeSet::from([key("A"), key("B"), key("gone")]);
        assert!(
            reconcile(&[photo(&["A", "B"])], &[key("A")], &selected)
                .keys
                .is_empty()
        );
        assert_eq!(
            reconcile(&[photo(&["A"])], &[key("A")], &selected).keys,
            vec![key("A")]
        );
    }

    fn catalog_model(merged: bool) -> Model {
        use crate::domain::{LibrarySnapshot, PhotoResource, ResourceRole, ScanAccess};
        let mut model = Model {
            ready: true,
            state: crate::app::SavedLibrary {
                apple_scope: "generated".into(),
                schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
                ..Default::default()
            },
            ..Default::default()
        };
        let assets = ["A", "B"]
            .into_iter()
            .enumerate()
            .map(|(index, id)| {
                let mut asset = photo(&[id]).assets.remove(0);
                asset.resources = vec![PhotoResource {
                    id: "original".into(),
                    name: format!("{id}.jpg"),
                    role: ResourceRole::Image,
                    sha1: Some(format!("{:040x}", if merged { 1 } else { index + 1 })),
                    bytes: Some(20),
                }];
                asset
            })
            .collect();
        model.state.snapshots = vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "generated".into(),
            scanned_at: Some(0.0),
            assets,
            access: ScanAccess::Full,
        }];
        model
    }

    fn publish_catalog(model: &mut Model, merged: bool) {
        use crux_core::App;
        let mut state = model.state.clone();
        state.snapshots = catalog_model(merged).state.snapshots;
        let _ = Suwop.update(
            Event::Finished {
                state,
                session: None,
                status: "generated update".into(),
                error: None,
                preview_to_select: None,
            },
            model,
        );
    }

    #[test]
    fn real_reducer_persists_merge_retirement_before_immediate_split_and_revocation()
    -> Result<(), String> {
        use crux_core::App;
        let mut model = catalog_model(false);
        let a = Suwop
            .view(&model)
            .photos
            .into_iter()
            .find(|p| p.assets[0].key == key("A"))
            .ok_or("generated A missing")?;
        let _ = Suwop.update(
            Event::ToggleGalleryPhoto {
                photo_id: photo_id(&a),
            },
            &mut model,
        );
        assert_eq!(Suwop.view(&model).gallery_selection.keys, vec![key("A")]);
        publish_catalog(&mut model, true);
        assert!(
            model.gallery_selection_keys.is_empty(),
            "Retirement must persist during the merge event itself"
        );
        publish_catalog(&mut model, false);
        assert!(Suwop.view(&model).gallery_selection.keys.is_empty());
        let ids = Suwop.view(&model).photos.iter().map(photo_id).collect();
        let _ = Suwop.update(
            Event::SelectGalleryPhotos {
                photo_ids: ids,
                selected: true,
            },
            &mut model,
        );
        assert_eq!(
            model.gallery_selection_keys,
            BTreeSet::from([key("A"), key("B")])
        );
        let _ = Suwop.update(Event::AppleChanged, &mut model);
        assert!(model.gallery_selection_keys.is_empty());
        publish_catalog(&mut model, false);
        assert!(
            Suwop.view(&model).gallery_selection.keys.is_empty(),
            "Regrant cannot restore a prior selection"
        );
        Ok(())
    }

    #[test]
    fn real_reducer_keeps_hidden_selection_and_orders_toggles_without_expanding_stale_select_all() {
        use crux_core::App;
        let mut model = catalog_model(false);
        let ids: Vec<_> = Suwop.view(&model).photos.iter().map(photo_id).collect();
        let _ = Suwop.update(
            Event::SelectGalleryPhotos {
                photo_ids: vec![ids[0].clone()],
                selected: true,
            },
            &mut model,
        );
        let selected = model.gallery_selection_keys.clone();
        let _ = Suwop.update(
            Event::Browse {
                options: crate::browser::BrowserOptions {
                    query: "no-matching-photo".into(),
                    sort: crate::browser::PhotoSort::Name,
                    ..Default::default()
                },
            },
            &mut model,
        );
        let hidden = Suwop.view(&model);
        assert!(hidden.browser.photo_ids.is_empty());
        assert_eq!(
            hidden
                .gallery_selection
                .keys
                .into_iter()
                .collect::<BTreeSet<_>>(),
            selected
        );
        let _ = Suwop.update(
            Event::ToggleGalleryPhoto {
                photo_id: ids[0].clone(),
            },
            &mut model,
        );
        let _ = Suwop.update(
            Event::ToggleGalleryPhoto {
                photo_id: ids[0].clone(),
            },
            &mut model,
        );
        assert_eq!(
            model.gallery_selection_keys, selected,
            "Two queued clicks toggle twice in Rust"
        );
        publish_catalog(&mut model, true);
        let _ = Suwop.update(
            Event::SelectGalleryPhotos {
                photo_ids: ids,
                selected: true,
            },
            &mut model,
        );
        assert!(
            model.gallery_selection_keys.is_empty(),
            "IDs captured before merge must not select the new group"
        );
    }

    fn benchmark_model(count: u32) -> Model {
        use crate::domain::{LibrarySnapshot, PhotoResource, ResourceRole, ScanAccess};
        let assets = (0..count)
            .map(|index| {
                let mut asset = photo(&[&format!("generated-{index:06}")]).assets.remove(0);
                asset.captured_at = Some(1_600_000_000.0 + f64::from(index) * 86_400.0);
                asset.latitude = Some(35.0 + f64::from(index % 90) * 0.01);
                asset.longitude = Some(139.0 + f64::from(index % 100) * 0.01);
                asset.resources = vec![PhotoResource {
                    id: "original".into(),
                    name: asset.name.clone(),
                    role: ResourceRole::Image,
                    sha1: Some(format!("{index:040x}")),
                    bytes: Some(2048),
                }];
                asset
            })
            .collect();
        Model {
            ready: true,
            state: crate::app::SavedLibrary {
                apple_scope: "generated".into(),
                schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
                snapshots: vec![LibrarySnapshot {
                    provider: Provider::Apple,
                    scope: "generated".into(),
                    scanned_at: Some(0.0),
                    assets,
                    access: ScanAccess::Full,
                }],
                ..Default::default()
            },
            ..Default::default()
        }
    }

    fn measure_publication(
        model: &mut Model,
        event: Option<Event>,
    ) -> Result<(crate::app::ViewModel, serde_json::Value), serde_json::Error> {
        use crux_core::App;
        let start = std::time::Instant::now();
        if let Some(event) = event {
            let _ = Suwop.update(event, model);
        }
        let view = Suwop.view(model);
        let bytes = serde_json::to_vec(&view)?;
        let size = bytes.len();
        std::hint::black_box(bytes);
        let measurement = serde_json::json!({"milliseconds": start.elapsed().as_secs_f64() * 1000.0, "publication_bytes": size});
        Ok((view, measurement))
    }

    /// Opt-in probe: build once, then execute under the OS peak-RSS tool in a
    /// fresh process. This measures Core publication rather than Swift rendering.
    #[test]
    #[ignore = "generated 10k/100k catalog measurement; run in an independent process"]
    fn generated_catalog_publication_benchmark() -> Result<(), Box<dyn std::error::Error>> {
        use std::io::Write as _;
        let count = std::env::var("SUWOP_BENCH_PHOTOS")
            .ok()
            .map(|value| value.parse::<u32>())
            .transpose()?
            .unwrap_or(10_000);
        assert!([10_000, 100_000].contains(&count));
        let fixture_start = std::time::Instant::now();
        let mut model = benchmark_model(count);
        let fixture_ms = fixture_start.elapsed().as_secs_f64() * 1000.0;
        let (first, publication) = measure_publication(&mut model, None)?;
        assert_eq!(first.photos.len(), usize::try_from(count)?);
        let selected_ids: Vec<_> = first.photos.iter().take(100).map(photo_id).collect();
        drop(first);
        let (search, search_measurement) = measure_publication(
            &mut model,
            Some(Event::Browse {
                options: crate::browser::BrowserOptions {
                    query: "generated-000".into(),
                    ..Default::default()
                },
            }),
        )?;
        let matched = search.browser.photo_ids.len();
        drop(search);
        let (sorted, sort_measurement) = measure_publication(
            &mut model,
            Some(Event::Browse {
                options: crate::browser::BrowserOptions {
                    sort: crate::browser::PhotoSort::Name,
                    ..Default::default()
                },
            }),
        )?;
        assert_eq!(sorted.browser.photo_ids.len(), usize::try_from(count)?);
        drop(sorted);
        let (selected, selection_measurement) = measure_publication(
            &mut model,
            Some(Event::SelectGalleryPhotos {
                photo_ids: selected_ids,
                selected: true,
            }),
        )?;
        assert_eq!(selected.gallery_selection.keys.len(), 100);
        drop(selected);
        let (organized, organization_measurement) = measure_publication(
            &mut model,
            Some(Event::BrowseOrganization {
                reference: crate::organization::OrganizationDate {
                    year: 2026,
                    month: 10,
                    day: 28,
                    time_zone: "Asia/Tokyo".into(),
                },
            }),
        )?;
        writeln!(
            std::io::stdout(),
            "GENERATED_CATALOG_PERFORMANCE {}",
            serde_json::json!({
                "photos": count, "profile": if cfg!(debug_assertions) { "debug" } else { "release" },
                "scope": "Rust full view plus JSON encoding; no Swift decode/render/native IO",
                "cache": "fresh process first publication, then warm same-model scenarios",
                "fixture_ms": fixture_ms, "first_publication": publication,
                "search_update_and_publication": search_measurement, "search_matches": matched,
                "sort_update_and_publication": sort_measurement,
                "selection_update_and_publication": selection_measurement, "selected_keys": 100,
                "organization_update_and_publication": organization_measurement,
                "place_groups": organized.organization.places.len(),
            })
        )?;
        Ok(())
    }
}
