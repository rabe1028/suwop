use std::time::Instant;
use suwop_core::analysis::{AnalysisBudget, AnalysisModel};
use suwop_local_store::Store;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let rows: i64 = args[1].parse()?;
    let dims: usize = args[2].parse()?;
    let root = std::path::PathBuf::from(&args[3]);
    let mut store = Store::open(&root)?;
    store.persist(&suwop_core::app::SavedLibrary::default())?;
    let model = AnalysisModel { dimensions: dims as u32, ..serde_json::from_value(serde_json::json!({
        "name":"bench","version":"1","preprocessing":"bench","rendition":"original","dimensions":dims}))? };
    let key = store.register(&model, &AnalysisBudget::default())?;
    let db = rusqlite::Connection::open(root.join("catalog.sqlite3"))?;
    let generation: i64 = db.query_row("SELECT latest FROM models WHERE id=?1", [&key], |r| r.get(0))?;
    let t = Instant::now();
    let tx = db.unchecked_transaction()?;
    tx.execute("INSERT INTO shards(id,generation,state) VALUES(1,?1,'ready')", [generation])?;
    let mut seed: u64 = 1;
    let mut next = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; ((seed >> 40) as i64 % 255 - 127) as i8 as u8 };
    {
        let mut asset = tx.prepare("INSERT INTO assets VALUES(?1,'r',?2)")?;
        let mut job = tx.prepare("INSERT INTO jobs(id,generation,asset,revision,state,shard) VALUES(?1,?2,?3,'r','done',1)")?;
        let mut vec = tx.prepare("INSERT INTO index_vectors(job,shard,scale,codes) VALUES(?1,1,?2,?3)")?;
        for i in 0..rows {
            let id = format!("a{i}");
            let json = serde_json::json!({"key":{"provider":"apple","scope":"bench","assetID":id},"appleVisibility":"visible","name":"x","revision":"r","capturedAt":null,"modifiedAt":null,"resources":[],"isFavorite":false,"latitude":null,"longitude":null,"inventoryComplete":false,"isOffline":false,"deletionBlockers":[]}).to_string();
            asset.execute(rusqlite::params![id, json])?;
            job.execute(rusqlite::params![i + 1, generation, id])?;
            let codes: Vec<u8> = (0..dims).map(|_| next()).collect();
            vec.execute(rusqlite::params![i + 1, 1.0 / (127.0 * (dims as f64).sqrt()), codes])?;
        }
    }
    tx.execute("UPDATE models SET active=latest", [])?;
    tx.execute("UPDATE generations SET state='ready'", [])?;
    tx.commit()?;
    eprintln!("populate {:?}", t.elapsed());
    drop(store);
    let store = Store::open(&root)?;
    let query: Vec<f32> = (0..dims).map(|i| ((i * 7919) % 13) as f32 - 6.0).collect();
    let mut times = Vec::new();
    for _ in 0..7 {
        let t = Instant::now();
        let hits = store.search(&key, &query, 100)?;
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(hits.len(), 100);
    }
    times.sort_by(f64::total_cmp);
    let size = std::fs::metadata(root.join("catalog.sqlite3"))?.len();
    println!("rows={rows} dims={dims} search_ms min={:.1} median={:.1} max={:.1} db_bytes={size}", times[0], times[3], times[6]);
    Ok(())
}
