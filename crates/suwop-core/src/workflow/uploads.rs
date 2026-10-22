use super::{HashResult, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider, ResourceRole, StoredAsset, TransferFile, same_location},
    immich::{PendingUpload, Session, UploadMetadataPlan, UploadPhase, UploadResumePrompt},
};

impl Runtime<'_> {
    pub(super) async fn forget_upload_record(&mut self, key: &AssetKey) -> Result<String, String> {
        let record = self
            .state
            .pending_uploads
            .iter()
            .find(|p| p.key == *key && key.provider == Provider::Immich)
            .ok_or("解除する未完了コピーの記録がありません。")?;
        let prompt = crate::immich::UploadForgetPrompt {
            key: key.clone(),
            name: crate::privacy::public_asset_name(&self.state, &record.source),
        };
        let confirmed: bool = io(self.ctx, ShellOperation::ConfirmForgetUpload { prompt }).await?;
        if !confirmed {
            return Ok("再開記録の解除をキャンセルしました。".into());
        }
        let previous = self.state.pending_uploads.clone();
        self.state.pending_uploads.retain(|p| p.key != *key);
        if let Err(error) = self.persist().await {
            self.state.pending_uploads = previous;
            return Err(error);
        }
        Ok("このコピーの再開記録を解除しました。写真と転送履歴は変更していません。元の写真からコピーを選ぶと新しく確認します。".into())
    }

    pub(super) async fn upload_file(
        &mut self,
        session: &Session,
        file: &TransferFile,
        source: &StoredAsset,
        now: f64,
        live_id: Option<&str>,
    ) -> Result<String, String> {
        self.check_content_generation(std::slice::from_ref(&source.key))?;
        self.check_transfer_trash(std::slice::from_ref(source))?;
        let matches: Vec<_> = self
            .state
            .pending_uploads
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
            if self
                .state
                .pending_uploads
                .iter()
                .filter(|p| p.key == pending.key)
                .count()
                != 1
            {
                return Err("作成済みコピーの ID が重複しています。書込みを停止しました。".into());
            }
            return self.resume_upload(session, file, pending).await;
        }
        if !matches.is_empty() {
            return Err("作成済みコピーの記録が重複しています。書込みを停止しました。".into());
        }
        self.begin_upload(session, file, source, now, live_id).await
    }

    pub(super) async fn complete_created_upload(
        &mut self,
        session: &Session,
        file: &TransferFile,
        pending: &PendingUpload,
    ) -> Result<String, String> {
        let plan = session
            .prepare_upload_metadata(self.ctx, &pending.key.asset_id, &pending.source)
            .await?;
        verify_uploaded_identity(session, file, &plan)?;
        if plan.asset.live_photo_video_id != pending.live_id {
            return Err("新しいコピーの Live Photo の関連づけを確認できません。".into());
        }
        self.commit_upload_metadata(session, pending, plan).await?;
        Ok(pending.key.asset_id.clone())
    }

    pub(super) async fn resume_upload(
        &mut self,
        session: &Session,
        file: &TransferFile,
        pending: &PendingUpload,
    ) -> Result<String, String> {
        self.check_keys(std::slice::from_ref(&pending.key))?;
        let plan = session
            .prepare_upload_metadata(self.ctx, &pending.key.asset_id, &pending.source)
            .await?;
        if plan.asset.live_photo_video_id != pending.live_id {
            return Err("作成済みコピーの Live Photo の関連づけが変わっています。".into());
        }
        self.verify_pending_original(session, file, &plan).await?;
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
            self.finish_pending_upload(&pending.key).await?;
            return Ok(pending.key.asset_id.clone());
        }
        self.check_content_generation(std::slice::from_ref(&pending.source.key))?;
        let confirmed: bool = io(
            self.ctx,
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
        self.verify_upload_unchanged(session, &plan).await?;
        self.commit_upload_metadata(session, pending, plan).await?;
        Ok(pending.key.asset_id.clone())
    }

    async fn verify_pending_original(
        &self,
        session: &Session,
        file: &TransferFile,
        plan: &UploadMetadataPlan,
    ) -> Result<(), String> {
        verify_uploaded_identity(session, file, plan)?;
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
        let path = format!("{}/{}", self.directory("resume-upload")?, plan.asset.id);
        session.download(self.ctx, &plan.asset.id, &path).await?;
        let hash: HashResult = io(self.ctx, ShellOperation::HashFile { path }).await?;
        if hash.signature != file.signature || Some(hash.sha1) != file.resource.sha1 {
            return Err("作成済みコピーの原本が一致しません。".into());
        }
        self.verify_upload_unchanged(session, plan).await
    }

    async fn verify_upload_unchanged(
        &self,
        session: &Session,
        plan: &UploadMetadataPlan,
    ) -> Result<(), String> {
        let fresh = session.asset(self.ctx, &plan.asset.id).await?;
        if fresh.updated_at != plan.asset.updated_at
            || fresh.record(&session.scope, None, None)
                != plan.asset.record(&session.scope, None, None)
        {
            return Err(
                "確認中にコピー先が変更されました。メタデータを書き込んでいません。".into(),
            );
        }
        Ok(())
    }

    async fn commit_upload_metadata(
        &mut self,
        session: &Session,
        pending: &PendingUpload,
        plan: UploadMetadataPlan,
    ) -> Result<(), String> {
        self.check_content_generation(std::slice::from_ref(&pending.source.key))?;
        self.check_keys(std::slice::from_ref(&pending.key))?;
        let entry = self
            .state
            .pending_uploads
            .iter_mut()
            .find(|p| p.key == pending.key)
            .ok_or("作成済みコピーの記録がありません。")?;
        let previous_phase = entry.phase;
        entry.phase = UploadPhase::MetadataStarted;
        // Journal before PUT, including the cancellation gap. Lost PUT responses
        // can only be verified by reads on the next explicit copy operation.
        if let Err(error) = self.persist().await {
            // No PUT was issued. Keep the in-memory phase truthful so a later
            // unrelated save cannot turn this into a lost-write recovery.
            if let Some(entry) = self
                .state
                .pending_uploads
                .iter_mut()
                .find(|p| p.key == pending.key)
            {
                entry.phase = previous_phase;
            }
            return Err(error);
        }
        self.check_content_generation(std::slice::from_ref(&pending.source.key))?;
        session
            .apply_upload_metadata(self.ctx, &pending.key.asset_id, plan.body)
            .await?;
        self.finish_pending_upload(&pending.key).await
    }

    async fn finish_pending_upload(&mut self, key: &AssetKey) -> Result<(), String> {
        let previous = self.state.pending_uploads.clone();
        self.state.pending_uploads.retain(|p| p.key != *key);
        if let Err(error) = self.persist().await {
            self.state.pending_uploads = previous;
            return Err(error);
        }
        Ok(())
    }
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
#[cfg(test)]
mod selected_read_resume_tests {
    use super::*;
    use crate::{
        app::{Effect, Event, SavedLibrary},
        domain::{AppleVisibility, FileSignature, LibrarySnapshot, PhotoResource, ScanAccess},
        immich::{UploadPhase, Version},
        immich_visibility::{
            AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
            ImmichVisibilityOperationKind,
        },
    };
    fn apple_source() -> StoredAsset {
        StoredAsset {
            immich_visibility: None,
            immich_stack: crate::domain::ImmichStackState::Unknown,
            immich_stack_membership: None,
            apple_visibility: AppleVisibility::Visible,
            key: AssetKey {
                provider: Provider::Apple,
                scope: "apple".into(),
                asset_id: "source".into(),
            },
            name: "source.jpg".into(),
            captured_at: None,
            modified_at: None,
            revision: "source-revision".into(),
            resources: vec![PhotoResource {
                id: "source-original".into(),
                name: "source.jpg".into(),
                role: ResourceRole::Image,
                sha1: Some("a".repeat(40)),
                bytes: Some(1),
            }],
            is_favorite: false,
            latitude: None,
            longitude: None,
            inventory_complete: true,
            is_offline: false,
            deletion_blockers: vec![],
        }
    }
    #[test]
    fn fenced_resume_destination_is_rejected_before_any_io_while_apple_source_remains_operable() {
        let source = apple_source();
        let key = AssetKey {
            provider: Provider::Immich,
            scope: "remote".into(),
            asset_id: "33333333-3333-4333-8333-333333333333".into(),
        };
        let mut state = SavedLibrary {
            schema_version: 8,
            apple_scope: "apple".into(),
            ..SavedLibrary::default()
        };
        state.snapshots.push(LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            access: ScanAccess::Full,
            assets: vec![source.clone()],
            scanned_at: Some(1.0),
        });
        state
            .immich_visibility_operations
            .push(ImmichVisibilityOperation {
                kind: ImmichVisibilityOperationKind::LockedTransition,
                id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into(),
                scope: key.scope.clone(),
                key: key.clone(),
                witness_digest: "b".repeat(64),
                from: ImmichVisibility::Timeline,
                to: ImmichVisibility::Locked,
                outcome: crate::apple_visibility::VisibilityOutcome::Unknown,
                observation: None,
                album_membership_observation: AlbumMembershipObservation::NotChecked,
                selected_observation: None,
            });
        let session = Session {
            ordinary_content_guard: None,
            ordinary_content_context: None,
            endpoint: "https://fixture.example/api".into(),
            key: "fixture-key".into(),
            user_id: "owner".into(),
            scope: "remote".into(),
            version: Version {
                major: 3,
                minor: 3,
                patch: 3,
            },
        };
        let pending = PendingUpload {
            key,
            source: source.clone(),
            resource: source.resources[0].clone(),
            signature: FileSignature {
                sha256: "c".repeat(64),
                bytes: 1,
            },
            live_id: None,
            phase: UploadPhase::MetadataPending,
        };
        let file = TransferFile {
            resource: pending.resource.clone(),
            path: "/fixture/source.jpg".into(),
            signature: pending.signature.clone(),
        };
        let completed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let observed = completed.clone();
        let mut command = crux_core::Command::<Effect, Event>::new(move |ctx| async move {
            let mut runtime = Runtime {
                refresh_persist_issued: false,
                ordinary_selected: vec![],
                denied_content: std::collections::BTreeSet::new(),
                ordinary_generation: std::sync::Arc::default(),
                started_ordinary_generation: 0,
                ordinary_revision: "fixture".into(),
                apple_generation: std::sync::Arc::default(),
                started_generation: 0,
                reversion_started: false,
                preferred_preview: None,
                ctx: &ctx,
                state,
                session: Some(session.clone()),
                workspace: None,
                editing_token: None,
            };
            assert_eq!(
                runtime.check_keys(std::slice::from_ref(&source.key)),
                Ok(Provider::Apple)
            );
            assert!(
                runtime
                    .resume_upload(&session, &file, &pending)
                    .await
                    .is_err()
            );
            observed.store(true, std::sync::atomic::Ordering::SeqCst);
        });
        assert_eq!(command.effects().count(), 0);
        assert!(completed.load(std::sync::atomic::Ordering::SeqCst));
    }
}
