//! Provider abilities. Each backend implements only what its service supports,
//! and workflows ask the [`Registry`] for one ability at a time instead of
//! branching on source × destination pairs. A registry is a table of
//! abilities, so a test can install a fake that implements only some of them.
//! A backend holds immutable connection scope only. Saved journals stay owned
//! by the workflow, which lends a narrow [`ImportWindow`]; authorization and
//! access epochs travel in the per-operation [`ReadIo`].
//!
//! Scope: these abilities cover catalog listing, original export/import,
//! source deletion, favorites, metadata and albums. Previews and other
//! renditions stay on their existing, independent rendition paths
//! (`media`, `ordinary_selected`, protected/private media); they are not
//! dispatched through this registry.
use std::sync::{Arc, atomic::AtomicU64};

use futures::future::BoxFuture;

use crate::{
    albums::{AlbumEdit, AlbumKey, AlbumSnapshot, StoredAlbum},
    amazon::UploadRecord,
    app::Context,
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferBundle,
        TransferReceipt, allow_deletion,
    },
    immich::{PendingUpload, UploadIntent},
    metadata::MetadataChange,
    transfer_lifecycle::{DeletionAttempt, SubmittedDeletion},
    transport::OrdinaryContentPurpose,
    workflow::journal::{DurableStage, JournalChange, StageBinding},
};

mod amazon;
mod apple;
mod immich;
mod immich_upload;

pub(crate) use amazon::AmazonBackend;
pub(crate) use apple::AppleBackend;
pub(crate) use immich::{ImmichBackend, hydrate as hydrate_immich};

pub(crate) type Io<'a, T> = BoxFuture<'a, Result<T, String>>;

/// Every provider, in the order multi-provider operations visit them.
pub(crate) const PROVIDERS: [Provider; 3] = [Provider::Apple, Provider::Immich, Provider::Amazon];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Ability {
    Listing,
    OriginalExport,
    OriginalImport,
    SourceDeletion,
    Favorite,
    Metadata,
    AlbumRead,
    AlbumCreate,
    AlbumEdit,
}

/// The static ability profile of each real service, independent of whether
/// it is currently connected. Service registries expose exactly this profile.
#[must_use]
pub(crate) fn offers(provider: Provider, ability: Ability) -> bool {
    match provider {
        Provider::Apple | Provider::Immich => true,
        Provider::Amazon => matches!(
            ability,
            Ability::Listing
                | Ability::OriginalExport
                | Ability::OriginalImport
                | Ability::Favorite
        ),
    }
}

#[must_use]
pub(crate) fn unsupported(provider: Provider, ability: Ability) -> String {
    let message = match (provider, ability) {
        (Provider::Amazon, Ability::Metadata) => {
            "Amazon Photosの日時・位置情報の変更には対応していません。別の保存先を選択してください。"
        }
        (Provider::Amazon, Ability::AlbumRead) => {
            "Amazon Photosのアルバム操作には対応していません。"
        }
        (Provider::Amazon, Ability::AlbumCreate) => {
            "Amazon Photosのアルバム作成には対応していません。"
        }
        (Provider::Amazon, Ability::AlbumEdit) => {
            "Amazon Photosのアルバム変更には対応していません。"
        }
        (Provider::Amazon, Ability::SourceDeletion) => {
            "Amazon Photosとの移動は原本保持の検証が未対応です。コピーを選択してください。"
        }
        _ => "この保存先はこの操作に対応していません。",
    };
    message.into()
}

/// Read authority for one operation: the effect context plus the access
/// generations captured when the operation started.
#[derive(Clone)]
pub(crate) struct ReadIo<'a> {
    ctx: &'a Context,
    ordinary: Arc<AtomicU64>,
    ordinary_expected: u64,
    apple: Arc<AtomicU64>,
    apple_expected: u64,
}

impl<'a> ReadIo<'a> {
    pub(crate) fn new(
        ctx: &'a Context,
        ordinary: (Arc<AtomicU64>, u64),
        apple: (Arc<AtomicU64>, u64),
    ) -> Self {
        Self {
            ctx,
            ordinary: ordinary.0,
            ordinary_expected: ordinary.1,
            apple: apple.0,
            apple_expected: apple.1,
        }
    }

