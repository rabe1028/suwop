//! Presentation grouping is deliberately separate from checksum/receipt identity.
//! These hints never authorize transfers, deletion, or verified presence.
use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    ImmichStackState, LibrarySnapshot, Presence, Provider, ResourceRole, ScanAccess, StoredAsset,
    TransferReceipt, UnifiedPhoto, catalog, normalize_sha1,
};

fn root(parent: &[usize], mut i: usize) -> usize {
    while parent[i] != i {
        i = parent[i];
    }
    i
}
fn join(parent: &mut [usize], a: usize, b: usize) {
    let (a, b) = (root(parent, a), root(parent, b));
    parent[a.max(b)] = a.min(b);
}

/// Group explicit stacks and unambiguous, same-name originals at the exact capture
/// instant. Never match just a basename, day, or nearby timestamp (bursts/reused names).
#[must_use]
pub fn photos(snapshots: &[LibrarySnapshot], receipts: &[TransferReceipt]) -> Vec<UnifiedPhoto> {
    let photos = catalog(snapshots, receipts);
    let mut parent: Vec<_> = (0..photos.len()).collect();
    let current: BTreeSet<_> = snapshots
        .iter()
        .filter(|s| s.access != ScanAccess::Unavailable)
        .map(|s| (s.provider, s.scope.as_str()))
        .collect();
    join_stacks(&photos, &current, &mut parent);
    let mut candidates: BTreeMap<_, BTreeMap<Provider, BTreeSet<usize>>> = BTreeMap::new();
    for (i, photo) in photos.iter().enumerate() {
        for asset in &photo.assets {
            let Some(date) = asset.captured_at.filter(|d| d.is_finite()) else {
                continue;
            };
            if asset.is_offline
                || !current.contains(&(asset.key.provider, asset.key.scope.as_str()))
            {
                continue;
            }
            for r in asset
                .originals()
                .filter(|r| matches!(r.role, ResourceRole::Image | ResourceRole::RawImage))
            {
                let name = r.name.to_lowercase();
                if name.is_empty() {
                    continue;
                }
                let role = r.role == ResourceRole::RawImage;
                candidates
                    .entry((name, date.to_bits(), role))
                    .or_default()
                    .entry(asset.key.provider)
                    .or_default()
                    .insert(root(&parent, i));
            }
        }
    }
    let mut hashes: BTreeMap<usize, BTreeMap<(String, bool), BTreeSet<String>>> = BTreeMap::new();
    for (i, photo) in photos.iter().enumerate() {
        let inventory = hashes.entry(root(&parent, i)).or_default();
        for resource in photo.assets.iter().flat_map(StoredAsset::originals) {
            if let Some(hash) = normalize_sha1(resource.sha1.as_deref()) {
                inventory
                    .entry((
                        resource.name.to_lowercase(),
                        resource.role == ResourceRole::RawImage,
                    ))
                    .or_default()
                    .insert(hash);
            }
        }
    }
    // Compute all candidates before joining: a duplicate in one library remains
    // ambiguous, instead of becoming unique as earlier candidates are merged.
    for providers in candidates.values() {
        let (Some(a), Some(b)) = (
            providers.get(&Provider::Apple),
            providers.get(&Provider::Immich),
        ) else {
            continue;
        };
        if a.len() != 1 || b.len() != 1 {
            continue;
        }
        let (Some(&a), Some(&b)) = (a.first(), b.first()) else {
            continue;
        };
        let left = root(&parent, a);
        let right = root(&parent, b);
        if left == right {
            continue;
        }
        let conflict = hashes.get(&left).is_some_and(|a| {
            hashes.get(&right).is_some_and(|b| {
                a.iter()
                    .any(|(key, values)| b.get(key).is_some_and(|other| values != other))
            })
        });
        if !conflict {
            join(&mut parent, left, right);
            let removed = hashes.remove(&left.max(right)).unwrap_or_default();
            let kept = hashes.entry(left.min(right)).or_default();
            for (key, values) in removed {
                kept.entry(key).or_default().extend(values);
            }
        }
    }
    let mut groups: BTreeMap<usize, UnifiedPhoto> = BTreeMap::new();
    for (i, photo) in photos.into_iter().enumerate() {
        let key = root(&parent, i);
        if let Some(group) = groups.get_mut(&key) {
            group.assets.extend(photo.assets);
            group.presence = Presence::Unverified;
        } else {
            groups.insert(key, photo);
        }
    }
    groups.into_values().collect()
}

fn join_stacks(
    photos: &[UnifiedPhoto],
    current: &BTreeSet<(Provider, &str)>,
    parent: &mut [usize],
) {
    let mut stacks: BTreeMap<_, Vec<_>> = BTreeMap::new();
    for (i, photo) in photos.iter().enumerate() {
        for asset in &photo.assets {
            if asset.key.provider == Provider::Immich
                && asset.immich_stack == ImmichStackState::Stacked
                && !asset.is_offline
                && current.contains(&(asset.key.provider, asset.key.scope.as_str()))
                && let Some(stack) = &asset.immich_stack_membership
            {
                stacks
                    .entry((&asset.key.scope, &stack.id))
                    .or_default()
                    .push((i, stack));
            }
        }
    }
    for members in stacks.values() {
        let (first, info) = members[0];
        // Contradictory inventory does not establish a grouping. Missing private
        // members are never fetched or surfaced through the stack relationship.
        if members.iter().all(|(_, s)| *s == info) {
            for (i, _) in members {
                join(parent, first, *i);
            }
        }
    }
}
