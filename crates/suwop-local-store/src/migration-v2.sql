-- Preserve identities, pending work and published generations from the initial schema.
CREATE TABLE embedding_vectors (
 job INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE, vector BLOB NOT NULL
);
INSERT INTO embedding_vectors(job,vector) SELECT id,vector FROM jobs WHERE vector IS NOT NULL;
ALTER TABLE jobs DROP COLUMN vector;
CREATE INDEX IF NOT EXISTS jobs_shard ON jobs(shard,state);
PRAGMA user_version=2;
