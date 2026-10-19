//! Independent fixture writes are never mixed with product effect traces.
use super::*;
pub(super) fn place_motion(
    agent: &ureq::Agent,
    f: &Fixture,
    placement: &str,
) -> Result<(), String> {
    let response: HttpResponse = serde_json::from_value(execute(
        agent,
        &f.elevated.request(
            &format!("assets/{}", f.motion),
            "PUT",
            Some(json!({"visibility":placement})),
        ),
    )?)
    .map_err(|_| "external motion setup")?;
    assert_eq!(response.status, 200);
    assert_eq!(response.body["id"], f.motion);
    assert_eq!(response.body["visibility"], placement);
    Ok(())
}
pub(super) fn drift_and_close(agent: &ureq::Agent, f: &Fixture, root: &Path) -> Result<(), String> {
    place_motion(agent, f, "hidden")?;
    for close in [false, true] {
        let directory = root.join(if close {
            "late-close"
        } else {
            "post-read-drift"
        });
        std::fs::create_dir(&directory).map_err(|_| "pair negative directory")?;
        let before = f.observe(agent, &directory)?;
        save_observation(&directory, "observer-before.json", &before)?;
        let (core, mut host) = start(agent, f, &directory)?;
        let effects = host.request(&core)?;
        let (held, remaining) = host.hold_read(&core, effects)?;
        let Effect::Io(mut request) = held;
        let ShellOperation::ReadImmichLockedLiveMember { read } = &request.operation else {
            return Err("pair held read".into());
        };
        let result = transport::download(&mut host, read)?;
        assert_eq!(host.roles, [ImmichLockedLiveRole::Parent]);
        if close {
            host.run(&core, Event::CloseImmichLocked)?;
        } else {
            f.set_visibility(agent, "timeline")?;
            std::fs::write(directory.join("external-drift.json"),b"{\"externalFixtureWrite\":\"P timeline after real parent original before product completion\"}").map_err(|_|"drift evidence")?;
        }
        let next = core
            .resolve(&mut request, live_response(Ok(result)))
            .map_err(|_| "late pair resolve")?;
        host.drain(&core, remaining)?;
        host.drain(&core, next)?;
        assert!(core.view().immich_locked_view.live.is_none());
        assert_eq!((host.prepares, host.publications), (0, 0));
        assert_eq!(
            host.roles.len(),
            1,
            "drift must prevent second original GET"
        );
        host.assert_released();
        host.save(if close {
            "late-close"
        } else {
            "post-read-drift"
        })?;
        if !close {
            f.set_visibility(agent, "locked")?;
            host.run(&core, Event::CloseImmichLocked)?;
        }
        let after = f.observe(agent, &directory)?;
        save_observation(&directory, "observer-after.json", &after)?;
        assert_eq!(after, before);
    }
    Ok(())
}

pub(super) fn save_observation(directory: &Path, name: &str, value: &Value) -> Result<(), String> {
    use std::io::Write;
    let bytes = serde_json::to_vec_pretty(value).map_err(|_| "observer encode")?;
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(directory.join(name))
        .map_err(|_| "observer evidence exists or unavailable")?;
    file.write_all(&bytes)
        .map_err(|_| "observer evidence write".into())
}
