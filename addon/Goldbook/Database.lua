local _, ns = ...
local Codec = ns.Codec

local Database = {}
ns.Database = Database

local SCHEMA = 4
local MAX_QUEUED_SCANS = 20
local MAX_QUEUE_AGE = 14 * 24 * 3600
local HISTORY_DAYS = 14
local KEPT_DAYS = 60
local HOUR = 3600
local DAY = 24 * HOUR
local ID_LENGTH, KEY_LENGTH = 8, 20
local PARK_MILLER = 2147483647

-- GoldbookDB:
--   prices[realmKey][itemKey]  = price record, see Codec.EncodePrice
--   history[realmKey][itemKey] = the item's prices per day for KEPT_DAYS, see Codec.HistoryDay
--   scanned[realmKey]          = time of the newest scan
--   items[itemKey]             = "quality|name"
--   vendor[itemID]             = what the item's data says a vendor pays, 0 when it buys nothing
--   vendorPaid[itemID]         = what a vendor paid for one, read from the buyback list, which outranks
--                                the item's data: that is wrong for some items
--   merchant[itemID]           = the lowest gold price a merchant asks for one it sells without limit
--   gold[character][hour]      = gold at the end of that hour of unix time, see Ledger
--   characters[character]      = { name, realm, faction, class, level, at, bags = { at, rows }, bank = { at, rows } }
--                                  saved at logout for the sync agent, rows as Advisor.Sell gives them, no bank
--                                  until the bank was seen open
--   bank[character]            = { at, items = { { key, count }, ... } }, the unbound items in the bank when last open
--   trades[character][]        = { at, side, item, key, count, price, fee }, auction house sales and purchases,
--                                  oldest first, see Trades
--   scans[]                    = scans waiting for the sync agent
--   linkSamples[]              = links of variants the last full scan left out
--   account                    = { id, key }, the login to the Goldbook web page, see Codec.RandomCode
--   settings                   = { lastReplicate, minProfit, autoScan, minimapAngle, hideMinimap, altClick,
--                                  window = { point, relativePoint, x, y } where the window was dropped }

-- Schema 1 records were "min,mv,avg,qty,seen".
local function upgradeFromSchema1(db)
  for realmKey, prices in pairs(db.prices or {}) do
    local newest = 0
    for key, packed in pairs(prices) do
      local min, mv, _, qty, seen = packed:match("^(%d+),(%d+),(%d+),(%d+),(%d+)$")
      seen = tonumber(seen)
      newest = math.max(newest, seen)
      prices[key] = Codec.EncodePrice({
        min = tonumber(min),
        qty = tonumber(qty),
        n = 0,
        seen = seen,
        mv = tonumber(mv),
        mvAt = tonumber(mv) > 0 and seen or 0,
        days = { tonumber(min) },
        ladder = {},
      })
    end
    db.scanned = db.scanned or {}
    db.scanned[realmKey] = newest
  end
end

-- Schema 2 had no dated history, so each item's starts from its newest price.
local function upgradeFromSchema2(db)
  db.history = {}
  for realmKey, prices in pairs(db.prices or {}) do
    local history = {}
    for key, packed in pairs(prices) do
      local record = Codec.DecodePrice(packed)
      local day = math.floor(record.seen / DAY)
      local mv = math.floor(record.mvAt / DAY) == day and record.mv or 0
      history[key] = Codec.HistoryDay(day, record.min, record.qty, mv)
    end
    db.history[realmKey] = history
  end
end

-- Schema 3 kept gold per day. A day's balance becomes that of its last hour.
-- Today's goes to the current hour instead, because at the last hour it would
-- outrank the balances recorded later today. A key past today is an hour
-- already, left by this version before an older one opened the file.
local function upgradeFromSchema3(db, now)
  local today, current = math.floor(now / DAY), math.floor(now / HOUR)
  for character, days in pairs(db.gold or {}) do
    local hours = {}
    for key, copper in pairs(days) do
      hours[key > today and key or math.min(key * 24 + 23, current)] = copper
    end
    db.gold[character] = hours
  end
end

-- Vendor sales booked before vendorPaid existed, or while the buyback list
-- was not read, say what a vendor paid too.
local function vendorPaidFromTrades(db)
  for _, booked in pairs(db.trades) do
    for _, trade in ipairs(booked) do
      local itemID = trade.side == "vendor" and trade.key and Codec.BaseID(trade.key)
      if itemID and not db.vendorPaid[itemID] then
        db.vendorPaid[itemID] = math.floor(trade.price / trade.count)
      end
    end
  end
end

