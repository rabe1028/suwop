CREATE TABLE IF NOT EXISTS index_vectors (
 job INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
 shard INTEGER NOT NULL REFERENCES shards(id), scale REAL NOT NULL, codes BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS index_vectors_shard ON index_vectors(shard);
-- Published vectors lived only in Lance files, which this version cannot read.
-- Their photos must be embedded again; pending shards keep their staged vectors.
UPDATE jobs SET state=CASE WHEN state='done' THEN 'awaiting' ELSE state END, shard=NULL
 WHERE shard IN (SELECT id FROM shards WHERE state='ready');
DELETE FROM index_vectors WHERE shard IN (SELECT id FROM shards WHERE state='ready');
DELETE FROM shards WHERE state='ready';
UPDATE generations SET state='retired' WHERE id NOT IN (SELECT latest FROM models);
UPDATE generations SET state='building' WHERE state='ready';
UPDATE models SET active=NULL;
PRAGMA user_version=5;
