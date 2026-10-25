//! Journaled Immich uploads. Each remote write is split into preparation,
//! a durably saved stage, one submission bound to that stage, and response
//! interpretation. A lost or ambiguous response leaves its stage as a fence
//! and is resolved only by reads on a later explicit copy.
use std::collections::BTreeSet;

use super::{CreatedCopies, ImmichBackend, ImportRequest, ImportWindow, ReadIo, authorize_import};
use crate::{
    app::{ShellOperation, io as shell},
    domain::{AssetKey, Provider, ResourceRole, StoredAsset, TransferFile, same_location},
    immich::{
        PendingUpload, Session, UploadIntent, UploadMetadataPlan, UploadPhase, UploadResumePrompt,
        valid_id,
    },
    workflow::{
        HashResult,
        journal::{JournalChange, StageBinding},
    },
};

impl ImmichBackend {
    pub(super) async fn import_bundle(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        request: ImportRequest<'_>,
    ) -> Result<CreatedCopies, String> {
        let ImportRequest {
            receipt,
            stage,
            bundle,
            now,
        } = request;
        if receipt.destination_scope != self.session.scope {
            return Err("写真ライブラリまたはアカウントが一致しません。".into());
        }
        authorize_import(stage, receipt, bundle)?;
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
                self.upload_file(io, window, file, metadata, now, None)
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
                .upload_file(io, window, file, metadata, now, attach)
                .await?;
            if attach.is_some()
                && self
                    .session
                    .asset(io.ctx(), &id)
                    .await?
                    .live_photo_video_id
                    .as_deref()
                    != attach
            {
                return Err("Live Photo の関連づけを確認できません。元データは残します。".into());
            }
            keys.insert(AssetKey {
                provider: Provider::Immich,
                scope: self.session.scope.clone(),
                asset_id: id,
            });
        }
        Ok(CreatedCopies(keys.into_iter().collect()))
    }

    async fn upload_file(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        file: &TransferFile,
        source: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<String, String> {
        window.check_source(source)?;
        let session = &self.session;
        let journal = window.pending_uploads();
        let matches: Vec<_> = journal
            .iter()
            .filter(|p| {
                p.key.provider == Provider::Immich
                    && p.key.scope == session.scope
                    && p.source.same_content_evidence(source)
                    && p.resource == file.resource
                    && p.signature == file.signature
                    && p.live_id.as_deref() == live_id
            })
            .cloned()
            .collect();
        if let [pending] = matches.as_slice() {
            if journal.iter().filter(|p| p.key == pending.key).count() != 1 {
                return Err("作成済みコピーの ID が重複しています。書込みを停止しました。".into());
            }
            return self.resume_upload(io, window, file, pending).await;
        }
        if !matches.is_empty() {
            return Err("作成済みコピーの記録が重複しています。書込みを停止しました。".into());
        }
        self.begin_upload(io, window, file, source, now, live_id)
            .await
    }

    async fn begin_upload(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        file: &TransferFile,
        source: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<String, String> {
        let session = &self.session;
        let intents: Vec<_> = window
            .upload_intents()
            .into_iter()
            .filter(|p| p.matches(session, file, source, live_id))
            .collect();
        if let [intent] = intents.as_slice() {
            check_unique_intent(&window.upload_intents(), intent)?;
            let id = session.reconcile_upload_intent(io.ctx(), intent).await?;
            let pending = promote_upload_intent(window, intent, id).await?;
            return self.resume_upload(io, window, file, &pending).await;
        }
        if !intents.is_empty() {
            return Err("アップロード開始記録が重複しています。書込みを停止しました。".into());
        }
        // Validate dates, checksums and Live linkage before journaling or POST.
        session.upload_request(file, source, now, live_id)?;
        let token: String = shell(io.ctx(), ShellOperation::RandomId).await?;
        valid_id(&token)?;
        let intent = UploadIntent {
            scope: session.scope.clone(),
            token,
            source: source.clone(),
            resource: file.resource.clone(),
            signature: file.signature.clone(),
            live_id: live_id.map(str::to_owned),
        };
        let stage = window
            .stage(JournalChange::ImmichIntent(intent.clone()))
            .await?;
        io.check(std::slice::from_ref(&source.key))?;
        stage.authorize(&StageBinding::immich_intent(&intent))?;
        let (id, created) = session
            .create_intended_upload(io.ctx(), file, &intent, now)
            .await?;
        if !created {
            window
                .stage(JournalChange::ImmichIntentRemoved {
                    scope: intent.scope,
                    token: intent.token,
                })
                .await?;
            return Ok(id);
        }
        let pending = promote_upload_intent(window, &intent, id).await?;
        self.complete_created_upload(io, window, file, &pending)
            .await
    }

    async fn complete_created_upload(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        file: &TransferFile,
        pending: &PendingUpload,
    ) -> Result<String, String> {
        let plan = self
            .session
            .prepare_upload_metadata(io.ctx(), &pending.key.asset_id, &pending.source)
            .await?;
        verify_uploaded_identity(&self.session, file, &plan)?;
        if plan.asset.live_photo_video_id != pending.live_id {
            return Err("新しいコピーの Live Photo の関連づけを確認できません。".into());
        }
        self.commit_upload_metadata(io, window, pending, plan)
            .await?;
        Ok(pending.key.asset_id.clone())
    }

    pub(crate) async fn resume_upload(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        file: &TransferFile,
        pending: &PendingUpload,
    ) -> Result<String, String> {
        window.check_destination(std::slice::from_ref(&pending.key))?;
        let session = &self.session;
        let plan = session
            .prepare_upload_metadata(io.ctx(), &pending.key.asset_id, &pending.source)
            .await?;
        if plan.asset.live_photo_video_id != pending.live_id {
            return Err("作成済みコピーの Live Photo の関連づけが変わっています。".into());
        }
        let directory = window.work_directory("resume-upload")?;
        self.verify_pending_original(io, &directory, file, &plan)
            .await?;
        if pending.phase == UploadPhase::MetadataStarted {
            let current = plan.asset.record(&session.scope, None, None);
            if plan.body.get("dateTimeOriginal").is_some()
                || current.is_favorite != pending.source.is_favorite
                || pending.source.latitude.is_some() && !same_location(&current, &pending.source)
            {
                return Err("メタデータ書込みの結果を確認できません。自動再試行せず、コピー先の情報画面で確認してください。".into());
            }
            // A lost response can be recovered by reads only when every intended
            // value is already present. It never authorizes another PUT.
            finish_pending_upload(window, &pending.key).await?;
            return Ok(pending.key.asset_id.clone());
        }
        io.check(std::slice::from_ref(&pending.source.key))?;
        let confirmed: bool = shell(
            io.ctx(),
            ShellOperation::ConfirmUploadResume {
                prompt: UploadResumePrompt {
                    key: pending.key.clone(),
                    name: plan.asset.original_file_name.clone(),
                    source: pending.source.clone(),
                },
            },
        )
        .await?;
        if !confirmed {
            return Err(
                "作成済みコピーのメタデータ反映をキャンセルしました。元の写真は残しています。"
                    .into(),
            );
        }
        self.verify_upload_unchanged(io, &plan).await?;
        self.commit_upload_metadata(io, window, pending, plan)
            .await?;
        Ok(pending.key.asset_id.clone())
    }

    async fn verify_pending_original(
        &self,
        io: &ReadIo<'_>,
        directory: &str,
        file: &TransferFile,
        plan: &UploadMetadataPlan,
    ) -> Result<(), String> {
        verify_uploaded_identity(&self.session, file, plan)?;
        if plan.asset.is_offline
            || plan.asset.is_edited != Some(false)
            || !(plan.asset.is_external == Some(false)
                || matches!(
                    plan.asset.library_id,
                    crate::immich::LibraryStorage::Internal
                ))
        {
            return Err("作成済みコピーの原本・保存種別・編集状態を確認できません。".into());
        }
        let path = format!("{directory}/{}", plan.asset.id);
        self.session
            .download(io.ctx(), &plan.asset.id, &path)
            .await?;
        let hash: HashResult = shell(io.ctx(), ShellOperation::HashFile { path }).await?;
        if hash.signature != file.signature || Some(hash.sha1) != file.resource.sha1 {
            return Err("作成済みコピーの原本が一致しません。".into());
        }
        self.verify_upload_unchanged(io, plan).await
    }

    async fn verify_upload_unchanged(
        &self,
        io: &ReadIo<'_>,
        plan: &UploadMetadataPlan,
    ) -> Result<(), String> {
        let scope = &self.session.scope;
        let fresh = self.session.asset(io.ctx(), &plan.asset.id).await?;
        if fresh.updated_at != plan.asset.updated_at
            || fresh.record(scope, None, None) != plan.asset.record(scope, None, None)
        {
            return Err(
                "確認中にコピー先が変更されました。メタデータを書き込んでいません。".into(),
            );
        }
        Ok(())
    }

    async fn commit_upload_metadata(
        &self,
        io: &ReadIo<'_>,
        window: &mut dyn ImportWindow,
        pending: &PendingUpload,
        plan: UploadMetadataPlan,
    ) -> Result<(), String> {
        io.check(std::slice::from_ref(&pending.source.key))?;
        window.check_destination(std::slice::from_ref(&pending.key))?;
        // Journal before PUT, including the cancellation gap. Lost PUT responses
        // can only be verified by reads on the next explicit copy operation.
        let stage = window
            .stage(JournalChange::ImmichMetadataStarted(pending.key.clone()))
            .await?;
        io.check(std::slice::from_ref(&pending.source.key))?;
        stage.authorize(&StageBinding::ImmichMetadata(pending.key.clone()))?;
        self.session
            .apply_upload_metadata(io.ctx(), &pending.key.asset_id, plan.body)
            .await?;
        finish_pending_upload(window, &pending.key).await
    }
}

fn check_unique_intent(journal: &[UploadIntent], intent: &UploadIntent) -> Result<(), String> {
    if journal.iter().filter(|p| p.token == intent.token).count() != 1 {
        return Err("アップロードの固有 ID が重複しています。書込みを停止しました。".into());
    }
    Ok(())
}

async fn promote_upload_intent(
    window: &mut dyn ImportWindow,
    intent: &UploadIntent,
    id: String,
) -> Result<PendingUpload, String> {
    check_unique_intent(&window.upload_intents(), intent)?;
    let pending = intent.pending(id);
    if window
        .pending_uploads()
        .iter()
        .any(|p| p.key == pending.key)
    {
        return Err(
            "作成済みコピーの ID が既存の記録と重複しています。書込みを停止しました。".into(),
        );
    }
    window
        .stage(JournalChange::ImmichIntentPromoted {
            token: intent.token.clone(),
            pending: pending.clone(),
        })
        .await?;
    Ok(pending)
}

async fn finish_pending_upload(
    window: &mut dyn ImportWindow,
    key: &AssetKey,
) -> Result<(), String> {
    window
        .stage(JournalChange::ImmichPendingRemoved(key.clone()))
        .await
        .map(|_| ())
}

fn verify_uploaded_identity(
    session: &Session,
    file: &TransferFile,
    plan: &UploadMetadataPlan,
) -> Result<(), String> {
    let record = plan.asset.record(&session.scope, None, None);
    let role = if file.resource.role == ResourceRole::LiveVideo {
        ResourceRole::Video
    } else {
        file.resource.role
    };
    if record.originals().next().is_none_or(|r| {
        r.name != crate::immich::safe_name(&file.resource.name)
            || r.role != role
            || r.sha1 != file.resource.sha1
    }) {
        return Err("アップロードされた原本の名前・種類・チェックサムが一致しません。".into());
    }
    Ok(())
}
