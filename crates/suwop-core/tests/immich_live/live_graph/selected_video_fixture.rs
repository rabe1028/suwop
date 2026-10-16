//! Disposable standalone/native-CID VIDEO graph setup; no public reverse-absence claim.
use super::*;
#[path = "selected_video_observer.rs"]
mod observer;
pub(crate) struct Fixture {
    elevated: Elevated,
    pub email: String,
    pub ids: [String; 4], // V, P, native M, P2
    pub albums: BTreeSet<String>,
    shares: [String; 2],
}
impl Fixture {
    pub fn setup(agent: &ureq::Agent, root: &Path) -> Result<Self, String> {
        let address = std::env::var("SUWOP_IMMICH_URL").map_err(|_| "video C2 URL")?;
        let key =
            std::env::var("SUWOP_IMMICH_API_KEY").map_err(|_| "video C2 fixture credential")?;
        let work = root.to_owned();
        let (sender, receiver) = std::sync::mpsc::channel();
        let mut command = Command::<Effect, Event>::new(move |ctx| async move {
            let result = Box::pin(Self::prepare(&ctx, &address, &key, &work)).await;
            let _ = sender.send(result);
        });
        drive_setup(agent, &mut command)?;
        receiver.recv().map_err(|_| "video C2 setup completion")?
    }
    async fn prepare(ctx: &Context, address: &str, key: &str, root: &Path) -> Result<Self, String> {
        let prefix = "selected-video-write";
        let elevated = setup_named(ctx, address, key, prefix).await?;
        let session = &elevated.ordinary;
        let (parent, albums) =
            ordinary_parent::native_checkpoint_setup(ctx, session, root, prefix).await?;
        let control: Value = serde_json::from_slice(
            &std::fs::read(root.join("parent-control.json")).map_err(|_| "C2 graph control")?,
        )
        .map_err(|_| "C2 graph JSON")?;
        let motion = control["motion"].as_str().ok_or("C2 motion")?.to_owned();
        let other = control["other"]
            .as_str()
            .ok_or("C2 other parent")?
            .to_owned();
        let video = upload(ctx, session, root, "V.mp4", V, ResourceRole::Video, None).await?;
        let admin = immich::connect(ctx, address, key, true).await?;
        crate::wait_metadata_queues(ctx, &admin).await?;
        for album in &albums {
            session
                .change_album_members(ctx, album, std::slice::from_ref(&video), true)
                .await?;
        }
        for id in [&video, &motion] {
            let reply = elevated
                .json(
                    ctx,
                    &format!("assets/{id}"),
                    "PUT",
                    Some(json!({"visibility":"timeline"})),
                )
                .await?;
            assert_eq!(reply["id"], *id);
            assert_eq!(reply["visibility"], "timeline");
        }
        let mut shares = Vec::new();
        for id in [&video, &motion] {
            let share=elevated.json(ctx,"shared-links","POST",Some(json!({"type":"INDIVIDUAL","assetIds":[id],"allowDownload":true,"showMetadata":true}))).await?;
            let value = share["key"].as_str().ok_or("C2 share key")?;
            if value.is_empty()
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            {
                return Err("C2 share encoding".into());
            }
            shares.push(value.to_owned());
        }
        Ok(Self {
            elevated,
            email: format!("{prefix}-{}@example.invalid", std::process::id()),
            ids: [video, parent, motion, other],
            albums: albums.into_iter().collect(),
            shares: shares.try_into().map_err(|_| "two direct shares")?,
        })
    }
    pub fn session(&self) -> Session {
        self.elevated.ordinary.clone()
    }
    pub fn key(&self, index: usize) -> suwop_core::domain::AssetKey {
        suwop_core::domain::AssetKey {
            provider: suwop_core::domain::Provider::Immich,
            scope: self.elevated.ordinary.scope.clone(),
            asset_id: self.ids[index].clone(),
        }
    }
    pub fn observe(
        &self,
        agent: &ureq::Agent,
        root: &Path,
        stage: &str,
        selected: Option<(usize, &str)>,
    ) -> Result<Value, String> {
        observer::observe(self, agent, root, stage, selected)
    }
    pub fn quiet(&self, root: &Path, stage: &str) -> Result<(), String> {
        observer::quiet(self, root, stage)
    }
}
