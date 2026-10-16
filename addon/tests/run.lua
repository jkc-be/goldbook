-- Loads the addon the way the client does (files in .toc order, shared
-- namespace), drives it through scans, and writes the resulting
-- SavedVariables file to fixtures/Goldbook.lua for the sync agent's tests.
-- Those tests expect exactly the three scans queued below.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")

local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")

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

local function lastPrint()
  return plain(Stub.printed[#Stub.printed])
end

local Stats, Codec, Database, Scanner, Advisor, Ledger = ns.Stats, ns.Codec, ns.Database, ns.Scanner, ns.Advisor, ns.Ledger

local function listings(...)
  local list = {}
  for _, pair in ipairs({ ... }) do
    list[#list + 1] = { price = pair[1], count = pair[2] }
  end
  return list
end

eq(Stats.MarketValue(listings({ 500, 70 }, { 110, 10 }, { 100, 10 }, { 105, 10 })), 105, "market value ignores the expensive 70%")
eq(Stats.MarketValue(listings({ 100, 1 }, { 300, 9 })), 233, "market value keeps the cheapest 15% across a price step")
eq(Stats.MarketValue(listings({ 100, 2 }, { 200, 8 })), 100, "market value stops at a 20% price step")
eq(Stats.MarketValue(listings({ 50, 1 }, { 100, 5 }, { 1000, 14 })), 100, "market value drops a low outlier")
eq(Stats.MarketValue(listings({ 7, 1 })), 7, "market value of one auction")
eq(Stats.MarketValue({}), nil, "market value of nothing")
eq(Stats.Median({ 300, 100, 200 }), 200, "median of an odd count")
eq(Stats.Median({ 100, 400, 200, 301 }), 251, "median of an even count rounds the midpoint")
eq(Stats.Median({}), nil, "median of nothing")
local summary = Stats.Summarize(listings({ 300, 2 }, { 100, 1 }, { 100, 4 }, { 200, 3 }, { 400, 1 }, { 500, 1 }, { 600, 9 }))
local levels = {}
for index, level in ipairs(summary.ladder) do
  levels[index] = level.price .. ":" .. level.count
end
eq(table.concat(levels, " "), "100:5 200:3 300:2 400:1 500:1", "ladder keeps the five cheapest price levels")
eq(summary.min .. " " .. summary.qty .. " " .. summary.n, "100 21 7", "summary counts units and auctions")

eq(Codec.KeyFromLink("|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"), "2589", "key of a plain item")
eq(Codec.KeyFromLink("|cff1eff00|Hitem:9775:0:0:0:0:0:584:1111:60|h[Bandit Cinch of the Monkey]|h|r"), "9775:584", "key keeps the suffix")
eq(Codec.KeyFromLink("|Hitem:9775:0:0:0:0:0:-12:1111|h[x]|h"), "9775:-12", "key keeps a negative suffix")
eq(Codec.KeyFromLink("|Hspell:133|h[Fireball]|h"), nil, "key of a non-item link")
local bonusLink = "|Hitem:" .. table.concat({ 727, "", "", "", "", "", "", "", "60", "", "", "", "2", "6654", "14322" }, ":") .. "|h[Notched Shortsword of Healing]|h"
eq(Codec.KeyFromLink(bonusLink, { [14322] = true }), "727:14322", "a known suffix is found among the bonus ids")
eq(Codec.KeyFromLink(bonusLink, { [14399] = true }), "727", "an unknown bonus id is not taken for a suffix")
eq(Codec.KeyFromLink(bonusLink), "727", "without known suffixes the bonus ids are ignored")
eq(Codec.ItemKey(4000000000), "4000000000", "item key above 2^31")
eq(Codec.ItemString("2589"), "item:2589:0:0:0:0:0:0", "item string of a plain item")
eq(Codec.ItemString("9775:-12"), "item:9775:0:0:0:0:0:-12", "item string keeps the suffix")
eq(plain(Codec.Money(123456)), "12g 34s 56c", "money")
eq(plain(Codec.Money(10000)), "1g 0s 0c", "money, round gold")
eq(plain(Codec.Money(5)), "5c", "money, copper only")
eq(Codec.Age(30), "just now", "age under a minute")
eq(Codec.Age(7200), "2h ago", "age in hours")
eq(Codec.Age(200000), "2d ago", "age in days")
local counted = 0
eq(Codec.RandomCode(32, function()
  counted = counted + 1
  return counted
end), "0123456789ABCDEFGHJKMNPQRSTVWXYZ", "codes are drawn from Crockford's base32, without I, L, O and U")
local stepped = 0
eq(Codec.RandomCode(8, function(n)
  stepped = stepped + 1
  return stepped * 7 % n + 1
end), "7ENW3AHR", "each character is drawn from the 32")
eq(Codec.Grouped("K7Q2M9PX", 4), "K7Q2-M9PX", "an ID shows in groups of 4")
eq(Codec.Grouped("7KQ2M9PXABCDEFGHJKMN", 5), "7KQ2M-9PXAB-CDEFG-HJKMN", "a key shows in groups of 5")

local NOW = 20000 * 86400
local function record(fields)
  local base = { min = 100, qty = 1, n = 0, seen = NOW, mv = 0, mvAt = 0, days = { 100 }, ladder = {} }
  for name, value in pairs(fields) do
    base[name] = value
  end
  return base
end

eq(Advisor.Proceeds(100), 95, "the auction house keeps 5%")
eq(Advisor.Usual(record({ days = { 100, 300, 200 } })), 200, "usual price is the median day")
eq(Advisor.Usual(record({ days = { 100, 300 } })), nil, "no usual price from two days")

local flip = Advisor.Deal(record({ min = 60, days = { 100, 110, 90, 60 } }), 0, NOW)
eq(flip.kind .. " " .. flip.sell .. " " .. flip.profit, "flip 100 35", "priced under 70% of earlier days is a flip")
eq(Advisor.Deal(record({ min = 75, days = { 100, 110, 90, 75 } }), 0, NOW), nil, "priced at 75% of earlier days is no deal")
eq(Advisor.Deal(record({ min = 60, days = { 100, 110, 60 } }), 0, NOW), nil, "two earlier days are not enough history")
eq(Advisor.Deal(record({ min = 60, days = { 100, 110, 90, 60 } }), 0, NOW + 60), nil, "an item missing from the newest scan is no deal")
local market = Advisor.Deal(record({ min = 50, mv = 100, mvAt = NOW, days = { 50 } }), 0, NOW)
eq(market.kind .. " " .. market.sell .. " " .. market.profit, "flip 100 45", "priced under today's market value is a flip")
eq(Advisor.Deal(record({ min = 50, mv = 100, mvAt = NOW - 86400, days = { 50 } }), 0, NOW), nil, "an old market value proves nothing")
local careful = Advisor.Deal(record({ min = 60, mv = 200, mvAt = NOW, days = { 100, 110, 90, 60 } }), 0, NOW)
eq(careful.sell, 100, "the lower of market value and earlier days is the resale price")
local vendored = Advisor.Deal(record({ min = 40, days = { 40 } }), 55, NOW)
eq(vendored.kind .. " " .. vendored.sell .. " " .. vendored.profit, "vendor 55 15", "priced under what a vendor pays is a vendor deal")
eq(tostring(vendored.units) .. " " .. vendored.total, "nil 15", "a quick scan knows of one unit")
local stocked = Advisor.Deal(record({
  min = 50, mv = 100, mvAt = NOW, days = { 50 },
  ladder = { { price = 50, count = 2 }, { price = 60, count = 3 }, { price = 95, count = 10 } },
}), 0, NOW)
eq(stocked.units .. " " .. stocked.total, "5 195", "a full scan counts the units worth buying and what they make")
local scrap = Advisor.Deal(record({ min = 40, ladder = { { price = 40, count = 4 }, { price = 55, count = 9 } } }), 55, NOW)
eq(scrap.units .. " " .. scrap.total, "4 60", "vendor deals stop at the vendor price")

eq(Advisor.PostPrice(record({ min = 100 }), 0, NOW), 99, "post one copper under the lowest listing")
eq(Advisor.PostPrice(record({ min = 100 }), 95, NOW), 101, "never post where the cut leaves less than a vendor pays")
eq(Advisor.PostPrice(record({ min = 30, days = { 100, 100, 100, 30 } }), 0, NOW), 100, "do not chase a listing under 60% of the usual price")
eq(Advisor.PostPrice(record({ min = 500, days = { 100, 100, 100, 500 } }), 0, NOW), 200, "do not post above twice the usual price")
eq(Advisor.PostPrice(record({ min = 80, seen = NOW - 60, mv = 120, mvAt = NOW - 60 }), 0, NOW), 120, "post at the market value when nobody is listing")

eq(Advisor.Deal(record({ min = 60, days = { 100, 110, 90, 60 } }), 0, NOW, true), nil, "what merchants sell is no flip")
local stockedVendor = Advisor.Deal(record({ min = 40, days = { 100, 110, 90, 40 } }), 55, NOW, true)
eq(stockedVendor.kind .. " " .. stockedVendor.sell, "vendor 55", "what merchants sell is still a vendor deal")

local shop = Database.Init(nil)
eq(tostring(Database.MerchantSells(shop, "3857")) .. " " .. tostring(Database.MerchantPrice(shop, "3857")), "true nil",
  "coal is known to be sold by merchants before one is seen")
eq(Database.MerchantSells(shop, "2589"), false, "linen cloth is not")
Database.SetMerchantPrice(shop, 2589, 5, 98)
Database.SetMerchantPrice(shop, 2589, 1, 25)
eq(tostring(Database.MerchantSells(shop, "2589:584")) .. " " .. Database.MerchantPrice(shop, "2589"), "true 20",
  "a merchant seen selling an item keeps its lowest price per unit")
shop.vendor[2865] = 962
Database.SetVendorPaid(shop, "2865", 2, 1154)
eq(Database.Vendor(shop, "2865"), 577, "what a vendor paid outranks the item's data")
local sold = Database.Init({ vendor = { [2865] = 962 }, trades = { A = { { side = "vendor", key = "2865", count = 3, price = 1731 } } } })
eq(Database.Vendor(sold, "2865"), 577, "vendor sales booked earlier say what a vendor pays")
shop.scanned.R = NOW
shop.prices.R = {
  ["3857"] = Codec.EncodePrice(record({ min = 2000, days = { 3000, 3000, 3000, 2000 } })),
  ["2592"] = Codec.EncodePrice(record({ min = 2000, days = { 3000, 3000, 3000, 2000 } })),
}
shop.vendor[3857] = 125
local found = {}
for index, item in ipairs(Advisor.Deals(shop, "R", 0)) do
  found[index] = item.key .. " " .. item.kind
end
eq(table.concat(found, ", "), "2592 flip", "the deals leave out flips of what merchants sell")
local coal = Advisor.Sell(shop, "R", { { key = "3857", count = 10 } })[1]
eq(coal.action .. " " .. tostring(coal.post) .. " " .. coal.value, "vendor nil 1250", "what merchants sell is worth what a vendor pays")

local books = Database.Init(nil)
local DAY, HOUR = 86400, 3600
-- A character's gold as "hour:copper", oldest first.
local function stored(hours)
  local entries = {}
  for hour in pairs(hours) do
    entries[#entries + 1] = hour
  end
  table.sort(entries)
  for index, hour in ipairs(entries) do
    entries[index] = hour .. ":" .. hours[hour]
  end
  return table.concat(entries, " ")
end
Ledger.Record(books, "A", 100, 10 * DAY)
Ledger.Record(books, "A", 150, 10 * DAY + 3600)
Ledger.Record(books, "A", 120, 11 * DAY)
Ledger.Record(books, "B", 500, 3 * DAY)
eq(stored(books.gold.A), "239:100 240:100 241:150 264:120", "gold is kept per hour, from the hour before the first as the opening balance")
local ledger = Ledger.Summary(books, 11 * DAY + 60)
eq(#ledger .. " " .. ledger[1].name .. " " .. ledger[2].name, "2 B A", "ledger lists characters richest first")
eq(ledger[2].gold .. " " .. ledger[2].today .. " " .. ledger[2].week .. " " .. ledger[2].idle, "120 -30 20 0", "ledger shows today's and the week's change")
eq(ledger[1].gold .. " " .. ledger[1].today .. " " .. ledger[1].week .. " " .. ledger[1].idle, "500 0 0 8", "a character not played today has no change today")
Ledger.Record(books, "A", 900, 100 * DAY)
eq(Ledger.Summary(books, 100 * DAY)[1].week, 0, "balances older than 60 days are dropped")

local hourly = Database.Init(nil)
Ledger.Record(hourly, "A", 100, 10 * DAY + 5 * HOUR + 60)
Ledger.Record(hourly, "A", 130, 10 * DAY + 5 * HOUR + 600)
Ledger.Record(hourly, "A", 170, 10 * DAY + 9 * HOUR)
eq(stored(hourly.gold.A), "244:100 245:130 249:170", "a later change in the same hour replaces the hour's balance")
local played = Ledger.Summary(hourly, 10 * DAY + 20 * HOUR)[1]
eq(played.gold .. " " .. played.today .. " " .. played.idle, "170 70 0", "the first day counts what it earned after the opening balance")
Ledger.Record(hourly, "A", 200, 70 * DAY + 23 * HOUR)
eq(stored(hourly.gold.A), "244:100 245:130 249:170 1703:200", "the day 60 days back is kept whole")
Ledger.Record(hourly, "A", 210, 71 * DAY)
eq(stored(hourly.gold.A), "1703:200 1704:210", "the hours of the day before it are dropped")

local account = Database.Init(nil)
Ledger.Record(account, "A", 1000, 10 * DAY)
Ledger.Record(account, "A", 1500, 11 * DAY)
Ledger.Record(account, "A", 1200, 12 * DAY)
Ledger.Record(account, "B", 300, 12 * DAY)
eq(table.concat(Ledger.History(account, 12 * DAY, 4), " "), "1300 1300 1800 1500", "history totals the characters per day and does not book a new character as a gain")
local performance = Ledger.Performance(account, 12 * DAY)
eq(performance.gold .. " " .. performance.today .. " " .. performance.week .. " " .. performance.month, "1500 -300 200 200", "performance over a day, a week and a month")
eq(performance.high .. " " .. performance.bestDay .. " " .. performance.worstDay, "1800 500 -300", "performance keeps the high and the best and worst day")
eq(("%.1f"):format(performance.todayPercent), "-16.7", "today's change in percent")

local market = Database.Init(nil)
local function priced(db, at, prices)
  local rows = {}
  for key, min in pairs(prices) do
    rows[#rows + 1] = { key = key, min = min, mv = 0, qty = 5, n = 0 }
  end
  Database.ApplyScan(db, { realm = "R", faction = "F", region = "EU", at = at, mode = "browse", by = "x", build = "1", rows = rows, names = {} })
end
priced(market, NOW, { ["1"] = 100, ["2"] = 200, ["4"] = 50, ["5"] = 300 })
priced(market, NOW + DAY, { ["1"] = 150, ["2"] = 100, ["3"] = 500, ["4"] = 60 })
local movers = Advisor.Movers(market, "R-F")
eq(#movers, 2, "movers need two days, a place in the newest scan and a price worth a silver")
eq(movers[1].key .. " " .. movers[1].change .. " " .. movers[1].before, "1 50 100", "the biggest gain comes first")
eq(movers[2].key .. " " .. movers[2].change, "2 -50", "the biggest loss comes last")

local upgraded = Database.Init({ version = 1, prices = { R = { ["1"] = "100,105,102,7,5000" } }, items = {}, scans = {}, settings = {} })
eq(upgraded.prices.R["1"], "100,7,0,5000,105,5000;100;", "schema 1 prices are carried over")
eq(#Codec.DecodePrice("100,7,0,5000,105,5000;100,90").days, 2, "records from before the ladder still read")
eq(upgraded.scanned.R, 5000, "schema 1 realms know their newest scan")
eq(upgraded.history.R["1"], "0:100:7:105", "schema 1 prices start a dated history")
eq(upgraded.version, 4, "schema version raised")
local fromSchema2 = Database.Init({ version = 2, prices = { R = {
  ["1"] = "1500,7,3,1760000000,1400,1760000000;1600,1550,1500;1500:2,1600:5",
  ["2"] = "100,4,0,1760000000,105,1759900000;100,90",
} }, scanned = { R = 1760000000 }, gold = { ["A-R"] = { [20369] = 5 } }, items = {}, scans = {}, settings = {} })
eq(fromSchema2.history.R["1"], "20370:1500:7:1400", "schema 2 history starts from the newest price, with that day's market value")
eq(fromSchema2.history.R["2"], "20370:100:4:0", "a market value from an earlier day is not booked on the newest day")
eq(fromSchema2.prices.R["1"], "1500,7,3,1760000000,1400,1760000000;1600,1550,1500;1500:2,1600:5", "schema 2 price records stay as they are")
eq(stored(fromSchema2.gold["A-R"]) .. " " .. fromSchema2.version, "488879:5 4", "schema 2 is raised to 4, with its gold by hour")
local fromSchema3 = Database.Init({ version = 3, gold = { ["A-R"] = { [20368] = 100, [20369] = 120, [20370] = 250 } } })
eq(stored(fromSchema3.gold["A-R"]), "488855:100 488879:120 488888:250", "schema 3 gold per day goes to each day's last hour, and today's to the current hour")
local reopened = Database.Init({ version = 3, gold = { ["A-R"] = { [488800] = 90, [20370] = 250 } } })
eq(stored(reopened.gold["A-R"]), "488800:90 488888:250", "hours an older version left in place stay hours")

local function base32(code)
  return not code:find("[^0-9A-HJKMNP-TV-Z]")
end
local made = GoldbookDB.account
eq(#made.id .. " " .. #made.key .. " " .. tostring(base32(made.id)) .. " " .. tostring(base32(made.key)), "8 20 true true",
  "the first load makes an 8 character ID and a 20 character key")
math.randomseed(2589)
local first = Database.Init(nil).account.key
math.randomseed(2589)
local again = Database.Init(nil).account.key
Stub.advance(0.001)
math.randomseed(2589)
local later = Database.Init(nil).account.key
eq(tostring(first == again) .. " " .. tostring(first == later), "true false",
  "a key made a millisecond later in the same second differs, even when math.random was seeded alike")

local history = Database.Init(nil)
local function scanned(db, at, min, mv, qty)
  Database.ApplyScan(db, {
    realm = "R", faction = "F", region = "EU", at = at, mode = "browse", by = "x", build = "1",
    rows = { { key = "1", min = min, mv = mv or 0, qty = qty or 1, n = mv and 3 or 0 } }, names = {},
  })
end
scanned(history, NOW, 100, 120)
scanned(history, NOW + 3600, 90)
eq(history.prices["R-F"]["1"], "90,1,0," .. NOW + 3600 .. ",120," .. NOW .. ";90;", "a second scan the same day replaces the day and keeps the market value")
scanned(history, NOW + 86400, 110)
eq(Database.Lookup(history, "R-F", "1").days[2], 110, "a scan the next day adds a day")
for day = 2, 16 do
  scanned(history, NOW + day * 86400, 100 + day)
end
local kept = Database.Lookup(history, "R-F", "1").days
eq(#kept .. " " .. kept[1] .. " " .. kept[14], "14 103 116", "history keeps the last 14 days")

local daily = Database.Init(nil)
scanned(daily, NOW, 100, 120, 4)
scanned(daily, NOW + 3600, 90, nil, 6)
eq(daily.history["R-F"]["1"], "20000:90:6:120", "a quick scan the same day replaces the price and quantity and keeps the day's market value")
priced(daily, NOW + DAY, { ["1"] = 110, ["2"] = 50 })
scanned(daily, NOW + 2 * DAY + 60, 130, 125, 3)
eq(daily.history["R-F"]["1"], "20000:90:6:120,20001:110:5:0,20002:130:3:125", "scans on three days make three dated days")
scanned(daily, NOW + 61 * DAY, 140)
eq(daily.history["R-F"]["1"], "20001:110:5:0,20002:130:3:125,20061:140:1:0", "days more than 60 days before the scan are cut off")
eq(daily.history["R-F"]["2"], "20001:50:5:0", "an item listed 60 days ago keeps its history")
scanned(daily, NOW + 62 * DAY, 150)
eq(daily.history["R-F"]["2"], nil, "an item not listed for more than 60 days loses its history")
local decoded = Database.History(daily, "R-F", "1")
eq(#decoded .. " " .. decoded[1].day .. " " .. decoded[1].min .. " " .. decoded[1].qty .. " " .. decoded[1].mv, "3 20002 130 3 125", "history decodes to dated days, oldest first")
eq(#Database.History(daily, "R-F", "2"), 0, "an item without history has no days")

local trend = Advisor.Evolution({
  { day = 19960, min = 200, qty = 1, mv = 0 },
  { day = 19969, min = 250, qty = 2, mv = 0 },
  { day = 19990, min = 300, qty = 3, mv = 310 },
  { day = 19993, min = 320, qty = 4, mv = 0 },
  { day = 19998, min = 280, qty = 5, mv = 0 },
  { day = 20000, min = 350, qty = 6, mv = 340 },
}, NOW + 3600, 30)
local trendRows = {}
for index, row in ipairs(trend.rows) do
  trendRows[index] = row.day .. ":" .. row.min .. ":" .. row.qty .. ":" .. row.mv .. ":" .. tostring(row.change)
end
eq(table.concat(trendRows, " "), "20000:350:6:340:25 19998:280:5:0:-12.5 19993:320:4:0:6.7 19990:300:3:310:20 19969:250:2:0:25 19960:200:1:0:nil",
  "evolution lists the days newest first with the change from the day before")
eq(trend.day .. " " .. trend.week .. " " .. trend.month, "25 9.4 40", "evolution compares with a day, a week and a month before")
local slots = {}
for index, slot in ipairs(trend.chart) do
  if slot then
    slots[#slots + 1] = index .. ":" .. slot.min
  end
end
eq(#trend.chart .. " " .. table.concat(slots, " "), "30 20:300 23:320 28:280 30:350", "evolution charts the last 30 days with gaps where the item was not seen")
eq(trend.low .. " " .. trend.high, "280 350", "evolution's low and high are those of the charted days")
local fresh = Advisor.Evolution({ { day = 20000, min = 100, qty = 1, mv = 0 } }, NOW, 30)
eq(tostring(fresh.day) .. " " .. tostring(fresh.week) .. " " .. #fresh.rows .. " " .. fresh.low, "nil nil 1 100", "one day has no change yet")

Stub.items[2589] = { name = "Linen Cloth", quality = 1, vendor = 13, cached = true }
Stub.items[2592] = { name = "Thrall's \"Ünicode\" Wool, Fine", quality = 1, vendor = 0, cached = false }
Stub.items[9775] = { name = "Bandit Cinch", quality = 2, vendor = 26000, cached = true }
Stub.items[7070] = { name = "Elemental Water", quality = 1, vendor = 400, cached = false }
Stub.items[4306] = { name = "Silk Cloth", quality = 1, vendor = 150, cached = true }

Stub.ah.browse = {
  { itemKey = { itemID = 2589, itemLevel = 0, itemSuffix = 0 }, minPrice = 120, totalQuantity = 40 },
  { itemKey = { itemID = 9775, itemSuffix = 584 }, minPrice = 25000, totalQuantity = 1 },
  { itemKey = { itemID = 2589, itemLevel = 5, itemSuffix = 0 }, minPrice = 110, totalQuantity = 2 },
  { itemKey = { itemID = 4306 }, minPrice = 0, totalQuantity = 3 },
  { itemKey = { itemID = 2592 }, minPrice = 300, totalQuantity = 7 },
}

Stub.money = 1000000
Stub.fire("PLAYER_MONEY")
eq(next(GoldbookDB.gold), nil, "gold that changes before login is not booked under a realm name that is not normalized yet")
Stub.fire("PLAYER_LOGIN")
eq(lastPrint(), "Goldbook " .. Stub.metadata.Version .. " loaded. Type /gb for commands.", "the login message gives the version from the .toc")
eq(stored(GoldbookDB.gold["Sultan-Faramon"]), "488887:1000000 488888:1000000", "gold recorded at login")
eq(Stub.categories[1].name, "Goldbook", "options entry registered")
eq(GoldbookMinimapButton.shown, true, "minimap button shown")
eq(("%.1f %.1f"):format(GoldbookMinimapButton.point[4], GoldbookMinimapButton.point[5]), "-53.0 -53.0", "minimap button starts bottom left")

Stub.cursor = { 100, 0 }
GoldbookMinimapButton.scripts.OnDragStart()
GoldbookMinimapButton.scripts.OnUpdate()
GoldbookMinimapButton.scripts.OnDragStop()
eq(("%.1f %.1f"):format(GoldbookMinimapButton.point[4], GoldbookMinimapButton.point[5]), "75.0 0.0", "minimap button follows the drag")
eq(GoldbookDB.settings.minimapAngle, 0, "minimap position remembered")
eq(GoldbookMinimapButton.scripts.OnUpdate, nil, "drag ends")

GoldbookDB.settings.window = { "TOPLEFT", "BOTTOMLEFT", 300, 600 }
GoldbookMinimapButton.scripts.OnClick(GoldbookMinimapButton, "LeftButton")
eq(GoldbookWindow.shown, true, "minimap left click opens the window")
local point, relativeTo, relativePoint, x, y = GoldbookWindow:GetPoint()
eq(("%s %s %s %d %d"):format(point, tostring(relativeTo == UIParent), relativePoint, x, y), "TOPLEFT true BOTTOMLEFT 300 600",
  "the window opens where it was left last session")
GoldbookWindow.scripts.OnDragStart(GoldbookWindow)
GoldbookWindow:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 420, 700)
GoldbookWindow.scripts.OnDragStop(GoldbookWindow)
eq(table.concat(GoldbookDB.settings.window, " "), "TOPLEFT BOTTOMLEFT 420 700", "where the window is dropped is remembered")
GoldbookMinimapButton.scripts.OnClick(GoldbookMinimapButton, "LeftButton")
eq(GoldbookWindow.shown, false, "minimap left click closes it again")
Goldbook_OnAddonCompartmentClick("Goldbook", "LeftButton")
eq(GoldbookWindow.shown, true, "addon compartment click opens the window")
GoldbookWindow:Hide()

SlashCmdList.GOLDBOOK("minimap")
eq(GoldbookMinimapButton.shown, false, "/gb minimap hides the button")
eq(GoldbookDB.settings.hideMinimap, true, "hidden minimap button remembered")
SlashCmdList.GOLDBOOK("minimap")
eq(GoldbookMinimapButton.shown, true, "/gb minimap shows it again")
eq(GoldbookDB.settings.hideMinimap, nil, "shown minimap button remembered")

local options = Stub.categories[1].frame
options.scripts.OnShow()
eq(options.checks.minimap.checked, true, "options checkbox reflects the button")
eq(options.checks.autoScan.checked, false, "automatic scanning starts off")
eq(options.checks.altClick.checked, true, "Alt+click starts on")
options.checks.minimap.checked = false
options.checks.minimap.scripts.OnClick(options.checks.minimap)
eq(GoldbookMinimapButton.shown, false, "options checkbox hides the button")
options.checks.minimap.checked = true
options.checks.minimap.scripts.OnClick(options.checks.minimap)

SlashCmdList.GOLDBOOK("")
eq(lastPrint(), "Goldbook /gb status  |  /gb minimap  |  /gb web", "/gb lists /gb web")

GoldbookDB.account = { id = "K7Q2M9PX", key = "7KQ2M9PXABCDEFGHJKMN" }
SlashCmdList.GOLDBOOK("web")
local web = GoldbookWebLogin
local function webButtons()
  local shown = {}
  for _, name in ipairs({ "newKey", "replace", "cancel" }) do
    if web[name].shown then
      shown[#shown + 1] = name
    end
  end
  return table.concat(shown, " ")
end
local function typeInto(box, text)
  box.text, box.selected = text, nil
  box.scripts.OnTextChanged(box, true)
end
eq(tostring(web.shown) .. " " .. web.id.text .. " " .. web.key.text, "true K7Q2-M9PX 7KQ2M-9PXAB-CDEFG-HJKMN", "/gb web shows the ID and key in groups")
eq(web.message.text .. " | " .. webButtons(), "Open the Goldbook site and log in under Characters. | newKey", "the dialog says where to log in")
-- The client passes the handlers more than the box.
web.id.scripts.OnEditFocusGained(web.id, 2 ^ 31)
web.key.scripts.OnMouseUp(web.key, "LeftButton")
eq(web.id.selected .. " " .. web.key.selected, "K7Q2-M9PX 7KQ2M-9PXAB-CDEFG-HJKMN", "clicking into a box selects all of its code for copying")
typeInto(web.key, "7KQ2M-9PXAB-CDEFGx-HJKMN")
eq(web.key.text .. " " .. web.key.selected, "7KQ2M-9PXAB-CDEFG-HJKMN 7KQ2M-9PXAB-CDEFG-HJKMN", "typing in a box puts the code back, selected")
eq(web.site.text .. " " .. web.height, "https://app.jkc-be.com/goldbook 182", "/gb web shows the site's address from the .toc, in a row above the ID")
web.site.scripts.OnMouseUp(web.site, "LeftButton")
eq(web.site.selected, "https://app.jkc-be.com/goldbook", "clicking the address selects all of it")
typeInto(web.site, "https://app.jkc-be.com/goldbookx")
eq(web.site.text .. " " .. web.site.selected, "https://app.jkc-be.com/goldbook https://app.jkc-be.com/goldbook", "typing over the address puts it back, selected")

web.newKey.scripts.OnClick(web.newKey)
eq(GoldbookDB.account.key .. " | " .. web.message.text .. " | " .. webButtons(),
  "7KQ2M9PXABCDEFGHJKMN | Old web logins stop working after the next sync. | replace cancel", "New key only asks, with a warning")
web.cancel.scripts.OnClick(web.cancel)
eq(GoldbookDB.account.key .. " | " .. web.message.text .. " | " .. webButtons(),
  "7KQ2M9PXABCDEFGHJKMN | Open the Goldbook site and log in under Characters. | newKey", "Cancel keeps the key")
web.newKey.scripts.OnClick(web.newKey)
web.replace.scripts.OnClick(web.replace)
local newKey = GoldbookDB.account.key
eq(GoldbookDB.account.id .. " " .. #newKey .. " " .. tostring(base32(newKey)) .. " " .. tostring(newKey ~= "7KQ2M9PXABCDEFGHJKMN"), "K7Q2M9PX 20 true true",
  "Replace key keeps the ID and draws a new key")
eq(web.key.text .. " | " .. webButtons(), newKey:sub(1, 5) .. "-" .. newKey:sub(6, 10) .. "-" .. newKey:sub(11, 15) .. "-" .. newKey:sub(16, 20) .. " | newKey",
  "the dialog shows the new key and asks no more")
eq(lastPrint(), "Goldbook New web key made. Type /reload or log out so Goldbook uploads it; until then the web page takes the old key.",
  "chat says when the new key takes effect")

web.newKey.scripts.OnClick(web.newKey)
web:Hide()
options.webLogin.scripts.OnClick(options.webLogin)
eq(tostring(web.shown) .. " " .. webButtons(), "true newKey", "Options' Show ID and key opens the dialog and drops a question left pending")
web:Hide()

-- WebLogin.lua loaded again on its own, as another client would load it.
local function webLoginAgain()
  local reloaded = setmetatable({}, { __index = ns })
  assert(loadfile(here .. "/../Goldbook/WebLogin.lua"))("Goldbook", reloaded)
  reloaded.WebLogin.Show()
  return GoldbookWebLogin
end
local modern = C_AddOns
C_AddOns, GetAddOnMetadata = nil, modern.GetAddOnMetadata
eq(webLoginAgain().site.text, "https://app.jkc-be.com/goldbook", "a client without C_AddOns reads the address with GetAddOnMetadata")
C_AddOns, GetAddOnMetadata = modern, nil
local website = Stub.metadata["X-Website"]
Stub.metadata["X-Website"] = nil
local siteless = webLoginAgain()
eq(tostring(rawget(siteless, "site")) .. " " .. siteless.id.text .. " " .. siteless.height, "nil K7Q2-M9PX 156",
  "without X-Website in the .toc the dialog leaves the Site row out")
Stub.metadata["X-Website"] = website
siteless:Hide()
GoldbookWebLogin = web

GoldbookMinimapButton.scripts.OnClick(GoldbookMinimapButton, "RightButton")
eq(lastPrint(), "Goldbook Cannot scan: open the auction house first.", "minimap right click scans, refused while the auction house is closed")

SlashCmdList.GOLDBOOK("scan")
eq(lastPrint(), "Goldbook Cannot scan: open the auction house first.", "scan refused while the auction house is closed")

Stub.fire("AUCTION_HOUSE_SHOW")
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
eq(Scanner.state, "scanning", "left click starts a scan")
Stub.advance(0.7)
eq(Scanner.state .. " " .. #GoldbookDB.scans, "scanning 0", "the scan waits briefly for the uncached variant's name")
eq(lastPrint(), "Goldbook Cannot scan: open the auction house first.", "nothing is announced while an item's name is still loading")
Stub.advance(4.3)

local scan = GoldbookDB.scans[1]
eq(#Stub.ah.queries, 1, "one browse query sent")
eq(#Stub.ah.queries[1].filters, 7, "browse query asks for every quality")
eq(Scanner.state, "idle", "browse scan finished")
eq(#GoldbookDB.scans, 1, "browse scan queued")
eq(scan.data, "2589,110,0,42,0;2592,300,0,7,0;9775:584,25000,0,1,0", "browse rows")
eq(scan.count, 3, "browse row count")
eq(scan.mode, "browse", "browse mode recorded")
eq(scan.realm .. "/" .. scan.faction .. "/" .. scan.region, "Faramon/Horde/EU", "realm recorded")
eq(scan.by .. "@" .. scan.build, "Sultan@1.60.1.70338", "scanner recorded")
eq(scan.at, 1760000000, "scan time recorded")
eq(GoldbookDB.prices["Faramon-Horde"]["2589"], "110,42,0,1760000000,0,0;110;", "price stored")
eq(GoldbookDB.scanned["Faramon-Horde"], 1760000000, "newest scan time stored")
eq(GoldbookDB.items["2589"], "1|Linen Cloth", "cached name stored")
eq(GoldbookDB.items["2592"], "1|Thrall's \"Ünicode\" Wool, Fine", "late name stored")
eq(GoldbookDB.items["9775:584"], "2|Bandit Cinch", "a variant whose item key info is not in yet is named after its base item")
eq(GoldbookDB.vendor[2589] .. " " .. GoldbookDB.vendor[2592], "13 0", "vendor prices stored, late ones too")
eq(plain(Stub.printed[#Stub.printed - 1]), "Goldbook 3 items scanned. Type /reload or log out to hand the scan to Goldbook.", "scan announced")
eq(lastPrint(), "Goldbook 1 deal worth 10s 0c. Type /gb deals.", "deals announced")
eq(GoldbookScanButton.text, "Goldbook scan", "button label restored")

Stub.ah.browse[3].minPrice = 200
Stub.ah.browse[1].minPrice = 200
Stub.ah.keyInfo["9775:584"] = { itemName = "Bandit Cinch of the Monkey", quality = 2 }
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(5)
eq(GoldbookDB.prices["Faramon-Horde"]["2589"], "200,42,0,1760000005,0,0;200;", "a later scan the same day replaces the price")
eq(GoldbookDB.items["9775:584"], "2|Bandit Cinch of the Monkey", "a quick scan names a variant by its item key, over the base name stored before")

local cloth = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
Stub.ah.replicate = {
  { itemID = 2589, count = 70, buyout = 35000, link = cloth },
  { itemID = 2589, count = 10, buyout = 1000, link = cloth },
  { itemID = 2589, count = 10, buyout = 1050, link = cloth },
  { itemID = 2589, count = 10, buyout = 1100, link = cloth },
  {
    itemID = 9775,
    count = 1,
    buyout = 30000,
    quality = 2,
    link = "|cff1eff00|Hitem:9775:0:0:0:0:0:584:1111:60|h[Bandit Cinch of the Monkey]|h|r",
    loadsAt = Stub.clock + 2,
  },
  { itemID = 4306, count = 5, buyout = 0, bid = 100, link = "|Hitem:4306|h[Silk Cloth]|h" },
  { itemID = 7070, count = 3, buyout = 1000, loadsAt = math.huge },
  {
    itemID = 863,
    count = 1,
    buyout = 11000,
    link = "|Hitem:" .. table.concat({ 863, "", "", "", "", "", "", "", "60", "", "", "", "1", "14999" }, ":") .. "|h[Gloom Reaper of Stamina]|h",
  },
}
Stub.items[863] = { name = "Gloom Reaper", quality = 2, vendor = 2000, cached = true }
SlashCmdList.GOLDBOOK("scan full")
Stub.advance(20)
scan = GoldbookDB.scans[3]
eq(#GoldbookDB.scans, 3, "full scan queued")
eq(scan.mode, "replicate", "full scan mode recorded")
eq(scan.data, "2589,100,105,100,4;7070,334,334,3,1;9775:584,30000,30000,1,1", "full scan rows")
eq(GoldbookDB.items["9775:584"], "2|Bandit Cinch of the Monkey", "full scan names the suffixed item")
eq(GoldbookDB.items["7070"], "1|Elemental Water", "item without a link is named later")
eq(GoldbookDB.prices["Faramon-Horde"]["863"], nil, "a variant with an unreadable suffix is not filed under its base item")
eq(GoldbookDB.linkSamples[1], Stub.ah.replicate[8].link, "the left-out variant's link is kept for inspection")
eq(GoldbookDB.prices["Faramon-Horde"]["2589"], "100,100,4,1760000016,105,1760000016;100;100:10,105:10,110:10,500:70", "full scan stores the market value and the ladder")
eq(GoldbookDB.prices["Faramon-Horde"]["2592"], "300,7,0,1760000005,0,0;300;", "an item the scan did not see keeps its old price")

SlashCmdList.GOLDBOOK("scan full")
eq(lastPrint(), "Goldbook Cannot scan: a full scan is available again in 15 min.", "full scan cooldown")
eq(#GoldbookDB.scans, 3, "refused scan queues nothing")

GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(0.15)
eq(GoldbookScanButton.text, "2 items", "button shows the progress")
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
eq(lastPrint(), "Goldbook Cannot scan: a scan is already running.", "a second start is refused")
eq(Scanner.state .. " " .. GoldbookScanButton.text, "scanning 2 items", "a refused start leaves the running scan alone")
Stub.fire("AUCTION_HOUSE_CLOSED")
eq(lastPrint(), "Goldbook Scan stopped: the auction house was closed.", "closing the auction house stops the scan")
Stub.advance(120)
eq(Scanner.state, "idle", "stopped scan stays stopped")
eq(#GoldbookDB.scans, 3, "stopped scan queues nothing")

Stub.fire("AUCTION_HOUSE_SHOW")
Stub.ah.silent = true
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(61)
eq(lastPrint(), "Goldbook Scan stopped: the auction house stopped responding.", "silent auction house times out")
eq(Scanner.state, "idle", "timed out scan is idle")
Stub.ah.silent = false

-- The player's own search answers while the scan's query still waits for the throttle.
Stub.ah.ready = false
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.ah.loaded = #Stub.ah.browse
Stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eq(Scanner.state .. " " .. #GoldbookDB.scans, "scanning 3", "results of the player's own search are not taken for the scan's")
Stub.fire("AUCTION_HOUSE_CLOSED")
Stub.ah.ready = true
Stub.fire("AUCTION_HOUSE_SHOW")

-- The player searches while the scan is on its second page; the search's own
-- result set must not be saved as the scan.
local before = GoldbookDB.scanned["Faramon-Horde"]
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(0.15)
local everything = Stub.ah.browse
Stub.ah.browse = { everything[1] }
Stub.ah.ready = true
C_AuctionHouse.SendBrowseQuery({ searchString = "linen", sorts = {}, filters = {} })
Stub.advance(1)
eq(lastPrint(), "Goldbook Scan stopped: another search replaced the scan; scan again.", "a search during the scan stops it")
eq(Scanner.state .. " " .. #GoldbookDB.scans .. " " .. GoldbookDB.scanned["Faramon-Horde"], "idle 3 " .. before, "the search's results are not saved as a scan")
Stub.ah.browse = everything

local listed = Stub.ah.browse
Stub.ah.browse = {}
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(5)
eq(lastPrint(), "Goldbook Scan stopped: the auction house returned no items.", "an empty answer is not a scan")
eq(#GoldbookDB.scans, 3, "an empty answer queues nothing")
Stub.ah.browse = listed

GameTooltip.lines, GameTooltip.itemLink = {}, cloth
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")),
  "  / Goldbook = 100 listed, seen 3m ago /   Min buyout = 1s 0c /   Market value = 1s 5c /   Post at = 99c /   Vendor = 13c /   Alt+click: price history",
  "tooltip lines")

Stub.shift, GameTooltip.owner, GameTooltip.lines = true, { count = 20 }, {}
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")),
  "  / Goldbook x20 = 100 listed, seen 3m ago /   Min buyout = 20s 0c /   Market value = 21s 0c /   Post at = 19s 80c /   Vendor = 2s 60c /   Alt+click: price history",
  "tooltip prices the stack while Shift is held")
Stub.shift, GameTooltip.owner = false, nil

GameTooltip.lines, GameTooltip.itemLink = {}, "|Hitem:7070::::::|h[Elemental Water]|h"
Stub.tooltipCalls[1](GameTooltip)
eq(plain(GameTooltip.lines[#GameTooltip.lines - 1]), "  Deal: a vendor pays 4s 0c, profit 1s 98c on 3 units", "tooltip points out a deal")

GameTooltip.lines, GameTooltip.itemLink = {}, "|Hitem:4306::::::|h[Silk Cloth]|h"
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")), "  / Goldbook =  /   Vendor = 1s 50c", "tooltip of an unscanned item shows the vendor price")

ns.db.merchant[2589], ns.db.vendorPaid[2589] = 50, 10
GameTooltip.lines, GameTooltip.itemLink = {}, cloth
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")),
  "  / Goldbook = 100 listed, seen 3m ago /   Min buyout = 1s 0c /   Market value = 1s 5c /   Vendor = 10c /   Merchant sells = 50c /   Alt+click: price history",
  "tooltip of what merchants sell shows their price, what a vendor paid, and no price to post at")
ns.db.merchant[2589], ns.db.vendorPaid[2589] = nil, nil
GameTooltip.lines, GameTooltip.itemLink = {}, "|Hitem:3857::::::|h[Coal]|h"
Stub.items[3857] = { name = "Coal", quality = 1, vendor = 125, cached = true }
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")), "  / Goldbook =  /   Vendor = 1s 25c /   Sold by merchants", "tooltip of known merchant goods says so without a price")
Stub.items[3857] = nil

local function cells(index)
  local texts = {}
  for column, cell in ipairs(GoldbookWindow.rows[index].cells) do
    texts[column] = plain(cell.text)
  end
  return table.concat(texts, " | ")
end

-- The tabs drawn selected, and any that cannot be clicked.
local function selectedTabs()
  local names = {}
  for name, tab in pairs(GoldbookWindow.tabs) do
    if rawget(tab, "highlighted") then
      names[#names + 1] = name
    end
    if rawget(tab, "enabled") == false then
      names[#names + 1] = name .. " (disabled)"
    end
  end
  table.sort(names)
  return table.concat(names, " ")
end

-- The days the chart marks, as day@height in the plot, and the days a line
-- reaches from the day before.
local function plotted()
  local marks, lines = {}, {}
  for index, day in ipairs(GoldbookWindow.chart.days) do
    if day.marker.shown then
      marks[#marks + 1] = index .. "@" .. math.floor(day.marker.point[5] + 0.5)
    end
    if day.line.shown then
      lines[#lines + 1] = index
    end
  end
  return marks, lines
end

SlashCmdList.GOLDBOOK("show cloth")
eq(GoldbookWindow.shown, true, "window opens")
eq(cells(1), "Linen Cloth | 1s 0c | 1s 5c | 100 | 3m ago", "price list shows the match")
eq(cells(2), " |  |  |  | ", "price list shows only matches")
eq(GoldbookWindow.rows[2].hit.shown, false, "empty rows cannot be clicked")
eq(GoldbookWindow.status.text, "1 item on Faramon-Horde", "price list status")
eq(selectedTabs(), "prices", "the open view's tab is drawn selected and every tab stays clickable")
eq(GoldbookWindow.search.hint.shown, false, "a search box with text shows no hint")
eq(GoldbookWindow.scroll.shown, false, "a list that fits has no scroll marker")
GameTooltip.lines = {}
GoldbookWindow.reload.scripts.OnEnter(GoldbookWindow.reload)
eq(table.concat(GameTooltip.lines, " / "), "Saves Goldbook's data so the sync agent can upload it.", "Reload says what it is for")
GoldbookWindow.reload.scripts.OnClick(GoldbookWindow.reload, "LeftButton", false)
eq(Stub.reloads, 1, "clicking Reload reloads the interface")

C_Item.GetItemIconByID = function(itemID)
  return itemID == 2589 and 132889 or nil
end
SlashCmdList.GOLDBOOK("show cloth")
eq(GoldbookWindow.rows[1].cells[1].text, "|T132889:14|t |cffffffffLinen Cloth|r", "an item's name follows its icon")
C_Item.GetItemIconByID = nil
GetItemIcon = function()
  return 134400
end
SlashCmdList.GOLDBOOK("show cloth")
eq(GoldbookWindow.rows[1].cells[1].text, "|T134400:14|t |cffffffffLinen Cloth|r", "a client without C_Item.GetItemIconByID asks GetItemIcon")
GetItemIcon = nil

GoldbookWindow.tabs.deals.scripts.OnClick()
eq(GoldbookWindow.search.text, "cloth", "switching views keeps the search text")
eq(GoldbookWindow.status.text, "0 deals in the scan of 3m ago. Click one to search for it.", "deals are filtered by the search text")
eq(selectedTabs(), "deals", "the selection follows the tab clicked")
SlashCmdList.GOLDBOOK("deals")
eq(GoldbookWindow.search.text, "", "/gb deals without text clears the search")
eq(GoldbookWindow.search.hint.shown, true, "an empty search box shows its hint")
GoldbookWindow.search.scripts.OnEditFocusGained(GoldbookWindow.search)
eq(GoldbookWindow.search.hint.shown, false, "the hint goes when the box is clicked into")
GoldbookWindow.search.scripts.OnEditFocusLost(GoldbookWindow.search)
eq(GoldbookWindow.search.hint.shown, true, "the hint comes back when the box is left empty")
eq(GoldbookWindow.headers[2].text, "Buy from", "deals view has its own columns")
eq(cells(1), "Elemental Water x3 | 3s 34c | 4s 0c | 1s 98c | Vendor?", "deals view lists the vendor deal with its units and total profit")
eq(GoldbookWindow.status.text, "1 deal in the scan of 3m ago. Click one to search for it. Vendor? prices are unconfirmed.",
  "deals status says the item's own vendor price is not confirmed")
GoldbookDB.vendorPaid[7070] = 400
SlashCmdList.GOLDBOOK("deals")
eq(cells(1) .. " / " .. GoldbookWindow.status.text, "Elemental Water x3 | 3s 34c | 4s 0c | 1s 98c | Vendor / 1 deal in the scan of 3m ago. Click one to search for it.",
  "a vendor price seen paid is confirmed")
GoldbookDB.vendorPaid[7070] = nil
SlashCmdList.GOLDBOOK("deals")

local firstRow = GoldbookWindow.rows[1].hit
firstRow.scripts.OnEnter(firstRow)
eq(GameTooltip.hyperlink, "item:7070:0:0:0:0:0:0", "hovering a row shows the item")
local function tooltipAnchor()
  local tipPoint, owner, ownerPoint, tipX, tipY = unpack(GameTooltip.point)
  return ("%s %s %s %d %d"):format(tipPoint, tostring(owner == firstRow), ownerPoint, tipX, tipY)
end
eq(tooltipAnchor(), "TOPLEFT true TOPRIGHT 19 0", "a row's tooltip sits beside the window, level with the row")
GoldbookWindow.right, UIParent.right, GameTooltip.width = 1100, 1280, 300
firstRow.scripts.OnEnter(firstRow)
eq(tooltipAnchor(), "TOPRIGHT true TOPLEFT -14 0", "it moves to the window's left when the screen ends first")
GoldbookWindow.right, UIParent.right, GameTooltip.width = nil, nil, nil
firstRow.scripts.OnClick(firstRow)
eq(AuctionHouseFrame.SearchBar.searchText .. " " .. AuctionHouseFrame.SearchBar.searches, "Elemental Water 1", "clicking a row searches the auction house")
AuctionHouseFrame.shown = false
firstRow.scripts.OnClick(firstRow)
eq(lastPrint(), "Goldbook Open the auction house and search for Elemental Water.", "clicking a row away from the auction house says what to do")
AuctionHouseFrame.shown = true

SlashCmdList.GOLDBOOK("minprofit 2.5")
eq(GoldbookDB.settings.minProfit, 25000, "/gb minprofit takes gold")
eq(lastPrint(), "Goldbook Resale deals must make at least 2g 50s 0c. Change it with /gb minprofit <gold>.", "/gb minprofit confirms")

Stub.bags[0] = {
  slots = 5,
  { hyperlink = cloth, stackCount = 20 },
  { hyperlink = cloth, stackCount = 5 },
  { hyperlink = "|Hitem:7070::::::|h[Elemental Water]|h", stackCount = 3 },
  { hyperlink = "|Hitem:6948::::::|h[Hearthstone]|h", stackCount = 1, isBound = true },
}
Stub.bags[1] = { slots = 1, { hyperlink = "|Hitem:4306::::::|h[Silk Cloth]|h", stackCount = 2 } }
GoldbookWindow.tabs.sell.scripts.OnClick()
eq(cells(1), "Linen Cloth x25 | 99c | 13c | 23s 50c | Auction", "sell view undercuts the lowest listing")
eq(cells(2), "Elemental Water x3 |  | 4s 0c | 12s 0c | Vendor", "sell view vendors what lists under vendor price")
eq(cells(3), "Silk Cloth x2 |  | 1s 50c | 3s 0c | Vendor", "sell view vendors what has no auction price")
eq(cells(4), " |  |  |  | ", "sell view skips bound items")
eq(plain(GoldbookWindow.status.text), "3 items worth 38s 50c after the auction house cut", "sell view totals the bags")

Stub.money = 1250000
Stub.fire("PLAYER_MONEY")
SlashCmdList.GOLDBOOK("gold")
eq(cells(1), "Sultan-Faramon | 125g 0s 0c | +25g 0s 0c | +25g 0s 0c | today", "gold view shows the character and what it earned")
eq(GoldbookWindow.rows[1].hit.shown, false, "gold rows are not items")
eq(plain(GoldbookWindow.chart.summary.text), "Total 125g 0s 0c   Today +25g 0s 0c (+25.0%)   7 days +25g 0s 0c   30 days +25g 0s 0c", "gold view states the account")
eq(plain(GoldbookWindow.chart.detail.text), "High 125g 0s 0c   Best day +25g 0s 0c   Bags 38s 50c   Net worth 125g 38s 50c", "gold view adds the bags to the net worth")
eq(GoldbookWindow.chart.caption.text, "Total gold over the last 30 days", "the gold caption names the line; the axis labels give its range")
eq(GoldbookWindow.rows[1].cells[3].text, "|cff20ff20+25|r|cffffd700g|r|cff20ff20 0|r|cffc7c7cfs|r|cff20ff20 0|r|cffeda55fc|r",
  "a gain is green between the coloured money units")
eq(GoldbookWindow.chart.summary.text:match("Today (.-)   7 days"),
  "|cff20ff20+25|r|cffffd700g|r|cff20ff20 0|r|cffc7c7cfs|r|cff20ff20 0|r|cffeda55fc|r (|cff20ff20+25.0%|r)",
  "the gold summary colours today's change and its percent")
eq(GoldbookWindow.chart.header.shown, false, "the gold summary is not an item to hover")
local marks, lines = plotted()
eq(#marks .. " " .. #lines .. " " .. marks[1] .. " " .. marks[29] .. " " .. marks[30], "30 29 1@5 29@5 30@85",
  "the gold line has a marker per day, from the lowest total at the bottom to the highest at the top")
local lastLine = GoldbookWindow.chart.days[30].line
eq(("%d,%d -> %d,%d"):format(lastLine.startPoint[3] + 0.5, lastLine.startPoint[4], lastLine.endPoint[3] + 0.5, lastLine.endPoint[4]),
  "558,5 -> 577,85", "a line joins each day to the day before")
eq(GoldbookWindow.chart.days[30].marker.width .. " " .. GoldbookWindow.chart.days[29].marker.width, "9 5", "the newest day has the larger marker")
eq(plain(GoldbookWindow.chart.high.text) .. " / " .. plain(GoldbookWindow.chart.low.text), "125g 0s 0c / 100g 0s 0c",
  "the axis labels give the high and the low")
GameTooltip.lines = {}
GoldbookWindow.chart.days[30].hit.scripts.OnEnter(GoldbookWindow.chart.days[30].hit)
eq(plain(table.concat(GameTooltip.lines, " / ")), "Thu 09 Oct / Total 125g 0s 0c", "hovering a gold day gives its day and total")

Stub.advance(0.2)
Stub.money = 1260000
local timers = #Stub.timers
for _ = 1, 10 do
  Stub.fire("PLAYER_MONEY")
end
eq(cells(1), "Sultan-Faramon | 125g 0s 0c | +25g 0s 0c | +25g 0s 0c | today", "the window is not redrawn on the spot for each gold change")
eq(#Stub.timers - timers, 1, "ten gold changes in a row queue one redraw")
Stub.advance(0.2)
eq(cells(1), "Sultan-Faramon | 126g 0s 0c | +26g 0s 0c | +26g 0s 0c | today", "the redraw a moment later shows the new balance")

Stub.items[5000] = { name = "Rough Stone", quality = 1, vendor = 2, cached = false }
Stub.bags[1][2] = { hyperlink = "|Hitem:5000::::::|h[Rough Stone]|h", stackCount = 4 }
Stub.bags[1].slots = 2
GoldbookWindow.tabs.sell.scripts.OnClick()
eq(cells(4), "item 5000 x4 |  |  | 0c | No price", "a bag item whose name is still loading is listed by its id")
Stub.advance(0.7)
eq(cells(4), "Rough Stone x4 |  | 2c | 8c | Vendor", "the name and vendor price fill in once they arrive")
Stub.bags[1][3] = { stackCount = 1 }
Stub.bags[1].slots = 3
GoldbookWindow.tabs.sell.scripts.OnClick()
eq(plain(GoldbookWindow.status.text), "4 items worth 38s 58c after the auction house cut", "a bag slot whose item has no link yet is left out")

SlashCmdList.GOLDBOOK("movers")
eq(GoldbookWindow.chart.shown, false, "the chart belongs to the gold view")
eq(GoldbookWindow.headers[4].text, "Change", "movers view has its own columns")
eq(GoldbookWindow.status.text, "0 prices moved since the day before. Top gains first; click Change for the losses.", "movers need a second day of prices")

SlashCmdList.GOLDBOOK("show")
eq(cells(1), "Bandit Cinch of the Monkey | 3g 0s 0c | 3g 0s 0c | 1 | 3m ago", "price list starts in name order")
GoldbookWindow.headerButtons[4].scripts.OnClick()
eq(GoldbookWindow.headers[4].text, "Listed v", "a header click sorts by that column, largest first")
eq(cells(1):match("^[^|]+"), "Linen Cloth ", "sorted by quantity the most listed item leads")
GoldbookWindow.headerButtons[4].scripts.OnClick()
eq(GoldbookWindow.headers[4].text .. " " .. cells(1):match("^[^|]+"), "Listed ^ Bandit Cinch of the Monkey ", "a second click reverses the order")

SlashCmdList.GOLDBOOK("autoscan")
eq(lastPrint(), "Goldbook Quick scan when the auction house opens: on.", "/gb autoscan turns it on")
local sent = #Stub.ah.queries
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.advance(2)
eq(#Stub.ah.queries, sent, "no automatic scan within 15 minutes of the last one")
Stub.advance(900)
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.advance(1.15)
eq(Scanner.state, "scanning", "the auction house opening starts a quick scan")
Stub.fire("AUCTION_HOUSE_CLOSED")
SlashCmdList.GOLDBOOK("autoscan")
eq(GoldbookDB.settings.autoScan, nil, "/gb autoscan turns it off again")

Stub.alt = true
HandleModifiedItemClick(Stub.bags[0][1].hyperlink)
eq(GoldbookWindow.shown, true, "Alt+click on a bag item opens the window")
eq(GoldbookWindow.headers[1].text .. " " .. GoldbookWindow.headers[5].text, "Day Change", "Alt+click shows the item's price history")
eq(cells(1), "Thu 09 Oct | 1s 0c | 1s 5c | 100 | ", "the newest day comes first")
eq(cells(2), " |  |  |  | ", "one row per day the item was seen")
eq(plain(GoldbookWindow.status.text), "1 day recorded for Linen Cloth. Alt+click any item for its history.", "item view status")
eq(plain(GoldbookWindow.chart.summary.text), "Linen Cloth   1s 0c", "item chart names the item and its price")
eq(selectedTabs(), "", "the item view has no tab to mark")
eq(GoldbookWindow.scroll.shown, false, "one day needs no scroll marker")
marks, lines = plotted()
eq(table.concat(marks, " ") .. " | " .. table.concat(lines, " "), "30@85 | ", "a single price is one marker at the top, without a line")
eq(plain(GoldbookWindow.chart.high.text) .. " / " .. GoldbookWindow.chart.low.text, "1s 0c / ", "a single price has one axis label")
local header = GoldbookWindow.chart.header
header.scripts.OnEnter(header)
eq(GameTooltip.hyperlink .. " " .. tostring(GameTooltip.point[2] == header), "item:2589:0:0:0:0:0:0 true",
  "hovering the item's name shows its tooltip")
local inserted = {}
function ChatEdit_InsertLink(link)
  inserted[#inserted + 1] = link
  return true
end
Stub.alt = false
header.scripts.OnClick(header)
Stub.shift = true
header.scripts.OnClick(header)
Stub.shift = false
Stub.alt = true
eq(table.concat(inserted, " "), "|Hitem:2589|h[Linen Cloth]|h", "Shift+click on the item's name links it in chat, a plain click does not")
ChatEdit_InsertLink = nil

SlashCmdList.GOLDBOOK("show")
Stub.shift = true
HandleModifiedItemClick(cloth)
eq(GoldbookWindow.headers[1].text, "Item", "Shift+Alt+click leaves the window alone")
Stub.shift = false
options.checks.altClick.checked = false
options.checks.altClick.scripts.OnClick(options.checks.altClick)
HandleModifiedItemClick(cloth)
eq(GoldbookWindow.headers[1].text, "Item", "Alt+click does nothing when turned off")
GameTooltip.lines, GameTooltip.itemLink = {}, cloth
Stub.tooltipCalls[1](GameTooltip)
eq(plain(GameTooltip.lines[#GameTooltip.lines]), "  Vendor = 13c", "the tooltip drops the Alt+click hint when it is off")
options.checks.altClick.checked = true
options.checks.altClick.scripts.OnClick(options.checks.altClick)
eq(GoldbookDB.settings.altClick, true, "Alt+click turned on again")

GoldbookWindow.rows[1].hit.scripts.OnClick(GoldbookWindow.rows[1].hit)
eq(GoldbookWindow.headers[1].text .. " " .. AuctionHouseFrame.SearchBar.searches, "Day 1", "Alt+click on a row opens its history instead of searching")
Stub.alt = false
GoldbookWindow.search.text = "silk"
GoldbookWindow.search.scripts.OnTextChanged(GoldbookWindow.search, true)
eq(GoldbookWindow.headers[1].text .. " " .. GoldbookWindow.status.text, "Item 0 items on Faramon-Horde", "typing a search leaves the item view for the price list")

GoldbookDB.items["2996"] = "1|Bolt of Linen Cloth"
GoldbookDB.prices["Faramon-Horde"]["2996"] = "500,3,0,1760000016,0,0;500;"
GoldbookDB.history["Faramon-Horde"]["2996"] = "20370:500:3:0"
SlashCmdList.GOLDBOOK("item linen CLOTH")
eq(cells(1), "Thu 09 Oct | 1s 0c | 1s 5c | 100 | ", "/gb item prefers the item named exactly that")
SlashCmdList.GOLDBOOK("item linen")
eq(cells(1), "Thu 09 Oct | 5s 0c |  | 3 | ", "/gb item otherwise takes the first name containing the text")
SlashCmdList.GOLDBOOK("item nothing like it")
eq(lastPrint(), "Goldbook No item priced on Faramon-Horde matches \"nothing like it\". Type /gb item <link or name>.", "/gb item says when nothing matches")

GoldbookDB.items["727:14322"] = "2|Notched Shortsword of Healing"
GoldbookDB.prices["Faramon-Horde"]["727:14322"] = "2600,2,2,1760000016,0,0;2400,2500,2600;"
GoldbookDB.history["Faramon-Horde"]["727:14322"] = "20361:2000:4:0,20362:2100:4:0,20363:2200:4:0,20364:2300:4:0,20365:2400:4:0,"
  .. "20366:2500:4:0,20367:2400:3:0,20368:2400:3:2450,20369:2500:2:0,20370:2600:2:0"
GameTooltip.lines, GameTooltip.itemLink = {}, bonusLink
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")),
  "  / Goldbook = 2 listed, seen 18m ago /   Min buyout = 26s 0c /   Usual over 3 days = 25s 0c /   Post at = 25s 99c /   Alt+click: price history",
  "the tooltip finds a variant by the suffix among its bonus ids")
Stub.alt = true
HandleModifiedItemClick(bonusLink)
Stub.alt = false
eq(plain(GoldbookWindow.status.text), "1-8 of 10 days recorded for Notched Shortsword of Healing. Alt+click any item for its history.",
  "Alt+click finds a variant by the suffix among its bonus ids; the status says which days show")
eq(cells(1), "Thu 09 Oct | 26s 0c |  | 2 | +4.0%", "the change from the day before")
eq(cells(8), "Thu 02 Oct | 22s 0c |  | 4 | +4.8%", "a view with a chart lists 8 rows")
eq(cells(9), " |  |  |  | ", "rows under the chart stay empty")
eq(GoldbookWindow.rows[1].cells[5].text .. " " .. GoldbookWindow.rows[3].cells[5].text .. " " .. GoldbookWindow.rows[4].cells[5].text,
  "|cff20ff20+4.0%|r 0.0% |cffff2020-4.0%|r", "a gain is green, a loss red, no change plain")
eq(tostring(GoldbookWindow.rows[1].stripe.shown) .. " " .. tostring(GoldbookWindow.rows[2].stripe.shown) .. " " .. tostring(GoldbookWindow.rows[10].stripe.shown),
  "false true false", "every other filled row is striped")
local thumb = GoldbookWindow.scroll.thumb
eq(("%s %.1f %.1f %s"):format(tostring(GoldbookWindow.scroll.shown), GoldbookWindow.scroll.height, thumb.height, tostring(thumb.point[5] == 0)),
  "true 144.0 115.2 true", "the scroll marker spans the 8 rows and its thumb starts at the top")
GoldbookWindow.scripts.OnMouseWheel(GoldbookWindow, -1)
eq(cells(1) .. " / " .. cells(8), "Tue 07 Oct | 24s 0c | 24s 50c | 3 | 0.0% / Tue 30 Sep | 20s 0c |  | 4 | ", "scrolling stops at the oldest day")
eq(plain(GoldbookWindow.status.text):match("^[^.]*"), "3-10 of 10 days recorded for Notched Shortsword of Healing", "the status follows the scrolling")
eq(("%.1f"):format(thumb.point[5]), "-28.8", "the thumb ends at the bottom with the oldest day")
eq(plain(GoldbookWindow.chart.summary.text), "Notched Shortsword of Healing   26s 0c   1 day +4.0%   7 days +18.2%", "item chart states the price and its changes")
eq(GoldbookWindow.chart.summary.text:match("1 day .*"), "1 day |cff20ff20+4.0%|r   7 days |cff20ff20+18.2%|r", "the item summary colours its changes")
eq(plain(GoldbookWindow.chart.detail.text), "Usual 25s 0c   Listed 2", "item chart gives the usual price; the axis labels give the range")
eq(GoldbookWindow.chart.caption.text, "Lowest price over the last 30 days", "the item caption names the line")
marks, lines = plotted()
eq(table.concat(marks, " "), "21@5 22@18 23@32 24@45 25@58 26@72 27@58 28@58 29@72 30@85",
  "the item line runs from the lowest price at the bottom to the highest at the top")
GameTooltip.lines = {}
GoldbookWindow.chart.days[28].hit.scripts.OnEnter(GoldbookWindow.chart.days[28].hit)
eq(plain(table.concat(GameTooltip.lines, " / ")), "Tue 07 Oct / Min buyout 24s 0c / Listed 3 / Market value 24s 50c", "hovering an item day gives that day's prices")

GoldbookDB.items["2997"] = "1|Bolt of Woolen Cloth"
GoldbookDB.prices["Faramon-Horde"]["2997"] = "100000,1,1,1760000016,0,0;100000;"
GoldbookDB.history["Faramon-Horde"]["2997"] = "20366:100000:1:0,20367:100000:1:0,20369:100040:1:0,20370:100000:1:0"
SlashCmdList.GOLDBOOK("gold")
marks, lines = plotted()
eq(#lines, 29, "the gold chart joins its 30 days")
SlashCmdList.GOLDBOOK("item woolen")
marks, lines = plotted()
eq(table.concat(marks, " ") .. " | " .. table.concat(lines, " "), "26@5 27@5 29@85 30@5 | 27 30",
  "after the gold chart only this item's markers and lines show, with no line across the missing day")
eq(cells(1) .. " / " .. cells(2), "Thu 09 Oct | 10g 0s 0c |  | 1 | 0.0% / Wed 08 Oct | 10g 0s 40c |  | 1 | 0.0%",
  "a change that rounds to nothing has no sign, up or down")
eq(GoldbookWindow.chart.summary.text:match("1 day .*"), "1 day 0.0%", "nor in the summary")
eq(GoldbookWindow.chart.days[30].marker.width .. " " .. GoldbookWindow.chart.days[29].marker.width, "9 5", "the newest day has the larger marker")

Stub.fire("AUCTION_HOUSE_SHOW")
Stub.ah.silent = true
SlashCmdList.GOLDBOOK("scan full")
Stub.advance(61)
eq(Scanner.state .. " " .. GoldbookScanButton.text, "scanning starting", "a full scan still waits for the list after a minute")
Stub.advance(120)
eq(lastPrint(), "Goldbook Scan stopped: the auction house stopped responding.", "a full scan gives up after three minutes without a list")
eq(GoldbookDB.settings.lastReplicate, 1760000011, "the cooldown counts from the list the server last sent, not from a request it ignored")
SlashCmdList.GOLDBOOK("scan full")
eq(Scanner.state, "scanning", "a full scan the server ignored can be tried again at once")
Stub.fire("AUCTION_HOUSE_CLOSED")
Stub.ah.silent = false

-- Scans into a database of their own: the sync tests expect exactly the three queued above.
local scratch = Database.Init({})
ns.db = scratch
Stub.fire("AUCTION_HOUSE_SHOW")
Stub.items[5001] = { name = "Lost Item", quality = 1, vendor = 0, cached = false, delay = math.huge }
Stub.ah.browse = {
  { itemKey = { itemID = 2589, itemSuffix = 0 }, minPrice = 120, totalQuantity = 40 },
  { itemKey = { itemID = 5001, itemSuffix = 0 }, minPrice = 500, totalQuantity = 1 },
}
GoldbookScanButton.scripts.OnClick(GoldbookScanButton, "LeftButton")
Stub.advance(14)
eq(#scratch.scans .. " " .. lastPrint(), "1 Goldbook Scan stopped: the auction house was closed.", "a scan with a name that never arrives is saved but not announced yet")
Stub.advance(2)
eq(lastPrint(), "Goldbook 2 items scanned, 1 still unnamed. Type /reload or log out to hand the scan to Goldbook.", "after 15 s the scan is announced with the names still missing")

Stub.items[2770] = { name = "Copper Ore", quality = 1, vendor = 5, cached = false }
Stub.items[15200] = { name = "Rusty Blade", quality = 2, vendor = 100, cached = false }
Stub.ah.replicate = {
  { itemID = 2770, count = 20, buyout = 2000, link = "|Hitem:2770::::::::60:::::|h[Copper Ore]|h" },
  {
    itemID = 15200,
    count = 1,
    buyout = 9000,
    quality = 2,
    link = "|Hitem:" .. table.concat({ 15200, "", "", "", "", "", "", "", "60", "", "", "", "1", "14995" }, ":") .. "|h[Rusty Blade of the Bear]|h",
  },
}
SlashCmdList.GOLDBOOK("scan full")
Stub.advance(5)
local ore = Database.Lookup(scratch, "Faramon-Horde", "2770")
eq(ore.min .. " " .. ore.qty .. " " .. ore.mv .. " " .. scratch.items["2770"], "100 20 100 1|Copper Ore", "a listing of an item whose name was still loading is filed once the name is in")
eq(scratch.prices["Faramon-Horde"]["15200"], nil, "a variant of an item whose name was still loading is not filed under the base item")
eq(scratch.linkSamples[1], Stub.ah.replicate[2].link, "the variant is left out and its link kept")
ns.db = GoldbookDB

local queue = Database.Init(nil)
for index = 1, 25 do
  scanned(queue, 1000 + index, 1)
end
eq(#queue.scans, 20, "queue keeps the newest 20 scans")
eq(queue.scans[1].at, 1006, "queue drops the oldest scans")
scanned(queue, 1025 + 15 * 24 * 3600, 1)
eq(#queue.scans, 1, "queue drops scans older than 14 days")

local function rowsText(rows)
  local texts = {}
  for index, row in ipairs(rows) do
    texts[index] = table.concat({ row.key, row.name, row.quality, row.count, row.action, tostring(row.post), row.vendor, row.value }, " ")
  end
  return table.concat(texts, " / ")
end

Stub.items[3576] = { name = "Tin Bar", quality = 1, vendor = 25, cached = false, delay = 5 }
Stub.bags[-1] = {
  slots = 3,
  { hyperlink = cloth, stackCount = 10 },
  { hyperlink = "|Hitem:2592::::::|h[Wool]|h", stackCount = 6 },
  { hyperlink = "|Hitem:6948::::::|h[Hearthstone]|h", stackCount = 1, isBound = true },
}
Stub.bags[5] = { slots = 2, { hyperlink = "|Hitem:3576::::::|h[Tin Bar]|h", stackCount = 5 } }
Stub.fire("BANKFRAME_OPENED")
Stub.advance(2)
Stub.bags[5][2] = { hyperlink = cloth, stackCount = 7 }
Stub.fire("BAG_UPDATE", 5)
Stub.advance(1)
Stub.bags[-1][2].stackCount = 8
Stub.fire("PLAYERBANKSLOTS_CHANGED", 2)
Stub.fire("BANKFRAME_CLOSED")
Stub.fire("BAG_UPDATE", 0)
Stub.advance(10)
local realmAtLogout = GetNormalizedRealmName
GetNormalizedRealmName = function() return nil end
Stub.fire("PLAYER_LOGOUT")
GetNormalizedRealmName = realmAtLogout
local sultan = GoldbookDB.characters["Sultan-Faramon"]
eq(GoldbookDB.characters["Sultan-Fara'mon"], nil, "logout does not create a display-realm duplicate when the normalized realm is unavailable")
assert(sultan, "logout must keep the character under its normalized login realm")
eq(table.concat({ sultan.name, sultan.realm, sultan.faction, sultan.class, sultan.level, sultan.at }, " "), "Sultan Faramon Horde WARRIOR 60 1760001336",
  "logging out saves who the character is and when")
eq(sultan.bags.at .. " " .. rowsText(sultan.bags.rows),
  "1760001336 2589 Linen Cloth 1 25 auction 99 13 2350 / 7070 Elemental Water 1 3 vendor nil 400 1200 / 4306 Silk Cloth 1 2 vendor nil 150 300 / "
    .. "5000 Rough Stone 1 4 vendor nil 2 8",
  "the snapshot prices the bags as the sell view does")
eq(sultan.bank.at .. " " .. rowsText(sultan.bank.rows),
  "1760001326 2592 Thrall's \"Ünicode\" Wool, Fine 1 8 auction 300 0 2280 / 2589 Linen Cloth 1 17 auction 99 13 1598 / 3576 Tin Bar 1 5 vendor nil 25 125",
  "the bank keeps its unbound items as last read while open, priced at logout with the details that arrived since")

-- The client's own SavedVariables layout: one value per line, array entries
-- tagged with their index, control characters as decimal escapes.
local function quote(text)
  return '"' .. text:gsub('[%c"\\]', function(char)
    if char == "\n" then
      return "\\n"
    elseif char == "\r" then
      return "\\r"
    elseif char == '"' or char == "\\" then
      return "\\" .. char
    end
    return ("\\%03d"):format(char:byte())
  end) .. '"'
end

local function serialize(value, out)
  if type(value) == "string" then
    out[#out + 1] = quote(value)
  elseif type(value) ~= "table" then
    out[#out + 1] = tostring(value)
  else
    out[#out + 1] = "{\n"
    for index, item in ipairs(value) do
      serialize(item, out)
      out[#out + 1] = ", -- [" .. index .. "]\n"
    end
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "number" or key > #value then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      out[#out + 1] = type(key) == "number" and ("[" .. key .. "] = ") or ("[" .. quote(key) .. "] = ")
      serialize(value[key], out)
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = "}"
  end
end

local function savedVariables()
  local out = { "\nGoldbookDB = " }
  serialize(GoldbookDB, out)
  out[#out + 1] = "\n"
  return table.concat(out)
end

local account = GoldbookDB.account
local beforeReload = account.id .. " " .. account.key
assert(loadstring(savedVariables()))()
Stub.fire("ADDON_LOADED", "Goldbook")
eq(tostring(GoldbookDB.account ~= account) .. " " .. GoldbookDB.account.id .. " " .. GoldbookDB.account.key, "true " .. beforeReload,
  "the ID and key read back from the file are kept")

Stub.name, Stub.class, Stub.level = "Mirelle", "MAGE", 42
Stub.fire("PLAYER_LOGIN")
Stub.fire("PLAYER_MONEY")
Stub.fire("PLAYER_LOGOUT")
local mirelle = GoldbookDB.characters["Mirelle-Faramon"]
eq(mirelle.class .. " " .. mirelle.level .. " " .. tostring(mirelle.bank) .. " " .. #GoldbookDB.characters["Sultan-Faramon"].bank.rows, "MAGE 42 nil 3",
  "a second character has no bank until it opens its own, and the first keeps its bank")

-- The sync tests hash this key, the contract's example.
GoldbookDB.account = { id = "K7Q2M9PX", key = "7KQ2M9PXABCDEFGHJKMN" }
local path = here .. "/../../fixtures/Goldbook.lua"
local file = io.open(path, "w")
if not file then
  -- The public addon repository has no fixtures folder and no sync tests.
  path = os.tmpname()
  file = assert(io.open(path, "w"))
end
file:write(savedVariables())
file:close()
local fixture = {}
setfenv(assert(loadfile(path)), fixture)()
local characters = {}
for name in pairs(fixture.GoldbookDB.characters) do
  characters[#characters + 1] = name
end
table.sort(characters)
eq(fixture.GoldbookDB.account.key .. " " .. table.concat(characters, " ") .. " " .. #fixture.GoldbookDB.scans,
  "7KQ2M9PXABCDEFGHJKMN Mirelle-Faramon Sultan-Faramon 3", "the fixture carries the account, both characters and the three scans")

print = nil
io.write(("%d checks, %d failed. Wrote %s\n"):format(checks, failures, path))
os.exit(failures == 0 and 0 or 1)
