//! Immich through its REST API. Originals are hashed after download and the
//! asset revision is re-read, so a concurrent change never becomes evidence.
use futures::future::BoxFuture;

use std::collections::BTreeMap;

use super::{
    AlbumCreator, AlbumEditor, AlbumReader, CatalogListing, CreatedCopies, DeletionOutcome,
    ExportRequest, FavoriteWrite, ImportRequest, ImportWindow, Io, ListRequest, Listing,
    ListingRange, MetadataWrite, OriginalExport, OriginalImport, ReadIo, SourceDeletion,
    authorize_deletion, submit_deletion,
};
use crate::{
    albums::{AlbumAction, AlbumEdit, AlbumKey, AlbumPermissions, AlbumSnapshot, StoredAlbum},
    app::{ShellOperation, io as shell},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferBundle, TransferFile,
        allow_deletion,
    },
    immich::{Asset, Session},
    metadata::MetadataChange,
    transfer_lifecycle::DeletionAttempt,
    transport::OrdinaryContentPurpose,
    workflow::{HashResult, journal::DurableStage},
};

/// Hydrate one freshly enumerated owned asset: its sidecar inventory and
/// stack membership, bound to the operation's access epoch. Shared by the
/// listing ability and the app refresh's reconciling enumeration.
pub(crate) async fn hydrate(
    session: &Session,
    io: &ReadIo<'_>,
    asset: &Asset,
    companion: Option<&Asset>,
) -> Result<StoredAsset, String> {
    let files = if session.version.uses_cursor() {
        session.files(io.ctx(), &asset.id).await.ok()
    } else {
        None
    };
    io.check(&[])?;
    let mut hydrated = asset.clone();
    session.hydrate_stack(io.ctx(), &mut hydrated).await;
    io.check(&[])?;
    Ok(hydrated.record(&session.scope, companion, files.as_deref()))
}

pub(crate) struct ImmichBackend {
    pub(super) session: Session,
}

impl ImmichBackend {
    /// The session already carries this operation's ordinary-access context.
    pub(crate) fn new(session: Session) -> Self {
        Self { session }
    }

