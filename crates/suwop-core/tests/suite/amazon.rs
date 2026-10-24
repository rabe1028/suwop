use crux_core::Core;
use serde_json::{Value, json};
use suwop_core::{
    amazon::{Connection, Node, UploadRecord, admit_url, formats},
    app::{Effect, Event, Model, SavedLibrary, ShellOperation, ShellResponse, Suwop},
    domain::{
        AppleVisibility, AssetKey, FileSignature, LibrarySnapshot, Presence, Provider,
        ResourceRole, ScanAccess, StoredAsset, TransferBundle, TransferFile, TransferIntent,
        TransferPhase, TransferReceipt,
    },
    protection::PersistentProtectedEntry,
};

const SHA1: &str = "a9993e364706816aba3e25717850c26c9cd0d89d";
const SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const MD5: &str = "900150983cd24fb0d6963f7d28e17f72";

fn connection() -> Result<Connection, String> {
    let mut connection = Connection::provisional("credential")?;
    connection.owner_id = "owner".into();
    connection.scope = "amazon.co.jp|owner".into();
    connection.root_id = "root".into();
    Ok(connection)
}
fn node(favorite: bool) -> Value {
    json!({"id":"photo","name":"photo.jpg","ownerId":"owner","modifiedDate":"2026-10-23T00:00:00Z",
        "status":"AVAILABLE","contentProperties":{"size":3,"md5":MD5,"contentType":"image/jpeg"},
        "settings":{"favorite":favorite}})
}
fn source(name: &str) -> Result<StoredAsset, String> {
    let mut asset = serde_json::from_value::<Node>(node(false))
        .map_err(|e| e.to_string())?
        .record(&connection()?);
    asset.key = AssetKey {
        provider: Provider::Apple,
        scope: "apple".into(),
        asset_id: "source".into(),
    };
    asset.name = name.into();
    asset.apple_visibility = AppleVisibility::Visible;
    asset.deletion_blockers.clear();
    asset.resources[0].name = name.into();
    asset.resources[0].sha1 = Some(SHA1.into());
    Ok(asset)
}
fn state(name: &str) -> Result<SavedLibrary, String> {
    let asset = source(name)?;
    Ok(SavedLibrary {
        schema_version: 9,
        apple_scope: "apple".into(),
        amazon_connection: Some(connection()?),
        snapshots: vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: vec![asset],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        }],
        ..SavedLibrary::default()
    })
}
fn core_from(state: SavedLibrary) -> Core<Suwop> {
    Core::new_with(
        Suwop,
        Model {
            state,
            ready: true,
            ..Model::default()
        },
    )
}
fn core(name: &str) -> Result<Core<Suwop>, String> {
    Ok(core_from(state(name)?))
}
/// A fully indexed (empty) Immich library, so only Amazon can prevent an
/// Apple-only presence claim.
fn with_indexed_immich(mut state: SavedLibrary) -> SavedLibrary {
    state.snapshots.push(LibrarySnapshot {
        provider: Provider::Immich,
        scope: "remote".into(),
        assets: vec![],
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    state
}
fn amazon_key() -> Result<AssetKey, String> {
    Ok(AssetKey {
        provider: Provider::Amazon,
        scope: connection()?.scope,
        asset_id: "photo".into(),
    })
}
fn amazon_snapshot(core: &Core<Suwop>) -> Option<LibrarySnapshot> {
    core.view()
        .state
        .snapshots
        .into_iter()
        .find(|s| s.provider == Provider::Amazon)
}
fn refresh_event() -> Event {
    Event::Refresh {
        permission: false,
        now: 2.0,
    }
}
fn resolve_event() -> Event {
    Event::ResolveAmazonUploads {
        id: "reconcile".into(),
    }
}
/// A durable fence from an upload whose response was lost before this run.
fn fenced_core(
    apple: Option<StoredAsset>,
    protect_destination: bool,
) -> Result<Core<Suwop>, String> {
    let mut state = state("photo.jpg")?;
    state.snapshots[0].assets = apple.into_iter().collect();
    let signature = FileSignature {
        sha256: SHA256.into(),
        bytes: 3,
    };
    state.receipts.push(TransferReceipt {
        id: "copy".into(),
        created_at: 1.0,
        phase: TransferPhase::Copying,
        intent: TransferIntent::Copy,
        source: vec![source("photo.jpg")?],
        destination: vec![],
        destination_provider: Provider::Amazon,
        destination_scope: connection()?.scope,
        signatures: [signature.clone()].into(),
    });
    state.amazon_uploads.push(UploadRecord {
        receipt_id: "copy".into(),
        scope: connection()?.scope,
        name: "photo.jpg".into(),
        signature,
        md5: MD5.into(),
        node_id: None,
        verified: false,
    });
    if protect_destination {
        state.protected_entries.push(PersistentProtectedEntry {
            id: "entry".into(),
            key: amazon_key()?,
        });
    }
    Ok(core_from(state))
}

#[derive(Default, PartialEq, Eq)]
enum Fault {
    #[default]
    None,
    LostUpload,
    CorruptOriginal,
    CorruptSha256,
    Endpoint,
    Journal,
    /// The native adapter proves the upload task never resumed.
    Unsent,
    /// The upload task resumed and the server answered with this status.
    Status(u16),
    /// The upload task resumed, but the native evidence is inconsistent.
    MalformedSubmission,
    /// HTTP 415, then saving the released record fails.
    ReleaseJournal,
    Connect,
    Persist,
    Search,
    /// The upload succeeds, but every later metadata read of it fails.
    NodeRead,
    /// The upload succeeds with an ID that is not a valid Amazon node ID.
    InvalidId,
    /// Search reports a library beyond the unofficial listing cap.
    HugeLibrary,
}

#[derive(Default)]
struct Shell {
    saved: Option<SavedLibrary>,
    /// Upload effects observed, including those never handed to the network.
    attempts: usize,
    /// Upload tasks that actually resumed.
    posts: usize,
    patches: usize,
    favorite: bool,
    removed: Vec<String>,
    fault: Fault,
    /// Apple Photos inventory returned by a scan.
    apple: Vec<StoredAsset>,
    apple_exports: usize,
    searches: usize,
    downloads: usize,
    /// Method of every Amazon HTTP effect.
    methods: Vec<String>,
    /// Bump the access generation (a connection event) while a search is in flight.
    interrupt_search: bool,
    /// Whether the published view already held Amazon assets at each persist.
    amazon_visible_at_persist: Vec<bool>,
}
impl Shell {
    fn upload(&mut self, request: &suwop_core::amazon::Request) -> Result<Value, String> {
        self.attempts += 1;
        let saved = self.saved.as_ref().ok_or("missing saved journal")?;
        assert!(saved.amazon_uploads.iter().any(|r| !r.verified));
        assert!(
            saved
                .receipts
                .iter()
                .any(|r| r.phase == TransferPhase::Copying)
        );
        let url = url::Url::parse(&request.http.url).map_err(|e| e.to_string())?;
        assert_eq!(request.http.method, "POST");
        assert_eq!(url.host_str(), Some("upload-photos.amazon.co.jp"));
        assert_eq!(request.http.files.len(), 1);
        if self.fault == Fault::Unsent {
            return Ok(json!({"submitted":false,"failure":"permit refused"}));
        }
        self.posts += 1;
        match self.fault {
            Fault::LostUpload => Err("upload response lost".into()),
            Fault::Status(status) => {
                Ok(json!({"submitted":true,"response":{"status":status,"body":null}}))
            }
            Fault::ReleaseJournal => {
                Ok(json!({"submitted":true,"response":{"status":415,"body":null}}))
            }
            Fault::MalformedSubmission => Ok(json!({"submitted":true})),
            Fault::InvalidId => {
                Ok(json!({"submitted":true,"response":{"status":201,"body":{"id":"../photo"}}}))
            }
            _ => Ok(json!({"submitted":true,"response":{"status":201,"body":{"id":"photo"}}})),
        }
    }

    fn handle(&mut self, operation: ShellOperation) -> Result<Value, String> {
        match operation {
            ShellOperation::Persist(state) => {
                let fail = match self.fault {
                    Fault::Journal => !state.amazon_uploads.is_empty(),
                    Fault::ReleaseJournal => self.posts > 0 && state.amazon_uploads.is_empty(),
                    Fault::Persist => true,
                    _ => false,
                };
                if fail {
                    return Err("journal unavailable".into());
                }
                self.saved = Some(state);
                Ok(Value::Null)
            }
            ShellOperation::Workspace { .. } => Ok(json!("/test/work")),
            ShellOperation::Cleanup { .. } => Ok(Value::Null),
            ShellOperation::RemoveAmazonCredential { account } => {
                self.removed.push(account);
                Ok(Value::Null)
            }
            ShellOperation::AmazonUpload { request } => self.upload(&request),
            ShellOperation::AppleScan { scope, .. } => serde_json::to_value(LibrarySnapshot {
                provider: Provider::Apple,
                scope,
                assets: self.apple.clone(),
                access: ScanAccess::Full,
                scanned_at: Some(2.0),
            })
            .map_err(|e| e.to_string()),
            ShellOperation::AppleExport { .. } => {
                self.apple_exports += 1;
                let asset = source("photo.jpg")?;
                serde_json::to_value(TransferBundle {
                    files: vec![TransferFile {
                        resource: asset.resources[0].clone(),
                        path: "/test/source".into(),
                        signature: FileSignature {
                            sha256: SHA256.into(),
                            bytes: 3,
                        },
                    }],
                    assets: vec![asset],
                })
                .map_err(|e| e.to_string())
            }
            ShellOperation::AmazonHashFile { .. } => Ok(
                json!({"sha1":SHA1,"md5":if self.fault == Fault::CorruptOriginal {"00000000000000000000000000000000"}else{MD5},"signature":{"sha256": if self.fault == Fault::CorruptSha256 && self.posts > 0 { "0000000000000000000000000000000000000000000000000000000000000000" } else { SHA256 },"bytes":3}}),
            ),
            ShellOperation::AmazonHttp { request } => {
                let url = url::Url::parse(&request.http.url).map_err(|e| e.to_string())?;
                // Uploads must use the typed AmazonUpload effect.
                assert_ne!(request.http.method, "POST");
                self.methods.push(request.http.method.clone());
                match url.path() {
                    "/drive/v1/search" => self.searches += 1,
                    "/drive/v1/nodes/photo/contentRedirection" => self.downloads += 1,
                    _ => {}
                }
                let failing = match self.fault {
                    Fault::Connect => (url.path() == "/drive/v1/nodes").then_some(401),
                    Fault::Search => (url.path() == "/drive/v1/search").then_some(401),
                    Fault::NodeRead => {
                        (self.posts > 0 && url.path() == "/drive/v1/nodes/photo").then_some(503)
                    }
                    _ => None,
                };
                if let Some(status) = failing {
                    return Ok(json!({"status":status,"body":null}));
                }
                if request.http.method == "PATCH" {
                    self.patches += 1;
                    self.favorite = request
                        .http
                        .body
                        .as_ref()
                        .and_then(|body| body["settings"]["favorite"].as_bool())
                        .ok_or("missing favorite")?;
                    return Ok(json!({"status":200,"body":node(self.favorite)}));
                }
                let body = match url.path() {
                    "/drive/v1/account/endpoint" => {
                        json!({"uploadServiceUrl":if self.fault == Fault::Endpoint {"https://upload-photos.amazon.co.jp.evil.test/"} else {"https://upload-photos.amazon.co.jp/"}})
                    }
                    "/drive/v1/nodes" => json!({"data":[{"ownerId":"owner","id":"root"}]}),
                    "/drive/v1/search" => json!({
                        "count": if self.fault == Fault::HugeLibrary { 20_000 } else { 1 },
                        "data": [node(self.favorite)],
                    }),
                    "/drive/v1/nodes/photo" => node(self.favorite),
                    "/drive/v1/nodes/photo/contentRedirection" => Value::Null,
                    _ => return Err("unexpected Amazon route".into()),
                };
                Ok(json!({"status":200,"body":body,"path":request.http.download_path}))
            }
            _ => Err("unexpected native effect".into()),
        }
    }
    fn run(&mut self, core: &Core<Suwop>, event: Event) -> Result<(), String> {
        let mut effects = core.process_event(event);
        let mut count = 0;
        while !effects.is_empty() {
            count += 1;
            if count > 100 {
                return Err("effect loop".into());
            }
            let Effect::Io(mut request) = effects.remove(0);
            match &request.operation {
                ShellOperation::Persist(_) => self
                    .amazon_visible_at_persist
                    .push(amazon_snapshot(core).is_some_and(|s| !s.assets.is_empty())),
                ShellOperation::AmazonHttp { request }
                    if self.interrupt_search && request.http.url.contains("/drive/v1/search") =>
                {
                    self.interrupt_search = false;
                    // Ignored while busy, but it still invalidates the running workflow.
                    effects.extend(core.process_event(Event::DisconnectAmazon));
                }
                _ => {}
            }
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
        Ok(())
    }
}
fn copy_event() -> Result<Event, String> {
    copy_event_id("copy")
}
fn copy_event_id(id: &str) -> Result<Event, String> {
    Ok(Event::CopyTo {
        keys: vec![source("photo.jpg")?.key],
        destination: Provider::Amazon,
        intent: TransferIntent::Copy,
        id: id.into(),
        now: 1.0,
    })
}
fn configure_event(credential_id: &str) -> Event {
    Event::ConfigureAmazon {
        credential_id: credential_id.into(),
        now: 2.0,
    }
}
fn saved_credential(shell: &Shell) -> Option<&str> {
    shell
        .saved
        .as_ref()
        .and_then(|s| s.amazon_connection.as_ref())
        .map(|c| c.credential_id.as_str())
}

#[test]
fn restricted_protected_and_trashed_nodes_cannot_authorize_ordinary_reads() -> Result<(), String> {
    for (field, value) in [
        ("restricted", json!(true)),
        ("protectedFolder", json!(true)),
        ("status", json!("TRASH")),
    ] {
        let mut raw = node(false);
        raw[field] = value;
        let observed: Node = serde_json::from_value(raw).map_err(|error| error.to_string())?;
        assert!(observed.validate(&connection()?).is_err());
    }
    Ok(())
}

#[test]
fn an_unindexed_amazon_library_never_makes_an_apple_only_claim() -> Result<(), String> {
    let remote = serde_json::from_value::<Node>(node(false))
        .map_err(|error| error.to_string())?
        .record(&connection()?);
    let mut snapshots = vec![
        LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: vec![source("photo.jpg")?],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        },
        LibrarySnapshot {
            provider: Provider::Immich,
            scope: "remote".into(),
            assets: vec![],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        },
        LibrarySnapshot {
            provider: Provider::Amazon,
            scope: connection()?.scope,
            assets: vec![remote],
            access: ScanAccess::Full,
            scanned_at: Some(1.0),
        },
    ];
    let photos = suwop_core::domain::catalog(&snapshots, &[]);
    assert!(
        photos
            .iter()
            .all(|p| p.presence != suwop_core::domain::Presence::AppleOnly)
    );
    snapshots[2].access = ScanAccess::Unavailable;
    assert!(
        suwop_core::domain::catalog(&snapshots, &[])
            .iter()
            .all(|p| p.presence == suwop_core::domain::Presence::Unverified)
    );
    Ok(())
}

#[test]
fn japan_endpoints_restrict_methods_and_do_not_authorize_cdn_cookies() -> Result<(), String> {
    assert!(admit_url(
        "https://www.amazon.co.jp/drive/v1/search",
        "GET"
    )?);
    assert!(admit_url(
        "https://upload-photos.amazon.co.jp/v2/upload",
        "POST"
    )?);
    assert!(!admit_url(
        "https://a.cloudfront.net/content?signature=secret",
        "GET"
    )?);
    for url in [
        "http://www.amazon.co.jp/drive/v1/search",
        "https://www.amazon.com/drive/v1/search",
        "https://www.amazon.co.jp.evil.test/drive/v1/search",
        "https://user@www.amazon.co.jp/drive/v1/search",
    ] {
        assert!(admit_url(url, "GET").is_err());
    }
    assert!(admit_url("https://www.amazon.co.jp/drive/v1/nodes/photo", "DELETE").is_err());
    assert!(admit_url("https://content-fe.drive.amazonaws.com/v2/upload", "POST").is_err());
    Ok(())
}

#[test]
fn upload_target_requires_the_account_advertised_japan_service() -> Result<(), String> {
    for raw in [
        "https://upload-photos.amazon.co.jp/",
        "https://upload-photos.amazon.co.jp/v2/upload",
    ] {
        let url = suwop_core::amazon::upload_target(&json!({"uploadServiceUrl":raw}))?;
        assert_eq!(url.as_str(), "https://upload-photos.amazon.co.jp/v2/upload");
    }
    assert!(
        suwop_core::amazon::upload_target(
            &json!({"contentUrl":"https://content-jp.drive.amazonaws.com/"})
        )
        .is_err()
    );
    for raw in [
        "http://upload-photos.amazon.co.jp/",
        "https://upload-photos.amazon.co.jp.evil.test/",
        "https://content-fe.drive.amazonaws.com/",
        "https://content-jp.drive.amazonaws.com/",
        "https://upload-photos.amazon.co.jp:444/",
        "https://user@upload-photos.amazon.co.jp/",
        "https://upload-photos.amazon.co.jp/?token=secret",
        "https://upload-photos.amazon.co.jp/#fragment",
        "https://upload-photos.amazon.co.jp/unknown",
    ] {
        assert!(suwop_core::amazon::upload_target(&json!({"uploadServiceUrl":raw})).is_err());
    }
    Ok(())
}

#[test]
fn unexpected_upload_service_stops_before_intent_or_post() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::Endpoint,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 0);
    assert!(core.view().state.amazon_uploads.is_empty());
    assert!(
        core.view()
            .error
            .as_deref()
            .is_some_and(|e| e.contains("アップロード先"))
    );
    Ok(())
}

