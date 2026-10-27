use crate::{
    app::{ConnectionSettings, Context, Event, SavedLibrary, ShellOperation, io},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferBundle,
        TransferIntent, TransferPhase, TransferReceipt,
    },
    immich::{Asset, Session, connect},
    provider::{
        Ability, AmazonBackend, AppleBackend, CreatedCopies, DeletionOutcome, ExportRequest,
        ImmichBackend, ImportRequest, ListRequest, Listing, OriginalImport, ReadIo, Registry,
    },
    transfer_lifecycle::{DeletionAuthority, LifecycleEffect, LifecycleEvent},
    transport::OrdinarySessionGuard,
};
use futures::StreamExt;
use journal::JournalChange;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
mod albums;
mod amazon;
mod apple_trash;
mod apple_visibility;
mod collections;
mod current_media;
mod current_rendering;
mod current_sharing;
mod edit_paste;
mod editing;
mod external_import;
mod favorites;
pub(crate) mod journal;
mod media;
mod metadata;
mod metadata_admission;
mod metadata_extended;
#[cfg(test)]
mod registry_tests;
mod reversion;
mod sharing;
mod status;
pub(crate) use status::initial_status;
pub(crate) fn metadata_event_blocked(event: &Event, state: &SavedLibrary) -> bool {
    metadata_admission::blocked(event, state)
}
mod trash;
mod trash_fence;
mod upload_intents;
mod uploads;

#[derive(Debug, Clone)]
pub struct Outcome {
    pub(crate) refresh_persist_issued: bool,
    pub(crate) ordinary_selected: Vec<crate::ordinary_selected::VerifiedPresentation>,
    pub preview_to_select: Option<AssetKey>,
    pub state: SavedLibrary,
    pub session: Option<Session>,
    pub status: String,
    pub error: Option<String>,
}
struct Runtime<'a> {
    refresh_persist_issued: bool,
    ordinary_selected: Vec<crate::ordinary_selected::VerifiedPresentation>,
    denied_content: BTreeSet<AssetKey>,
    ordinary_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    started_ordinary_generation: u64,
    ordinary_revision: String,
    // Only a session the model already holds may be published before Finished.
    session_published: bool,
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
    /// Abilities installed in place of the real services (test seam).
    injected_registry: Option<Registry>,
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
    run_guarded(
        ctx,
        event,
        state,
        session,
        apple_generation,
        BTreeSet::new(),
        std::sync::Arc::default(),
    )
    .await
}

