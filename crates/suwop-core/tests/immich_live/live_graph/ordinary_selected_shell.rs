//! Real HTTP + opaque fixture stages. This does not claim Swift raster/cache/UI acceptance.
use super::*;
use std::collections::BTreeMap;
use suwop_core::{
    domain::LibrarySnapshot, domain::ScanAccess, ordinary_selected::OrdinarySelectedImageTicket,
};
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    Initialize,
    Authenticate,
    Inspect,
    Ordinary,
}
struct Stage {
    ticket: OrdinarySelectedImageTicket,
    path: std::path::PathBuf,
}
pub(super) struct Shell<'a> {
    agent: &'a ureq::Agent,
    directory: &'a Path,
    session: &'a Session,
    fixture: &'a Fixture,
    pub phase: Phase,
    pub trace: Vec<String>,
    pub pending: Vec<Effect>,
    pub released: Vec<String>,
    stages: BTreeMap<String, Stage>,
}
impl<'a> Shell<'a> {
    pub fn new(
        agent: &'a ureq::Agent,
        directory: &'a Path,
        fixture: &'a Fixture,
        raw: &Value,
    ) -> Result<Self, String> {
        let shell = Self {
            agent,
            directory,
            session: &fixture.elevated.ordinary,
            fixture,
            phase: Phase::Initialize,
            trace: vec![],
            pending: vec![],
            released: vec![],
            stages: BTreeMap::new(),
        };
        shell.save(raw)?;
        Ok(shell)
    }
    fn save(&self, value: &Value) -> Result<(), String> {
        let path = self.directory.join("journal.tmp");
        std::fs::write(
            &path,
            serde_json::to_vec(value).map_err(|_| "journal encode")?,
        )
        .map_err(|_| "journal write")?;
        std::fs::rename(path, self.directory.join("journal.json"))
            .map_err(|_| "journal rename".into())
    }
    pub fn raw(&self) -> Result<Value, String> {
        serde_json::from_slice(
            &std::fs::read(self.directory.join("journal.json")).map_err(|_| "journal read")?,
        )
        .map_err(|_| "journal decode".into())
    }
    pub fn start(&mut self, core: &Core<Suwop>, event: Event) {
        assert!(self.pending.is_empty());
        self.pending.extend(core.process_event(event));
    }
    pub fn resolve(
        &mut self,
        core: &Core<Suwop>,
        effect: Effect,
        value: Value,
    ) -> Result<(), String> {
        let Effect::Io(mut request) = effect;
        self.pending.extend(
            core.resolve(&mut request, live_response(Ok(value)))
                .map_err(|_| "selected resolve")?,
        );
        Ok(())
    }
    pub fn drain(&mut self, core: &Core<Suwop>) -> Result<(), String> {
        while !self.pending.is_empty() {
            let effect = self.pending.remove(0);
            let Effect::Io(request) = &effect;
            let value = self.respond(core, &request.operation)?;
            self.resolve(core, effect, value)?;
        }
        Ok(())
    }
    pub fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        self.start(core, event);
        self.drain(core)
    }
    pub fn respond(
        &mut self,
        core: &Core<Suwop>,
        operation: &ShellOperation,
    ) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) => self.http(request),
            ShellOperation::ReadState => { self.trace.push("readState".into()); self.raw() }
            ShellOperation::Persist(raw) => { self.trace.push("persist".into()); self.save(&serde_json::to_value(raw).map_err(|_| "persist encode")?)?; Ok(Value::Null) }
            ShellOperation::ReadOrdinarySelectedImage {ticket} => self.read(core, ticket),
            ShellOperation::PublishOrdinarySelectedImage {ticket, staged_id} => self.publish(core,ticket,staged_id),
            ShellOperation::ReleaseOrdinarySelectedImage {staged_id} => {
                self.trace.push("release-selected".into());
                self.released.push(staged_id.clone());
                if let Some(stage) = self.stages.remove(staged_id) { std::fs::remove_file(stage.path).map_err(|_| "stage release")?; }
                Ok(Value::Null)
            }
            ShellOperation::ReleaseOrdinarySelectedImages {generation} => {
                self.trace.push("release-generation".into());
                let revoked_ids = self.stages.iter().filter(|(_,s)|s.ticket.generation<=*generation).map(|(id,_)|id.clone()).collect::<Vec<_>>();
                for id in revoked_ids { if let Some(stage) = self.stages.remove(&id) { std::fs::remove_file(stage.path).map_err(|_| "stage generation release")?; self.released.push(id); } }
                Ok(Value::Null)
            }
            ShellOperation::AppleScan {scope,..} => serde_json::to_value(LibrarySnapshot {provider:Provider::Apple,scope:scope.clone(),assets:vec![],access:ScanAccess::Full,scanned_at:Some(crate::visibility::scan_now()?)}).map_err(|_| "scan encode".into()),
            ShellOperation::AppleAlbums {scope} => Ok(json!({"provider":"apple","scope":scope,"albums":[],"access":"full"})),
            ShellOperation::ReleaseImmichLockedImage {..} | ShellOperation::ReleaseImmichLockedImages {..}
            | ShellOperation::ScheduleImmichLockedCheck {..} | ShellOperation::ScheduleImmichLockedExpiry {..}
            | ShellOperation::ReleaseProtectedImage {..} | ShellOperation::ReleaseProtectedImages {..} => {
                self.trace.push("cleanup-or-timer".into()); Ok(Value::Null)
            }
            _ => Err("unexpected selected-read effect: confirmations/provider writes/original exports forbidden".into()),
        }
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        let prefix = format!("{}/", self.session.endpoint);
        let path = request
            .url
            .strip_prefix(&prefix)
            .ok_or("wrong selected read origin")?;
        let selected = format!("assets/{}", self.fixture.parent);
        let other = format!("assets/{}", self.fixture.other);
        if self.phase == Phase::Inspect {
            assert_eq!(request.method, "GET");
            assert!(
                request
                    .headers
                    .get("Authorization")
                    .is_some_and(|v| v.starts_with("Bearer "))
                    && !request.headers.contains_key("x-api-key")
            );
            if path == "auth/status" {
                self.trace.push("GET auth/status".into());
            } else if path == selected {
                self.trace.push("GET selected-detail".into());
            } else {
                return Err("Inspect outside exact selected/status whitelist".into());
            }
        } else if self.phase == Phase::Authenticate {
            let allowed = matches!(
                (request.method.as_str(), path),
                (
                    "GET",
                    "server/features" | "server/version" | "users/me" | "auth/status"
                ) | (
                    "POST",
                    "auth/login"
                        | "auth/session/unlock"
                        | "auth/session/lock"
                        | "auth/logout"
                        | "search/metadata"
                )
            ) || request.method == "GET" && path == selected;
            if !allowed {
                return Err("unexpected PIN setup/cleanup route".into());
            }
            self.trace.push(if path == selected {
                "GET selected-detail".into()
            } else {
                format!("{} {path}", request.method)
            });
        } else if self.phase == Phase::Ordinary {
            assert!(!request.headers.contains_key("Authorization"));
            assert!(request.headers.contains_key("x-api-key"));
            let label = if request.method == "POST" && path == "search/metadata" {
                "POST catalog-read"
            } else if request.method == "GET" && path == selected {
                let authorization = request
                    .ordinary_content_authorization
                    .as_ref()
                    .ok_or("selected metadata authority missing")?;
                assert_eq!(authorization.source_keys, vec![self.fixture.key()]);
                assert!(!authorization.expected_revision.is_empty());
                assert!(matches!(
                    authorization.purpose,
                    suwop_core::immich::OrdinaryContentPurpose::SelectedPresentationMetadata
                ));
                "GET selected-detail"
            } else if request.method == "GET" && path == other {
                "GET independent-catalog-detail"
            } else if request.method == "GET"
                && (path == format!("asset-files?assetId={}", self.fixture.parent)
                    || path == format!("asset-files?assetId={}", self.fixture.other))
            {
                "GET catalog-inventory"
            } else {
                return Err("ordinary read outside P/catalog whitelist; related media/original/auth/write forbidden".into());
            };
            self.trace.push(label.into());
        } else {
            return Err("HTTP during initialization".into());
        }
        let value =
            execute(self.agent, request).map_err(|_| "real selected read transport failure")?;
        let response: HttpResponse =
            serde_json::from_value(value.clone()).map_err(|_| "HTTP response decode")?;
        immich::check_status(response.status)?;
        Ok(value)
    }
    fn live_ticket(&self, core: &Core<Suwop>, ticket: &OrdinarySelectedImageTicket) {
        assert_eq!(ticket.key, self.fixture.key());
        assert!(
            core.view()
                .ordinary_selected_presentation
                .iter()
                .any(|p| p.key == ticket.key
                    && p.proof_id == ticket.proof_id
                    && p.generation == ticket.generation)
        );
        assert!(
            core.view()
                .ordinary_selected_pending
                .iter()
                .any(|p| p.request_id == ticket.request_id
                    && p.scene_id == ticket.scene_id
                    && p.key == ticket.key
                    && p.kind == ticket.kind
                    && p.proof_id == ticket.proof_id
                    && p.generation == ticket.generation)
        );
        assert!(
            !core
                .view()
                .ordinary_selected_images
                .iter()
                .any(|a| a.request_id == ticket.request_id)
        );
    }
    fn read(
        &mut self,
        core: &Core<Suwop>,
        ticket: &OrdinarySelectedImageTicket,
    ) -> Result<Value, String> {
        self.live_ticket(core, ticket);
        let expected = self
            .session
            .preview_request(&self.fixture.parent, ticket.kind == Kind::Preview)?;
        assert!(ticket.request.url == expected.url && ticket.request.method == "GET");
        assert!(
            ticket.request.headers.contains_key("x-api-key")
                && !ticket.request.headers.contains_key("Authorization")
        );
        let id = format!("fixture-stage-{}", ticket.request_id);
        let path = self.directory.join(format!("{id}.image"));
        let mut request = ticket.request.clone();
        request.download_path = Some(path.to_string_lossy().into_owned());
        let response: HttpResponse = serde_json::from_value(
            execute(self.agent, &request).map_err(|_| "still transport failure")?,
        )
        .map_err(|_| "still response")?;
        assert_eq!(response.status, 200);
        let bytes = std::fs::read(&path).map_err(|_| "still bytes")?;
        let dimensions = super::super::derivative_headers::dimensions(&bytes)
            .ok_or("invalid actual derivative dimensions")?;
        std::fs::write(
            self.directory
                .join(format!("observed-{}.image", ticket.request_id)),
            &bytes,
        )
        .map_err(|_| "observed raster evidence")?;
        write(
            self.directory,
            &format!("raster-{}", ticket.request_id),
            &json!({"kind":ticket.kind,"dimensions":dimensions,"byteCount":bytes.len(),"sha256":format!("{:x}",sha2::Sha256::digest(&bytes))}),
        )?;
        assert!(
            self.stages
                .insert(
                    id.clone(),
                    Stage {
                        ticket: ticket.clone(),
                        path
                    }
                )
                .is_none()
        );
        self.trace.push(format!("read-staged-{:?}", ticket.kind));
        Ok(json!({"requestID":ticket.request_id,"stagedID":id}))
    }
    fn publish(
        &mut self,
        core: &Core<Suwop>,
        ticket: &OrdinarySelectedImageTicket,
        id: &str,
    ) -> Result<Value, String> {
        self.live_ticket(core, ticket);
        let stage = self.stages.get(id).ok_or("missing exact stage")?;
        assert!(
            stage.ticket.request_id == ticket.request_id
                && stage.ticket.scene_id == ticket.scene_id
                && stage.ticket.key == ticket.key
                && stage.ticket.kind == ticket.kind
                && stage.ticket.proof_id == ticket.proof_id
                && stage.ticket.generation == ticket.generation
                && stage.ticket.expected_revision == ticket.expected_revision
        );
        self.trace.push("publish-staged".into());
        Ok(json!({"requestID":ticket.request_id,"stagedID":id}))
    }
    pub fn assert_approved(&self, core: &Core<Suwop>, request_id: &str) -> Result<(), String> {
        let view = core.view();
        let access = view
            .ordinary_selected_images
            .iter()
            .find(|a| a.request_id == request_id)
            .ok_or("approved access missing")?;
        let stage = self
            .stages
            .get(&access.staged_id)
            .ok_or("approved stage missing")?;
        assert!(
            stage.ticket.key == access.key
                && stage.ticket.scene_id == access.scene_id
                && stage.ticket.kind == access.kind
                && stage.ticket.proof_id == access.proof_id
                && stage.ticket.generation == access.generation
                && stage.ticket.request_id == access.request_id
        );
        Ok(())
    }
    pub fn stage_count(&self) -> usize {
        self.stages.len()
    }
}
