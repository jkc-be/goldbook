-- The ledger grows into the accounting of all gold that comes and goes:
-- goods from merchants, player trades and cash on delivery, and gold alone
-- such as quest rewards, repairs and mail. `party` names the other player of
-- a trade or a mail; it is not part of an entry's identity. SQLite cannot
-- change a CHECK constraint in place, so the table is rebuilt with the same rows.
CREATE TABLE trades_new (
  account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  realm TEXT NOT NULL,
  at INTEGER NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('sell', 'buy', 'vendor', 'merchant', 'tradeSell', 'tradeBuy',
    'tradeIn', 'tradeOut', 'mailIn', 'mailOut', 'cod', 'quest', 'loot', 'repair', 'postage',
    'deposit', 'travel', 'training', 'respec', 'otherIn', 'otherOut')),
  item TEXT NOT NULL,
  count INTEGER NOT NULL,
  price INTEGER NOT NULL,
  fee INTEGER NOT NULL,
  copy INTEGER NOT NULL,
  item_key TEXT,
  party TEXT,
  PRIMARY KEY (account_id, name, realm, at, side, item, count, price, fee, copy)
) WITHOUT ROWID;

INSERT INTO trades_new (account_id, name, realm, at, side, item, count, price, fee, copy, item_key)
  SELECT account_id, name, realm, at, side, item, count, price, fee, copy, item_key FROM trades;
DROP TABLE trades;
ALTER TABLE trades_new RENAME TO trades;
CREATE INDEX trades_by_time ON trades (account_id, at DESC);
