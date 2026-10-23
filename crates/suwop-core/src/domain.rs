use std::collections::{BTreeMap, BTreeSet};

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    Apple,
    Immich,
    Amazon,
}

impl Provider {
    #[must_use]
    pub fn other(self) -> Self {
        match self {
            Self::Apple => Self::Immich,
            Self::Immich | Self::Amazon => Self::Apple,
        }
    }
}

#[derive(
    Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub struct AssetKey {
    pub provider: Provider,
    pub scope: String,
    #[serde(rename = "assetID")]
    pub asset_id: String,
}
impl AssetKey {
    #[must_use]
    pub fn id(&self) -> String {
        format!("{:?}|{}|{}", self.provider, self.scope, self.asset_id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ResourceRole {
    Image,
    RawImage,
    Video,
    LiveVideo,
    Auxiliary,
}
impl ResourceRole {
    #[must_use]
    pub fn is_original(self) -> bool {
        self != Self::Auxiliary
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PhotoResource {
    pub id: String,
    pub name: String,
    pub role: ResourceRole,
    pub sha1: Option<String>,
    pub bytes: Option<u64>,
}

/// Apple physical-asset visibility is independent of content revision evidence.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum AppleVisibility {
    #[default]
    Unknown,
    Visible,
    Hidden,
}

/// Fresh Immich stack knowledge; legacy snapshots do not establish absence.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ImmichStackState {
    #[default]
    Unknown,
    Unstacked,
    Stacked,
}

/// Server-declared membership, used only to group already visible assets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ImmichStackMembership {
    pub id: String,
    pub primary_asset_id: String,
    pub asset_count: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StoredAsset {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub immich_visibility: Option<crate::immich_visibility::ImmichVisibility>,
    #[serde(default)]
    pub immich_stack: ImmichStackState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub immich_stack_membership: Option<ImmichStackMembership>,
    #[serde(default)]
    pub apple_visibility: AppleVisibility,
    pub key: AssetKey,
    pub name: String,
    pub captured_at: Option<f64>,
    pub modified_at: Option<f64>,
    pub revision: String,
    pub resources: Vec<PhotoResource>,
    pub is_favorite: bool,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub inventory_complete: bool,
    pub is_offline: bool,
    pub deletion_blockers: Vec<String>,
}
impl StoredAsset {
    #[must_use]
    pub fn content_visible(&self) -> bool {
        self.key.provider != Provider::Apple || self.apple_visibility == AppleVisibility::Visible
    }

    /// Visibility authorizes current reads, but is not part of persisted original evidence.
    #[must_use]
    pub fn same_content_evidence(&self, other: &Self) -> bool {
        let mut evidence = self.clone();
        evidence.apple_visibility = other.apple_visibility;
        evidence.immich_visibility = other.immich_visibility;
        evidence == *other
    }
    pub fn originals(&self) -> impl Iterator<Item = &PhotoResource> {
        self.resources.iter().filter(|r| r.role.is_original())
    }
    #[must_use]
    pub fn fingerprints_complete(&self) -> bool {
        !self.is_offline
            && self.inventory_complete
            && self.originals().next().is_some()
            && self
                .originals()
                .all(|r| normalize_sha1(r.sha1.as_deref()).is_some())
    }
    #[must_use]
    pub fn checksums(&self) -> BTreeSet<String> {
        self.originals()
            .filter_map(|r| normalize_sha1(r.sha1.as_deref()))
            .collect()
    }
}

#[must_use]
pub fn normalize_sha1(input: Option<&str>) -> Option<String> {
    let value = input?;
    if value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(value.to_ascii_lowercase());
    }
    let bytes = STANDARD.decode(value).ok()?;
    (bytes.len() == 20).then(|| hex(&bytes))
}
#[must_use]
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ScanAccess {
    Full,
    Limited,
    Unavailable,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySnapshot {
    pub provider: Provider,
    pub scope: String,
    pub assets: Vec<StoredAsset>,
    pub access: ScanAccess,
    pub scanned_at: Option<f64>,
}
impl LibrarySnapshot {
    #[must_use]
    pub fn completely_indexed(&self) -> bool {
        self.access == ScanAccess::Full
            && self.scanned_at.is_some()
            && self.assets.iter().all(StoredAsset::fingerprints_complete)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum Presence {
    Amazon,
    Multiple,
    Both,
    AppleOnly,
    ImmichOnly,
    Partial,
    Unverified,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UnifiedPhoto {
    pub assets: Vec<StoredAsset>,
    pub presence: Presence,
}

fn root(parent: &[usize], mut i: usize) -> usize {
    while parent[i] != i {
        i = parent[i];
    }
    i
}
fn join(parent: &mut [usize], a: usize, b: usize) {
    let x = root(parent, a);
    let y = root(parent, b);
    parent[x.max(y)] = x.min(y);
}
fn group_presence(group: &[StoredAsset], snapshots: &[LibrarySnapshot]) -> Presence {
    let current = |p| snapshot_current(snapshots, p);
    let indexed = |p| snapshot_indexed(snapshots, p);
    let apple = group.iter().any(|a| a.key.provider == Provider::Apple);
    let immich = group.iter().any(|a| a.key.provider == Provider::Immich);
    let complete = group.iter().all(StoredAsset::fingerprints_complete);
    let amazon_indexed =
        !snapshots.iter().any(|s| s.provider == Provider::Amazon) || indexed(Provider::Amazon);
    if group.iter().any(|a| a.is_offline) {
        Presence::Unverified
    } else if group.iter().any(|a| a.key.provider == Provider::Amazon) {
        let providers: BTreeSet<_> = group.iter().map(|a| a.key.provider).collect();
        if !current(Provider::Amazon) {
            Presence::Unverified
        } else if providers.len() == 1 {
            Presence::Amazon
        } else if complete
            && providers.iter().all(|p| current(*p))
            && providers
                .iter()
                .all(|p| checksum_counts(group, *p) == checksum_counts(group, Provider::Amazon))
        {
            Presence::Multiple
        } else {
            Presence::Unverified
        }
    } else if apple && immich {
        if !current(Provider::Apple) || !current(Provider::Immich) {
            Presence::Unverified
        } else if complete
            && checksum_counts(group, Provider::Apple) == checksum_counts(group, Provider::Immich)
        {
            Presence::Both
        } else {
            Presence::Partial
        }
    } else if apple
        && complete
        && current(Provider::Apple)
        && indexed(Provider::Immich)
        && amazon_indexed
    {
        Presence::AppleOnly
    } else if immich
        && complete
        && current(Provider::Immich)
        && indexed(Provider::Apple)
        && amazon_indexed
    {
        Presence::ImmichOnly
    } else {
        Presence::Unverified
    }
}

fn checksum_counts(assets: &[StoredAsset], provider: Provider) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for asset in assets.iter().filter(|a| a.key.provider == provider) {
        for checksum in asset
            .originals()
            .filter_map(|r| normalize_sha1(r.sha1.as_deref()))
        {
            *counts.entry(checksum).or_default() += 1;
        }
    }
    counts
}
fn catalog_assets(snapshots: &[LibrarySnapshot]) -> Vec<StoredAsset> {
    let mut by_key = BTreeMap::new();
    for snapshot in snapshots {
        for asset in &snapshot.assets {
            if asset.content_visible()
                && asset.key.provider == snapshot.provider
                && asset.key.scope == snapshot.scope
            {
                by_key.insert(asset.key.clone(), asset.clone());
            }
        }
    }
    by_key.into_values().collect()
}
#[must_use]
pub fn catalog(snapshots: &[LibrarySnapshot], receipts: &[TransferReceipt]) -> Vec<UnifiedPhoto> {
    let assets = catalog_assets(snapshots);
    let mut parent: Vec<_> = (0..assets.len()).collect();
    let mut owner = BTreeMap::new();
    for (i, asset) in assets.iter().enumerate() {
        for checksum in asset.checksums() {
            if let Some(&other) = owner.get(&checksum) {
                join(&mut parent, i, other);
            } else {
                owner.insert(checksum, i);
            }
        }
    }
    let indices: BTreeMap<_, _> = assets
        .iter()
        .enumerate()
        .map(|(i, a)| (&a.key, i))
        .collect();
    for receipt in receipts
        .iter()
        .filter(|r| r.phase != TransferPhase::Copying)
    {
        let valid: Vec<_> = receipt
            .source
            .iter()
            .chain(&receipt.destination)
            .filter_map(|member| {
                let i = *indices.get(&member.key)?;
                (assets[i].fingerprints_complete()
                    && !member.checksums().is_empty()
                    && assets[i].checksums() == member.checksums())
                .then_some(i)
            })
            .collect();
        if let Some(&first) = valid.first() {
            for &i in &valid {
                join(&mut parent, first, i);
            }
        }
    }
    let mut groups: BTreeMap<_, Vec<_>> = BTreeMap::new();
    for (i, asset) in assets.into_iter().enumerate() {
        groups.entry(root(&parent, i)).or_default().push(asset);
    }
    let mut photos: Vec<_> = groups
        .into_values()
        .map(|group| {
            let presence = group_presence(&group, snapshots);
            UnifiedPhoto {
                assets: group,
                presence,
            }
        })
        .collect();
    let date = |p: &UnifiedPhoto| {
        p.assets
            .iter()
            .filter_map(|a| a.captured_at)
            .max_by(f64::total_cmp)
            .unwrap_or(f64::MIN)
    };
    photos.sort_by(|a, b| {
        date(b)
            .total_cmp(&date(a))
            .then_with(|| a.assets[0].key.cmp(&b.assets[0].key))
    });
    photos
}

#[derive(
    Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub struct FileSignature {
    pub sha256: String,
    pub bytes: u64,
}
impl FileSignature {
    #[must_use]
    pub fn valid(&self) -> bool {
        self.bytes > 0
            && self.sha256.len() == 64
            && self
                .sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TransferFile {
    pub resource: PhotoResource,
    pub path: String,
    pub signature: FileSignature,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TransferBundle {
    pub assets: Vec<StoredAsset>,
    pub files: Vec<TransferFile>,
}
impl TransferBundle {
    #[must_use]
    pub fn signatures(&self) -> BTreeSet<FileSignature> {
        self.files.iter().map(|f| f.signature.clone()).collect()
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.assets.is_empty()
            || self.files.is_empty()
            || !self.assets.iter().all(StoredAsset::fingerprints_complete)
            || !self.files.iter().all(|f| {
                f.signature.valid() && normalize_sha1(f.resource.sha1.as_deref()).is_some()
            })
        {
            return Err("すべての原本を読み出せていません。元データは残します。".into());
        }
        let mut expected: Vec<_> = self
            .assets
            .iter()
            .flat_map(StoredAsset::originals)
            .filter_map(|r| normalize_sha1(r.sha1.as_deref()))
            .collect();
        let mut actual: Vec<_> = self
            .files
            .iter()
            .filter_map(|f| normalize_sha1(f.resource.sha1.as_deref()))
            .collect();
        expected.sort();
        actual.sort();
        if expected != actual {
            return Err("原本の構成と転送ファイルが一致しません。".into());
        }
        Ok(())
    }
    pub fn block_duplicates(&mut self) {
        if self.assets.len() > 1 && self.signatures().len() < self.files.len() {
            for a in &mut self.assets {
                a.deletion_blockers
                    .push("同一バイト列の独立した写真が複数あるためコピーのみ".into());
            }
        }
    }
}
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "camelCase")]
pub enum TransferIntent {
    #[default]
    Copy,
    Move,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum TransferPhase {
    Copying,
    Copied,
    DeletingSource,
    Moved,
    DeletionUncertain,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TransferReceipt {
    pub id: String,
    pub created_at: f64,
    pub phase: TransferPhase,
    #[serde(default)]
    pub intent: TransferIntent,
    pub source: Vec<StoredAsset>,
    pub destination: Vec<StoredAsset>,
    pub destination_provider: Provider,
    pub destination_scope: String,
    pub signatures: BTreeSet<FileSignature>,
}
impl TransferReceipt {
    #[must_use]
    pub fn move_blockers(&self) -> Vec<String> {
        let mut blockers: BTreeSet<_> = self
            .source
            .iter()
            .flat_map(|a| a.deletion_blockers.clone())
            .collect();
        if self.intent != TransferIntent::Move {
            blockers.insert("コピーとして開始した履歴から元を削除することはできません".into());
        }
        if self.phase != TransferPhase::Copied {
            blockers.insert("移動準備が完了していません".into());
        }
        blockers.into_iter().collect()
    }
}
pub fn allow_deletion(assets: &[StoredAsset]) -> Result<(), String> {
    if assets.is_empty()
        || !assets.iter().all(|a| {
            a.deletion_blockers.is_empty()
                && a.inventory_complete
                && !a.is_offline
                && a.resources.iter().all(|r| r.role.is_original())
        })
    {
        return Err("安全に移動できない写真です。コピーのみ利用できます。".into());
    }
    Ok(())
}
pub fn verify_source(saved: &TransferReceipt, fresh: &mut TransferBundle) -> Result<(), String> {
    if saved.intent != TransferIntent::Move
        || saved.phase != TransferPhase::Copied
        || !saved.move_blockers().is_empty()
    {
        return Err("この履歴から元データを削除できません。".into());
    }
    fresh.validate()?;
    fresh.block_duplicates();
    allow_deletion(&fresh.assets)?;
    let revisions = |assets: &[StoredAsset]| {
        assets
            .iter()
            .map(|a| {
                (
                    a.key.clone(),
                    (
                        a.revision.clone(),
                        a.latitude.map(f64::to_bits),
                        a.longitude.map(f64::to_bits),
                        a.captured_at.map(f64::to_bits),
                        a.is_favorite,
                    ),
                )
            })
            .collect::<BTreeMap<_, _>>()
    };
    if revisions(&saved.source) != revisions(&fresh.assets)
        || saved.signatures != fresh.signatures()
    {
        return Err("コピー後に転送元が変更されています。元データは残します。".into());
    }
    Ok(())
}
/// Capture instants share an inclusive one-millisecond tolerance throughout
/// upload planning, metadata readback and move verification.
pub(crate) fn same_capture_date(actual: f64, expected: f64) -> bool {
    actual.is_finite() && expected.is_finite() && (actual - expected).abs() <= 0.001
}

pub fn verify_destination(saved: &TransferReceipt, fresh: &TransferBundle) -> Result<(), String> {
    fresh.validate()?;
    let expected: BTreeSet<_> = saved.destination.iter().map(|a| &a.key).collect();
    let actual: BTreeSet<_> = fresh.assets.iter().map(|a| &a.key).collect();
    if expected != actual || !saved.signatures.is_subset(&fresh.signatures()) {
        return Err("転送先の原本を再確認できません。元データは残します。".into());
    }
    // Library-level location must survive a move, including an explicit absence.
    if saved.intent == TransferIntent::Move {
        let Some(source) = saved.source.first() else {
            return Err("転送元がありません。".into());
        };
        if fresh.assets.iter().any(|a| !same_location(source, a)) {
            return Err("転送先の位置情報が一致しません。元データは残します。".into());
        }
        if fresh.assets.iter().any(|a| {
            a.is_favorite != source.is_favorite
                || !match (source.captured_at, a.captured_at) {
                    (Some(date), Some(target)) => same_capture_date(date, target),
                    (None, None) => true,
                    _ => false,
                }
        }) {
            return Err(
                "転送先の撮影日時またはお気に入りが一致しません。元データは残します。".into(),
            );
        }
    }
    Ok(())
}
#[must_use]
pub fn same_location(a: &StoredAsset, b: &StoredAsset) -> bool {
    let near = |x: Option<f64>, y: Option<f64>| match (x, y) {
        (Some(x), Some(y)) => x.is_finite() && y.is_finite() && (x - y).abs() < 0.000_001,
        (None, None) => true,
        _ => false,
    };
    near(a.latitude, b.latitude) && near(a.longitude, b.longitude)
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
// These independent flags mirror PhotoKit facts, not domain state.
#[allow(clippy::struct_excessive_bools)]
pub struct AppleFacts {
    pub asset: StoredAsset,
    pub full_access: bool,
    pub can_delete: bool,
    pub burst: bool,
    pub shared: bool,
    pub live: bool,
}
#[must_use]
pub fn describe_apple(mut facts: AppleFacts) -> StoredAsset {
    let a = &mut facts.asset;
    for resource in &mut a.resources {
        resource.sha1 = normalize_sha1(resource.sha1.as_deref());
    }
    a.deletion_blockers.clear();
    for (blocked, reason) in [
        (!facts.full_access, "写真へのアクセスが制限されています"),
        (!facts.can_delete, "この写真は削除できません"),
        (facts.burst, "バースト写真はコピーのみ"),
        (facts.shared, "共有アルバムの写真はコピーのみ"),
        (facts.live, "Live Photo は関連情報保護のためコピーのみ"),
        (
            a.resources.iter().any(|r| !r.role.is_original()),
            "編集・補助データがあるためコピーのみ",
        ),
    ] {
        if blocked {
            a.deletion_blockers.push(reason.into());
        }
    }
    let complete = a.originals().next().is_some();
    a.inventory_complete = complete;
    facts.asset
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleImportEntry {
    pub file: TransferFile,
    pub kind: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AppleImportPlan {
    pub entries: Vec<AppleImportEntry>,
    pub metadata: StoredAsset,
}
pub fn apple_import_plan(bundle: &TransferBundle) -> Result<AppleImportPlan, String> {
    bundle.validate()?;
    let mut seen = BTreeSet::new();
    let files: Vec<_> = bundle
        .files
        .iter()
        .filter(|f| seen.insert(f.signature.clone()))
        .collect();
    let image = files
        .iter()
        .filter(|f| f.resource.role == ResourceRole::Image)
        .count();
    let raw = files
        .iter()
        .filter(|f| f.resource.role == ResourceRole::RawImage)
        .count();
    let live = files
        .iter()
        .filter(|f| f.resource.role == ResourceRole::LiveVideo)
        .count();
    let paired = files.len() == 2 && image == 1 && (raw == 1 || live == 1);
    if !(files.len() == 1 && files[0].resource.role != ResourceRole::LiveVideo || paired) {
        return Err(
            "この原本の組み合わせは Apple Photos に追加できません。元データは残します。".into(),
        );
    }
    let entries = files
        .into_iter()
        .map(|f| AppleImportEntry {
            file: f.clone(),
            kind: match f.resource.role {
                ResourceRole::Video => "video",
                ResourceRole::LiveVideo => "pairedVideo",
                ResourceRole::RawImage if paired => "alternatePhoto",
                _ => "photo",
            }
            .into(),
        })
        .collect();
    let mut metadata = bundle.assets[0].clone();
    metadata.is_favorite = bundle.assets.iter().any(|a| a.is_favorite);
    Ok(AppleImportPlan { entries, metadata })
}

fn snapshot_current(snapshots: &[LibrarySnapshot], provider: Provider) -> bool {
    let matching: Vec<_> = snapshots
        .iter()
        .filter(|s| s.provider == provider)
        .collect();
    !matching.is_empty()
        && matching
            .iter()
            .all(|s| s.access != ScanAccess::Unavailable && s.scanned_at.is_some())
}
fn snapshot_indexed(snapshots: &[LibrarySnapshot], provider: Provider) -> bool {
    let matching: Vec<_> = snapshots
        .iter()
        .filter(|s| s.provider == provider)
        .collect();
    !matching.is_empty() && matching.iter().all(|s| s.completely_indexed())
}
