local _, ns = ...
local Database = ns.Database

-- The account's revenue and expenses, per character, as a broker's statement
-- lists them. Each entry is { at, side, item, key, count, price, fee, party }:
-- `side` one of SIDES, `item` the goods' name or for gold alone a short
-- description, `count` the units of goods or the movements added up, `price`
-- the copper moved, `fee` the auction house cut of a sale, `party` the other
-- player. A booked entry never changes, because the server keeps every entry
-- it receives.
--
-- The auction house mails an invoice for each of its trades: "seller" with
-- the sale price and its cut, "buyer" with what was paid. The mailbox shows
-- the same mails again each time it opens, so a trade is booked once: an
-- invoice that matches a booked trade to within SAME_MAIL seconds is that
-- trade. A sale to a vendor shows up in the merchant's buyback list with what
-- the vendor paid; see Trades.Merchant. Every other entry comes from
-- Accounting.
local Trades = {}
ns.Trades = Trades

local HOUR = 3600
local DAY = 24 * HOUR
-- Auction house mail stays 30 days; the days it has left date it.
local MAIL_DAYS = 30
local SAME_MAIL = 120
local KEPT_DAYS = 180
-- About a month at a busy pace. Entries the mailbox can still show are kept
-- past it, so that their invoices are not booked again.
local MAX_TRADES = 3000
local MAX_ITEM, MAX_PARTY = 200, 64
local INVOICES = { seller = "sell", buyer = "buy" }
-- A full buyback list drops its oldest entry for each sale.
local BUYBACK_SLOTS = 12

-- Every kind of entry, in the order the Accounting view offers them: its
-- label, whether it adds to the gold, whether it moves goods, which way it
-- went with the other player, and the `item` of an entry of gold alone.
-- `free` goods may change hands for no gold; `accrues` gold is added up per
-- hour, see Trades.Accrue.
Trades.SIDES = {
  { "sell", "Auction sale", revenue = true, goods = true },
  { "buy", "Auction purchase", goods = true },
  { "vendor", "Vendor sale", revenue = true, goods = true },
  { "merchant", "Merchant purchase", goods = true },
  { "tradeSell", "Trade sale", revenue = true, goods = true, free = true, party = "to" },
  { "tradeBuy", "Trade purchase", goods = true, free = true, party = "from" },
  { "tradeIn", "Trade gold in", revenue = true, party = "from", text = "Gold" },
  { "tradeOut", "Trade gold out", party = "to", text = "Gold" },
  { "mailIn", "Mail gold in", revenue = true, party = "from", text = "Gold" },
  { "mailOut", "Mail gold out", party = "to", text = "Gold" },
  { "cod", "Cash on delivery", goods = true, party = "from" },
  { "quest", "Quest reward", revenue = true, text = "Quest" },
  { "loot", "Looted gold", revenue = true, accrues = true, text = "Looted gold" },
  { "repair", "Repairs", text = "Repairs" },
  { "postage", "Postage", text = "Postage" },
  { "deposit", "Auction deposit", text = "Auction" },
  { "travel", "Flight", text = "Flight" },
  { "training", "Training", text = "Training" },
  { "respec", "Talent reset", text = "Talent reset" },
  { "otherIn", "Other income", revenue = true, accrues = true, text = "Other" },
  { "otherOut", "Other expense", accrues = true, text = "Other" },
}
local SIDE = {}
for _, side in ipairs(Trades.SIDES) do
  SIDE[side[1]] = side
end
Trades.SIDE = SIDE

