//! Real disposable-server traffic through product Core import events. Only
//! staged-file inspection and local storage are fixture adapters; no live user
//! library, system picker, or `PhotoKit` service is called by this test.
use super::*;
use crux_core::Core;
use sha2::{Digest, Sha256};
use suwop_core::{
    app::{Model, Suwop},
    external_import::{ImportItem, ImportMetadata, ImportPhase, StagedResource},
};

#[path = "external_import_fixtures.rs"]
mod fixtures;

pub(super) async fn exercise(
    ctx: &Context,
    session: &Session,
    directory: &Path,
) -> Result<(), String> {
    let root = directory.join("external-import");
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let sets = fixtures::items(&root)?;
    for (case, item) in sets.into_iter().enumerate() {
        let state = SavedLibrary {
            schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
            ..SavedLibrary::default()
        };
        let core = fixture_core(state.clone(), session);
        let mut host = Host {
            ctx,
            root: root.clone(),
            state,
            mutations: vec![],
            lose_upload: false,
            observations: BTreeMap::new(),
            diagnostics: Vec::new(),
        };
        let operation = format!("pp03-import-{case}");
        host.drive(
            &core,
            Event::ImportStaged {
                id: operation.clone(),
                destination: Provider::Immich,
                items: vec![item.clone()],
                now: 1_760_000_000.0,
            },
        )
        .await?;
        if let Some(error) = core.view().error {
            if error != "読み出し中に写真が変更されました。" {
                return Err(format!("external import case {case}: {error}"));
            }
            Box::pin(reconcile_freshness_refusal(&mut host, session)).await?;
        }
        let record = host
            .state
            .external_imports
            .last()
            .ok_or("missing import journal")?
            .clone();
        assert_eq!(record.phase, ImportPhase::Verified);
        assert_eq!(record.created, Some(true));
        let originals =
            snapshot_created_import(&mut host, session, &record.destination_keys).await?;
        // Fresh process, same durable journal. Same-byte external re-import on
        // a single image is AlreadyPresent; it must not update existing metadata.
        let restarted = fixture_core(host.state.clone(), session);
        host.mutations.clear();
        host.drive(
            &restarted,
            Event::ImportStaged {
                id: format!("pp03-reimport-{case}"),
                destination: Provider::Immich,
                items: vec![ImportItem {
                    id: format!("reimport-{case}"),
                    ..item.clone()
                }],
                now: 1_760_000_100.0,
            },
        )
        .await?;
        let last = host
            .state
            .external_imports
            .last()
            .ok_or("reimport journal")?;
        if item.resources.len() == 1 {
            assert!(restarted.view().error.is_none());
            assert_eq!(last.phase, ImportPhase::AlreadyPresent);
            assert_eq!(last.destination_keys, record.destination_keys);
        } else {
            assert!(restarted.view().error.is_some());
            assert_eq!(last.phase, ImportPhase::Uncertain);
        }
        assert!(
            host.mutations
                .iter()
                .all(|(method, url)| method == "POST" && url.ends_with("/assets"))
        );
        verify_unchanged(ctx, session, &originals).await?;
        if case == 0 {
            Box::pin(verify_duplicate_existing(
                &mut host,
                session,
                &record.destination_keys,
            ))
            .await?;
        }
    }
    Box::pin(lost_response(ctx, session, &root)).await?;
    Ok(())
}

async fn snapshot_created_import(
    host: &mut Host<'_>,
    session: &Session,
    keys: &[AssetKey],
) -> Result<Vec<suwop_core::immich::Asset>, String> {
    let mut originals = vec![];
    let mut snapshot = vec![];
    for key in keys {
        let asset = settled_created_asset(host.ctx, session, &key.asset_id).await?;
        let files = session.files(host.ctx, &asset.id).await?;
        snapshot.push(asset.record(&session.scope, None, Some(&files)));
        originals.push(asset);
    }
    host.state.snapshots = vec![LibrarySnapshot {
        provider: Provider::Immich,
        scope: session.scope.clone(),
        assets: snapshot,
        access: ScanAccess::Full,
        scanned_at: Some(1_760_000_000.0),
    }];
    Ok(originals)
}