    fn ctx(&self) -> &'a Context {
        self.ctx
    }

    pub(crate) fn check_ordinary(&self) -> Result<(), String> {
        if self.ordinary_expected != self.ordinary.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("写真へのアクセスが変わりました。処理を中止しました。".into());
        }
        Ok(())
    }

    /// The access epochs of these keys are still the ones this operation
    /// started with. Callers pass every key a decision depends on, not only
    /// the keys the next request touches.
    pub(crate) fn check(&self, keys: &[AssetKey]) -> Result<(), String> {
        self.check_ordinary()?;
        // A generation comparison is a cancellation fence, not cross-thread
        // data synchronization.
        if keys.iter().any(|k| k.provider == Provider::Apple)
            && self.apple_expected != self.apple.load(std::sync::atomic::Ordering::Relaxed)
        {
            return Err(
                "読み出し中に Apple Photos のアクセスが変わりました。処理を中止しました。".into(),
            );
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ListingRange {
    /// The whole account. Only a complete one can establish absence.
    WholeLibrary,
    /// A user-granted subset, such as limited Photos access.
    Selection,
}

#[derive(Debug)]
pub(crate) struct Listing {
    pub snapshot: LibrarySnapshot,
    pub range: ListingRange,
    /// A partial result that is still worth publishing.
    pub warning: Option<String>,
}

impl Listing {
    /// A subset never becomes a full inventory.
    pub(crate) fn into_snapshot(self) -> (LibrarySnapshot, Option<String>) {
        let mut snapshot = self.snapshot;
        if self.range != ListingRange::WholeLibrary && snapshot.access == ScanAccess::Full {
            snapshot.access = ScanAccess::Limited;
        }
        (snapshot, self.warning)
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ListRequest {
    /// The native adapter may ask the user for access.
    pub permission: bool,
    pub now: f64,
}

/// Enumerate the service's catalog. A listing never consults workflow
/// journals. The app refresh of Immich uses this enumeration's hydration
/// ([`hydrate_immich`]) but replaces it, per asset, with a fresh read when a
/// saved visibility operation tracks that asset; see `refresh_immich`.
pub(crate) trait CatalogListing: Send + Sync {
    fn list<'a>(&'a self, io: ReadIo<'a>, request: ListRequest) -> Io<'a, Listing>;
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct ExportRequest<'a> {
    pub keys: &'a [AssetKey],
    pub directory: &'a str,
    pub purpose: OrdinaryContentPurpose,
}

/// Original bytes only. Renditions such as previews are never originals.
pub(crate) trait OriginalExport: Send + Sync {
    fn export<'a>(&'a self, io: ReadIo<'a>, request: ExportRequest<'a>) -> Io<'a, TransferBundle>;
}

/// The workflow's journal, lent to one import. Records are returned as copies;
/// every change goes through [`ImportWindow::stage`], which saves it durably
/// before acknowledging it and restores memory if the save fails.
pub(crate) trait ImportWindow: Send {
    fn upload_intents(&self) -> Vec<UploadIntent>;
    fn pending_uploads(&self) -> Vec<PendingUpload>;
    fn amazon_uploads(&self) -> Vec<UploadRecord>;
    fn cataloged(&self, key: &AssetKey) -> Option<StoredAsset>;
    fn work_directory(&self, name: &str) -> Result<String, String>;
    /// Current owner, scope, protection and pending-write fences.
    fn check_destination(&self, keys: &[AssetKey]) -> Result<(), String>;
    /// Access epoch and same-original trash fences of one source.
    fn check_source(&self, source: &StoredAsset) -> Result<(), String>;
    fn stage(&mut self, change: JournalChange) -> Io<'_, DurableStage>;
}

#[derive(Debug)]
pub(crate) struct ImportRequest<'a> {
    /// The complete receipt whose `Copying` stage was saved; never inferred.
    pub receipt: &'a TransferReceipt,
    pub stage: DurableStage,
    pub bundle: &'a TransferBundle,
    pub now: f64,
}

/// Destination keys an import created. Creation is not verification: only
/// the shared lifecycle verification turns a fresh readback into evidence.
#[derive(Debug)]
pub(crate) struct CreatedCopies(pub Vec<AssetKey>);

pub(crate) trait OriginalImport: Send + Sync {
    fn scope(&self) -> &str;
    /// Whether verified copies here may complete an explicit Move.
    fn supports_move(&self) -> bool;
    /// Verified copies are published as a Limited view until the next refresh.
    fn publishes_copies(&self) -> bool;
    /// Admission before any export, journal or write.
    fn admit(&self, window: &dyn ImportWindow, keys: &[AssetKey]) -> Result<(), String>;
    fn import<'a>(
        &'a self,
        io: ReadIo<'a>,
        window: &'a mut dyn ImportWindow,
        request: ImportRequest<'a>,
    ) -> Io<'a, CreatedCopies>;
}

/// The saved `Copying` stage must be this exact receipt, and the bundle must
/// be exactly its sources.
pub(crate) fn authorize_import(
    stage: DurableStage,
    receipt: &TransferReceipt,
    bundle: &TransferBundle,
) -> Result<(), String> {
    stage.authorize(&StageBinding::Copying(receipt.clone()))?;
    if receipt.source != bundle.assets {
        return Err("転送記録と転送元が一致しません。書込みは開始しません。".into());
    }
    Ok(())
}

#[derive(Debug)]
pub(crate) enum DeletionOutcome {
    /// Stopped before the native deletion; the unconsumed attempt is the proof.
    NotSubmitted(DeletionAttempt, String),
    /// Issued, or possibly issued, with the native result.
    Submitted(SubmittedDeletion, Result<(), String>),
}

pub(crate) trait SourceDeletion: Send + Sync {
    fn delete<'a>(
        &'a self,
        io: ReadIo<'a>,
        stage: DurableStage,
        attempt: DeletionAttempt,
    ) -> BoxFuture<'a, DeletionOutcome>;
}

