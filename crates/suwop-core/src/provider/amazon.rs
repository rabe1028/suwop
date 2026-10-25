//! Amazon Photos (Japan). Copies only: there is no deletion, metadata or album
//! ability, and its copies never complete a Move.
use std::collections::BTreeSet;

use super::{
    CatalogListing, CreatedCopies, ExportRequest, FavoriteWrite, ImportRequest, ImportWindow, Io,
    ListRequest, Listing, ListingRange, OriginalExport, OriginalImport, ReadIo, authorize_import,
};
use crate::{
    amazon::{Connection, Hash, Request, UploadOutcome, UploadRecord, UploadRecordPhase, formats},
    app::{Event, ShellOperation, io as shell},
    domain::{
        AssetKey, LibrarySnapshot, Provider, ScanAccess, StoredAsset, TransferBundle, TransferFile,
    },
    transport::{OrdinaryContentAuthorization, OrdinaryContentPurpose, OrdinarySessionGuard},
    workflow::journal::{DurableStage, JournalChange, StageBinding},
};

/// The unofficial listing cap of the search API.
const LISTING_CAP: usize = 9999;

pub(crate) struct AmazonBackend {
    /// Saved settings: no content authorization or access guard of its own.
    connection: Connection,
    revision: String,
    guard: OrdinarySessionGuard,
}

impl AmazonBackend {
    pub(crate) fn new(
        connection: Connection,
        revision: String,
        guard: OrdinarySessionGuard,
    ) -> Self {
        Self {
            connection,
            revision,
            guard,
        }
    }

    /// A connection bound to this operation's access epoch and content purpose.
    pub(crate) fn session(&self, keys: &[AssetKey], purpose: OrdinaryContentPurpose) -> Connection {
        let mut connection = self.connection.clone();
        connection.content_authorization = Some(OrdinaryContentAuthorization {
            source_keys: keys.to_vec(),
            expected_revision: self.revision.clone(),
            purpose,
        });
        connection.ordinary_guard = Some(self.guard.clone());
        connection
    }

    /// Metadata listing only, bound to the access epoch, without content authority.
    pub(crate) fn listing_session(&self) -> Connection {
        let mut connection = self.session(&[], OrdinaryContentPurpose::Read);
        connection.content_authorization = None;
        connection
    }

    fn snapshot(&self, assets: Vec<StoredAsset>, access: ScanAccess, now: f64) -> LibrarySnapshot {
        LibrarySnapshot {
            provider: Provider::Amazon,
            scope: self.connection.scope.clone(),
            assets,
            access,
            scanned_at: Some(now),
        }
    }

    async fn list_all(&self, io: &ReadIo<'_>, now: f64) -> Result<Listing, String> {
        // Catalog reads use the saved connection with explicit epoch checks.
        let connection = &self.connection;
        let mut checked = connection.clone();
        checked.connect(io.ctx()).await?;
        io.check(&[])?;
        if checked.scope != connection.scope {
            return Err(
                "Amazon Photosのアカウントが変わりました。接続設定から確認してください。".into(),
            );
        }
        let mut records = Vec::new();
        let mut seen = BTreeSet::new();
        let mut expected = None;
        loop {
            io.check(&[])?;
            if records.len() >= LISTING_CAP {
                return Ok(Listing {
                    snapshot: self.snapshot(records, ScanAccess::Limited, now),
                    range: ListingRange::WholeLibrary,
                    warning: Some("Amazon Photosは取得可能なページ上限に達しました。取得済み分を表示しています。一覧は未完了です。".into()),
                });
            }
            let (total, nodes) = connection.page(io.ctx(), records.len()).await?;
            // A page read across an access change is never recorded.
            io.check(&[])?;
            if expected.is_some_and(|old| old != total)
                || (nodes.is_empty() && records.len() != total)
            {
                return Err(
                    "取得中にAmazon Photosの一覧が変わりました。未完了として再読込してください。"
                        .into(),
                );
            }
            expected = Some(total);
            for node in nodes {
                if !seen.insert(node.id.clone()) {
                    return Err("Amazon Photosのページが重複しました。一覧は未完了です。".into());
                }
                records.push(node.record(connection));
            }
            if records.len() > total {
                return Err("Amazon Photosの一覧件数が一致しません。".into());
            }
            // Status text only; never the working catalog state.
            io.ctx().send_event(Event::FetchProgress {
                status: format!("Amazon Photosを取得中: {} / {total} 件", records.len()),
            });
            if records.len() == total {
                return Ok(Listing {
                    snapshot: self.snapshot(records, ScanAccess::Full, now),
                    range: ListingRange::WholeLibrary,
                    warning: None,
                });
            }
        }
    }

