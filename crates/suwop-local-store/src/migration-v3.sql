CREATE TABLE IF NOT EXISTS inference_runs (model TEXT PRIMARY KEY REFERENCES models(id), state TEXT NOT NULL, budget INTEGER NOT NULL, error TEXT);
CREATE TABLE IF NOT EXISTS inference_selection (id INTEGER PRIMARY KEY CHECK(id=1), model TEXT NOT NULL);
PRAGMA user_version=3;
