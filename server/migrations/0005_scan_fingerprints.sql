-- Keep existing scan IDs and price rows while replacing the per-second
-- uniqueness rule. The connection supplies scan_fingerprint so old scans
-- get the same identity as a later retry of their complete snapshot.
CREATE TABLE scans_new (
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
  fingerprint TEXT NOT NULL UNIQUE
);

INSERT INTO scans_new
SELECT s.*, scan_fingerprint(json_array(
  s.realm, s.faction, s.region, s.scanned_at, s.mode, s.scanner, s.build,
  json((SELECT json_group_array(json_array(
    p.item_key, p.min_buyout, p.market_value, p.quantity, p.num_auctions
  )) FROM prices p WHERE p.scan_id = s.id))
)) FROM scans s;

CREATE TABLE prices_new (
  scan_id INTEGER NOT NULL REFERENCES scans_new (id),
  item_key TEXT NOT NULL,
  min_buyout INTEGER NOT NULL,
  market_value INTEGER NOT NULL,
  quantity INTEGER NOT NULL,
  num_auctions INTEGER NOT NULL,
  PRIMARY KEY (scan_id, item_key)
) WITHOUT ROWID;

INSERT INTO prices_new SELECT * FROM prices;
DROP TABLE prices;
DROP TABLE scans;
ALTER TABLE scans_new RENAME TO scans;
ALTER TABLE prices_new RENAME TO prices;
CREATE INDEX scans_by_realm_time ON scans (realm, faction, scanned_at, id);
