//! Original and known graph/membership controls, independent of product capability.
use super::*;
fn get(
    f: &Fixture,
    agent: &ureq::Agent,
    path: &str,
    destination: Option<&Path>,
) -> Result<HttpResponse, String> {
    let mut request = f.elevated.request(path, "GET", None);
    request.download_path = destination.map(|p| p.to_string_lossy().into_owned());
    let reply: HttpResponse =
        serde_json::from_value(execute(agent, &request)?).map_err(|_| "C2 observer response")?;
    assert_eq!(reply.status, 200);
    Ok(reply)
}
pub(super) fn observe(
    f: &Fixture,
    agent: &ureq::Agent,
    root: &Path,
    stage: &str,
    selected: Option<(usize, &str)>,
) -> Result<Value, String> {
    let output = root.join(stage);
    std::fs::create_dir(&output).map_err(|_| "C2 observer stage exists")?;
    let pair = native_pair_bytes()?;
    let expected = [V.to_vec(), pair.0, pair.1, png(1)?];
    let mut rows = Vec::new();
    for (index, id) in f.ids.iter().enumerate() {
        let detail = get(f, agent, &format!("assets/{id}"), None)?.body;
        assert_eq!(detail["id"], *id);
        assert_eq!(detail["ownerId"], f.elevated.ordinary.user_id);
        assert_eq!(
            detail["type"],
            if index == 0 || index == 2 {
                "VIDEO"
            } else {
                "IMAGE"
            }
        );
        if index == 1 || index == 3 {
            assert_eq!(detail["livePhotoVideoId"], f.ids[2]);
        } else {
            assert_eq!(detail.get("livePhotoVideoId"), Some(&Value::Null));
        }
        assert_eq!(detail.get("stack"), Some(&Value::Null));
        let memberships = get(f, agent, &format!("albums?assetId={id}"), None)?.body;
        let memberships = memberships
            .as_array()
            .ok_or("C2 membership list")?
            .iter()
            .map(|a| a["id"].as_str().map(str::to_owned).ok_or("C2 album ID"))
            .collect::<Result<BTreeSet<_>, _>>()?;
        if let Some((chosen, visibility)) = selected {
            if index == chosen {
                assert_eq!(detail["visibility"], visibility);
                assert!(memberships.is_empty());
            } else if index == 1 || index == 3 {
                assert_eq!(memberships, f.albums);
            }
        }
        let original = output.join(format!("original-{index}.bin"));
        get(
            f,
            agent,
            &format!("assets/{id}/original?edited=false"),
            Some(&original),
        )?;
        let bytes = std::fs::read(&original).map_err(|_| "C2 observer original")?;
        assert_eq!(bytes, expected[index]);
        rows.push(json!({"id":id,"detail":detail,"albums":memberships,"sha1":format!("{:x}",Sha1::digest(&bytes)),"bytes":bytes.len()}));
    }
    for (slot, index) in [0, 2].into_iter().enumerate() {
        let destination = output.join(format!("direct-share-{index}.bin"));
        let mut request = f.elevated.ordinary.request(
            &format!(
                "assets/{}/original?edited=false&key={}",
                f.ids[index], f.shares[slot]
            ),
            "GET",
            None,
        );
        request.headers.clear();
        request.download_path = Some(destination.to_string_lossy().into_owned());
        let raw = execute(agent, &request).map_err(|_| "C2 direct-share transport")?;
        let reply: HttpResponse =
            serde_json::from_value(raw).map_err(|_| "C2 direct-share response")?;
        assert_eq!(
            reply.status, 200,
            "known individual shared links remain a separate access path"
        );
        assert_eq!(
            std::fs::read(destination).map_err(|_| "C2 share bytes")?,
            expected[index]
        );
    }
    ordinary_controls(f, agent, &output, &expected, &rows)?;
    let value = json!(rows);
    std::fs::write(
        output.join("observations.json"),
        serde_json::to_vec_pretty(&value).map_err(|_| "C2 observe encode")?,
    )
    .map_err(|_| "C2 observe write")?;
    Ok(value)
}
pub(super) fn quiet(_f: &Fixture, root: &Path, stage: &str) -> Result<(), String> {
    let path = root.join("queue-baseline.json");
    let baseline = if path.exists() {
        serde_json::from_slice(&std::fs::read(&path).map_err(|_| "C2 queue baseline read")?)
            .map_err(|_| "C2 queue baseline JSON")?
    } else {
        let baseline = write_contract::selected_video_queue_snapshot()?;
        std::fs::write(
            &path,
            serde_json::to_vec(&baseline).map_err(|_| "C2 queue baseline encode")?,
        )
        .map_err(|_| "C2 queue baseline write")?;
        baseline
    };
    for name in ["sidecar", "metadataExtraction"] {
        for field in ["active", "waiting", "paused", "delayed", "prioritized"] {
            assert_eq!(baseline[name][field], 0);
        }
    }
    let mut samples = Vec::new();
    for _ in 0..20 {
        let value = write_contract::selected_video_queue_snapshot()?;
        assert_eq!(
            value, baseline,
            "no observed enqueue during bounded post-product window"
        );
        samples.push(value);
        std::thread::sleep(Duration::from_millis(250));
    }
    std::fs::write(root.join(format!("{stage}-quiet-window.json")),serde_json::to_vec(&json!({"samples":samples,"intervalMilliseconds":250,"scope":"isolated queues only; no future-job guarantee"})).map_err(|_|"C2 queue encode")?).map_err(|_|"C2 queue write")?;
    Ok(())
}

