use crux_core::Core;
use serde_json::{Value, json};
use std::collections::VecDeque;
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{LibrarySnapshot, Provider, ScanAccess},
    immich::{
        Asset, HttpRequest, HttpResponse, Session, Version, date_string, endpoint, safe_name,
        same_origin, valid_id,
    },
};
const USER: &str = "22222222-2222-4222-8222-222222222222";
const ID: &str = "11111111-1111-4111-8111-111111111111";
fn asset_json() -> Value {
    json!({"id":ID,"ownerId":USER,"type":"IMAGE","originalFileName":"raw.dng","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","isFavorite":false,"isOffline":false,"isTrashed":false,"isEdited":false,"libraryId":null})
}

#[test]
fn capture_dates_keep_subseconds_in_both_directions() -> Result<(), String> {
    for date in [1_765_000_000.123_456, 35.999_999_999, -0.25, 10.0] {
        let mut json = asset_json();
        json["fileCreatedAt"] = Value::from(date_string(date));
        let asset: Asset = serde_json::from_value(json).map_err(|e| e.to_string())?;
        let captured = asset
            .record("scope", None, Some(&[]))
            .captured_at
            .ok_or("missing capture date")?;
        assert!((captured - date).abs() < 0.000_001);
    }
    assert!(date_string(f64::NAN).is_empty());
    Ok(())
}
fn scan(
    version: Version,
    pages: Vec<Value>,
) -> Result<(Vec<HttpRequest>, suwop_core::app::ViewModel), String> {
    let (requests, view, _) = scan_with_peak(version, pages)?;
    Ok((requests, view))
}
fn scan_with_peak(
    version: Version,
    pages: Vec<Value>,
) -> Result<(Vec<HttpRequest>, suwop_core::app::ViewModel, usize), String> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "test".into(),
        user_id: USER.into(),
        scope: "test".into(),
        version,
    };
    let core = Core::new_with(
        Suwop,
        Model {
            state: SavedLibrary {
                schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: "apple".into(),
                ..SavedLibrary::default()
            },
            session: Some(session),
            ready: true,
            ..Model::default()
        },
    );
    let mut pages: VecDeque<_> = pages.into();
    let mut seen = Vec::new();
    let mut effects = core.process_event(Event::Refresh {
        permission: false,
        now: 10.0,
    });
    let mut peak = 0;
    let mut saw_partial = false;
    while !effects.is_empty() {
        peak = peak.max(effects.len());
        let Effect::Io(mut request) = effects.remove(0);
        let value = match &request.operation {
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope: scope.clone(),
                assets: vec![],
                access: ScanAccess::Full,
                scanned_at: Some(10.0),
            })
            .map_err(|e| e.to_string())?,
            ShellOperation::Persist(_) => Value::Null,
            ShellOperation::Http(http) => {
                let body = if http.url.ends_with("search/metadata") {
                    pages.pop_front().ok_or("missing response fixture")?
                } else {
                    json!([])
                };
                seen.push(http.clone());
                serde_json::to_value(HttpResponse {
                    status: 200,
                    body,
                    path: None,
                })
                .map_err(|e| e.to_string())?
            }
            _ => return Err("unexpected effect".into()),
        };
        effects.extend(
            core.resolve(
                &mut request,
                ShellResponse {
                    value: Some(value),
                    error: None,
                },
            )
            .map_err(|e| e.to_string())?,
        );
        saw_partial |= assert_partial_preview(&core.view());
    }
    if seen
        .iter()
        .filter(|r| r.url.contains("asset-files?"))
        .count()
        > 32
    {
        assert!(
            saw_partial,
            "must publish before all detail requests resolve"
        );
    }
    Ok((seen, core.view(), peak))
}
fn assert_partial_preview(view: &suwop_core::app::ViewModel) -> bool {
    if let Some(snapshot) = view
        .state
        .snapshots
        .iter()
        .find(|s| s.provider == Provider::Immich && s.access == ScanAccess::Limited)
    {
        assert!(
            view.busy,
            "partial publication must not finish the workflow"
        );
        assert!(!snapshot.completely_indexed());
        assert!(!view.can_transfer);
        assert!(!view.photos.is_empty(), "verified subset must be visible");
        assert!(
            view.preview_choices
                .values()
                .any(|choices| !choices.is_empty())
        );
        return true;
    }
    false
}
#[test]
fn endpoint_and_redirect_validation_preserve_proxy_prefix() -> Result<(), String> {
    assert_eq!(
        endpoint("https://example.com/photos/", false)?,
        "https://example.com/photos/api"
    );
    for bad in [
        "http://example.com",
        "https://user:password@example.com",
        "file:///photos",
        "https://example.com/a/../b",
        "https://example.com/%2e%2e",
        "https://example.com?key=test",
    ] {
        assert!(endpoint(bad, false).is_err());
    }
    assert!(endpoint("http://example.com", true).is_ok());
    assert!(same_origin(
        "https://example.com:443/a",
        "https://EXAMPLE.com/b"
    ));
    assert!(!same_origin(
        "https://example.com/a",
        "http://example.com/b"
    ));
    assert!(valid_id("../assets").is_err());
    assert_eq!(safe_name("/a/unsafe\r\n\".jpg"), "unsafe___.jpg");
    Ok(())
}
#[test]
fn v3_cursor_contract_requests_all_stack_members_and_sidecar_inventory() -> Result<(), String> {
    let (seen, view) = scan(
        Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
        vec![
            json!({"assets":{"items":[asset_json()],"nextCursor":"next"}}),
            json!({"assets":{"items":[asset_json()],"nextCursor":null}}),
        ],
    )?;
    assert!(view.error.is_none());
    assert_eq!(view.state.snapshots[1].assets.len(), 1);
    let body = seen[0].body.as_ref().ok_or("missing request body")?;
    assert_eq!(body["withStacked"], true);
    assert_eq!(
        body["filter"]["visibility"]["in"],
        json!(["timeline", "archive"])
    );
    assert_eq!(
        seen[1].body.as_ref().ok_or("missing cursor")?["cursor"],
        "next"
    );
    assert!(seen.iter().any(|r| r.url.contains("asset-files?assetId=")));
    Ok(())
}
#[test]
fn v2_pagination_scans_timeline_and_archive() -> Result<(), String> {
    let (seen, view) = scan(
        Version {
            major: 2,
            minor: 6,
            patch: 0,
        },
        vec![
            json!({"assets":{"items":[],"nextPage":"2"}}),
            json!({"assets":{"items":[],"nextPage":null}}),
            json!({"assets":{"items":[],"nextPage":null}}),
        ],
    )?;
    assert!(view.error.is_none());
    assert_eq!(seen.len(), 3);
    assert_eq!(
        seen[0].body.as_ref().ok_or("body")?["visibility"],
        "timeline"
    );
    assert_eq!(seen[1].body.as_ref().ok_or("body")?["page"], 2);
    assert_eq!(
        seen[2].body.as_ref().ok_or("body")?["visibility"],
        "archive"
    );
    Ok(())
}
#[test]
fn missing_or_repeated_page_tokens_never_prove_complete_inventory() -> Result<(), String> {
    for pages in [
        vec![json!({"assets":{"items":[]}})],
        vec![
            json!({"assets":{"items":[],"nextCursor":"again"}}),
            json!({"assets":{"items":[],"nextCursor":"again"}}),
        ],
    ] {
        let (_, view) = scan(
            Version {
                major: 3,
                minor: 2,
                patch: 4,
            },
            pages,
        )?;
        assert!(view.error.is_some());
        assert!(
            !view
                .state
                .snapshots
                .iter()
                .any(|s| s.provider == Provider::Immich && s.completely_indexed())
        );
    }
    Ok(())
}
#[test]
fn external_unknown_sidecar_and_missing_live_companion_are_copy_only()
-> Result<(), Box<dyn std::error::Error>> {
    let asset: Asset = serde_json::from_value(asset_json())?;
    assert!(
        !asset
            .record("scope", None, None)
            .deletion_blockers
            .is_empty()
    );
    assert!(
        asset
            .record("scope", None, Some(&[]))
            .deletion_blockers
            .is_empty()
    );
    let mut native = asset_json();
    native["libraryId"] = json!(ID);
    let asset: Asset = serde_json::from_value(native)?;
    assert!(
        !asset
            .record("scope", None, Some(&[]))
            .deletion_blockers
            .is_empty()
    );
    let mut native = asset_json();
    native["livePhotoVideoId"] = json!(ID);
    let asset: Asset = serde_json::from_value(native)?;
    assert!(!asset.record("scope", None, Some(&[])).inventory_complete);
    Ok(())
}

