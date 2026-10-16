//! Hold real product effects; external changes never enter the product trace.
use super::*;
#[derive(Clone, Copy, PartialEq, Eq)]
enum Point {
    BeforeAcquisition,
    AfterAcquisition,
    BeforeFinalApproval,
    QuoteAfterClose,
}
pub(super) fn exercise(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<(), String> {
    for (index, point, label) in [
        (0, Point::BeforeAcquisition, "held-pre-metadata"),
        (1, Point::AfterAcquisition, "held-acquired-file"),
        (
            2,
            Point::BeforeFinalApproval,
            "held-prepared-before-final-metadata",
        ),
        (3, Point::QuoteAfterClose, "held-quote-closed-grant"),
    ] {
        fixture.set_visibility(agent, &fixture.video, "locked")?;
        let directory = root.join(label);
        std::fs::create_dir(&directory).map_err(|_| "video drift directory")?;
        let (core, mut host, journal) = start(agent, fixture, &directory)?;
        let grant = id(40 + index);
        authenticate(&mut host, &core, &grant)?;
        let request_id = id(50 + index);
        host.start(&core, request(&core, &fixture.video, &grant, &request_id)?);
        let effect = hold(&mut host, &core, point)?;
        let Effect::Io(native) = &effect;
        let value = host.respond(&core, &native.operation)?;
        assert!(core.view().immich_locked_view.video.is_none());
        if point == Point::QuoteAfterClose {
            close(&mut host, &core)?;
        } else {
            fixture.set_visibility(agent, &fixture.video, "archive")?;
        }
        host.resolve(&core, effect, value)?;
        host.drain(&core)?;
        assert!(core.view().immich_locked_view.video.is_none());
        assert_eq!(host.stage_count(), 0);
        assert_eq!(host.raw(), &journal);
        let reads = host
            .trace
            .iter()
            .filter(|s| s.as_str() == "GET selected-original-stream")
            .count();
        if point == Point::BeforeAcquisition || point == Point::QuoteAfterClose {
            assert_eq!(reads, 0);
        } else {
            assert_eq!(reads, 1);
        }
        if point == Point::AfterAcquisition {
            assert!(!host.trace.iter().any(|s| s == "prepare-hidden-mock"));
        }
        assert!(host.released.iter().all(|id| id == &request_id));
        assert_eq!(
            host.released.len(),
            usize::from(
                point != Point::BeforeAcquisition
                    || host
                        .trace
                        .iter()
                        .any(|s| s == "storage-quote-synthetic-capacity")
            )
        );
        write_json(
            &directory.join("rejected-effects.json"),
            &json!({"effects":host.trace,"fileAndQuoteCount":host.stage_count(),"releasedLeaseIDs":host.released,"approved":false,"externalChange":if point==Point::QuoteAfterClose {"actual product Close before held quote completion"} else {"fixture selected VIDEO visibility only, separate observer authority"}}),
        )?;
        if point != Point::QuoteAfterClose {
            close(&mut host, &core)?;
        }
        fixture.set_visibility(agent, &fixture.video, "locked")?;
    }
    Ok(())
}
fn hold(host: &mut Shell<'_>, core: &Core<Suwop>, point: Point) -> Result<Effect, String> {
    while !host.pending.is_empty() {
        let effect = host.pending.remove(0);
        let Effect::Io(request) = &effect;
        let selected = match (&request.operation, point) {
            (ShellOperation::Http(http), Point::BeforeAcquisition) => {
                http.method == "GET"
                    && http.url
                        == format!(
                            "{}/assets/{}",
                            host.fixture.elevated.ordinary.endpoint, host.fixture.video
                        )
            }
            (ShellOperation::ReadImmichLockedVideo { .. }, Point::AfterAcquisition)
            | (ShellOperation::PrepareImmichLockedVideo { .. }, Point::BeforeFinalApproval)
            | (ShellOperation::InspectImmichLockedVideoStorage { .. }, Point::QuoteAfterClose) => {
                true
            }
            _ => false,
        };
        if selected {
            return Ok(effect);
        }
        let value = host.respond(core, &request.operation)?;
        host.resolve(core, effect, value)?;
    }
    Err("real video held boundary never reached".into())
}