    async fn export_originals(
        &self,
        io: &ReadIo<'_>,
        request: ExportRequest<'_>,
    ) -> Result<TransferBundle, String> {
        let connection = self.session(request.keys, request.purpose);
        let mut bundle = TransferBundle {
            assets: vec![],
            files: vec![],
        };
        for (index, key) in request.keys.iter().enumerate() {
            if key.provider != Provider::Amazon || key.scope != connection.scope {
                return Err("Amazon Photosのアカウントが一致しません。".into());
            }
            let node = connection.node(io.ctx(), &key.asset_id).await?;
            let path = format!("{}/{index}-original", request.directory);
            let hash = connection.download(io.ctx(), &node, &path).await?;
            let mut record = node.record(&connection);
            let resource = record
                .resources
                .first_mut()
                .ok_or("Amazon Photosの原本がありません。")?;
            resource.sha1 = Some(hash.sha1);
            bundle.files.push(TransferFile {
                resource: resource.clone(),
                path,
                signature: hash.signature,
            });
            bundle.assets.push(record);
        }
        Ok(bundle)
    }

    /// Submit exactly once, only under the saved stage of this record and
    /// while the sources' access epochs are unchanged.
    async fn submit(
        connection: &Connection,
        io: &ReadIo<'_>,
        stage: DurableStage,
        (record, sources): (&UploadRecord, &[AssetKey]),
        request: Request,
    ) -> Result<UploadOutcome, String> {
        stage.authorize(&StageBinding::AmazonUpload(record.clone()))?;
        if let Err(error) = io.check(sources) {
            return Ok(UploadOutcome::Refused(error));
        }
        connection.submit_upload(io.ctx(), request).await
    }

    async fn upload_one(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        connection: &Connection,
        (index, file, record, sources): (usize, &TransferFile, UploadRecord, &[AssetKey]),
        request: Request,
    ) -> Result<AssetKey, String> {
        let stage = window
            .stage(JournalChange::AmazonUpload(record.clone()))
            .await?;
        // Never retried. Only definite non-storage releases this attempt's fence.
        let response =
            match Self::submit(connection, io, stage, (&record, sources), request).await? {
                UploadOutcome::Accepted(response) => response,
                UploadOutcome::Refused(reason) => {
                    return Err(
                        match window.stage(JournalChange::AmazonRelease(record)).await {
                            Ok(_) => reason,
                            Err(error) => format!("{reason}\n{error}"),
                        },
                    );
                }
            };
        let id = response.body["id"]
            .as_str()
            .ok_or("Amazon Photosのアップロード結果が不明です。再送せず一覧を確認してください。")?;
        // The returned ID is this POST's only attribution. Journal it before
        // any read, so a failed readback never forces a listing search. An
        // invalid ID leaves the attempt's fence ambiguous.
        crate::amazon::valid_id(id)?;
        window
            .stage(JournalChange::AmazonCreated {
                record: record.clone(),
                node_id: id.to_owned(),
            })
            .await?;
        let created = UploadRecord {
            node_id: Some(id.to_owned()),
            ..record
        };
        let node = connection.node(io.ctx(), id).await?;
        node.validate(connection)?;
        let path = format!("{}/amazon-{index}", window.work_directory("readback")?);
        let readback = connection.download(io.ctx(), &node, &path).await?;
        if readback.signature != file.signature {
            return Err(
                "Amazon Photosに保存された原本のSHA-256が一致しません。元の原本は残します。".into(),
            );
        }
        window.stage(JournalChange::AmazonVerified(created)).await?;
        Ok(AssetKey {
            provider: Provider::Amazon,
            scope: connection.scope.clone(),
            asset_id: node.id,
        })
    }

