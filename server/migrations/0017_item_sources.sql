-- Where each item's name came from: 'player' for a player's upload,
-- 'battlenet-forever' or 'battlenet-classic-era' for the Battle.net item API
-- of that game. Every name stored before this migration is a player's.

ALTER TABLE items ADD COLUMN source TEXT NOT NULL DEFAULT 'player';
