//! Deterministic external single-P changes at real transport/completion boundaries.
use super::*;
#[derive(Clone, Copy)]
enum Point {
    PreRead,
    PostRead,
    PostPublish,
}
pub(super) fn exercise(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    agent: &ureq::Agent,
    fixture: &Fixture,
    directory: &Path,
    locked: &Value,
    visibility: &str,
) -> Result<(), String> {
    for (point, id, label) in [
        (
            Point::PreRead,
            "55555555-5555-4555-8555-555555555555",
            "pre-read-drift",
        ),
        (
            Point::PostRead,
            "66666666-6666-4666-8666-666666666666",
            "post-stage-drift",
        ),
        (
            Point::PostPublish,
            "77777777-7777-4777-8777-777777777777",
            "post-publish-drift",
        ),
    ] {
        fixture.set_visibility(agent, visibility)?;
        refresh(host, core)?;
        assert_readonly(core, &fixture.key(), visibility)?;
        host.trace.clear();
        host.start(core, image(&fixture.key(), Kind::Preview, id));
        let effect = hold(host, core, point, &fixture.parent)?;
        let result = if matches!(point, Point::PreRead) {
            None
        } else {
            let Effect::Io(request) = &effect;
            Some(host.respond(core, &request.operation)?)
        };
        assert!(
            !core
                .view()
                .ordinary_selected_images
                .iter()
                .any(|a| a.request_id == id)
        );
        let stage_id = result
            .as_ref()
            .and_then(|v| v["stagedID"].as_str())
            .map(str::to_owned);
        let released = host.released.len();
        fixture.set_visibility(
            agent,
            if visibility == "timeline" {
                "archive"
            } else {
                "timeline"
            },
        )?;
        let value = if let Some(value) = result {
            value
        } else {
            let Effect::Io(request) = &effect;
            host.respond(core, &request.operation)?
        };
        host.resolve(core, effect, value)?;
        host.drain(core)?;
        assert!(
            core.view()
                .ordinary_selected_images
                .iter()
                .all(|a| a.key != fixture.key())
        );
        assert!(
            core.view()
                .ordinary_selected_presentation
                .iter()
                .all(|p| p.key != fixture.key())
        );
        assert_eq!(host.stage_count(), 0);
        assert!(!host.trace.iter().any(|s| s == "persist"));
        if let Some(stage) = stage_id {
            assert_eq!(
                host.released[released..]
                    .iter()
                    .filter(|id| **id == stage)
                    .count(),
                1
            );
        } else {
            assert!(host.trace.iter().all(|s| !s.starts_with("read-staged-")));
        }
        if matches!(point, Point::PostRead) {
            assert!(!host.trace.iter().any(|s| s == "publish-staged"));
        }
        assert_journals(locked, &host.raw()?);
        write(
            directory,
            label,
            &json!({"effects":host.trace,"approved":false,"stageCount":host.stage_count(),"externalChange":"selected visibility only, separate fixture authority"}),
        )?;
    }
    Ok(())
}
fn hold(
    host: &mut Shell<'_>,
    core: &Core<Suwop>,
    point: Point,
    parent: &str,
) -> Result<Effect, String> {
    while !host.pending.is_empty() {
        let effect = host.pending.remove(0);
        let Effect::Io(request) = &effect;
        let stop = match (&request.operation, point) {
            (ShellOperation::Http(http), Point::PreRead) => {
                http.method == "GET" && http.url.ends_with(&format!("/assets/{parent}"))
            }
            (ShellOperation::ReadOrdinarySelectedImage { .. }, Point::PostRead)
            | (ShellOperation::PublishOrdinarySelectedImage { .. }, Point::PostPublish) => true,
            _ => false,
        };
        if stop {
            return Ok(effect);
        }
        let value = host.respond(core, &request.operation)?;
        host.resolve(core, effect, value)?;
    }
    Err("required real selected read boundary was not reached".into())
}
