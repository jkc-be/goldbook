-- A client that answers "" for both realm names, as WoW Forever does since
-- its update of 2026-11-20: the realm GoldbookDB recorded stands in, and what
-- was filed under the blank realm moves to it.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
local Database = ns.Database

local checks, failures = 0, 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(label, tostring(expected), tostring(actual)))
  end
end
local function plain(text)
  return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
local function serialize(value)
  if type(value) ~= "table" then
    return type(value) == "string" and ("%q"):format(value) or tostring(value)
  end
  local keys, out = {}, {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for index, key in ipairs(keys) do
    out[index] = tostring(key) .. "=" .. serialize(value[key])
  end
  return "{" .. table.concat(out, ",") .. "}"
end
local function keys(list)
  local names = {}
  for key in pairs(list) do
    names[#names + 1] = tostring(key)
  end
  table.sort(names)
  return table.concat(names, " ")
end
local NO_REALM = "Goldbook The game gives no realm name, so Goldbook cannot tell which auction house this is and shows no prices."
local function warnings()
  local count = 0
  for _, text in ipairs(Stub.printed) do
    count = count + (plain(text) == NO_REALM and 1 or 0)
  end
  return count
end

local REALM = "CAMWOWEU4Realm8PvP"
local NOW = time()
local HOUR = math.floor(NOW / 3600)
eq(NOW .. " " .. HOUR, "1760000000 488888", "the stub's clock")

-- What the affected player's file held, in small: the character's entries
-- from before the update under its realm, and those since under none.
local function saved()
  return {
    version = 6,
    characters = {
      ["Sultan-" .. REALM] = { name = "Sultan", realm = REALM, faction = "Horde", class = "WARRIOR", level = 59, at = NOW - 86400 },
      ["Mirelle-" .. REALM] = { name = "Mirelle", realm = REALM, faction = "Horde", class = "MAGE", level = 20, at = NOW - 3600 },
      ["Sultan-"] = { name = "Sultan", realm = "", faction = "Horde", class = "WARRIOR", level = 60, at = NOW - 600 },
    },
    bags = { ["Sultan-" .. REALM] = { { key = "2589", count = 5 } }, ["Sultan-"] = { { key = "2589", count = 9 } } },
    bank = { ["Sultan-"] = { at = NOW - 700, items = { { key = "2592", count = 3 } } } },
    gold = { ["Sultan-" .. REALM] = { [HOUR - 30] = 100, [HOUR - 2] = 500 }, ["Sultan-"] = { [HOUR - 2] = 700, [HOUR - 1] = 900 } },
    trades = {
      ["Sultan-" .. REALM] = {
        { at = NOW - 90000, side = "sell", item = "Linen Cloth", key = "2589", count = 20, price = 2000, fee = 100 },
      },
      ["Sultan-"] = {
        { at = NOW - 89940, side = "sell", item = "Linen Cloth", key = "2589", count = 20, price = 2000, fee = 100 },
        { at = NOW - 650, side = "repair", item = "Repairs", count = 1, price = 300, fee = 0 },
      },
    },
    accruing = {
      ["Sultan-" .. REALM] = { loot = { at = HOUR * 3600, side = "loot", item = "Looted gold", count = 2, price = 50, fee = 0 } },
      ["Sultan-"] = {
        loot = { at = HOUR * 3600, side = "loot", item = "Looted gold", count = 3, price = 70, fee = 0 },
        otherOut = { at = HOUR * 3600, side = "otherOut", item = "Other", count = 1, price = 10, fee = 0 },
      },
    },
    recipes = { ["Sultan-" .. REALM] = { [2018] = true }, ["Sultan-"] = { [2020] = true } },
    sellerScans = {
      [REALM .. "|Horde|2589|" .. NOW - 90000] = { realm = REALM, faction = "Horde", itemKey = "2589", scannedAt = NOW - 90000, offers = {} },
      ["|Horde|2589|" .. NOW - 500] = { realm = "", faction = "Horde", itemKey = "2589", scannedAt = NOW - 500, offers = {
        { unitPrice = 100, quantity = 5, owners = { "Sultan-", "Zed" }, totalOwners = 2 },
      } },
    },
    scans = { { realm = "", faction = "Horde", region = "EU", at = NOW - 500, mode = "browse", by = "Sultan", build = "1.60.1.70338", count = 0, data = "" } },
    prices = {
      [REALM .. "-Horde"] = {
        ["2589"] = "120,40,3," .. NOW - 90000 .. ",125," .. NOW - 90000 .. ";120;",
        ["4306"] = "900,4,1," .. NOW - 100 .. ",0,0;900;",
      },
      ["-Horde"] = {
        ["2589"] = "100,50,2," .. NOW - 500 .. ",0,0;100;",
        ["4306"] = "950,6,2," .. NOW - 500 .. ",940," .. NOW - 500 .. ";950;",
        ["2592"] = "300,7,1," .. NOW - 500 .. ",0,0;300;",
      },
    },
    history = {
      [REALM .. "-Horde"] = { ["2589"] = "20369:120:40:125", ["4306"] = "20370:900:4:0" },
      ["-Horde"] = { ["2589"] = "20370:100:50:0", ["4306"] = "20370:950:6:940", ["2592"] = "20370:300:7:0" },
    },
    hours = {
      [REALM .. "-Horde"] = { ["2589"] = "488863:120:40:125" },
      ["-Horde"] = { ["2589"] = "488887:100:50:0" },
    },
    scanned = { [REALM .. "-Horde"] = NOW - 90000, ["-Horde"] = NOW - 500 },
    fromServer = { [REALM .. "-Horde"] = { ["2589"] = NOW - 90000 } },
    items = { ["2589"] = "1|Linen Cloth", ["2592"] = "1|Wool Cloth", ["4306"] = "1|Silk Cloth" },
  }
end

local function login(db)
  GoldbookDB = db
  Stub.fire("ADDON_LOADED", "Goldbook")
  Stub.fire("PLAYER_LOGIN")
end
local function tooltip()
  GameTooltip.lines, GameTooltip.itemLink = {}, "|Hitem:2589::::::|h[Linen Cloth]|h"
  Stub.tooltipCalls[1](GameTooltip)
  return plain(table.concat(GameTooltip.lines, " / "))
end
Stub.items[2589] = { name = "Linen Cloth", quality = 1, vendor = 13, cached = true }
Stub.money = 1000

local normalized, shown = GetNormalizedRealmName, GetRealmName
function GetNormalizedRealmName()
  return ""
end
function GetRealmName()
  return ""
end

login(nil)
eq(ns.RealmKey() .. " " .. ns.CharacterKey(), "-Horde Sultan-", "without a realm from the game or the file, the realm is unknown")
eq(plain(Stub.printed[#Stub.printed]), NO_REALM, "an unknown realm is said at login")
eq(warnings(), 1, "and said once")

login(saved())
local db = GoldbookDB
eq(ns.RealmKey() .. " " .. ns.CharacterKey(), REALM .. "-Horde Sultan-" .. REALM, "the realm recorded for the character stands in")
eq(ns.MarketName(), "EU PvP-Horde", "and names its auction house")
eq(warnings(), 1, "a recorded realm needs no warning")
eq(tooltip(), "  / Goldbook = 50 listed, seen 8m ago /   Min buyout = 1s 00c /   Market value (1d ago) = 1s 25c /   Post at = 99c /   Vendor = 13c /   Alt+click: price history",
  "the tooltip finds the price again")

eq(keys(db.characters), "Mirelle-" .. REALM .. " Sultan-" .. REALM, "the blank character entry is gone")
local sultan = db.characters["Sultan-" .. REALM]
eq(sultan.realm .. " " .. sultan.level .. " " .. sultan.at, REALM .. " 60 1759999400", "the newer logout snapshot is kept, with its realm")
eq(keys(db.bags) .. " " .. db.bags["Sultan-" .. REALM][1].count, "Sultan-" .. REALM .. " 9", "the bags as last seen")
eq(keys(db.bank) .. " " .. db.bank["Sultan-" .. REALM].items[1].key, "Sultan-" .. REALM .. " 2592", "a bank the realm lacked moves as it is")
eq(keys(db.gold) .. " " .. serialize(db.gold["Sultan-" .. REALM]), "Sultan-" .. REALM .. " {488858=100,488886=700,488887=900,488888=1000}",
  "the hours of gold are joined, the later balance of an hour kept")
local trades = {}
for index, trade in ipairs(db.trades["Sultan-" .. REALM]) do
  trades[index] = trade.side .. ":" .. trade.at
end
eq(keys(db.trades) .. " " .. table.concat(trades, " "), "Sultan-" .. REALM .. " sell:1759910000 repair:1759999350",
  "trades are joined oldest first, and a sale the mailbox showed again is booked once")
eq(keys(db.accruing) .. " " .. serialize(db.accruing["Sultan-" .. REALM]),
  "Sultan-" .. REALM .. ' {loot={at=1759996800,count=5,fee=0,item="Looted gold",price=120,side="loot"},otherOut={at=1759996800,count=1,fee=0,item="Other",price=10,side="otherOut"}}',
  "gold adding up this hour is added together")
eq(keys(db.recipes) .. " " .. keys(db.recipes["Sultan-" .. REALM]), "Sultan-" .. REALM .. " 2018 2020", "known recipes are joined")

eq(keys(db.sellerScans), REALM .. "|Horde|2589|1759910000 " .. REALM .. "|Horde|2589|1759999500", "seller snapshots are filed under the realm")
local snapshot = db.sellerScans[REALM .. "|Horde|2589|1759999500"]
eq(snapshot.realm .. " " .. table.concat(snapshot.offers[1].owners, " "), REALM .. " Sultan-" .. REALM .. " Zed", "with the realm in them and in the character's name")
eq(db.scans[1].realm, REALM, "a queued scan gets the realm")

eq(keys(db.prices) .. " / " .. keys(db.history) .. " / " .. keys(db.hours) .. " / " .. keys(db.scanned) .. " / " .. keys(db.fromServer),
  (REALM .. "-Horde / "):rep(4) .. REALM .. "-Horde", "the blank market is gone")
local market = REALM .. "-Horde"
eq(db.prices[market]["2589"], "100,50,2,1759999500,125,1759910000;120,100;", "the price seen later wins and keeps the market value measured last")
eq(db.prices[market]["4306"], "900,4,1,1759999900,940,1759999500;900;", "a price the realm saw later stays and takes a later market value")
eq(db.prices[market]["2592"], "300,7,1,1759999500,0,0;300;", "a price the realm lacked moves as it is")
eq(db.history[market]["2589"] .. " / " .. db.history[market]["4306"] .. " / " .. db.history[market]["2592"],
  "20369:120:40:125,20370:100:50:0 / 20370:900:4:940 / 20370:300:7:0", "days are joined, a day both have keeps its lowest price")
eq(db.hours[market]["2589"], "488863:120:40:125,488887:100:50:0", "hours are joined")
eq(db.scanned[market], 1759999500, "the newest scan time is kept")
eq(tostring(Database.FromServer(db, market, "2589")), "false", "a price scanned since is no longer the server's")

local before = serialize(db)
Stub.fire("PLAYER_LOGIN")
eq(serialize(db) == before, true, "a second login changes nothing")
Database.MoveBlankRealm(db, "Sultan", "Horde", REALM, NOW)
eq(serialize(db) == before, true, "moving again changes nothing")

Stub.fire("AUCTION_HOUSE_SHOW")
local AH = C_AuctionHouse
AH.HasFullCommoditySearchResults = function() return true end
AH.GetNumCommoditySearchResults = function() return 1 end
AH.GetCommoditySearchResultInfo = function() return { quantity = 8, unitPrice = 300, owners = { "player" }, totalNumberOfOwners = 1 } end
Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 7070)
Stub.advance(1.1)
local own = db.sellerScans[REALM .. "|Horde|7070|" .. time()]
eq(own and own.realm .. " " .. own.offers[1].owners[1], REALM .. " Sultan-" .. REALM, "a seller snapshot taken without a realm from the game is filed under the recorded one")
Stub.fire("AUCTION_HOUSE_CLOSED")
Stub.fire("PLAYER_LOGOUT")
eq(keys(db.characters), "Mirelle-" .. REALM .. " Sultan-" .. REALM, "logout saves the character under the recorded realm")

-- With characters on several realms, a blank market could be either's.
local several = saved()
several.characters["Thrall-Faramon"] = { name = "Thrall", realm = "Faramon", faction = "Horde", class = "SHAMAN", level = 60, at = NOW - 60 }
several.sellerScans["|Alliance|2589|" .. NOW - 400] = { realm = "", faction = "Alliance", itemKey = "2589", scannedAt = NOW - 400, offers = {} }
several.scans[2] = { realm = "", faction = "Alliance", by = "Jaina", at = NOW - 400 }
several = Database.Init(several)
eq(Database.RecordedRealm(several, "Sultan"), REALM, "a character's own realm is preferred to a newer one of another character")
eq(Database.RecordedRealm(several, "Jaina"), "Faramon", "a character without one takes the newest of the account")
eq(Database.RecordedRealm({ characters = { ["Sultan-"] = several.characters["Sultan-"] } }, "Sultan"), "", "a blank entry records no realm")
eq(Database.RecordedRealm({ characters = {
  ["Sultan-Old"] = { name = "Sultan" },
  ["Sultan-Undated"] = { name = "Sultan", realm = "Undated" },
  ["Sultan-" .. REALM] = { name = "Sultan", realm = REALM, at = 1 },
} }, "Sultan"), REALM, "an entry without a realm or a time is passed over, not an error")
Database.MoveBlankRealm(several, "Sultan", "Horde", REALM, NOW)
eq(keys(several.prices) .. " / " .. keys(several.scanned), "-Horde " .. REALM .. "-Horde / -Horde " .. REALM .. "-Horde", "the blank market stays")
eq(several.prices["-Horde"]["2589"], "100,50,2,1759999500,0,0;100;", "as it was")
eq(keys(several.gold) .. " / " .. keys(several.sellerScans),
  "Sultan-" .. REALM .. " / " .. REALM .. "|Horde|2589|1759910000 " .. REALM .. "|Horde|2589|1759999500 |Alliance|2589|1759999600",
  "the character's own entries and its faction's seller snapshots still move")
eq(several.scans[1].realm .. "/" .. several.scans[2].realm, REALM .. "/", "and so does its own queued scan, not another character's")

-- A snapshot already filed under the realm for the same second keeps its place.
local taken = Database.Init({
  characters = { ["Sultan-" .. REALM] = { name = "Sultan", realm = REALM, at = NOW } },
  sellerScans = {
    ["|Horde|2589|5"] = { realm = "", faction = "Horde", itemKey = "2589", scannedAt = 5, offers = { { unitPrice = 1, quantity = 1, owners = {}, totalOwners = 0 } } },
    [REALM .. "|Horde|2589|5"] = { realm = REALM, faction = "Horde", itemKey = "2589", scannedAt = 5, offers = {} },
  },
})
Database.MoveBlankRealm(taken, "Sultan", "Horde", REALM, NOW)
eq(keys(taken.sellerScans) .. " " .. #taken.sellerScans[REALM .. "|Horde|2589|5|000001"].offers,
  REALM .. "|Horde|2589|5 " .. REALM .. "|Horde|2589|5|000001 1", "a moved snapshot never replaces one")

GetNormalizedRealmName, GetRealmName = normalized, shown
login(saved())
eq(ns.RealmKey() .. " " .. ns.CharacterKey(), "Faramon-Horde Sultan-Faramon", "a realm the game names is used as before")
eq(GoldbookDB.characters["Sultan-"].realm .. " " .. keys(GoldbookDB.prices), " -Horde " .. REALM .. "-Horde", "and nothing is moved")
function GetNormalizedRealmName()
  return ""
end
eq(ns.Scanner.Realm(), "Fara'mon", "a blank normalized name falls back to the display name")
GetNormalizedRealmName = normalized
eq(warnings(), 1, "no warning when the game names the realm")

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