/// The saved `DeletingSource` stage must be this attempt's exact receipt.
pub(crate) fn authorize_deletion(
    stage: DurableStage,
    attempt: &DeletionAttempt,
) -> Result<(), String> {
    stage.authorize(&StageBinding::DeletingSource(attempt.receipt().clone()))?;
    allow_deletion(attempt.sources())
}

/// The final deletion boundary. Every source and verified destination epoch
/// must still be current. Callers issue the native request with no await in
/// between; once submitted, non-submission can no longer be claimed.
pub(crate) fn submit_deletion(
    io: &ReadIo<'_>,
    attempt: DeletionAttempt,
) -> Result<SubmittedDeletion, (DeletionAttempt, String)> {
    match io.check(&attempt.dependencies()) {
        Ok(()) => Ok(attempt.submit()),
        Err(error) => Err((attempt, error)),
    }
}

pub(crate) trait FavoriteWrite: Send + Sync {
    /// Keys one native request may change together.
    fn batch_size(&self) -> usize;
    fn saved_status(&self) -> &'static str;
    fn set_favorite<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        value: bool,
    ) -> Io<'a, Vec<StoredAsset>>;
}

pub(crate) trait MetadataWrite: Send + Sync {
    fn change_metadata<'a>(
        &'a self,
        io: ReadIo<'a>,
        keys: &'a [AssetKey],
        change: &'a MetadataChange,
    ) -> Io<'a, Vec<StoredAsset>>;
}

pub(crate) trait AlbumReader: Send + Sync {
    fn album_scope(&self) -> &str;
    fn read_albums<'a>(&'a self, io: ReadIo<'a>) -> Io<'a, AlbumSnapshot>;
}

pub(crate) trait AlbumCreator: Send + Sync {
    fn create_album<'a>(&'a self, io: ReadIo<'a>, title: &'a str) -> Io<'a, StoredAlbum>;
}

pub(crate) trait AlbumEditor: Send + Sync {
    fn edit_collection<'a>(
        &'a self,
        _io: ReadIo<'a>,
        _edit: &'a crate::albums::CollectionEdit,
        _expected: &'a AlbumSnapshot,
    ) -> Io<'a, ()> {
        Box::pin(async {
            Err("この保存先のコレクション操作は未対応です。".into())
        })
    }

    fn edit_album<'a>(
        &'a self,
        io: ReadIo<'a>,
        key: &'a AlbumKey,
        edit: &'a AlbumEdit,
    ) -> Io<'a, ()>;
}

/// One connected provider's abilities. A service fills exactly its profile;
/// a test may fill any subset with fakes.
#[derive(Clone, Default)]
pub(crate) struct Abilities {
    pub listing: Option<Arc<dyn CatalogListing>>,
    pub export: Option<Arc<dyn OriginalExport>>,
    pub import: Option<Arc<dyn OriginalImport>>,
    pub deletion: Option<Arc<dyn SourceDeletion>>,
    pub favorite: Option<Arc<dyn FavoriteWrite>>,
    pub metadata: Option<Arc<dyn MetadataWrite>>,
    pub album_read: Option<Arc<dyn AlbumReader>>,
    pub album_create: Option<Arc<dyn AlbumCreator>>,
    pub album_edit: Option<Arc<dyn AlbumEditor>>,
}