#[test]
fn unsupported_formats_and_names_preserve_originals() -> Result<(), String> {
    for name in [
        "photo.xmp",
        "photo.pdf",
        "photo.svg",
        "photo.txt",
        "CON.jpg",
        "bad?.jpg",
        "photo.jpg ",
    ] {
        let resource = source(name)?.resources.remove(0);
        let error = formats::check_resource(&resource)
            .err()
            .ok_or("expected unsupported file")?;
        assert!(error.contains("Apple PhotosまたはImmich"));
        assert!(error.contains("原本は残します"));
    }
    for name in ["photo.jpg", "photo.heic", "photo.dng", "photo.cr3"] {
        formats::check_resource(&source(name)?.resources[0])?;
    }
    let mut live = source("motion.mov")?.resources.remove(0);
    live.role = ResourceRole::LiveVideo;
    assert!(formats::check_resource(&live).is_err());
    Ok(())
}

#[test]
fn unsupported_original_stops_before_any_upload() -> Result<(), String> {
    let core = core("photo.xmp")?;
    let mut shell = Shell::default();
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 0);
    assert!(
        core.view()
            .error
            .is_some_and(|e| e.contains("保存できません"))
    );
    Ok(())
}

#[test]
fn uploaded_original_requires_saved_journal_and_round_trip_sha256() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell::default();
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    let state = shell.saved.ok_or("missing saved state")?;
    assert!(state.amazon_uploads[0].verified);
    assert_eq!(state.receipts[0].phase, TransferPhase::Copied);
    assert_eq!(state.receipts[0].destination_provider, Provider::Amazon);
    Ok(())
}

