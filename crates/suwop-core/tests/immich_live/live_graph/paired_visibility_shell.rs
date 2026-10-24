//! Real provider transport; confirmation, native JOIN and atomic JSON CAS are labelled fixture adapters.
use super::*;
use suwop_core::immich_live_writes::Outcome;
struct ReadScope {
    workspace: std::path::PathBuf,
    keys: Vec<suwop_core::domain::AssetKey>,
    files: Vec<String>,
    ended: bool,
}
pub(super) struct PairShell<'a> {
    pub agent: &'a ureq::Agent,
    pub fixture: &'a Fixture,
    pub directory: &'a Path,
    pub puts: Vec<String>,
    pub trace: Vec<String>,
    pub confirmations: usize,
    captured: std::collections::BTreeMap<String, (Vec<suwop_core::domain::AssetKey>, String)>,
    joined_capture: Option<String>,
    revision: u64,
    read_scopes: std::collections::BTreeMap<String, ReadScope>,
    pub read_workspaces: Vec<std::path::PathBuf>,
    pub originals: Vec<Value>,
    pub plays: usize,
    pub ends: usize,
    pub lose_response_at: Option<usize>,
}
impl<'a> PairShell<'a> {
    pub fn new(
        agent: &'a ureq::Agent,
        fixture: &'a Fixture,
        directory: &'a Path,
        state: &SavedLibrary,
    ) -> Result<Self, String> {
        let host = Self {
            agent,
            fixture,
            directory,
            puts: vec![],
            trace: vec![],
            confirmations: 0,
            captured: std::collections::BTreeMap::new(),
            joined_capture: None,
            revision: 0,
            read_scopes: std::collections::BTreeMap::new(),
            read_workspaces: vec![],
            originals: vec![],
            plays: 0,
            ends: 0,
            lose_response_at: None,
        };
        host.save(state)?;
        Ok(host)
    }
    fn save(&self, state: &SavedLibrary) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(state).map_err(|_| "pair journal encode")?;
        std::fs::write(self.directory.join("journal.tmp"), bytes)
            .map_err(|_| "pair journal write")?;
        std::fs::rename(
            self.directory.join("journal.tmp"),
            self.directory.join("journal.json"),
        )
        .map_err(|_| "pair journal rename".into())
    }
    pub fn raw(&self) -> Result<SavedLibrary, String> {
        serde_json::from_slice(
            &std::fs::read(self.directory.join("journal.json")).map_err(|_| "pair journal read")?,
        )
        .map_err(|_| "pair journal decode".into())
    }
    pub fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut pending = std::collections::VecDeque::from(core.process_event(event));
        let mut count = 0;
        while let Some(effect) = pending.pop_front() {
            count += 1;
            if count > 2000 {
                return Err("pair effect budget".into());
            }
            let Effect::Io(mut request) = effect;
            let response = self.respond(core, &request.operation);
            pending.extend(
                core.resolve(&mut request, live_response(response))
                    .map_err(|_| "pair resolve")?,
            );
        }
        assert!(!core.view().busy);
        Ok(())
    }
    fn respond(&mut self, core: &Core<Suwop>, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Http(request) => self.http(request),
            ShellOperation::Workspace { id } => self.workspace(id),
            ShellOperation::BeginOrdinaryLivePairRead {
                scope_id,
                keys,
                workspace,
                presentation,
            } => self.begin(core, scope_id, keys, workspace, presentation),
            ShellOperation::OrdinaryLivePairReadHttp { scope_id, request } => {
                self.original(scope_id, request)
            }
            ShellOperation::PlayOrdinaryLivePairRead { scope_id, plan } => {
                self.play(scope_id, plan)
            }
            ShellOperation::EndOrdinaryLivePairRead {
                scope_id,
                retry_cleanup,
            } => self.end(scope_id, *retry_cleanup),
            ShellOperation::ReadState => {
                serde_json::to_value(self.raw()?).map_err(|_| "pair read state".into())
            }
            ShellOperation::Persist(state) => {
                self.save(state)?;
                Ok(Value::Null)
            }
            ShellOperation::ReadStateVersioned => {
                Ok(json!({"revision":self.revision.to_string(),"state":self.raw()?}))
            }
            ShellOperation::PersistIfCurrent { revision, state } => {
                if revision != &self.revision.to_string() {
                    return Ok(json!(false));
                }
                suwop_core::immich_live_writes::validate_transition(&self.raw()?, state)?;
                self.save(state)?;
                self.revision += 1;
                Ok(json!(true))
            }
            ShellOperation::ConfirmImmichLivePlacement { prompt } => {
                self.confirmations += 1;
                let current = core
                    .view()
                    .live_placement_prompt
                    .ok_or("pair prepared prompt")?;
                assert_eq!(prompt.intent_digest, current.intent_digest);
                assert_eq!(prompt.resources.len(), 2);
                assert_eq!(prompt.aliases.len(), 1);
                assert!(prompt.shared_reference_limitations_acknowledged);
                write(
                    self.directory,
                    &format!("prompt-{}.json", self.confirmations),
                    &serde_json::to_value(prompt).map_err(|_| "pair prompt")?,
                )?;
                Ok(json!(true))
            }
            ShellOperation::CapturePrivateMediaBatch {
                keys,
                capture_id,
                intent_digest,
                ..
            } => {
                assert_eq!(keys.len(), 2);
                assert!(
                    self.captured
                        .insert(capture_id.clone(), (keys.clone(), intent_digest.clone()))
                        .is_none()
                );
                self.joined_capture = None;
                self.trace
                    .push(format!("synthetic native capture {capture_id}"));
                Ok(Value::Null)
            }
            ShellOperation::DrainCapturedPrivateMediaBatch {
                capture_id,
                keys,
                intent_digest,
                ..
            } => {
                assert_eq!(
                    self.captured.get(capture_id),
                    Some(&(keys.clone(), intent_digest.clone()))
                );
                self.joined_capture = Some(capture_id.clone());
                self.trace
                    .push(format!("synthetic native JOIN {capture_id}"));
                Ok(json!({"captureID":capture_id,"cancelledBeforeCapture":false}))
            }
            ShellOperation::ReleaseImmichLockedImages { .. }
            | ShellOperation::ReleaseImmichLockedImage { .. }
            | ShellOperation::ScheduleImmichLockedCheck { .. }
            | ShellOperation::ScheduleImmichLockedExpiry { .. } => Ok(Value::Null),
            _ => Err("paired visibility unexpected native effect".into()),
        }
    }
    fn workspace(&mut self, id: &str) -> Result<Value, String> {
        immich::valid_id(id)?;
        let workspace = self
            .directory
            .canonicalize()
            .map_err(|_| "fixture canonical directory")?
            .join(format!("suwop-{id}"));
        std::fs::create_dir(&workspace).map_err(|_| "fixture read workspace")?;
        self.read_workspaces.push(workspace.clone());
        Ok(json!(workspace.to_string_lossy()))
    }
    fn begin(
        &mut self,
        core: &Core<Suwop>,
        scope_id: &str,
        keys: &[suwop_core::domain::AssetKey],
        workspace: &str,
        presentation: &impl serde::Serialize,
    ) -> Result<Value, String> {
        assert_eq!(
            keys,
            &[
                self.fixture.key(),
                suwop_core::domain::AssetKey {
                    asset_id: self.fixture.motion.clone(),
                    ..self.fixture.key()
                }
            ]
        );
        assert!(core.view().immich_locked_view.grant_id.is_none());
        let presentation = serde_json::to_value(presentation).map_err(|_| "issued proof encode")?;
        let projected = core
            .view()
            .ordinary_live_pairs
            .into_iter()
            .find(|p| Some(p.proof_id.as_str()) == presentation["proofID"].as_str())
            .ok_or("fresh ordinary proof")?;
        assert_eq!(
            serde_json::to_value(projected).map_err(|_| "fresh proof encode")?,
            presentation
        );
        let path = std::path::PathBuf::from(workspace);
        assert!(self.read_workspaces.contains(&path));
        assert_eq!(
            path.file_name().and_then(|p| p.to_str()),
            Some(format!("suwop-{scope_id}").as_str())
        );
        assert!(!self.read_scopes.contains_key(scope_id));
        self.read_scopes.insert(
            scope_id.to_owned(),
            ReadScope {
                workspace: path,
                keys: keys.to_vec(),
                files: vec![],
                ended: false,
            },
        );
        self.trace.push(format!("synthetic Begin {scope_id}"));
        Ok(json!(true))
    }
    fn play(
        &mut self,
        scope_id: &str,
        plan: &suwop_core::media::PlaybackPlan,
    ) -> Result<Value, String> {
        let scope = self.read_scopes.get(scope_id).ok_or("read owner")?;
        assert!(!scope.ended);
        assert_eq!(plan.source_keys, scope.keys);
        assert_eq!(plan.files, scope.files);
        assert_eq!(plan.files.len(), 2);
        assert!(
            plan.files
                .iter()
                .all(|path| std::path::Path::new(path).is_file())
        );
        assert!(matches!(plan.kind, suwop_core::media::PlaybackKind::Live));
        self.plays += 1;
        self.trace.push(format!(
            "synthetic Play receipt {scope_id}; no OS playback claim"
        ));
        Ok(Value::Null)
    }
    fn end(&mut self, scope_id: &str, retry_cleanup: bool) -> Result<Value, String> {
        let scope = self
            .read_scopes
            .get_mut(scope_id)
            .ok_or("exact read owner")?;
        assert!(!scope.ended && !retry_cleanup);
        assert!(
            scope.workspace.parent()
                == Some(
                    self.directory
                        .canonicalize()
                        .map_err(|_| "fixture directory")?
                        .as_path()
                )
        );
        std::fs::remove_dir_all(&scope.workspace).map_err(|_| "exact read workspace cleanup")?;
        scope.ended = true;
        self.ends += 1;
        self.trace
            .push(format!("synthetic End {scope_id}; exact workspace removed"));
        Ok(Value::Null)
    }
    fn original(&mut self, scope_id: &str, request: &HttpRequest) -> Result<Value, String> {
        let scope = self
            .read_scopes
            .get_mut(scope_id)
            .ok_or("original read owner")?;
        assert!(!scope.ended && scope.files.len() < 2);
        assert_eq!(request.method, "GET");
        assert!(
            request.immich_visibility_authorization.is_none()
                && request.immich_archive_authorization.is_none()
        );
        let key = &scope.keys[scope.files.len()];
        let authorization = request
            .ordinary_content_authorization
            .as_ref()
            .ok_or("physical read authorization")?;
        assert_eq!(authorization.source_keys, vec![key.clone()]);
        assert!(matches!(
            authorization.purpose,
            suwop_core::immich::OrdinaryContentPurpose::Read
        ));
        assert!(!authorization.expected_revision.is_empty());
        assert_eq!(
            request.url,
            format!(
                "{}/assets/{}/original?edited=false",
                self.fixture.elevated.ordinary.endpoint, key.asset_id
            )
        );
        let path = request
            .download_path
            .as_ref()
            .ok_or("original destination")?;
        let destination = std::path::Path::new(path);
        let relative = destination
            .strip_prefix(&scope.workspace)
            .map_err(|_| "original escapes workspace")?;
        assert!(
            relative
                .components()
                .all(|part| matches!(part, std::path::Component::Normal(_)))
        );
        std::fs::create_dir_all(destination.parent().ok_or("original parent")?)
            .map_err(|_| "original subdirectory")?;
        let response = execute(self.agent, request)?;
        let parsed: HttpResponse =
            serde_json::from_value(response.clone()).map_err(|_| "original HTTP response")?;
        assert_eq!(parsed.status, 200);
        assert_eq!(parsed.path.as_deref(), Some(path.as_str()));
        let bytes = std::fs::read(destination).map_err(|_| "original fixture bytes")?;
        let pair = native_pair_bytes()?;
        assert_eq!(
            bytes,
            if scope.files.is_empty() {
                pair.0
            } else {
                pair.1
            }
        );
        let sha1 = format!("{:x}", sha1::Sha1::digest(&bytes));
        let signature = FileSignature {
            sha256: format!("{:x}", sha2::Sha256::digest(&bytes)),
            bytes: u64::try_from(bytes.len()).map_err(|_| "original byte count")?,
        };
        assert!(signature.valid());
        self.originals
            .push(json!({"scopeID":scope_id,"key":key,"sha1":sha1,"signature":signature}));
        scope.files.push(path.clone());
        self.trace.push(format!(
            "actual GET original + SHA1/SHA256 {} {scope_id}",
            key.asset_id
        ));
        Ok(json!({"response":response,"hash":{"sha1":sha1,"signature":signature}}))
    }
    fn validate_put(&mut self, request: &HttpRequest, path: &str) -> Result<(), String> {
        assert_eq!(path, "assets");
        let body = request.body.as_ref().ok_or("pair PUT body")?;
        let ids = body["ids"].as_array().ok_or("pair PUT ids")?;
        assert_eq!(ids.len(), 1, "one physical resource per provider PUT");
        let id = ids[0].as_str().ok_or("pair PUT id")?;
        assert!([self.fixture.parent.as_str(), self.fixture.motion.as_str()].contains(&id));
        assert_eq!(body.as_object().ok_or("pair PUT object")?.len(), 2);
        assert!(matches!(
            body["visibility"].as_str(),
            Some("locked" | "timeline" | "archive" | "hidden")
        ));
        assert!(self.confirmations > 0);
        assert!(
            request
                .headers
                .get("Authorization")
                .is_some_and(|v| v.starts_with("Bearer "))
        );
        assert!(!request.headers.contains_key("x-api-key"));
        let durable = self.raw()?;
        let batch = durable
            .immich_live_operations
            .last()
            .ok_or("durable pair batch")?;
        let joined = self.joined_capture.as_ref().ok_or("current capture JOIN")?;
        let (keys, digest) = self.captured.get(joined).ok_or("current captured keys")?;
        assert_eq!(
            digest, &batch.intent.digest,
            "JOIN belongs to this exact batch intent"
        );
        assert_eq!(
            keys.iter().cloned().collect::<BTreeSet<_>>(),
            batch
                .intent
                .resources
                .iter()
                .map(|r| r.initial.key.clone())
                .collect()
        );
        assert!(
            self.trace
                .iter()
                .any(|entry| entry == &format!("synthetic native JOIN {joined}"))
        );

        let step = batch
            .steps
            .iter()
            .find(|step| matches!(step.outcome, Outcome::Unknown { accepted: None, .. }))
            .ok_or("durable pre-submit Unknown")?;
        let resource = batch
            .intent
            .resources
            .iter()
            .find(|resource| resource.id == step.resource_id)
            .ok_or("durable pair resource")?;
        assert_eq!(resource.initial.key.asset_id, id);
        self.puts.push(id.into());
        Ok(())
    }
    fn http(&mut self, request: &HttpRequest) -> Result<Value, String> {
        let prefix = format!("{}/", self.fixture.elevated.ordinary.endpoint);
        let path = request
            .url
            .strip_prefix(&prefix)
            .ok_or("pair foreign origin")?;
        let mutating = request.method == "PUT";
        if mutating {
            self.validate_put(request, path)?;
        } else {
            let exact_member = |id: &str| {
                [
                    self.fixture.parent.as_str(),
                    self.fixture.motion.as_str(),
                    self.fixture.other.as_str(),
                ]
                .contains(&id)
            };
            let allowed = request.method == "GET"
                && (path.strip_prefix("assets/").is_some_and(exact_member)
                    || path
                        .strip_prefix("albums?assetId=")
                        .is_some_and(exact_member)
                    || matches!(
                        path,
                        "server/version" | "server/features" | "users/me" | "auth/status"
                    ))
                || request.method == "POST"
                    && matches!(
                        path,
                        "auth/login"
                            | "auth/session/unlock"
                            | "auth/session/lock"
                            | "auth/logout"
                            | "search/metadata"
                    );
            if !allowed {
                return Err("pair rejects unrelated provider mutation".into());
            }
        }
        self.trace.push(format!(
            "{} {}",
            request.method,
            if mutating { "assets singleton" } else { path }
        ));
        let result = execute(self.agent, request)?;
        if mutating {
            let response: HttpResponse =
                serde_json::from_value(result.clone()).map_err(|_| "pair PUT response")?;
            assert_eq!(response.status, 204);
            if self.lose_response_at == Some(self.puts.len()) {
                return Err("injected loss after actual provider 204".into());
            }
        }
        Ok(result)
    }
}
