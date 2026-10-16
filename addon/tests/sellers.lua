local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
Stub.fire("AUCTION_HOUSE_SHOW")
local AH, rows, complete = C_AuctionHouse, {}, false
AH.HasFullItemSearchResults = function() return complete end
AH.GetNumItemSearchResults = function() return #rows end
AH.GetItemSearchResultInfo = function(_, i) return rows[i] end
AH.HasFullCommoditySearchResults = function() return complete end
AH.GetNumCommoditySearchResults = function() return #rows end
AH.GetCommoditySearchResultInfo = function(_, i) return rows[i] end
local key = { itemID = 2589, itemSuffix = 0 }
local function latest(itemKey)
  local found
  for _, snapshot in pairs(ns.db.sellerScans) do
    if snapshot.itemKey == itemKey and (not found or snapshot.scannedAt > found.scannedAt) then
      found = snapshot
    end
  end
  return found
end
local function search()
  Stub.fire("ITEM_SEARCH_RESULTS_UPDATED", key)
  Stub.advance(1.1)
end
rows = {
  { quantity = 60, buyoutAmount = 6000, owners = { "Alice" }, totalNumberOfOwners = 1 },
  { quantity = 10, buyoutAmount = 1200, owners = { "Bob" }, totalNumberOfOwners = 1 },
  { quantity = 20, buyoutAmount = 2600, owners = { "Alice", "Carol" }, totalNumberOfOwners = 2 },
  { quantity = 10, buyoutAmount = 1400, owners = {}, totalNumberOfOwners = 2 },
  { quantity = 4, buyoutAmount = 0, owners = { "BidOnly" }, totalNumberOfOwners = 1 },
}
search()
assert(next(ns.db.sellerScans) == nil, "partial search must not replace a complete market snapshot")
complete = true
search()
local saved = latest("2589")
assert(#saved.offers == 4 and saved.offers[1].unitPrice == 100, "only buyout stock is recorded at per-unit prices")
assert(saved.offers[3].totalOwners == 2 and #saved.offers[4].owners == 0, "shared and unknown ownership must be preserved")
search()
assert(#latest("2589").offers == 4, "each observation records stock without adding prior quantities")
assert(latest("2589").scannedAt > saved.scannedAt, "repeated searches keep their observation times")
rows[1].quantity, rows[1].buyoutAmount = 40, 4000
search()
assert(latest("2589").offers[1].quantity == 40 and saved.offers[1].quantity == 60, "changed stock must preserve the earlier book")
rows[1].quantity, rows[1].buyoutAmount = 60, 6000
search()
rows = { { quantity = 8, unitPrice = 300, owners = { "player" }, totalNumberOfOwners = 1 } }
Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 7070)
Stub.advance(1.1)
assert(latest("7070").offers[1].owners[1] == "Sultan-Faramon", "own stock must use the character name")
rows, key = {}, { itemID = 9999 }
search()
assert(#latest("9999").offers == 0, "an empty complete search clears old stock")
rows, key = { { quantity = 1, buyoutAmount = 25, owners = { "SuffixSeller" }, totalNumberOfOwners = 1 } }, { itemID = 9775, itemSuffix = 584 }
search()
assert(latest("9775:584"), "random suffix variants must stay separate")
Stub.fire("AUCTION_HOUSE_CLOSED")
rows = {}
search()
assert(#latest("9775:584").offers == 1, "late events after closing must be ignored")

local function serialize(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local out = { "{" }
  for _, v in ipairs(value) do
    out[#out + 1] = serialize(v) .. ","
  end
  for k, v in pairs(value) do
    if type(k) ~= "number" then
      out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(v) .. ","
    end
  end
  out[#out + 1] = "}"
  return table.concat(out)
end
if arg[1] then
  local out = assert(io.open(arg[1], "w"))
  out:write("GoldbookDB = ", serialize({ items = {}, scans = {}, sellerScans = ns.db.sellerScans }), "\n")
  out:close()
end
-- Legacy latest-only entries must survive the first capture after an update.
Stub.fire("AUCTION_HOUSE_SHOW")
ns.db.sellerScans["Faramon|Horde|legacy"] = { scannedAt = time(), offers = {} }
search()
assert(ns.db.sellerScans["Faramon|Horde|legacy"], "legacy snapshots must survive")
ns.db.sellerScans.stale = { scannedAt = time() - 15 * 24 * 3600, offers = {} }
for i = 1, 10010 do
  ns.db.sellerScans["old" .. i] = { scannedAt = time() - 1, offers = {} }
end
search()
local retained = 0
for _ in pairs(ns.db.sellerScans) do retained = retained + 1 end
assert(retained == 10000 and not ns.db.sellerScans.stale, "capture must bound snapshot count and age")
ns.db.sellerScans = {}
local manyOffers = {}
for i = 1, 50000 do manyOffers[i] = {} end
for i = 1, 4 do
  ns.db.sellerScans["large" .. i] = { scannedAt = time() - i, offers = manyOffers }
end
rows = { { quantity = 1, buyoutAmount = 25, owners = { "SuffixSeller" }, totalNumberOfOwners = 1 } }
search()
assert(ns.db.sellerScans.large1 and not ns.db.sellerScans.large4, "offer budget must prune the oldest books first")
assert(latest("9775:584"), "offer budget must keep the newest book")
io.write("Seller capture passed: complete searches, per-unit prices, shared owners, own stock, empty results and suffixes.\n")