#[test]
fn failed_journal_prevents_remote_write() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::Journal,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.attempts, 0);
    assert!(core.view().error.is_some());
    // The unsaved intent is not kept in memory, so it cannot become a phantom fence.
    assert!(core.view().state.amazon_uploads.is_empty());
    shell.fault = Fault::None;
    shell.run(&core, copy_event_id("next")?)?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    Ok(())
}

#[test]
fn explicit_rejection_releases_only_its_fence_and_the_next_copy_can_upload() -> Result<(), String> {
    for status in [400, 413, 415] {
        let core = core("photo.jpg")?;
        let mut shell = Shell {
            fault: Fault::Status(status),
            ..Shell::default()
        };
        shell.run(&core, copy_event()?)?;
        assert_eq!(shell.posts, 1);
        assert!(
            core.view()
                .error
                .is_some_and(|e| e.contains("Apple PhotosまたはImmich"))
        );
        let saved = shell.saved.as_ref().ok_or("missing saved state")?;
        assert!(saved.amazon_uploads.is_empty());
        assert!(
            saved
                .receipts
                .iter()
                .all(|r| r.phase != TransferPhase::Copied)
        );
        shell.fault = Fault::None;
        shell.run(&core, copy_event_id("next")?)?;
        assert_eq!(shell.posts, 2);
        assert!(core.view().error.is_none(), "{:?}", core.view().error);
        let saved = shell.saved.as_ref().ok_or("missing saved state")?;
        assert_eq!(saved.amazon_uploads.len(), 1);
        assert!(saved.amazon_uploads[0].verified);
    }
    Ok(())
}

