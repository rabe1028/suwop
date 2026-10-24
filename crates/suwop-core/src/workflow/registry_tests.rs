//! The common copy/Move orchestration driven through injected fakes that
//! implement only some abilities, as a new service would.
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};

use serde_json::{Value, json};

use super::Runtime;
use crate::{
    app::{Context, Effect, Event, SavedLibrary, ShellOperation, ShellResponse},
    domain::{
        AppleVisibility, AssetKey, FileSignature, ImmichStackState, LibrarySnapshot, PhotoResource,
        Provider, ResourceRole, ScanAccess, StoredAsset, TransferBundle, TransferFile,
        TransferIntent, TransferPhase,
    },
    immich::{Session, Version},
    provider::{
        Abilities, CreatedCopies, ExportRequest, ImportRequest, ImportWindow, Io, OriginalExport,
        OriginalImport, ReadIo, Registry, authorize_import,
    },
};

const SHA1: &str = "1111111111111111111111111111111111111111";

fn asset(provider: Provider, scope: &str, id: &str) -> StoredAsset {
    StoredAsset {
        immich_visibility: None,
        immich_stack: ImmichStackState::Unknown,
        immich_stack_membership: None,
        apple_visibility: AppleVisibility::Visible,
        key: AssetKey {
            provider,
            scope: scope.into(),
            asset_id: id.into(),
        },
        name: "photo.jpg".into(),
        captured_at: Some(10.0),
        modified_at: None,
        revision: "revision".into(),
        resources: vec![PhotoResource {
            id: id.into(),
            name: "photo.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some(SHA1.into()),
            bytes: Some(3),
        }],
        is_favorite: false,
        latitude: None,
        longitude: None,
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}

fn bundle(asset: StoredAsset) -> TransferBundle {
    TransferBundle {
        files: vec![TransferFile {
            resource: asset.resources[0].clone(),
            path: "/fake/original".into(),
            signature: FileSignature {
                sha256: "a".repeat(64),
                bytes: 3,
            },
        }],
        assets: vec![asset],
    }
}

/// Export only: a read-only source.
struct FakeSource {
    exports: AtomicUsize,
}

impl OriginalExport for FakeSource {
    fn export<'a>(
        &'a self,
        _io: ReadIo<'a>,
        _request: ExportRequest<'a>,
    ) -> Io<'a, TransferBundle> {
        self.exports.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move { Ok::<_, String>(bundle(asset(Provider::Apple, "apple", "source"))) })
    }
}

/// Copy destination without deletion, metadata or albums.
struct FakeDestination {
    imports: AtomicUsize,
    readbacks: AtomicUsize,
}

impl OriginalExport for FakeDestination {
    fn export<'a>(
        &'a self,
        _io: ReadIo<'a>,
        _request: ExportRequest<'a>,
    ) -> Io<'a, TransferBundle> {
        self.readbacks.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move { Ok::<_, String>(bundle(asset(Provider::Immich, "remote", "copy"))) })
    }
}

impl OriginalImport for FakeDestination {
    fn scope(&self) -> &'static str {
        "remote"
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
        _io: ReadIo<'a>,
        _window: &'a mut dyn ImportWindow,
        request: ImportRequest<'a>,
    ) -> Io<'a, CreatedCopies> {
        Box::pin(async move {
            authorize_import(request.stage, request.receipt, request.bundle)?;
            self.imports.fetch_add(1, Ordering::SeqCst);
            Ok::<_, String>(CreatedCopies(vec![
                asset(Provider::Immich, "remote", "copy").key,
            ]))
        })
    }
}

