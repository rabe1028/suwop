use super::Runtime;
use crate::{
    albums::{
        AlbumAction, AlbumEdit, AlbumKey, AlbumSnapshot, validate_edit, validate_snapshot,
        validate_title,
    },
    domain::{Provider, ScanAccess},
    provider::{Ability, PROVIDERS, offers, unsupported},
};

impl Runtime<'_> {
    pub(super) async fn refresh_albums(&mut self) -> Result<String, String> {
        let mut errors = Vec::new();
        if let Err(error) = self.ensure_session().await {
            self.invalidate_albums(Provider::Immich);
            errors.push(error);
        }
        let registry = self.registry();
        for provider in PROVIDERS {
            if registry.album_reader(provider).is_none() {
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

    pub(super) async fn reload_albums(&mut self, provider: Provider) -> Result<(), String> {
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

    pub(super) fn invalidate_albums(&mut self, provider: Provider) {
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
        let registry = self.registry();
        let albums = registry
            .album_reader(provider)
            .ok_or_else(|| registry.missing(provider, Ability::AlbumRead))?;
        let snapshot = albums.read_albums(self.read_io()).await?;
        validate_snapshot(&snapshot, provider, albums.album_scope())?;
        Ok(snapshot)
    }

    pub(super) async fn create_album(
        &mut self,
        provider: Provider,
        title: &str,
    ) -> Result<String, String> {
        validate_title(title)?;
        if !offers(provider, Ability::AlbumCreate) {
            return Err(unsupported(provider, Ability::AlbumCreate));
        }
        self.ensure_connections([provider]).await?;
        let registry = self.registry();
        let creator = registry
            .album_creator(provider)
            .ok_or_else(|| registry.missing(provider, Ability::AlbumCreate))?;
        let scope = registry
            .album_reader(provider)
            .ok_or_else(|| registry.missing(provider, Ability::AlbumRead))?
            .album_scope()
            .to_owned();
        let title = title.trim();
        let result = creator.create_album(self.read_io(), title).await;
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
        if !offers(key.provider, Ability::AlbumEdit) {
            return Err(unsupported(key.provider, Ability::AlbumEdit));
        }
        self.ensure_connections([key.provider]).await?;
        if !edit.keys.is_empty() {
            self.check_keys(&edit.keys)?;
        }
        let registry = self.registry();
        let albums = registry
            .album_editor(key.provider)
            .ok_or_else(|| registry.missing(key.provider, Ability::AlbumEdit))?;
        let reader = registry
            .album_reader(key.provider)
            .ok_or_else(|| registry.missing(key.provider, Ability::AlbumRead))?;
        if key.scope != reader.album_scope() {
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
        let result = albums.edit_album(self.read_io(), key, &edit).await;
        self.invalidate_albums(key.provider);
        result?;
        self.reload_albums(key.provider).await?;
        self.verify_album_edit(key, &edit)?;
        self.persist().await?;
        Ok("アルバムを変更しました。写真の原本は残っています。".into())
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
