local _, ns = ...
local Stats, Database = ns.Stats, ns.Database

-- Turns stored prices into advice: what to buy, and how to sell what you own.
local Advisor = {}
ns.Advisor = Advisor

local AH_CUT = 0.05
local DEAL_RATIO = 0.7
local MIN_HISTORY = 3
local FLOOR_RATIO = 0.6
local CEILING_RATIO = 2
local MOVER_MIN_PRICE = 100
local DAY = 24 * 3600
local WEEK = 7
local MONTH = 30

-- What a sale at `price` pays out after the auction house keeps its cut.
function Advisor.Proceeds(price)
  return math.floor(price * (1 - AH_CUT))
end

local function median(days, count)
  local values = {}
  for index = 1, count do
    values[index] = days[index]
  end
  return Stats.Median(values)
end

-- The middle lowest price over the days the item was seen, once there are
-- enough days for one cheap or greedy listing not to decide it.
function Advisor.Usual(record)
  if #record.days >= MIN_HISTORY then
    return median(record.days, #record.days)
  end
end

-- What the item sells for, judged without today's lowest price, so that a
-- bargain does not lower the bar it is measured against. Takes the lower of
-- today's market value and the usual price of earlier days.
local function resaleValue(record)
  local market = record.mvAt == record.seen and record.mv > 0 and record.mv or nil
  local earlier = #record.days - 1 >= MIN_HISTORY and median(record.days, #record.days - 1) or nil
  if market and earlier then
    return math.min(market, earlier)
  end
  return market or earlier
end

-- `earns` is what one unit brings in and `limit` the highest price still worth
-- paying. After a full scan the ladder says how many units that covers and
-- what buying them all makes; after a quick scan only one unit is known.
local function deal(kind, record, sell, earns, limit)
  local units, total = 0, 0
  for _, level in ipairs(record.ladder) do
    if level.price > limit then
      break
    end
    units = units + level.count
    total = total + (earns - level.price) * level.count
  end
  local profit = earns - record.min
  if units == 0 then
    return { kind = kind, sell = sell, profit = profit, total = profit }
  end
  return { kind = kind, sell = sell, profit = profit, total = total, units = units }
end

-- A deal is something listed right now that sells for more: to a vendor,
-- which is certain, or on the auction house at its usual price. Of the two
-- the one that makes more is returned. What merchants sell (`stocked`) is
-- only a deal to vendor: its usual auction price is paid only by buyers who
-- do not know a merchant has it.
function Advisor.Deal(record, vendor, newestScan, stocked)
  if record.seen ~= newestScan then
    return nil
  end
  local best
  if vendor and vendor > record.min then
    best = deal("vendor", record, vendor, vendor, vendor - 1)
  end
  local resale = not stocked and resaleValue(record)
  if resale and record.min <= resale * DEAL_RATIO then
    local flip = deal("flip", record, resale, Advisor.Proceeds(resale), resale * DEAL_RATIO)
    if not best or flip.total > best.total then
      best = flip
    end
  end
  return best
end

-- Vendor deals always count; a flip must make `minProfit` in total.
function Advisor.Deals(db, realmKey, minProfit)
  local newestScan = db.scanned[realmKey]
  local deals = {}
  for _, item in ipairs(Database.Items(db, realmKey)) do
    local found = Advisor.Deal(item, Database.Vendor(db, item.key), newestScan, Database.MerchantSells(db, item.key))
    if found and (found.kind == "vendor" or found.total >= minProfit) then
      item.kind, item.sell, item.total, item.units = found.kind, found.sell, found.total, found.units
      deals[#deals + 1] = item
    end
  end
  table.sort(deals, function(a, b)
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.key < b.key
  end)
  return deals
end

-- In percent, to one decimal.
local function percentChange(from, to)
  return math.floor((to - from) / from * 1000 + 0.5) / 10
end

-- Items in the newest scan whose lowest price differs from the day before
-- they were last seen, biggest rise first. `change` is in percent. Prices
-- under a silver on both days are left out as noise.
function Advisor.Movers(db, realmKey)
  local newestScan = db.scanned[realmKey]
  local movers = {}
  for _, item in ipairs(Database.Items(db, realmKey)) do
    local before = item.days[#item.days - 1]
    if item.seen == newestScan and before and before ~= item.min and math.max(before, item.min) >= MOVER_MIN_PRICE then
      item.before = before
      item.change = percentChange(before, item.min)
      movers[#movers + 1] = item
    end
  end
  table.sort(movers, function(a, b)
    if a.change ~= b.change then
      return a.change > b.change
    end
    return a.key < b.key
  end)
  return movers
end

-- How one item's lowest price moved, from its Database.History. `rows` are
-- the days it was seen, newest first, each with its change from the day
-- before it. `chart` has a slot per calendar day of the last `span`, oldest
-- first: that day's entry, or false when the item was not seen. `day`, `week`
-- and `month` compare the newest price with the newest one at least that many
-- days older.
function Advisor.Evolution(history, now, span)
  local rows, byDay = {}, {}
  for index = #history, 1, -1 do
    local entry, older = history[index], history[index - 1]
    rows[#rows + 1] = {
      day = entry.day,
      min = entry.min,
      qty = entry.qty,
      mv = entry.mv,
      change = older and percentChange(older.min, entry.min) or nil,
    }
    byDay[entry.day] = entry
  end

  local evolution = { rows = rows, chart = {} }
  local today = math.floor(now / DAY)
  for day = today - span + 1, today do
    local entry = byDay[day] or false
    evolution.chart[#evolution.chart + 1] = entry
    if entry then
      evolution.low = math.min(evolution.low or entry.min, entry.min)
      evolution.high = math.max(evolution.high or entry.min, entry.min)
    end
  end

  local newest = history[#history]
  local function since(days)
    for index = #history - 1, 1, -1 do
      if history[index].day <= newest.day - days then
        return percentChange(history[index].min, newest.min)
      end
    end
  end
  evolution.day, evolution.week, evolution.month = since(1), since(WEEK), since(MONTH)
  return evolution
end

-- The price to post one unit at. Undercut the lowest listing by a copper, but
-- never below a floor (60% of the normal price, and more than a vendor pays
-- after the cut) and never above twice the normal price. When the lowest
-- listing is under the floor, hold the normal price instead of chasing it.
function Advisor.PostPrice(record, vendor, newestScan)
  local normal = Advisor.Usual(record) or (record.mv > 0 and record.mv) or record.min
  local floor = math.floor(normal * FLOOR_RATIO)
  if vendor and vendor > 0 then
    floor = math.max(floor, math.ceil(vendor / (1 - AH_CUT)) + 1)
  end
  local undercut = record.seen == newestScan and record.min - 1 or nil
  if not undercut or undercut < floor then
    return math.max(normal, floor)
  end
  return math.min(undercut, normal * CEILING_RATIO)
end

-- bag = { { key, count }, ... }. Says for each item whether to auction it or
-- vendor it, and what that brings in. An item whose lowest listing already
-- pays less than a vendor goes to the vendor, and so does one that merchants
-- sell, which no informed buyer pays the auction price for.
function Advisor.Sell(db, realmKey, bag)
  local newestScan = db.scanned[realmKey]
  local rows, total = {}, 0
  for _, held in ipairs(bag) do
    local record = Database.Lookup(db, realmKey, held.key)
    local vendor = Database.Vendor(db, held.key) or 0
    local name, quality = Database.Item(db, held.key)
    local row = { key = held.key, name = name or ("item " .. held.key), quality = quality or 1, count = held.count, vendor = vendor }
    local underVendor = record and record.seen == newestScan and Advisor.Proceeds(record.min) <= vendor
    local stocked = Database.MerchantSells(db, held.key)
    local post = record and not underVendor and not stocked and Advisor.PostPrice(record, vendor, newestScan)
    if post and Advisor.Proceeds(post) > vendor then
      row.action, row.post, row.value = "auction", post, Advisor.Proceeds(post) * held.count
    elseif vendor > 0 then
      row.action, row.value = "vendor", vendor * held.count
    else
      row.action, row.value = "unknown", 0
    end
    total = total + row.value
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then
      return a.value > b.value
    end
    return a.key < b.key
  end)
  return rows, total
end