// Server extraction jobs may finish after a successful create/readback. Capture
// the no-mutation control only after its generated EXIF projection has settled.
async fn settled_created_asset(
    ctx: &Context,
    session: &Session,
    id: &str,
) -> Result<suwop_core::immich::Asset, String> {
    let mut previous = Value::Null;
    let mut stable = 0;
    for _ in 0..20 {
        let asset = session.asset(ctx, id).await?;
        let observed = serde_json::to_value(&asset).map_err(|error| error.to_string())?;
        let extracted = asset
            .exif_info
            .as_ref()
            .is_some_and(|exif| exif.date_time_original.is_some());
        if extracted && observed == previous {
            stable += 1;
        } else {
            stable = 0;
        }
        if stable == 3 {
            return Ok(asset);
        }
        previous = observed;
        let _: Value = suwop_core::app::io(ctx, ShellOperation::Wait { milliseconds: 500 }).await?;
    }
    Err("Generated import EXIF projection did not settle before the no-mutation control".into())
}

async fn verify_duplicate_existing(
    host: &mut Host<'_>,
    session: &Session,
    keys: &[AssetKey],
) -> Result<(), String> {
    // Actual Duplicate event must classify the dedup answer as existing,
    // not a new independent copy. The source remains unchanged.
    let restarted = fixture_core(host.state.clone(), session);
    host.mutations.clear();
    host.drive(
        &restarted,
        Event::Duplicate {
            id: "pp04-existing".into(),
            destination: Provider::Immich,
            keys: keys.to_vec(),
            current: false,
            now: 1_760_000_200.0,
        },
    )
    .await?;
    assert!(
        restarted.view().error.is_none(),
        "{:?}",
        restarted.view().error
    );
    assert_eq!(
        host.state
            .external_imports
            .last()
            .ok_or("duplicate journal")?
            .phase,
        ImportPhase::AlreadyPresent
    );
    assert!(host.mutations.iter().all(|(method, _)| method != "PUT"));
    Ok(())
}

