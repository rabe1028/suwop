use super::Runtime;
use crate::domain::{AssetKey, StoredAsset, TransferPhase, TransferReceipt};

/// A source key whose deletion may already have been issued by any receipt
/// (`DeletingSource` or `DeletionUncertain`) is never deleted again, by that
/// receipt or another one. Keys compare in full, so other providers and
/// accounts are unaffected. `Moved` is certain and fences nothing. The fence
/// is never cleared automatically.
pub(super) fn uncertain_source_fence(
    receipts: &[TransferReceipt],
    keys: &[AssetKey],
) -> Result<(), String> {
    if receipts
        .iter()
        .filter(|r| {
            matches!(
                r.phase,
                TransferPhase::DeletingSource | TransferPhase::DeletionUncertain
            )
        })
        .flat_map(|r| &r.source)
        .any(|asset| keys.contains(&asset.key))
    {
        return Err(
            "この写真には削除結果を確認できない移動があります。自動では削除しません。転送元を確認してください。"
                .into(),
        );
    }
    Ok(())
}

impl Runtime<'_> {
    pub(super) fn check_transfer_trash(&self, assets: &[StoredAsset]) -> Result<(), String> {
        self.check_transfer_apple_trash(assets)?;
        self.check_visibility_keys(&assets.iter().map(|a| a.key.clone()).collect::<Vec<_>>())?;
        let Some(session) = &self.session else {
            return Ok(());
        };
        for operation in &self.state.pending_trash {
            if operation.scope != session.scope {
                continue;
            }
            for asset in assets {
                let checksums = asset.checksums();
                if operation.assets.iter().any(|pending| {
                    pending.key == asset.key || checksums.contains(&pending.checksum)
                }) {
                    return Err(
                        "同じ原本のゴミ箱操作の結果を先に確認してください。転送は開始しません。"
                            .into(),
                    );
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Provider, TransferIntent};

    fn key(scope: &str) -> AssetKey {
        AssetKey {
            provider: Provider::Immich,
            scope: scope.into(),
            asset_id: "same".into(),
        }
    }

    fn receipt(phase: TransferPhase, source: &AssetKey) -> Result<TransferReceipt, String> {
        let mut receipt: TransferReceipt = serde_json::from_value(serde_json::json!({
            "id": "earlier", "createdAt": 1.0, "phase": phase, "intent": TransferIntent::Move,
            "source": [], "destination": [], "destinationProvider": "apple",
            "destinationScope": "apple", "signatures": []
        }))
        .map_err(|e| e.to_string())?;
        let asset = serde_json::json!({
            "key": source, "name": "photo.jpg", "capturedAt": null, "modifiedAt": null,
            "revision": "r", "resources": [], "isFavorite": false, "latitude": null,
            "longitude": null, "inventoryComplete": true, "isOffline": false,
            "deletionBlockers": []
        });
        receipt
            .source
            .push(serde_json::from_value(asset).map_err(|e| e.to_string())?);
        Ok(receipt)
    }

    #[test]
    fn only_possibly_issued_deletions_fence_the_exact_source_key() -> Result<(), String> {
        let fenced = key("remote");
        for phase in [
            TransferPhase::DeletingSource,
            TransferPhase::DeletionUncertain,
        ] {
            let receipts = [receipt(phase, &fenced)?];
            assert!(uncertain_source_fence(&receipts, std::slice::from_ref(&fenced)).is_err());
            // Another account with the same asset ID is independent.
            assert!(uncertain_source_fence(&receipts, &[key("another-account")]).is_ok());
        }
        for phase in [
            TransferPhase::Copying,
            TransferPhase::Copied,
            TransferPhase::Moved,
        ] {
            let receipts = [receipt(phase, &fenced)?];
            assert!(uncertain_source_fence(&receipts, std::slice::from_ref(&fenced)).is_ok());
        }
        Ok(())
    }
}
