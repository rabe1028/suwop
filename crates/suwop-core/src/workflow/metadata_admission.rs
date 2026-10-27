use crate::{
    app::{Event, SavedLibrary},
    domain::AssetKey,
};

pub(super) fn blocked(event: &Event, state: &SavedLibrary) -> bool {
    let keys: Vec<AssetKey> = match event {
        Event::SetFavorite { keys, .. }
        | Event::SetMetadata { keys, .. }
        | Event::EditMetadata { keys, .. }
        | Event::Copy { keys, .. }
        | Event::CopyTo { keys, .. }
        | Event::Duplicate { keys, .. }
        | Event::TrashApple { keys, .. }
        | Event::ChangeTrash { keys, .. }
        | Event::HideApple { keys, .. }
        | Event::PastePhotoEdits { keys, .. } => keys.clone(),
        Event::EditCollection { edit, .. } => edit.photos.clone(),
        Event::PrepareImmichLivePlacement { parents, .. } => parents.clone(),
        Event::PrepareImmichLiveResourcePlacements {
            parents,
            destinations,
            ..
        } => parents
            .iter()
            .cloned()
            .chain(
                destinations
                    .iter()
                    .map(|destination| destination.key.clone()),
            )
            .collect(),
        Event::PasteSelectedPhotoEdits { anchors, .. } => anchors.clone(),
        Event::EditImage { key, .. }
        | Event::RevertImage { key, .. }
        | Event::ResolveEditPaste { key, .. } => vec![key.clone()],
        Event::CompleteMove { id, .. } => state
            .receipts
            .iter()
            .filter(|r| r.id == *id)
            .flat_map(|r| r.source.iter().chain(&r.destination))
            .map(|asset| asset.key.clone())
            .collect(),
        Event::RestoreMetadata { operation_id, .. } => state
            .metadata_operations
            .iter()
            .filter(|record| record.id == *operation_id)
            .flat_map(|record| record.keys.clone())
            .collect(),
        _ => Vec::new(),
    };
    keys.iter()
        .any(|key| state.metadata_intent_holds.contains(key))
        || crate::metadata::blocked(&keys, &state.metadata_operations)
}
