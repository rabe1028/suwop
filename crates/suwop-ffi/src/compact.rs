//! Compact transport for the full library view (action 18).
//!
//! The view carries each published `StoredAsset` once in `state.snapshots` and again in
//! `photos`. This wire form sends every distinct asset once and replaces both copies with
//! table indexes. It is a lossless re-encoding of `ViewModel`: the same projection is built,
//! nothing is filtered or decided here, and the shell only substitutes indexes back.
use serde::Serialize;
use std::collections::BTreeMap;
use suwop_core::{
    app::ViewModel,
    domain::{AssetKey, StoredAsset},
};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactLibrary {
    /// Distinct assets, in first-occurrence order (snapshots first, then photos).
    pub assets: Vec<StoredAsset>,
    /// `snapshot_assets[i]` lists table indexes for `view.state.snapshots[i].assets`.
    pub snapshot_assets: Vec<Vec<usize>>,
    /// `photo_assets[i]` lists table indexes for `view.photos[i].assets`.
    pub photo_assets: Vec<Vec<usize>>,
    /// The full view with those two asset arrays emptied; every other field is unchanged.
    pub view: ViewModel,
}

/// Two copies may share an entry only when they serialize identically. `PartialEq`
/// already rejects NaN; the bit comparison also keeps `-0.0` and `0.0` distinct.
fn identical(a: &StoredAsset, b: &StoredAsset) -> bool {
    let bits = |asset: &StoredAsset| {
        [
            asset.captured_at,
            asset.modified_at,
            asset.latitude,
            asset.longitude,
        ]
        .map(|value| value.map(f64::to_bits))
    };
    a == b && bits(a) == bits(b)
}

#[derive(Default)]
struct Table {
    assets: Vec<StoredAsset>,
    by_key: BTreeMap<AssetKey, Vec<usize>>,
}
impl Table {
    fn intern(&mut self, asset: StoredAsset) -> usize {
        let candidates = self.by_key.entry(asset.key.clone()).or_default();
        if let Some(&index) = candidates
            .iter()
            .find(|&&index| identical(&self.assets[index], &asset))
        {
            return index;
        }
        let index = self.assets.len();
        candidates.push(index);
        self.assets.push(asset);
        index
    }
    fn take(&mut self, assets: &mut Vec<StoredAsset>) -> Vec<usize> {
        std::mem::take(assets)
            .into_iter()
            .map(|asset| self.intern(asset))
            .collect()
    }
}

impl CompactLibrary {
    #[must_use]
    pub fn new(mut view: ViewModel) -> Self {
        let mut table = Table::default();
        let snapshot_assets = view
            .state
            .snapshots
            .iter_mut()
            .map(|snapshot| table.take(&mut snapshot.assets))
            .collect();
        let photo_assets = view
            .photos
            .iter_mut()
            .map(|photo| table.take(&mut photo.assets))
            .collect();
        Self {
            assets: table.assets,
            snapshot_assets,
            photo_assets,
            view,
        }
    }

    /// Inverse used by tests to prove the encoding is lossless.
    #[cfg(test)]
    pub fn expand(self) -> Result<ViewModel, String> {
        let Self {
            assets,
            snapshot_assets,
            photo_assets,
            mut view,
        } = self;
        let resolve = |indexes: Vec<usize>| -> Result<Vec<StoredAsset>, String> {
            indexes
                .into_iter()
                .map(|i| assets.get(i).cloned().ok_or_else(|| "index".to_owned()))
                .collect()
        };
        if snapshot_assets.len() != view.state.snapshots.len()
            || photo_assets.len() != view.photos.len()
        {
            return Err("shape".into());
        }
        for (snapshot, indexes) in view.state.snapshots.iter_mut().zip(snapshot_assets) {
            snapshot.assets = resolve(indexes)?;
        }
        for (photo, indexes) in view.photos.iter_mut().zip(photo_assets) {
            photo.assets = resolve(indexes)?;
        }
        Ok(view)
    }
}
