//! Local metadata transactions and a separately scheduled, rebuildable Lance index.
mod api;
mod catalog;
mod engine;
mod inference;
mod inference_jobs;
mod jobs;
mod worker;

pub use api::{Command, Request, dispatch};
pub use catalog::Store;
pub use worker::wake;

use sha2::{Digest, Sha256};
pub type Result<T> = std::result::Result<T, String>;
fn error(value: impl std::fmt::Display) -> String {
    value.to_string()
}
fn digest(value: impl AsRef<[u8]>) -> String {
    suwop_core::domain::hex(&Sha256::digest(value.as_ref()))
}
