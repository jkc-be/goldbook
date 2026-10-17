local ADDON, ns = ...
local Codec, Database, Scanner, Advisor, Ledger, Trades = ns.Codec, ns.Database, ns.Scanner, ns.Advisor, ns.Ledger, ns.Trades

-- Every uncached item asks the server, so the pace stays gentle: 250 a second
-- names 8000 new items in about 32 s, and only items not named yet ask.
local INFO_BATCH = 25
local INFO_BATCH_DELAY = 0.1
local NAMES_TIMEOUT = 15
local DEFAULT_MIN_PROFIT = 1000
local BAGS = { 0, 1, 2, 3, 4 }
-- The bank's own slots, then its six bag slots, numbered after the bags.
local BANK = { -1, 5, 6, 7, 8, 9, 10 }
local AUTO_SCAN_INTERVAL = 15 * 60
local AUTO_SCAN_DELAY = 1
local PREFIX = "|cffffd100Goldbook|r "
-- As the .toc states it, for the window, the options and chat.
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
local loginIdentity

function ns.Print(text)
  print(PREFIX .. text)
end

function ns.RealmKey()
  local identity = loginIdentity or Scanner.Identity()
  return Database.RealmKey(identity.realm, identity.faction)
end

-- "Name-Realm", as gold, the bank and the logout snapshot are filed.
local function characterKey()
  local identity = loginIdentity or Scanner.Identity()
  return identity.by .. "-" .. identity.realm
end

function ns.MinProfit()
  return ns.db.settings.minProfit or DEFAULT_MIN_PROFIT
end

-- Name, quality and vendor price load asynchronously; keys still waiting,
-- grouped by item id.
local awaiting = {}
-- The newest scan until it is announced.
local unannounced

local function awaitingCount()
  local count = 0
  for _, keys in pairs(awaiting) do
    for _ in pairs(keys) do
      count = count + 1
    end
  end
  return count
end

local function resolveItem(key)
  local itemID = Codec.BaseID(key)
  local name, _, quality, _, _, _, _, _, _, _, vendor = C_Item.GetItemInfo(itemID)
  if not name then
    awaiting[itemID] = awaiting[itemID] or {}
    awaiting[itemID][key] = true
    return
  end
  -- A full scan may already have stored the name with its suffix.
  if not ns.db.items[key] then
    Database.SetItem(ns.db, key, name, quality or 1)
  end
  ns.db.vendor[itemID] = vendor or 0
end

local function unresolved(key)
  return not ns.db.items[key] or ns.db.vendor[Codec.BaseID(key)] == nil
end

