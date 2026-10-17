local _, ns = ...
local Codec = ns.Codec

local Database = {}
ns.Database = Database

local SCHEMA = 5
local MAX_QUEUED_SCANS = 20
local MAX_QUEUE_AGE = 14 * 24 * 3600
local HISTORY_DAYS = 14
local KEPT_DAYS = 60
-- The hours the chart shows by the hour, as the server's export keeps them.
local KEPT_HOURS = 168
local HOUR = 3600
local DAY = 24 * HOUR
local ID_LENGTH, KEY_LENGTH = 8, 20
local PARK_MILLER = 2147483647

-- GoldbookDB:
--   prices[realmKey][itemKey]  = price record, see Codec.EncodePrice
--   history[realmKey][itemKey] = the item's prices per day for KEPT_DAYS, see Codec.HistoryDay
--   hours[realmKey][itemKey]   = the same per hour for the KEPT_HOURS up to the item's newest scan
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
--   fromServer[realmKey][itemKey] = the server's seen time of a price taken from GoldbookServerData,
--                                until a scan here prices the item again
--   serverMerged[realmKey]     = the scannedAt of the server data merged last, see Database.MergeServer
--   settings                   = { lastReplicate, minProfit, autoScan, minimapAngle, hideMinimap, altClick, theme, scale,
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
  -- Schema 5 adds the hours, which start empty.
  db.hours = db.hours or {}
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
  db.fromServer = db.fromServer or {}
  db.serverMerged = db.serverMerged or {}
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

-- Every price kept for one item, oldest first, as { at, min, qty, mv, hourly }
-- with `at` the start of its hour or day: its hours, and before them the days
-- before the first of them.
function Database.Points(db, realmKey, key)
  local hours = db.hours[realmKey]
  local packed = hours and hours[key]
  local hourly = packed and Codec.DecodeHistory(packed) or {}
  local first = hourly[1] and math.floor(hourly[1].day * HOUR / DAY) or math.huge
  local points = {}
  for _, entry in ipairs(Database.History(db, realmKey, key)) do
    if entry.day < first then
      points[#points + 1] = { at = entry.day * DAY, min = entry.min, qty = entry.qty, mv = entry.mv }
    end
  end
  for _, entry in ipairs(hourly) do
    points[#points + 1] = { at = entry.day * HOUR, min = entry.min, qty = entry.qty, mv = entry.mv, hourly = true }
  end
  return points
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

-- A day's price is its lowest, as in the history.
local function withToday(old, min, at)
  local days = old and old.days or {}
  if old and math.floor(old.seen / DAY) == math.floor(at / DAY) then
    days[#days] = math.min(days[#days] or min, min)
  else
    days[#days + 1] = min
  end
  while #days > HISTORY_DAYS do
    table.remove(days, 1)
  end
  return days
end

-- Adds the scan to the entry numbered `number`, a day or an hour, of a
-- history without decoding it, and cuts the entries before `first` off. A
-- later scan of the same day or hour keeps the lowest price with the quantity
-- listed at it, the earlier one's when they tie, and the newest market value
-- a full scan measured, as the server's export folds them. A scan from a
-- clock set back leaves a newer entry as it is.
local function logEntry(packed, number, row, first)
  local min, qty, mv = row.min, row.qty, row.mv
  if packed then
    local start, newest, newestMv, newestMin, newestQty = Codec.NewestDay(packed)
    if newest > number then
      return packed
    elseif newest == number then
      packed, mv = packed:sub(1, start - 1), mv > 0 and mv or newestMv
      if newestMin <= min then
        min, qty = newestMin, newestQty
      end
    else
      packed = packed .. ","
    end
  end
  packed = (packed or "") .. Codec.HistoryDay(number, min, qty, mv)
  while tonumber(packed:match("^%d+")) < first do
    packed = packed:sub(packed:find(",", 1, true) + 1)
  end
  return packed
end

-- Leaves out the items whose newest entry is before `first`.
local function forget(histories, first)
  for key, packed in pairs(histories) do
    local _, newest = Codec.NewestDay(packed)
    if newest < first then
      histories[key] = nil
    end
  end
end

-- A history with the entries of `server` it lacks, oldest first, the local
-- entry kept where both have one, and only the `kept` numbers up to the
-- newest of either. Both are "number:min:qty:mv,..." strings, see
-- Codec.HistoryDay.
local function filled(packed, server, kept)
  if packed == server or not server then
    return packed
  end
  local merged, entries = {}, {}
  for _, list in ipairs({ packed or "", server }) do
    for number, rest in list:gmatch("(%d+)(:[^,]*)") do
      number = tonumber(number)
      if not entries[number] then
        entries[number] = number .. rest
        merged[#merged + 1] = number
      end
    end
  end
  table.sort(merged)
  local first, joined = merged[#merged] - kept + 1, {}
  for _, number in ipairs(merged) do
    if number >= first then
      joined[#joined + 1] = entries[number]
    end
  end
  return table.concat(joined, ",")
end

-- The lows of an item's last days, as a price record keeps them.
local function recentDays(packed)
  local days = {}
  for min in (packed or ""):gmatch("%d+:(%d+):%d+:%d+") do
    days[#days + 1] = tonumber(min)
  end
  while #days > HISTORY_DAYS do
    table.remove(days, 1)
  end
  return days
end

-- Merges the prices others scanned, which the Goldbook app writes to
-- ServerData.lua as GoldbookServerData (see docs/server-data.md), into the
-- saved data. A price seen here as late or later stays; an older one takes
-- the server's, and its market value when the server measured one later.
-- Server days and hours fill only what this history lacks, and server names
-- only the items without one. Merging the same data again changes nothing,
-- and a realm whose data was merged as it is now is skipped. Returns how many
-- prices it took.
function Database.MergeServer(db, data)
  if type(data) ~= "table" or data.version ~= 1 then
    return 0
  end
  for key, item in pairs(data.items or {}) do
    db.items[key] = db.items[key] or item
  end
  local taken = 0
  for realmKey, realm in pairs(data.realms or {}) do
    if db.serverMerged[realmKey] ~= realm.scannedAt then
      local prices, history, hours = db.prices[realmKey] or {}, db.history[realmKey] or {}, db.hours[realmKey] or {}
      local fromServer = db.fromServer[realmKey] or {}
      db.prices[realmKey], db.history[realmKey], db.hours[realmKey], db.fromServer[realmKey] = prices, history, hours, fromServer
      for key, packed in pairs(realm.days or {}) do
        history[key] = filled(history[key], packed, KEPT_DAYS + 1)
      end
      for key, packed in pairs(realm.hours or {}) do
        hours[key] = filled(hours[key], packed, KEPT_HOURS)
      end
      for key, packed in pairs(realm.prices or {}) do
        local server = Codec.DecodePrice(packed .. ";")
        local old = prices[key] and Codec.DecodePrice(prices[key])
        if not old or old.seen < server.seen then
          local measured = not old or server.mvAt > old.mvAt
          prices[key] = Codec.EncodePrice({
            min = server.min,
            qty = server.qty,
            n = server.n,
            seen = server.seen,
            mv = measured and server.mv or old.mv,
            mvAt = measured and server.mvAt or old.mvAt,
            days = recentDays(history[key]),
            ladder = {},
          })
          fromServer[key] = server.seen
          taken = taken + 1
        elseif server.mvAt > old.mvAt then
          old.mv, old.mvAt = server.mv, server.mvAt
          prices[key] = Codec.EncodePrice(old)
        end
      end
      db.serverMerged[realmKey] = realm.scannedAt
    end
  end
  return taken
end

-- Whether an item's price on the realm came from the server's data.
function Database.FromServer(db, realmKey, key)
  local fromServer = db.fromServer[realmKey]
  return fromServer ~= nil and fromServer[key] ~= nil
end

-- scan = { realm, faction, region, at, mode, by, build, rows, names }
function Database.ApplyScan(db, scan)
  local realmKey = Database.RealmKey(scan.realm, scan.faction)
  local prices = db.prices[realmKey] or {}
  db.prices[realmKey] = prices
  local history, hours = db.history[realmKey] or {}, db.hours[realmKey] or {}
  db.history[realmKey], db.hours[realmKey] = history, hours
  local today, hour = math.floor(scan.at / DAY), math.floor(scan.at / HOUR)
  db.scanned[realmKey] = scan.at

  local fromServer = db.fromServer[realmKey] or {}
  for _, row in ipairs(scan.rows) do
    fromServer[row.key] = nil
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
    history[row.key] = logEntry(history[row.key], today, row, today - KEPT_DAYS)
    hours[row.key] = logEntry(hours[row.key], hour, row, hour - KEPT_HOURS + 1)
  end
  forget(history, today - KEPT_DAYS)
  forget(hours, hour - KEPT_HOURS + 1)
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