fn runtime(ctx: &Context, registry: Registry) -> Runtime<'_> {
    let mut state = SavedLibrary {
        schema_version: 9,
        apple_scope: "apple".into(),
        ..SavedLibrary::default()
    };
    state.snapshots.push(LibrarySnapshot {
        provider: Provider::Apple,
        scope: "apple".into(),
        assets: vec![asset(Provider::Apple, "apple", "source")],
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    Runtime {
        refresh_persist_issued: false,
        ordinary_selected: vec![],
        denied_content: std::collections::BTreeSet::new(),
        ordinary_generation: Arc::default(),
        started_ordinary_generation: 0,
        ordinary_revision: "fixture".into(),
        session_published: true,
        apple_generation: Arc::default(),
        started_generation: 0,
        reversion_started: false,
        preferred_preview: None,
        ctx,
        state,
        session: Some(Session {
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
        }),
        workspace: None,
        editing_token: None,
        injected_registry: Some(registry),
    }
}

type Observed = Arc<Mutex<Option<(Result<(), String>, Vec<TransferPhase>)>>>;

/// Run one copy through the workflow and answer its native effects.
fn copy(registry: Registry, intent: TransferIntent) -> Result<(Observed, usize), String> {
    let observed: Observed = Arc::default();
    let sink = observed.clone();
    let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
        let mut runtime = runtime(&ctx, registry);
        let source = asset(Provider::Apple, "apple", "source").key;
        let result = runtime
            .copy_to(&[source], Provider::Immich, intent, "receipt", 1.0)
            .await;
        let phases = runtime.state.receipts.iter().map(|r| r.phase).collect();
        if let Ok(mut slot) = sink.lock() {
            *slot = Some((result, phases));
        }
    });
    let mut effects_seen = 0;
    for _ in 0..50 {
        let effects: Vec<_> = command.effects().collect();
        if effects.is_empty() {
            return Ok((observed, effects_seen));
        }
        for Effect::Io(mut effect) in effects {
            effects_seen += 1;
            let value = match &effect.operation {
                ShellOperation::Workspace { .. } => json!("/fake"),
                ShellOperation::Persist(_) => Value::Null,
                _ => return Err("only journal and workspace effects are expected".into()),
            };
            effect
                .resolve(ShellResponse {
                    value: Some(value),
                    error: None,
                })
                .map_err(|_| "resolve")?;
        }
    }
    Err("effect loop did not terminate".into())
}

#[test]
fn a_copy_only_fake_service_runs_the_common_copy_and_cannot_be_moved() -> Result<(), String> {
    let source = Arc::new(FakeSource {
        exports: AtomicUsize::new(0),
    });
    let destination = Arc::new(FakeDestination {
        imports: AtomicUsize::new(0),
        readbacks: AtomicUsize::new(0),
    });
    let registry = Registry::new(
        Abilities {
            export: Some(source.clone() as Arc<dyn OriginalExport>),
            ..Abilities::default()
        },
        Some(Abilities {
            export: Some(destination.clone() as Arc<dyn OriginalExport>),
            import: Some(destination.clone() as Arc<dyn OriginalImport>),
            ..Abilities::default()
        }),
        None,
    );

    let (observed, effects) = copy(registry.clone(), TransferIntent::Copy)?;
    let (result, phases) = observed
        .lock()
        .map_err(|_| "lock")?
        .take()
        .ok_or("copy did not finish")?;
    assert_eq!(result, Ok(()));
    assert_eq!(phases, [TransferPhase::Copied]);
    // Workspace, the Copying save before import, and the Copied save.
    assert_eq!(effects, 3);
    assert_eq!(source.exports.load(Ordering::SeqCst), 1);
    assert_eq!(destination.imports.load(Ordering::SeqCst), 1);
    assert_eq!(destination.readbacks.load(Ordering::SeqCst), 1);

    // The fake source has no deletion ability: a Move stops before any effect.
    let (observed, effects) = copy(registry, TransferIntent::Move)?;
    let (result, phases) = observed
        .lock()
        .map_err(|_| "lock")?
        .take()
        .ok_or("move did not finish")?;
    assert!(result.is_err());
    assert!(phases.is_empty());
    assert_eq!(effects, 0);
    assert_eq!(destination.imports.load(Ordering::SeqCst), 1);
    Ok(())
}
