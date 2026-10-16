local _, ns = ...
local Database = ns.Database

-- Auction house sales and purchases, and sales to vendors, per character, as
-- a broker's statement lists them. The auction house mails an invoice for
-- each of its trades: "seller" with the sale price and its cut, "buyer" with
-- what was paid. The mailbox shows the same mails again each time it opens,
-- so a trade is booked once: an invoice that matches a booked trade to within
-- SAME_MAIL seconds is that trade. A sale to a vendor shows up in the
-- merchant's buyback list with what the vendor paid; see Trades.Merchant.
local Trades = {}
ns.Trades = Trades

local DAY = 24 * 3600
-- Auction house mail stays 30 days; the days it has left date it.
local MAIL_DAYS = 30
local SAME_MAIL = 120
local KEPT_DAYS = 180
local MAX_TRADES = 1000
local SIDES = { seller = "sell", buyer = "buy" }
-- A full buyback list drops its oldest entry for each sale.
local BUYBACK_SLOTS = 12

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
    local side = SIDES[invoiceType]
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

-- Oldest first, KEPT_DAYS and at most MAX_TRADES.
local function prune(booked, now)
  table.sort(booked, function(a, b)
    return a.at < b.at
  end)
  local oldest = now - KEPT_DAYS * DAY
  while booked[1] and (booked[1].at < oldest or #booked > MAX_TRADES) do
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
      booked[#booked + 1] = match
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
-- closes. Every entry tells what the vendor paid for the item, which
-- Database.Vendor trusts over the item's data. An entry new to the buyback
-- list is a sale to a vendor. An entry gone while nothing was added was
-- bought back, and its sale is taken off again; one gone as another came in
-- fell off the end of a full list. A full list that sold the same stack as
-- its oldest entry reads the same after, so then gold gained by exactly an
-- entry's price is that sale. Returns how many sales were booked and how many
-- were taken off.
function Trades.Merchant(db, character, realmKey, now, money, opened)
  local entries = buyback(db, realmKey)
  for _, entry in ipairs(entries) do
    if entry.key then
      Database.SetVendorPaid(db, entry.key, entry.count, entry.price)
    end
  end
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
      booked[#booked + 1] = vendorSale(entry, now)
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
        booked[#booked + 1] = vendorSale(entry, now)
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

-- Every booked trade, newest first, as the Trades view lists them: { name,
-- key, quality, character, side, count, each, price, fee, net, at }, where
-- `net` is what it added to the gold: the sale less the cut, what the vendor
-- paid, or minus the price paid.
function Trades.Rows(db)
  local rows = {}
  for character, booked in pairs(db.trades) do
    for _, trade in ipairs(booked) do
      local quality
      if trade.key then
        quality = select(2, Database.Item(db, trade.key))
      end
      rows[#rows + 1] = {
        name = trade.item,
        key = trade.key,
        quality = quality or 1,
        character = character,
        side = trade.side,
        count = trade.count,
        each = math.floor(trade.price / trade.count + 0.5),
        price = trade.price,
        fee = trade.fee,
        net = trade.side == "buy" and -trade.price or trade.price - trade.fee,
        at = trade.at,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.name < b.name
  end)
  return rows
end

-- What `rows` add up to: `sold` is what the sales brought in after the cut,
-- at auction and to vendors, `bought` what the purchases cost, and `net` the
-- two together. `profit` is the profit or loss realized per item on the units
-- both bought and sold, at the average sale less the average cost, nil when
-- no item was both bought and sold.
function Trades.Totals(rows)
  local totals = { sold = 0, bought = 0, net = 0 }
  local items = {}
  for _, row in ipairs(rows) do
    local item = items[row.name] or { bought = 0, cost = 0, sold = 0, proceeds = 0 }
    items[row.name] = item
    if row.side == "buy" then
      totals.bought = totals.bought + row.price
      item.bought, item.cost = item.bought + row.count, item.cost + row.price
    else
      totals.sold = totals.sold + row.net
      item.sold, item.proceeds = item.sold + row.count, item.proceeds + row.net
    end
    totals.net = totals.net + row.net
  end
  for _, item in pairs(items) do
    local matched = math.min(item.bought, item.sold)
    if matched > 0 then
      totals.profit = (totals.profit or 0)
        + math.floor(matched * (item.proceeds / item.sold - item.cost / item.bought) + 0.5)
    end
  end
  return totals
end
