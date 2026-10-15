CREATE TABLE IF NOT EXISTS analysis_asset_keys (id TEXT PRIMARY KEY, json TEXT NOT NULL);
INSERT OR IGNORE INTO analysis_asset_keys SELECT id,json_extract(json,'$.key') FROM assets;
CREATE INDEX IF NOT EXISTS jobs_asset_revision ON jobs(asset,revision);
PRAGMA user_version=4;
