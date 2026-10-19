-- Website sign-in with Battle.net. A sign-in on its way is kept by the hash
-- of its state and of the browser's cookie, and is used once.
CREATE TABLE battlenet_web_logins (
  state_hash TEXT PRIMARY KEY,
  csrf_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER
) WITHOUT ROWID;

-- A player's website session, kept by the hash of its cookie's token as the
-- ID sessions in sessions are.
CREATE TABLE battlenet_web_sessions (
  token_hash TEXT PRIMARY KEY,
  identity_hash TEXT NOT NULL REFERENCES battlenet_identities (identity_hash),
  expires_at INTEGER NOT NULL
) WITHOUT ROWID;
