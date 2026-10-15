//! Exact selected-resource product control, not reverse-graph independence.
use super::*;

pub(in super::super) async fn ordinary_linked_setup(
    ctx: &Context,
    address: &str,
    key: &str,
    directory: &Path,
) -> Result<(Session, String, Vec<String>), String> {
    let session = setup_named(ctx, address, key, "ordinary-linked").await?;
    let graph = graph(ctx, &session, directory).await?;
    let mut known = Vec::new();
    for title in ["Selected motion first", "Selected motion second"] {
        let album = session.ordinary.create_album(ctx, title).await?;
        session
            .ordinary
            .change_album_members(
                ctx,
                &album.id,
                &[graph.motion.clone(), graph.other_parent.clone()],
                true,
            )
            .await?;
        known.push(album.id);
    }
    visibility(ctx, &session, &[&graph.parent], "locked").await?;
    visibility(ctx, &session, &[&graph.motion], "timeline").await?;
    assert_eq!(
        detail(ctx, &session, &graph.parent).await?["visibility"],
        "locked"
    );
    assert_eq!(
        detail(ctx, &session, &graph.other_parent).await?["visibility"],
        "timeline"
    );
    preserve_originals(ctx, &session, &graph, directory).await?;
    std::fs::write(
        directory.join("linked-control.json"),
        serde_json::to_vec(&json!({"graph":graph,"albums":known}))
            .map_err(|_| "linked controls encode")?,
    )
    .map_err(|_| "linked controls write")?;
    // No elevated credential escapes this setup. Product uses only the API key.
    session.json(ctx, "auth/session/lock", "POST", None).await?;
    session.json(ctx, "auth/logout", "POST", None).await?;
    Ok((session.ordinary, graph.motion, known))
}
fn controls(directory: &Path) -> Result<(Graph, Vec<String>), String> {
    let raw: Value = serde_json::from_slice(
        &std::fs::read(directory.join("linked-control.json"))
            .map_err(|_| "linked controls read")?,
    )
    .map_err(|_| "linked controls decode")?;
    Ok((
        serde_json::from_value(raw["graph"].clone()).map_err(|_| "linked graph")?,
        serde_json::from_value(raw["albums"].clone()).map_err(|_| "linked albums")?,
    ))
}
pub(in super::super) fn ordinary_linked_controls(
    agent: &ureq::Agent,
    session: &Session,
    directory: &Path,
) -> Result<(), String> {
    let (graph, _) = controls(directory)?;
    let parent: HttpResponse = serde_json::from_value(execute(
        agent,
        &session.request(&format!("assets/{}", graph.parent), "GET", None),
    )?)
    .map_err(|_| "linked parent response")?;
    assert_eq!(
        parent.status, 400,
        "known locked parent remains unavailable to ordinary authority"
    );
    let other: HttpResponse = serde_json::from_value(execute(
        agent,
        &session.request(&format!("assets/{}", graph.other_parent), "GET", None),
    )?)
    .map_err(|_| "linked other parent response")?;
    assert_eq!(other.status, 200);
    assert_eq!(other.body["visibility"], "timeline");
    assert_eq!(other.body["livePhotoVideoId"], graph.motion);
    Ok(())
}
pub(in super::super) fn verify_ordinary_linked(
    agent: &ureq::Agent,
    ordinary: &Session,
    directory: &Path,
) -> Result<(), String> {
    let ordinary = ordinary.clone();
    let directory = directory.to_path_buf();
    let mut command = Command::<Effect, Event>::new(move |ctx| async move {
        let result = verify(&ctx, ordinary, &directory).await;
        ctx.send_event(Event::Finished {
            state: SavedLibrary::default(),
            session: None,
            status: String::new(),
            error: result.err(),
            preview_to_select: None,
        });
    });
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            break;
        }
        for Effect::Io(mut effect) in effects {
            let result = match &effect.operation {
                ShellOperation::Http(request) => execute(agent, request),
                _ => Err("unexpected linked verification effect".into()),
            };
            effect
                .resolve(live_response(result))
                .map_err(|_| "linked verification resolve")?;
        }
    }
    match command.events().last() {
        Some(Event::Finished { error: None, .. }) => Ok(()),
        Some(Event::Finished {
            error: Some(error), ..
        }) => Err(error),
        _ => Err("linked verification completion".into()),
    }
}
async fn verify(ctx: &Context, ordinary: Session, directory: &Path) -> Result<(), String> {
    // A new fixture-only session verifies the locked parent after product ends.
    let email = format!("ordinary-linked-{}@example.invalid", std::process::id());
    let mut login = ordinary.request(
        "auth/login",
        "POST",
        Some(json!({"email":email,"password":"GraphFixtureOnly123!"})),
    );
    login.headers.remove("x-api-key");
    let body = checked(ctx, login).await?;
    let session = Elevated {
        ordinary,
        token: body["accessToken"]
            .as_str()
            .ok_or("linked verification token")?
            .into(),
    };
    session.unlock(ctx).await?;
    let (graph, known) = controls(directory)?;
    let result = async {
        assert_eq!(
            detail(ctx, &session, &graph.parent).await?["visibility"],
            "locked"
        );
        assert_eq!(
            detail(ctx, &session, &graph.other_parent).await?["visibility"],
            "timeline"
        );
        assert_eq!(
            detail(ctx, &session, &graph.motion).await?["visibility"],
            "timeline"
        );
        for parent in [&graph.parent, &graph.other_parent] {
            assert_eq!(
                detail(ctx, &session, parent).await?["livePhotoVideoId"],
                graph.motion
            );
        }
        for id in [&graph.motion, &graph.other_parent] {
            assert_membership(ctx, &session, id, &known, true).await?;
        }
        preserve_originals(ctx, &session, &graph, directory).await
    }
    .await;
    let lock = session.json(ctx, "auth/session/lock", "POST", None).await;
    let logout = session.json(ctx, "auth/logout", "POST", None).await;
    result?;
    lock?;
    logout?;
    Ok(())
}
