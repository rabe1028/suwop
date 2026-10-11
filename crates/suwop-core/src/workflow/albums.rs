use super::{Runtime, ShellOperation, io};
use crate::{
    albums::{
        AlbumAction, AlbumEdit, AlbumKey, AlbumPermissions, AlbumSnapshot, StoredAlbum,
        validate_edit, validate_snapshot, validate_title,
    },
    domain::{AssetKey, Provider, ScanAccess},
};

impl Runtime<'_> {
    pub(super) async fn refresh_albums(&mut self) -> Result<String, String> {
        let mut errors = Vec::new();
        if let Err(error) = self.ensure_session().await {
            self.invalidate_albums(Provider::Immich);
            errors.push(error);
        }
        for provider in [Provider::Apple, Provider::Immich] {
            if provider == Provider::Immich && self.session.is_none() {
                continue;
            }
            if let Err(error) = self.reload_albums(provider).await {
                errors.push(error);
            }
        }
        self.persist().await?;
        if errors.is_empty() {
            Ok("アルバムを更新しました。".into())
        } else {
            Err(errors.join("\n"))
        }
    }

    async fn reload_albums(&mut self, provider: Provider) -> Result<(), String> {
        let result = self.read_albums(provider).await;
        match result {
            Ok(snapshot) => {
                self.state.albums.retain(|s| s.provider != provider);
                self.state.albums.push(snapshot);
                Ok(())
            }
            Err(error) => {
                self.invalidate_albums(provider);
                Err(error)
            }
        }
    }

    fn invalidate_albums(&mut self, provider: Provider) {
        for s in self
            .state
            .albums
            .iter_mut()
            .filter(|s| s.provider == provider)
        {
            s.access = ScanAccess::Unavailable;
        }
    }

    async fn read_albums(&self, provider: Provider) -> Result<AlbumSnapshot, String> {
        let snapshot = match provider {
            Provider::Apple => {
                io(
                    self.ctx,
                    ShellOperation::AppleAlbums {
                        scope: self.state.apple_scope.clone(),
                    },
                )
                .await?
            }
            Provider::Immich => {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                let mut albums = Vec::new();
                for album in session
                    .albums(self.ctx)
                    .await?
                    .into_iter()
                    .filter(|a| a.owned_by(&session.user_id))
                {
                    let members = session
                        .album_members(self.ctx, &album.id)
                        .await?
                        .into_iter()
                        .map(|a| AssetKey {
                            provider,
                            scope: session.scope.clone(),
                            asset_id: a.id,
                        })
                        .collect();
                    albums.push(StoredAlbum {
                        key: AlbumKey {
                            provider,
                            scope: session.scope.clone(),
                            album_id: album.id,
                        },
                        title: album.album_name,
                        members,
                        permissions: AlbumPermissions {
                            add: true,
                            remove: true,
                            rename: true,
                            delete: true,
                        },
                    });
                }
                AlbumSnapshot {
                    provider,
                    scope: session.scope.clone(),
                    albums,
                    access: ScanAccess::Full,
                }
            }
        };
        validate_snapshot(&snapshot, provider, self.album_scope(provider)?)?;
        Ok(snapshot)
    }

    fn album_scope(&self, provider: Provider) -> Result<&str, String> {
        match provider {
            Provider::Apple => Ok(&self.state.apple_scope),
            Provider::Immich => Ok(&self
                .session
                .as_ref()
                .ok_or("Immich に接続してください。")?
                .scope),
        }
    }

    pub(super) async fn create_album(
        &mut self,
        provider: Provider,
        title: &str,
    ) -> Result<String, String> {
        validate_title(title)?;
        if provider == Provider::Immich {
            self.ensure_session().await?;
        }
        let scope = self.album_scope(provider)?.to_owned();
        let title = title.trim();
        let result: Result<StoredAlbum, String> = match provider {
            Provider::Apple => {
                io(
                    self.ctx,
                    ShellOperation::AppleAlbumCreate {
                        scope: scope.clone(),
                        title: title.into(),
                    },
                )
                .await
            }
            Provider::Immich => {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                session
                    .create_album(self.ctx, title)
                    .await
                    .map(|a| StoredAlbum {
                        key: AlbumKey {
                            provider,
                            scope: scope.clone(),
                            album_id: a.id,
                        },
                        title: a.album_name,
                        members: Vec::new(),
                        permissions: AlbumPermissions::default(),
                    })
            }
        };
        // A failed callback can still have committed. Never silently retry creation.
        self.invalidate_albums(provider);
        let created = result?;
        if created.key.provider != provider || created.key.scope != scope || created.title != title
        {
            return Err(
                "作成したアルバムの保存先または名前を確認できません。一覧を更新してください。"
                    .into(),
            );
        }
        self.reload_albums(provider).await?;
        if !self
            .state
            .albums
            .iter()
            .flat_map(|s| &s.albums)
            .any(|a| a.key == created.key && a.title == title)
        {
            self.invalidate_albums(provider);
            return Err("作成したアルバムを再取得できません。一覧を更新してください。".into());
        }
        self.persist().await?;
        Ok("アルバムを作成しました。".into())
    }

    pub(super) async fn edit_album(
        &mut self,
        key: &AlbumKey,
        edit: &AlbumEdit,
    ) -> Result<String, String> {
        if key.provider == Provider::Immich {
            self.ensure_session().await?;
        }
        if key.scope != self.album_scope(key.provider)? {
            return Err("アルバムの保存先が変わっています。".into());
        }
        // Capabilities and membership must be fresh before each mutation.
        self.reload_albums(key.provider).await?;
        let album = self
            .state
            .albums
            .iter()
            .filter(|s| s.access == ScanAccess::Full)
            .flat_map(|s| &s.albums)
            .find(|a| a.key == *key)
            .ok_or("アルバムを確認できません。")?;
        validate_edit(album, edit)?;
        let mut edit = edit.clone();
        edit.title = edit.title.map(|s| s.trim().into());
        if matches!(edit.action, AlbumAction::Add)
            && edit.keys.iter().any(|key| {
                !self
                    .state
                    .snapshots
                    .iter()
                    .filter(|s| s.access != ScanAccess::Unavailable)
                    .flat_map(|s| &s.assets)
                    .any(|a| a.key == *key)
            })
        {
            return Err("選択した写真を確認できません。一覧を更新してください。".into());
        }
        let result = self.perform_album_edit(key, &edit).await;
        self.invalidate_albums(key.provider);
        result?;
        self.reload_albums(key.provider).await?;
        self.verify_album_edit(key, &edit)?;
        self.persist().await?;
        Ok("アルバムを変更しました。写真の原本は残っています。".into())
    }

    async fn perform_album_edit(&self, key: &AlbumKey, edit: &AlbumEdit) -> Result<(), String> {
        match key.provider {
            Provider::Apple => io::<serde_json::Value>(
                self.ctx,
                ShellOperation::AppleAlbumEdit {
                    key: key.clone(),
                    edit: edit.clone(),
                },
            )
            .await
            .map(|_| ()),
            Provider::Immich => {
                let session = self.session.as_ref().ok_or("Immich に接続してください。")?;
                match edit.action {
                    AlbumAction::Rename => {
                        session
                            .rename_album(
                                self.ctx,
                                &key.album_id,
                                edit.title.as_deref().ok_or("名前がありません。")?,
                            )
                            .await
                    }
                    AlbumAction::Delete => session.delete_album(self.ctx, &key.album_id).await,
                    AlbumAction::Add | AlbumAction::Remove => {
                        let ids = edit
                            .keys
                            .iter()
                            .map(|k| k.asset_id.clone())
                            .collect::<Vec<_>>();
                        session
                            .change_album_members(
                                self.ctx,
                                &key.album_id,
                                &ids,
                                matches!(edit.action, AlbumAction::Add),
                            )
                            .await
                    }
                }
            }
        }
    }

    fn verify_album_edit(&mut self, key: &AlbumKey, edit: &AlbumEdit) -> Result<(), String> {
        let album = self
            .state
            .albums
            .iter()
            .flat_map(|s| &s.albums)
            .find(|a| a.key == *key);
        let verified = match edit.action {
            AlbumAction::Delete => album.is_none(),
            AlbumAction::Rename => album.is_some_and(|a| Some(&a.title) == edit.title.as_ref()),
            AlbumAction::Add | AlbumAction::Remove => album.is_some_and(|a| {
                edit.keys
                    .iter()
                    .all(|k| a.members.contains(k) == matches!(edit.action, AlbumAction::Add))
            }),
        };
        if verified {
            Ok(())
        } else {
            self.invalidate_albums(key.provider);
            Err("アルバムの保存結果を確認できません。一覧を更新してください。".into())
        }
    }
}