#[test]
fn unexpected_locked_search_members_are_excluded_without_losing_timeline_or_archive()
-> Result<(), String> {
    let mut ordinary = asset_json();
    ordinary["visibility"] = json!("timeline");
    let mut archived = asset_json();
    archived["id"] = json!("33333333-3333-4333-8333-333333333333");
    archived["visibility"] = json!("archive");
    let mut locked = asset_json();
    locked["id"] = json!("44444444-4444-4444-8444-444444444444");
    locked["visibility"] = json!("locked");
    locked["originalFileName"] = json!("PRIVATE-LOCKED.jpg");
    let (_, view) = scan(
        Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
        vec![json!({"assets":{"items":[ordinary,archived,locked],"nextCursor":null}})],
    )?;
    let snapshot = view
        .state
        .snapshots
        .iter()
        .find(|s| s.provider == Provider::Immich)
        .ok_or("missing remote snapshot")?;
    assert_eq!(snapshot.assets.len(), 2);
    assert!(snapshot.assets.iter().any(|a| a.key.asset_id == ID));
    assert!(
        snapshot
            .assets
            .iter()
            .any(|a| a.key.asset_id == "33333333-3333-4333-8333-333333333333")
    );
    assert!(
        !serde_json::to_string(&view)
            .map_err(|e| e.to_string())?
            .contains("PRIVATE-LOCKED")
    );
    Ok(())
}

#[test]
fn hydration_is_bounded_parallel_and_publishes_every_asset() -> Result<(), String> {
    let items: Vec<_> = (1..=65)
        .map(|n| {
            let mut item = asset_json();
            item["id"] = json!(format!("{n:08}-1111-4111-8111-111111111111"));
            item
        })
        .collect();
    let (seen, view, peak) = scan_with_peak(
        Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
        vec![json!({"assets":{"items":items,"nextCursor":null}})],
    )?;
    assert_eq!(peak, 32, "requests must overlap without unbounded fan-out");
    assert!(view.error.is_none(), "{:?}", view.error);
    assert!(!view.busy);
    assert_eq!(view.state.snapshots[1].assets.len(), 65);
    assert_eq!(
        seen.iter()
            .filter(|r| r.url.contains("asset-files?"))
            .count(),
        65
    );
    assert!(!view.status.contains("取得中"));
    Ok(())
}