local function resolveItems(keys, from, done)
  local to = math.min(from + INFO_BATCH - 1, #keys)
  for index = from, to do
    resolveItem(keys[index])
  end
  if to < #keys then
    C_Timer.After(INFO_BATCH_DELAY, function()
      resolveItems(keys, to + 1, done)
    end)
  else
    done()
  end
end

-- Unbound items in `containers` as { key, count }, one entry per item.
local function heldItems(containers)
  local byKey, held, realmKey = {}, {}, ns.RealmKey()
  for _, container in ipairs(containers) do
    for slot = 1, C_Container.GetContainerNumSlots(container) do
      local info = C_Container.GetContainerItemInfo(container, slot)
      -- Older container APIs give no link for an item that is not cached yet.
      local key = info and not info.isBound and info.hyperlink and Database.KeyFromLink(ns.db, realmKey, info.hyperlink)
      if key then
        if not byKey[key] then
          byKey[key] = { key = key, count = 0 }
          held[#held + 1] = byKey[key]
          if unresolved(key) then
            resolveItem(key)
          end
        end
        byKey[key].count = byKey[key].count + info.stackCount
      end
    end
  end
  return held
end

function ns.BagItems()
  return heldItems(BAGS)
end

-- Said only once the item details are in, because a /reload before that
-- would upload the scan without its names; after NAMES_TIMEOUT it says how
-- many are still missing.
local function announce(scan, unnamed)
  local deals = Advisor.Deals(ns.db, ns.RealmKey(), ns.MinProfit())
  local missing = unnamed > 0 and (", " .. unnamed .. " still unnamed") or ""
  ns.Print(#scan.rows .. " items scanned" .. missing .. ". Type /reload or log out to hand the scan to Goldbook.")
  if scan.bookCount then
    ns.Print(scan.bookCount .. " order books recorded. Keep the desktop app open and type /reload to upload them.")
    if scan.bookSkipped > 0 then
      ns.Print(scan.bookSkipped .. " order books were incomplete or too large and were not saved.")
    end
  end
  if scan.skipped > 0 then
    ns.Print("Left out " .. scan.skipped .. " listings of item variants it could not tell apart. A quick scan first helps.")
  end
  if #deals > 0 then
    local worth = 0
    for _, deal in ipairs(deals) do
      worth = worth + deal.total
    end
    ns.Print(#deals .. (#deals == 1 and " deal" or " deals") .. " worth " .. Codec.Money(worth) .. ". Type /gb deals.")
  end
  ns.UI.Refresh()
end

local function announceOnceNamed()
  if unannounced and next(awaiting) == nil then
    local scan = unannounced
    unannounced = nil
    announce(scan, 0)
  end
end

Scanner.Subscribe(function(kind, payload)
  if kind == "done" then
    Database.ApplyScan(ns.db, payload)
    if payload.samples and #payload.samples > 0 then
      ns.db.linkSamples = payload.samples
    end
    local keys = {}
    for _, row in ipairs(payload.rows) do
      if unresolved(row.key) then
        keys[#keys + 1] = row.key
      end
    end
    if #keys > INFO_BATCH then
      ns.Print("Scan saved. Loading details of " .. #keys .. " items...")
    end
    resolveItems(keys, 1, function()
      unannounced = payload
      announceOnceNamed()
      if unannounced then
        C_Timer.After(NAMES_TIMEOUT, function()
          if unannounced == payload then
            unannounced = nil
            announce(payload, awaitingCount())
            -- Whatever did not answer is asked again by the next scan or bag
            -- check, instead of holding up every later announcement.
            awaiting = {}
          end
        end)
      end
    end)
  elseif kind == "fail" then
    ns.Print("Scan stopped: " .. payload .. ".")
  elseif kind == "refused" then
    ns.Print("Cannot scan: " .. payload .. ".")
  end
end)

local COMMANDS = {
  scan = function(argument)
    Scanner.Start(argument == "full" and "replicate" or "browse")
  end,
  show = function(argument)
    ns.UI.Show("prices", argument)
  end,
  deals = function(argument)
    ns.UI.Show("deals", argument)
  end,
  sell = function(argument)
    ns.UI.Show("sell", argument)
  end,
  gold = function(argument)
    ns.UI.Show("gold", argument)
  end,
  trades = function(argument)
    ns.UI.Show("trades", argument)
  end,
  movers = function(argument)
    ns.UI.Show("movers", argument)
  end,
  -- A link, an exact name, or else the first name containing the text.
  item = function(argument)
    if argument:find("item:", 1, true) then
      ns.UI.ShowItem(argument)
      return
    end
    local matches = argument ~= "" and Database.Search(ns.db, ns.RealmKey(), argument) or {}
    local found = matches[1]
    for _, item in ipairs(matches) do
      if item.name:lower() == argument:lower() then
        found = item
        break
      end
    end
    if found then
      ns.UI.ShowItem(found.key)
    else
      ns.Print("No item priced on " .. ns.RealmKey() .. " matches \"" .. argument .. "\". Type /gb item <link or name>.")
    end
  end,
  autoscan = function()
    ns.db.settings.autoScan = not ns.db.settings.autoScan or nil
    ns.Print("Quick scan when the auction house opens: " .. (ns.db.settings.autoScan and "on" or "off") .. ".")
  end,
  minprofit = function(argument)
    local gold = tonumber(argument)
    if gold and gold >= 0 then
      ns.db.settings.minProfit = math.floor(gold * 10000 + 0.5)
      ns.UI.Refresh()
    end
    ns.Print("Resale deals must make at least " .. Codec.Money(ns.MinProfit()) .. ". Change it with /gb minprofit <gold>.")
  end,
  minimap = function()
    ns.MinimapButton.SetShown(not ns.MinimapButton.IsShown())
  end,
  web = function()
    ns.WebLogin.Show()
  end,
  theme = function(argument)
    if argument ~= "" and not ns.UI.SetTheme(argument:lower()) then
      ns.Print("There is no \"" .. argument .. "\" theme.")
    end
    ns.Print("The window is " .. ns.UI.Theme() .. ". Change it with /gb theme light or /gb theme dark.")
  end,
  scale = function(argument)
    local low, high = ns.UI.MIN_SCALE, ns.UI.MAX_SCALE
    if argument ~= "" and not ns.UI.SetScale(tonumber(argument)) then
      ns.Print(("The window's size goes from %.1f to %.1f, 1 being its normal size."):format(low, high))
    end
    ns.Print(("The window is at size %.2f. Change it with /gb scale <%.1f-%.1f>."):format(ns.UI.Scale(), low, high))
  end,
  status = function()
    local known = 0
    for _ in pairs(ns.db.prices[ns.RealmKey()] or {}) do
      known = known + 1
    end
    local last = ns.db.scans[#ns.db.scans]
    ns.Print("Version " .. ns.VERSION .. ". " .. known .. " items priced on " .. ns.RealmKey() .. ", " .. #ns.db.scans .. " scans queued for sync.")
    local books = 0
    for _ in pairs(ns.db.sellerScans) do books = books + 1 end
    ns.Print(books .. " order book snapshots saved locally. Type /reload with the desktop app open to sync.")
    if last then
      ns.Print("Last scan " .. Codec.Age(time() - last.at) .. " (" .. last.count .. " items).")
    end
  end,
}

SLASH_GOLDBOOK1, SLASH_GOLDBOOK2 = "/goldbook", "/gb"
SlashCmdList.GOLDBOOK = function(input)
  local command, argument = input:match("^(%S*)%s*(.-)%s*$")
  local run = COMMANDS[command:lower()]
  if run then
    run(argument)
  else
    ns.Print("/gb scan  |  /gb scan full  |  /gb deals  |  /gb sell  |  /gb movers  |  /gb gold  |  /gb trades  |  /gb show [text]")
    ns.Print("/gb item <link or name>  |  /gb minprofit <gold>  |  /gb autoscan")
    ns.Print("/gb status  |  /gb minimap  |  /gb web  |  /gb theme light|dark  |  /gb scale <0.7-1.4>")
  end
end

local function recordGold()
  Ledger.Record(ns.db, characterKey(), GetMoney(), time())
end

local function plural(count, noun)
  return count .. " " .. noun .. (count == 1 and "" or "s")
end

-- The mailbox fires this when it opens and whenever its mail changes.
local function bookTrades()
  local sold, bought = Trades.Book(ns.db, characterKey(), Trades.FromInbox(ns.db, ns.RealmKey(), time()), time())
  if sold + bought > 0 then
    local parts = {}
    if sold > 0 then
      parts[#parts + 1] = plural(sold, "sale")
    end
    if bought > 0 then
      parts[#parts + 1] = plural(bought, "purchase")
    end
    ns.Print("Booked " .. table.concat(parts, " and ") .. " from the mailbox. Type /gb trades.")
    ns.UI.RefreshSoon()
  end
end

-- Vendor sales booked since the merchant opened, said once it closes.
local vendorSales = 0

local function bookVendorSales(opened)
  local sold, undone = Trades.Merchant(ns.db, characterKey(), ns.RealmKey(), time(), GetMoney(), opened)
  vendorSales = vendorSales + sold - undone
  if sold + undone > 0 then
    ns.UI.RefreshSoon()
  end
end

-- What the open merchant sells without limit, for gold alone.
local function recordMerchantGoods()
  for index = 1, GetMerchantNumItems() do
    local _, _, price, count, available = GetMerchantItemInfo(index)
    local itemID = GetMerchantItemID(index)
    if itemID and price and price > 0 and available == -1 and GetMerchantItemCostInfo(index) == 0 then
      Database.SetMerchantPrice(ns.db, itemID, math.max(count or 1, 1), price)
    end
  end
end

local function recordBank()
  ns.db.bank[characterKey()] = { at = time(), items = heldItems(BANK) }
end

-- For the sync agent, rebuilt when the client is about to write the file.
-- The bank is priced here too, with the newest prices, not when it was read.
local function saveCharacter()
  local identity, character, now, realmKey = loginIdentity or Scanner.Identity(), characterKey(), time(), ns.RealmKey()
  local bank = ns.db.bank[character]
  ns.db.characters[character] = {
    name = identity.by,
    realm = identity.realm,
    faction = identity.faction,
    class = select(2, UnitClass("player")),
    level = UnitLevel("player"),
    at = now,
    bags = { at = now, rows = Advisor.Sell(ns.db, realmKey, ns.BagItems()) },
    bank = bank and { at = bank.at, rows = Advisor.Sell(ns.db, realmKey, bank.items) },
  }
end

-- Keeps prices fresh without a click. Waits a moment so the auction house
-- window finishes its own first query.
local function autoScan()
  if not ns.db.settings.autoScan or time() - (ns.db.scanned[ns.RealmKey()] or 0) < AUTO_SCAN_INTERVAL then
    return
  end
  C_Timer.After(AUTO_SCAN_DELAY, function()
    if Scanner.open and Scanner.state == "idle" then
      Scanner.Start("browse")
    end
  end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, first, second)
  if event == "ADDON_LOADED" and first == ADDON then
    GoldbookDB = Database.Init(GoldbookDB)
    ns.db = GoldbookDB
    local taken = Database.MergeServer(ns.db, GoldbookServerData)
    if taken > 0 then
      ns.Print("Took " .. plural(taken, "newer price") .. " from the Goldbook server.")
    end
  elseif event == "PLAYER_LOGIN" then
    -- Before login the normalized realm name may be unknown, and gold booked
    -- under the display name would count the character twice.
    loginIdentity = Scanner.Identity()
    frame:RegisterEvent("PLAYER_MONEY")
    frame:RegisterEvent("MAIL_INBOX_UPDATE")
    frame:RegisterEvent("MERCHANT_SHOW")
    frame:RegisterEvent("MERCHANT_UPDATE")
    frame:RegisterEvent("MERCHANT_CLOSED")
    recordGold()
    ns.Print(ns.VERSION .. " loaded. Type /gb for commands.")
  elseif event == "PLAYER_MONEY" then
    recordGold()
    ns.UI.RefreshSoon()
  elseif event == "MAIL_INBOX_UPDATE" then
    bookTrades()
  elseif event == "MERCHANT_SHOW" then
    vendorSales = 0
    bookVendorSales(true)
    recordMerchantGoods()
  elseif event == "MERCHANT_UPDATE" then
    bookVendorSales(false)
    recordMerchantGoods()
  elseif event == "MERCHANT_CLOSED" then
    bookVendorSales(false)
    if vendorSales > 0 then
      ns.Print("Booked " .. plural(vendorSales, "vendor sale") .. ". Type /gb trades.")
    end
    vendorSales = 0
  elseif event == "AUCTION_HOUSE_SHOW" then
    autoScan()
  elseif event == "BANKFRAME_OPENED" then
    -- A closed bank reads as empty, so its changes are followed only while it is open.
    frame:RegisterEvent("BAG_UPDATE")
    frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
    recordBank()
  elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" then
    recordBank()
  elseif event == "BANKFRAME_CLOSED" then
    frame:UnregisterEvent("BAG_UPDATE")
    frame:UnregisterEvent("PLAYERBANKSLOTS_CHANGED")
  elseif event == "PLAYER_LOGOUT" then
    saveCharacter()
  elseif event == "GET_ITEM_INFO_RECEIVED" and awaiting[first] then
    local keys = awaiting[first]
    awaiting[first] = nil
    -- `second` is false for an item id the server knows nothing about.
    if second then
      for key in pairs(keys) do
        resolveItem(key)
      end
      ns.UI.RefreshSoon()
    end
    announceOnceNamed()
  end
end)
