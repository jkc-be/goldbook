-- IDs from different computers can be linked, so that logging in with any of
-- them shows the characters of all. Each still uploads under its own ID. The
-- group is kept under one of its IDs: owner_id names it, and is NULL on that
-- ID itself, so no owner has an owner of its own.
ALTER TABLE accounts ADD COLUMN owner_id TEXT REFERENCES accounts (id);
CREATE INDEX accounts_by_owner ON accounts (COALESCE(owner_id, id));