#[test]
fn refused_native_submission_is_not_a_post_and_leaves_no_fence() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::Unsent,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!((shell.attempts, shell.posts), (1, 0));
    assert!(core.view().error.is_some_and(|e| e.contains("送信する前")));
    let saved = shell.saved.as_ref().ok_or("missing saved state")?;
    assert!(saved.amazon_uploads.is_empty());
    shell.fault = Fault::None;
    shell.run(&core, copy_event_id("next")?)?;
    assert_eq!((shell.attempts, shell.posts), (2, 1));
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    Ok(())
}

#[test]
fn outcomes_after_submission_remain_fenced_and_are_never_resent() -> Result<(), String> {
    for fault in [
        Fault::LostUpload,
        Fault::Status(500),
        Fault::Status(409),
        Fault::Status(429),
        Fault::Status(201),
        Fault::MalformedSubmission,
    ] {
        let core = core("photo.jpg")?;
        let mut shell = Shell {
            fault,
            ..Shell::default()
        };
        shell.run(&core, copy_event()?)?;
        assert_eq!(shell.posts, 1);
        assert!(core.view().error.is_some());
        assert!(
            shell
                .saved
                .as_ref()
                .is_some_and(|s| s.amazon_uploads.len() == 1 && !s.amazon_uploads[0].verified)
        );
        shell.fault = Fault::None;
        shell.run(&core, copy_event_id("next")?)?;
        assert_eq!((shell.attempts, shell.posts), (1, 1));
        assert!(core.view().error.is_some_and(|e| e.contains("未確定")));
    }
    Ok(())
}

