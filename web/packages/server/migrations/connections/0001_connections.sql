-- Each athlete's Intervals.icu OAuth token, encrypted. Kept out of the event
-- history so it can be deleted for good.
CREATE TABLE intervals_connections (
  athlete_id TEXT PRIMARY KEY,
  token_ciphertext TEXT NOT NULL,
  scopes TEXT NOT NULL,
  connected_at TEXT NOT NULL
);
