local _, ns = ...
local Database, Trades = ns.Database, ns.Trades

-- Books what each change of gold was for, and the trades made in person,
-- see Trades for the entries.
--
-- PLAYER_MONEY says only that the gold changed. What for comes from what
-- caused it: a call Goldbook hooks, such as BuyMerchantItem or SendMail, or
-- an event that says, such as QUEST_TURNED_IN. Each leaves a claim: the side
-- to book, which way the gold goes, and how much when that is known. A
-- change is matched to the claims made within GRACE seconds of it, before or
-- after, because the server answers a call a moment later and some events
-- come after the gold. Gold no claim explains within GRACE goes to the window
-- that was open when it moved, such as a merchant's, or else is other income
-- or expense.
local Accounting = {}
ns.Accounting = Accounting

local GRACE = 10
-- The trade window's slots; a seventh holds what will not be traded.
local TRADE_SLOTS = 6
local MAIL_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16

-- What a window makes of gold no claim explains, while it is open and GRACE
-- after: the side to book, or "skip" when another booking covers it.
local WINDOWS = {
  -- Sales are booked from the buyback list (Trades.Merchant), and purchases
  -- and buybacks leave claims, so a loss left over is a repair.
  merchant = { gain = "skip", loss = "repair" },
  loot = { gain = "loot" },
  -- Booked from the trade window once the trade completes.
  trade = { gain = "skip", loss = "skip" },
  -- The client settling the gold it had at login.
  login = { gain = "skip", loss = "skip" },
}

-- Claims waiting for gold: { side, sign, amount, item, party, stacks, id, at }.
local claims = {}
-- Windows open now or lately: { name, from, to }.
local spans = {}
-- Changes of gold not explained yet: { at, left }.
local changes = {}
local money
-- The trade window as last read: { party, given, received, paid, got }.
local trade
-- The title of the quest whose reward is shown.
local completing

-- What `api` answers, or nothing on a client without it.
local function ask(api, ...)
  if api then
    return api(...)
  end
end

local function keyOf(link)
  return link and Database.KeyFromLink(ns.db, ns.RealmKey(), link)
end

