-- Where each item's name came from: 'player' for a player's upload, or
-- 'battlenet-forever' for the Battle.net item API of WoW Forever. Every name
-- stored before this migration is a player's.

ALTER TABLE items ADD COLUMN source TEXT NOT NULL DEFAULT 'player';
