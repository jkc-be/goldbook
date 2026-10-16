-- Auction house sales and purchases, as the addon booked them from the
-- mailbox. An account upload replaces its characters but only adds trades,
-- so the ledger outlives what the addon keeps. Equal trades of one upload are
-- told apart by `copy`, 0 for the first, so that two equal sales in one
-- mailbox stay two rows and a repeated upload adds none.
CREATE TABLE trades (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  realm TEXT NOT NULL,
  at INTEGER NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
  item TEXT NOT NULL,
  count INTEGER NOT NULL,
  price INTEGER NOT NULL,
  fee INTEGER NOT NULL,
  copy INTEGER NOT NULL,
  item_key TEXT,
  PRIMARY KEY (account_id, name, realm, at, side, item, count, price, fee, copy)
) WITHOUT ROWID;

CREATE INDEX trades_by_time ON trades (account_id, at DESC);