    fn key(&self, id: &str) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: self.session.scope.clone(),
            asset_id: id.into(),
        }
    }

    fn session_for(&self, keys: &[AssetKey], purpose: OrdinaryContentPurpose) -> Session {
        let mut session = self.session.clone();
        if let Some(context) = &mut session.ordinary_content_context {
            context.source_keys = keys.to_vec();
            context.purpose = purpose;
        }
        session
    }

    /// One owned asset with its Live companion and sidecar inventory.
    pub(crate) async fn record(
        &self,
        io: &ReadIo<'_>,
        asset: &Asset,
    ) -> Result<StoredAsset, String> {
        let mut session = self.session.clone();
        if let Some(context) = &mut session.ordinary_content_context {
            context.source_keys = vec![self.key(&asset.id)];
        }
        let companion = match &asset.live_photo_video_id {
            Some(id) => Some(session.asset(io.ctx(), id).await?),
            None => None,
        };
        let files = if session.version.uses_cursor() {
            session.files(io.ctx(), &asset.id).await.ok()
        } else {
            None
        };
        Ok(asset.record(&session.scope, companion.as_ref(), files.as_deref()))
    }

    async fn export_originals(
        &self,
        io: &ReadIo<'_>,
        request: ExportRequest<'_>,
    ) -> Result<TransferBundle, String> {
        let session = self.session_for(request.keys, request.purpose);
        let mut assets = Vec::new();
        let mut files = Vec::new();
        for (n, key) in request.keys.iter().enumerate() {
            let native = session.asset(io.ctx(), &key.asset_id).await?;
            let mut record = self.record(io, &native).await?;
            for (i, resource) in record
                .resources
                .iter_mut()
                .enumerate()
                .filter(|(_, r)| r.role.is_original())
            {
                let path = format!("{}/{n}-{i}", request.directory);
                session.download(io.ctx(), &resource.id, &path).await?;
                let hash: HashResult =
                    shell(io.ctx(), ShellOperation::HashFile { path: path.clone() }).await?;
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
            let after = session.asset(io.ctx(), &key.asset_id).await?;
            if native.updated_at != after.updated_at || native.checksum != after.checksum {
                return Err("読み出し中に写真が変更されました。".into());
            }
            assets.push(record);
        }
        Ok(TransferBundle { assets, files })
    }

    /// Re-read every source right before deletion; drift stops before DELETE.
    async fn recheck_sources(
        &self,
        io: &ReadIo<'_>,
        sources: &[StoredAsset],
    ) -> Result<(), String> {
        for saved in sources {
            let native = self.session.asset(io.ctx(), &saved.key.asset_id).await?;
            let current = self.record(io, &native).await?;
            allow_deletion(std::slice::from_ref(&current))?;
            if current.revision != saved.revision {
                return Err("削除直前に写真の状態が変わりました。".into());
            }
        }
        Ok(())
    }

    async fn delete_sources(
        &self,
        io: &ReadIo<'_>,
        stage: DurableStage,
        attempt: DeletionAttempt,
    ) -> DeletionOutcome {
        if let Err(error) = authorize_deletion(stage, &attempt) {
            return DeletionOutcome::NotSubmitted(attempt, error);
        }
        if let Err(error) = self.recheck_sources(io, attempt.sources()).await {
            return DeletionOutcome::NotSubmitted(attempt, error);
        }
        let ids: Vec<_> = attempt
            .sources()
            .iter()
            .map(|a| a.key.asset_id.clone())
            .collect();
        // Every source and destination epoch, including an Apple destination
        // that changed while the re-reads above were awaiting.
        let submitted = match submit_deletion(io, attempt) {
            Ok(submitted) => submitted,
            Err((attempt, error)) => return DeletionOutcome::NotSubmitted(attempt, error),
        };
        // No await between the epoch check and the DELETE request.
        let result = self.session.trash_move(io.ctx(), &ids).await;
        DeletionOutcome::Submitted(submitted, result)
    }

    async fn read_owned_albums(&self, io: &ReadIo<'_>) -> Result<AlbumSnapshot, String> {
        let session = &self.session;
        let mut albums = Vec::new();
        for album in session
            .albums(io.ctx())
            .await?
            .into_iter()
            .filter(|a| a.owned_by(&session.user_id))
        {
            let members = session
                .album_members(io.ctx(), &album.id)
                .await?
                .into_iter()
                .map(|a| self.key(&a.id))
                .collect();
            albums.push(StoredAlbum {
                key: AlbumKey {
                    provider: Provider::Immich,
                    scope: session.scope.clone(),
                    album_id: album.id,
                },
                title: album.album_name,
                members,
                permissions: AlbumPermissions {
                    add: true,
                    remove: true,
                    rename: true,
                    delete: true,
                },
            });
        }
        Ok(AlbumSnapshot {
            provider: Provider::Immich,
            scope: session.scope.clone(),
            albums,
            access: ScanAccess::Full,
        })
    }
}

impl OriginalExport for ImmichBackend {
    fn export<'a>(&'a self, io: ReadIo<'a>, request: ExportRequest<'a>) -> Io<'a, TransferBundle> {
        Box::pin(async move { self.export_originals(&io, request).await })
    }
}

impl OriginalImport for ImmichBackend {
    fn scope(&self) -> &str {
        &self.session.scope
    }

    fn supports_move(&self) -> bool {
        true
    }

    fn publishes_copies(&self) -> bool {
        false
    }

    fn admit(&self, _window: &dyn ImportWindow, _keys: &[AssetKey]) -> Result<(), String> {
        Ok(())
    }

    fn import<'a>(
        &'a self,
        io: ReadIo<'a>,
        window: &'a mut dyn ImportWindow,
        request: ImportRequest<'a>,
    ) -> Io<'a, CreatedCopies> {
        Box::pin(async move { self.import_bundle(&io, window, request).await })
    }
}

impl SourceDeletion for ImmichBackend {
    fn delete<'a>(
        &'a self,
        io: ReadIo<'a>,
        stage: DurableStage,
        attempt: DeletionAttempt,
    ) -> BoxFuture<'a, DeletionOutcome> {
        Box::pin(async move { self.delete_sources(&io, stage, attempt).await })
    }
}

