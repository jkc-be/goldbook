-- A character that never scanned its realm, with only the prices the Goldbook
-- app brought from the server: the advice it gets and the scan it names.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
dofile(here .. "/auctionstub.lua")(Stub)
local ns = Stub.loadAddon(here .. "/../Goldbook")

local checks, failures = 0, 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(label, tostring(expected), tostring(actual)))
  end
end
local function plain(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function tooltip(link)
  GameTooltip.lines, GameTooltip.itemLink = {}, link
  Stub.tooltipCalls[1](GameTooltip)
  return plain(table.concat(GameTooltip.lines, " / "))
end

local DAY = 86400
local now = time()
local served = now - 600
local today = math.floor(served / DAY)
-- Linen Cloth sold for 3g the days before and is listed at 1g in the server's
-- newest scan, Silk Cloth at 2g 50s. Wool Cloth was last seen a day earlier.
GoldbookServerData = {
  version = 1, server = "x",
  items = { ["2589"] = "1|Linen Cloth", ["2592"] = "1|Wool Cloth", ["4306"] = "1|Silk Cloth" },
  realms = { ["Faramon-Horde"] = {
    scannedAt = served,
    prices = {
      ["2589"] = "10000,50,3," .. served .. ",0,0",
      ["4306"] = "25000,20,2," .. served .. ",0,0",
      ["2592"] = "10,5,1," .. (served - DAY) .. ",0,0",
    },
    days = {
      ["2589"] = ("%d:30000:1:0,%d:30000:1:0,%d:30000:1:0,%d:10000:50:0"):format(today - 3, today - 2, today - 1, today),
      ["4306"] = ("%d:30000:1:0,%d:30000:1:0,%d:30000:1:0,%d:25000:20:0"):format(today - 3, today - 2, today - 1, today),
    },
  } },
}
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
UIParent:SetSize(1920, 1080)
local db, key, Advisor = GoldbookDB, ns.RealmKey(), ns.Advisor

local deals = Advisor.Deals(db, key, 0)
eq(#deals .. " " .. (deals[1] and deals[1].key .. " " .. deals[1].total or "-"), "1 2589 18500", "Linen Cloth in the server's newest scan is a deal")
local movers = {}
for index, item in ipairs(Advisor.Movers(db, key)) do
  movers[index] = item.key .. " " .. item.change
end
eq(table.concat(movers, ", "), "4306 -16.7, 2589 -66.7", "the items of the server's newest scan move")
local sold = Advisor.Sell(db, key, { { key = "4306", count = 1 } })
eq(sold[1].action .. " " .. tostring(sold[1].post), "auction 24999", "the bags post Silk Cloth under the server's newest listing")
eq(tooltip("|Hitem:4306::::::|h[Silk Cloth]|h"),
  "  / Goldbook = 20 listed, seen 10m ago, from the server /   Min buyout = 2g 50s 00c /   Usual over 4 days = 3g 00s 00c"
    .. " /   Post at = 2g 49s 99c /   Alt+click: price history",
  "the tooltip posts under the server's newest listing")
eq(tooltip("|Hitem:2589::::::|h[Linen Cloth]|h"),
  "  / Goldbook = 50 listed, seen 10m ago, from the server /   Min buyout = 1g 00s 00c /   Usual over 4 days = 3g 00s 00c"
    .. " /   Post at = 3g 00s 00c /   Deal: resells for 3g 00s 00c, profit 1g 85s 00c each /   Alt+click: price history",
  "the tooltip points out the deal")
ns.UI.Show("deals")
eq(plain(GoldbookWindow.lastScan.text), "Server scan 10m ago", "the rail dates the server's scan")
eq(GoldbookWindow.head.sub.text, "1 in the scan of 10m ago, from the server", "the deals view says whose scan it is")
Stub.fire("AUCTION_HOUSE_SHOW")
SlashCmdList.GOLDBOOK("ah")
local panel = GoldbookAuctionHouse
panel.search:SetText("Mithril")
panel.searchButton.scripts.OnClick(panel.searchButton)
eq(panel.scanTime.text, "Last scan: " .. date("%d %b %H:%M", served) .. " (10m ago, from the server)\nRun at least a Quick scan for a fresh reference.",
  "the auction house window dates the server's scan")
eq(panel.empty.text, "No matching scan prices. Clear filters or run a Quick scan.", "and does not ask for a first scan")
Stub.fire("AUCTION_HOUSE_CLOSED")
db.settings.autoScan = true
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.advance(1)
eq(ns.Scanner.state, "scanning", "opening the auction house still runs the quick scan")
ns.Database.ApplyScan(db, { realm = "Faramon", faction = "Horde", region = "EU", at = now, mode = "browse", by = "Sultan",
  build = "1.60.1.70338", rows = { { key = "2592", min = 9, qty = 1, n = 0, mv = 0 } }, names = {} })
eq(#Advisor.Deals(db, key, 0), 0, "the server's older listing is no longer a deal")
ns.UI.Show("deals")
eq(plain(GoldbookWindow.lastScan.text), "Last scan just now", "the rail dates the scan here")

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
