//! Apple Photos through the native `PhotoKit` adapter.
use futures::future::BoxFuture;
use serde_json::Value;

use super::{
    AlbumCreator, AlbumEditor, AlbumReader, CatalogListing, CreatedCopies, DeletionOutcome,
    ExportRequest, FavoriteWrite, ImportRequest, ImportWindow, Io, ListRequest, Listing,
    ListingRange, MetadataWrite, OriginalExport, OriginalImport, ReadIo, SourceDeletion,
    authorize_deletion, authorize_import, submit_deletion,
};
use crate::{
    albums::{AlbumEdit, AlbumKey, AlbumSnapshot, StoredAlbum},
    app::{ShellOperation, io as shell},
    domain::{
        AssetKey, LibrarySnapshot, ScanAccess, StoredAsset, TransferBundle, apple_import_plan,
    },
    metadata::MetadataChange,
    transfer_lifecycle::DeletionAttempt,
    workflow::journal::DurableStage,
};

pub(crate) struct AppleBackend {
    scope: String,
}

impl AppleBackend {
    pub(crate) fn new(scope: String) -> Self {
        Self { scope }
    }
}

impl CatalogListing for AppleBackend {
    fn list<'a>(&'a self, io: ReadIo<'a>, request: ListRequest) -> Io<'a, Listing> {
        Box::pin(async move {
            let snapshot: LibrarySnapshot = shell(
                io.ctx(),
                ShellOperation::AppleScan {
                    scope: self.scope.clone(),
                    permission: request.permission,
                },
            )
            .await?;
            let range = if snapshot.access == ScanAccess::Full {
                ListingRange::WholeLibrary
            } else {
                ListingRange::Selection
            };
            Ok::<_, String>(Listing {
                snapshot,
                range,
                warning: None,
            })
        })
    }
}

impl OriginalExport for AppleBackend {
    fn export<'a>(&'a self, io: ReadIo<'a>, request: ExportRequest<'a>) -> Io<'a, TransferBundle> {
        Box::pin(async move {
            shell::<TransferBundle>(
                io.ctx(),
                ShellOperation::AppleExport {
                    keys: request.keys.to_vec(),
                    directory: request.directory.into(),
                },
            )
            .await
        })
    }
}

impl OriginalImport for AppleBackend {
    fn scope(&self) -> &str {
        &self.scope
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
        _window: &'a mut dyn ImportWindow,
        request: ImportRequest<'a>,
    ) -> Io<'a, CreatedCopies> {
        Box::pin(async move {
            let ImportRequest {
                receipt,
                stage,
                bundle,
                now: _,
            } = request;
            let plan = apple_import_plan(bundle)?;
            authorize_import(stage, receipt, bundle)?;
            let sources: Vec<_> = receipt.source.iter().map(|a| a.key.clone()).collect();
            io.check(&sources)?;
            let keys: Vec<AssetKey> = shell(io.ctx(), ShellOperation::AppleImport(plan)).await?;
            Ok::<_, String>(CreatedCopies(keys))
        })
    }
}

impl SourceDeletion for AppleBackend {
    fn delete<'a>(
        &'a self,
        io: ReadIo<'a>,
        stage: DurableStage,
        attempt: DeletionAttempt,
    ) -> BoxFuture<'a, DeletionOutcome> {
        Box::pin(async move {
            if let Err(error) = authorize_deletion(stage, &attempt) {
                return DeletionOutcome::NotSubmitted(attempt, error);
            }
            let assets = attempt.sources().to_vec();
            let submitted = match submit_deletion(&io, attempt) {
                Ok(submitted) => submitted,
                Err((attempt, error)) => return DeletionOutcome::NotSubmitted(attempt, error),
            };
            // Issued once, with no await since the epoch check. Any failure
            // after this point may follow a deletion.
            let result = shell::<Value>(io.ctx(), ShellOperation::AppleTrash { assets })
                .await
                .map(|_| ());
            DeletionOutcome::Submitted(submitted, result)
        })
    }
}

impl FavoriteWrite for AppleBackend {
    fn batch_size(&self) -> usize {
        usize::MAX
    }

    fn saved_status(&self) -> &'static str {
        "Apple Photos のお気に入りを保存しました。"
    }

    fn set_favorite<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        value: bool,
    ) -> Io<'a, Vec<StoredAsset>> {
        Box::pin(async move {
            shell::<Vec<StoredAsset>>(
                io.ctx(),
                ShellOperation::AppleFavorite {
                    keys: keys.to_vec(),
                    value,
                },
            )
            .await
        })
    }
}

impl MetadataWrite for AppleBackend {
    fn change_metadata<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        change: &'a MetadataChange,
    ) -> Io<'a, Vec<StoredAsset>> {
        Box::pin(async move {
            shell::<Vec<StoredAsset>>(
                io.ctx(),
                ShellOperation::AppleMetadata {
                    keys: keys.to_vec(),
                    change: change.clone(),
                },
            )
            .await
        })
    }
}

impl AlbumReader for AppleBackend {
    fn album_scope(&self) -> &str {
        &self.scope
    }

    fn read_albums<'a>(&'a self, io: ReadIo<'a>) -> Io<'a, AlbumSnapshot> {
        Box::pin(async move {
            shell::<AlbumSnapshot>(
                io.ctx(),
                ShellOperation::AppleAlbums {
                    scope: self.scope.clone(),
                },
            )
            .await
        })
    }
}

impl AlbumCreator for AppleBackend {
    fn create_album<'a>(&'a self, io: ReadIo<'a>, title: &'a str) -> Io<'a, StoredAlbum> {
        Box::pin(async move {
            shell::<StoredAlbum>(
                io.ctx(),
                ShellOperation::AppleAlbumCreate {
                    scope: self.scope.clone(),
                    title: title.into(),
                },
            )
            .await
        })
    }
}

impl AlbumEditor for AppleBackend {
    fn edit_collection<'a>(
        &'a self,
        io: ReadIo<'a>,
        edit: &'a crate::albums::CollectionEdit,
        expected: &'a AlbumSnapshot,
    ) -> Io<'a, ()> {
        Box::pin(async move {
            shell::<()>(
                io.ctx(),
                ShellOperation::AppleCollectionEdit {
                    scope: self.scope.clone(),
                    edit: edit.clone(),
                    expected: expected.clone(),
                },
            )
            .await
        })
    }
    fn edit_album<'a>(
        &'a self,
        io: ReadIo<'a>,
        key: &'a AlbumKey,
        edit: &'a AlbumEdit,
    ) -> Io<'a, ()> {
        Box::pin(async move {
            shell::<Value>(
                io.ctx(),
                ShellOperation::AppleAlbumEdit {
                    key: key.clone(),
                    edit: edit.clone(),
                },
            )
            .await
            .map(|_| ())
        })
    }
}
