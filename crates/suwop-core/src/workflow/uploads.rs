use super::{JournalChange, Runtime};
use crate::{
    app::{ShellOperation, io},
    domain::{AssetKey, Provider},
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
        self.persist_stage(JournalChange::ImmichPendingRemoved(key.clone()))
            .await?;
        Ok("このコピーの再開記録を解除しました。写真と転送履歴は変更していません。元の写真からコピーを選ぶと新しく確認します。".into())
    }
}

#[cfg(test)]
mod selected_read_resume_tests {
    use super::*;
    use crate::{
        app::{Effect, Event, SavedLibrary},
        domain::{
            AppleVisibility, FileSignature, LibrarySnapshot, PhotoResource, ResourceRole,
            ScanAccess, StoredAsset, TransferFile,
        },
        immich::{PendingUpload, Session, UploadPhase, Version},
        immich_visibility::{
            AlbumMembershipObservation, ImmichVisibility, ImmichVisibilityOperation,
            ImmichVisibilityOperationKind,
        },
        provider::ImmichBackend,
    };
    fn apple_source() -> StoredAsset {
        StoredAsset {
            immich_parent_revision: None,
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
            schema_version: crate::immich_live_writes::CURRENT_SCHEMA_VERSION,
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
                session_published: true,
                apple_generation: std::sync::Arc::default(),
                started_generation: 0,
                reversion_started: false,
                preferred_preview: None,
                ctx: &ctx,
                state,
                session: Some(session.clone()),
                workspace: None,
                editing_token: None,
                injected_registry: None,
            };
            assert_eq!(
                runtime.check_keys(std::slice::from_ref(&source.key)),
                Ok(Provider::Apple)
            );
            let backend = ImmichBackend::new(session);
            let io = runtime.read_io();
            assert!(
                backend
                    .resume_upload(&io, &mut runtime, &file, &pending)
                    .await
                    .is_err()
            );
            observed.store(true, std::sync::atomic::Ordering::SeqCst);
        });
        assert_eq!(command.effects().count(), 0);
        assert!(completed.load(std::sync::atomic::Ordering::SeqCst));
    }
}
