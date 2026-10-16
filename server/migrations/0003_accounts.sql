CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  key_hash TEXT NOT NULL,
  updated_at INTEGER NOT NULL
) WITHOUT ROWID;

-- gold, bags and bank hold JSON: [[time, copper], ...] by unix time on the
-- hour, as uploaded or as 0004_gold_hours.sql converted it from days, and
-- {"at", "rows"} or null.
CREATE TABLE characters (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  realm TEXT NOT NULL,
  faction TEXT,
  class TEXT,
  level INTEGER,
  updated_at INTEGER,
  gold TEXT NOT NULL,
  bags TEXT,
  bank TEXT,
  PRIMARY KEY (account_id, name, realm)
) WITHOUT ROWID;

-- token_hash is the SHA-256 of the cookie's token; the token itself is never stored.
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
) WITHOUT ROWID;

CREATE INDEX sessions_by_account ON sessions (account_id);
