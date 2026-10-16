CREATE TABLE upload_identities (
    fingerprint TEXT PRIMARY KEY,
    blocked_at INTEGER
);
CREATE TABLE upload_tokens (
    token_hash TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL REFERENCES upload_identities(fingerprint),
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
);
CREATE INDEX upload_tokens_fingerprint ON upload_tokens(fingerprint);