#[test]
fn unsaved_release_of_a_rejected_upload_keeps_the_fence() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::ReleaseJournal,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(
        core.view()
            .error
            .is_some_and(|e| e.contains("journal unavailable"))
    );
    // Memory matches the durable journal, which still holds the pre-POST record.
    assert_eq!(core.view().state.amazon_uploads.len(), 1);
    assert!(
        shell
            .saved
            .as_ref()
            .is_some_and(|s| s.amazon_uploads.iter().any(|r| !r.verified))
    );
    shell.fault = Fault::None;
    shell.run(&core, copy_event_id("next")?)?;
    assert_eq!((shell.attempts, shell.posts), (1, 1));
    assert!(core.view().error.is_some_and(|e| e.contains("未確定")));
    Ok(())
}

#[test]
fn failed_new_connection_removes_only_its_provisional_credential() -> Result<(), String> {
    for fault in [Fault::Connect, Fault::Persist] {
        let core = core("photo.jpg")?;
        let mut shell = Shell {
            fault,
            ..Shell::default()
        };
        shell.run(&core, configure_event("fresh"))?;
        assert!(core.view().error.is_some());
        assert_eq!(shell.removed, ["fresh"]);
        assert_eq!(
            core.view()
                .state
                .amazon_connection
                .map(|c| c.credential_id)
                .as_deref(),
            Some("credential")
        );
    }
    Ok(())
}

