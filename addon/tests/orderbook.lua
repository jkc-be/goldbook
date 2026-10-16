local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.items[2770] = { name = "Copper Ore", cached = true }
Stub.items[2840] = { name = "Copper Bar", cached = true }
local function listing(itemID, count, buyout, owner)
  return { itemID = itemID, count = count, buyout = buyout, ownerFullName = owner,
    link = "|Hitem:" .. itemID .. "|h[" .. Stub.items[itemID].name .. "]|h" }
end
local function history(key)
  local rows = {}
  for _, snapshot in pairs(ns.db.sellerScans) do
    if snapshot.itemKey == key then rows[#rows + 1] = snapshot end
  end
  table.sort(rows, function(a, b) return a.scannedAt < b.scannedAt end)
  return rows
end
local function full()
  ns.db.settings.lastReplicate = 0
  ns.Scanner.Start("replicate")
  Stub.advance(10)
end
Stub.ah.replicate = {
  listing(2770, 10, 1000, "Alice-Faramon"),
  listing(2770, 5, 500, "Alice-Faramon"),
  listing(2770, 7, 1400),
  listing(2770, 3, 0, "BidOnly"),
  listing(2840, 4, 2000, "Bob-Faramon"),
}
Stub.ah.replicate[5].loadsAt = Stub.clock + 2
full()
local ore, bar = history("2770")[1], history("2840")[1]
assert(ore and bar, "a full scan must queue order books without individual searches")
assert(#ore.offers == 2, "same seller and unit price must aggregate; bid-only listings are excluded")
local byPrice = {}
for _, offer in ipairs(ore.offers) do byPrice[offer.unitPrice] = offer end
assert(byPrice[100].quantity == 15 and byPrice[100].owners[1] == "Alice-Faramon")
assert(byPrice[200].quantity == 7 and #byPrice[200].owners == 0, "unknown sellers still contribute stock")
assert(#bar.offers == 1 and bar.offers[1].quantity == 4, "cold-cache retries must not duplicate listings")

Stub.ah.replicate = { listing(2840, 2, 1200, "Bob-Faramon") }
full()
assert(#history("2770") == 2 and #history("2770")[2].offers == 0, "a disappeared item needs an empty book")
assert(history("2840")[2].offers[1].unitPrice == 600, "a later full scan is a new observation")
assert(ore.offers[1].quantity > 0, "historical books must remain unchanged")

local function serialize(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local out = { "{" }
  for _, v in ipairs(value) do out[#out + 1] = serialize(v) .. "," end
  for k, v in pairs(value) do
    if type(k) ~= "number" then
      out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(v) .. ","
    end
  end
  out[#out + 1] = "}"
  return table.concat(out)
end
if arg[1] then
  local output = assert(io.open(arg[1], "w"))
  output:write("GoldbookDB = ", serialize({ items = {}, scans = {}, sellerScans = ns.db.sellerScans }), "\n")
  output:close()
end

ns.db.settings.lastReplicate = 0
ns.Scanner.Start("replicate")
Stub.fire("AUCTION_HOUSE_CLOSED")
Stub.advance(10)
assert(#history("2840") == 2, "a cancelled full scan must not publish a partial book")
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.items[863] = { name = "Gloom Reaper", cached = true }
Stub.ah.replicate = {
  listing(863, 1, 200, "Alice"),
  { itemID = 863, count = 1, buyout = 400,
    link = "|Hitem:863::::::::60::::1:14999|h[Gloom Reaper of Stamina]|h" },
}
full()
assert(#history("863") == 0, "unresolved variants must not publish an incomplete base-item book")
assert(#history("2840") == 2, "an incomplete full scan cannot establish that an old item disappeared")
io.write("Full-scan order books passed: collection, aggregation, owners, retries, empty stock and cancellation.\n")
