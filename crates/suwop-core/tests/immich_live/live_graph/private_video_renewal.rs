//! Actual server heartbeat identity/status; native CAS and preparation remain explicit mocks.
use super::*;
fn hold_read(host: &mut Shell<'_>, core: &Core<Suwop>) -> Result<Effect, String> {
    while !host.pending.is_empty() {
        let effect = host.pending.remove(0);
        let Effect::Io(native) = &effect;
        if matches!(
            native.operation,
            ShellOperation::ReadImmichLockedVideo { .. }
        ) {
            return Ok(effect);
        }
        let value = host.respond(core, &native.operation)?;
        host.resolve(core, effect, value)?;
    }
    Err("held renewal original missing".into())
}
pub(super) fn exercise(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<(), String> {
    let directory = root.join("two-renewals-real-session");
    std::fs::create_dir(&directory).map_err(|_| "renewal directory")?;
    let (core, mut host, journal) = start(agent, fixture, &directory)?;
    let grant = id(70);
    authenticate(&mut host, &core, &grant)?;
    let request_id = id(71);
    host.start(&core, request(&core, &fixture.video, &grant, &request_id)?);
    let read = hold_read(&mut host, &core)?;
    let first = core
        .view()
        .immich_locked_view
        .video_acquisition
        .ok_or("initial acquisition")?;
    for expected in 2..=3 {
        let view = core.view().immich_locked_view;
        host.run(
            &core,
            Event::CheckImmichLockedSession {
                grant_id: grant.clone(),
                generation: view.generation,
                lease_id: view.lease_id,
            },
        )?;
        let current = core
            .view()
            .immich_locked_view
            .video_acquisition
            .ok_or("renewed acquisition")?;
        assert_eq!(current.lease.lease_id, expected);
        assert_eq!(current.acknowledged_lease_id, expected);
        assert_eq!(current.staged_id, first.staged_id);
        assert_eq!(current.pending.key, first.pending.key);
    }
    let Effect::Io(native) = &read;
    let value = host.respond(&core, &native.operation)?;
    host.resolve(&core, read, value)?;
    host.drain(&core)?;
    host.assert_approved(&core, &request_id)?;
    assert!(core.view().immich_locked_view.video_acquisition.is_none());
    assert_eq!(host.raw(), &journal);
    write_json(
        &directory.join("renewal-result.json"),
        &json!({"successorLeaseIDs":[2,3],"effects":host.trace,"nativeCAS":"mock; no monotonic native timing claim","nativePreparation":"mock; no AV motion claim","journalUnchanged":true}),
    )?;
    host.run(
        &core,
        Event::StopImmichLockedVideo {
            scene_id: SCENE.into(),
            request_id,
            retry_cleanup: true,
        },
    )?;
    assert_eq!(host.stage_count(), 0);
    close(&mut host, &core)
}
