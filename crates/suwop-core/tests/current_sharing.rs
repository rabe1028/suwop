use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset,
    },
    editing::{ImageEncodingFacts, PixelSize},
    immich::{Asset, HttpResponse, Session, Version},
    sharing::{
        CurrentImageExport, CurrentImageFacts, CurrentImageRenderPlan, CurrentImageRenderResult,
        current_image_asset,
    },
    workflow::HashResult,
};

const ID: &str = "11111111-1111-4111-8111-111111111111";
const OWNER: &str = "22222222-2222-4222-8222-222222222222";
const FILE: &str = "33333333-3333-4333-8333-333333333333";
fn apple() -> StoredAsset {
    StoredAsset {
        apple_visibility: suwop_core::domain::AppleVisibility::Visible,
        key: AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        },
        name: "original.jpg".into(),
        captured_at: Some(10.0),
        modified_at: None,
        revision: "source-1".into(),
        resources: vec![PhotoResource {
            id: "0".into(),
            name: "original.jpg".into(),
            role: ResourceRole::Image,
            sha1: Some("1".repeat(40)),
            bytes: Some(12),
        }],
        is_favorite: true,
        latitude: Some(0.0),
        longitude: Some(0.0),
        inventory_complete: true,
        is_offline: false,
        deletion_blockers: vec![],
    }
}
fn session() -> Session {
    Session {
        endpoint: "https://photos.example/api".into(),
        key: "fixture".into(),
        user_id: OWNER.into(),
        scope: "remote".into(),
        version: Version {
            major: 3,
            minor: 2,
            patch: 4,
        },
    }
}
fn native_remote() -> Value {
    json!({"id":ID,"ownerId":OWNER,"type":"IMAGE","originalFileName":"original.jpg","checksum":"1111111111111111111111111111111111111111","fileCreatedAt":"1970-01-01T00:00:10Z","fileModifiedAt":"1970-01-01T00:00:10Z","updatedAt":"revision-1","isFavorite":true,"isOffline":false,"isTrashed":false,"isEdited":true,"isExternal":false,"exifInfo":{"dateTimeOriginal":"1970-01-01T00:00:10Z","fileSizeInByte":12}})
}
fn facts() -> CurrentImageFacts {
    CurrentImageFacts {
        content_type: "public.png".into(),
        width: 48000,
        height: 32000,
        orientation: 1,
        frames: 1,
    }
}
fn state(asset: StoredAsset) -> SavedLibrary {
    SavedLibrary {
        schema_version: 3,
        apple_scope: "apple".into(),
        snapshots: vec![LibrarySnapshot {
            provider: asset.key.provider,
            scope: asset.key.scope.clone(),
            access: ScanAccess::Limited,
            assets: vec![asset],
            scanned_at: Some(10.0),
        }],
        ..SavedLibrary::default()
    }
}
#[derive(Clone, Copy, Default)]
enum Fault {
    #[default]
    None,
    WebP,
    Revision,
    Escape,
    Format,
    MultipleFrames,
    Empty,
    CopyChanged,
    Cancel,
    Cleanup,
    ExportLost,
    UnknownEdited,
    Unedited,
    WrongOriginal,
    ChangedEdits,
    UnsupportedEdits,
    WrongRender,
    WrongMetadata,
    OversizedRender,
    HdrRender,
}
struct Shell {
    asset: StoredAsset,
    fault: Fault,
    trace: Vec<String>,
    files: Vec<String>,
    hashes: usize,
    rendered: bool,
    edit_reads: usize,
}
impl Shell {
    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Workspace { .. } => {
                self.trace.push("workspace".into());
                Ok(json!("/tmp/current-test"))
            }
            ShellOperation::AppleCurrentImage { directory, asset } => {
                self.trace.push("current-image".into());
                if matches!(self.fault, Fault::ExportLost) {
                    return Err("cancelled export".into());
                }
                let mut fresh = self.asset.clone();
                if matches!(self.fault, Fault::Revision) {
                    fresh.revision = "changed".into();
                }
                let mut image = facts();
                if matches!(self.fault, Fault::WebP) {
                    image.content_type = "org.webmproject.webp".into();
                }
                if matches!(self.fault, Fault::Format) {
                    image.content_type = "application/unknown".into();
                }
                if matches!(self.fault, Fault::MultipleFrames) {
                    image.frames = 2;
                }
                let path = if matches!(self.fault, Fault::Escape) {
                    "/outside/current".into()
                } else {
                    format!("{directory}/current-image")
                };
                serde_json::to_value(CurrentImageExport {
                    asset,
                    fresh_asset: fresh,
                    path,
                    image,
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::InspectCurrentImage { .. } => {
                serde_json::to_value(facts()).map_err(|e| e.to_string())
            }
            ShellOperation::InspectImageEncoding { .. } => {
                self.trace.push("inspect-encoding".into());
                serde_json::to_value(ImageEncodingFacts {
                    raw_dimensions: if matches!(self.fault, Fault::OversizedRender) {
                        PixelSize {
                            width: 4001,
                            height: 4000,
                        }
                    } else {
                        PixelSize {
                            width: 4,
                            height: 3,
                        }
                    },
                    orientation: 1,
                    has_color_space: true,
                    has_alpha: false,
                    hdr: matches!(self.fault, Fault::HdrRender),
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::RenderCurrentImage { plan, .. } => self.render(plan),
            ShellOperation::HashFile { path } => self.hash(&path),
            ShellOperation::CopyFile { .. } => {
                self.trace.push("copy".into());
                Ok(Value::Null)
            }
            ShellOperation::ShareFiles(presentation) => {
                assert_eq!(presentation.source_keys, Some(vec![self.asset.key.clone()]));
                self.trace.push("share".into());
                self.files = presentation.files.into_iter().map(|f| f.name).collect();
                Ok(json!(!matches!(self.fault, Fault::Cancel)))
            }
            ShellOperation::Cleanup { .. } => {
                self.trace.push("cleanup".into());
                if matches!(self.fault, Fault::Cleanup) {
                    Err("cleanup failed".into())
                } else {
                    Ok(Value::Null)
                }
            }
            ShellOperation::Http(request) => self.http(request),
            _ => Err("unexpected write or effect".into()),
        }
    }
    fn hash(&mut self, path: &str) -> Result<Value, String> {
        self.hashes += 1;
        self.trace.push("hash".into());
        let original = self.asset.key.provider == Provider::Immich
            && (!self.rendered || path.contains("current-original"));
        serde_json::to_value(HashResult {
            sha1: if original {
                if matches!(self.fault, Fault::WrongOriginal) {
                    "2"
                } else {
                    "1"
                }
            } else {
                "a"
            }
            .repeat(40),
            signature: FileSignature {
                sha256: if self.hashes == 2 && matches!(self.fault, Fault::CopyChanged) {
                    "b"
                } else {
                    "a"
                }
                .repeat(64),
                bytes: if matches!(self.fault, Fault::Empty) {
                    0
                } else if original {
                    12
                } else {
                    8
                },
            },
        })
        .map_err(|e| e.to_string())
    }
    fn render(&mut self, plan: CurrentImageRenderPlan) -> Result<Value, String> {
        self.trace.push("render".into());
        self.rendered = true;
        assert_eq!(
            plan.transform.output_size(plan.dimensions)?,
            PixelSize {
                width: 1,
                height: 2
            }
        );
        let mut image = facts();
        image.width = if matches!(self.fault, Fault::WrongRender) {
            2
        } else {
            1
        };
        image.height = 2;
        let mut metadata = plan.metadata;
        if matches!(self.fault, Fault::WrongMetadata) {
            metadata.date_time_original = None;
        }
        serde_json::to_value(CurrentImageRenderResult { image, metadata })
            .map_err(|e| e.to_string())
    }
    fn http(&mut self, request: suwop_core::immich::HttpRequest) -> Result<Value, String> {
        self.trace
            .push(format!("{} {}", request.method, request.url));
        if request.method != "GET" {
            return Err("write forbidden".into());
        }
        let body = if request.download_path.is_some() {
            Value::Null
        } else if request.url.ends_with("/edits") {
            self.edit_reads += 1;
            json!({"assetId":ID,"edits":[
                {"id":FILE,"action":if matches!(self.fault, Fault::UnsupportedEdits) {"brightness"} else {"crop"},"parameters":{"x":0,"y":0,"width":2,"height":1}},
                {"id":OWNER,"action":"rotate","parameters":{"angle":if self.edit_reads == 2 && matches!(self.fault, Fault::ChangedEdits) {180} else {90}}}
            ]})
        } else if request.url.contains("asset-files?") {
            // Looks valid and remains stable while a newer editor job is
            // pending: file identity alone is not current-render provenance.
            json!([{"id":FILE,"type":"fullsize","isEdited":true,"path":"old-render.jpg","updatedAt":"1970-01-01T00:00:10Z"}])
        } else {
            let mut asset = native_remote();
            if matches!(self.fault, Fault::UnknownEdited) {
                asset["isEdited"] = Value::Null;
            } else if matches!(self.fault, Fault::Unedited | Fault::WrongOriginal) {
                asset["isEdited"] = json!(false);
            }
            asset
        };
        serde_json::to_value(HttpResponse {
            status: 200,
            body,
            path: request.download_path,
        })
        .map_err(|e| e.to_string())
    }
    fn run(&mut self, remote: bool) -> Result<Core<Suwop>, String> {
        let core = Core::new_with(
            Suwop,
            Model {
                ready: true,
                state: state(self.asset.clone()),
                session: remote.then(session),
                ..Model::default()
            },
        );
        let mut effects = core.process_event(Event::ShareCurrentImage {
            key: self.asset.key.clone(),
            id: ID.into(),
        });
        let mut calls = 0;
        while !effects.is_empty() {
            calls += 1;
            if calls > 100 {
                return Err("unbounded effects".into());
            }
            let Effect::Io(mut request) = effects.remove(0);
            let response = match self.handle(request.operation.clone()) {
                Ok(value) => ShellResponse {
                    value: Some(value),
                    error: None,
                },
                Err(error) => ShellResponse {
                    value: None,
                    error: Some(error),
                },
            };
            effects.extend(
                core.resolve(&mut request, response)
                    .map_err(|e| e.to_string())?,
            );
        }
        assert!(!core.view().busy);
        Ok(core)
    }
}
fn shell(asset: StoredAsset, fault: Fault) -> Shell {
    Shell {
        asset,
        fault,
        trace: vec![],
        files: vec![],
        hashes: 0,
        rendered: false,
        edit_reads: 0,
    }
}

#[test]
fn current_image_share_keeps_rendered_bytes_and_finishes_before_cleanup_without_mutation()
-> Result<(), String> {
    for fault in [Fault::None, Fault::WebP, Fault::Cancel, Fault::Cleanup] {
        let mut shell = shell(apple(), fault);
        let before = serde_json::to_value(state(shell.asset.clone())).map_err(|e| e.to_string())?;
        let core = shell.run(false)?;
        assert_eq!(
            shell.trace,
            [
                "workspace",
                "current-image",
                "hash",
                "copy",
                "hash",
                "share",
                "cleanup"
            ]
        );
        assert_eq!(
            shell.files,
            [if matches!(fault, Fault::WebP) {
                "original-current.webp"
            } else {
                "original-current.png"
            }]
        );
        assert_eq!(
            before,
            serde_json::to_value(core.view().state).map_err(|e| e.to_string())?
        );
        assert_eq!(core.view().error.is_some(), matches!(fault, Fault::Cleanup));
    }
    Ok(())
}
#[test]
fn invalid_current_exports_never_reach_native_sharing() -> Result<(), String> {
    for fault in [
        Fault::Revision,
        Fault::Escape,
        Fault::Format,
        Fault::MultipleFrames,
        Fault::Empty,
        Fault::CopyChanged,
        Fault::ExportLost,
    ] {
        let mut shell = shell(apple(), fault);
        let core = shell.run(false)?;
        assert!(core.view().error.is_some());
        assert!(!shell.trace.contains(&"share".into()));
        assert_eq!(shell.trace.last().map(String::as_str), Some("cleanup"));
    }
    Ok(())
}
#[test]
fn current_export_rejects_foreign_ambiguous_and_nonstill_sources_before_io() {
    let original = apple();
    for variant in 0..5 {
        let mut saved = state(original.clone());
        match variant {
            0 => saved.snapshots[0].scope = "foreign".into(),
            1 => saved.snapshots.push(saved.snapshots[0].clone()),
            2 => saved.snapshots[0].assets.push(original.clone()),
            3 => saved.snapshots[0].access = ScanAccess::Unavailable,
            _ => saved.snapshots[0].assets[0].resources[0].role = ResourceRole::Video,
        }
        assert!(current_image_asset(&saved.snapshots, "apple", None, &original.key).is_err());
    }
    let mut limited = original.clone();
    limited.inventory_complete = false;
    limited.resources[0].sha1 = None;
    assert!(current_image_asset(&state(limited).snapshots, "apple", None, &original.key).is_ok());
}
#[test]
fn edited_remote_sharing_renders_the_latest_series_without_reading_cached_fullsize_files()
-> Result<(), String> {
    let remote: Asset = serde_json::from_value(native_remote()).map_err(|e| e.to_string())?;
    let mut shell = shell(remote.record("remote", None, None), Fault::None);
    let core = shell.run(true)?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(!shell.trace.iter().any(|r| r.contains("asset-files")));
    assert!(
        shell
            .trace
            .iter()
            .any(|r| r.contains("/original?edited=false"))
    );
    assert!(!shell.trace.iter().any(|r| r.contains("thumbnail")));
    assert!(shell.trace.contains(&"render".into()));
    assert_eq!(shell.edit_reads, 2);
    assert_eq!(shell.files, ["original-current.png"]);
    assert!(shell.trace.contains(&"share".into()));
    assert_eq!(
        serde_json::to_value(core.view().state).map_err(|e| e.to_string())?,
        serde_json::to_value(state(shell.asset.clone())).map_err(|e| e.to_string())?
    );
    Ok(())
}

#[test]
fn changed_unsupported_unrenderable_or_inconsistent_edits_never_reach_sharing() -> Result<(), String>
{
    for fault in [
        Fault::ChangedEdits,
        Fault::UnsupportedEdits,
        Fault::WrongRender,
        Fault::WrongMetadata,
        Fault::OversizedRender,
        Fault::HdrRender,
    ] {
        let remote: Asset = serde_json::from_value(native_remote()).map_err(|e| e.to_string())?;
        let mut shell = shell(remote.record("remote", None, None), fault);
        let core = shell.run(true)?;
        assert!(core.view().error.is_some());
        assert!(!shell.trace.contains(&"share".into()));
        assert!(!shell.trace.iter().any(|r| r.contains("asset-files")));
        assert_eq!(shell.trace.last().map(String::as_str), Some("cleanup"));
    }
    Ok(())
}
#[test]
fn unedited_remote_current_sharing_explicitly_reads_the_original() -> Result<(), String> {
    let mut native = native_remote();
    native["isEdited"] = json!(false);
    let remote: Asset = serde_json::from_value(native).map_err(|e| e.to_string())?;
    for fault in [Fault::Unedited, Fault::WrongOriginal] {
        let mut shell = shell(remote.record("remote", None, None), fault);
        let core = shell.run(true)?;
        assert_eq!(
            core.view().error.is_none(),
            matches!(fault, Fault::Unedited)
        );
        assert!(shell.trace.contains(&format!(
            "GET https://photos.example/api/assets/{ID}/original?edited=false"
        )));
        assert!(!shell.trace.iter().any(|r| r.contains("asset-files")));
        assert_eq!(
            shell.trace.contains(&"share".into()),
            matches!(fault, Fault::Unedited)
        );
    }
    Ok(())
}

#[test]
fn unknown_remote_edit_state_never_falls_back_to_originals() -> Result<(), String> {
    let remote: Asset = serde_json::from_value(native_remote()).map_err(|e| e.to_string())?;
    let mut shell = shell(remote.record("remote", None, None), Fault::UnknownEdited);
    let core = shell.run(true)?;
    assert!(core.view().error.is_some());
    assert!(!shell.trace.contains(&"share".into()));
    assert!(!shell.trace.iter().any(|r| r.contains("/original")));
    Ok(())
}
