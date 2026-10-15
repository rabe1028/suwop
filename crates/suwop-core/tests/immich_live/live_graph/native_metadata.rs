//! Disposable harness-only, owner-scoped read-only metadata completion checkpoint.
use super::*;
use std::io::{Seek, SeekFrom, Write};
use std::process::{Command as Process, Stdio};

pub(super) fn metadata_ready(session: &Session, ids: [&str; 3]) -> Result<(), String> {
    for id in std::iter::once(session.user_id.as_str()).chain(ids) {
        let valid = id.len() == 36
            && id.bytes().enumerate().all(|(i, c)| {
                if [8, 13, 18, 23].contains(&i) {
                    c == b'-'
                } else {
                    c.is_ascii_hexdigit()
                }
            });
        if !valid {
            return Err("metadata checkpoint UUID".into());
        }
    }
    let root = std::path::PathBuf::from(
        std::env::var_os("SUWOP_NATIVE_LIVE_EVIDENCE_DIR").ok_or("metadata evidence root")?,
    );
    std::fs::create_dir_all(&root).map_err(|_| "metadata evidence directory")?;
    let sql = format!(
        r#"BEGIN READ ONLY;
SET LOCAL statement_timeout='5s';
SELECT coalesce(json_agg(json_build_object('id',a.id,'ownerId',a."ownerId",'type',a.type,'metadataExtractedAt',j."metadataExtractedAt")), '[]'::json) FROM asset a LEFT JOIN asset_job_status j ON j."assetId"=a.id WHERE a."ownerId"='{}'::uuid AND a.id IN ('{}'::uuid,'{}'::uuid,'{}'::uuid);
ROLLBACK;
"#,
        session.user_id, ids[0], ids[1], ids[2]
    );
    let mut sql_evidence = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(root.join("metadata-completion.sql"))
        .map_err(|_| "metadata SQL evidence already exists or unavailable")?;
    sql_evidence
        .write_all(sql.as_bytes())
        .map_err(|_| "metadata SQL evidence")?;
    let mut result_evidence = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(root.join("metadata-completion.json"))
        .map_err(|_| "metadata result evidence already exists or unavailable")?;
    let project = std::env::var("IMMICH_TEST_PROJECT").map_err(|_| "metadata isolated project")?;
    let compose =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docker/immich-test/docker-compose.yml");
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let mut samples = Vec::new();
    loop {
        let rows = query_metadata(&project, &compose, &sql)?;
        let rows_array = rows.as_array().ok_or("metadata checkpoint rows")?;
        let ready = rows_array.len() == 3
            && ids.iter().enumerate().all(|(i, id)| {
                rows_array
                    .iter()
                    .filter(|r| {
                        r["id"] == *id
                            && r["ownerId"] == session.user_id
                            && r["type"] == if i == 1 { "VIDEO" } else { "IMAGE" }
                            && r["metadataExtractedAt"].as_str().is_some()
                    })
                    .count()
                    == 1
            });
        samples.push(rows);
        result_evidence
            .set_len(0)
            .map_err(|_| "metadata evidence truncate")?;
        result_evidence
            .seek(SeekFrom::Start(0))
            .map_err(|_| "metadata evidence seek")?;
        result_evidence
            .write_all(
                &serde_json::to_vec_pretty(&samples).map_err(|_| "metadata evidence encode")?,
            )
            .map_err(|_| "metadata evidence write")?;
        result_evidence
            .flush()
            .map_err(|_| "metadata evidence flush")?;
        if ready {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err("metadata completion timeout".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

pub(super) fn query_metadata(project: &str, compose: &Path, sql: &str) -> Result<Value, String> {
    let mut child = Process::new("docker")
        .args(["compose", "-p", project, "-f"])
        .arg(compose)
        .args([
            "exec",
            "-T",
            "database",
            "psql",
            "-U",
            "postgres",
            "-d",
            "immich",
            "-Atq",
            "-v",
            "ON_ERROR_STOP=1",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "metadata checkpoint spawn")?;
    child
        .stdin
        .take()
        .ok_or("metadata checkpoint stdin")?
        .write_all(sql.as_bytes())
        .map_err(|_| "metadata checkpoint SQL")?;
    let output = child
        .wait_with_output()
        .map_err(|_| "metadata checkpoint wait")?;
    if !output.status.success() {
        return Err("metadata checkpoint query failed".into());
    }
    serde_json::from_slice(&output.stdout).map_err(|_| "metadata checkpoint JSON".into())
}