async fn reconcile_freshness_refusal(host: &mut Host<'_>, session: &Session) -> Result<(), String> {
    let record = host
        .state
        .external_imports
        .last()
        .ok_or("freshness journal missing")?
        .clone();
    assert_eq!(record.phase, ImportPhase::Uncertain);
    assert_eq!(record.created, Some(true));
    assert!(!record.destination_keys.is_empty());
    let writes = host.mutations.clone();
    let disk: SavedLibrary = serde_json::from_slice(
        &std::fs::read(host.root.join("journal.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let restarted = fixture_core(disk, session);
    for _ in 0..5 {
        let _: Value =
            suwop_core::app::io(host.ctx, ShellOperation::Wait { milliseconds: 1000 }).await?;
        host.drive(
            &restarted,
            Event::InspectImport {
                id: record.id.clone(),
            },
        )
        .await?;
        assert_eq!(
            host.mutations, writes,
            "read-only recovery must never repeat upload or metadata writes"
        );
        if restarted.view().error.is_none() {
            assert_eq!(
                host.state
                    .external_imports
                    .last()
                    .ok_or("reconciled journal missing")?
                    .phase,
                ImportPhase::Verified
            );
            host.diagnostics.push(
                "freshness refusal recovered read-only after restart; no writes replayed".into(),
            );
            host.save_diagnostics()?;
            return Ok(());
        }
        if restarted.view().error.as_deref() != Some("読み出し中に写真が変更されました。")
        {
            return Err(format!(
                "read-only import recovery failed: {:?}",
                restarted.view().error
            ));
        }
    }
    Err("import destination did not become stable across bounded read-only inspections".into())
}

async fn lost_response(ctx: &Context, session: &Session, root: &Path) -> Result<(), String> {
    let state = SavedLibrary {
        schema_version: suwop_core::immich_live_writes::CURRENT_SCHEMA_VERSION,
        ..SavedLibrary::default()
    };
    let core = fixture_core(state.clone(), session);
    let mut host = Host {
        ctx,
        root: root.into(),
        state,
        mutations: vec![],
        lose_upload: true,
        observations: BTreeMap::new(),
        diagnostics: Vec::new(),
    };
    host.drive(
        &core,
        Event::ImportStaged {
            id: "pp03-lost".into(),
            destination: Provider::Immich,
            items: vec![fixtures::lost_item(root)?],
            now: 1_760_000_300.0,
        },
    )
    .await?;
    assert!(core.view().error.is_some());
    assert_eq!(host.mutations.len(), 1);
    let saved = host
        .state
        .external_imports
        .last()
        .ok_or("lost response journal")?
        .clone();
    assert_eq!(saved.phase, ImportPhase::Uncertain);
    assert!(saved.destination_keys.is_empty());
    assert_eq!(saved.created, None);
    // A process restart reads the durable journal. No destination ID can be
    // guessed from a checksum, and inspecting must never upload again.
    let disk: SavedLibrary = serde_json::from_slice(
        &std::fs::read(root.join("journal.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let restarted = fixture_core(disk, session);
    host.mutations.clear();
    host.drive(&restarted, Event::InspectImport { id: saved.id })
        .await?;
    assert!(restarted.view().error.is_some());
    assert!(host.mutations.is_empty());
    assert_eq!(
        host.state
            .external_imports
            .last()
            .ok_or("unknown journal retained")?
            .phase,
        ImportPhase::Uncertain
    );
    assert!(root.join("lost-response").is_file());
    Ok(())
}

fn fixture_core(state: SavedLibrary, session: &Session) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            ready: true,
            state,
            session: Some(session.clone()),
            ..Model::default()
        },
    )
}

struct Host<'a> {
    ctx: &'a Context,
    root: std::path::PathBuf,
    state: SavedLibrary,
    mutations: Vec<(String, String)>,
    lose_upload: bool,
    observations: BTreeMap<String, (String, String)>,
    diagnostics: Vec<String>,
}
impl Host<'_> {
    async fn drive(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut pending = std::collections::VecDeque::from(core.process_event(event));
        let mut count = 0;
        while let Some(Effect::Io(mut request)) = pending.pop_front() {
            count += 1;
            if count > 1000 {
                return Err("external import fixture effect budget".into());
            }
            let result = self.respond(&request.operation).await;
            if result.is_err() {
                self.diagnostics.push(format!(
                    "failed effect {:?}",
                    std::mem::discriminant(&request.operation)
                ));
            }
            pending.extend(
                core.resolve(
                    &mut request,
                    match result {
                        Ok(value) => ShellResponse {
                            value: Some(value),
                            error: None,
                        },
                        Err(error) => ShellResponse {
                            value: None,
                            error: Some(error),
                        },
                    },
                )
                .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        self.save_diagnostics()?;
        Ok(())
    }
    fn save_diagnostics(&self) -> Result<(), String> {
        std::fs::write(
            self.root.join("safe-diagnostics.json"),
            serde_json::to_vec(&self.diagnostics).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())
    }
    fn observe_asset_revision(&mut self, response: &Value) {
        let body = &response["body"];
        if let (Some(id), Some(updated), Some(checksum)) = (
            body["id"].as_str(),
            body["updatedAt"].as_str(),
            body["checksum"].as_str(),
        ) && let Some((old_revision, old_checksum)) = self
            .observations
            .insert(id.into(), (updated.into(), checksum.into()))
            && (old_revision != updated || old_checksum != checksum)
        {
            self.diagnostics.push(format!(
                "revision_changed={},checksum_changed={}",
                old_revision != updated,
                old_checksum != checksum
            ));
        }
    }

    fn stage_files(&self, files: &[suwop_core::sharing::ShareFile]) -> Result<Value, String> {
        let mut resources = vec![];
        for (index, file) in files.iter().enumerate() {
            let bytes = std::fs::read(&file.path).map_err(|e| e.to_string())?;
            let token = format!("duplicate-resource-{index}");
            std::fs::write(self.root.join(&token), &bytes).map_err(|e| e.to_string())?;
            resources.push(StagedResource {
                token,
                name: file.name.clone(),
                role: ResourceRole::Image,
                media_type: "image/png".into(),
                sha256: format!("{:x}", Sha256::digest(&bytes)),
                bytes: bytes.len() as u64,
                content_identifier: None,
            });
        }
        serde_json::to_value(vec![ImportItem {
            id: "duplicate-item".into(),
            resources,
            metadata: ImportMetadata::default(),
        }])
        .map_err(|e| e.to_string())
    }

    async fn respond(&mut self, operation: &ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::ImportHttp { request } => {
                let current = self
                    .state
                    .external_imports
                    .last()
                    .ok_or("write without durable journal")?;
                assert_eq!(current.phase, ImportPhase::Submitting);
                self.mutations
                    .push((request.method.clone(), request.url.clone()));
                let value: Value =
                    suwop_core::app::io(self.ctx, ShellOperation::Http(request.clone())).await?;
                if self.lose_upload && request.method == "POST" && request.url.ends_with("/assets")
                {
                    self.lose_upload = false;
                    return Err("fixture lost upload response".into());
                }
                Ok(value)
            }
            ShellOperation::Http(request) => {
                if let Some(path) = &request.download_path {
                    let path = Path::new(path);
                    if !path.starts_with(&self.root)
                        || path
                            .components()
                            .any(|c| matches!(c, std::path::Component::ParentDir))
                    {
                        return Err("download escaped fixture workspace".into());
                    }
                    std::fs::create_dir_all(path.parent().ok_or("download parent missing")?)
                        .map_err(|e| e.to_string())?;
                }
                let value: Value =
                    suwop_core::app::io(self.ctx, ShellOperation::Http(request.clone())).await?;
                if request.method == "GET" {
                    self.observe_asset_revision(&value);
                }
                Ok(value)
            }
            ShellOperation::Wait { milliseconds } => {
                suwop_core::app::io(
                    self.ctx,
                    ShellOperation::Wait {
                        milliseconds: *milliseconds,
                    },
                )
                .await
            }
            ShellOperation::ResolveImportResource { resource, .. } => {
                let path = self.root.join(&resource.token);
                let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
                assert_eq!(resource.sha256, format!("{:x}", Sha256::digest(&bytes)));
                Ok(json!(path.to_string_lossy()))
            }
            ShellOperation::StageImportFiles { files, .. } => self.stage_files(files),
            ShellOperation::Workspace { id } => {
                let path = self.root.join("work").join(id);
                std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
                Ok(json!(path.to_string_lossy()))
            }
            ShellOperation::HashFile { path } => {
                let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
                Ok(json!({"sha1":format!("{:x}",sha1::Sha1::digest(&bytes)),
                    "signature":{"sha256":format!("{:x}",Sha256::digest(&bytes)),"bytes":bytes.len()}}))
            }
            ShellOperation::Persist(state) => {
                suwop_core::external_import::validate_transition(
                    &self.state.external_imports,
                    &state.external_imports,
                )?;
                self.state = state.clone();
                std::fs::write(
                    self.root.join("journal.json"),
                    serde_json::to_vec(state).map_err(|e| e.to_string())?,
                )
                .map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            ShellOperation::Cleanup { .. } | ShellOperation::ReleaseImportStaging { .. } => {
                Ok(Value::Null)
            }
            _ => Err("unexpected import fixture native effect".into()),
        }
    }
}

async fn verify_unchanged(
    ctx: &Context,
    session: &Session,
    originals: &[suwop_core::immich::Asset],
) -> Result<(), String> {
    for before in originals {
        let after = session.asset(ctx, &before.id).await?;
        assert_eq!(after.checksum, before.checksum);
        assert_eq!(after.original_file_name, before.original_file_name);
        assert_eq!(after.is_favorite, before.is_favorite);
        assert_eq!(after.live_photo_video_id, before.live_photo_video_id);
        assert_eq!(
            serde_json::to_value(&after.exif_info).map_err(|e| e.to_string())?,
            serde_json::to_value(&before.exif_info).map_err(|e| e.to_string())?
        );
    }
    Ok(())
}