-- Stacks of the same item as one, in the order first seen.
local function merged(stacks)
  local list, byItem = {}, {}
  for _, stack in ipairs(stacks) do
    local id = stack.item .. "|" .. tostring(stack.key)
    if byItem[id] then
      byItem[id].count = byItem[id].count + stack.count
    else
      byItem[id] = { item = stack.item, key = stack.key, count = stack.count }
      list[#list + 1] = byItem[id]
    end
  end
  return list
end

-- `copper` shared over `stacks` by their market value, or by their units
-- when one of them has none, rounded so that the shares add up.
local function split(copper, stacks)
  local weights, total, byUnits = {}, 0, false
  for index, stack in ipairs(stacks) do
    local record = stack.key and Database.Lookup(ns.db, ns.RealmKey(), stack.key)
    weights[index] = record and record.mv > 0 and record.mv * stack.count or 0
    byUnits = byUnits or weights[index] == 0
  end
  for index, stack in ipairs(stacks) do
    weights[index] = byUnits and stack.count or weights[index]
    total = total + weights[index]
  end
  local shares, sum, before = {}, 0, 0
  for index, weight in ipairs(weights) do
    sum = sum + weight
    local upTo = math.floor(copper * sum / total + 0.5)
    shares[index], before = upTo - before, upTo
  end
  return shares
end

-- The entries `copper` moved for `claim` makes: one per stack of goods, or
-- one of gold alone.
local function entries(side, copper, claim, now)
  if not claim.stacks then
    local item = claim.item ~= "" and claim.item or nil
    return { { at = now, side = side, item = item or Trades.SIDE[side].text, price = copper, party = claim.party } }
  end
  local list = {}
  for index, share in ipairs(split(copper, claim.stacks)) do
    local stack = claim.stacks[index]
    list[index] = { at = now, side = side, item = stack.item, key = stack.key, count = stack.count, price = share, party = claim.party }
  end
  return list
end

local function book(side, copper, claim)
  if side == "skip" then
    return
  end
  local now = time()
  if Trades.SIDE[side].accrues then
    Trades.Accrue(ns.db, ns.CharacterKey(), side, copper, now)
  else
    Trades.Add(ns.db, ns.CharacterKey(), entries(side, copper, claim, now), now)
  end
  ns.UI.RefreshSoon()
end

-- Books what the claims made around `change` explain of it: first those
-- with an amount that fits in what is left, then one that takes any. A claim
-- takes no part of a change smaller than its amount, which is some other
-- gold. Once GRACE has passed, the window open when the gold moved explains
-- the rest, or else it is other.
local function explain(change, final)
  local sign = change.left > 0 and 1 or -1
  for _, sized in ipairs({ true, false }) do
    local index = 1
    while change.left ~= 0 and claims[index] do
      local claim = claims[index]
      if claim.sign == sign and (claim.amount ~= nil) == sized and (claim.amount or 0) <= math.abs(change.left)
        and math.abs(claim.at - change.at) <= GRACE then
        local copper = claim.amount or math.abs(change.left)
        table.remove(claims, index)
        book(claim.side, copper, claim)
        change.left = change.left - sign * copper
      else
        index = index + 1
      end
    end
  end
  if change.left == 0 or not final then
    return
  end
  local side = sign > 0 and "otherIn" or "otherOut"
  for _, span in ipairs(spans) do
    local made = WINDOWS[span.name][sign > 0 and "gain" or "loss"]
    if made and change.at >= span.from and change.at <= (span.to or math.huge) + GRACE then
      side = made
      break
    end
  end
  book(side, math.abs(change.left), {})
  change.left = 0
end

local function settle()
  local now = GetTime()
  local waiting = {}
  for _, change in ipairs(changes) do
    explain(change, now - change.at >= GRACE)
    if change.left ~= 0 then
      waiting[#waiting + 1] = change
    end
  end
  changes = waiting
  for index = #claims, 1, -1 do
    if now - claims[index].at > GRACE then
      table.remove(claims, index)
    end
  end
  for index = #spans, 1, -1 do
    if spans[index].to and now - spans[index].to > 2 * GRACE then
      table.remove(spans, index)
    end
  end
end

-- A claim the same as one still waiting is the same action seen twice, as
-- when a mail is opened twice before the server answers.
local function claim(new)
  for _, waiting in ipairs(claims) do
    if new.id and waiting.id == new.id then
      return
    end
  end
  new.at = GetTime()
  claims[#claims + 1] = new
  settle()
end

local function open(name)
  spans[#spans + 1] = { name = name, from = GetTime() }
end

local function close(name)
  for _, span in ipairs(spans) do
    if span.name == name and not span.to then
      span.to = GetTime()
    end
  end
end

local function moneyChanged()
  local now = GetMoney()
  local copper = now - (money or now)
  money = now
  if copper ~= 0 then
    changes[#changes + 1] = { at = GetTime(), left = copper }
    settle()
    C_Timer.After(GRACE, settle)
  end
end

-- The copper a loot message names, read with the client's own words for the
-- coins, or nil when it names none.
local function lootedCopper(text)
  local copper
  for _, coin in ipairs({ { GOLD_AMOUNT, 10000 }, { SILVER_AMOUNT, 100 }, { COPPER_AMOUNT, 1 } }) do
    if coin[1] and text then
      local pattern = coin[1]:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%d", "(%%d+)")
      local amount = text:match(pattern)
      if amount then
        copper = (copper or 0) + tonumber(amount) * coin[2]
      end
    end
  end
  return copper
end

local function questTitle(questID)
  return ask(C_QuestLog and C_QuestLog.GetTitleForQuestID, questID) or completing
end

local function tradeStacks(info, link)
  local stacks = {}
  for slot = 1, TRADE_SLOTS do
    local item, _, count = ask(info, slot)
    if item and item ~= "" then
      stacks[#stacks + 1] = { item = item, key = keyOf(ask(link, slot)), count = math.max(count or 1, 1) }
    end
  end
  return merged(stacks)
end

-- Read on every change, because the window is empty by the time the trade
-- is complete.
local function readTrade()
  trade = {
    party = UnitName("NPC") or (trade and trade.party),
    given = tradeStacks(GetTradePlayerItemInfo, GetTradePlayerItemLink),
    received = tradeStacks(GetTradeTargetItemInfo, GetTradeTargetItemLink),
    paid = ask(GetPlayerTradeMoney) or 0,
    got = ask(GetTargetTradeMoney) or 0,
  }
end

-- Items given are sales and items received purchases, each side's gold
-- shared over the other side's items; gold for no items is gold alone.
local function bookTrade()
  local done = trade
  trade = nil
  if not done then
    return
  end
  local now, list = time(), {}
  local function add(stacks, copper, goods, gold)
    if #stacks > 0 or copper > 0 then
      local side = #stacks > 0 and goods or gold
      for _, entry in ipairs(entries(side, copper, { stacks = #stacks > 0 and stacks or nil, party = done.party }, now)) do
        list[#list + 1] = entry
      end
    end
  end
  add(done.given, done.got, "tradeSell", "tradeIn")
  add(done.received, done.paid, "tradeBuy", "tradeOut")
  if #list > 0 then
    Trades.Add(ns.db, ns.CharacterKey(), list, now)
    ns.Print("Booked the trade" .. (done.party and (" with " .. done.party) or "") .. ". Type /gb accounting.")
    ns.UI.RefreshSoon()
  end
end

local function mailMoney(index)
  local _, _, sender, subject, copper, _, daysLeft, _, _, _, _, canReply = ask(GetInboxHeaderInfo, index)
  if not copper or copper <= 0 then
    return
  end
  local id = table.concat({ "money", tostring(sender), tostring(subject), copper, tostring(daysLeft) }, "|")
  local invoice, _, _, bid, _, _, cut = ask(GetInboxInvoiceInfo, index)
  if invoice == "seller" then
    -- The sale is booked from its invoice at the price less the cut; the
    -- deposit the mail also returns is left over, as other income.
    claim({ side = "skip", sign = 1, amount = (bid or copper) - (cut or 0), id = id })
  elseif invoice or canReply == false then
    -- The auction house returning a bid, which was not booked either.
    claim({ side = "skip", sign = 1, amount = copper, id = id })
  else
    claim({ side = "mailIn", sign = 1, amount = copper, item = subject, party = sender, id = id })
  end
end

local function mailCOD(index)
  local _, _, sender, subject, _, cod, daysLeft = ask(GetInboxHeaderInfo, index)
  if not cod or cod <= 0 then
    return
  end
  local stacks = {}
  for attachment = 1, MAIL_ATTACHMENTS do
    local item, _, _, count = ask(GetInboxItem, index, attachment)
    if item then
      stacks[#stacks + 1] = { item = item, key = keyOf(ask(GetInboxItemLink, index, attachment)), count = math.max(count or 1, 1) }
    end
  end
  if #stacks > 0 then
    local id = table.concat({ "cod", tostring(sender), tostring(subject), cod, tostring(daysLeft) }, "|")
    claim({ side = "cod", sign = -1, amount = cod, party = sender, stacks = merged(stacks), id = id })
  end
end

local function positive(copper)
  return copper and copper > 0 and copper or nil
end

-- What happens after each of these calls, which the client answers later.
-- A missing one is left alone, so a client without it books that gold as
-- other.
local HOOKS = {
  BuyMerchantItem = function(index, quantity)
    local item = ns.MerchantItem(index)
    if item and item.price > 0 then
      local stack = item.stack
      quantity = quantity or stack
      -- The price is for `stack` items; a part of one costs what the server rounds it to.
      claim({ side = "merchant", sign = -1, amount = quantity % stack == 0 and item.price * quantity / stack or nil,
        stacks = { { item = item.name, key = keyOf(item.link), count = quantity } } })
    end
  end,
  BuybackItem = function(index)
    local _, _, price = ask(GetBuybackItemInfo, index)
    if positive(price) then
      claim({ side = "skip", sign = -1, amount = price })
    end
  end,
  TakeTaxiNode = function(index)
    local cost = positive(ask(TaxiNodeCost, index))
    if cost then
      claim({ side = "travel", sign = -1, amount = cost, item = ask(TaxiNodeName, index) })
    end
  end,
  BuyTrainerService = function(index)
    local name, rank = ask(GetTrainerServiceInfo, index)
    local cost = positive(ask(GetTrainerServiceCost, index))
    if cost and name then
      claim({ side = "training", sign = -1, amount = cost, item = name .. (rank and rank ~= "" and (" (" .. rank .. ")") or "") })
    end
  end,
  ConfirmTalentWipe = function()
    claim({ side = "respec", sign = -1 })
  end,
  SendMail = function(recipient)
    local postage, attached = positive(ask(GetSendMailPrice)), positive(ask(GetSendMailMoney))
    if postage then
      claim({ side = "postage", sign = -1, amount = postage })
    end
    if attached then
      claim({ side = "mailOut", sign = -1, amount = attached, party = recipient })
    end
  end,
  TakeInboxMoney = mailMoney,
  TakeInboxItem = mailCOD,
  AutoLootMailItem = function(index)
    mailMoney(index)
    mailCOD(index)
  end,
}

-- The name of the item at an item location, while it is still there.
local function nameAt(location)
  return ask(C_Item.DoesItemExist, location) and ask(C_Item.GetItemName, location) or nil
end

local AUCTION_HOOKS = {
  PostItem = function(item)
    claim({ side = "deposit", sign = -1, item = nameAt(item) })
  end,
  PostCommodity = function(item)
    claim({ side = "deposit", sign = -1, item = nameAt(item) })
  end,
  -- What a bid or buyout costs is booked from the buyer's invoice.
  PlaceBid = function(_, bid)
    claim({ side = "skip", sign = -1, amount = positive(bid) })
  end,
  ConfirmCommoditiesPurchase = function()
    claim({ side = "skip", sign = -1 })
  end,
}

local EVENTS = {
  PLAYER_MONEY = moneyChanged,
  MERCHANT_SHOW = function()
    open("merchant")
  end,
  MERCHANT_CLOSED = function()
    close("merchant")
  end,
  LOOT_OPENED = function()
    open("loot")
  end,
  LOOT_CLOSED = function()
    close("loot")
  end,
  CHAT_MSG_MONEY = function(text)
    claim({ side = "loot", sign = 1, amount = lootedCopper(text) })
  end,
  QUEST_COMPLETE = function()
    completing = ask(GetTitleText)
  end,
  QUEST_TURNED_IN = function(questID, _, copper)
    if positive(copper) then
      claim({ side = "quest", sign = 1, amount = copper, item = questTitle(questID) })
    end
  end,
  TRADE_SHOW = function()
    trade = nil
    open("trade")
    readTrade()
  end,
  TRADE_PLAYER_ITEM_CHANGED = readTrade,
  TRADE_TARGET_ITEM_CHANGED = readTrade,
  TRADE_MONEY_CHANGED = readTrade,
  TRADE_ACCEPT_UPDATE = readTrade,
  TRADE_CLOSED = function()
    close("trade")
  end,
  -- The server's word that the trade went through, which neither the
  -- window closing nor the gold says: a trade of items alone moves no gold,
  -- and the window closes as well when the trade is cancelled.
  UI_INFO_MESSAGE = function(first, second)
    if ERR_TRADE_COMPLETE and (second == ERR_TRADE_COMPLETE or first == ERR_TRADE_COMPLETE) then
      bookTrade()
    end
  end,
}

for name, after in pairs(HOOKS) do
  if type(_G[name]) == "function" then
    hooksecurefunc(name, after)
  end
end
for name, after in pairs(AUCTION_HOOKS) do
  if C_AuctionHouse and type(C_AuctionHouse[name]) == "function" then
    hooksecurefunc(C_AuctionHouse, name, after)
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    money = GetMoney()
    open("login")
    close("login")
    Trades.Close(ns.db, time())
    for name in pairs(EVENTS) do
      -- A newer client refuses to register an event it does not have.
      if ask(C_EventUtils and C_EventUtils.IsEventValid, name) ~= false then
        frame:RegisterEvent(name)
      end
    end
  else
    EVENTS[event](...)
  end
end)
