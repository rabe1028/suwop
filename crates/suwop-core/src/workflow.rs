use crate::{
    app::{ConnectionSettings, Context, Event, SavedLibrary, ShellOperation, io},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ResourceRole, ScanAccess, StoredAsset, TransferBundle,
        TransferFile, TransferIntent, TransferPhase, TransferReceipt, allow_deletion,
        apple_import_plan, verify_destination, verify_source,
    },
    immich::{Asset, Session, connect},
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
mod albums;
mod apple_trash;
mod current_rendering;
mod current_sharing;
mod edit_paste;
mod editing;
mod favorites;
mod media;
mod metadata;
mod reversion;
mod sharing;
mod trash;
mod trash_fence;
mod upload_intents;
mod uploads;

#[derive(Debug)]
pub struct Outcome {
    pub preview_to_select: Option<AssetKey>,
    pub state: SavedLibrary,
    pub session: Option<Session>,
    pub status: String,
    pub error: Option<String>,
}
struct Runtime<'a> {
    // A generation comparison is a cancellation fence, not cross-thread data synchronization.
    // Capture once at workflow start; refresh must never renew an already granted read.
    apple_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    started_generation: u64,
    reversion_started: bool,
    preferred_preview: Option<AssetKey>,
    ctx: &'a Context,
    state: SavedLibrary,
    session: Option<Session>,
    workspace: Option<String>,
    editing_token: Option<String>,
}

/// Standalone contract runners have no concurrent Apple observer.
pub async fn run(
    ctx: &Context,
    event: Event,
    state: SavedLibrary,
    session: Option<Session>,
) -> Outcome {
    run_observed(ctx, event, state, session, std::sync::Arc::default()).await
}

