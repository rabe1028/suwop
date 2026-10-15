use crux_core::Command;
use serde_json::{Value, json};
use std::collections::VecDeque;
use suwop_core::{
    app::{Effect, Event, SavedLibrary, ShellOperation, ShellResponse},
    immich::{HttpRequest, HttpResponse, Session, Version, albums::AlbumInfo},
};
const USER: &str = "22222222-2222-4222-8222-222222222222";
const ALBUM: &str = "11111111-1111-4111-8111-111111111111";
const PHOTO: &str = "33333333-3333-4333-8333-333333333333";
fn owned() -> Value {
    json!({"id":ALBUM,"albumName":"旅行","albumUsers":[{"role":"owner","user":{"id":USER}}]})
}
fn photo() -> Value {
    json!({"id":PHOTO,"ownerId":USER,"type":"IMAGE","originalFileName":"photo.jpg","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"2026-01-01T00:00:00Z","fileModifiedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","isFavorite":false,"isOffline":false,"isTrashed":false})
}
#[derive(Clone, Copy)]
enum Action {
    Members,
    Add,
    Delete,
}
fn run(action: Action, bodies: Vec<Value>) -> Result<(Vec<HttpRequest>, Option<String>), String> {
    let session = Session {
        ordinary_content_guard: None,
        ordinary_content_context: None,
        endpoint: "https://example/api".into(),
        key: "test".into(),
        user_id: USER.into(),
        scope: "scope".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    };
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = match action {
            Action::Members => session.album_members(&ctx, ALBUM).await.map(|_| ()),
            Action::Add => {
                session
                    .change_album_members(&ctx, ALBUM, &[PHOTO.into()], true)
                    .await
            }
            Action::Delete => session.delete_album(&ctx, ALBUM).await,
        };
        ctx.send_event(Event::Finished {
            preview_to_select: None,
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
        });
    });
    let mut bodies: VecDeque<_> = bodies.into();
    let mut seen = Vec::new();
    loop {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for effect in effects {
            let Effect::Io(mut request) = effect;
            let ShellOperation::Http(http) = &request.operation else {
                return Err("unexpected native effect".into());
            };
            seen.push(http.clone());
            let value = serde_json::to_value(HttpResponse {
                status: 200,
                body: bodies.pop_front().ok_or("missing HTTP fixture")?,
                path: None,
            })
            .map_err(|e| e.to_string())?;
            request
                .resolve(ShellResponse {
                    value: Some(value),
                    error: None,
                })
                .map_err(|e| e.to_string())?;
        }
    }
    let Event::Finished { error, .. } = command.events().last().ok_or("missing result")? else {
        return Err("unexpected final event".into());
    };
    Ok((seen, error))
}

#[test]
fn ownership_requires_unambiguous_matching_owner() -> Result<(), Box<dyn std::error::Error>> {
    let a: AlbumInfo = serde_json::from_value(owned())?;
    assert!(a.owned_by(USER));
    let a: AlbumInfo =
        serde_json::from_value(json!({"id":ALBUM,"albumName":"legacy","ownerId":USER}))?;
    assert!(a.owned_by(USER));
    for body in [
        json!({"id":ALBUM,"albumName":"bad","ownerId":PHOTO,"albumUsers":[{"role":"owner","user":{"id":USER}}]}),
        json!({"id":ALBUM,"albumName":"bad","albumUsers":[{"role":"owner","user":{"id":USER}},{"role":"owner","user":{"id":PHOTO}}]}),
        json!({"id":ALBUM,"albumName":"bad"}),
    ] {
        let a: AlbumInfo = serde_json::from_value(body)?;
        assert!(!a.owned_by(USER));
    }
    Ok(())
}

#[test]
fn member_search_has_album_filter_and_consumes_all_pages() -> Result<(), String> {
    let (seen, error) = run(
        Action::Members,
        vec![
            owned(),
            json!({"assets":{"items":[photo()],"nextCursor":"next"}}),
            json!({"assets":{"items":[],"nextCursor":null}}),
        ],
    )?;
    assert!(error.is_none());
    let body = seen[1].body.as_ref().ok_or("missing search")?;
    assert_eq!(body["filter"]["albumIds"]["any"], json!([ALBUM]));
    assert_eq!(body["filter"]["trashedAt"]["eq"], Value::Null);
    assert_eq!(
        seen[2].body.as_ref().ok_or("missing cursor")?["cursor"],
        "next"
    );
    Ok(())
}

#[test]
fn incomplete_pages_and_duplicate_bulk_receipts_are_not_success() -> Result<(), String> {
    for bodies in [
        vec![owned(), json!({"assets":{"items":[]}})],
        vec![
            owned(),
            json!({"assets":{"items":[],"nextCursor":"same"}}),
            json!({"assets":{"items":[],"nextCursor":"same"}}),
        ],
    ] {
        assert!(run(Action::Members, bodies)?.1.is_some());
    }
    let (_, error) = run(
        Action::Add,
        vec![
            owned(),
            photo(),
            json!([{"id":PHOTO,"success":true},{"id":PHOTO,"success":true}]),
        ],
    )?;
    assert!(error.is_some());
    Ok(())
}

#[test]
fn duplicate_add_is_idempotent_only_after_fresh_membership_verification() -> Result<(), String> {
    for present in [true, false] {
        let (_, error) = run(
            Action::Add,
            vec![
                owned(),
                photo(),
                json!([{"id":PHOTO,"success":false,"error":"duplicate"}]),
                owned(),
                json!({"assets":{"items":if present {vec![photo()]} else {vec![]},"nextCursor":null}}),
            ],
        )?;
        assert_eq!(error.is_none(), present);
    }
    Ok(())
}

#[test]
fn collection_delete_never_issues_asset_delete_or_trash() -> Result<(), String> {
    let (seen, error) = run(Action::Delete, vec![owned(), Value::Null, json!([])])?;
    assert!(error.is_none());
    let writes: Vec<_> = seen.iter().filter(|r| r.method != "GET").collect();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].method, "DELETE");
    assert!(writes[0].url.ends_with(&format!("/albums/{ALBUM}")));
    Ok(())
}
