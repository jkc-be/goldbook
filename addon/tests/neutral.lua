local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
local db = ns.db

local GOBLIN, ORC = {}, { faction = "Horde" }
local LINEN = { itemID = 2589, itemSuffix = 0 }

local function open(auctioneer, browse)
  Stub.auctioneer = auctioneer
  Stub.ah.browse = browse or { { itemKey = LINEN, minPrice = 100, totalQuantity = 5 } }
  Stub.fire("AUCTION_HOUSE_SHOW")
end

local function scanAt(auctioneer, browse, mode)
  local count = #db.scans
  open(auctioneer, browse)
  ns.Scanner.Start(mode or "browse")
  Stub.advance(mode == "replicate" and 20 or 1)
  Stub.fire("AUCTION_HOUSE_CLOSED")
  assert(#db.scans == count + 1, "the scan finished")
  return db.scans[#db.scans]
end

local function linen(price)
  return { { itemKey = LINEN, minPrice = price, totalQuantity = 5 } }
end

local function minPrice(market)
  return db.prices[market] and db.prices[market]["2589"] and db.prices[market]["2589"]:match("^(%d+),")
end

local scan = scanAt(GOBLIN, linen(150))
assert(scan.faction == "Neutral", "a scan at a neutral auctioneer is filed under Neutral, not " .. scan.faction)
assert(minPrice("Faramon-Neutral") == "150", "the neutral scan's prices go to the neutral market")
assert(minPrice("Faramon-Horde") == nil, "the Horde market gets no neutral price")

scan = scanAt(ORC, linen(110))
assert(scan.faction == "Horde", "a scan at a Horde auctioneer stays Horde, not " .. scan.faction)
assert(minPrice("Faramon-Horde") == "110" and minPrice("Faramon-Neutral") == "150",
  "each market keeps its own price")

scan = scanAt(nil, linen(120))
assert(scan.faction == "Horde", "without an auctioneer to ask, a scan stays with the player's faction")

open(GOBLIN)
assert(ns.RealmKey() == "Faramon-Horde", "the rest of the addon keeps the player's market at a neutral auction house")
local AH, rows = C_AuctionHouse, { { quantity = 5, buyoutAmount = 750, owners = { "Gazlowe" }, totalNumberOfOwners = 1 } }
AH.HasFullItemSearchResults = function() return true end
AH.GetNumItemSearchResults = function() return #rows end
AH.GetItemSearchResultInfo = function(_, index) return rows[index] end
Stub.fire("ITEM_SEARCH_RESULTS_UPDATED", LINEN)
Stub.advance(1.1)
Stub.fire("AUCTION_HOUSE_CLOSED")
local book
for _, snapshot in pairs(db.sellerScans) do
  if snapshot.itemKey == "2589" and (not book or snapshot.scannedAt > book.scannedAt) then
    book = snapshot
  end
end
assert(book and book.faction == "Neutral", "an order book read at a neutral auction house is filed under Neutral")

-- A full scan tells variants apart by the suffixes quick scans have seen, in
-- the player's market and in the neutral one.
local function shortsword(suffix)
  return { itemKey = { itemID = 727, itemSuffix = suffix }, minPrice = 2500, totalQuantity = 1 }
end
local function shortswordLink(suffix)
  return "|Hitem:" .. table.concat({ 727, "", "", "", "", "", "", "", "60", "", "", "", "2", "6654", suffix }, ":")
    .. "|h[Notched Shortsword of " .. suffix .. "]|h"
end
Stub.items[727] = { name = "Notched Shortsword", quality = 2, cached = true }
Stub.ah.keyInfo["727:14322"] = { itemName = "Notched Shortsword of 14322", quality = 2 }
Stub.ah.keyInfo["727:14399"] = { itemName = "Notched Shortsword of 14399", quality = 2 }
scanAt(ORC, { shortsword(14322) })
scanAt(GOBLIN, { shortsword(14399) })
Stub.ah.replicate = {
  { itemID = 727, count = 1, buyout = 2600, quality = 2, link = shortswordLink(14322) },
  { itemID = 727, count = 1, buyout = 2700, quality = 2, link = shortswordLink(14399) },
}
scan = scanAt(GOBLIN, nil, "replicate")
assert(scan.faction == "Neutral" and scan.data:find("727:14322,2600,", 1, true) and scan.data:find("727:14399,2700,", 1, true),
  "a neutral full scan files variants by suffixes seen in either market: " .. scan.data)

-- Automatic scans wait 15 minutes per market.
local function autoScanAt(auctioneer)
  local count = #db.scans
  open(auctioneer)
  Stub.advance(2)
  Stub.fire("AUCTION_HOUSE_CLOSED")
  return #db.scans > count and db.scans[#db.scans].faction or "none"
end
Stub.advance(16 * 60)
db.settings.autoScan = true
assert(autoScanAt(GOBLIN) == "Neutral", "a stale neutral market scans itself")
assert(autoScanAt(GOBLIN) == "none", "a fresh neutral market does not scan again while the Horde one is stale")
assert(autoScanAt(ORC) == "Horde", "a stale Horde market scans itself")
Stub.advance(16 * 60)
assert(autoScanAt(ORC) == "Horde", "the Horde market scans itself again once stale")
assert(autoScanAt(GOBLIN) == "Neutral", "a stale neutral market scans itself while the Horde one is fresh")
io.write("Neutral auction house regressions passed.\n")