pub async fn run_guarded(
    ctx: &Context,
    event: Event,
    state: SavedLibrary,
    session: Option<Session>,
    apple_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
    denied_content: BTreeSet<AssetKey>,
    ordinary_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
) -> Outcome {
    let started_generation = apple_generation.load(std::sync::atomic::Ordering::Relaxed);
    let started_ordinary_generation = ordinary_generation.load(std::sync::atomic::Ordering::SeqCst);
    let revision = crate::app::ordinary_revision(
        session.as_ref().map(|s| s.scope.as_str()),
        started_ordinary_generation,
    );
    let mut session = session;
    if let Some(session) = &mut session {
        bind_ordinary_context(
            session,
            &ordinary_generation,
            started_ordinary_generation,
            &revision,
        );
    }
    let mut runtime = Runtime {
        refresh_persist_issued: false,
        ordinary_selected: Vec::new(),
        ordinary_generation,
        started_ordinary_generation,
        ordinary_revision: revision.clone(),
        session_published: session.is_some(),
        denied_content,
        apple_generation,
        started_generation,
        reversion_started: false,
        preferred_preview: None,
        ctx,
        state,
        session,
        workspace: None,
        editing_token: None,
        injected_registry: None,
    };
    let metadata_change = metadata_event(&event);
    let sharing = matches!(
        event,
        Event::Share { .. } | Event::ShareCurrentImage { .. } | Event::ShareCurrentImages { .. }
    );
    let playback = matches!(event, Event::Play { .. });
    let reverting = matches!(event, Event::RevertImage { .. });
    let editing = editing_event(&event);
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
    if let Some(session) = &mut runtime.session {
        session.ordinary_content_context = None;
        session.ordinary_content_guard = None;
    }
    match result {
        Ok(status) => Outcome {
            refresh_persist_issued: runtime.refresh_persist_issued,
            ordinary_selected: runtime.ordinary_selected,
            preview_to_select: runtime.preferred_preview,
            state: runtime.state,
            session: runtime.session,
            status,
            error: None,
        },
        Err(error) => Outcome {
            refresh_persist_issued: runtime.refresh_persist_issued,
            ordinary_selected: Vec::new(),
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
impl<'a> Runtime<'a> {
    /// Read authority bound to the access generations captured at start.
    fn read_io(&self) -> ReadIo<'a> {
        ReadIo::new(
            self.ctx,
            (
                self.ordinary_generation.clone(),
                self.started_ordinary_generation,
            ),
            (self.apple_generation.clone(), self.started_generation),
        )
    }

    /// Backends for the current immutable connection settings.
    fn registry(&self) -> Registry {
        if let Some(registry) = &self.injected_registry {
            return registry.clone();
        }
        Registry::services(
            AppleBackend::new(self.state.apple_scope.clone()),
            self.session.clone().map(ImmichBackend::new),
            self.amazon_backend().ok(),
        )
    }

    fn amazon_backend(&self) -> Result<AmazonBackend, String> {
        let connection = self
            .state
            .amazon_connection
            .clone()
            .ok_or("Amazon Photosに接続してください。")?;
        Ok(AmazonBackend::new(
            connection,
            self.ordinary_revision.clone(),
            OrdinarySessionGuard {
                generation: self.ordinary_generation.clone(),
                expected: self.started_ordinary_generation,
            },
        ))
    }
}

impl Runtime<'_> {
    async fn initialize(&mut self, scope: String) -> Result<String, String> {
        let raw: Value = io(self.ctx, ShellOperation::ReadState).await?;
        self.state = if raw.is_null() {
            SavedLibrary {
                schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
                apple_scope: scope,
                ..SavedLibrary::default()
            }
        } else {
            migrate(raw)?
        };
        for s in &mut self.state.snapshots {
            s.access = ScanAccess::Unavailable;
        }
        // No deletion attempt survives a restart: a saved DeletingSource may
        // already have deleted and is never issued again.
        for receipt in &mut self.state.receipts {
            if let Some(step) = crate::transfer_lifecycle::recover(receipt) {
                *receipt = step.receipt;
            }
        }
        for s in &mut self.state.albums {
            s.access = ScanAccess::Unavailable;
        }
        self.invalidate_amazon();
        if let Some(trash) = &mut self.state.trash {
            trash.verified = false;
        }
        self.persist().await?;
        Ok("写真ライブラリを接続してください。".into())
    }

    async fn disconnect(&mut self) -> Result<String, String> {
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

    /// Select one directly awaited operation future, rather than one generator containing
    /// every operation's inline state. No task/executor or effect is started at dispatch.
    fn execute(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        if metadata_admission::blocked(&event, &self.state) {
            return Box::pin(async {
                Err("この写真には結果不明の情報変更があります。変更履歴で保存先の状態を確認してください。自動再送は行いません。".into())
            });
        }
        match event {
            Event::Initialize { scope } => Box::pin(async move { self.initialize(scope).await }),
            _ if self.state.schema_version != crate::immich_live_writes::CURRENT_SCHEMA_VERSION => {
                Box::pin(async move {
                    Err("ローカル記録が利用できません。転送は無効です。".into())
                })
            }
            event => self.execute_ready(event),
        }
    }

    fn execute_import_share(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        match event {
            Event::InspectImport { id } => Box::pin(async move {
                self.inspect_import(&id).await?;
                Ok("取り込み先の確認を完了しました。".into())
            }),
            Event::ImportStaged {
                id,
                destination,
                items,
                now,
            } => Box::pin(async move {
                self.import_staged(&id, destination, items, now).await?;
                Ok("取り込み結果を記録しました。".into())
            }),
            Event::Duplicate {
                keys,
                destination,
                current,
                id,
                now,
            } => Box::pin(async move {
                self.duplicate(&keys, destination, current, &id, now)
                    .await?;
                Ok("複製結果を記録しました。".into())
            }),
            Event::ShareCurrentImages {
                keys,
                id,
                remove_location,
            } => Box::pin(
                async move { self.share_current_images(&keys, &id, remove_location).await },
            ),
            Event::ShareCurrentImage { key, id } => {
                Box::pin(async move { self.share_current_image(&key, &id).await })
            }
            _ => Box::pin(async { Err("不正な操作です。".into()) }),
        }
    }

    fn execute_metadata_event(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        match event {
            Event::EditMetadata { keys, edit, id } => {
                Box::pin(async move { self.edit_metadata(&keys, &edit, &id, None).await })
            }
            Event::InspectMetadata { operation_id } => {
                Box::pin(async move { self.inspect_metadata(&operation_id).await })
            }
            Event::RestoreMetadata {
                id,
                operation_id,
                original,
            } => Box::pin(async move { self.restore_metadata(&id, &operation_id, original).await }),
            _ => Box::pin(async { Err("不正な操作です。".into()) }),
        }
    }

    fn execute_transfer_event(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        match event {
            Event::Copy {
                keys,
                intent,
                id,
                now,
            } => Box::pin(async move {
                self.copy(&keys, intent, &id, now).await?;
                Ok("コピーを検証しました。元データは残っています。".into())
            }),
            Event::CompleteMove { id, workspace } => Box::pin(async move {
                self.complete_move(&id, &workspace).await?;
                Ok("移動が完了しました。転送元のゴミ箱を確認してください。".into())
            }),
            _ => Box::pin(async { Err("不正な操作です。".into()) }),
        }
    }

    fn execute_ready(
        &mut self,
        event: Event,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<String, String>> + Send + '_>>
    {
        match event {
            event @ (Event::ConfigureAmazon { .. }
            | Event::DisconnectAmazon
            | Event::ResolveAmazonUploads { .. }
            | Event::CopyTo { .. }) => self.execute_provider_event(event),
            Event::HideApple { keys, id } => {
                Box::pin(async move { self.hide_apple(&keys, &id).await })
            }
            Event::UnhideApple { record_id, id } => {
                Box::pin(async move { self.unhide_apple(&record_id, &id).await })
            }
            Event::InspectAppleVisibility { record_id } => {
                Box::pin(async move { self.inspect_visibility_record(&record_id).await })
            }
            Event::Refresh { permission, now } => Box::pin(async move {
                self.refresh(permission, now).await?;
                Ok("一覧を更新しました。".into())
            }),
            Event::Configure {
                address,
                key,
                allow_http,
                id,
                now,
            } => Box::pin(async move { self.configure(&address, &key, allow_http, id, now).await }),
            Event::Disconnect => Box::pin(async move { self.disconnect().await }),
            Event::Index { id } => Box::pin(async move { self.index(&id).await }),
            Event::ForgetUploadRecord { key } => {
                Box::pin(async move { self.forget_upload_record(&key).await })
            }
            Event::ForgetUploadIntent { scope, token } => {
                Box::pin(async move { self.forget_upload_intent(&scope, &token).await })
            }
            Event::SetFavorite { keys, value } => {
                Box::pin(async move { self.favorite(&keys, value).await })
            }
            event @ (Event::EditMetadata { .. }
            | Event::InspectMetadata { .. }
            | Event::RestoreMetadata { .. }) => self.execute_metadata_event(event),
            Event::EditCollection { provider, edit } => {
                Box::pin(async move { self.edit_collection(provider, &edit).await })
            }
            Event::SetMetadata { keys, input } => {
                Box::pin(async move { self.change_metadata(&keys, &input).await })
            }
            Event::EditImage { key, id } => {
                Box::pin(async move { self.edit_image(&key, &id).await })
            }
            Event::CopyPhotoEdits { key, options, id } => {
                Box::pin(async move { self.copy_photo_edits(&key, options, &id).await })
            }
            Event::PastePhotoEdits { keys, id } => {
                Box::pin(async move { self.paste_photo_edits(&keys, &id).await })
            }
            Event::PasteSelectedPhotoEdits { anchors, id } => Box::pin(async move {
                let keys = self.selected_paste_keys(&anchors)?;
                self.paste_photo_edits(&keys, &id).await
            }),
            Event::ResolveEditPaste { key, id } => {
                Box::pin(async move { self.resolve_edit_paste(&key, &id).await })
            }
            Event::RevertImage { key, id } => {
                Box::pin(async move { self.revert_image(&key, &id).await })
            }
            Event::Share { keys, id } => Box::pin(async move { self.share(&keys, &id).await }),
            event @ (Event::InspectImport { .. }
            | Event::ImportStaged { .. }
            | Event::Duplicate { .. }
            | Event::ShareCurrentImages { .. }
            | Event::ShareCurrentImage { .. }) => self.execute_import_share(event),
            Event::Play { keys, id } => Box::pin(async move { self.play(&keys, &id).await }),
            Event::RefreshAlbums => Box::pin(async move { self.refresh_albums().await }),
            Event::RefreshTrash { now } => Box::pin(async move { self.refresh_trash(now).await }),
            Event::TrashApple { keys, id } => {
                Box::pin(async move { self.trash_apple(&keys, &id).await })
            }
            Event::ResolveAppleTrash { id } => {
                Box::pin(async move { self.resolve_apple_trash(&id).await })
            }
            Event::ChangeTrash { keys, action, id } => {
                Box::pin(async move { self.change_trash(&keys, action, &id).await })
            }
            Event::ResolveTrash { id } => Box::pin(async move { self.resolve_trash(&id).await }),
            Event::CreateAlbum { provider, title } => {
                Box::pin(async move { self.create_album(provider, &title).await })
            }
            Event::EditAlbum { key, edit } => {
                Box::pin(async move { self.edit_album(&key, &edit).await })
            }
            event @ (Event::Copy { .. } | Event::CompleteMove { .. }) => {
                self.execute_transfer_event(event)
            }
            _ => Box::pin(async move { Err("不正な操作です。".into()) }),
        }
    }
    fn preserve_original_fingerprints(&self, fresh: &mut [StoredAsset]) {
        for record in fresh {
            if let Some(old) = self
                .state
                .snapshots
                .iter()
                .flat_map(|s| &s.assets)
                .chain(
                    self.state
                        .receipts
                        .iter()
                        .filter(|r| r.phase != TransferPhase::Copying)
                        .flat_map(|r| r.source.iter().chain(&r.destination)),
                )
                .find(|old| {
                    old.key == record.key
                        && (record.key.provider != Provider::Amazon
                            || old.revision == record.revision)
                })
            {
                if record.key.provider == Provider::Amazon {
                    crate::amazon::preserve_fingerprints(old, record);
                } else {
                    crate::metadata::preserve_original_fingerprints(old, record);
                }
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
        let keys: Vec<_> = self
            .state
            .snapshots
            .iter()
            .filter(|s| {
                matches!(s.provider, Provider::Apple | Provider::Amazon)
                    && s.access != ScanAccess::Unavailable
            })
            .flat_map(|s| &s.assets)
            .filter(|a| {
                self.state.apple_content_visible(&a.key)
                    && !self.denied_content.contains(&a.key)
                    && !a.fingerprints_complete()
            })
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
                    self.replace_records(bundle.assets);
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
            session: None,
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
            let mut session =
                connect(self.ctx, &connection.address, &key, connection.allow_http).await?;
            self.check_ordinary_generation()?;
            session.ordinary_content_guard = Some(crate::immich::OrdinarySessionGuard {
                generation: self.ordinary_generation.clone(),
                expected: self.started_ordinary_generation,
            });
            session.ordinary_content_context = Some(crate::immich::OrdinaryContentAuthorization {
                source_keys: vec![],
                expected_revision: self.ordinary_revision.clone(),
                purpose: crate::immich::OrdinaryContentPurpose::Read,
            });
            self.session = Some(session);
        }
        Ok(())
    }
    async fn refresh(&mut self, permission: bool, now: f64) -> Result<(), String> {
        self.check_content_generation(&[])?;
        let mut errors = Vec::new();
        self.ctx.send_event(Event::FetchProgress {
            status: "Apple Photos の一覧を確認中…".into(),
        });
        let registry = self.registry();
        let listing = match registry.listing(Provider::Apple) {
            Some(apple) => {
                apple
                    .list(self.read_io(), ListRequest { permission, now })
                    .await
            }
            None => Err(registry.missing(Provider::Apple, Ability::Listing)),
        };
        match listing.map(Listing::into_snapshot) {
            Ok((mut snapshot, _)) => {
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
        self.refresh_immich(now, &mut errors).await?;
        match self.refresh_amazon(now).await {
            Ok(None) => {}
            // A Limited partial catalog at the page cap is kept, not invalidated.
            Ok(Some(warning)) => errors.push(warning),
            Err(error) => {
                self.invalidate_amazon();
                errors.push(error);
            }
        }
        self.check_content_generation(&[])?;
        self.ctx.send_event(Event::FetchProgress {
            status: "取得したカタログを保存中…".into(),
        });
        self.refresh_persist_issued = true;
        let _: Value = io(self.ctx, ShellOperation::Persist(self.state.clone())).await?;
        self.check_content_generation(&[])?;
        self.progress("記録を保存しました。");
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("\n"))
        }
    }
    async fn refresh_immich(&mut self, now: f64, errors: &mut Vec<String>) -> Result<(), String> {
        if let Some(session) = &self.session {
            match session.list(self.ctx, now).await {
                Ok(assets) => {
                    let by_id: BTreeMap<_, _> = assets.iter().map(|a| (&a.id, a)).collect();
                    let mut records = Vec::new();
                    let total = assets.len();
                    self.ctx.send_event(Event::FetchProgress {
                        status: format!("Immich の詳細を取得中: 0 / {total} 件"),
                    });
                    // Bound native requests; publish verified subsets as Limited so
                    // incomplete enumeration never authorizes a Move.
                    // Do not clone the previous full remote catalog at every
                    // publication only to discard it again. Keep failure recovery
                    // in self.state and clone a remote-free base for partial views.
                    let mut partial_base = self.state.clone();
                    partial_base
                        .snapshots
                        .retain(|s| s.provider != Provider::Immich);
                    let mut proofs = Vec::new();
                    let mut completed = 0;
                    let pending: Vec<_> = assets
                        .iter()
                        .map(|asset| self.refresh_immich_record(session, asset, &by_id))
                        .collect();
                    let mut hydration = futures::stream::iter(pending).buffer_unordered(32);
                    let mut failure = None;
                    while let Some(result) = hydration.next().await {
                        let result = self.check_content_generation(&[]).and(result);
                        let record = match result {
                            Ok(record) => record,
                            Err(error) => {
                                failure = Some(error);
                                break;
                            }
                        };
                        completed += 1;
                        if let Some((record, proof)) = record {
                            records.push(record);
                            if let Some(proof) = proof {
                                proofs.push(proof);
                            }
                        }
                        // Publish the first batch promptly, then amortize full-view work.
                        // The canonical workflow state stays private until completion.
                        if completed == 32 || completed % 512 == 0 {
                            let mut partial = partial_base.clone();
                            partial.snapshots.push(LibrarySnapshot {
                                provider: Provider::Immich,
                                scope: session.scope.clone(),
                                assets: records.clone(),
                                access: ScanAccess::Limited,
                                scanned_at: Some(now),
                            });
                            self.ctx.send_event(Event::Progress {
                                state: partial,
                                // A session this workflow established changes the
                                // ordinary revision that its in-flight reads carry.
                                session: self.session_published.then(|| session.clone()),
                                status: "取得済みの写真を表示しています。".into(),
                            });
                        }
                        if completed % 32 == 0 || completed == total {
                            self.ctx.send_event(Event::FetchProgress {
                                status: format!("Immich の詳細を取得中: {completed} / {total} 件"),
                            });
                        }
                    }
                    drop(hydration);
                    self.ordinary_selected.extend(proofs);
                    if let Some(error) = failure {
                        return Err(error);
                    }
                    self.check_content_generation(&[])?;
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
        Ok(())
    }
    async fn refresh_immich_record(
        &self,
        session: &Session,
        asset: &Asset,
        by_id: &BTreeMap<&String, &Asset>,
    ) -> Result<
        Option<(
            StoredAsset,
            Option<crate::ordinary_selected::VerifiedPresentation>,
        )>,
        String,
    > {
        let key = AssetKey {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            asset_id: asset.id.clone(),
        };
        if self
            .state
            .immich_visibility_operations
            .iter()
            .any(|o| o.key == key && o.selected_observation.is_some())
        {
            return Ok(self
                .selected_candidate(session, &key)
                .await
                .map(|proof| (proof.asset.clone(), Some(proof))));
        }
        let tracked = self
            .state
            .immich_visibility_operations
            .iter()
            .filter(|o| o.key == key && o.observation.is_some())
            .collect::<Vec<_>>();
        if !tracked.is_empty() {
            let raw = self.visibility_reconciliation(session, &key).await;
            let verified = raw.ok().and_then(|v| {
                crate::immich_visibility::reconciliation_facts(
                    &v,
                    &session.scope,
                    &session.user_id,
                    &tracked,
                )
                .ok()
            });
            if !verified.is_some_and(|f| {
                f.key == key
                    && f.visibility != crate::immich_visibility::ImmichVisibility::Locked
                    && tracked.iter().all(|o| {
                        o.witness_digest == f.witness
                            && matches!(
                                o.observation,
                                Some(
                                    crate::immich_visibility::ImmichVisibility::Timeline
                                        | crate::immich_visibility::ImmichVisibility::Archive
                                )
                            )
                    })
            }) {
                return Ok(None);
            }
        }
        let companion = asset
            .live_photo_video_id
            .as_ref()
            .and_then(|id| by_id.get(id).copied());
        let record =
            crate::provider::hydrate_immich(session, &self.read_io(), asset, companion).await?;
        Ok(Some((record, None)))
    }
    async fn selected_candidate(
        &self,
        session: &Session,
        key: &AssetKey,
    ) -> Option<crate::ordinary_selected::VerifiedPresentation> {
        if self.denied_content.contains(key)
            || self.state.protected_entries.iter().any(|e| e.key == *key)
        {
            return None;
        }
        let raw = self.selected_reconciliation(session, key).await.ok()?;
        let proof = crate::ordinary_selected::VerifiedPresentation::from_fresh(
            &raw,
            &self.state,
            session,
            self.started_ordinary_generation,
        )
        .ok()?;
        (proof.asset.key == *key).then_some(proof)
    }
    async fn selected_reconciliation(
        &self,
        session: &Session,
        key: &AssetKey,
    ) -> Result<Value, String> {
        self.check_content_generation(std::slice::from_ref(key))?;
        crate::immich::valid_id(&key.asset_id)?;
        if key.provider != Provider::Immich
            || key.scope != session.scope
            || !self
                .state
                .immich_visibility_operations
                .iter()
                .any(|o| o.key == *key && o.selected_observation.is_some())
        {
            return Err("確認記録がありません。".into());
        }
        let mut request = session.request(&format!("assets/{}", key.asset_id), "GET", None);
        request.ordinary_content_authorization =
            Some(crate::immich::OrdinaryContentAuthorization {
                source_keys: vec![key.clone()],
                expected_revision: self.ordinary_revision.clone(),
                purpose: crate::immich::OrdinaryContentPurpose::SelectedPresentationMetadata,
            });
        let response: crate::immich::HttpResponse =
            io(self.ctx, ShellOperation::Http(request)).await?;
        self.check_content_generation(std::slice::from_ref(key))?;
        crate::immich::check_status(response.status)?;
        Ok(response.body)
    }
    async fn visibility_reconciliation(
        &self,
        session: &Session,
        key: &AssetKey,
    ) -> Result<Value, String> {
        self.check_content_generation(std::slice::from_ref(key))?;
        crate::immich::valid_id(&key.asset_id)?;
        if key.scope != session.scope
            || key.provider != Provider::Immich
            || !self.state.immich_visibility_operations.iter().any(|o| {
                o.key == *key
                    && matches!(
                        o.observation,
                        Some(
                            crate::immich_visibility::ImmichVisibility::Timeline
                                | crate::immich_visibility::ImmichVisibility::Archive
                        )
                    )
            })
        {
            return Err("現在の状態を確認できません。".into());
        }
        let mut request = session.request(&format!("assets/{}", key.asset_id), "GET", None);
        let context = session
            .ordinary_content_context
            .as_ref()
            .ok_or("読み出しの許可を確認できません。")?;
        request.ordinary_content_authorization =
            Some(crate::immich::OrdinaryContentAuthorization {
                source_keys: vec![key.clone()],
                expected_revision: context.expected_revision.clone(),
                purpose: crate::immich::OrdinaryContentPurpose::VisibilityReconciliation,
            });
        let response: crate::immich::HttpResponse =
            io(self.ctx, ShellOperation::Http(request)).await?;
        self.check_content_generation(std::slice::from_ref(key))?;
        crate::immich::check_status(response.status)?;
        Ok(response.body)
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
    fn check_ordinary_generation(&self) -> Result<(), String> {
        self.read_io().check_ordinary()
    }
    fn check_content_generation(&self, keys: &[AssetKey]) -> Result<(), String> {
        self.read_io().check(keys)
    }
    /// Immich is the only provider whose session is established lazily.
    async fn ensure_connections(
        &mut self,
        providers: impl IntoIterator<Item = Provider>,
    ) -> Result<(), String> {
        if providers.into_iter().any(|p| p == Provider::Immich) {
            self.ensure_session().await
        } else {
            Ok(())
        }
    }
    fn check_content_keys(&self, keys: &[AssetKey]) -> Result<(), String> {
        self.check_ordinary_generation()?;
        if keys.iter().any(|key| self.denied_content.contains(key)) {
            return Err("保護する写真を通常の操作から利用できません。".into());
        }
        let access = crate::privacy::ContentAccess::new(&self.state);
        if keys.iter().any(|k| !access.visible(k)) {
            return Err("Apple Photos の可視性を確認して一覧を更新してください。".into());
        }
        Ok(())
    }
    // Scope, exact set and pending-write fences also apply to newly created copies.
    fn check_identity_keys(&self, keys: &[AssetKey]) -> Result<Provider, String> {
        self.check_ordinary_generation()?;
        if keys.iter().any(|key| {
            self.denied_content.contains(key)
                || crate::immich_visibility::fences(&self.state, key)
                || self
                    .state
                    .protected_entries
                    .iter()
                    .any(|entry| entry.key == *key)
        }) {
            return Err("保護する写真を通常の操作から利用できません。".into());
        }
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
        self.check_visibility_keys(keys)?;
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
            Provider::Amazon => self
                .state
                .amazon_connection
                .as_ref()
                .ok_or("Amazon Photosに接続してください。")?
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
        let session = self.session.clone().ok_or("Immich に接続してください。")?;
        ImmichBackend::new(session)
            .record(&self.read_io(), asset)
            .await
    }
    async fn export(&self, keys: &[AssetKey], name: &str) -> Result<TransferBundle, String> {
        self.check_content_keys(keys)?;
        self.export_authorized(keys, name, crate::immich::OrdinaryContentPurpose::Read)
            .await
    }
    /// Only fresh keys returned by this operation's import may bypass catalog membership.
    /// (Amazon upload-journal reconciliation separately binds one exact journaled
    /// destination ID with the same purpose; it is not general unpublished access.)
    async fn export_readback(
        &self,
        keys: &[AssetKey],
        name: &str,
    ) -> Result<TransferBundle, String> {
        self.export_authorized(
            keys,
            name,
            crate::immich::OrdinaryContentPurpose::DestinationReadback,
        )
        .await
    }
    async fn export_authorized(
        &self,
        keys: &[AssetKey],
        name: &str,
        purpose: crate::immich::OrdinaryContentPurpose,
    ) -> Result<TransferBundle, String> {
        let provider = self.check_identity_keys(keys)?;
        let directory = self.directory(name)?;
        let registry = self.registry();
        let exporter = registry
            .export(provider)
            .ok_or_else(|| registry.missing(provider, Ability::OriginalExport))?;
        let bundle = exporter
            .export(
                self.read_io(),
                ExportRequest {
                    keys,
                    directory: &directory,
                    purpose,
                },
            )
            .await?;
        // Completeness and identity of originals are checked here, in common
        // code, whichever service produced them.
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
        self.check_content_generation(keys)?;
        Ok(bundle)
    }
    /// Lend the journal to one destination import, after the source fences.
    async fn import(
        &mut self,
        importer: &dyn OriginalImport,
        request: ImportRequest<'_>,
    ) -> Result<CreatedCopies, String> {
        let keys: Vec<_> = request
            .bundle
            .assets
            .iter()
            .map(|a| a.key.clone())
            .collect();
        self.check_content_generation(&keys)?;
        self.check_transfer_trash(&request.bundle.assets)?;
        let io = self.read_io();
        importer.import(io, self, request).await
    }
    /// Verified copies are published as a Limited view: their own originals
    /// were read back, but concurrent catalog membership was not.
    fn publish_copies(
        &mut self,
        provider: Provider,
        scope: &str,
        assets: &[StoredAsset],
        now: f64,
    ) {
        if let Some(snapshot) = self
            .state
            .snapshots
            .iter_mut()
            .find(|s| s.provider == provider && s.scope == scope)
        {
            for asset in assets {
                snapshot.assets.retain(|a| a.key != asset.key);
                snapshot.assets.push(asset.clone());
            }
            snapshot.access = ScanAccess::Limited;
        } else {
            self.state.snapshots.push(LibrarySnapshot {
                provider,
                scope: scope.into(),
                assets: assets.to_vec(),
                access: ScanAccess::Limited,
                scanned_at: Some(now),
            });
        }
    }
    async fn copy(
        &mut self,
        keys: &[AssetKey],
        intent: TransferIntent,
        id: &str,
        now: f64,
    ) -> Result<(), String> {
        let provider = keys.first().ok_or("写真を選択してください。")?.provider;
        self.copy_to(keys, provider.other(), intent, id, now).await
    }

    async fn copy_to(
        &mut self,
        keys: &[AssetKey],
        destination: Provider,
        intent: TransferIntent,
        id: &str,
        now: f64,
    ) -> Result<(), String> {
        self.ensure_connections(keys.iter().map(|k| k.provider).chain([destination]))
            .await?;
        let provider = self.check_keys(keys)?;
        if provider == destination {
            return Err("転送元と別の保存先を選択してください。".into());
        }
        let registry = self.registry();
        let importer = registry
            .import(destination)
            .ok_or_else(|| registry.missing(destination, Ability::OriginalImport))?;
        if intent == TransferIntent::Move
            && let Some(blocker) = registry.move_blocker(provider, destination)
        {
            return Err(blocker);
        }
        importer.admit(&*self, keys)?;
        // A saved receipt is never overwritten: its deletion safety is per ID.
        if self.state.receipts.iter().any(|r| r.id == id) {
            return Err(
                "同じ転送IDの記録が既にあります。新しい操作として開始してください。".into(),
            );
        }
        // A Move would later delete a source another receipt may have deleted.
        if intent == TransferIntent::Move {
            trash_fence::uncertain_source_fence(&self.state.receipts, keys)?;
        }
        self.workspace(id).await?;
        let mut bundle = self.export(keys, "source").await?;
        self.check_transfer_trash(&bundle.assets)?;
        bundle.block_duplicates();
        // The reducer admits the receipt; its save must complete before import.
        let step = crate::transfer_lifecycle::start(TransferReceipt {
            id: id.into(),
            created_at: now,
            phase: TransferPhase::Copying,
            intent,
            source: bundle.assets.clone(),
            destination: Vec::new(),
            destination_provider: destination,
            destination_scope: importer.scope().into(),
            signatures: bundle.signatures(),
        })?;
        let stage = self
            .persist_stage(JournalChange::Receipt(step.receipt.clone()))
            .await?;
        let created = self
            .import(
                importer,
                ImportRequest {
                    receipt: &step.receipt,
                    stage,
                    bundle: &bundle,
                    now,
                },
            )
            .await?;
        let verification = self.export_readback(&created.0, "verify").await?;
        let verified =
            crate::transfer_lifecycle::verify_copy(&step.receipt, &created.0, &verification)?;
        let step = crate::transfer_lifecycle::reduce(
            &step.receipt,
            LifecycleEvent::CopyVerified(verified),
        )?;
        self.replace_records(bundle.assets);
        if importer.publishes_copies() {
            self.publish_copies(destination, importer.scope(), &verification.assets, now);
        }
        self.persist_stage(JournalChange::Receipt(step.receipt))
            .await
            .map(|_| ())
    }
    async fn complete_move(&mut self, id: &str, workspace: &str) -> Result<(), String> {
        let receipt = self
            .state
            .receipts
            .iter()
            .find(|r| r.id == id)
            .cloned()
            .ok_or("移動記録がありません。")?;
        // No live attempt can exist at the start of an operation: a saved
        // DeletingSource may already have deleted and is never issued again.
        if let Some(step) = crate::transfer_lifecycle::recover(&receipt) {
            self.persist_stage(JournalChange::Receipt(step.receipt))
                .await?;
            return Err(
                "前回の削除結果を確認できません。自動再試行はしません。転送元を確認してください。"
                    .into(),
            );
        }
        // Copy, legacy, partial and already finished receipts stop here.
        if !receipt.move_blockers().is_empty() {
            return Err(receipt.move_blockers().join(" / "));
        }
        // Another receipt's possibly issued deletion of the same source is
        // never retried through this one. This receipt is Copied here.
        let source_keys: Vec<_> = receipt.source.iter().map(|a| a.key.clone()).collect();
        trash_fence::uncertain_source_fence(&self.state.receipts, &source_keys)?;
        self.ensure_connections(
            receipt
                .source
                .iter()
                .map(|a| a.key.provider)
                .chain([receipt.destination_provider]),
        )
        .await?;
        self.check_transfer_trash(&receipt.source)?;
        self.check_transfer_trash(&receipt.destination)?;
        let destination_keys: Vec<_> = receipt.destination.iter().map(|a| a.key.clone()).collect();
        let provider = self.check_keys(&source_keys)?;
        self.check_keys(&destination_keys)?;
        let registry = self.registry();
        let deleter = registry
            .deletion(provider)
            .ok_or_else(|| registry.missing(provider, Ability::SourceDeletion))?;
        self.workspace(workspace).await?;
        let mut source = self.export(&source_keys, "source").await?;
        let source = crate::transfer_lifecycle::verify_source_evidence(&receipt, &mut source)?;
        let destination = self.export(&destination_keys, "target").await?;
        let destination =
            crate::transfer_lifecycle::verify_destination_evidence(&receipt, &destination)?;
        let authority = DeletionAuthority::new(&receipt, source, destination)?;
        let step = crate::transfer_lifecycle::reduce(
            &receipt,
            LifecycleEvent::AuthorizeDeletion(authority),
        )?;
        let LifecycleEffect::PersistThenDelete(attempt) = step.effect else {
            return Err("移動の削除段階を確認できません。元データは残します。".into());
        };
        // Persist first: a failed save must never be followed by deletion.
        // An unacknowledged save stops here; the attempt is dropped unsent.
        let stage = self
            .persist_stage(JournalChange::Receipt(step.receipt.clone()))
            .await?;
        let (event, error) = deletion_event(deleter.delete(self.read_io(), stage, attempt).await);
        let next = crate::transfer_lifecycle::reduce(&step.receipt, event)?;
        // A failed save keeps the durable DeletingSource, which is never retried.
        self.persist_stage(JournalChange::Receipt(next.receipt))
            .await?;
        if let Some(error) = error {
            return Err(error);
        }
        Ok(())
    }
}
/// The reducer event of one native deletion outcome, bound to its attempt.
fn deletion_event(outcome: DeletionOutcome) -> (LifecycleEvent, Option<String>) {
    match outcome {
        DeletionOutcome::NotSubmitted(attempt, error) => {
            (LifecycleEvent::DeletionNotSubmitted(attempt), Some(error))
        }
        DeletionOutcome::Submitted(submitted, Ok(())) => {
            (LifecycleEvent::DeletionSucceeded(submitted), None)
        }
        DeletionOutcome::Submitted(submitted, Err(error)) => (
            LifecycleEvent::DeletionUnknown(submitted),
            Some(format!(
                "削除結果を確認してください。自動再試行はしません。{error}"
            )),
        ),
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
    if !(1..=u64::from(crate::immich_live_writes::CURRENT_SCHEMA_VERSION)).contains(&version) {
        return Err("未対応のカタログ形式です。既存ファイルは変更しません。".into());
    }
    crate::metadata::migrate_journal(&mut raw, version)?;
    if version < 11 {
        if raw
            .get("externalImports")
            .is_some_and(|value| !value.is_null())
        {
            return Err(
                "旧形式に未対応の取り込み記録があります。既存ファイルは変更しません。".into(),
            );
        }
        raw["externalImports"] = serde_json::json!([]);
    } else if !raw.get("externalImports").is_some_and(Value::is_array) {
        return Err("取り込み記録の構成が不正です。既存ファイルは変更しません。".into());
    }
    let live_fields = [
        "immichLiveOperations",
        "immichLiveUnstartedClosures",
        "immichLiveLegacyReconciliations",
    ];
    let live_since = u64::from(crate::immich_live_writes::LIVE_JOURNAL_SCHEMA_VERSION);
    if version < live_since
        && live_fields
            .iter()
            .any(|field| raw.get(field).is_some_and(|v| !v.is_null()))
    {
        return Err(
            "旧形式に未対応の Live 変更記録があります。既存ファイルは変更しません。".into(),
        );
    }
    for field in live_fields {
        if version < live_since {
            raw[field] = serde_json::json!([]);
        } else if !raw.get(field).is_some_and(Value::is_array) {
            return Err("Live 変更記録の構成が不正です。既存ファイルは変更しません。".into());
        }
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
    if version < 7
        && raw["immichVisibilityOperations"]
            .as_array()
            .is_some_and(|ops| {
                ops.iter()
                    .any(|o| o.get("kind").is_some_and(|k| k != "lockedTransition"))
            })
    {
        return Err("旧形式に未対応の操作があります。既存ファイルは変更しません。".into());
    }
    if version < 8
        && raw["immichVisibilityOperations"]
            .as_array()
            .is_some_and(|ops| {
                ops.iter().any(|op| {
                    op.get("selectedObservation")
                        .is_some_and(|value| !value.is_null())
                })
            })
    {
        return Err("旧形式に未対応の観測があります。既存ファイルは変更しません。".into());
    }
    raw["schemaVersion"] = Value::from(crate::immich_live_writes::CURRENT_SCHEMA_VERSION);
    let state: SavedLibrary = serde_json::from_value(raw)
        .map_err(|e| format!("カタログを読み出せません。既存ファイルは変更しません。{e}"))?;
    let mut ids = BTreeSet::new();
    for op in &state.apple_visibility_operations {
        crate::apple_visibility::validate_operation(op, &state.apple_scope)?;
        if !ids.insert(&op.id) {
            return Err("非表示の操作 UUID が重複しています。".into());
        }
    }
    for operation in &state.immich_visibility_operations {
        crate::immich_visibility::validate_operation(operation)?;
        if !ids.insert(&operation.id) {
            return Err("非表示の操作 UUID が重複しています。".into());
        }
    }
    crate::protection::validate_membership(&state)?;
    crate::immich_live_writes::validate_library(&state)?;
    Ok(state)
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

fn bind_ordinary_context(
    session: &mut Session,
    generation: &std::sync::Arc<std::sync::atomic::AtomicU64>,
    expected: u64,
    revision: &str,
) {
    session.ordinary_content_guard = Some(crate::immich::OrdinarySessionGuard {
        generation: generation.clone(),
        expected,
    });
    session.ordinary_content_context = Some(crate::immich::OrdinaryContentAuthorization {
        source_keys: vec![],
        expected_revision: revision.into(),
        purpose: crate::immich::OrdinaryContentPurpose::Read,
    });
}

fn metadata_event(event: &Event) -> bool {
    matches!(
        event,
        Event::SetFavorite { .. }
            | Event::SetMetadata { .. }
            | Event::EditMetadata { .. }
            | Event::RestoreMetadata { .. }
            | Event::CreateAlbum { .. }
            | Event::EditAlbum { .. }
            | Event::EditImage { .. }
            | Event::RevertImage { .. }
            | Event::PastePhotoEdits { .. }
            | Event::PasteSelectedPhotoEdits { .. }
            | Event::ResolveEditPaste { .. }
    )
}

fn editing_event(event: &Event) -> bool {
    matches!(
        event,
        Event::EditImage { .. }
            | Event::RevertImage { .. }
            | Event::CopyPhotoEdits { .. }
            | Event::PastePhotoEdits { .. }
            | Event::PasteSelectedPhotoEdits { .. }
            | Event::ResolveEditPaste { .. }
    )
}
