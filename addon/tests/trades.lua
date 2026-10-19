-- Books auction house invoices from a simulated mailbox and lists them in the
-- Accounting view. With a path as its argument it writes the SavedVariables file
-- that scripts/verify-trades.py uploads.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
local Trades = ns.Trades
local DAY = 24 * 3600

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

-- The mailbox: { daysLeft, invoice = { type, item, buyer or seller, bid, buyout, deposit, cut, count }, link }.
-- daysLeft counts down with the clock, as the client's does.
local inbox = {}
local function mail(daysLeft, invoice, link)
  return { expires = time() + daysLeft * DAY, invoice = invoice, link = link }
end
function GetInboxNumItems()
  return #inbox
end
function GetInboxHeaderInfo(index)
  local entry = inbox[index]
  return nil, nil, entry.invoice and "Auction House" or "Mirelle", "Subject", 0, 0, (entry.expires - time()) / DAY
end
function GetInboxInvoiceInfo(index)
  local invoice = inbox[index].invoice
  if not invoice then
    return nil
  end
  return invoice[1], invoice[2], invoice[3], invoice[4], invoice[5], invoice[6], invoice[7], 0, 0, 0, invoice[8]
end
function GetInboxItemLink(index)
  return inbox[index].link
end

local function booked(character)
  local texts = {}
  for index, trade in ipairs(ns.db.trades[character or "Sultan-Faramon"] or {}) do
    texts[index] = table.concat({ trade.side, trade.item, tostring(trade.key), trade.count, trade.price, trade.fee, trade.at - time() }, " ")
  end
  return table.concat(texts, " / ")
end

ns.db.items["2589"] = "1|Linen Cloth"
ns.db.items["9775"] = "2|Bandit Cinch of the Monkey"
ns.db.items["9775:584"] = "2|Bandit Cinch of the Monkey"
ns.db.items["2592"] = "1|Wool Cloth"
local cinch = "|Hitem:9775:0:0:0:0:0:584:1111:60|h[Bandit Cinch of the Monkey]|h"

inbox = {
  mail(29.5, { "seller", "Linen Cloth", "Alice", 2000, 2000, 60, 100, 20 }),
  mail(30, { "buyer", "Bandit Cinch of the Monkey", "Bob", 9000, 9000, 0, 0, 1 }, cinch),
  mail(29.9, { "seller_temp_invoice", "Wool Cloth", "Carol", 500, 500, 10, 25, 5 }),
  mail(25),
  mail(28, { "seller", "Gnomish Widget", "Dave", 700, 700, 0, 35, nil }),
}
local printed = #Stub.printed
Stub.fire("MAIL_INBOX_UPDATE")
eq(booked(), "sell Gnomish Widget nil 1 700 35 -172800 / sell Linen Cloth 2589 20 2000 100 -43200 / buy Bandit Cinch of the Monkey 9775:584 1 9000 0 0",
  "sales and purchases are booked oldest first, dated by the days their mail has left, keyed by name or by the mailed item's link")
