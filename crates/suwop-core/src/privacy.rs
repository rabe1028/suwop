//! One-way presentation boundary. This type is never accepted by persistence.
use crate::{
    app::{ConnectionSettings, SavedLibrary},
    domain::{
        AssetKey, FileSignature, LibrarySnapshot, PhotoResource, Provider, ResourceRole,
        ScanAccess, StoredAsset, TransferReceipt,
    },
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PublishedLibrary {
    pub apple_visibility_operations: Vec<crate::apple_visibility::AppleVisibilitySummary>,
    #[serde(default)]
    pub edit_clipboard: Option<crate::editing::EditClipboard>,
    #[serde(default)]
    pub pending_edit_pastes: Vec<crate::editing::PendingEditPaste>,
    pub schema_version: u32,
    pub apple_scope: String,
    pub connection: Option<ConnectionSettings>,
    #[serde(default)]
    pub snapshots: Vec<LibrarySnapshot>,
    #[serde(default)]
    pub receipts: Vec<TransferReceipt>,
    #[serde(default)]
    pub albums: Vec<crate::albums::AlbumSnapshot>,
    #[serde(default)]
    pub pending_uploads: Vec<crate::immich::PendingUpload>,
    #[serde(default)]
    pub upload_intents: Vec<crate::immich::UploadIntent>,
    #[serde(default)]
    pub trash: Option<crate::trash::TrashSnapshot>,
    #[serde(default)]
    pub pending_trash: Vec<crate::trash::TrashOperation>,
    #[serde(default)]
    pub pending_apple_trash: Vec<crate::trash::AppleTrashOperation>,
}

impl SavedLibrary {
    pub(crate) fn apple_content_visible(&self, key: &AssetKey) -> bool {
        ContentAccess::new(self).visible(key)
    }

    pub(crate) fn presentation_snapshots(&self) -> Vec<LibrarySnapshot> {
        let access = ContentAccess::new(self);
        self.snapshots
            .iter()
            .cloned()
            .map(|mut s| {
                s.assets.retain(|a| access.visible(&a.key));
                s
            })
            .collect()
    }

    pub(crate) fn recorded_assets(&self) -> impl Iterator<Item = &StoredAsset> {
        self.snapshots
            .iter()
            .flat_map(|s| &s.assets)
            .chain(
                self.receipts
                    .iter()
                    .flat_map(|r| r.source.iter().chain(&r.destination)),
            )
            .chain(self.pending_apple_trash.iter().flat_map(|o| &o.assets))
            .chain(self.pending_uploads.iter().map(|u| &u.source))
            .chain(self.upload_intents.iter().map(|u| &u.source))
            .chain(
                self.pending_edit_pastes
                    .iter()
                    .flat_map(|p| &p.before.assets),
            )
    }
}

/// Build exact current physical membership once; content-equivalent copies grant no access.
pub(crate) struct ContentAccess {
    visible: BTreeSet<AssetKey>,
    hidden: BTreeSet<AssetKey>,
    protected: BTreeSet<AssetKey>,
    app_protected: BTreeSet<AssetKey>,
}
impl ContentAccess {
    pub(crate) fn new(state: &SavedLibrary) -> Self {
        let snapshots: Vec<_> = state
            .snapshots
            .iter()
            .filter(|s| s.provider == Provider::Apple && s.scope == state.apple_scope)
            .collect();
        let mut visible = BTreeSet::new();
        let mut hidden = BTreeSet::new();
        let mut duplicates = BTreeSet::new();
        if let [snapshot] = snapshots.as_slice()
            && snapshot.access != ScanAccess::Unavailable
        {
            let mut seen = BTreeSet::new();
            for asset in &snapshot.assets {
                if !seen.insert(asset.key.clone()) {
                    duplicates.insert(asset.key.clone());
                }
                if asset.apple_visibility == crate::domain::AppleVisibility::Hidden {
                    hidden.insert(asset.key.clone());
                }
                if asset.key.provider == Provider::Apple
                    && asset.key.scope == state.apple_scope
                    && asset.content_visible()
                {
                    visible.insert(asset.key.clone());
                }
            }
        }
        visible.retain(|k| {
            !duplicates.contains(k)
                && !state
                    .apple_visibility_operations
                    .iter()
                    .any(|o| o.fences(k))
        });
        hidden.retain(|k| !duplicates.contains(k));
        Self {
            app_protected: state
                .protected_entries
                .iter()
                .map(|e| e.key.clone())
                .collect(),
            visible,
            hidden,
            protected: state
                .protected_entries
                .iter()
                .map(|e| e.key.clone())
                .chain(
                    state
                        .immich_visibility_operations
                        .iter()
                        .filter(|o| crate::immich_visibility::fences(state, &o.key))
                        .map(|o| o.key.clone()),
                )
                .collect(),
        }
    }
    pub(crate) fn visible(&self, key: &AssetKey) -> bool {
        self.can_operate(key)
    }
    pub(crate) fn can_operate(&self, key: &AssetKey) -> bool {
        !self.protected.contains(key)
            && (key.provider != Provider::Apple || self.visible.contains(key))
    }

    pub(crate) fn can_present(&self, key: &AssetKey, presentation: &BTreeSet<AssetKey>) -> bool {
        !self.app_protected.contains(key) && (self.can_operate(key) || presentation.contains(key))
    }
    pub(crate) fn protected(&self, key: &AssetKey) -> bool {
        self.protected.contains(key)
    }
    pub(crate) fn receipt_visible(&self, receipt: &TransferReceipt) -> bool {
        receipt
            .source
            .iter()
            .chain(&receipt.destination)
            .all(|asset| self.visible(&asset.key))
    }
}

fn omit_protected_records(state: &mut SavedLibrary, access: &ContentAccess) {
    let protected = |key: &AssetKey| access.protected.contains(key);
    state.receipts.retain(|r| {
        !r.source
            .iter()
            .chain(&r.destination)
            .any(|a| protected(&a.key))
    });
    state
        .pending_uploads
        .retain(|u| !protected(&u.source.key) && !protected(&u.key));
    state.upload_intents.retain(|u| !protected(&u.source.key));
    state
        .pending_apple_trash
        .retain(|o| !o.assets.iter().any(|a| protected(&a.key)));
    state
        .pending_trash
        .retain(|o| !o.assets.iter().any(|a| protected(&a.key)));
    state
        .apple_visibility_operations
        .retain(|o| !o.targets.iter().any(|t| protected(&t.key)));
    state
        .pending_edit_pastes
        .retain(|p| !protected(&p.key) && !p.before.assets.iter().any(|a| protected(&a.key)));
    if state
        .edit_clipboard
        .as_ref()
        .and_then(|c| c.source_key.as_ref())
        .is_some_and(protected)
    {
        state.edit_clipboard = None;
    }
    if let Some(trash) = &mut state.trash {
        trash
            .items
            .retain(|item| !protected(&item.asset.key) && !protected(&item.identity.key));
    }
}

impl PublishedLibrary {
    pub(crate) fn from_canonical(canonical: &SavedLibrary) -> Self {
        let access = ContentAccess::new(canonical);
        let mut state = canonical.clone();
        omit_protected_records(&mut state, &access);
        state
            .snapshots
            .iter_mut()
            .for_each(|s| s.assets.retain(|a| access.visible(&a.key)));
        for r in &mut state.receipts {
            // Aggregate signatures cannot be attributed safely to the visible
            // members of a mixed receipt. Keep its identity and workflow phase.
            if !access.receipt_visible(r) {
                r.signatures.clear();
            }
            for a in r.source.iter_mut().chain(&mut r.destination) {
                redact_asset(&access, a);
            }
        }
        for o in &mut state.pending_apple_trash {
            for a in &mut o.assets {
                redact_asset(&access, a);
            }
        }
        for u in &mut state.pending_uploads {
            if !access.visible(&u.source.key) {
                redact_upload_evidence(&mut u.resource, &mut u.signature);
            }
            redact_asset(&access, &mut u.source);
        }
        for u in &mut state.upload_intents {
            if !access.visible(&u.source.key) {
                redact_upload_evidence(&mut u.resource, &mut u.signature);
            }
            redact_asset(&access, &mut u.source);
        }
        for p in &mut state.pending_edit_pastes {
            if !access.visible(&p.key) {
                p.name = "非公開の写真".into();
                p.before.files.clear();
                p.initial_adjustment = None;
                for a in &mut p.before.assets {
                    redact_asset(&access, a);
                }
            }
        }
        for s in &mut state.albums {
            if s.access == ScanAccess::Unavailable {
                for album in &mut s.albums {
                    album.members.retain(|key| {
                        !canonical
                            .immich_visibility_operations
                            .iter()
                            .any(|o| o.key == *key)
                    });
                }
            }
            s.albums
                .iter_mut()
                .for_each(|a| a.members.retain(|k| access.visible(k)));
        }
        if let Some(c) = &mut state.edit_clipboard
            && c.source_key.as_ref().is_none_or(|k| !access.visible(k))
        {
            c.source_name = "非公開の写真".into();
        }
        Self {
            apple_visibility_operations: state
                .apple_visibility_operations
                .iter()
                .map(|operation| operation.summary_with_history(&state.apple_visibility_operations))
                .collect(),
            edit_clipboard: state.edit_clipboard,
            pending_edit_pastes: state.pending_edit_pastes,
            schema_version: state.schema_version,
            apple_scope: state.apple_scope,
            connection: state.connection,
            snapshots: state.snapshots,
            receipts: state.receipts,
            albums: state.albums,
            pending_uploads: state.pending_uploads,
            upload_intents: state.upload_intents,
            trash: state.trash,
            pending_trash: state.pending_trash,
            pending_apple_trash: state.pending_apple_trash,
        }
    }
}

fn redact_upload_evidence(resource: &mut PhotoResource, signature: &mut FileSignature) {
    resource.id.clear();
    resource.name = "非公開の写真".into();
    resource.role = ResourceRole::Image;
    resource.sha1 = None;
    resource.bytes = None;
    // This deliberately invalid placeholder belongs only to PublishedLibrary;
    // all reconciliation and mutation authorization use the canonical proof.
    signature.sha256.clear();
    signature.bytes = 0;
}

fn redact_asset(access: &ContentAccess, asset: &mut StoredAsset) {
    if access.visible(&asset.key) {
        return;
    }
    asset.apple_visibility = if access.hidden.contains(&asset.key) {
        crate::domain::AppleVisibility::Hidden
    } else {
        crate::domain::AppleVisibility::Unknown
    };
    asset.name = "非公開の写真".into();
    asset.revision.clear();
    asset.resources.clear();
    asset.captured_at = None;
    asset.modified_at = None;
    asset.latitude = None;
    asset.longitude = None;
    asset.is_favorite = false;
    asset.inventory_complete = false;
    asset.deletion_blockers = vec!["可視性を確認できない写真です。".into()];
}

/// Remove sensitive tokens from stale operation text without losing generic recovery guidance.
pub(crate) fn public_text(state: &SavedLibrary, text: &str) -> String {
    let access = ContentAccess::new(state);
    let mut result = text.to_owned();
    for asset in state.recorded_assets().filter(|a| !access.visible(&a.key)) {
        for token in std::iter::once(asset.name.as_str())
            .chain(std::iter::once(asset.revision.as_str()))
            .chain(asset.resources.iter().map(|r| r.name.as_str()))
        {
            if !token.is_empty() {
                result = result.replace(token, "非公開の写真");
            }
        }
        for token in [asset.latitude, asset.longitude]
            .into_iter()
            .flatten()
            .map(|v| v.to_string())
        {
            result = result.replace(&token, "非公開");
        }
    }
    if let Some(clipboard) = &state.edit_clipboard
        && clipboard
            .source_key
            .as_ref()
            .is_none_or(|key| !access.visible(key))
        && !clipboard.source_name.is_empty()
    {
        result = result.replace(&clipboard.source_name, "非公開の写真");
    }
    for paste in &state.pending_edit_pastes {
        if !access.visible(&paste.key) {
            for file in &paste.before.files {
                if !file.path.is_empty() {
                    result = result.replace(&file.path, "非公開のファイル");
                }
            }
        }
    }
    result
}

pub(crate) fn public_asset_name(state: &SavedLibrary, asset: &StoredAsset) -> String {
    if state.apple_content_visible(&asset.key) {
        asset.name.clone()
    } else {
        "非公開の写真".into()
    }
}
pub(crate) fn public_clipboard_name(
    state: &SavedLibrary,
    clipboard: &crate::editing::EditClipboard,
) -> String {
    if clipboard
        .source_key
        .as_ref()
        .is_some_and(|key| state.apple_content_visible(key))
    {
        clipboard.source_name.clone()
    } else {
        "非公開の写真".into()
    }
}
