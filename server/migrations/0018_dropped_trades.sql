-- Trades the addon took off after uploading them, such as a vendor sale it
-- booked again at a later merchant visit. An account upload takes them off
-- the trades and never stores them again, so an upload from another
-- installation of the same ID that still holds one does not bring it back.
CREATE TABLE dropped_trades (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  realm TEXT NOT NULL,
  at INTEGER NOT NULL,
  side TEXT NOT NULL,
  item TEXT NOT NULL,
  count INTEGER NOT NULL,
  price INTEGER NOT NULL,
  fee INTEGER NOT NULL,
  PRIMARY KEY (account_id, name, realm, at, side, item, count, price, fee)
) WITHOUT ROWID;