pub async fn run_observed(
    ctx: &Context,
    event: Event,
    state: SavedLibrary,
    session: Option<Session>,
    apple_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
) -> Outcome {
    let started_generation = apple_generation.load(std::sync::atomic::Ordering::Relaxed);
    let mut runtime = Runtime {
        apple_generation,
        started_generation,
        reversion_started: false,
        preferred_preview: None,
        ctx,
        state,
        session,
        workspace: None,
        editing_token: None,
    };
    let metadata_change = matches!(
        event,
        Event::SetFavorite { .. }
            | Event::SetMetadata { .. }
            | Event::CreateAlbum { .. }
            | Event::EditAlbum { .. }
            | Event::EditImage { .. }
            | Event::RevertImage { .. }
            | Event::PastePhotoEdits { .. }
            | Event::PasteSelectedPhotoEdits { .. }
            | Event::ResolveEditPaste { .. }
    );
    let sharing = matches!(event, Event::Share { .. } | Event::ShareCurrentImage { .. });
    let playback = matches!(event, Event::Play { .. });
    let reverting = matches!(event, Event::RevertImage { .. });
    let editing = matches!(
        event,
        Event::EditImage { .. }
            | Event::RevertImage { .. }
            | Event::CopyPhotoEdits { .. }
            | Event::PastePhotoEdits { .. }
            | Event::PasteSelectedPhotoEdits { .. }
            | Event::ResolveEditPaste { .. }
    );
    let mut result = runtime.execute(event).await;
    if let Some(token) = runtime.editing_token.take() {
        let close: Result<Value, _> = io(ctx, ShellOperation::AppleEditClose { token }).await;
        if let Err(error) = close {
            // A native lease may still be using these files. Retain the private
            // workspace instead of deleting underneath the native session.
            runtime.workspace = None;
            result = Err(format!("編集用データを閉じられませんでした: {error}"));
        }
    }
    if let Some(path) = runtime.workspace.take() {
        let cleanup: Result<Value, _> = io(ctx, ShellOperation::Cleanup { path }).await;
        if (sharing || playback || editing)
            && let Err(error) = cleanup
        {
            result = Err(format!("作業ファイルを片付けられませんでした: {error}"));
        }
    }
    match result {
        Ok(status) => Outcome {
            preview_to_select: runtime.preferred_preview,
            state: runtime.state,
            session: runtime.session,
            status,
            error: None,
        },
        Err(error) => Outcome {
            preview_to_select: runtime.preferred_preview,
            state: runtime.state,
            session: runtime.session,
            status: if sharing {
                "共有処理で問題が発生しました。写真と転送履歴は変更していません。"
            } else if playback {
                "再生処理で問題が発生しました。写真と転送履歴は変更していません。"
            } else if reverting && !runtime.reversion_started {
                "原本への復元を開始できませんでした。写真は変更していません。"
            } else if metadata_change {
                "変更が保存済みの場合があります。一覧を更新して確認してください。"
            } else {
                "処理を完了できませんでした。元データと転送履歴を確認してください。"
            }
            .into(),
            error: Some(error),
        },
    }
}
impl Runtime<'_> {
    async fn initialize(&mut self, scope: String) -> Result<String, String> {
        let raw: Value = io(self.ctx, ShellOperation::ReadState).await?;
        self.state = if raw.is_null() {
            SavedLibrary {
                schema_version: 3,
                apple_scope: scope,
                ..SavedLibrary::default()
            }
        } else {
            migrate(raw)?
        };
        for s in &mut self.state.snapshots {
            s.access = ScanAccess::Unavailable;
        }
        for s in &mut self.state.albums {
            s.access = ScanAccess::Unavailable;
        }
        if let Some(trash) = &mut self.state.trash {
            trash.verified = false;
        }
        self.persist().await?;
        Ok("写真ライブラリを接続してください。".into())
    }

    async fn execute(&mut self, event: Event) -> Result<String, String> {
        match event {
            Event::Initialize { scope } => self.initialize(scope).await,
            _ if self.state.schema_version != 3 => {
                Err("ローカル記録が利用できません。転送は無効です。".into())
            }
            Event::Refresh { permission, now } => {
                self.refresh(permission, now).await?;
                Ok("一覧を更新しました。".into())
            }
            Event::Configure {
                address,
                key,
                allow_http,
                id,
                now,
            } => self.configure(&address, &key, allow_http, id, now).await,
            Event::Disconnect => {
                let old = self.state.clone();
                self.state.trash = None;
                self.state.albums.retain(|s| s.provider != Provider::Immich);
                self.state.connection = None;
                self.state
                    .snapshots
                    .retain(|s| s.provider != Provider::Immich);
                if let Err(e) = self.persist().await {
                    self.state = old;
                    return Err(e);
                }
                self.session = None;
                if let Some(connection) = old.connection {
                    let _: Result<Value, _> = io(
                        self.ctx,
                        ShellOperation::RemoveCredential {
                            account: connection.credential_id,
                        },
                    )
                    .await;
                }
                Ok("接続を解除しました。転送履歴は保持しています。".into())
            }
            Event::Index { id } => self.index(&id).await,
            Event::ForgetUploadRecord { key } => self.forget_upload_record(&key).await,
            Event::ForgetUploadIntent { scope, token } => {
                self.forget_upload_intent(&scope, &token).await
            }
            Event::SetFavorite { keys, value } => self.favorite(&keys, value).await,
            Event::SetMetadata { keys, input } => self.change_metadata(&keys, &input).await,
            Event::EditImage { key, id } => self.edit_image(&key, &id).await,
            Event::CopyPhotoEdits { key, options, id } => {
                self.copy_photo_edits(&key, options, &id).await
            }
            Event::PastePhotoEdits { keys, id } => self.paste_photo_edits(&keys, &id).await,
            Event::PasteSelectedPhotoEdits { anchors, id } => {
                let keys = self.selected_paste_keys(&anchors)?;
                self.paste_photo_edits(&keys, &id).await
            }
            Event::ResolveEditPaste { key, id } => self.resolve_edit_paste(&key, &id).await,
            Event::RevertImage { key, id } => self.revert_image(&key, &id).await,
            Event::Share { keys, id } => self.share(&keys, &id).await,
            Event::ShareCurrentImage { key, id } => self.share_current_image(&key, &id).await,
            Event::Play { keys, id } => self.play(&keys, &id).await,
            Event::RefreshAlbums => self.refresh_albums().await,
            Event::RefreshTrash { now } => self.refresh_trash(now).await,
            Event::TrashApple { keys, id } => self.trash_apple(&keys, &id).await,
            Event::ResolveAppleTrash { id } => self.resolve_apple_trash(&id).await,
            Event::ChangeTrash { keys, action, id } => self.change_trash(&keys, action, &id).await,
            Event::ResolveTrash { id } => self.resolve_trash(&id).await,
            Event::CreateAlbum { provider, title } => self.create_album(provider, &title).await,
            Event::EditAlbum { key, edit } => self.edit_album(&key, &edit).await,
            Event::Copy {
                keys,
                intent,
                id,
                now,
            } => {
                self.copy(&keys, intent, &id, now).await?;
                Ok("コピーを検証しました。元データは残っています。".into())
            }
            Event::CompleteMove { id, workspace } => {
                self.complete_move(&id, &workspace).await?;
                Ok("移動が完了しました。転送元のゴミ箱を確認してください。".into())
            }
            _ => Err("不正な操作です。".into()),
        }
    }
    fn preserve_original_fingerprints(&self, fresh: &mut [StoredAsset]) {
        for record in fresh {
            if let Some(old) = self
                .state
                .snapshots
                .iter()
                .flat_map(|s| &s.assets)
                .find(|old| old.key == record.key)
            {
                crate::metadata::preserve_original_fingerprints(old, record);
            }
        }
    }
    fn replace_records(&mut self, fresh: Vec<StoredAsset>) {
        for record in fresh {
            for snapshot in &mut self.state.snapshots {
                if let Some(old) = snapshot.assets.iter_mut().find(|a| a.key == record.key) {
                    *old = record.clone();
                }
            }
        }
    }
    async fn configure(
        &mut self,
        address: &str,
        key: &str,
        allow_http: bool,
        id: String,
        now: f64,
    ) -> Result<String, String> {
        let session = connect(self.ctx, address, key.trim(), allow_http).await?;
        let settings = ConnectionSettings {
            address: session.endpoint.clone(),
            allow_http,
            credential_id: id.clone(),
        };
        let _: Value = io(
            self.ctx,
            ShellOperation::SaveCredential {
                account: id.clone(),
                key: key.trim().into(),
            },
        )
        .await?;
        let old = self.state.clone();
        self.state.albums.retain(|s| s.provider != Provider::Immich);
        self.state.trash = None;
        self.state.connection = Some(settings);
        self.state
            .snapshots
            .retain(|s| s.provider != Provider::Immich);
        if let Err(error) = self.persist().await {
            self.state = old;
            let _: Result<Value, _> =
                io(self.ctx, ShellOperation::RemoveCredential { account: id }).await;
            return Err(error);
        }
        if let Some(connection) = old.connection {
            let _: Result<Value, _> = io(
                self.ctx,
                ShellOperation::RemoveCredential {
                    account: connection.credential_id,
                },
            )
            .await;
        }
        self.session = Some(session);
        self.refresh(false, now).await?;
        Ok("Immich に接続しました。".into())
    }
    async fn index(&mut self, id: &str) -> Result<String, String> {
        self.workspace(id).await?;
        let index = self
            .state
            .snapshots
            .iter()
            .position(|s| s.provider == Provider::Apple && s.access != ScanAccess::Unavailable)
            .ok_or("先に Apple Photos の一覧を更新してください。")?;
        let keys: Vec<_> = self.state.snapshots[index]
            .assets
            .iter()
            .filter(|a| a.content_visible() && !a.fingerprints_complete())
            .map(|a| a.key.clone())
            .collect();
        let mut failures = 0;
        for (n, key) in keys.iter().enumerate() {
            self.progress(&format!("原本を照合中 {} / {}", n + 1, keys.len()));
            match self
                .export(std::slice::from_ref(key), &format!("index-{n}"))
                .await
            {
                Ok(bundle) => {
                    if let Some(asset) = bundle.assets.first()
                        && let Some(old) = self.state.snapshots[index]
                            .assets
                            .iter_mut()
                            .find(|a| a.key == *key)
                    {
                        *old = asset.clone();
                    }
                }
                Err(error) if error == "cancelled" => {
                    self.persist().await?;
                    return Err(error);
                }
                Err(_) => failures += 1,
            }
            if n % 20 == 0 {
                self.persist().await?;
            }
        }
        self.persist().await?;
        Ok(format!("原本の照合が完了しました（失敗 {failures} 件）。"))
    }
    async fn persist(&self) -> Result<(), String> {
        let _: Value = io(self.ctx, ShellOperation::Persist(self.state.clone())).await?;
        self.progress("記録を保存しました。");
        Ok(())
    }
    fn progress(&self, status: &str) {
        self.ctx.send_event(Event::Progress {
            state: self.state.clone(),
            status: status.into(),
        });
    }
    async fn workspace(&mut self, id: &str) -> Result<(), String> {
        self.workspace = Some(io(self.ctx, ShellOperation::Workspace { id: id.into() }).await?);
        Ok(())
    }
    fn directory(&self, name: &str) -> Result<String, String> {
        Ok(format!(
            "{}/{name}",
            self.workspace.as_deref().ok_or("作業領域がありません。")?
        ))
    }
    async fn ensure_session(&mut self) -> Result<(), String> {
        if self.session.is_some() {
            return Ok(());
        }
        if let Some(connection) = &self.state.connection {
            let key: String = io(
                self.ctx,
                ShellOperation::ReadCredential {
                    account: connection.credential_id.clone(),
                },
            )
            .await?;
            self.session =
                Some(connect(self.ctx, &connection.address, &key, connection.allow_http).await?);
        }
        Ok(())
    }
    async fn refresh(&mut self, permission: bool, now: f64) -> Result<(), String> {
        let mut errors = Vec::new();
        match io::<LibrarySnapshot>(
            self.ctx,
            ShellOperation::AppleScan {
                scope: self.state.apple_scope.clone(),
                permission,
            },
        )
        .await
        {
            Ok(mut snapshot) => {
                // Reuse hashes only for the exact same revision and resource inventory.
                let previous: BTreeMap<_, _> = self
                    .state
                    .snapshots
                    .iter()
                    .filter(|s| s.provider == Provider::Apple)
                    .flat_map(|s| &s.assets)
                    .map(|a| (&a.key, a))
                    .collect();
                for asset in &mut snapshot.assets {
                    if let Some(old) = previous
                        .get(&asset.key)
                        .filter(|old| old.revision == asset.revision)
                    {
                        for resource in &mut asset.resources {
                            if let Some(cached) = old.resources.iter().find(|r| {
                                r.id == resource.id
                                    && r.name == resource.name
                                    && r.role == resource.role
                            }) {
                                resource.sha1.clone_from(&cached.sha1);
                                resource.bytes = cached.bytes;
                            }
                        }
                    }
                }
                self.replace(snapshot);
            }
            Err(e) => {
                self.invalidate(Provider::Apple);
                errors.push(e);
            }
        }
        match self.ensure_session().await {
            Ok(()) => {}
            Err(e) => {
                self.invalidate(Provider::Immich);
                errors.push(e);
            }
        }
        if let Some(session) = &self.session {
            match session.list(self.ctx, now).await {
                Ok(assets) => {
                    let by_id: BTreeMap<_, _> = assets.iter().map(|a| (&a.id, a)).collect();
                    let mut records = Vec::new();
                    for asset in &assets {
                        let files = if session.version.uses_cursor() {
                            session.files(self.ctx, &asset.id).await.ok()
                        } else {
                            None
                        };
                        records.push(
                            asset.record(
                                &session.scope,
                                asset
                                    .live_photo_video_id
                                    .as_ref()
                                    .and_then(|id| by_id.get(id).copied()),
                                files.as_deref(),
                            ),
                        );
                    }
                    self.replace(LibrarySnapshot {
                        provider: Provider::Immich,
                        scope: session.scope.clone(),
                        assets: records,
                        access: ScanAccess::Full,
                        scanned_at: Some(now),
                    });
                }
                Err(e) => {
                    self.invalidate(Provider::Immich);
                    errors.push(e);
                }
            }
        }
        self.persist().await?;
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("\n"))
        }
    }
    fn replace(&mut self, snapshot: LibrarySnapshot) {
        self.state
            .snapshots
            .retain(|s| s.provider != snapshot.provider);
        self.state.snapshots.push(snapshot);
    }
    fn invalidate(&mut self, provider: Provider) {
        for s in self
            .state
            .snapshots
            .iter_mut()
            .filter(|s| s.provider == provider)
        {
            s.access = ScanAccess::Unavailable;
        }
    }
    fn check_keys(&self, keys: &[AssetKey]) -> Result<Provider, String> {
        self.check_content_keys(keys)?;
        self.check_identity_keys(keys)
    }
    fn check_content_generation(&self, keys: &[AssetKey]) -> Result<(), String> {
        if keys.iter().any(|k| k.provider == Provider::Apple)
            && self.started_generation
                != self
                    .apple_generation
                    .load(std::sync::atomic::Ordering::Relaxed)
        {
            return Err(
                "読み出し中に Apple Photos のアクセスが変わりました。処理を中止しました。".into(),
            );
        }
        Ok(())
    }
    fn check_content_keys(&self, keys: &[AssetKey]) -> Result<(), String> {
        let access = crate::privacy::ContentAccess::new(&self.state);
        if keys.iter().any(|k| !access.visible(k)) {
            return Err("Apple Photos の可視性を確認して一覧を更新してください。".into());
        }
        Ok(())
    }
    // Scope, exact set and pending-write fences also apply to newly created copies.
    fn check_identity_keys(&self, keys: &[AssetKey]) -> Result<Provider, String> {
        if self
            .state
            .pending_edit_pastes
            .iter()
            .any(|pending| keys.contains(&pending.key))
        {
            return Err(
                "編集の貼り付け結果を先に確認してください。書き込みは再送しません。".into(),
            );
        }
        self.check_apple_trash_keys(keys)?;
        if self
            .state
            .pending_trash
            .iter()
            .flat_map(|operation| &operation.assets)
            .any(|asset| keys.contains(&asset.key))
        {
            return Err("ゴミ箱の操作結果を先に確認してください。書き込みは再送しません。".into());
        }
        let first = keys.first().ok_or("写真が選択されていません。")?;
        let scope = match first.provider {
            Provider::Apple => self.state.apple_scope.as_str(),
            Provider::Immich => self
                .session
                .as_ref()
                .ok_or("Immich に接続してください。")?
                .scope
                .as_str(),
        };
        if keys
            .iter()
            .any(|k| k.provider != first.provider || k.scope != scope)
            || keys.iter().collect::<BTreeSet<_>>().len() != keys.len()
        {
            return Err("写真ライブラリまたはアカウントが一致しません。".into());
        }
        Ok(first.provider)
    }
    async fn immich_record(&self, asset: &Asset) -> Result<StoredAsset, String> {
        let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
        let companion = match &asset.live_photo_video_id {
            Some(id) => Some(session.asset(self.ctx, id).await?),
            None => None,
        };
        let files = if session.version.uses_cursor() {
            session.files(self.ctx, &asset.id).await.ok()
        } else {
            None
        };
        Ok(asset.record(&session.scope, companion.as_ref(), files.as_deref()))
    }
    async fn export(&self, keys: &[AssetKey], name: &str) -> Result<TransferBundle, String> {
        self.check_content_keys(keys)?;
        self.export_readback(keys, name).await
    }
    /// Only fresh keys returned by this operation's import may bypass catalog membership.
    async fn export_readback(
        &self,
        keys: &[AssetKey],
        name: &str,
    ) -> Result<TransferBundle, String> {
        let provider = self.check_identity_keys(keys)?;
        let directory = self.directory(name)?;
        let bundle = match provider {
            Provider::Apple => {
                io(
                    self.ctx,
                    ShellOperation::AppleExport {
                        keys: keys.to_vec(),
                        directory,
                    },
                )
                .await?
            }
            Provider::Immich => {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                let mut assets = Vec::new();
                let mut files = Vec::new();
                for (n, key) in keys.iter().enumerate() {
                    let native = session.asset(self.ctx, &key.asset_id).await?;
                    let mut record = self.immich_record(&native).await?;
                    for (i, resource) in record
                        .resources
                        .iter_mut()
                        .enumerate()
                        .filter(|(_, r)| r.role.is_original())
                    {
                        let path = format!("{directory}/{n}-{i}");
                        session.download(self.ctx, &resource.id, &path).await?;
                        let hash: HashResult =
                            io(self.ctx, ShellOperation::HashFile { path: path.clone() }).await?;
                        if Some(&hash.sha1) != resource.sha1.as_ref() {
                            return Err("Immich の原本とチェックサムが一致しません。".into());
                        }
                        resource.bytes = Some(hash.signature.bytes);
                        files.push(TransferFile {
                            resource: resource.clone(),
                            path,
                            signature: hash.signature,
                        });
                    }
                    let after = session.asset(self.ctx, &key.asset_id).await?;
                    if native.updated_at != after.updated_at || native.checksum != after.checksum {
                        return Err("読み出し中に写真が変更されました。".into());
                    }
                    assets.push(record);
                }
                TransferBundle { assets, files }
            }
        };
        bundle.validate()?;
        if bundle.assets.iter().any(|a| !a.content_visible()) {
            return Err("読み出し中に Apple Photos の可視性が変わりました。".into());
        }
        if bundle
            .assets
            .iter()
            .map(|a| &a.key)
            .collect::<BTreeSet<_>>()
            != keys.iter().collect()
        {
            return Err("転送元の一覧が変わりました。".into());
        }
        Ok(bundle)
    }
    async fn import(
        &mut self,
        bundle: &TransferBundle,
        provider: Provider,
        now: f64,
    ) -> Result<Vec<AssetKey>, String> {
        self.check_content_generation(
            &bundle
                .assets
                .iter()
                .map(|a| a.key.clone())
                .collect::<Vec<_>>(),
        )?;
        self.check_transfer_trash(&bundle.assets)?;
        if provider == Provider::Apple {
            return io(
                self.ctx,
                ShellOperation::AppleImport(apple_import_plan(bundle)?),
            )
            .await;
        }
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        let mut seen = BTreeSet::new();
        let files: Vec<_> = bundle
            .files
            .iter()
            .filter(|f| seen.insert(f.signature.clone()))
            .collect();
        let metadata = bundle.assets.first().ok_or("転送元がありません。")?;
        let live: Vec<_> = files
            .iter()
            .filter(|f| f.resource.role == ResourceRole::LiveVideo)
            .collect();
        if live.len() > 1
            || !live.is_empty()
                && files
                    .iter()
                    .filter(|f| f.resource.role == ResourceRole::Image)
                    .count()
                    != 1
        {
            return Err("複数の Live Photo を一つの転送として扱えません。".into());
        }
        let live_id = match live.first() {
            Some(file) => Some(
                self.upload_file(&session, file, metadata, now, None)
                    .await?,
            ),
            None => None,
        };
        let mut keys = BTreeSet::new();
        for file in files
            .iter()
            .filter(|f| f.resource.role != ResourceRole::LiveVideo)
        {
            let attach = if file.resource.role == ResourceRole::Image {
                live_id.as_deref()
            } else {
                None
            };
            let id = self
                .upload_file(&session, file, metadata, now, attach)
                .await?;
            if attach.is_some()
                && session
                    .asset(self.ctx, &id)
                    .await?
                    .live_photo_video_id
                    .as_deref()
                    != attach
            {
                return Err("Live Photo の関連づけを確認できません。元データは残します。".into());
            }
            keys.insert(AssetKey {
                provider,
                scope: session.scope.clone(),
                asset_id: id,
            });
        }
        Ok(keys.into_iter().collect())
    }
    fn save_receipt(&mut self, receipt: TransferReceipt) {
        if let Some(index) = self.state.receipts.iter().position(|r| r.id == receipt.id) {
            self.state.receipts[index] = receipt;
        } else {
            self.state.receipts.push(receipt);
        }
    }
    async fn copy(
        &mut self,
        keys: &[AssetKey],
        intent: TransferIntent,
        id: &str,
        now: f64,
    ) -> Result<(), String> {
        self.ensure_session().await?;
        let provider = self.check_keys(keys)?;
        self.workspace(id).await?;
        let mut bundle = self.export(keys, "source").await?;
        self.check_transfer_trash(&bundle.assets)?;
        bundle.block_duplicates();
        let destination = provider.other();
        let scope = if destination == Provider::Apple {
            self.state.apple_scope.clone()
        } else {
            self.session
                .as_ref()
                .ok_or("Immich に接続してください。")?
                .scope
                .clone()
        };
        let mut receipt = TransferReceipt {
            id: id.into(),
            created_at: now,
            phase: TransferPhase::Copying,
            intent,
            source: bundle.assets.clone(),
            destination: Vec::new(),
            destination_provider: destination,
            destination_scope: scope,
            signatures: bundle.signatures(),
        };
        self.save_receipt(receipt.clone());
        self.persist().await?;
        let imported = self.import(&bundle, destination, now).await?;
        let verification = self.export_readback(&imported, "verify").await?;
        receipt.destination = verification.assets.clone();
        verify_destination(&receipt, &verification)?;
        receipt.phase = TransferPhase::Copied;
        self.save_receipt(receipt);
        self.persist().await
    }
    async fn complete_move(&mut self, id: &str, workspace: &str) -> Result<(), String> {
        self.ensure_session().await?;
        let mut receipt = self
            .state
            .receipts
            .iter()
            .find(|r| r.id == id)
            .cloned()
            .ok_or("移動記録がありません。")?;
        if !receipt.move_blockers().is_empty() {
            return Err(receipt.move_blockers().join(" / "));
        }
        self.check_transfer_trash(&receipt.source)?;
        self.check_transfer_trash(&receipt.destination)?;
        self.check_keys(
            &receipt
                .source
                .iter()
                .map(|a| a.key.clone())
                .collect::<Vec<_>>(),
        )?;
        self.check_keys(
            &receipt
                .destination
                .iter()
                .map(|a| a.key.clone())
                .collect::<Vec<_>>(),
        )?;
        self.workspace(workspace).await?;
        let mut source = self
            .export(
                &receipt
                    .source
                    .iter()
                    .map(|a| a.key.clone())
                    .collect::<Vec<_>>(),
                "source",
            )
            .await?;
        verify_source(&receipt, &mut source)?;
        let destination = self
            .export(
                &receipt
                    .destination
                    .iter()
                    .map(|a| a.key.clone())
                    .collect::<Vec<_>>(),
                "target",
            )
            .await?;
        verify_destination(&receipt, &destination)?;
        // Persist first: a failed write must never be followed by deletion.
        receipt.phase = TransferPhase::DeletingSource;
        self.save_receipt(receipt.clone());
        self.persist().await?;
        let result = self.trash(&source.assets).await;
        receipt.phase = if result.is_ok() {
            TransferPhase::Moved
        } else {
            TransferPhase::DeletionUncertain
        };
        self.save_receipt(receipt);
        self.persist().await?;
        result.map_err(|e| format!("削除結果を確認してください。自動再試行はしません。{e}"))
    }
    async fn trash(&self, assets: &[StoredAsset]) -> Result<(), String> {
        allow_deletion(assets)?;
        if assets[0].key.provider == Provider::Apple {
            let _: Value = io(
                self.ctx,
                ShellOperation::AppleTrash {
                    assets: assets.to_vec(),
                },
            )
            .await?;
            return Ok(());
        }
        let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
        for saved in assets {
            let current = self
                .immich_record(&session.asset(self.ctx, &saved.key.asset_id).await?)
                .await?;
            allow_deletion(std::slice::from_ref(&current))?;
            if current.revision != saved.revision {
                return Err("削除直前に写真の状態が変わりました。".into());
            }
        }
        session
            .trash(
                self.ctx,
                &assets
                    .iter()
                    .map(|a| a.key.asset_id.clone())
                    .collect::<Vec<_>>(),
            )
            .await
    }
}
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct HashResult {
    pub sha1: String,
    pub signature: crate::domain::FileSignature,
}

pub fn migrate(mut raw: Value) -> Result<SavedLibrary, String> {
    let version = raw["schemaVersion"]
        .as_u64()
        .ok_or("カタログ形式が不正です。既存ファイルは変更しません。")?;
    if ![1, 2, 3].contains(&version) {
        return Err("未対応のカタログ形式です。既存ファイルは変更しません。".into());
    }
    if version == 1 {
        convert_dates(&mut raw);
        raw["schemaVersion"] = Value::from(2);
        if let Some(receipts) = raw["receipts"].as_array_mut() {
            for r in receipts {
                r["intent"] = Value::from("copy");
            }
        }
    }
    raw["schemaVersion"] = Value::from(3);
    serde_json::from_value(raw)
        .map_err(|e| format!("カタログを読み出せません。既存ファイルは変更しません。{e}"))
}
fn convert_dates(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                if ["createdAt", "capturedAt", "modifiedAt", "scannedAt"].contains(&key.as_str()) {
                    if let Some(old) = value.as_f64() {
                        *value = Value::from(old + 978_307_200.0);
                    }
                } else {
                    convert_dates(value);
                }
            }
        }
        Value::Array(array) => {
            for v in array {
                convert_dates(v);
            }
        }
        _ => {}
    }
}