eq(plain(Stub.printed[#Stub.printed]), "Goldbook Booked 2 sales and 1 purchase from the mailbox. Type /gb accounting.", "new trades are announced")
eq(#Stub.printed, printed + 1, "a pending sale and a letter are not booked")

Stub.advance(600)
printed = #Stub.printed
Stub.fire("MAIL_INBOX_UPDATE")
eq(#ns.db.trades["Sultan-Faramon"] .. " " .. #Stub.printed, "3 " .. printed, "the same mail read again later is not booked twice, and nothing is said")

table.remove(inbox, 1)
inbox[#inbox + 1] = mail(30, { "seller", "Linen Cloth", "Erin", 2000, 2000, 60, 100, 20 })
inbox[#inbox + 1] = mail(30, { "seller", "Linen Cloth", "Frank", 2000, 2000, 60, 100, 20 })
Stub.fire("MAIL_INBOX_UPDATE")
eq(#ns.db.trades["Sultan-Faramon"] .. " " .. plain(Stub.printed[#Stub.printed]), "5 Goldbook Booked 2 sales from the mailbox. Type /gb accounting.",
  "two equal sales in one mailbox are two trades, and a mail taken out does not unbook its trade")
Stub.fire("MAIL_INBOX_UPDATE")
eq(#ns.db.trades["Sultan-Faramon"], 5, "equal sales read again stay two trades")

Stub.name = "Mirelle"
Stub.fire("PLAYER_LOGIN")
inbox = { mail(29, { "buyer", "Linen Cloth", "Alice", 1500, 1500, 0, 0, 20 }) }
Stub.fire("MAIL_INBOX_UPDATE")
eq(booked("Mirelle-Faramon"), "buy Linen Cloth 2589 20 1500 0 -86400", "each character books its own trades; a purchase without a link is keyed by name")

SlashCmdList.GOLDBOOK("accounting")
-- The text of the row's cells the view uses.
local function cells(index)
  local texts = {}
  for _, cell in ipairs(GoldbookWindow.rows[index].cells) do
    if cell.shown then
      texts[#texts + 1] = plain(cell.text)
    end
  end
  return table.concat(texts, " | ")
end
-- The cards above the list, as "KEY value".
local function cards()
  local texts = {}
  for index, card in ipairs(GoldbookWindow.cards.cards) do
    texts[index] = plain(card.key.text .. " " .. card.value.text)
  end
  return table.concat(texts, " / ")
end
local function segment(index)
  local button = GoldbookWindow.segments.buttons[index]
  button.scripts.OnClick(button)
end
eq(GoldbookWindow.version.text .. " " .. tostring(GoldbookWindow.version.point[2] ~= nil), Stub.metadata.Version .. " true",
  "the window shows the addon's version beside its title")
eq(GoldbookWindow.headers[1].text .. " " .. GoldbookWindow.headers[2].text .. " " .. GoldbookWindow.headers[3].text .. " "
  .. GoldbookWindow.headers[4].text .. " " .. GoldbookWindow.headers[5].text,
  "ENTRY SOURCE NET CHARACTER WHEN ↓", "the accounting view has its own columns, newest first")
eq(cells(1), "Linen Cloth x20 | Auction sale | +19s 00c | Sultan | just now", "the newest entry comes first; a sale nets its price less the cut")
eq(cells(3), "Bandit Cinch of the Monkey x1 | Auction purchase | -90s 00c | Sultan | 10m ago", "a purchase costs its price")
eq(cells(5), "Linen Cloth x20 | Auction purchase | -15s 00c | Mirelle | 1d ago", "every character's entries are listed")
eq(cells(6), "Gnomish Widget x1 | Auction sale | +6s 65c | Sultan | 2d ago", "a sale without a count is one item")
eq(GoldbookWindow.rows[3].cells[1].text:sub(1, 10), "|cff1eff00", "an item booked under a known key keeps its quality colour")
eq(GoldbookWindow.rows[3].cells[3].text:sub(1, 10), "|cffff8c7d", "a purchase is red, a sale green")
eq(GoldbookWindow.rows[1].hit.shown, false, "trades are not items to hover")
eq(plain(GoldbookWindow.head.sub.text) .. " / " .. cards(), "6 entries / REVENUE 63s 65c / EXPENSES 1g 05s 00c / NET -41s 35c / REALIZED PROFIT +4s 00c",
  "the cards total the entries shown, revenue after the cut, and the profit on the 20 Linen Cloth bought at 75c and sold at 95c")
eq(tostring(GoldbookWindow.filters.controls.profession.shown) .. " " .. tostring(GoldbookWindow.filters.controls.source.shown) .. " "
  .. tostring(GoldbookWindow.filters.controls.character.shown), "false true true", "the accounting view filters by source and character, not by item")

segment(2)
eq(cards() .. " / " .. cells(1):match("^[^|]+"), "REVENUE 63s 65c / EXPENSES 0c / NET +63s 65c / REALIZED PROFIT – / Linen Cloth x20 ",
  "Revenue lists what brought gold in")
segment(3)
eq(cells(1):match("^[^|]+") .. "/ " .. cells(4) .. " / " .. GoldbookWindow.head.sub.text, "Bandit Cinch of the Monkey x1 /  |  |  |  |  / 2 entries",
  "Expenses lists what cost gold")
segment(1)

local sources = GoldbookWindow.filters.controls.source
sources.scripts.OnClick(sources)
local offered = {}
for index, option in ipairs(sources.menu.options) do
  if option.shown then
    offered[index] = option.label.text
  end
end
eq(table.concat(offered, ", "), "All sources, Auction sale, Auction purchase", "the source chip offers the sources booked, in the order of the sides")
sources.menu.options[3].scripts.OnClick(sources.menu.options[3])
eq(sources.label.text .. " / " .. GoldbookWindow.head.sub.text, "Auction purchase / 2 entries", "choosing a source lists its entries")
GoldbookWindow.filters.clear.scripts.OnClick(GoldbookWindow.filters.clear)

local chip = GoldbookWindow.filters.controls.character
chip.scripts.OnClick(chip)
local options = {}
for index, option in ipairs(chip.menu.options) do
  if option.shown then
    options[index] = option.label.text
  end
end
eq(table.concat(options, ", "), "All characters, Mirelle, Sultan", "the character chip offers each character with trades")
chip.menu.options[2].scripts.OnClick(chip.menu.options[2])
eq(chip.label.text .. " / " .. cells(1) .. " / " .. GoldbookWindow.head.sub.text,
  "Mirelle / Linen Cloth x20 | Auction purchase | -15s 00c | Mirelle | 1d ago / 1 entry", "choosing a character lists that character's entries")
eq(GoldbookWindow.filters.clear.shown, true, "a chosen character can be cleared")
GoldbookWindow.filters.clear.scripts.OnClick(GoldbookWindow.filters.clear)
eq(chip.label.text .. " " .. GoldbookWindow.head.sub.text, "All characters 6 entries", "clearing the filters lists every character again")

GoldbookWindow.search:SetText("mirelle")
eq(cells(1) .. " / " .. cells(2), "Linen Cloth x20 | Auction purchase | -15s 00c | Mirelle | 1d ago /  |  |  |  | ", "the search matches the character")
eq(cards(), "REVENUE 0c / EXPENSES 15s 00c / NET -15s 00c / REALIZED PROFIT –", "and the cards follow it, without a profit where nothing was both bought and sold")
GoldbookWindow.search:SetText("widget")
eq(cells(1):match("^[^|]+"), "Gnomish Widget x1 ", "the search matches the item")
GoldbookWindow.search:SetText("")
GoldbookWindow.headerButtons[3].scripts.OnClick()
eq(cells(1):match("^[^|]+") .. "/ " .. cells(6):match("^[^|]+"), "Linen Cloth x20 / Bandit Cinch of the Monkey x1 ", "sorted by net the best trade leads")
GoldbookWindow.tabs.gold.scripts.OnClick()
GoldbookWindow.tabs.accounting.scripts.OnClick()
eq(tostring(GoldbookWindow.tabs.accounting.selected.shown) .. " " .. GoldbookWindow.tabs.accounting.label.text, "true Accounting", "the Accounting tab is drawn selected")
local hubs = GoldbookWindow.hubs
eq(table.concat({ hubs.market.point[3], hubs.inventory.point[3], hubs.ledger.point[3], hubs.ledger.label.text, tostring(hubs.ledger.selected.shown) }, " "),
  "-10 -46 -82 Ledger true", "the hubs run down the rail, Ledger last and picked")
eq(tostring(GoldbookWindow.tabs.accounting.label.point[2] == GoldbookWindow.tabs.gold) .. " " .. tostring(GoldbookWindow.tabs.mail.shown),
  "true false", "Accounting's tab follows Gold's, and the other hubs' tabs are hidden")

local window = { trades = {}, accruing = {} }
local old = {}
for index = 1, 3005 do
  old[index] = { side = "sell", item = "Linen Cloth", count = 1, price = index, fee = 0, at = 100 * DAY + index }
end
Trades.Book(window, "A", old, 100 * DAY + 4000)
eq(#window.trades.A .. " " .. window.trades.A[1].price, "3005 1", "past 3000 entries, those the mailbox may still show are kept")
Trades.Book(window, "A", {}, 140 * DAY)
eq(#window.trades.A .. " " .. window.trades.A[1].price, "3000 6", "a character keeps its newest 3000 entries older than a month")
Trades.Book(window, "A", {}, 280 * DAY + 1000)
eq(#window.trades.A .. " " .. window.trades.A[1].price, "2006 1000", "entries older than 180 days are dropped")
eq(table.concat({ Trades.Book(window, "A", { old[3005] }, 280 * DAY + 1000) }, " "), "0 0", "Book says nothing was new")

-- The merchant's buyback list: { item, count, price, link }, oldest first.
local buyback = {}
function GetNumBuybackItems()
  return #buyback
end
function GetBuybackItemInfo(index)
  local entry = buyback[index]
  return entry[1], nil, entry[3], entry[2]
end
function GetBuybackItemLink(index)
  return buyback[index][4]
end
-- The open merchant's goods: { itemID, price, count, available, costs },
-- `available` being -1 without limit and `costs` how many items or
-- currencies it asks besides gold.
local goods = {}
function GetMerchantNumItems()
  return #goods
end
function GetMerchantItemInfo(index)
  local entry = goods[index]
  return "Goods", nil, entry[2], entry[3], entry[4], true, true, entry[5] > 0
end
function GetMerchantItemID(index)
  return goods[index][1]
end
function GetMerchantItemCostInfo(index)
  return goods[index][5]
end
local star = "|Hitem:15301:0:0:0:0:0:1019:0:60|h[Jagged Star of the Eagle]|h"
local function vendored()
  local texts = {}
  for _, trade in ipairs(ns.db.trades["Mirelle-Faramon"]) do
    if trade.side == "vendor" then
      texts[#texts + 1] = table.concat({ trade.item, tostring(trade.key), trade.count, trade.price, trade.fee, trade.at - time() }, " ")
    end
  end
  return table.concat(texts, " / ")
end

inbox = { mail(30, { "buyer", "Jagged Star of the Eagle", "Gwen", 2300, 2300, 0, 0, 1 }, star) }
Stub.fire("MAIL_INBOX_UPDATE")
buyback = { { "Broken Fang", 1, 85 } }
Stub.fire("MERCHANT_SHOW")
eq(vendored(), "", "what the buyback list held when the merchant opened was sold before and is not booked again")
buyback[2] = { "Jagged Star of the Eagle", 1, 3100, star }
Stub.money = Stub.money + 3100
Stub.fire("MERCHANT_UPDATE")
Stub.fire("MERCHANT_UPDATE")
eq(vendored(), "Jagged Star of the Eagle 15301:1019 1 3100 0 0", "a new buyback entry is a vendor sale, booked once, keyed by its link")
buyback[3] = { "Broken Fang", 1, 85 }
buyback[4] = { "Broken Fang", 1, 85 }
Stub.fire("MERCHANT_UPDATE")
eq(select(2, vendored():gsub("Broken Fang", "")), 2, "two equal stacks sold are two sales")
table.remove(buyback, 4)
Stub.fire("MERCHANT_UPDATE")
eq(select(2, vendored():gsub("Broken Fang", "")), 1, "an item bought back takes its sale off again")
printed = #Stub.printed
Stub.fire("MERCHANT_CLOSED")
eq(plain(Stub.printed[#Stub.printed]), "Goldbook Booked 2 vendor sales. Type /gb accounting.", "closing the merchant says how many sales it booked")
eq(#Stub.printed, printed + 1, "and says it once")

buyback = {}
for index = 1, 12 do
  buyback[index] = { "Ruined Pelt", 1, 50 + index }
end
buyback[1] = { "Broken Fang", 1, 85 }
Stub.fire("MERCHANT_SHOW")
table.remove(buyback, 1)
buyback[12] = { "Broken Fang", 1, 85 }
Stub.money = Stub.money + 85
Stub.fire("MERCHANT_UPDATE")
eq(select(2, vendored():gsub("Broken Fang", "")), 2, "a full list that sold the same stack as its oldest entry books it from the gold gained")
table.remove(buyback, 1)
buyback[12] = { "Ruined Pelt", 1, 55 }
Stub.money = Stub.money + 55
Stub.fire("MERCHANT_UPDATE")
eq(select(2, vendored():gsub("Ruined Pelt", "")), 1, "with the list full, a sale unlike the oldest entry is seen as usual")
Stub.fire("MERCHANT_CLOSED")

goods = { { 3857, 500, 1, -1, 0 }, { 2512, 10, 200, -1, 0 }, { 6325, 400, 1, 2, 0 }, { 18839, 900, 1, -1, 1 } }
Stub.fire("MERCHANT_SHOW")
goods = { { 3857, 475, 1, -1, 0 } }
Stub.fire("MERCHANT_UPDATE")
goods = { { 3857, 500, 1, -1, 0 } }
Stub.fire("MERCHANT_SHOW")
Stub.fire("MERCHANT_CLOSED")
local stock = {}
for _, itemID in ipairs({ 3857, 2512, 6325, 18839 }) do
  stock[#stock + 1] = itemID .. "=" .. tostring(ns.db.merchant[itemID])
end
eq(table.concat(stock, " "), "3857=475 2512=1 6325=nil 18839=nil",
  "merchants' goods without limit and for gold alone are kept at their lowest price per unit")

-- Newer clients have only C_MerchantFrame.GetItemInfo, and no GetMerchantItemCostInfo.
local merchantItemInfo, merchantItemCostInfo = GetMerchantItemInfo, GetMerchantItemCostInfo
GetMerchantItemInfo, GetMerchantItemCostInfo = nil, nil
C_MerchantFrame = {
  GetItemInfo = function(index)
    local entry = goods[index]
    return { name = "Goods", price = entry[2], stackCount = entry[3], numAvailable = entry[4], hasExtendedCost = entry[5] > 0 }
  end,
}
ns.db.merchant[3857], ns.db.merchant[2512] = nil, nil
goods = { { 3857, 500, 1, -1, 0 }, { 2512, 10, 200, -1, 0 }, { 18839, 900, 1, -1, 1 } }
Stub.fire("MERCHANT_SHOW")
Stub.fire("MERCHANT_CLOSED")
eq(tostring(ns.db.merchant[3857]) .. " " .. tostring(ns.db.merchant[2512]) .. " " .. tostring(ns.db.merchant[18839]), "500 1 nil",
  "a client with only C_MerchantFrame.GetItemInfo still records the merchant's goods")
GetMerchantItemInfo, GetMerchantItemCostInfo, C_MerchantFrame = merchantItemInfo, merchantItemCostInfo, nil
goods = {}

SlashCmdList.GOLDBOOK("trades jagged")
eq(GoldbookWindow.tabs.accounting.selected.shown, true, "/gb trades still opens the Accounting view")
eq(cells(1), "Jagged Star of the Eagle x1 | Vendor sale | +31s 00c | Mirelle | just now", "a vendor sale nets what the vendor paid")
eq(cards(), "REVENUE 31s 00c / EXPENSES 23s 00c / NET +8s 00c / REALIZED PROFIT +8s 00c", "bought at 23s and sold to a vendor at 31s makes 8s")
local loss = { accruing = {}, trades = { A = {
  { at = 1, side = "buy", item = "Jagged Star of the Eagle", count = 1, price = 2300, fee = 0 },
  { at = 2, side = "vendor", item = "Jagged Star of the Eagle", count = 1, price = 1900, fee = 0 },
} }, items = {} }
eq(Trades.Totals(Trades.Rows(loss)).profit, -400, "sold to a vendor for less than it cost is a loss")
local mixed = { accruing = {}, items = {}, trades = {
  ["A-R"] = {
    { at = 10, side = "buy", item = "Runecloth", count = 20, price = 2000, fee = 0 },
    { at = 20, side = "repair", item = "Repairs", count = 1, price = 500, fee = 0 },
    { at = 30, side = "sell", item = "Runecloth", count = 10, price = 1500, fee = 75 },
  },
  ["B-R"] = { { at = 40, side = "merchant", item = "Coarse Thread", count = 5, price = 50, fee = 0 } },
} }
local perItem = {}
for _, item in ipairs(Trades.Items(Trades.Rows(mixed))) do
  perItem[#perItem + 1] = table.concat({ item.name, item.bought, item.cost, tostring(item.averageCost), item.sold, item.proceeds,
    tostring(item.averageSale), tostring(item.profit), item.last }, " ")
end
eq(table.concat(perItem, " / "), "Coarse Thread 5 50 10 0 0 nil nil 40 / Runecloth 20 2000 100 10 1425 142.5 425 30",
  "By item adds up the goods per item, realizes profit on the units both bought and sold, and leaves out gold-only entries")
SlashCmdList.GOLDBOOK("items jagged")
eq(GoldbookWindow.tabs.items.selected.shown, true, "/gb items opens the By item view")
eq(cells(1), "Jagged Star of the Eagle | 1 | 23s 00c | 1 | 31s 00c | +8s 00c | just now", "an item bought for 23s and sold for 31s")
eq(cards() .. " " .. plain(GoldbookWindow.cards.cards[4].detail.text),
  "BOUGHT 23s 00c / SOLD 31s 00c / REALIZED PROFIT +8s 00c / BEST ITEM +8s 00c Jagged Star of the Eagle",
  "the cards total the items shown, the best item under its profit")
GoldbookWindow.search:SetText("")

-- The file the end-to-end check uploads, with the account the sync tests use.
if arg[1] then
  ns.db.account = { id = "K7Q2M9PX", key = "7KQ2M9PXABCDEFGHJKMN" }
  local function serialize(value)
    if type(value) == "string" then
      return string.format("%q", value)
    elseif type(value) ~= "table" then
      return tostring(value)
    end
    local out, keys = { "{" }, {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, key in ipairs(keys) do
      out[#out + 1] = "[" .. serialize(key) .. "]=" .. serialize(value[key]) .. ","
    end
    out[#out + 1] = "}"
    return table.concat(out)
  end
  local saved = { account = ns.db.account, gold = ns.db.gold, items = ns.db.items, scans = {}, trades = ns.db.trades }
  local out = assert(io.open(arg[1], "w"))
  out:write("GoldbookDB = ", serialize(saved), "\n")
  out:close()
end

io.write(("%d trade checks, %d failed.\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