fn ordinary_controls(
    f: &Fixture,
    agent: &ureq::Agent,
    output: &Path,
    expected: &[Vec<u8>; 4],
    rows: &[Value],
) -> Result<(), String> {
    let mut controls = Vec::new();
    for index in [0, 2] {
        let id = &f.ids[index];
        let request = f
            .elevated
            .ordinary
            .request(&format!("assets/{id}"), "GET", None);
        assert!(!request.headers.contains_key("Authorization"));
        let detail: HttpResponse =
            serde_json::from_value(execute(agent, &request)?).map_err(|_| "C2 ordinary detail")?;
        if detail.status == 200 {
            assert_eq!(detail.body["id"], *id);
        }
        let mut request =
            f.elevated
                .ordinary
                .request(&format!("assets/{id}/original?edited=false"), "GET", None);
        let path = output.join(format!("ordinary-original-{index}.bin"));
        request.download_path = Some(path.to_string_lossy().into_owned());
        let original: HttpResponse = serde_json::from_value(execute(agent, &request)?)
            .map_err(|_| "C2 ordinary original")?;
        let matches = original.status == 200
            && std::fs::read(&path).map_err(|_| "C2 ordinary bytes")? == expected[index];
        if original.status == 200 {
            assert!(matches);
        }
        if index == 0 || rows[index]["detail"]["visibility"] != "locked" {
            let locked = rows[index]["detail"]["visibility"] == "locked";
            assert_eq!(detail.status, if locked { 400 } else { 200 });
            assert_eq!(original.status, if locked { 404 } else { 200 });
        }
        // Related album access to M is measured separately; never infer locked means inaccessible.
        controls.push(json!({"resourceID":id,"authority":"ordinary owner API key without shared-link key/elevation","detailStatus":detail.status,"originalStatus":original.status,"originalBytesMatch":matches,"selectedVisibility":rows[index]["detail"]["visibility"],"scope":if index==0{"standalone fixture; exact known graph only"}else{"native motion with two retained parents; access is observed, not confidentiality proof"}}));
    }
    std::fs::write(
        output.join("ordinary-controls.json"),
        serde_json::to_vec_pretty(&controls).map_err(|_| "C2 controls encode")?,
    )
    .map_err(|_| "C2 controls write")?;
    Ok(())
}
