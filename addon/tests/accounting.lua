-- Moves gold in a simulated client the way the game's actions do and checks
-- what the accounting books for each, and lists the entries in the
-- Accounting view.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.money = 1000000
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
local Codec = ns.Codec
local GRACE = 10
local HOUR = 3600

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

local function link(itemID, name)
  return "|Hitem:" .. itemID .. "::::::|h[" .. name .. "]|h"
end

-- Market values per unit, as a full scan leaves them.
local function value(key, name, mv)
  ns.db.items[key] = "1|" .. name
  ns.db.prices["Faramon-Horde"] = ns.db.prices["Faramon-Horde"] or {}
  ns.db.prices["Faramon-Horde"][key] = Codec.EncodePrice({ min = mv, qty = 10, n = 1, seen = time(), mv = mv, mvAt = time(), days = { mv }, ladder = {} })
end
value("12360", "Arcanite Bar", 100000)
value("12359", "Thorium Bar", 4000)
value("10620", "Thorium Ore", 2500)

local function gain(copper)
  Stub.money = Stub.money + copper
  Stub.fire("PLAYER_MONEY")
end
local function pay(copper)
  gain(-copper)
end

-- The entries booked since the last call, oldest first, as "side item key
-- count price party".
local seen = {}
local function booked()
  local texts = {}
  for _, entry in ipairs(ns.db.trades["Sultan-Faramon"] or {}) do
    if not seen[entry] then
      seen[entry] = true
      texts[#texts + 1] = table.concat({ entry.side, entry.item, tostring(entry.key), entry.count, entry.price, tostring(entry.party) }, " ")
    end
  end
  return table.concat(texts, " / ")
end
-- The gold being added up this hour, as "side count price".
local function accruing()
  local texts = {}
  for side, entry in pairs(ns.db.accruing["Sultan-Faramon"] or {}) do
    texts[#texts + 1] = table.concat({ side, entry.count, entry.price }, " ")
  end
  table.sort(texts)
  return table.concat(texts, " / ")
end

-- A whole hour ahead, so that every test below runs within one hour.
Stub.advance(HOUR - time() % HOUR + 1)
local hour = time() - time() % HOUR

Stub.fire("PLAYER_LOGIN")
Stub.advance(1)
gain(500)
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|", "the gold the client settles on just after login is not booked")
Stub.advance(GRACE * 2)

local flour, water = link(2678, "Simple Flour"), link(159, "Refreshing Spring Water")
Stub.merchant = { { "Simple Flour", 25, 5, flour }, { "Refreshing Spring Water", 25, 1, water } }
Stub.buyback = { { "Broken Fang", 1, 85 } }
Stub.fire("MERCHANT_SHOW")
BuyMerchantItem(1)
BuyMerchantItem(2, 4)
pay(125)
eq(booked(), "merchant Simple Flour 2678 5 25 nil / merchant Refreshing Spring Water 159 4 100 nil",
  "two purchases paid with one change of gold are each booked at their price")
BuyMerchantItem(1, 10)
Stub.fire("MERCHANT_CLOSED")
Stub.advance(1)
pay(50)
eq(booked(), "merchant Simple Flour 2678 10 50 nil", "a purchase is booked when the gold comes after the merchant closed")
Stub.fire("MERCHANT_SHOW")
BuyMerchantItem(1, 7)
pay(36)
eq(booked(), "merchant Simple Flour 2678 7 36 nil", "part of a stack costs what the server asks")
local merchantItemInfo = GetMerchantItemInfo
GetMerchantItemInfo = nil
C_MerchantFrame = {
  GetItemInfo = function(index)
    local entry = Stub.merchant[index]
    return { name = entry[1], price = entry[2], stackCount = entry[3], numAvailable = -1, hasExtendedCost = false }
  end,
}
BuyMerchantItem(2, 3)
pay(75)
eq(booked(), "merchant Refreshing Spring Water 159 3 75 nil", "a client with only C_MerchantFrame.GetItemInfo books the purchase too")
GetMerchantItemInfo, C_MerchantFrame = merchantItemInfo, nil

pay(4320)
eq(booked(), "", "gold spent at a merchant without a purchase waits for what explains it")
Stub.advance(GRACE)
eq(booked(), "repair Repairs nil 1 4320 nil", "and is a repair once nothing did")
gain(3100)
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|", "gold a merchant pays is left to the buyback list, which books the sale")
BuybackItem(1)
pay(85)
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|", "buying a sale back is not a repair, and its sale is taken off instead")
Stub.fire("MERCHANT_CLOSED")
Stub.advance(GRACE * 3)
pay(20)
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|otherOut 1 20", "a merchant closed for longer than the wait explains nothing")

Stub.taxi = { { "Orgrimmar, Durotar", 1010 } }
TakeTaxiNode(1)
pay(1010)
eq(booked(), "travel Orgrimmar, Durotar nil 1 1010 nil", "a flight is booked to its destination")
Stub.trainer = { { "Fireball", "Rank 3", 1800 }, { "First Aid", "", 100 } }
BuyTrainerService(1)
BuyTrainerService(2)
pay(1900)
eq(booked(), "training Fireball (Rank 3) nil 1 1800 nil / training First Aid nil 1 100 nil", "training is booked per spell, with its rank")
ConfirmTalentWipe()
pay(10000)
eq(booked(), "respec Talent reset nil 1 10000 nil", "a talent reset costs what the gold says")

gain(2500)
Stub.advance(0.5)
Stub.quests[1234] = "The Defias Brotherhood"
Stub.fire("QUEST_TURNED_IN", 1234, 1000, 2500)
eq(booked(), "quest The Defias Brotherhood nil 1 2500 nil", "a quest reward is booked when the event comes after the gold")
Stub.questTitle = "Wanted: Gath'Ilzogg"
Stub.fire("QUEST_COMPLETE")
Stub.fire("QUEST_TURNED_IN", 999, 0, 500)
gain(500)
eq(booked(), "quest Wanted: Gath'Ilzogg nil 1 500 nil", "a quest the log does not name takes the title the quest frame showed")

Stub.fire("LOOT_OPENED")
gain(37)
Stub.fire("LOOT_CLOSED")
eq(accruing(), "otherOut 1 20", "looted gold waits for a loot message that may still come")
Stub.advance(GRACE + 1)
eq(booked() .. "|" .. accruing(), "|loot 1 37 / otherOut 1 20", "gold gained with the loot window open is looted, added up for the hour")
Stub.fire("CHAT_MSG_MONEY", "Your share of the loot is 1 Silver, 5 Copper.")
gain(105)
gain(77)
eq(accruing(), "loot 2 142 / otherOut 1 20", "a loot message claims the share it names")
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|loot 2 142 / otherIn 1 77 / otherOut 1 20", "gold nothing explains is other income")

Stub.sending = { 30, 50000 }
SendMail("Mirelle", "Gold", "")
pay(50030)
eq(booked(), "postage Postage nil 1 30 nil / mailOut Gold nil 1 50000 Mirelle", "sending gold books its postage and the gold sent to whom")
Stub.sending = { 30, 0 }
SendMail("Mirelle", "Ore", "")
pay(30)
eq(booked(), "postage Postage nil 1 30 nil", "a mail without gold costs its postage")

local arcanite = link(12360, "Arcanite Bar")
-- The mails refuse every take, so that the gold moves only as each check says.
Stub.inbox.mails = {
  { sender = "Mirelle", subject = "For the ore", money = 20000, daysLeft = 29.5, refuses = true },
  { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1960, daysLeft = 29, refuses = true, canReply = false,
    invoice = { "seller", "Linen Cloth", "Alice", 2000, 2000, 60, 100 } },
  { sender = "Auction House", subject = "Outbid on Wool Cloth", money = 500, daysLeft = 28, refuses = true, canReply = false },
  { sender = "Kargath", subject = "Bars", cod = 240000, daysLeft = 27, refuses = true,
    items = { { 12360, "Arcanite Bar", 2 }, { 12359, "Thorium Bar", 10 } } },
  { sender = "Kargath", subject = "Plain", cod = 900, daysLeft = 26, refuses = true, items = { { 90001, "Mystery Box", 3 } } },
}
TakeInboxMoney(1)
TakeInboxMoney(1)
gain(20000)
eq(booked(), "mailIn For the ore nil 1 20000 Mirelle", "gold taken from a player's mail is booked once, with its subject and sender")
TakeInboxMoney(2)
gain(1960)
TakeInboxMoney(3)
gain(500)
eq(booked() .. "|" .. accruing(), "|loot 2 142 / otherIn 1 77 / otherOut 1 20",
  "gold from the auction house waits: its sale is booked from the invoice, and a returned bid was never booked")
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|loot 2 142 / otherIn 2 137 / otherOut 1 20", "the deposit a sale returns is other income")
TakeInboxItem(4, 2)
pay(240000)
eq(booked(), "cod Arcanite Bar 12360 2 200000 Kargath / cod Thorium Bar 12359 10 40000 Kargath",
  "cash on delivery is shared over the items by their market value")
AutoLootMailItem(5)
pay(900)
eq(booked(), "cod Mystery Box 90001 3 900 Kargath", "taking all of a mail pays its cash on delivery too")

Stub.bags[0] = { slots = 16, { hyperlink = link(14047, "Runecloth"), stackCount = 20 } }
C_AuctionHouse.PostItem({ bagID = 0, slotIndex = 1 }, 2, 1, 0, 50000)
pay(150)
eq(booked(), "deposit Runecloth nil 1 150 nil", "posting an auction books its deposit under the item posted")
C_AuctionHouse.PlaceBid(77, 23000)
pay(23000)
C_AuctionHouse.ConfirmCommoditiesPurchase(14047, 20)
pay(48000)
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|loot 2 142 / otherIn 2 137 / otherOut 1 20", "bids and buyouts are left to the buyer's invoice")

local function trade(party, given, paid, received, got)
  Stub.trade = { party = party, player = { items = given, money = paid }, target = { items = received, money = got } }
end
local ore = link(10620, "Thorium Ore")
Stub.trade.party = "Mirelle"
Stub.fire("TRADE_SHOW")
trade("Mirelle", { { "Thorium Ore", 20, ore }, { "Arcanite Bar", 1, arcanite } }, 0, {}, 0)
Stub.fire("TRADE_PLAYER_ITEM_CHANGED", 1)
trade("Mirelle", { { "Thorium Ore", 20, ore }, { "Arcanite Bar", 1, arcanite } }, 0, {}, 150000)
Stub.fire("TRADE_MONEY_CHANGED")
Stub.fire("TRADE_ACCEPT_UPDATE", 1, 1)
trade(nil, {}, 0, {}, 0)
Stub.fire("TRADE_CLOSED")
local printed = #Stub.printed
Stub.fire("UI_INFO_MESSAGE", 222, "Trade complete.")
gain(150000)
eq(booked(), "tradeSell Thorium Ore 10620 20 50000 Mirelle / tradeSell Arcanite Bar 12360 1 100000 Mirelle",
  "items given in a trade are sold for the gold received, shared by their market value")
eq(plain(Stub.printed[#Stub.printed]) .. " " .. (#Stub.printed - printed), "Goldbook Booked the trade with Mirelle. Type /gb accounting. 1",
  "a booked trade is announced once")
Stub.advance(GRACE)
eq(booked() .. "|" .. accruing(), "|loot 2 142 / otherIn 2 137 / otherOut 1 20", "the trade's gold is not booked again")

trade("Kargath", {}, 1000, { { "Mystery Box", 3 }, { "Odd Stone", 1 } }, 0)
Stub.fire("TRADE_SHOW")
Stub.fire("TRADE_ACCEPT_UPDATE", 1, 1)
Stub.fire("TRADE_CLOSED")
Stub.fire("UI_INFO_MESSAGE", 222, "Trade complete.")
pay(1000)
eq(booked(), "tradeBuy Mystery Box nil 3 750 Kargath / tradeBuy Odd Stone nil 1 250 Kargath",
  "items without a market value share the gold paid by their units")

trade("Kargath", { { "Arcanite Bar", 1, arcanite } }, 50000, {}, 20000)
Stub.fire("TRADE_SHOW")
Stub.fire("TRADE_ACCEPT_UPDATE", 1, 1)
Stub.fire("UI_INFO_MESSAGE", 222, "Trade complete.")
Stub.fire("TRADE_CLOSED")
pay(30000)
eq(booked(), "tradeSell Arcanite Bar 12360 1 20000 Kargath / tradeOut Gold nil 1 50000 Kargath",
  "gold given for no items is gold out, whichever comes first of the message and the window closing")

trade("Kargath", { { "Thorium Ore", 5, ore } }, 0, {}, 0)
Stub.fire("TRADE_SHOW")
Stub.fire("TRADE_CLOSED")
trade("Mirelle", {}, 0, {}, 7000)
Stub.fire("TRADE_SHOW")
Stub.fire("TRADE_MONEY_CHANGED")
Stub.fire("TRADE_CLOSED")
Stub.fire("UI_INFO_MESSAGE", 222, "Trade complete.")
gain(7000)
eq(booked(), "tradeIn Gold nil 1 7000 Mirelle", "a cancelled trade is not booked, and gold for nothing is gold in")
trade("Mirelle", { { "Thorium Ore", 5, ore } }, 0, {}, 0)
Stub.fire("TRADE_SHOW")
Stub.fire("TRADE_CLOSED")
Stub.fire("UI_INFO_MESSAGE", 222, "Trade complete.")
eq(booked(), "tradeSell Thorium Ore 10620 5 0 Mirelle", "items given for nothing are sold for nothing")

Stub.advance(HOUR)
gain(12)
Stub.advance(GRACE)
eq(booked(), "loot Looted gold nil 2 142 nil / otherIn Other nil 2 137 nil / otherOut Other nil 1 20 nil",
  "once the hour has ended, the gold added up in it is booked")
local accrued = {}
for _, entry in ipairs(ns.db.trades["Sultan-Faramon"]) do
  if entry.side == "loot" then
    accrued[#accrued + 1] = entry.at - hour
  end
end
eq(table.concat(accrued, " ") .. " " .. accruing(), "0 otherIn 1 12", "dated the start of its hour, while the new hour adds up anew")

SlashCmdList.GOLDBOOK("accounting thorium ore")
local function cells(index)
  local texts = {}
  for _, cell in ipairs(GoldbookWindow.rows[index].cells) do
    if cell.shown then
      texts[#texts + 1] = plain(cell.text)
    end
  end
  return table.concat(texts, " | ")
end
eq(cells(1) .. " / " .. cells(2), "Thorium Ore x5 · to Mirelle | Trade sale | 0c | Sultan | 1h ago / Thorium Ore x20 · to Mirelle | Trade sale | +5g 00s 00c | Sultan | 1h ago",
  "a trade names who it was with")
SlashCmdList.GOLDBOOK("accounting trade gold out")
eq(cells(1), "Gold · to Kargath | Trade gold out | -5g 00s 00c | Sultan | 1h ago", "gold alone is named by what it was, and found by its source")
eq(GoldbookWindow.rows[1].icon.texture, "Interface\\Icons\\INV_Misc_Coin_01", "and shows a coin")
SlashCmdList.GOLDBOOK("accounting other income")
eq(cells(1), "Other | Other income | +12c | Sultan | 2m ago", "the hour still adding up is listed too, from its start")
SlashCmdList.GOLDBOOK("accounting arcanite")
local function cards()
  local texts = {}
  for index, card in ipairs(GoldbookWindow.cards.cards) do
    texts[index] = plain(card.key.text .. " " .. card.value.text)
  end
  return table.concat(texts, " / ")
end
eq(cards(), "REVENUE 12g 00s 00c / EXPENSES 20g 00s 00c / NET -8g 00s 00c / REALIZED PROFIT -8g 00s 00c",
  "two bars bought on delivery at 10g each and sold in trades for 10g and 2g lose 8g")
GoldbookWindow.search:SetText("")
local chip = GoldbookWindow.filters.controls.source
chip.scripts.OnClick(chip)
local options = {}
for index, option in ipairs(chip.menu.options) do
  if option.shown then
    options[index] = option.label.text
  end
end
eq(table.concat(options, ", "), "All sources, Merchant purchase, Trade sale, Trade purchase, Trade gold in, Trade gold out, Mail gold in, "
  .. "Mail gold out, Cash on delivery, Quest reward, Looted gold, Repairs, Postage, Auction deposit, Flight, Training, Talent reset, Other income, Other expense",
  "the source chip offers every source booked")
local eleventh = chip.menu.options[11]
eq(table.concat({ chip.menu.width, chip.menu.height, eleventh.point[2], eleventh.point[3] }, " "), "400 228 201 -4",
  "twenty choices run in two columns of ten")

io.write(("%d accounting checks, %d failed.\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
