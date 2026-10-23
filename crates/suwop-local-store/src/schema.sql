CREATE TABLE IF NOT EXISTS library_state (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, revision TEXT NOT NULL, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS models (id TEXT PRIMARY KEY, json TEXT NOT NULL, active INTEGER, latest INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS generations (
 id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL REFERENCES models(id),
 budget TEXT NOT NULL, batch_rows INTEGER NOT NULL, state TEXT NOT NULL, error TEXT
);
CREATE TABLE IF NOT EXISTS jobs (
 id INTEGER PRIMARY KEY AUTOINCREMENT, generation INTEGER NOT NULL REFERENCES generations(id),
 asset TEXT NOT NULL, revision TEXT NOT NULL, state TEXT NOT NULL, shard INTEGER, reason TEXT,
 UNIQUE(generation, asset, revision)
);
CREATE INDEX IF NOT EXISTS jobs_work ON jobs(generation,state);
CREATE TABLE IF NOT EXISTS shards (
 id INTEGER PRIMARY KEY AUTOINCREMENT, generation INTEGER NOT NULL REFERENCES generations(id),
 state TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS embedding_vectors (
 job INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE, vector BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS jobs_shard ON jobs(shard,state);
CREATE TABLE IF NOT EXISTS inference_runs (model TEXT PRIMARY KEY REFERENCES models(id), state TEXT NOT NULL, budget INTEGER NOT NULL, error TEXT);
CREATE TABLE IF NOT EXISTS inference_selection (id INTEGER PRIMARY KEY CHECK(id=1), model TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS analysis_asset_keys (id TEXT PRIMARY KEY, json TEXT NOT NULL);
INSERT OR IGNORE INTO analysis_asset_keys SELECT id,json_extract(json,'$.key') FROM assets;
CREATE INDEX IF NOT EXISTS jobs_asset_revision ON jobs(asset,revision);
CREATE TABLE IF NOT EXISTS index_vectors (
 job INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
 shard INTEGER NOT NULL REFERENCES shards(id), scale REAL NOT NULL, codes BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS index_vectors_shard ON index_vectors(shard);
PRAGMA user_version=5;
