-- Sales to vendors join the ledger as side 'vendor'. SQLite cannot change a
-- CHECK constraint in place, so the table is rebuilt with the same rows.
CREATE TABLE trades_new (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  realm TEXT NOT NULL,
  at INTEGER NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('buy', 'sell', 'vendor')),
  item TEXT NOT NULL,
  count INTEGER NOT NULL,
  price INTEGER NOT NULL,
  fee INTEGER NOT NULL,
  copy INTEGER NOT NULL,
  item_key TEXT,
  PRIMARY KEY (account_id, name, realm, at, side, item, count, price, fee, copy)
) WITHOUT ROWID;

INSERT INTO trades_new SELECT account_id, name, realm, at, side, item, count, price, fee, copy, item_key FROM trades;
DROP TABLE trades;
ALTER TABLE trades_new RENAME TO trades;
CREATE INDEX trades_by_time ON trades (account_id, at DESC);
