local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = {}
for _, file in ipairs({ "Stats", "Codec", "Scanner" }) do
  assert(loadfile(here .. "/../Goldbook/" .. file .. ".lua"))("Goldbook", ns)
end

local completed = {}
ns.Scanner.Subscribe(function(kind, scan)
  if kind == "done" then
    completed[#completed + 1] = scan
  end
end)
Stub.ah.browse = {
  { itemKey = { itemID = 9775, itemSuffix = 584 }, minPrice = 25000, totalQuantity = 1 },
  { itemKey = { itemID = 9775, itemSuffix = 585 }, minPrice = 30000, totalQuantity = 1 },
}
Stub.fire("AUCTION_HOUSE_SHOW")
ns.Scanner.Start("browse")
Stub.advance(0.2)
assert(#completed == 0, "a cold-cache final page must wait for its suffix names")
Stub.ah.keyInfo["9775:584"] = { itemName = "Bandit Cinch of the Monkey", quality = 2 }
Stub.ah.keyInfo["9775:585"] = { itemName = "Bandit Cinch of the Eagle", quality = 2 }
Stub.fire("ITEM_KEY_ITEM_INFO_RECEIVED", 9775)
assert(#completed == 1, "the item-info event must complete the scan")
assert(completed[1].names["9775:584"].name == "Bandit Cinch of the Monkey")
assert(completed[1].names["9775:585"].name == "Bandit Cinch of the Eagle")

-- A missing reply must not hold the scan forever, or discard names that arrived.
Stub.ah.keyInfo = {}
ns.Scanner.Start("browse")
Stub.advance(0.2)
Stub.ah.keyInfo["9775:584"] = { itemName = "Bandit Cinch of the Monkey", quality = 2 }
Stub.fire("ITEM_KEY_ITEM_INFO_RECEIVED", 9775)
assert(#completed == 1, "the scan must still wait for the second variant")
Stub.advance(5)
assert(#completed == 2, "the scan must finish after the name timeout")
assert(completed[2].names["9775:584"].name == "Bandit Cinch of the Monkey")
assert(completed[2].names["9775:585"] == nil)

-- An old timeout must leave a newer scan alone.
Stub.ah.keyInfo = {}
ns.Scanner.Start("browse")
Stub.advance(0.2)
Stub.fire("AUCTION_HOUSE_CLOSED")
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.ah.silent = true
ns.Scanner.Start("browse")
Stub.advance(5)
assert(ns.Scanner.state == "scanning" and #completed == 2, "a cancelled scan's timeout must be ignored")
Stub.fire("AUCTION_HOUSE_CLOSED")
io.write("Scanner suffix-name regressions passed.\n")
