-- The newest price of every item ever scanned on a realm and faction, which
-- Prices lists, as the addon lists every item it has a price for.
CREATE TABLE latest_prices (
  realm TEXT NOT NULL,
  faction TEXT NOT NULL,
  item_key TEXT NOT NULL,
  scan_id INTEGER NOT NULL REFERENCES scans (id),
  PRIMARY KEY (realm, faction, item_key)
) WITHOUT ROWID;

INSERT INTO latest_prices (realm, faction, item_key, scan_id)
SELECT realm, faction, item_key, scan_id FROM (
  SELECT s.realm, s.faction, p.item_key, p.scan_id,
    ROW_NUMBER() OVER (PARTITION BY s.realm, s.faction, p.item_key ORDER BY s.scanned_at DESC, s.id DESC) AS newest
  FROM prices p JOIN scans s ON s.id = p.scan_id
) WHERE newest = 1;
