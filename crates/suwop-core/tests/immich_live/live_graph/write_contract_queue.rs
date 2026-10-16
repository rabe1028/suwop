//! Read-only isolated queue telemetry adapted from the retained v3.3.3 probe.
use super::*;
pub(super) fn metadata_stamp(root: &Path, session: &Session, id: &str) -> Result<String, String> {
    let sql = std::fs::read_to_string(root.join("metadata-completion.sql"))
        .map_err(|_| "probe checkpoint SQL")?;
    let project = std::env::var("IMMICH_TEST_PROJECT").map_err(|_| "probe isolated project")?;
    let compose =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docker/immich-test/docker-compose.yml");
    let rows = native_metadata::query_metadata(&project, &compose, &sql)?;
    let row = rows
        .as_array()
        .ok_or("probe metadata rows")?
        .iter()
        .find(|row| row["id"] == id && row["ownerId"] == session.user_id)
        .ok_or("probe metadata exact row")?;
    row["metadataExtractedAt"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "probe metadata timestamp".into())
}
pub(super) fn queue_snapshot() -> Result<Value, String> {
    let project = std::env::var("IMMICH_TEST_PROJECT").map_err(|_| "queue isolated project")?;
    if !project.starts_with("suwop-")
        || !project
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("unexpected queue observation project".into());
    }
    let compose =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docker/immich-test/docker-compose.yml");
    let output = std::process::Command::new("docker")
        .args(["compose", "-p", &project, "-f"])
        .arg(compose)
        .args(["exec", "-T", "redis", "redis-cli", "--raw", "EVAL_RO"])
        .arg(include_str!(
            "../../../../../scripts/immich-queue-observation.lua"
        ))
        .arg("0")
        .stderr(std::process::Stdio::null())
        .output()
        .map_err(|_| "queue snapshot spawn")?;
    if !output.status.success() {
        return Err("queue snapshot failed".into());
    }
    let value: Value =
        serde_json::from_slice(&output.stdout).map_err(|_| "queue snapshot decode")?;
    let keys = value.as_object().ok_or("queue namespaces")?;
    if keys.len() != 2
        || !keys.contains_key("sidecar")
        || !keys.contains_key("metadataExtraction")
        || value["metadataExtraction"]["id"].is_null()
    {
        return Err("initial metadata queue not established or wrong namespace".into());
    }
    Ok(value)
}
fn queue_idle(value: &Value) -> bool {
    ["sidecar", "metadataExtraction"].iter().all(|name| {
        ["active", "waiting", "paused", "delayed", "prioritized"]
            .iter()
            .all(|field| value[name][field] == 0)
    })
}
pub(in super::super::super) fn native_cid_before_product(root: &Path) -> Result<(), String> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut prior = Value::Null;
    let mut stable = 0;
    let mut samples = Vec::new();
    loop {
        let value = queue_snapshot()?;
        stable = if queue_idle(&value) && value == prior {
            stable + 1
        } else {
            0
        };
        prior = value.clone();
        samples.push(value);
        if stable >= 3 {
            write_evidence(root, "pre-product-queue.json", &prior)?;
            write_evidence(
                root,
                "pre-product-queue-settle.json",
                &json!({"samples":samples,"intervalMilliseconds":250,"scope":"isolated sidecar+metadata queues only"}),
            )?;
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err("initial queues not quiet".into());
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}
pub(super) fn observe_quiet(ordinary: &Session, root: &Path, stage: &str) -> Result<(), String> {
    let baseline: Value = serde_json::from_slice(
        &std::fs::read(root.join("pre-product-queue.json")).map_err(|_| "queue baseline read")?,
    )
    .map_err(|_| "queue baseline decode")?;
    let control = control(root)?;
    let original_stamps: Value = serde_json::from_slice(
        &std::fs::read(root.join("after-unlink-baseline/observations.json"))
            .map_err(|_| "baseline read")?,
    )
    .map_err(|_| "baseline decode")?;
    let mut samples = Vec::new();
    for index in 0..20 {
        let queues = queue_snapshot()?;
        assert_eq!(
            queues, baseline,
            "queue counter/event change: no-enqueue claim not established"
        );
        let mut stamps = Vec::new();
        for (i, role) in ["parent", "motion", "other"].iter().enumerate() {
            let id = control[role].as_str().ok_or("quiet exact ID")?;
            let stamp = metadata_stamp(root, ordinary, id)?;
            assert_eq!(
                original_stamps[i]["metadataExtractedAt"], stamp,
                "metadata changed during bounded quiet observation"
            );
            stamps.push(stamp);
        }
        samples.push(json!({"sample":index,"queues":queues,"metadataExtractedAt":stamps}));
        write_evidence(
            root,
            &format!("{stage}-quiet-window.json"),
            &json!({"sampleCount":samples.len(),"intervalMilliseconds":250,"scope":"bounded no-observed-enqueue; no future-job guarantee; no forced metadata jobs","samples":samples}),
        )?;
        std::thread::sleep(Duration::from_millis(250));
    }
    Ok(())
}
