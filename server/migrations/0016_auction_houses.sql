-- Scans and seller snapshots are read by the auction house their realm
-- belongs to. The migration knows no rule: every row starts in a house named
-- after its realm, and house::reconcile moves rows at startup to the rule
-- SHARDING_AUCTION_HOUSES selects. A realm that is not a WoW Forever shard
-- stays its own house under either rule, so nothing a client sees changes
-- for it; scripts/verify-migration.py compares every answer with the
-- baseline recorded before this migration.

ALTER TABLE scans ADD COLUMN house TEXT NOT NULL DEFAULT '';
UPDATE scans SET house = realm;
DROP INDEX scans_by_realm_time;
CREATE INDEX scans_by_house_time ON scans (house, faction, scanned_at, id);

ALTER TABLE seller_snapshots ADD COLUMN house TEXT NOT NULL DEFAULT '';
UPDATE seller_snapshots SET house = realm;
DROP INDEX sellers_by_item;
CREATE INDEX sellers_by_item ON seller_snapshots (house, faction, item_key, scanned_at DESC);

-- The newest price of every item in a house and faction, keyed by house so
-- that a shard nobody scanned reads its house's list without a row per shard.
CREATE TABLE latest_prices_new (
  house TEXT NOT NULL,
  faction TEXT NOT NULL,
  item_key TEXT NOT NULL,
  scan_id INTEGER NOT NULL REFERENCES scans (id),
  PRIMARY KEY (house, faction, item_key)
) WITHOUT ROWID;
INSERT INTO latest_prices_new (house, faction, item_key, scan_id)
SELECT realm, faction, item_key, scan_id FROM latest_prices;
DROP TABLE latest_prices;
ALTER TABLE latest_prices_new RENAME TO latest_prices;
