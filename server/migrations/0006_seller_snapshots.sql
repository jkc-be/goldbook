CREATE TABLE seller_snapshots (
  fingerprint TEXT NOT NULL UNIQUE,
  realm TEXT NOT NULL,
  faction TEXT NOT NULL,
  item_key TEXT NOT NULL,
  scanned_at INTEGER NOT NULL,
  payload TEXT NOT NULL
);
CREATE INDEX sellers_by_item ON seller_snapshots (realm, faction, item_key, scanned_at DESC);