impl Abilities {
    fn apple(backend: AppleBackend) -> Self {
        let b = Arc::new(backend);
        Self {
            listing: Some(b.clone() as Arc<dyn CatalogListing>),
            export: Some(b.clone() as Arc<dyn OriginalExport>),
            import: Some(b.clone() as Arc<dyn OriginalImport>),
            deletion: Some(b.clone() as Arc<dyn SourceDeletion>),
            favorite: Some(b.clone() as Arc<dyn FavoriteWrite>),
            metadata: Some(b.clone() as Arc<dyn MetadataWrite>),
            album_read: Some(b.clone() as Arc<dyn AlbumReader>),
            album_create: Some(b.clone() as Arc<dyn AlbumCreator>),
            album_edit: Some(b as Arc<dyn AlbumEditor>),
        }
    }

    fn immich(backend: ImmichBackend) -> Self {
        let b = Arc::new(backend);
        Self {
            listing: Some(b.clone() as Arc<dyn CatalogListing>),
            export: Some(b.clone() as Arc<dyn OriginalExport>),
            import: Some(b.clone() as Arc<dyn OriginalImport>),
            deletion: Some(b.clone() as Arc<dyn SourceDeletion>),
            favorite: Some(b.clone() as Arc<dyn FavoriteWrite>),
            metadata: Some(b.clone() as Arc<dyn MetadataWrite>),
            album_read: Some(b.clone() as Arc<dyn AlbumReader>),
            album_create: Some(b.clone() as Arc<dyn AlbumCreator>),
            album_edit: Some(b as Arc<dyn AlbumEditor>),
        }
    }

    fn amazon(backend: AmazonBackend) -> Self {
        let b = Arc::new(backend);
        Self {
            listing: Some(b.clone() as Arc<dyn CatalogListing>),
            export: Some(b.clone() as Arc<dyn OriginalExport>),
            import: Some(b.clone() as Arc<dyn OriginalImport>),
            favorite: Some(b as Arc<dyn FavoriteWrite>),
            ..Self::default()
        }
    }
}

/// Abilities for one operation. A disconnected provider has no table.
#[derive(Clone)]
pub(crate) struct Registry {
    apple: Abilities,
    immich: Option<Abilities>,
    amazon: Option<Abilities>,
}

impl Registry {
    /// An ability table per provider; the seam for fakes.
    pub(crate) fn new(
        apple: Abilities,
        immich: Option<Abilities>,
        amazon: Option<Abilities>,
    ) -> Self {
        Self {
            apple,
            immich,
            amazon,
        }
    }

    /// The real services, from the current immutable connection settings.
    pub(crate) fn services(
        apple: AppleBackend,
        immich: Option<ImmichBackend>,
        amazon: Option<AmazonBackend>,
    ) -> Self {
        Self::new(
            Abilities::apple(apple),
            immich.map(Abilities::immich),
            amazon.map(Abilities::amazon),
        )
    }

    fn table(&self, provider: Provider) -> Option<&Abilities> {
        match provider {
            Provider::Apple => Some(&self.apple),
            Provider::Immich => self.immich.as_ref(),
            Provider::Amazon => self.amazon.as_ref(),
        }
    }

    pub(crate) fn connected(&self, provider: Provider) -> bool {
        self.table(provider).is_some()
    }

    /// Why an ability is absent: no connection, or not offered by the service.
    pub(crate) fn missing(&self, provider: Provider, ability: Ability) -> String {
        if offers(provider, ability) && !self.connected(provider) {
            return match provider {
                Provider::Immich => "Immich に接続してください。",
                _ => "Amazon Photosに接続してください。",
            }
            .into();
        }
        unsupported(provider, ability)
    }

    pub(crate) fn listing(&self, provider: Provider) -> Option<&dyn CatalogListing> {
        self.table(provider)?.listing.as_deref()
    }

    pub(crate) fn export(&self, provider: Provider) -> Option<&dyn OriginalExport> {
        self.table(provider)?.export.as_deref()
    }

    pub(crate) fn import(&self, provider: Provider) -> Option<&dyn OriginalImport> {
        self.table(provider)?.import.as_deref()
    }

    pub(crate) fn deletion(&self, provider: Provider) -> Option<&dyn SourceDeletion> {
        self.table(provider)?.deletion.as_deref()
    }

    pub(crate) fn favorites(&self, provider: Provider) -> Option<&dyn FavoriteWrite> {
        self.table(provider)?.favorite.as_deref()
    }

    pub(crate) fn metadata(&self, provider: Provider) -> Option<&dyn MetadataWrite> {
        self.table(provider)?.metadata.as_deref()
    }

