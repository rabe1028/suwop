//! Select a fresh, small authority projection without constructing the gallery.
use crux_core::{App, Command};
use std::{
    collections::BTreeSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};
use suwop_core::{
    app::{Event, Model, Suwop, ViewModel},
    domain::AssetKey,
    immich_live_writes::{PairImagePhase, PairImageTicket, ordinary_live_image_ticket_issued},
};

pub enum Selection {
    Ordinary(Vec<AssetKey>),
    /// Exact private paired raster ticket. Answers only issued/not issued.
    PairImage(Box<PairImageTicket>, PairImagePhase),
    Progress,
    /// The full library view, re-encoded with a shared asset table.
    Compact,
}
pub type Query = Arc<Mutex<Option<Selection>>>;
pub struct ProjectionApp {
    query: Query,
    membership: Mutex<Option<Membership>>,
    view_version: AtomicU64,
}
struct Membership {
    generation: u64,
    keys: BTreeSet<AssetKey>,
    revision: String,
}
impl ProjectionApp {
    pub fn new(query: Query) -> Self {
        Self {
            query,
            membership: Mutex::new(None),
            view_version: AtomicU64::new(0),
        }
    }
}

#[derive(serde::Serialize)]
#[serde(untagged)]
pub enum Projection {
    Unavailable,
    Progress {
        version: String,
        progress: Option<String>,
    },
    Library(Box<ViewModel>),
    Compact(Box<crate::compact::CompactLibrary>),
    Ordinary {
        keys: Vec<AssetKey>,
        revision: String,
    },
    PairImage {
        issued: bool,
    },
}
impl App for ProjectionApp {
    type Event = Event;
    type Model = Model;
    type Effect = <Suwop as App>::Effect;
    type ViewModel = Projection;
    fn update(&self, event: Event, model: &mut Model) -> Command<Self::Effect, Event> {
        if matches!(event, Event::FetchProgress { .. }) {
            return Suwop.update(event, model);
        }
        self.view_version.fetch_add(1, Ordering::SeqCst);
        // Every catalog/authority event invalidates the index. Count-only progress does not.
        // A poisoned cache remains unavailable rather than granting stale reads.
        if let Ok(mut cache) = self.membership.lock() {
            *cache = None;
        }
        Suwop.update(event, model)
    }
    fn view(&self, model: &Model) -> Projection {
        let Ok(query) = self.query.lock() else {
            // A poisoned selector grants no authority and cannot decode as a library.
            return Projection::Unavailable;
        };
        match query.as_ref() {
            Some(Selection::Progress) => Projection::Progress {
                // Async revocation can happen without a model event.
                version: format!(
                    "{}:{}:{}:{}:{}:{}",
                    self.view_version.load(Ordering::SeqCst),
                    model.ordinary_generation.load(Ordering::SeqCst),
                    model.apple_generation.load(Ordering::SeqCst),
                    model.protection.generation.load(Ordering::SeqCst),
                    model.immich_locked.generation.load(Ordering::SeqCst),
                    model.immich_archive.generation.load(Ordering::SeqCst)
                ),
                progress: model.fetch_status.clone(),
            },
            Some(Selection::Ordinary(keys)) => {
                let Ok(mut cache) = self.membership.lock() else {
                    return Projection::Unavailable;
                };
                // Async effects can revoke generation without a Crux event. Read
                // the Rust atomic on every query; never cache a clock-based grant.
                let generation = model.ordinary_generation.load(Ordering::SeqCst);
                if cache
                    .as_ref()
                    .is_none_or(|entry| entry.generation != generation)
                {
                    let (keys, revision) = Suwop::ordinary_content_membership(model);
                    *cache = Some(Membership {
                        generation,
                        keys: keys.into_iter().collect(),
                        revision,
                    });
                }
                let Some(entry) = cache.as_ref() else {
                    return Projection::Unavailable;
                };
                if model.ordinary_generation.load(Ordering::SeqCst) != entry.generation {
                    return Projection::Unavailable;
                }
                Projection::Ordinary {
                    keys: keys
                        .iter()
                        .filter(|key| entry.keys.contains(*key))
                        .cloned()
                        .collect(),
                    revision: entry.revision.clone(),
                }
            }
            Some(Selection::PairImage(ticket, phase)) => Projection::PairImage {
                issued: ordinary_live_image_ticket_issued(model, ticket, *phase),
            },
            Some(Selection::Compact) => Projection::Compact(Box::new(
                crate::compact::CompactLibrary::new(Suwop.view(model)),
            )),
            None => Projection::Library(Box::new(Suwop.view(model))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use suwop_core::domain::{
        AppleVisibility, ImmichStackState, LibrarySnapshot, Provider, ScanAccess, StoredAsset,
    };

    #[test]
    fn progress_does_not_invalidate_catalog_but_catalog_events_do() -> Result<(), String> {
        let app = ProjectionApp::new(Arc::new(Mutex::new(Some(Selection::Progress))));
        let mut model = Model::default();
        let _ = app.update(
            Event::FetchProgress {
                status: "8 / 19".into(),
            },
            &mut model,
        );
        let Projection::Progress { version, progress } = app.view(&model) else {
            return Err("progress missing".into());
        };
        assert_eq!(version, "0:0:0:0:0:0");
        assert_eq!(progress.as_deref(), Some("8 / 19"));
        let _ = app.update(Event::AppleChanged, &mut model);
        let Projection::Progress { version, .. } = app.view(&model) else {
            return Err("progress missing".into());
        };
        assert!(version.starts_with("1:"));
        model.ordinary_generation.fetch_add(1, Ordering::SeqCst);
        let Projection::Progress {
            version: revoked, ..
        } = app.view(&model)
        else {
            return Err("progress missing".into());
        };
        assert_ne!(version, revoked);
        Ok(())
    }

    #[test]
    fn cached_membership_observes_async_revocation_and_every_model_update() -> Result<(), String> {
        let key = AssetKey {
            provider: Provider::Apple,
            scope: "apple".into(),
            asset_id: "photo".into(),
        };
        let asset = StoredAsset {
            key: key.clone(),
            name: "photo.jpg".into(),
            revision: "1".into(),
            apple_visibility: AppleVisibility::Visible,
            immich_visibility: None,
            immich_stack: ImmichStackState::Unknown,
            immich_stack_membership: None,
            captured_at: None,
            modified_at: None,
            resources: vec![],
            is_favorite: false,
            latitude: None,
            longitude: None,
            inventory_complete: false,
            is_offline: false,
            deletion_blockers: vec![],
        };
        let mut model = Model::default();
        model.state.apple_scope = "apple".into();
        model.state.snapshots = vec![LibrarySnapshot {
            provider: Provider::Apple,
            scope: "apple".into(),
            assets: vec![asset],
            access: ScanAccess::Full,
            scanned_at: None,
        }];
        let app = ProjectionApp::new(Arc::new(Mutex::new(Some(Selection::Ordinary(vec![
            key.clone(),
        ])))));
        let Projection::Ordinary { keys, revision } = app.view(&model) else {
            return Err("missing authority".into());
        };
        assert_eq!(keys, vec![key]);
        // Repeated reads use the same authority, never a clock-sensitive private view.
        let Projection::Ordinary {
            revision: repeated, ..
        } = app.view(&model)
        else {
            return Err("missing authority".into());
        };
        assert_eq!(revision, repeated);
        model.ordinary_generation.fetch_add(1, Ordering::SeqCst);
        let Projection::Ordinary {
            revision: revoked, ..
        } = app.view(&model)
        else {
            return Err("missing authority".into());
        };
        assert_ne!(revision, revoked);
        // Even a model update without another generation bump invalidates the index.
        model.state.snapshots[0].access = ScanAccess::Unavailable;
        let before_update = model.ordinary_generation.load(Ordering::SeqCst);
        let _ = app.update(
            Event::Browse {
                options: suwop_core::browser::BrowserOptions::default(),
            },
            &mut model,
        );
        assert_eq!(
            model.ordinary_generation.load(Ordering::SeqCst),
            before_update
        );
        let Projection::Ordinary { keys, .. } = app.view(&model) else {
            return Err("missing authority".into());
        };
        assert!(keys.is_empty());
        Ok(())
    }

    #[test]
    fn pair_image_query_answers_only_issued_and_rejects_unissued_ticket() -> Result<(), String> {
        let ticket: PairImageTicket = serde_json::from_value(serde_json::json!({
            "ownerID": "never-issued:1",
            "requestID": "00000001-0000-4000-8000-000000000000",
            "sceneID": "00000002-0000-4000-8000-000000000000",
            "presentation": {
                "parentKey": {"provider": "immich", "scope": "s", "assetID": "a"},
                "motionKey": {"provider": "immich", "scope": "s", "assetID": "b"},
                "proofID": "p",
                "generation": 1,
                "parentVisibility": "timeline",
                "motionVisibility": "hidden"
            },
            "kind": "thumbnail",
            "expectedRevision": "r",
            "request": {"url": "https://fixture.invalid/api", "method": "GET", "headers": {},
                "body": null, "fields": {}, "files": [], "downloadPath": null}
        }))
        .map_err(|e| e.to_string())?;
        let app = ProjectionApp::new(Arc::new(Mutex::new(Some(Selection::PairImage(
            Box::new(ticket),
            PairImagePhase::Read,
        )))));
        let encoded =
            serde_json::to_value(app.view(&Model::default())).map_err(|e| e.to_string())?;
        assert_eq!(encoded, serde_json::json!({"issued": false}));
        Ok(())
    }
}
