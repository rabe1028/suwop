//! External setup and independent observer; never part of the product Inspect effect trace.
use super::*;
pub(super) const STILL_SHA1: &str = "2ad1f4d64d8e8d78751e2af0145e4f79382875f4";
pub(super) struct Fixture {
    pub elevated: Elevated,
    pub email: String,
    pub parent: String,
    pub motion: String,
    other: String,
    albums: Vec<String>,
}
impl Fixture {
    pub fn setup(agent: &ureq::Agent, directory: &Path) -> Result<Self, String> {
        let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "fixture URL")?;
        let key = std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "fixture key")?;
        let work = directory.to_path_buf();
        let (sender, receiver) = std::sync::mpsc::channel();
        let mut command = Command::<Effect, Event>::new(move |ctx| async move {
            let result = Box::pin(Self::prepare(&ctx, &address, &key, &work)).await;
            let _ = sender.send(result);
        });
        loop {
            let effects = command.effects().collect::<Vec<_>>();
            if effects.is_empty() {
                break;
            }
            for Effect::Io(mut request) in effects {
                let result = match &request.operation {
                    ShellOperation::Http(http) => execute(agent, http),
                    ShellOperation::Wait { milliseconds } => {
                        std::thread::sleep(Duration::from_millis(u64::from(*milliseconds)));
                        Ok(Value::Null)
                    }
                    _ => Err("unexpected external setup effect".into()),
                };
                request
                    .resolve(live_response(result))
                    .map_err(|_| "setup resolve")?;
            }
        }
        receiver.recv().map_err(|_| "setup completion")?
    }
    async fn prepare(
        ctx: &Context,
        address: &str,
        key: &str,
        directory: &Path,
    ) -> Result<Self, String> {
        let elevated = setup_named(ctx, address, key, "selected-recovery").await?;
        let ordinary = &elevated.ordinary;
        let (parent, albums) =
            super::super::ordinary_parent::recovery_native_parent_setup(ctx, ordinary, directory)
                .await?;
        let control: Value = serde_json::from_slice(
            &std::fs::read(directory.join("parent-control.json")).map_err(|_| "control read")?,
        )
        .map_err(|_| "control decode")?;
        let motion = control["motion"].as_str().ok_or("motion id")?.to_owned();
        let other = control["other"].as_str().ok_or("other id")?.to_owned();
        // Public explicit setup, not a current product transition or automatic metadata cause.
        elevated
            .json(
                ctx,
                &format!("assets/{parent}"),
                "PUT",
                Some(json!({"livePhotoVideoId":null})),
            )
            .await?;
        let unlinked = elevated
            .json(ctx, &format!("assets/{parent}"), "GET", None)
            .await?;
        assert_eq!(unlinked["visibility"], "timeline");
        assert!(unlinked["livePhotoVideoId"].is_null() && unlinked["stack"].is_null());
        assert_eq!(
            suwop_core::domain::normalize_sha1(unlinked["checksum"].as_str()).as_deref(),
            Some(STILL_SHA1)
        );
        assert_eq!(unlinked["ownerId"], ordinary.user_id);
        let unlinked_motion = elevated
            .json(ctx, &format!("assets/{motion}"), "GET", None)
            .await?;
        assert_eq!(unlinked_motion["visibility"], "timeline");
        let memberships = elevated
            .json(ctx, &format!("albums?assetId={parent}"), "GET", None)
            .await?;
        let actual = memberships
            .as_array()
            .ok_or("setup memberships")?
            .iter()
            .map(|a| a["id"].as_str().ok_or("setup album id"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        assert_eq!(actual, albums.iter().map(String::as_str).collect());
        for album in &albums {
            ordinary
                .change_album_members(ctx, album, std::slice::from_ref(&parent), false)
                .await?;
        }
        elevated
            .json(
                ctx,
                &format!("assets/{parent}"),
                "PUT",
                Some(json!({"visibility":"locked"})),
            )
            .await?;
        let locked = elevated
            .json(ctx, &format!("assets/{parent}"), "GET", None)
            .await?;
        assert_eq!(locked["visibility"], "locked");
        assert!(locked["livePhotoVideoId"].is_null());
        elevated
            .json(
                ctx,
                &format!("assets/{parent}"),
                "PUT",
                Some(json!({"livePhotoVideoId":motion})),
            )
            .await?;
        Ok(Self {
            elevated,
            email: format!("selected-recovery-{}@example.invalid", std::process::id()),
            parent,
            motion,
            other,
            albums,
        })
    }
    pub fn key(&self) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: self.elevated.ordinary.scope.clone(),
            asset_id: self.parent.clone(),
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
        let response: HttpResponse =
            serde_json::from_value(execute(agent, &request)?).map_err(|_| "observer response")?;
        immich::check_status(response.status)?;
        Ok(response.body)
    }
    pub fn observe(&self, agent: &ureq::Agent, directory: &Path) -> Result<Value, String> {
        let pair = native_pair_bytes()?;
        let expected = [pair.0, pair.1, png(1)?];
        let mut observations = Vec::new();
        for (index, id) in [&self.parent, &self.motion, &self.other]
            .into_iter()
            .enumerate()
        {
            let detail = self.get(agent, &format!("assets/{id}"), None)?;
            assert_eq!(detail["id"], *id);
            assert_eq!(detail["ownerId"], self.elevated.ordinary.user_id);
            assert_eq!(detail["type"], if index == 1 { "VIDEO" } else { "IMAGE" });
            if index == 0 {
                assert_eq!(detail["visibility"], "locked");
                assert_eq!(detail["livePhotoVideoId"], self.motion);
                assert!(detail["stack"].is_null());
                assert_eq!(
                    suwop_core::domain::normalize_sha1(detail["checksum"].as_str()).as_deref(),
                    Some(STILL_SHA1)
                );
            }
            let membership = self.get(agent, &format!("albums?assetId={id}"), None)?;
            let memberships = membership
                .as_array()
                .ok_or("observer albums")?
                .iter()
                .map(|a| {
                    a["id"]
                        .as_str()
                        .map(str::to_owned)
                        .ok_or("observer album id")
                })
                .collect::<Result<BTreeSet<_>, _>>()?;
            if index == 0 {
                assert!(memberships.is_empty());
            }
            if index == 2 {
                assert_eq!(detail["visibility"], "timeline");
                assert_eq!(detail["livePhotoVideoId"], self.motion);
                assert_eq!(memberships, self.albums.iter().cloned().collect());
            }
            let path = directory.join(format!("observer-{index}.bin"));
            self.get(
                agent,
                &format!("assets/{id}/original?edited=false"),
                Some(&path),
            )?;
            let bytes = std::fs::read(path).map_err(|_| "observer original")?;
            assert_eq!(bytes, expected[index]);
            let identity = [
                "id",
                "ownerId",
                "type",
                "checksum",
                "visibility",
                "livePhotoVideoId",
            ]
            .into_iter()
            .map(|field| (field.to_owned(), detail[field].clone()))
            .collect::<serde_json::Map<_, _>>();
            observations.push(json!({"identity":identity,"albumIDs":memberships,"originalSHA256":format!("{:x}",sha2::Sha256::digest(bytes))}));
        }
        Ok(json!(observations))
    }
    pub fn close(&self, agent: &ureq::Agent) -> Result<(), String> {
        for path in ["auth/session/lock", "auth/logout"] {
            let response: HttpResponse =
                serde_json::from_value(execute(agent, &self.elevated.request(path, "POST", None))?)
                    .map_err(|_| "observer close")?;
            immich::check_status(response.status)?;
        }
        Ok(())
    }
}