/// Enumeration with plain hydration. The app refresh additionally replaces
/// assets tracked by a saved visibility operation with a fresh read.
impl CatalogListing for ImmichBackend {
    fn list<'a>(&'a self, io: ReadIo<'a>, request: ListRequest) -> Io<'a, Listing> {
        Box::pin(async move {
            let session = &self.session;
            let assets = session.list(io.ctx(), request.now).await?;
            let by_id: BTreeMap<_, _> = assets.iter().map(|a| (&a.id, a)).collect();
            let mut records = Vec::new();
            for asset in &assets {
                let companion = asset
                    .live_photo_video_id
                    .as_ref()
                    .and_then(|id| by_id.get(id).copied());
                records.push(hydrate(session, &io, asset, companion).await?);
            }
            Ok::<_, String>(Listing {
                snapshot: LibrarySnapshot {
                    provider: Provider::Immich,
                    scope: session.scope.clone(),
                    assets: records,
                    access: ScanAccess::Full,
                    scanned_at: Some(request.now),
                },
                range: ListingRange::WholeLibrary,
                warning: None,
            })
        })
    }
}

impl FavoriteWrite for ImmichBackend {
    fn batch_size(&self) -> usize {
        1
    }

    fn saved_status(&self) -> &'static str {
        "Immich のお気に入りを保存しました。"
    }

    fn set_favorite<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        value: bool,
    ) -> Io<'a, Vec<StoredAsset>> {
        Box::pin(async move {
            let mut records = Vec::new();
            for key in keys {
                let asset = self
                    .session
                    .favorite(io.ctx(), &key.asset_id, value)
                    .await?;
                records.push(self.record(&io, &asset).await?);
            }
            Ok::<_, String>(records)
        })
    }
}

impl MetadataWrite for ImmichBackend {
    fn change_metadata<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        change: &'a MetadataChange,
    ) -> Io<'a, Vec<StoredAsset>> {
        Box::pin(async move {
            let ids: Vec<_> = keys.iter().map(|k| k.asset_id.clone()).collect();
            let assets = self.session.metadata(io.ctx(), &ids, change).await?;
            let mut records = Vec::new();
            for asset in assets {
                records.push(self.record(&io, &asset).await?);
            }
            Ok::<_, String>(records)
        })
    }
}

impl AlbumReader for ImmichBackend {
    fn album_scope(&self) -> &str {
        &self.session.scope
    }

    fn read_albums<'a>(&'a self, io: ReadIo<'a>) -> Io<'a, AlbumSnapshot> {
        Box::pin(async move { self.read_owned_albums(&io).await })
    }
}

impl AlbumCreator for ImmichBackend {
    fn create_album<'a>(&'a self, io: ReadIo<'a>, title: &'a str) -> Io<'a, StoredAlbum> {
        Box::pin(async move {
            let album = self.session.create_album(io.ctx(), title).await?;
            Ok::<_, String>(StoredAlbum {
                key: AlbumKey {
                    provider: Provider::Immich,
                    scope: self.session.scope.clone(),
                    album_id: album.id,
                },
                title: album.album_name,
                members: Vec::new(),
                permissions: AlbumPermissions::default(),
            })
        })
    }
}

impl AlbumEditor for ImmichBackend {
    fn edit_album<'a>(
        &'a self,
        io: ReadIo<'a>,
        key: &'a AlbumKey,
        edit: &'a AlbumEdit,
    ) -> Io<'a, ()> {
        Box::pin(async move {
            let ctx = io.ctx();
            match edit.action {
                AlbumAction::Rename => {
                    self.session
                        .rename_album(
                            ctx,
                            &key.album_id,
                            edit.title.as_deref().ok_or("名前がありません。")?,
                        )
                        .await
                }
                AlbumAction::Delete => self.session.delete_album(ctx, &key.album_id).await,
                AlbumAction::Add | AlbumAction::Remove => {
                    let ids = edit
                        .keys
                        .iter()
                        .map(|k| k.asset_id.clone())
                        .collect::<Vec<_>>();
                    self.session
                        .change_album_members(
                            ctx,
                            &key.album_id,
                            &ids,
                            matches!(edit.action, AlbumAction::Add),
                        )
                        .await
                }
            }
        })
    }
}
