//! Native workers retire when idle. Wake delivery and retirement share one lock.
use crate::{Result, Store, error};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock, mpsc},
    time::Duration,
};
type Workers = BTreeMap<PathBuf, mpsc::SyncSender<()>>;
static WORKERS: OnceLock<Mutex<Workers>> = OnceLock::new();
pub fn wake(root: &Path) -> Result<()> {
    let root = root.canonicalize().map_err(error)?;
    let registry = WORKERS.get_or_init(Mutex::default);
    let mut workers = registry.lock().map_err(error)?;
    if let Some(sender) = workers.get(&root) {
        match sender.try_send(()) {
            Ok(()) | Err(mpsc::TrySendError::Full(())) => return Ok(()),
            Err(mpsc::TrySendError::Disconnected(())) => {
                workers.remove(&root);
            }
        }
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    let path = root.clone();
    std::thread::Builder::new()
        .name("suwop-analysis".into())
        .spawn(move || {
            if let Ok(runtime) = runtime() {
                loop {
                    if let Ok(mut store) = Store::open_existing(&path) {
                        while matches!(runtime.block_on(store.step()), Ok(true)) {}
                    }
                    if receiver.recv_timeout(Duration::from_secs(2)).is_ok() {
                        continue;
                    }
                    // A wake arriving before retirement is consumed; a later wake starts
                    // a new worker. No caller waits for a Lance operation under this lock.
                    if let Ok(mut workers) = registry.lock() {
                        if receiver.try_recv().is_ok() {
                            continue;
                        }
                        workers.remove(&path);
                    }
                    return;
                }
            }
            if let Ok(mut workers) = registry.lock() {
                workers.remove(&path);
            }
        })
        .map_err(error)?;
    workers.insert(root, sender);
    Ok(())
}
pub(crate) fn runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .max_blocking_threads(2)
        .enable_all()
        .build()
        .map_err(error)
}