#[test]
fn failed_reconnection_never_removes_the_current_credential() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::Connect,
        ..Shell::default()
    };
    shell.run(&core, configure_event("credential"))?;
    assert!(core.view().error.is_some());
    assert!(shell.removed.is_empty());
    Ok(())
}

#[test]
fn refresh_failure_after_adoption_keeps_the_new_credential() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::Search,
        ..Shell::default()
    };
    shell.run(&core, configure_event("fresh"))?;
    assert!(core.view().error.is_some());
    // Only the replaced connection's credential is removed.
    assert_eq!(shell.removed, ["credential"]);
    assert_eq!(saved_credential(&shell), Some("fresh"));
    Ok(())
}

#[test]
fn lost_upload_response_is_persisted_and_never_retried_automatically() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::LostUpload,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_some_and(|e| e.contains("未確定")));
    assert!(
        shell
            .saved
            .as_ref()
            .is_some_and(|s| s.amazon_uploads.iter().any(|r| !r.verified))
    );
    Ok(())
}

#[test]
fn lost_response_is_reconciled_by_reading_original_without_resending() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::LostUpload,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    shell.fault = Fault::None;
    shell.run(
        &core,
        Event::ResolveAmazonUploads {
            id: "reconcile".into(),
        },
    )?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    // Reconciliation proves byte availability only; it never completes the copy.
    assert!(shell.saved.as_ref().is_some_and(
        |s| s.amazon_uploads[0].verified && s.receipts[0].phase == TransferPhase::Copying
    ));
    Ok(())
}

#[test]
fn verified_amazon_fingerprint_survives_a_catalog_refresh() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell::default();
    shell.run(&core, copy_event()?)?;
    shell.run(
        &core,
        Event::ConfigureAmazon {
            credential_id: "credential".into(),
            now: 2.0,
        },
    )?;
    let snapshot = core
        .view()
        .state
        .snapshots
        .into_iter()
        .find(|s| s.provider == Provider::Amazon)
        .ok_or("snapshot")?;
    assert_eq!(snapshot.assets[0].resources[0].sha1.as_deref(), Some(SHA1));
    Ok(())
}

#[test]
fn corrupt_remote_original_never_completes_copy() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::CorruptOriginal,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert!(core.view().error.is_some());
    assert!(
        shell
            .saved
            .as_ref()
            .is_some_and(|s| s.receipts.iter().all(|r| r.phase != TransferPhase::Copied))
    );
    Ok(())
}