-- A random source for Codec.RandomCode. The client gives addons only
-- math.random, which may be seeded from the clock in seconds, so two accounts
-- made in the same second could get the same codes. A Park-Miller stream
-- seeded from the finer timers is added to each draw to tell them apart.
local function randomSource()
  local micro = debugprofilestop and debugprofilestop() * 1000 or 0
  local seed = math.floor(micro + GetTime() * 1000 + time()) % (PARK_MILLER - 1) + 1
  return function(n)
    seed = seed * 16807 % PARK_MILLER
    return (math.random(n) + math.floor(seed / PARK_MILLER * n)) % n + 1
  end
end

-- One source for both codes, because two seeded from the same clock reading
-- would draw alike.
local function newAccount()
  local random = randomSource()
  return { id = Codec.RandomCode(ID_LENGTH, random), key = Codec.RandomCode(KEY_LENGTH, random) }
end

function Database.Init(saved)
  local db = saved or {}
  if db.version == 1 then
    upgradeFromSchema1(db)
    db.version = 2
  end
  if db.version == 2 then
    upgradeFromSchema2(db)
    db.version = 3
  end
  if db.version == 3 then
    upgradeFromSchema3(db, time())
  end
  db.version = SCHEMA
  db.prices = db.prices or {}
  db.history = db.history or {}
  db.scanned = db.scanned or {}
  db.items = db.items or {}
  db.vendor = db.vendor or {}
  db.vendorPaid = db.vendorPaid or {}
  db.merchant = db.merchant or {}
  db.gold = db.gold or {}
  db.scans = db.scans or {}
  db.sellerScans = db.sellerScans or {}
  db.settings = db.settings or {}
  db.characters = db.characters or {}
  db.bank = db.bank or {}
  db.trades = db.trades or {}
  db.account = db.account or newAccount()
  vendorPaidFromTrades(db)
  return db
end

-- Logins made with the old key end once the sync agent uploads the new one.
function Database.NewKey(db)
  db.account.key = Codec.RandomCode(KEY_LENGTH, randomSource())
end

function Database.RealmKey(realm, faction)
  return realm .. "-" .. faction
end

function Database.SetItem(db, key, name, quality)
  db.items[key] = quality .. "|" .. name
end

function Database.Item(db, key)
  local packed = db.items[key]
  if not packed then
    return nil
  end
  local quality, name = packed:match("^(%d+)|(.*)$")
  return name, tonumber(quality)
end

function Database.Vendor(db, key)
  local itemID = Codec.BaseID(key)
  return db.vendorPaid[itemID] or db.vendor[itemID]
end

-- Whether Database.Vendor is what a vendor was seen paying, not the item's data.
function Database.VendorSeen(db, key)
  return db.vendorPaid[Codec.BaseID(key)] ~= nil
end

-- `price` is what the vendor paid for `count` of the item.
function Database.SetVendorPaid(db, key, count, price)
  db.vendorPaid[Codec.BaseID(key)] = math.floor(price / count)
end

-- Goods merchants sell without limit, known before a merchant selling them
-- was visited: drinks, spices, thread, vials, flux, dyes, trade supplies,
-- class reagents and fishing supplies.
local MERCHANT_GOODS = {}
for _, itemID in ipairs({
  159, 1179, 2678, 2692, 3713, 4289,
  2320, 2321, 4291, 8343, 14341,
  3371, 3372, 8925,
  2880, 3466, 3857, 4470, 4471, 6217,
  2324, 2604, 2605, 4340, 4341, 4342, 6260,
  5140, 17020, 17026, 17029, 17030, 17031, 17034, 17035, 17036, 17037, 17038, 17056,
  6256, 6529, 6530,
}) do
  MERCHANT_GOODS[itemID] = true
end

-- A merchant selling `count` for `price` without limit.
function Database.SetMerchantPrice(db, itemID, count, price)
  local each = math.ceil(price / count)
  db.merchant[itemID] = math.min(db.merchant[itemID] or each, each)
end

-- What a merchant asks for one, once a merchant selling it was seen.
function Database.MerchantPrice(db, key)
  return db.merchant[Codec.BaseID(key)]
end

-- Whether anyone can buy the item from a merchant in any amount. Its listings
-- on the auction house then sell only to buyers who do not know that.
function Database.MerchantSells(db, key)
  local itemID = Codec.BaseID(key)
  return db.merchant[itemID] ~= nil or MERCHANT_GOODS[itemID] == true
end

function Database.Lookup(db, realmKey, key)
  local prices = db.prices[realmKey]
  local packed = prices and prices[key]
  return packed and Codec.DecodePrice(packed)
end

