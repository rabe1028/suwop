//! Product effects only. Setup and independent server observations never enter this trace.
use super::*;
use suwop_core::protection::ProtectionScenePhase;
pub(super) struct RecoveryShell<'a> {
    agent: &'a ureq::Agent,
    directory: &'a Path,
    endpoint: &'a str,
    pub trace: Vec<String>,
    pub inspect_only: Option<String>,
}
impl<'a> RecoveryShell<'a> {
    pub fn new(
        agent: &'a ureq::Agent,
        directory: &'a Path,
        session: &'a Session,
        raw: &Value,
    ) -> Result<Self, String> {
        let host = Self {
            agent,
            directory,
            endpoint: &session.endpoint,
            trace: vec![],
            inspect_only: None,
        };
        host.save(raw)?;
        Ok(host)
    }
    fn save(&self, value: &Value) -> Result<(), String> {
        let temporary = self.directory.join("journal.tmp");
        std::fs::write(
            &temporary,
            serde_json::to_vec(value).map_err(|_| "journal encode")?,
        )
        .map_err(|_| "journal write")?;
        std::fs::rename(temporary, self.directory.join("journal.json"))
            .map_err(|_| "journal rename".into())
    }
    pub fn raw(&self) -> Result<Value, String> {
        serde_json::from_slice(
            &std::fs::read(self.directory.join("journal.json")).map_err(|_| "journal read")?,
        )
        .map_err(|_| "raw journal decode".into())
    }
    pub fn operation(&self) -> Result<Value, String> {
        let raw = self.raw()?;
        let operations = raw["immichVisibilityOperations"]
            .as_array()
            .ok_or("operations")?;
        assert_eq!(operations.len(), 1);
        Ok(operations[0].clone())
    }
    pub fn reset_trace(&mut self) {
        self.trace.clear();
    }
    pub fn assert_inspect_trace(&self) {
        assert!(self.inspect_only.is_some());
        assert_eq!(
            self.trace,
            [
                "GET auth/status",
                "GET selected-detail",
                "GET auth/status",
                "persist"
            ]
        );
    }
    pub fn authenticate(
        &mut self,
        core: &Core<Suwop>,
        email: &str,
        grant: &str,
    ) -> Result<(), String> {
        self.run(
            core,
            Event::ImmichLockedSceneChanged {
                scene_id: SCENE.into(),
                phase: ProtectionScenePhase::Active,
            },
        )?;
        self.run(core, open(email, grant))?;
        assert_eq!(
            core.view().immich_locked_view.grant_id.as_deref(),
            Some(grant)
        );
        Ok(())
    }
    pub fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        while !effects.is_empty() {
            let Effect::Io(mut request) = effects.remove(0);
            let response = self.respond(&request.operation)?;
            effects.extend(
                core.resolve(&mut request, live_response(Ok(response)))
                    .map_err(|_| "recovery resolve")?,
            );
        }
        assert!(!core.view().busy);
        if core.view().error.is_some() {
            return Err("unexpected recovery core error".into());
        }
        Ok(())
    }
    fn respond(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) => self.http(request),
            ShellOperation::ReadState => {
                self.trace.push("readState".into());
                self.raw()
            }
            ShellOperation::Persist(raw) => {
                self.trace.push("persist".into());
                self.save(&serde_json::to_value(raw).map_err(|_| "persist encode")?)?;
                Ok(Value::Null)
            }
            ShellOperation::ReleaseImmichLockedImage { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. } => {
                self.trace.push("release-image".into());
                Ok(Value::Null)
            }
            ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. } => {
                self.trace.push("schedule".into());
                Ok(Value::Null)
            }
            _ => Err(
                "unexpected recovery effect (confirmation/media/provider mutation forbidden)"
                    .into(),
            ),
        }
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        let prefix = format!("{}/", self.endpoint);
        let path = request
            .url
            .strip_prefix(&prefix)
            .ok_or("unexpected recovery origin")?;
        if let Some(selected) = &self.inspect_only {
            assert_eq!(request.method, "GET");
            assert!(
                request
                    .headers
                    .get("Authorization")
                    .is_some_and(|v| v.starts_with("Bearer "))
            );
            assert!(!request.headers.contains_key("x-api-key"));
            let label = if path == "auth/status" {
                "GET auth/status"
            } else if path == format!("assets/{selected}") {
                "GET selected-detail"
            } else {
                return Err("Inspect read outside exact selected/status whitelist".into());
            };
            self.trace.push(label.into());
        } else {
            let allowed = matches!(
                (request.method.as_str(), path),
                ("GET", "server/features" | "users/me" | "auth/status")
                    | (
                        "POST",
                        "auth/login"
                            | "auth/session/unlock"
                            | "auth/session/lock"
                            | "auth/logout"
                            | "search/metadata"
                    )
            ) || (request.method == "GET"
                && path.starts_with("assets/")
                && !path.contains('?')
                && !path[7..].contains('/'));
            if !allowed {
                return Err("unexpected auth/reload HTTP (provider writes/media forbidden)".into());
            }
            self.trace.push(if path.starts_with("assets/") {
                "GET auth-list-detail".into()
            } else {
                format!("{} {path}", request.method)
            });
        }
        let response = execute(self.agent, request)?;
        let parsed: HttpResponse =
            serde_json::from_value(response.clone()).map_err(|_| "real response decode")?;
        immich::check_status(parsed.status)?;
        Ok(response)
    }
}
