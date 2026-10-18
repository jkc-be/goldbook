-- The Battle.net players whose registered installs uploaded each ID. An ID
-- that installs of more than one player uploaded keeps every one of them.
CREATE TABLE account_identities (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  identity_hash TEXT NOT NULL REFERENCES battlenet_identities (identity_hash),
  first_seen INTEGER NOT NULL,
  PRIMARY KEY (account_id, identity_hash)
) WITHOUT ROWID;

CREATE INDEX account_identities_by_identity ON account_identities (identity_hash);
