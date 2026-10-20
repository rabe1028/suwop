//! Select a fresh, small authority projection without constructing the gallery.
use crux_core::{App, Command};
use std::sync::{Arc, Mutex};
use suwop_core::{
    app::{Event, Model, Suwop, ViewModel},
    domain::AssetKey,
};

pub type Query = Arc<Mutex<Option<Vec<AssetKey>>>>;
pub struct ProjectionApp(pub Query);
#[derive(serde::Serialize)]
#[serde(untagged)]
pub enum Projection {
    Unavailable,
    Library(Box<ViewModel>),
    Ordinary {
        keys: Vec<AssetKey>,
        revision: String,
    },
}
impl App for ProjectionApp {
    type Event = Event;
    type Model = Model;
    type Effect = <Suwop as App>::Effect;
    type ViewModel = Projection;
    fn update(&self, event: Event, model: &mut Model) -> Command<Self::Effect, Event> {
        Suwop.update(event, model)
    }
    fn view(&self, model: &Model) -> Projection {
        let Ok(query) = self.0.lock() else {
            // A poisoned selector grants no authority and cannot decode as a library.
            return Projection::Unavailable;
        };
        match query.as_ref() {
            Some(keys) => {
                let (keys, revision) = Suwop::ordinary_content_projection(model, keys);
                Projection::Ordinary { keys, revision }
            }
            None => Projection::Library(Box::new(Suwop.view(model))),
        }
    }
}
