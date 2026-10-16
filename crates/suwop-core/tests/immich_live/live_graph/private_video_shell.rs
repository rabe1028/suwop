//! Product effect whitelist and hidden opaque leases. Native prepare is explicitly mocked.
use super::*;
use std::collections::BTreeMap;
use suwop_core::immich_locked::video::{
    ImmichLockedVideoPending, ImmichLockedVideoStorageFacts, ImmichLockedVideoTicket,
};
struct Lease {
    pending: ImmichLockedVideoPending,
    path: std::path::PathBuf,
    prepared: bool,
}
#[derive(PartialEq, Eq)]
pub(super) enum Phase {
    Initialize,
    Authenticate,
    Selected,
}
pub(super) struct Shell<'a> {
    pub agent: &'a ureq::Agent,
    pub fixture: &'a Fixture,
    pub directory: &'a Path,
    pub phase: Phase,
    pub selected: String,
    pub pending: Vec<Effect>,
    pub trace: Vec<String>,
    pub released: Vec<String>,
    pub absent_size: bool,
    raw: Value,
    leases: BTreeMap<String, Lease>,
}
impl<'a> Shell<'a> {
    pub fn new(
        agent: &'a ureq::Agent,
        fixture: &'a Fixture,
        directory: &'a Path,
        raw: Value,
    ) -> Self {
        Self {
            agent,
            fixture,
            directory,
            phase: Phase::Initialize,
            selected: fixture.video.clone(),
            pending: vec![],
            trace: vec![],
            released: vec![],
            absent_size: false,
            raw,
            leases: BTreeMap::new(),
        }
    }
    pub fn raw(&self) -> &Value {
        &self.raw
    }
    pub fn stage_count(&self) -> usize {
        self.leases.len()
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
                .map_err(|_| "video effect resolve")?,
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
            ShellOperation::ReadState => Ok(self.raw.clone()),
            ShellOperation::Persist(raw) => {
                assert!(
                    self.phase == Phase::Initialize,
                    "private video must not persist"
                );
                self.raw = serde_json::to_value(raw).map_err(|_| "video persist encode")?;
                Ok(Value::Null)
            }
            ShellOperation::Http(request) => self.http(request),
            ShellOperation::InspectImmichLockedVideoStorage { pending } => {
                self.quote(core, pending)
            }
            ShellOperation::ReadImmichLockedVideo { ticket } => self.read(core, ticket),
            ShellOperation::PrepareImmichLockedVideo { ticket, staged_id } => {
                self.prepare(core, ticket, staged_id)
            }
            ShellOperation::ReleaseImmichLockedVideo { pending, lease_id } => {
                self.release(lease_id, Some(pending))?;
                Ok(Value::Null)
            }
            ShellOperation::ReleaseImmichLockedVideos { generation } => {
                let ids = self
                    .leases
                    .iter()
                    .filter(|(_, l)| l.pending.generation <= *generation)
                    .map(|(id, _)| id.clone())
                    .collect::<Vec<_>>();
                for id in ids {
                    self.release(&id, None)?;
                }
                Ok(Value::Null)
            }
            ShellOperation::ReleaseImmichLockedImage { .. }
            | ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. }
            | ShellOperation::ReleaseOrdinarySelectedImage { .. }
            | ShellOperation::ReleaseOrdinarySelectedImages { .. }
            | ShellOperation::ReleaseProtectedImage { .. }
            | ShellOperation::ReleaseProtectedImages { .. } => {
                self.trace.push("cleanup-or-timer".into());
                Ok(Value::Null)
            }
            _ => Err(
                "private video rejects ordinary export/workspace/share/confirmation/provider write"
                    .into(),
            ),
        }
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        let prefix = format!("{}/", self.fixture.elevated.ordinary.endpoint);
        let path = request
            .url
            .strip_prefix(&prefix)
            .ok_or("private video wrong origin")?;
        let selected = format!("assets/{}", self.selected);
        let label = if self.phase == Phase::Authenticate {
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
            ) || request.method == "GET"
                && [
                    format!("assets/{}", self.fixture.video),
                    format!("assets/{}", self.fixture.motion),
                ]
                .contains(&path.to_owned());
            if !allowed {
                return Err(
                    "video auth outside exact locked inventory/own detail whitelist".into(),
                );
            }
            if path.starts_with("assets/") {
                "GET own-video-inventory".into()
            } else {
                format!("{} {path}", request.method)
            }
        } else if self.phase == Phase::Selected {
            assert!(
                request.headers.contains_key("Authorization")
                    && !request.headers.contains_key("x-api-key")
            );
            assert!(request.ordinary_content_authorization.is_none());
            if request.method == "GET" && path == selected {
                "GET selected-detail".into()
            } else if request.method == "GET" && path == "auth/status" {
                "GET auth/status".into()
            } else if request.method == "POST"
                && ["auth/session/lock", "auth/logout"].contains(&path)
            {
                format!("POST {path}")
            } else {
                return Err(
                    "private video traversed related key/original or issued provider write".into(),
                );
            }
        } else {
            return Err("HTTP during video initialize".into());
        };
        self.trace.push(label);
        let mut value = execute(self.agent, request).map_err(|_| "private video HTTP failure")?;
        let reply: HttpResponse =
            serde_json::from_value(value.clone()).map_err(|_| "video response decode")?;
        immich::check_status(reply.status)?;
        // Deliberate synthetic metadata absence for policy coverage; actual bytes/route stay real.
        if self.absent_size {
            remove_sizes(&mut value["body"]);
        }
        Ok(value)
    }
    fn quote(
        &mut self,
        core: &Core<Suwop>,
        pending: &ImmichLockedVideoPending,
    ) -> Result<Value, String> {
        Self::current(core, pending)?;
        let id = pending.request_id.clone();
        let facts = ImmichLockedVideoStorageFacts {
            lease_id: id.clone(),
            measurement_nonce: pending.grant_id.clone(),
            deadline_unix_milliseconds: transport::now_ms()?
                .checked_add(30_000)
                .ok_or("quote deadline")?,
            available_bytes: 2 * 1024 * 1024 * 1024,
            other_unallocated_bytes: 0,
            allocation_unit_bytes: 4096,
            capacity_class:
                suwop_core::immich_locked::video::ImmichLockedVideoCapacityClass::ImportantUsage,
        };
        assert!(
            self.leases
                .insert(
                    id.clone(),
                    Lease {
                        pending: pending.clone(),
                        path: self.directory.join(format!("{id}.mp4")),
                        prepared: false
                    }
                )
                .is_none()
        );
        self.trace.push("storage-quote-synthetic-capacity".into());
        serde_json::to_value(facts).map_err(|_| "video quote encode".into())
    }
    fn current(core: &Core<Suwop>, pending: &ImmichLockedVideoPending) -> Result<(), String> {
        let view = core.view().immich_locked_view;
        assert_eq!(view.grant_id.as_ref(), Some(&pending.grant_id));
        assert_eq!(view.scene_id.as_ref(), Some(&pending.scene_id));
        let current = view
            .video_pending
            .as_ref()
            .ok_or("live private video pending missing")?;
        assert_binding(current, pending);
        assert!(
            view.video.is_none(),
            "must not reveal before final metadata approval"
        );
        Ok(())
    }
    fn read(
        &mut self,
        core: &Core<Suwop>,
        ticket: &ImmichLockedVideoTicket,
    ) -> Result<Value, String> {
        Self::current(core, &ticket.pending)?;
        let expected = self.fixture.elevated.ordinary.request(
            &format!("assets/{}/original?edited=false", self.selected),
            "GET",
            None,
        );
        assert_eq!(ticket.pending.key, self.fixture.key(&self.selected));
        assert_eq!(ticket.request.url, expected.url);
        assert!(
            ticket.request.headers.contains_key("Authorization")
                && !ticket.request.headers.contains_key("x-api-key")
                && ticket.request.ordinary_content_authorization.is_none()
        );
        let lease = self
            .leases
            .get(&ticket.storage.lease_id)
            .ok_or("video missing quote")?;
        assert_binding(&lease.pending, &ticket.pending);
        let expected_bytes = self.fixture.expected(&self.selected)?;
        let measured_length =
            u64::try_from(expected_bytes.len()).map_err(|_| "fixture video size")?;
        if self.absent_size {
            assert!(ticket.expected_bytes.is_none());
            let usable = ticket
                .storage
                .available_bytes
                .checked_sub(ticket.minimum_remaining_bytes)
                .and_then(|n| n.checked_sub(ticket.storage.other_unallocated_bytes))
                .ok_or("fixture finite storage budget")?;
            assert_eq!(
                ticket.max_received_bytes,
                usable / ticket.storage.allocation_unit_bytes
                    * ticket.storage.allocation_unit_bytes
            );
            assert!(ticket.max_received_bytes > measured_length);
        } else if let Some(expected) = ticket.expected_bytes {
            assert_eq!(expected, measured_length);
            assert_eq!(ticket.max_received_bytes, expected);
        }
        let result = transport::download(self.agent, ticket, &lease.path)?;
        let actual = std::fs::read(&lease.path).map_err(|_| "video result bytes")?;
        assert_eq!(actual, self.fixture.expected(&self.selected)?);
        self.trace.push("GET selected-original-stream".into());
        write_json(
            &self
                .directory
                .join(format!("acquired-{}.json", ticket.pending.request_id)),
            &json!({"requestID":ticket.pending.request_id,"sha1":result.sha1,"signature":result.signature,"expectedBytes":ticket.expected_bytes,"maximumReceivedBytes":ticket.max_received_bytes,"sizeFieldMode":if self.absent_size {"synthetic absence over real original"} else {"actual server metadata"}}),
        )?;
        serde_json::to_value(result).map_err(|_| "video result encode".into())
    }
    fn prepare(
        &mut self,
        core: &Core<Suwop>,
        ticket: &ImmichLockedVideoTicket,
        id: &str,
    ) -> Result<Value, String> {
        Self::current(core, &ticket.pending)?;
        assert_eq!(id, ticket.storage.lease_id);
        let lease = self.leases.get_mut(id).ok_or("prepare missing lease")?;
        assert_binding(&lease.pending, &ticket.pending);
        assert!(lease.path.is_file());
        lease.prepared = true;
        self.trace.push("prepare-hidden-mock".into());
        Ok(json!({"requestID":ticket.pending.request_id,"stagedID":id}))
    }
    pub fn assert_approved(&self, core: &Core<Suwop>, request: &str) -> Result<(), String> {
        let access = core
            .view()
            .immich_locked_view
            .video
            .ok_or("final private video access missing")?;
        assert_eq!(access.pending.request_id, request);
        let lease = self
            .leases
            .get(&access.staged_id)
            .ok_or("approved video missing lease")?;
        assert!(lease.prepared && lease.path.is_file());
        assert_binding(&lease.pending, &access.pending);
        Ok(())
    }
    fn release(
        &mut self,
        id: &str,
        pending: Option<&ImmichLockedVideoPending>,
    ) -> Result<(), String> {
        if let Some(lease) = self.leases.remove(id) {
            if let Some(p) = pending {
                assert_binding(&lease.pending, p);
            }
            if lease.path.exists() {
                std::fs::remove_file(lease.path).map_err(|_| "video stage cleanup")?;
            }
            self.released.push(id.into());
        }
        self.trace.push("release-video".into());
        Ok(())
    }
}
fn assert_binding(a: &ImmichLockedVideoPending, b: &ImmichLockedVideoPending) {
    assert_eq!(
        (
            &a.request_id,
            &a.entry_id,
            &a.grant_id,
            &a.scene_id,
            a.generation,
            &a.key
        ),
        (
            &b.request_id,
            &b.entry_id,
            &b.grant_id,
            &b.scene_id,
            b.generation,
            &b.key
        )
    );
}
fn remove_sizes(value: &mut Value) {
    if let Some(exif) = value.get_mut("exifInfo").and_then(Value::as_object_mut) {
        exif.remove("fileSizeInByte");
    }
    if let Some(object) = value.as_object_mut() {
        for child in object.values_mut() {
            remove_sizes(child);
        }
    } else if let Some(array) = value.as_array_mut() {
        for child in array {
            remove_sizes(child);
        }
    }
}