#[test]
fn mismatched_readback_sha256_never_completes_an_amazon_copy() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::CorruptSha256,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(
        core.view()
            .error
            .is_some_and(|error| error.contains("SHA-256"))
    );
    assert!(
        shell
            .saved
            .as_ref()
            .is_some_and(|state| !state.amazon_uploads[0].verified
                && state.receipts[0].phase == TransferPhase::Copying)
    );
    Ok(())
}

#[test]
fn connection_lists_amazon_assets_and_selects_a_preview() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell::default();
    shell.run(
        &core,
        Event::ConfigureAmazon {
            credential_id: "credential".into(),
            now: 1.0,
        },
    )?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(
        core.view()
            .photos
            .iter()
            .any(|p| p.assets.iter().any(|a| a.key.provider == Provider::Amazon))
    );
    assert!(
        core.view()
            .preview_sources
            .values()
            .any(|key| key.provider == Provider::Amazon)
    );
    Ok(())
}

#[test]
fn favorite_updates_are_read_back_from_amazon() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell::default();
    shell.run(
        &core,
        Event::ConfigureAmazon {
            credential_id: "credential".into(),
            now: 1.0,
        },
    )?;
    let key = AssetKey {
        provider: Provider::Amazon,
        scope: connection()?.scope,
        asset_id: "photo".into(),
    };
    shell.run(
        &core,
        Event::SetFavorite {
            keys: vec![key],
            value: true,
        },
    )?;
    assert_eq!(shell.patches, 1);
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert!(
        core.view()
            .photos
            .iter()
            .flat_map(|p| &p.assets)
            .any(|a| a.key.provider == Provider::Amazon && a.is_favorite)
    );
    Ok(())
}

#[test]
fn refresh_publishes_the_amazon_catalog_only_with_its_final_result() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        apple: vec![source("photo.jpg")?],
        ..Shell::default()
    };
    shell.run(&core, refresh_event())?;
    assert_eq!(shell.searches, 1);
    // The refresh's own durable save happens before admission; no Amazon page
    // was published as working state ahead of it.
    assert_eq!(shell.amazon_visible_at_persist.first(), Some(&false));
    let snapshot = amazon_snapshot(&core).ok_or("missing admitted Amazon catalog")?;
    assert_eq!(snapshot.access, ScanAccess::Full);
    assert_eq!(snapshot.assets.len(), 1);
    Ok(())
}

#[test]
fn access_change_during_an_amazon_page_publishes_no_refresh_state() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        apple: vec![source("photo.jpg")?],
        interrupt_search: true,
        ..Shell::default()
    };
    shell.run(&core, refresh_event())?;
    assert_eq!(shell.searches, 1);
    assert!(core.view().error.is_some());
    // The stale page is neither saved nor published.
    assert!(
        shell
            .amazon_visible_at_persist
            .iter()
            .all(|visible| !visible)
    );
    assert!(amazon_snapshot(&core).is_none_or(|s| s.assets.is_empty()));
    assert!(shell.saved.as_ref().is_none_or(|s| {
        s.snapshots
            .iter()
            .all(|s| s.provider != Provider::Amazon || s.assets.is_empty())
    }));
    Ok(())
}

#[test]
fn amazon_assets_are_not_queued_for_semantic_analysis() -> Result<(), String> {
    let mut state = state("photo.jpg")?;
    state.snapshots.push(LibrarySnapshot {
        provider: Provider::Amazon,
        scope: connection()?.scope,
        assets: vec![
            serde_json::from_value::<Node>(node(false))
                .map_err(|e| e.to_string())?
                .record(&connection()?),
        ],
        access: ScanAccess::Full,
        scanned_at: Some(1.0),
    });
    let providers: Vec<_> = suwop_core::analysis::visible_assets(&state)
        .map(|a| a.key.provider)
        .collect();
    assert_eq!(providers, [Provider::Apple]);
    Ok(())
}

#[test]
fn returned_upload_id_is_journaled_before_a_failed_readback() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::NodeRead,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_some());
    let saved = shell.saved.as_ref().ok_or("missing saved state")?;
    assert_eq!(saved.amazon_uploads[0].node_id.as_deref(), Some("photo"));
    assert!(!saved.amazon_uploads[0].verified);
    // A library beyond the listing cap: only the journaled ID can resolve it.
    shell.fault = Fault::HugeLibrary;
    shell.run(&core, resolve_event())?;
    assert!(core.view().error.is_none(), "{:?}", core.view().error);
    assert_eq!((shell.posts, shell.searches, shell.downloads), (1, 0, 1));
    let saved = shell.saved.as_ref().ok_or("missing saved state")?;
    assert!(saved.amazon_uploads[0].verified);
    assert_eq!(saved.receipts[0].phase, TransferPhase::Copying);
    Ok(())
}