    pub(crate) fn album_reader(&self, provider: Provider) -> Option<&dyn AlbumReader> {
        self.table(provider)?.album_read.as_deref()
    }

    pub(crate) fn album_creator(&self, provider: Provider) -> Option<&dyn AlbumCreator> {
        self.table(provider)?.album_create.as_deref()
    }

    pub(crate) fn album_editor(&self, provider: Provider) -> Option<&dyn AlbumEditor> {
        self.table(provider)?.album_edit.as_deref()
    }

    /// An explicit Move needs deletion at the source and a destination whose
    /// verified copies preserve what a Move promises.
    pub(crate) fn move_blocker(&self, source: Provider, destination: Provider) -> Option<String> {
        if self.deletion(source).is_none() {
            return Some(self.missing(source, Ability::SourceDeletion));
        }
        if !self
            .import(destination)
            .is_some_and(OriginalImport::supports_move)
        {
            return Some(match destination {
                Provider::Amazon => unsupported(destination, Ability::SourceDeletion),
                _ => self.missing(destination, Ability::OriginalImport),
            });
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        amazon::Connection,
        immich::{Session, Version},
        transport::OrdinarySessionGuard,
    };

    fn connected() -> Result<Registry, String> {
        let session = Session {
            ordinary_content_guard: None,
            ordinary_content_context: None,
            endpoint: "https://fixture.example/api".into(),
            key: "key".into(),
            user_id: "owner".into(),
            scope: "remote".into(),
            version: Version {
                major: 3,
                minor: 2,
                patch: 4,
            },
        };
        let mut connection = Connection::provisional("credential")?;
        connection.scope = "amazon.co.jp|owner".into();
        let guard = OrdinarySessionGuard {
            generation: Arc::default(),
            expected: 0,
        };
        Ok(Registry::services(
            AppleBackend::new("apple".into()),
            Some(ImmichBackend::new(session)),
            Some(AmazonBackend::new(connection, "revision".into(), guard)),
        ))
    }

    fn exposes(registry: &Registry, provider: Provider, ability: Ability) -> bool {
        match ability {
            Ability::Listing => registry.listing(provider).is_some(),
            Ability::OriginalExport => registry.export(provider).is_some(),
            Ability::OriginalImport => registry.import(provider).is_some(),
            Ability::SourceDeletion => registry.deletion(provider).is_some(),
            Ability::Favorite => registry.favorites(provider).is_some(),
            Ability::Metadata => registry.metadata(provider).is_some(),
            Ability::AlbumRead => registry.album_reader(provider).is_some(),
            Ability::AlbumCreate => registry.album_creator(provider).is_some(),
            Ability::AlbumEdit => registry.album_editor(provider).is_some(),
        }
    }

    const ABILITIES: [Ability; 9] = [
        Ability::Listing,
        Ability::OriginalExport,
        Ability::OriginalImport,
        Ability::SourceDeletion,
        Ability::Favorite,
        Ability::Metadata,
        Ability::AlbumRead,
        Ability::AlbumCreate,
        Ability::AlbumEdit,
    ];

    #[test]
    fn a_connected_registry_exposes_exactly_each_service_profile() -> Result<(), String> {
        let registry = connected()?;
        for provider in PROVIDERS {
            for ability in ABILITIES {
                assert_eq!(
                    exposes(&registry, provider, ability),
                    offers(provider, ability),
                    "{provider:?} {ability:?}"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn disconnected_services_expose_nothing_and_ask_for_a_connection() {
        let registry = Registry::services(AppleBackend::new("apple".into()), None, None);
        for provider in [Provider::Immich, Provider::Amazon] {
            for ability in ABILITIES {
                assert!(!exposes(&registry, provider, ability));
            }
        }
        assert_eq!(
            registry.missing(Provider::Immich, Ability::OriginalExport),
            "Immich に接続してください。"
        );
        assert!(
            registry
                .missing(Provider::Amazon, Ability::Metadata)
                .contains("対応していません")
        );
    }

    #[test]
    fn moves_need_source_deletion_and_a_move_preserving_destination() -> Result<(), String> {
        let registry = connected()?;
        assert!(
            registry
                .move_blocker(Provider::Apple, Provider::Immich)
                .is_none()
        );
        assert!(
            registry
                .move_blocker(Provider::Immich, Provider::Apple)
                .is_none()
        );
        assert!(
            registry
                .move_blocker(Provider::Amazon, Provider::Apple)
                .is_some()
        );
        assert!(
            registry
                .move_blocker(Provider::Apple, Provider::Amazon)
                .is_some()
        );
        Ok(())
    }
}
