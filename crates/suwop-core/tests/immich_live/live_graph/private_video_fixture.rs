//! External synthetic setup/observer, separate from the measured C1 product trace.
use super::*;
pub(super) struct Fixture {
    pub elevated: Elevated,
    pub email: String,
    pub video: String,
    pub parent: String,
    pub motion: String,
    pub other: String,
    albums: BTreeSet<String>,
}
impl Fixture {
    pub fn setup(agent: &ureq::Agent, directory: &Path) -> Result<Self, String> {
        let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "video fixture URL")?;
        let key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "video fixture admin key")?;
        let work = directory.to_path_buf();
        let (sender, receiver) = std::sync::mpsc::channel();
        let mut command = Command::<Effect, Event>::new(move |ctx| async move {
            let result = Box::pin(Self::prepare(&ctx, &address, &key, &work)).await;
            let _ = sender.send(result);
        });
        drive_setup(agent, &mut command)?;
        receiver.recv().map_err(|_| "video setup completion")?
    }
    async fn prepare(
        ctx: &Context,
        address: &str,
        key: &str,
        directory: &Path,
    ) -> Result<Self, String> {
        let prefix = "private-video";
        let elevated = setup_named(ctx, address, key, prefix).await?;
        let ordinary = &elevated.ordinary;
        let (parent, albums) =
            ordinary_parent::native_checkpoint_setup(ctx, ordinary, directory, prefix).await?;
        let control: Value = serde_json::from_slice(
            &std::fs::read(directory.join("parent-control.json"))
                .map_err(|_| "video graph control")?,
        )
        .map_err(|_| "video graph control JSON")?;
        let motion = control["motion"]
            .as_str()
            .ok_or("video motion ID")?
            .to_owned();
        let other = control["other"]
            .as_str()
            .ok_or("video second parent ID")?
            .to_owned();
        let video = upload(
            ctx,
            ordinary,
            directory,
            "V.mp4",
            V,
            ResourceRole::Video,
            None,
        )
        .await?;
        let admin = immich::connect(ctx, address, key, true).await?;
        crate::wait_metadata_queues(ctx, &admin).await?;
        // Explicit single-record fixture setup: no bulk metadata cascade/album loss is claimed.
        for id in [&video, &motion] {
            let fresh = elevated
                .json(
                    ctx,
                    &format!("assets/{id}"),
                    "PUT",
                    Some(json!({"visibility":"locked"})),
                )
                .await?;
            assert_eq!(fresh["id"], *id);
            assert_eq!(fresh["visibility"], "locked");
        }
        Ok(Self {
            elevated,
            email: format!("{prefix}-{}@example.invalid", std::process::id()),
            video,
            parent,
            motion,
            other,
            albums: albums.into_iter().collect(),
        })
    }
    pub fn key(&self, id: &str) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: self.elevated.ordinary.scope.clone(),
            asset_id: id.into(),
        }
    }
    pub fn expected(&self, id: &str) -> Result<Vec<u8>, String> {
        if id == self.video {
            Ok(V.to_vec())
        } else if id == self.motion {
            Ok(native_pair_bytes()?.1)
        } else {
            Err("not a selected private video".into())
        }
    }
    fn get(
        &self,
        agent: &ureq::Agent,
        path: &str,
        destination: Option<&Path>,
    ) -> Result<Value, String> {
        let mut request = self.elevated.request(path, "GET", None);
        request.download_path = destination.map(|p| p.to_string_lossy().into_owned());
        let reply: HttpResponse = serde_json::from_value(execute(agent, &request)?)
            .map_err(|_| "video observer response")?;
        assert_eq!(reply.status, 200);
        Ok(reply.body)
    }
    pub fn observe(
        &self,
        agent: &ureq::Agent,
        directory: &Path,
        label: &str,
    ) -> Result<Value, String> {
        let output = directory.join(label);
        std::fs::create_dir(&output)
            .map_err(|_| "video observer directory exists or unavailable")?;
        let pair = native_pair_bytes()?;
        let expected = [V.to_vec(), pair.0, pair.1, png(1)?];
        let ids = [&self.video, &self.parent, &self.motion, &self.other];
        let mut observed = vec![];
        for (index, id) in ids.into_iter().enumerate() {
            let detail = self.get(agent, &format!("assets/{id}"), None)?;
            assert_eq!(detail["id"], *id);
            assert_eq!(detail["ownerId"], self.elevated.ordinary.user_id);
            assert_eq!(
                detail["type"],
                if index == 0 || index == 2 {
                    "VIDEO"
                } else {
                    "IMAGE"
                }
            );
            if index == 1 || index == 3 {
                assert_eq!(detail["livePhotoVideoId"], self.motion);
            }
            let memberships = self.get(agent, &format!("albums?assetId={id}"), None)?;
            let albums = memberships
                .as_array()
                .ok_or("video observer albums")?
                .iter()
                .map(|a| a["id"].as_str().map(str::to_owned).ok_or("video album ID"))
                .collect::<Result<BTreeSet<_>, _>>()?;
            assert_eq!(
                albums,
                if index == 0 {
                    BTreeSet::new()
                } else {
                    self.albums.clone()
                }
            );
            let path = output.join(format!("original-{index}.bin"));
            self.get(
                agent,
                &format!("assets/{id}/original?edited=false"),
                Some(&path),
            )?;
            let bytes = std::fs::read(path).map_err(|_| "video observer original")?;
            assert_eq!(bytes, expected[index]);
            let fields = [
                "id",
                "ownerId",
                "type",
                "checksum",
                "updatedAt",
                "visibility",
                "livePhotoVideoId",
                "stack",
            ];
            let identity = fields
                .into_iter()
                .map(|field| (field.to_owned(), detail[field].clone()))
                .collect::<serde_json::Map<_, _>>();
            observed.push(json!({"identity":identity,"albumIDs":albums,"originalSHA256":format!("{:x}",sha2::Sha256::digest(bytes))}));
        }
        let value = json!(observed);
        write_json(&output.join("observations.json"), &value)?;
        Ok(value)
    }
    pub fn set_visibility(&self, agent: &ureq::Agent, id: &str, to: &str) -> Result<(), String> {
        assert!(id == self.video || id == self.motion);
        assert!(["timeline", "archive", "locked"].contains(&to));
        let response: HttpResponse = serde_json::from_value(execute(
            agent,
            &self.elevated.request(
                &format!("assets/{id}"),
                "PUT",
                Some(json!({"visibility":to})),
            ),
        )?)
        .map_err(|_| "video external visibility response")?;
        assert_eq!(response.status, 200);
        assert_eq!(response.body["id"], id);
        assert_eq!(response.body["visibility"], to);
        Ok(())
    }
    pub fn close(&self, agent: &ureq::Agent) -> Result<(), String> {
        for path in ["auth/session/lock", "auth/logout"] {
            let response: HttpResponse =
                serde_json::from_value(execute(agent, &self.elevated.request(path, "POST", None))?)
                    .map_err(|_| "video observer close")?;
            assert_eq!(
                response.status,
                if path == "auth/session/lock" {
                    204
                } else {
                    200
                }
            );
        }
        Ok(())
    }
}
fn drive_setup(agent: &ureq::Agent, command: &mut Command<Effect, Event>) -> Result<(), String> {
    loop {
        let effects = command.effects().collect::<Vec<_>>();
        if effects.is_empty() {
            return Ok(());
        }
        for Effect::Io(mut request) in effects {
            let result = match &request.operation {
                ShellOperation::Http(http) => execute(agent, http),
                ShellOperation::Wait { milliseconds } => {
                    std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                    Ok(Value::Null)
                }
                _ => Err("unexpected external video setup effect".into()),
            };
            request
                .resolve(live_response(result))
                .map_err(|_| "video setup resolve")?;
        }
    }
}
pub(super) fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    use std::io::Write;
    let encoded = serde_json::to_vec_pretty(value).map_err(|_| "private video evidence encode")?;
    std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .and_then(|mut file| file.write_all(&encoded))
        .map_err(|_| "private video evidence write".into())
}
