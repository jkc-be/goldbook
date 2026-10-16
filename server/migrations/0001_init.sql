CREATE TABLE scans (
  id INTEGER PRIMARY KEY,
  realm TEXT NOT NULL,
  faction TEXT NOT NULL,
  region TEXT NOT NULL,
  scanned_at INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('browse', 'replicate')),
  scanner TEXT NOT NULL,
  build TEXT NOT NULL,
  item_count INTEGER NOT NULL,
  uploaded_at INTEGER NOT NULL,
  UNIQUE (realm, faction, scanned_at)
);

CREATE TABLE items (
  item_key TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  quality INTEGER NOT NULL
) WITHOUT ROWID;

-- market_value and num_auctions are 0 for browse scans, which only see each
-- item's lowest price and total quantity.
CREATE TABLE prices (
  scan_id INTEGER NOT NULL REFERENCES scans (id),
  item_key TEXT NOT NULL,
  min_buyout INTEGER NOT NULL,
  market_value INTEGER NOT NULL,
  quantity INTEGER NOT NULL,
  num_auctions INTEGER NOT NULL,
  PRIMARY KEY (scan_id, item_key)
) WITHOUT ROWID;

CREATE INDEX prices_by_item ON prices (item_key, scan_id);
