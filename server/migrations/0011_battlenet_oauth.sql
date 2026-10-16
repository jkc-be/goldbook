CREATE TABLE battlenet_identities (
    identity_hash TEXT PRIMARY KEY,
    blocked_at INTEGER
);
ALTER TABLE upload_identities ADD COLUMN battlenet_identity TEXT REFERENCES battlenet_identities(identity_hash);
CREATE INDEX upload_identities_battlenet ON upload_identities(battlenet_identity);
CREATE TABLE battlenet_sessions (
    token_hash TEXT PRIMARY KEY,
    identity_hash TEXT NOT NULL REFERENCES battlenet_identities(identity_hash),
    expires_at INTEGER NOT NULL
);
CREATE TABLE battlenet_pairings (
    request_id TEXT PRIMARY KEY,
    poll_hash TEXT UNIQUE NOT NULL,
    user_code_hash TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    state_hash TEXT UNIQUE,
    csrf_hash TEXT,
    consumed_at INTEGER,
    identity_hash TEXT REFERENCES battlenet_identities(identity_hash),
    failed INTEGER NOT NULL DEFAULT 0,
    polled_at INTEGER,
    last_poll_at INTEGER
);
