-- Addons before 0.5.4 booked a merchant's whole buyback list again as new
-- vendor sales each time a merchant opened. A hidden entry is left out of the
-- ledger but stays stored, so the addon uploading it again adds no new row.
-- 0019_balance_correction in db.rs hides those re-bookings once.
ALTER TABLE trades ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
