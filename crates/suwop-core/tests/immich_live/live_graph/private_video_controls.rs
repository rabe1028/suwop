//! Independent ordinary/non-elevated controls, outside the product request trace.
use super::*;
pub(super) fn observe(agent: &ureq::Agent, fixture: &Fixture, root: &Path) -> Result<(), String> {
    let ordinary = &fixture.elevated.ordinary;
    let mut login = ordinary.request(
        "auth/login",
        "POST",
        Some(json!({"email":fixture.email,"password":"GraphFixtureOnly123!"})),
    );
    login.headers.remove("x-api-key");
    let response: HttpResponse =
        serde_json::from_value(execute(agent, &login)?).map_err(|_| "video control login")?;
    assert_eq!(response.status, 201);
    let token = response.body["accessToken"]
        .as_str()
        .ok_or("video control token")?
        .to_owned();
    let bearer = |path: &str| {
        let mut request = ordinary.request(path, "GET", None);
        request.headers.remove("x-api-key");
        request
            .headers
            .insert("Authorization".into(), format!("Bearer {token}"));
        request
    };
    let status: HttpResponse = serde_json::from_value(execute(agent, &bearer("auth/status"))?)
        .map_err(|_| "video control auth status")?;
    assert_eq!(status.status, 200);
    assert_eq!(status.body["isElevated"], false);
    let mut observations = vec![];
    for (role, id) in [
        ("standalone", &fixture.video),
        ("explicit-native-motion", &fixture.motion),
    ] {
        for source in ["ordinary-api-key", "non-elevated-owner"] {
            let path = format!("assets/{id}");
            let request = if source == "ordinary-api-key" {
                ordinary.request(&path, "GET", None)
            } else {
                bearer(&path)
            };
            let detail: HttpResponse = serde_json::from_value(execute(agent, &request)?)
                .map_err(|_| "video control detail")?;
            let path = format!("assets/{id}/original?edited=false");
            let mut request = if source == "ordinary-api-key" {
                ordinary.request(&path, "GET", None)
            } else {
                bearer(&path)
            };
            let file = root.join(format!("control-{role}-{source}.bin"));
            request.download_path = Some(file.to_string_lossy().into_owned());
            let original: HttpResponse = serde_json::from_value(execute(agent, &request)?)
                .map_err(|_| "video control original")?;
            let bytes_match = original.status == 200
                && std::fs::read(&file).map_err(|_| "video control bytes")?
                    == fixture.expected(id)?;
            if role == "standalone" {
                assert_eq!(detail.status, 400);
                assert_eq!(original.status, 404);
                assert!(!bytes_match);
            }
            // Native M retains P/P2 album grants. Raw200 here is a server limitation, not C1 authority.
            observations.push(json!({"selectedRole":role,"authority":source,"detailStatus":detail.status,"originalStatus":original.status,"originalBytesMatch":bytes_match}));
        }
    }
    write_json(
        &root.join("ordinary-and-non-elevated-controls.json"),
        &json!(observations),
    )?;
    let mut logout = bearer("auth/logout");
    logout.method = "POST".into();
    let response: HttpResponse =
        serde_json::from_value(execute(agent, &logout)?).map_err(|_| "video control logout")?;
    assert_eq!(response.status, 200);
    Ok(())
}
