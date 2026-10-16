-- No query used this index: the price history walks the realm's scans and
-- probes the primary key of prices. It doubled the rows written per scan.
DROP INDEX prices_by_item;
