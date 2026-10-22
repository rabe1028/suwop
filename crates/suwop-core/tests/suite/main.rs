//! Offline integration tests share one binary: each former `tests/*.rs` file
//! is a module here, so the library and its generics are linked once.
//! `immich_live` stays a separate target because it needs a live server.

mod albums;
mod albums_contract;
mod app_protection;
mod apple_trash;
mod apple_visibility;
mod browser;
mod browser_dates;
mod browser_live;
mod current_render_plan;
mod current_sharing;
mod domain;
mod edit_clipboard;
mod edit_paste_workflow;
mod editing;
mod editing_apple;
mod editing_color;
mod editing_workflow;
mod favorites;
mod immich_archive;
mod immich_contract;
mod immich_locked;
mod immich_visibility;
mod media;
mod metadata;
mod preview;
mod privacy;
mod reversion;
mod sharing;
mod trash;
mod upload_dates;
mod workflow;
