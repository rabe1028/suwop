//! Native storage/CAS/PhotoKit/publication are labelled mocks; all provider HTTP is real.
use super::*;
pub(super) struct Shell<'a> {
    pub agent: &'a ureq::Agent,
    pub fixture: &'a Fixture,
    pub directory: &'a Path,
    pub authenticated: bool,
    pub trace: Vec<String>,
    pub roles: Vec<ImmichLockedLiveRole>,
    pub received: u64,
    pub expected: Vec<Value>,
    forbidden: usize,
    pub stages: Vec<std::path::PathBuf>,
    pub prepares: usize,
    pub publications: usize,
    releases: usize,
    journal: Value,
}
impl<'a> Shell<'a> {
    pub fn new(
        agent: &'a ureq::Agent,
        fixture: &'a Fixture,
        directory: &'a Path,
        journal: Value,
    ) -> Self {
        Self {
            agent,
            fixture,
            directory,
            journal,
            authenticated: false,
            trace: vec![],
            roles: vec![],
            received: 0,
            expected: vec![],
            forbidden: 0,
            stages: vec![],
            prepares: 0,
            publications: 0,
            releases: 0,
        }
    }
    pub fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.drain(core, core.process_event(event))
    }
    pub fn drain(&mut self, core: &Core<Suwop>, effects: Vec<Effect>) -> Result<(), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        while let Some(effect) = queue.pop_front() {
            queue.extend(self.resolve(core, effect)?);
        }
        Ok(())
    }
    pub fn resolve(&mut self, core: &Core<Suwop>, effect: Effect) -> Result<Vec<Effect>, String> {
        let Effect::Io(mut request) = effect;
        let value = self.respond(&request.operation);
        core.resolve(&mut request, live_response(value))
            .map_err(|_| "pair resolve".into())
    }
    pub fn request(&mut self, core: &Core<Suwop>) -> Result<Vec<Effect>, String> {
        for id in [&self.fixture.parent, &self.fixture.motion] {
            let response: HttpResponse = serde_json::from_value(execute(
                self.agent,
                &self
                    .fixture
                    .elevated
                    .request(&format!("assets/{id}"), "GET", None),
            )?)
            .map_err(|_| "independent pair facts")?;
            assert_eq!(response.status, 200);
            assert_eq!(response.body["id"], *id);
            assert_eq!(
                response.body["ownerId"],
                self.fixture.elevated.ordinary.user_id
            );
            self.expected.push(response.body);
        }
        assert_eq!(self.expected[0]["visibility"], "locked");
        assert_eq!(self.expected[0]["livePhotoVideoId"], self.fixture.motion);
        assert!(self.expected[1]["livePhotoVideoId"].is_null());
        self.run(
            core,
            Event::InspectImmichLiveResources {
                parent_key: self.fixture.key(),
                request_id: REQUEST.into(),
                grant_id: GRANT.into(),
                scene_id: SCENE.into(),
            },
        )?;
        let plan = core
            .view()
            .immich_live_resources
            .and_then(|v| v.plan)
            .ok_or("real pair plan missing")?;
        assert_eq!(plan.read_targets[0].key, self.fixture.key());
        assert_eq!(plan.read_targets[1].key.asset_id, self.fixture.motion);
        Ok(core.process_event(Event::RequestImmichLockedLive {
            plan_id: plan.plan_id,
            request_id: REQUEST.into(),
            scene_id: SCENE.into(),
            grant_id: GRANT.into(),
        }))
    }
    pub fn hold_read(
        &mut self,
        core: &Core<Suwop>,
        effects: Vec<Effect>,
    ) -> Result<(Effect, Vec<Effect>), String> {
        let mut queue: std::collections::VecDeque<_> = effects.into();
        while let Some(e) = queue.pop_front() {
            let Effect::Io(r) = &e;
            if matches!(
                r.operation,
                ShellOperation::ReadImmichLockedLiveMember { .. }
            ) {
                return Ok((e, queue.into()));
            }
            queue.extend(self.resolve(core, e)?);
        }
        Err("product omitted original read".into())
    }
    pub fn assert_released(&self) {
        assert_eq!(
            self.forbidden, 0,
            "no forbidden product effects may be emitted"
        );
        assert!(self.releases > 0);
        assert!(self.stages.iter().all(|p| !p.exists()));
    }
    pub fn save(&self, label: &str) -> Result<(), String> {
        let evidence = json!({"label":label,"trace":self.trace,"roles":self.roles,"receivedBytes":self.received,"prepareMocks":self.prepares,"publicationMocks":self.publications,"releaseMocks":self.releases,"journal":self.journal,"forbiddenEffects":self.forbidden,"independentFacts":self.expected,"nativeBoundary":"synthetic storage/prepare/publication/JOIN; no PhotoKit or native capacity claim"});
        std::fs::write(
            self.directory.join(format!("{label}.json")),
            serde_json::to_vec_pretty(&evidence).map_err(|_| "pair evidence encode")?,
        )
        .map_err(|_| "pair evidence write".into())
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        let prefix = format!("{}/", self.fixture.elevated.ordinary.endpoint);
        let path = request
            .url
            .strip_prefix(&prefix)
            .ok_or("pair foreign origin")?;
        let detail = path.strip_prefix("assets/").is_some_and(|id| {
            [
                self.fixture.parent.as_str(),
                self.fixture.motion.as_str(),
                self.fixture.other.as_str(),
            ]
            .contains(&id)
        });
        let allowed = (request.method == "GET"
            && (detail
                || matches!(
                    path,
                    "server/version" | "server/features" | "users/me" | "auth/status"
                )))
            || (request.method == "POST"
                && matches!(
                    path,
                    "auth/login"
                        | "auth/session/unlock"
                        | "auth/session/lock"
                        | "auth/logout"
                        | "search/metadata"
                ));
        if !allowed {
            self.forbidden += 1;
            return Err(
                "pair rejects provider mutation/original outside issued read effect".into(),
            );
        }
        if self.authenticated {
            assert!(
                request
                    .headers
                    .get("Authorization")
                    .is_some_and(|v| v.starts_with("Bearer "))
            );
            assert!(!request.headers.contains_key("x-api-key"));
        }
        self.trace.push(if detail {
            "GET exact own metadata".into()
        } else {
            format!("{} {path}", request.method)
        });
        execute(self.agent, request)
    }
    fn respond(&mut self, op: &ShellOperation) -> Result<Value, String> {
        match op {
            ShellOperation::Http(r) => self.http(r),
            ShellOperation::ReadState => Ok(self.journal.clone()),
            ShellOperation::ReadCredential { .. } => Err("unexpected pair credential read".into()),
            ShellOperation::InspectImmichLockedLiveStorage {
                pending,
                quote_deadline_unix_milliseconds,
            } => {
                assert_eq!(pending.parent_key, self.fixture.key());
                assert_eq!(pending.motion_key.asset_id, self.fixture.motion);
                self.trace.push("synthetic native quote".into());
                Ok(
                    json!({"storage":{"leaseID":QUOTE,"measurementNonce":GRANT,"deadlineUnixMilliseconds":quote_deadline_unix_milliseconds,"availableBytes":1_073_741_824_u64,"otherUnallocatedBytes":0,"allocationUnitBytes":4096,"capacityClass":"available"},"representations":[]}),
                )
            }
            ShellOperation::ReadImmichLockedLiveMember { read } => transport::download(self, read),
            ShellOperation::PrepareImmichLockedLive { ticket, originals } => {
                assert_eq!(
                    self.roles,
                    [ImmichLockedLiveRole::Parent, ImmichLockedLiveRole::Motion]
                );
                assert_eq!(originals[0].sha1, ticket.members[0].expected_sha1);
                assert_eq!(originals[1].sha1, ticket.members[1].expected_sha1);
                self.prepares += 1;
                Ok(
                    json!({"requestID":ticket.pending.request_id,"pairLeaseID":ticket.storage.lease_id,"acquisitionLeaseID":ticket.acquisition_lease.lease_id,"preparedID":GRANT}),
                )
            }
            ShellOperation::PublishImmichLockedLive { publication, .. } => {
                self.publications += 1;
                serde_json::to_value(publication).map_err(|_| "pair publish encode".into())
            }
            ShellOperation::ReleaseImmichLockedLive {
                pending,
                pair_lease_id,
            } => {
                assert_eq!(pending.parent_key, self.fixture.key());
                assert_eq!(pending.motion_key.asset_id, self.fixture.motion);
                assert_eq!(pending.request_id, REQUEST);
                if let Some(id) = pair_lease_id {
                    assert_eq!(id, QUOTE);
                }
                self.releases += 1;
                for p in &self.stages {
                    if p.exists() {
                        std::fs::remove_file(p).map_err(|_| "pair exact release")?;
                    }
                }
                Ok(json!({"pending":pending,"pairLeaseID":pair_lease_id}))
            }
            ShellOperation::ReleaseImmichLockedLives { .. }
            | ShellOperation::ScheduleImmichLockedLiveAcquisitionExpiry { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. }
            | ShellOperation::ReleaseImmichLockedImage { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. } => Ok(Value::Null),
            _ => {
                self.forbidden += 1;
                Err("pair rejects persist/confirmation/export/other native authority".into())
            }
        }
    }
}
