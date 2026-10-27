use crux_core::Command;
use serde_json::{Value, json};
use std::collections::VecDeque;
use suwop_core::{
    albums::AlbumDateOrder,
    app::{Effect, Event, SavedLibrary, ShellOperation, ShellResponse},
    immich::{HttpRequest, HttpResponse, Session, Version},
};
const OWNER: &str = "22222222-2222-4222-8222-222222222222";
const OTHER: &str = "33333333-3333-4333-8333-333333333333";
const ALBUM: &str = "11111111-1111-4111-8111-111111111111";
fn album(owner: &str, order: &str) -> Value {
    json!({"id":ALBUM,"albumName":"album","ownerId":owner,"order":order,"albumUsers":[{"role":"owner","user":{"id":owner}},{"role":"viewer","user":{"id":OWNER}}]})
}
fn run(read: bool, bodies: Vec<Value>) -> Result<(Vec<HttpRequest>, Option<String>), String> {
    let session = Session {
        endpoint: "https://example/api".into(),
        key: "fixture".into(),
        user_id: OWNER.into(),
        scope: "scope".into(),
        version: Version {
            major: 3,
            minor: 3,
            patch: 3,
        },
        ordinary_content_guard: None,
        ordinary_content_context: None,
    };
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = if read {
            session.album_members(&ctx, ALBUM).await.map(|_| ())
        } else {
            session
                .set_album_date_order(&ctx, ALBUM, AlbumDateOrder::Asc)
                .await
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
    let mut seen = vec![];
    loop {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            break;
        }
        for effect in effects {
            let Effect::Io(mut request) = effect;
            let ShellOperation::Http(http) = &request.operation else {
                return Err("unexpected native mutation".into());
            };
            seen.push(http.clone());
            let value = serde_json::to_value(HttpResponse {
                status: 200,
                body: bodies.pop_front().ok_or("missing fixture")?,
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
        return Err("unexpected result".into());
    };
    Ok((seen, error))
}

#[test]
fn date_order_is_saved_and_verified_without_asset_metadata_writes() -> Result<(), String> {
    let (seen, error) = run(
        false,
        vec![album(OWNER, "desc"), Value::Null, album(OWNER, "asc")],
    )?;
    assert!(error.is_none());
    let writes: Vec<_> = seen.iter().filter(|r| r.method != "GET").collect();
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].method, "PATCH");
    assert!(writes[0].url.ends_with(&format!("/albums/{ALBUM}")));
    assert_eq!(writes[0].body, Some(json!({"order":"asc"})));
    assert!(
        run(
            false,
            vec![album(OWNER, "desc"), Value::Null, album(OWNER, "desc")]
        )?
        .1
        .is_some()
    );
    Ok(())
}

#[test]
fn shared_album_read_does_not_grant_owner_write_or_asset_ownership() -> Result<(), String> {
    let (seen, error) = run(
        true,
        vec![
            album(OTHER, "desc"),
            json!({"assets":{"items":[],"nextCursor":null}}),
        ],
    )?;
    assert!(error.is_none());
    let search = seen
        .iter()
        .find(|r| r.url.ends_with("/search/metadata"))
        .and_then(|r| r.body.as_ref())
        .ok_or("missing search request")?;
    assert!(search.get("order").is_none());
    assert_eq!(
        search["orderBy"],
        json!({"field":"fileCreatedAt","direction":"desc"})
    );
    assert_eq!(seen.len(), 2);
    assert!(
        seen.iter()
            .all(|r| r.method == "GET" || r.url.ends_with("/search/metadata"))
    );
    let (seen, error) = run(false, vec![album(OTHER, "desc")])?;
    assert!(error.is_some());
    assert!(seen.iter().all(|r| r.method == "GET"));
    let mut ungranted = album(OTHER, "desc");
    ungranted["albumUsers"] = json!([]);
    assert!(run(true, vec![ungranted])?.1.is_some());
    Ok(())
}