-- One item's prices per day, oldest first: { { day, min, qty, mv }, ... }.
function Database.History(db, realmKey, key)
  local history = db.history[realmKey]
  local packed = history and history[key]
  return packed and Codec.DecodeHistory(packed) or {}
end

-- The key a link is priced under on this realm. A bonus id is the suffix when
-- the realm has a price for that variant.
function Database.KeyFromLink(db, realmKey, link)
  local prices = db.prices[realmKey] or {}
  local itemID = tonumber(link:match("item:(%d+)"))
  return Codec.KeyFromLink(link, function(bonus)
    return prices[Codec.ItemKey(itemID, bonus)] ~= nil
  end)
end

local function prune(db, now)
  local kept = {}
  for _, scan in ipairs(db.scans) do
    if now - scan.at <= MAX_QUEUE_AGE then
      kept[#kept + 1] = scan
    end
  end
  while #kept > MAX_QUEUED_SCANS do
    table.remove(kept, 1)
  end
  db.scans = kept
end

-- A later scan on the same day replaces that day's price.
local function withToday(old, min, at)
  local days = old and old.days or {}
  if old and math.floor(old.seen / DAY) == math.floor(at / DAY) then
    days[#days] = min
  else
    days[#days + 1] = min
  end
  while #days > HISTORY_DAYS do
    table.remove(days, 1)
  end
  return days
end

-- Adds the scan's day to an item's history without decoding it. The same day
-- again replaces the newest entry, keeping a market value a full scan
-- measured earlier that day; days before the kept window are cut off.
local function logDay(packed, today, row)
  local mv = row.mv
  if packed then
    local start, day, dayMv = Codec.NewestDay(packed)
    if day == today then
      packed, mv = packed:sub(1, start - 1), mv > 0 and mv or dayMv
    else
      packed = packed .. ","
    end
  end
  packed = (packed or "") .. Codec.HistoryDay(today, row.min, row.qty, mv)
  while tonumber(packed:match("^%d+")) < today - KEPT_DAYS do
    packed = packed:sub(packed:find(",", 1, true) + 1)
  end
  return packed
end

-- scan = { realm, faction, region, at, mode, by, build, rows, names }
function Database.ApplyScan(db, scan)
  local realmKey = Database.RealmKey(scan.realm, scan.faction)
  local prices = db.prices[realmKey] or {}
  db.prices[realmKey] = prices
  local history = db.history[realmKey] or {}
  db.history[realmKey] = history
  local today = math.floor(scan.at / DAY)
  db.scanned[realmKey] = scan.at

  for _, row in ipairs(scan.rows) do
    local old = prices[row.key] and Codec.DecodePrice(prices[row.key])
    -- Only a full scan measures a market value; a quick scan keeps the last one.
    local measured = row.mv > 0
    prices[row.key] = Codec.EncodePrice({
      min = row.min,
      qty = row.qty,
      n = row.n,
      seen = scan.at,
      mv = measured and row.mv or (old and old.mv or 0),
      mvAt = measured and scan.at or (old and old.mvAt or 0),
      days = withToday(old, row.min, scan.at),
      ladder = row.ladder or {},
    })
    history[row.key] = logDay(history[row.key], today, row)
  end
  -- Items not listed for longer than the kept window.
  for key, packed in pairs(history) do
    local _, newest = Codec.NewestDay(packed)
    if newest < today - KEPT_DAYS then
      history[key] = nil
    end
  end
  for key, item in pairs(scan.names) do
    Database.SetItem(db, key, item.name, item.quality)
  end

  db.scans[#db.scans + 1] = {
    realm = scan.realm,
    faction = scan.faction,
    region = scan.region,
    at = scan.at,
    mode = scan.mode,
    by = scan.by,
    build = scan.build,
    count = #scan.rows,
    data = Codec.EncodeRows(scan.rows),
  }
  prune(db, scan.at)
end

-- Every priced item of a realm as { key, name, quality, <price record fields> }.
function Database.Items(db, realmKey)
  local items = {}
  for key, packed in pairs(db.prices[realmKey] or {}) do
    local item = Codec.DecodePrice(packed)
    local name, quality = Database.Item(db, key)
    item.key, item.name, item.quality = key, name or ("item " .. key), quality or 1
    items[#items + 1] = item
  end
  return items
end

function Database.Search(db, realmKey, text)
  local needle = text:lower()
  local results = {}
  for _, item in ipairs(Database.Items(db, realmKey)) do
    if needle == "" or item.name:lower():find(needle, 1, true) then
      results[#results + 1] = item
    end
  end
  table.sort(results, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.key < b.key
  end)
  return results
end