-- The key an item name is priced under: the one named exactly that, the
-- shortest when several are, so that a base item wins over a variant still
-- named after it.
local function keysByName(db)
  local keys = {}
  for key, packed in pairs(db.items) do
    local name = packed:match("^%d+|(.*)$")
    local known = keys[name]
    if name and (not known or #key < #known or (#key == #known and key < known)) then
      keys[name] = key
    end
  end
  return keys
end

-- The auction house invoices in the mailbox as { side, item, key, count,
-- price, fee, at }: price is the whole stack's, fee the auction house cut.
-- A sale still waiting for its money ("seller_temp_invoice") is left for the
-- mail that brings it.
function Trades.FromInbox(db, realmKey, now)
  local invoices, keys = {}, nil
  for index = 1, GetInboxNumItems() do
    local invoiceType, item, _, bid, _, _, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    local side = INVOICES[invoiceType]
    local daysLeft = select(7, GetInboxHeaderInfo(index))
    if side and item and item ~= "" and bid and bid > 0 and daysLeft then
      local link = side == "buy" and GetInboxItemLink and GetInboxItemLink(index, 1)
      local key = link and Database.KeyFromLink(db, realmKey, link)
      if not key then
        keys = keys or keysByName(db)
        key = keys[item]
      end
      invoices[#invoices + 1] = {
        side = side,
        item = item,
        key = key,
        count = math.max(count or 1, 1),
        price = bid,
        fee = side == "sell" and consignment or 0,
        at = now - math.max(0, math.floor((MAIL_DAYS - daysLeft) * DAY + 0.5)),
      }
    end
  end
  return invoices
end

-- Keeps `booked` oldest first, an entry after those of the same time.
local function insert(booked, entry)
  local index = #booked
  while index > 0 and booked[index].at > entry.at do
    index = index - 1
  end
  table.insert(booked, index + 1, entry)
end

-- KEPT_DAYS and at most MAX_TRADES, but never what the mailbox may still show.
local function prune(booked, now)
  local oldest, mailed = now - KEPT_DAYS * DAY, now - MAIL_DAYS * DAY
  while booked[1] and (booked[1].at < oldest or (#booked > MAX_TRADES and booked[1].at < mailed)) do
    table.remove(booked, 1)
  end
end

local function same(trade, invoice)
  return trade.side == invoice.side and trade.item == invoice.item and trade.count == invoice.count
    and trade.price == invoice.price and trade.fee == invoice.fee and math.abs(trade.at - invoice.at) <= SAME_MAIL
end

-- Books the invoices not booked yet for `character`, oldest first, keeping
-- KEPT_DAYS and at most MAX_TRADES. Returns how many sales and purchases
-- were new.
function Trades.Book(db, character, invoices, now)
  local booked = db.trades[character] or {}
  db.trades[character] = booked
  local claimed, sold, bought = {}, 0, 0
  for _, invoice in ipairs(invoices) do
    local match
    for _, trade in ipairs(booked) do
      if not claimed[trade] and same(trade, invoice) then
        match = trade
        break
      end
    end
    if not match then
      match = {
        at = invoice.at,
        side = invoice.side,
        item = invoice.item,
        key = invoice.key,
        count = invoice.count,
        price = invoice.price,
        fee = invoice.fee,
      }
      insert(booked, match)
      if invoice.side == "sell" then
        sold = sold + 1
      else
        bought = bought + 1
      end
    end
    claimed[match] = true
  end
  prune(booked, now)
  return sold, bought
end

-- Books `entries` for `character` as they are, leaving out any the contract
-- with the server refuses: no gold where gold must move, or no item.
function Trades.Add(db, character, entries, now)
  local booked = db.trades[character] or {}
  db.trades[character] = booked
  for _, entry in ipairs(entries) do
    local side = SIDE[entry.side]
    if side and entry.item and entry.item ~= "" and (entry.price >= 1 or (side.free and entry.price == 0)) then
      insert(booked, {
        at = entry.at,
        side = entry.side,
        item = entry.item:sub(1, MAX_ITEM),
        key = entry.key,
        count = math.max(entry.count or 1, 1),
        price = entry.price,
        fee = entry.fee or 0,
        party = entry.party and entry.party ~= "" and entry.party:sub(1, MAX_PARTY) or nil,
      })
    end
  end
  prune(booked, now)
end

-- Books the hours of accrued gold that have ended, of every character.
function Trades.Close(db, now)
  local hour = now - now % HOUR
  for character, open in pairs(db.accruing) do
    for _, side in ipairs(Trades.SIDES) do
      local entry = open[side[1]]
      if entry and entry.at < hour then
        Trades.Add(db, character, { entry }, now)
        open[side[1]] = nil
      end
    end
    if next(open) == nil then
      db.accruing[character] = nil
    end
  end
end

-- Gold that comes in many small amounts, as looted gold does, is added up per
-- character, side and hour in db.accruing, dated the start of the hour, and
-- booked once the hour has ended: a booked entry never changes.
function Trades.Accrue(db, character, side, copper, now)
  Trades.Close(db, now)
  local open = db.accruing[character] or {}
  db.accruing[character] = open
  local entry = open[side]
  if not entry then
    entry = { at = now - now % HOUR, side = side, item = SIDE[side].text, count = 0, price = 0, fee = 0 }
    open[side] = entry
  end
  entry.count, entry.price = entry.count + 1, entry.price + copper
end

-- The merchant's buyback list as { item, key, count, price, id }, price
-- being what the vendor paid for the whole stack; `id` tells equal entries
-- apart from others.
local function buyback(db, realmKey)
  local entries, keys = {}, nil
  for index = 1, GetNumBuybackItems() do
    local item, _, price, count = GetBuybackItemInfo(index)
    if item and item ~= "" and price and price > 0 then
      local link = GetBuybackItemLink(index)
      local key = link and Database.KeyFromLink(db, realmKey, link)
      if not key then
        keys = keys or keysByName(db)
        key = keys[item]
      end
      count = math.max(count or 1, 1)
      entries[#entries + 1] = {
        item = item,
        key = key,
        count = count,
        price = price,
        id = table.concat({ item, count, price, link or "" }, "|"),
      }
    end
  end
  return entries
end

-- How many of each entry, and one of them by its id.
local function tally(entries)
  local counts, byId = {}, {}
  for _, entry in ipairs(entries) do
    counts[entry.id] = (counts[entry.id] or 0) + 1
    byId[entry.id] = entry
  end
  return counts, byId
end

local function vendorSale(entry, now)
  return { at = now, side = "vendor", item = entry.item, key = entry.key, count = entry.count, price = entry.price, fee = 0 }
end

-- The buyback list as last read, tallied, and the gold then.
local listed, listedById, listedMoney

-- Called when a merchant opens, whenever its lists change, and when it
-- closes. An entry new to the buyback list is a sale to a vendor. An entry gone while nothing was added was
-- bought back, and its sale is taken off again; one gone as another came in
-- fell off the end of a full list. A full list that sold the same stack as
-- its oldest entry reads the same after, so then gold gained by exactly an
-- entry's price is that sale. Returns how many sales were booked and how many
-- were taken off.
function Trades.Merchant(db, character, realmKey, now, money, opened)
  local entries = buyback(db, realmKey)
  local counts, byId = tally(entries)
  local before, beforeById, beforeMoney = listed, listedById, listedMoney
  listed, listedById, listedMoney = counts, byId, money
  -- A list that was not read yet holds sales booked before a /reload.
  if opened or not before then
    return 0, 0
  end
  local booked = db.trades[character] or {}
  db.trades[character] = booked
  local seen, sold = {}, 0
  for _, entry in ipairs(entries) do
    seen[entry.id] = (seen[entry.id] or 0) + 1
    if seen[entry.id] > (before[entry.id] or 0) then
      insert(booked, vendorSale(entry, now))
      sold = sold + 1
    end
  end
  local undone, changed = 0, sold > 0
  for id, count in pairs(before) do
    changed = changed or count ~= (counts[id] or 0)
  end
  local gained = beforeMoney and money - beforeMoney or 0
  if not changed and #entries == BUYBACK_SLOTS and gained > 0 then
    for index = #entries, 1, -1 do
      local entry = entries[index]
      if entry.price == gained then
        insert(booked, vendorSale(entry, now))
        sold = 1
        break
      end
    end
  end
  if sold == 0 then
    for id, count in pairs(before) do
      local gone = beforeById[id]
      for _ = 1, count - (counts[id] or 0) do
        for index = #booked, 1, -1 do
          local trade = booked[index]
          if trade.side == "vendor" and trade.item == gone.item and trade.count == gone.count and trade.price == gone.price then
            table.remove(booked, index)
            undone = undone + 1
            break
          end
        end
      end
    end
  end
  prune(booked, now)
  return sold, undone
end

-- Every entry, booked or still accruing, newest first, as the Accounting
-- view lists them: { name, key, quality, character, side, source, revenue,
-- goods, party, count, price, fee, net, at }, where `net` is what it
-- did to the gold: a revenue less the auction house cut, or minus an expense.
function Trades.Rows(db)
  local rows = {}
  local function add(character, entry)
    local side = SIDE[entry.side]
    local quality
    if entry.key then
      quality = select(2, Database.Item(db, entry.key))
    end
    rows[#rows + 1] = {
      name = entry.item,
      key = entry.key,
      quality = quality or 1,
      character = character,
      side = entry.side,
      source = side[2],
      revenue = side.revenue == true,
      goods = side.goods == true,
      party = entry.party,
      count = entry.count,
      price = entry.price,
      fee = entry.fee,
      net = side.revenue and entry.price - entry.fee or -entry.price,
      at = entry.at,
    }
  end
  for character, booked in pairs(db.trades) do
    for _, entry in ipairs(booked) do
      if SIDE[entry.side] then
        add(character, entry)
      end
    end
  end
  for character, open in pairs(db.accruing) do
    for _, entry in pairs(open) do
      add(character, entry)
    end
  end
  table.sort(rows, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.side < b.side
  end)
  return rows
end

-- One row per item that `rows` moved, the goods of every side however they
-- were bought and sold, by name: { name, key, quality, bought, cost, sold,
-- proceeds, averageCost, averageSale, profit, last }. `profit` is realized on
-- the units both bought and sold, at the average sale less the average cost,
-- nil when none were both; `last` is when the item last moved.
function Trades.Items(rows)
  local items, byName = {}, {}
  for _, row in ipairs(rows) do
    if row.goods then
      local item = byName[row.name]
      if not item then
        item = { name = row.name, quality = row.quality, bought = 0, cost = 0, sold = 0, proceeds = 0, last = row.at }
        byName[row.name], items[#items + 1] = item, item
      end
      item.key, item.last = item.key or row.key, math.max(item.last, row.at)
      if row.revenue then
        item.sold, item.proceeds = item.sold + row.count, item.proceeds + row.net
      else
        item.bought, item.cost = item.bought + row.count, item.cost - row.net
      end
    end
  end
  for _, item in ipairs(items) do
    item.averageCost = item.bought > 0 and item.cost / item.bought or nil
    item.averageSale = item.sold > 0 and item.proceeds / item.sold or nil
    local matched = math.min(item.bought, item.sold)
    if matched > 0 then
      item.profit = math.floor(matched * (item.averageSale - item.averageCost) + 0.5)
    end
  end
  return items
end

-- What `rows` add up to: `revenue` after the auction house cut, `expenses`,
-- and `net` the two together. `profit` is the sum of Trades.Items' profits,
-- nil when no item was both bought and sold.
function Trades.Totals(rows)
  local totals = { revenue = 0, expenses = 0, net = 0 }
  for _, row in ipairs(rows) do
    if row.revenue then
      totals.revenue = totals.revenue + row.net
    else
      totals.expenses = totals.expenses - row.net
    end
    totals.net = totals.net + row.net
  end
  for _, item in ipairs(Trades.Items(rows)) do
    if item.profit then
      totals.profit = (totals.profit or 0) + item.profit
    end
  end
  return totals
end