    async fn import_bundle(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        request: ImportRequest<'_>,
    ) -> Result<CreatedCopies, String> {
        let ImportRequest {
            receipt,
            stage,
            bundle,
            now: _,
        } = request;
        if receipt.destination_scope != self.connection.scope {
            return Err("Amazon Photosのアカウントが一致しません。".into());
        }
        authorize_import(stage, receipt, bundle)?;
        let receipt_id = receipt.id.as_str();
        let keys: Vec<_> = bundle.assets.iter().map(|a| a.key.clone()).collect();
        let connection = self.session(&keys, OrdinaryContentPurpose::Read);
        // Validate the entire set before the first remote write. Each journal
        // record must identify exactly one upload of this receipt.
        let mut seen = BTreeSet::new();
        for file in &bundle.files {
            formats::check_resource(&file.resource)?;
            if !seen.insert((&file.resource.name, &file.signature)) {
                return Err(
                    "同じ原本を一つの転送で重複してアップロードしません。元の原本は残します。"
                        .into(),
                );
            }
        }
        if window
            .amazon_uploads()
            .iter()
            .any(|r| r.receipt_id == receipt_id)
        {
            return Err("この転送のアップロード記録が既にあります。書込みは再送しません。".into());
        }
        let mut imported = Vec::new();
        for (index, file) in bundle.files.iter().enumerate() {
            let hash: Hash = shell(
                io.ctx(),
                ShellOperation::AmazonHashFile {
                    path: file.path.clone(),
                },
            )
            .await?;
            if hash.signature != file.signature {
                return Err("アップロード前に原本が変わりました。".into());
            }
            let upload = connection
                .upload_request(
                    io.ctx(),
                    file,
                    &hash.md5,
                    bundle
                        .assets
                        .iter()
                        .find(|asset| asset.resources.iter().any(|r| r.id == file.resource.id))
                        .and_then(|asset| asset.captured_at),
                )
                .await?;
            let record = UploadRecord {
                receipt_id: receipt_id.into(),
                scope: connection.scope.clone(),
                name: file.resource.name.clone(),
                signature: file.signature.clone(),
                md5: hash.md5,
                node_id: None,
                verified: false,
            };
            imported.push(
                self.upload_one(
                    io,
                    window,
                    &connection,
                    (index, file, record, keys.as_slice()),
                    upload,
                )
                .await?,
            );
        }
        Ok(CreatedCopies(imported))
    }
}

impl CatalogListing for AmazonBackend {
    fn list<'a>(&'a self, io: ReadIo<'a>, request: ListRequest) -> Io<'a, Listing> {
        Box::pin(async move { self.list_all(&io, request.now).await })
    }
}

impl OriginalExport for AmazonBackend {
    fn export<'a>(&'a self, io: ReadIo<'a>, request: ExportRequest<'a>) -> Io<'a, TransferBundle> {
        Box::pin(async move { self.export_originals(&io, request).await })
    }
}

impl OriginalImport for AmazonBackend {
    fn scope(&self) -> &str {
        &self.connection.scope
    }

    fn supports_move(&self) -> bool {
        false
    }

    fn publishes_copies(&self) -> bool {
        true
    }

    fn admit(&self, window: &dyn ImportWindow, keys: &[AssetKey]) -> Result<(), String> {
        if window
            .amazon_uploads()
            .iter()
            .any(|r| r.phase() != UploadRecordPhase::Verified && r.scope == self.connection.scope)
        {
            return Err("Amazon Photosへの未確定アップロードがあります。接続設定で結果を再確認してください。自動再送はしません。".into());
        }
        for key in keys {
            let asset = window
                .cataloged(key)
                .ok_or("転送元の原本を確認できません。")?;
            for resource in &asset.resources {
                formats::check_resource(resource)?;
            }
        }
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

impl FavoriteWrite for AmazonBackend {
    fn batch_size(&self) -> usize {
        1
    }

    fn saved_status(&self) -> &'static str {
        "Amazon Photosのお気に入りを保存しました。"
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
                let connection =
                    self.session(std::slice::from_ref(key), OrdinaryContentPurpose::Read);
                records.push(connection.favorite(io.ctx(), &key.asset_id, value).await?);
            }
            Ok::<_, String>(records)
        })
    }
}