#[test]
fn invalid_returned_upload_id_keeps_the_ambiguous_fence() -> Result<(), String> {
    let core = core("photo.jpg")?;
    let mut shell = Shell {
        fault: Fault::InvalidId,
        ..Shell::default()
    };
    shell.run(&core, copy_event()?)?;
    assert_eq!(shell.posts, 1);
    assert!(core.view().error.is_some());
    let saved = shell.saved.as_ref().ok_or("missing saved state")?;
    assert!(saved.amazon_uploads[0].node_id.is_none() && !saved.amazon_uploads[0].verified);
    shell.fault = Fault::None;
    shell.run(&core, copy_event_id("next")?)?;
    assert_eq!((shell.attempts, shell.posts), (1, 1));
    assert!(core.view().error.is_some_and(|e| e.contains("未確定")));
    Ok(())
}

#[test]
fn reconciliation_reads_only_the_destination_when_the_source_is_gone() -> Result<(), String> {
    let mut hidden = source("photo.jpg")?;
    hidden.apple_visibility = AppleVisibility::Hidden;
    for apple in [None, Some(hidden)] {
        let core = fenced_core(apple, false)?;
        let mut shell = Shell::default();
        shell.run(&core, resolve_event())?;
        assert!(core.view().error.is_none(), "{:?}", core.view().error);
        // GET-only destination reads: no write, no source export.
        assert_eq!(
            (shell.attempts, shell.patches, shell.apple_exports),
            (0, 0, 0)
        );
        assert!(shell.methods.iter().all(|m| m == "GET"));
        assert_eq!((shell.searches, shell.downloads), (1, 1));
        let saved = shell.saved.as_ref().ok_or("missing saved state")?;
        assert_eq!(saved.amazon_uploads[0].node_id.as_deref(), Some("photo"));
        assert!(saved.amazon_uploads[0].verified);
        // Never completes the copy or creates Move/deletion authority.
        assert_eq!(saved.receipts[0].phase, TransferPhase::Copying);
        assert!(saved.receipts[0].destination.is_empty());
    }
    Ok(())
}

#[test]
fn reconciliation_never_reads_a_protected_destination() -> Result<(), String> {
    let core = fenced_core(Some(source("photo.jpg")?), true)?;
    let mut shell = Shell::default();
    shell.run(&core, resolve_event())?;
    assert!(core.view().error.is_some());
    assert_eq!((shell.searches, shell.downloads), (1, 0));
    assert!(
        shell
            .saved
            .as_ref()
            .is_some_and(|s| !s.amazon_uploads[0].verified)
    );
    Ok(())
}

#[test]
fn adopted_connection_without_an_inventory_is_unavailable_not_absent() -> Result<(), String> {
    let core = core_from(with_indexed_immich(state("photo.jpg")?));
    let mut shell = Shell {
        fault: Fault::Search,
        ..Shell::default()
    };
    shell.run(&core, configure_event("fresh"))?;
    assert!(core.view().error.is_some());
    let scope = connection()?.scope;
    let saved = shell.saved.as_ref().ok_or("missing saved state")?;
    assert!(
        saved
            .snapshots
            .iter()
            .any(|s| s.provider == Provider::Amazon
                && s.scope == scope
                && s.access == ScanAccess::Unavailable)
    );
    for snapshots in [saved.snapshots.clone(), core.view().state.snapshots] {
        assert!(
            suwop_core::domain::catalog(&snapshots, &[])
                .iter()
                .all(|p| p.presence != Presence::AppleOnly)
        );
    }
    Ok(())
}

#[test]
fn connected_library_whose_root_read_fails_never_claims_apple_only() -> Result<(), String> {
    // A connected state persisted before any Amazon inventory existed.
    let core = core_from(with_indexed_immich(state("photo.jpg")?));
    let mut shell = Shell {
        apple: vec![source("photo.jpg")?],
        fault: Fault::Connect,
        ..Shell::default()
    };
    shell.run(&core, refresh_event())?;
    let snapshot = amazon_snapshot(&core).ok_or("missing Amazon placeholder")?;
    assert_eq!(snapshot.access, ScanAccess::Unavailable);
    assert!(
        suwop_core::domain::catalog(&core.view().state.snapshots, &[])
            .iter()
            .all(|p| p.presence != Presence::AppleOnly)
    );
    Ok(())
}
