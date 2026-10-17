-- A stand-in for the WoW client: virtual clock, timers, events, and an auction
-- house that pages, throttles and loads item data late, as the real one does.
local Stub = {
  clock = 0,
  timers = {},
  frames = {},
  printed = {},
  items = {},
  bags = {},
  tooltipCalls = {},
  categories = {},
  metadata = {},
  cursor = { 0, 0 },
  shift = false,
  alt = false,
  ctrl = false,
  money = 0,
  reloads = 0,
  name = "Sultan",
  class = "WARRIOR",
  level = 60,
}

local EPOCH = 1760000000
-- The client's finer timers count from about when the computer started.
local UPTIME = 86400 + 0.4375

function time()
  return EPOCH + math.floor(Stub.clock)
end
function GetTime()
  return UPTIME + Stub.clock
end
function debugprofilestop()
  return (UPTIME + Stub.clock) * 1000 + 0.125
end

function print(text)
  Stub.printed[#Stub.printed + 1] = text
end

local function noop() end

local methods = {}
function methods:SetScript(name, handler)
  self.scripts[name] = handler
end
function methods:HookScript(name, handler)
  self.scripts[name] = handler
end
function methods:RegisterEvent(event)
  self.events[event] = true
end
function methods:UnregisterEvent(event)
  self.events[event] = nil
end
-- An edit box's selection, kept as the text selected. HighlightText counts
-- from 0 and selects to the end without an end; new text drops the selection.
-- Like the client, it refuses a position that is not a 32-bit integer.
function methods:HighlightText(from, to)
  for _, position in ipairs({ from or 0, to or 0 }) do
    if type(position) ~= "number" or position % 1 ~= 0 or position < -2 ^ 31 or position >= 2 ^ 31 then
      error("bad argument to HighlightText: " .. tostring(position), 2)
    end
  end
  self.selected = self.text:sub((from or 0) + 1, to or -1)
end
function methods:SetText(text)
  self.text = text
  self.selected = nil
  if self.scripts.OnTextChanged then
    self.scripts.OnTextChanged(self)
  end
end
function methods:GetText()
  return self.text
end
function methods:Show()
  self.shown = true
end
function methods:Hide()
  self.shown = false
end
function methods:IsShown()
  return self.shown
end
function methods:GetName()
  return self.name
end
local function child(parent)
  local widget = Stub.widget()
  widget.stubParent = parent
  return widget
end
function methods:CreateFontString()
  return child(self)
end
function methods:CreateTexture()
  return child(self)
end
function methods:CreateLine()
  return child(self)
end
function methods:SetStartPoint(...)
  self.startPoint = { ... }
end
function methods:SetEndPoint(...)
  self.endPoint = { ... }
end
function methods:SetThickness(thickness)
  self.thickness = thickness
end
function methods:SetTexture(texture)
  self.texture = texture
end
function methods:SetTextColor(r, g, b)
  self.textColor = { r, g, b }
end
function methods:LockHighlight()
  self.highlighted = true
end
function methods:UnlockHighlight()
  self.highlighted = false
end
function methods:SetShown(shown)
  self.shown = shown
end
function methods:SetSize(width, height)
  self.width, self.height = width, height
end
function methods:SetHeight(height)
  self.height = height
end
-- The client refuses an anchor that would make a region depend on itself,
-- and so does the stub: anchors[point] is the region each point hangs on.
local function dependsOn(region, target, seen)
  if region == target then
    return true
  end
  seen = seen or {}
  if seen[region] then
    return false
  end
  seen[region] = true
  for _, relative in pairs(rawget(region, "anchors") or {}) do
    if dependsOn(relative, target, seen) then
      return true
    end
  end
  return false
end

local function anchor(self, point, relative)
  if type(relative) == "string" then
    relative = _G[relative]
  end
  if type(relative) == "table" then
    if dependsOn(relative, self) then
      error("Action[SetPoint] failed because[Cannot anchor to a region dependent on it]", 3)
    end
    local anchors = rawget(self, "anchors") or {}
    anchors[point] = relative
    self.anchors = anchors
  end
end

-- Without a region to hang on, a point hangs on the parent.
function methods:SetPoint(point, relative, ...)
  if relative == nil or type(relative) == "number" then
    anchor(self, point, rawget(self, "stubParent"))
  else
    anchor(self, point, relative)
  end
  self.point = { point, relative, ... }
end
function methods:SetAllPoints(relative)
  anchor(self, "ALL", relative or rawget(self, "stubParent"))
end
function methods:ClearAllPoints()
  self.anchors = nil
end
function methods:GetPoint()
  return unpack(self.point)
end
function methods:SetChecked(checked)
  self.checked = checked
end
function methods:GetChecked()
  return self.checked
end
-- Nothing is laid out, so a widget is only as wide, and reaches only as far
-- right, as a test says.
function methods:GetWidth()
  return rawget(self, "width") or 0
end
function methods:GetHeight()
  return rawget(self, "height") or 0
end
function methods:GetRight()
  return rawget(self, "right") or 0
end
-- A test places a frame by setting its centre.
function methods:GetCenter()
  local center = rawget(self, "center") or { 0, 0 }
  return center[1], center[2]
end
function methods:SetScale(scale)
  self.scale = scale
end
function methods:GetScale()
  return rawget(self, "scale") or 1
end
function methods:SetValue(value)
  self.value = value
end
function methods:GetValue()
  return self.value
end
function methods:GetEffectiveScale()
  return 1
end
function methods:SetEnabled(enabled)
  self.enabled = enabled
end
function methods:SetHyperlink(link)
  self.hyperlink = link
end
function methods:GetOwner()
  return self.owner
end
function methods:SetSearchText(text)
  self.searchText = text
end
function methods:StartSearch()
  self.searches = (rawget(self, "searches") or 0) + 1
end
function methods:AddLine(text)
  self.lines[#self.lines + 1] = text
end
function methods:AddDoubleLine(left, right)
  self.lines[#self.lines + 1] = left .. " = " .. right
end

function Stub.widget(name)
  local widget = { name = name, scripts = {}, events = {}, lines = {}, shown = true, text = "" }
  setmetatable(widget, {
    __index = function(_, key)
      return methods[key] or (type(key) == "string" and key:match("^[A-Z]") and noop or nil)
    end,
  })
  Stub.frames[#Stub.frames + 1] = widget
  if name then
    _G[name] = widget
  end
  return widget
end

function Stub.fire(event, ...)
  if event == "PLAYER_LOGIN" then
    Stub.loggedIn = true
  elseif event == "BANKFRAME_OPENED" or event == "BANKFRAME_CLOSED" then
    Stub.bankOpen = event == "BANKFRAME_OPENED"
  end
  local listening = {}
  for _, frame in ipairs(Stub.frames) do
    if frame.events[event] then
      listening[#listening + 1] = frame
    end
  end
  for _, frame in ipairs(listening) do
    frame.scripts.OnEvent(frame, event, ...)
  end
end

function Stub.advance(seconds)
  local target = Stub.clock + seconds
  while true do
    local next
    for index, timer in ipairs(Stub.timers) do
      if timer.at <= target and (not next or timer.at < Stub.timers[next].at) then
        next = index
      end
    end
    if not next then
      break
    end
    local timer = table.remove(Stub.timers, next)
    Stub.clock = timer.at
    timer.run()
  end
  Stub.clock = target
end

function CreateFrame(_, name, parent)
  local widget = Stub.widget(name)
  widget.stubParent = parent
  return widget
end
function CreateFont(name)
  return Stub.widget(name)
end
function CreateColor(r, g, b, a)
  return { r = r, g = g, b = b, a = a or 1 }
end

-- Loads the addon in `folder` as the client does: the files its .toc lists,
-- in order, sharing one namespace. The .toc's "## Field: value" lines answer
-- GetAddOnMetadata.
function Stub.loadAddon(folder)
  local ns = {}
  for line in io.lines(folder .. "/Goldbook.toc") do
    local field, value = line:match("^## ([%w-]+):%s*(.-)%s*$")
    local file = line:match("^([%w_]+%.lua)%s*$")
    if field then
      Stub.metadata[field] = value
    elseif file then
      assert(loadfile(folder .. "/" .. file))("Goldbook", ns)
    end
  end
  return ns
end

C_AddOns = {}
function C_AddOns.GetAddOnMetadata(addon, field)
  assert(addon == "Goldbook", "no .toc read for " .. tostring(addon))
  return Stub.metadata[field]
end

C_Timer = {}
function C_Timer.After(delay, run)
  Stub.timers[#Stub.timers + 1] = { at = Stub.clock + delay, run = run }
end

local ah = { ready = true, silent = false, browse = {}, loaded = 0, pageSize = 2, replicate = {}, queries = {}, keyInfo = {} }
Stub.ah = ah

local function throttle()
  ah.ready = false
  C_Timer.After(0.2, function()
    ah.ready = true
    Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  end)
end

local function requireReady(request)
  if not ah.ready then
    error(request .. " sent while throttled", 3)
  end
end

C_AuctionHouse = {}
function C_AuctionHouse.IsThrottledMessageSystemReady()
  return ah.ready
end
function C_AuctionHouse.SendBrowseQuery(query)
  requireReady("SendBrowseQuery")
  ah.queries[#ah.queries + 1] = query
  if ah.silent then
    return
  end
  ah.loaded = math.min(ah.pageSize, #ah.browse)
  throttle()
  C_Timer.After(0.1, function()
    Stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  end)
end
function C_AuctionHouse.RequestMoreBrowseResults()
  requireReady("RequestMoreBrowseResults")
  local added = {}
  local from = ah.loaded
  ah.loaded = math.min(from + ah.pageSize, #ah.browse)
  for index = from + 1, ah.loaded do
    added[#added + 1] = ah.browse[index]
  end
  throttle()
  C_Timer.After(0.1, function()
    Stub.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", added)
  end)
end
function C_AuctionHouse.HasFullBrowseResults()
  return ah.loaded >= #ah.browse
end
function C_AuctionHouse.GetBrowseResults()
  local results = {}
  for index = 1, ah.loaded do
    results[index] = ah.browse[index]
  end
  return results
end
-- Stub.ah.keyInfo["itemID:suffix"] = { itemName, quality }; a key not listed
-- is not loaded yet and answers nil.
function C_AuctionHouse.GetItemKeyInfo(itemKey)
  return ah.keyInfo[itemKey.itemID .. ":" .. (itemKey.itemSuffix or 0)]
end
function C_AuctionHouse.ReplicateItems()
  if ah.silent then
    return
  end
  C_Timer.After(1, function()
    Stub.fire("REPLICATE_ITEM_LIST_UPDATE")
  end)
end
function C_AuctionHouse.GetNumReplicateItems()
  return #ah.replicate
end
function C_AuctionHouse.GetReplicateItemInfo(index)
  local auction = ah.replicate[index + 1]
  local loaded = Stub.clock >= (auction.loadsAt or 0)
  return nil, nil, auction.count, auction.quality or 1, nil, 0, nil, auction.bid or 0, 0, auction.buyout, 0, nil, nil,
    auction.owner, auction.ownerFullName, 0, auction.itemID, loaded
end
function C_AuctionHouse.GetReplicateItemLink(index)
  local auction = ah.replicate[index + 1]
  if Stub.clock >= (auction.loadsAt or 0) then
    return auction.link
  end
end

-- Stub.items[itemID] = { name, quality, vendor, itemData, cached, delay }.
-- `vendor` is what the tooltip says a vendor pays, `itemData` what
-- C_Item.GetItemInfo says instead when the two differ. Uncached items answer
-- nil, then arrive through GET_ITEM_INFO_RECEIVED after `delay` seconds (half a
-- second by default; math.huge for an item the server never answers for).
C_Item = {}
function C_Item.GetItemInfo(item)
  local itemID = tonumber(item) or tonumber(item:match("item:(%d+)"))
  item = Stub.items[itemID]
  if not item then
    return nil
  end
  if item.cached then
    local link = "|Hitem:" .. itemID .. "|h[" .. item.name .. "]|h"
    return item.name, link, item.quality, nil, nil, nil, nil, nil, nil, nil, item.itemData or item.vendor
  end
  C_Timer.After(item.delay or 0.5, function()
    item.cached = true
    Stub.fire("GET_ITEM_INFO_RECEIVED", itemID, true)
  end)
end
function C_Item.RequestLoadItemDataByID() end

C_TooltipInfo = {}
function C_TooltipInfo.GetHyperlink(link)
  local item = Stub.items[tonumber(link:match("item:(%d+)"))]
  if not (item and item.cached) then
    return nil
  end
  local lines = { { type = Enum.TooltipDataLineType.ItemName, leftText = item.name } }
  if (item.vendor or 0) > 0 then
    lines[#lines + 1] = { type = Enum.TooltipDataLineType.SellPrice, price = item.vendor, maxPrice = -1 }
  end
  return { lines = lines }
end

-- Stub.bags[container] = { slots = n, [slot] = item info }. The bank's
-- containers, its own slots (-1) and its bags (5 to 10), read as empty
-- while it is closed.
local function readable(container)
  return Stub.bags[container] and (Stub.bankOpen or (container >= 0 and container <= 4))
end
C_Container = {}
function C_Container.GetContainerNumSlots(container)
  return readable(container) and Stub.bags[container].slots or 0
end
function C_Container.GetContainerItemInfo(container, slot)
  return readable(container) and Stub.bags[container][slot] or nil
end
-- The client counts the bank's bags apart; only the bags are asked here.
function C_Container.GetContainerNumFreeSlots(container)
  local bag = readable(container) and Stub.bags[container]
  if not bag then
    return 0, 0
  end
  local free = bag.slots
  for slot = 1, bag.slots do
    free = free - (bag[slot] and 1 or 0)
  end
  return free, 0
end

-- The mailbox. Stub.inbox.mails holds every mail, newest first:
--   { sender, subject, money, cod, daysLeft, text, refuses, canReply,
--     invoice = { type, item, player, bid, buyout, deposit, cut, count },
--     items = { [slot] = { itemID, name, count, quality } } }
-- The client shows the first `shows` of them and holds back the rest. A take
-- answers with MAIL_INBOX_UPDATE after `answer` seconds (none when nil); an
-- item goes to the first empty bag slot, or the client says ERR_INV_FULL; a
-- mail with neither money nor items left, nor text, is deleted, which
-- renumbers the mails after it. A mail that `refuses` keeps what it holds.
-- Players' mail can be replied to unless `canReply` is false.
-- `takes` lists every take as "money <index>" or "item <index>:<slot>".
local inbox = { mails = {}, shows = 50, answer = 0.2, takes = {} }
Stub.inbox = inbox
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
ERR_INV_FULL = "Inventory is full."
ATTACHMENTS_MAX_RECEIVE = 16

function Stub.openMailbox()
  Stub.fire("MAIL_SHOW")
  Stub.fire("MAIL_INBOX_UPDATE")
end
function CheckInbox() end
function GetInboxNumItems()
  return math.min(#inbox.mails, inbox.shows), #inbox.mails
end
local function attached(mail)
  local count = 0
  for _ in pairs(mail.items or {}) do
    count = count + 1
  end
  return count
end
function GetInboxHeaderInfo(index)
  local mail = inbox.mails[index]
  local count = attached(mail)
  return "Interface\\Icons\\INV_Letter_15", nil, mail.sender, mail.subject, mail.money or 0, mail.cod or 0, mail.daysLeft or 30,
    count > 0 and count or nil, false, false, mail.text ~= nil, mail.canReply ~= false, false
end
function GetInboxInvoiceInfo(index)
  local invoice = inbox.mails[index].invoice
  if not invoice then
    return nil
  end
  return invoice[1], invoice[2], invoice[3], invoice[4], invoice[5], invoice[6], invoice[7], 0, 0, 0, invoice[8]
end
function GetInboxItem(index, slot)
  local item = (inbox.mails[index].items or {})[slot]
  if item then
    return item[2], item[1], 130000 + item[1], item[3], item[4] or 1, true
  end
end
function GetInboxItemLink(index, slot)
  local item = (inbox.mails[index].items or {})[slot]
  if item then
    return (ITEM_QUALITY_COLORS[item[4] or 1] or ITEM_QUALITY_COLORS[1]).hex .. "|Hitem:" .. item[1] .. "::::::::60:::::|h[" .. item[2] .. "]|h|r"
  end
end
local function taken(index)
  local mail = inbox.mails[index]
  if (mail.money or 0) == 0 and attached(mail) == 0 and not mail.text then
    table.remove(inbox.mails, index)
  end
  if inbox.answer then
    C_Timer.After(inbox.answer, function()
      Stub.fire("MAIL_INBOX_UPDATE")
    end)
  end
end
function TakeInboxMoney(index)
  inbox.takes[#inbox.takes + 1] = "money " .. index
  local mail = inbox.mails[index]
  if not mail.refuses then
    Stub.money = Stub.money + (mail.money or 0)
    mail.money = 0
    taken(index)
  end
end
function TakeInboxItem(index, slot)
  inbox.takes[#inbox.takes + 1] = "item " .. index .. ":" .. slot
  local mail = inbox.mails[index]
  if mail.refuses then
    return
  end
  for container = 0, 4 do
    local bag = Stub.bags[container]
    for place = 1, bag and bag.slots or 0 do
      if not bag[place] then
        local item = mail.items[slot]
        bag[place] = { hyperlink = GetInboxItemLink(index, slot), stackCount = item[3] }
        mail.items[slot] = nil
        taken(index)
        return
      end
    end
  end
  Stub.fire("UI_ERROR_MESSAGE", 3, ERR_INV_FULL)
end
function AutoLootMailItem(index)
  inbox.takes[#inbox.takes + 1] = "all " .. index
end

function IsShiftKeyDown()
  return Stub.shift
end
function IsAltKeyDown()
  return Stub.alt
end
function IsControlKeyDown()
  return Stub.ctrl
end

date = os.date

-- Item buttons hand modified clicks to this; the default UI's own handling
-- (chat links, dressing room) is not simulated.
function HandleModifiedItemClick()
  return false
end
-- Runs `hook` with the same arguments after the function, which may be a
-- global or a field of `owner`.
function hooksecurefunc(owner, name, hook)
  if type(owner) == "string" then
    owner, name, hook = _G, owner, name
  end
  local original = owner[name]
  owner[name] = function(...)
    local result = original(...)
    hook(...)
    return result
  end
end

function GetMoney()
  return Stub.money
end

-- Counted instead of reloading. It takes no arguments, and refuses any so
-- that a click handler cannot hand it the click's own.
function ReloadUI(...)
  assert(select("#", ...) == 0, "ReloadUI takes no arguments")
  Stub.reloads = Stub.reloads + 1
end

TooltipDataProcessor = {}
function TooltipDataProcessor.AddTooltipPostCall(_, handler)
  Stub.tooltipCalls[#Stub.tooltipCalls + 1] = handler
end
TooltipUtil = {}
function TooltipUtil.GetDisplayedItem(tooltip)
  return tooltip.itemName, tooltip.itemLink
end

Enum = {
  AuctionHouseFilter = {
    PoorQuality = 5,
    CommonQuality = 6,
    UncommonQuality = 7,
    RareQuality = 8,
    EpicQuality = 9,
    LegendaryQuality = 10,
    ArtifactQuality = 11,
  },
  AuctionHouseSortOrder = { Price = 0, Name = 1 },
  TooltipDataType = { Item = 0 },
  TooltipDataLineType = { ItemName = 1, SellPrice = 11 },
}
ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" }, [2] = { hex = "|cff1eff00" } }
SlashCmdList = {}
UISpecialFrames = {}
tinsert = table.insert
GameTooltip_Hide = noop
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
NumberFontNormal = Stub.widget("NumberFontNormal")
function NumberFontNormal.GetFont()
  return "Fonts\\ARIALN.TTF", 14, "OUTLINE"
end
UIParent = Stub.widget("UIParent")
AuctionHouseFrame = Stub.widget("AuctionHouseFrame")
AuctionHouseFrame.SearchBar = Stub.widget()
Stub.widget("Minimap").width = 140

function GetCursorPosition()
  return Stub.cursor[1], Stub.cursor[2]
end

Settings = {}
function Settings.RegisterCanvasLayoutCategory(frame, name)
  return { frame = frame, name = name }
end
function Settings.RegisterAddOnCategory(category)
  Stub.categories[#Stub.categories + 1] = category
end
Stub.widget("GameTooltip")
Stub.widget("ItemRefTooltip")

function GetBuildInfo()
  return "1.60.1", "70338"
end
-- The normalized realm name is only known once the player is logged in; the
-- display name, which may differ from it, is known before.
function GetNormalizedRealmName()
  return Stub.loggedIn and "Faramon" or nil
end
function GetRealmName()
  return "Fara'mon"
end
function GetCurrentRegionName()
  return "EU"
end
function UnitFactionGroup()
  return "Horde"
end
-- "NPC" is whoever the trade window is open with.
function UnitName(unit)
  if unit == "NPC" then
    return Stub.trade.party
  end
  return Stub.name
end
function UnitClass()
  return Stub.class:sub(1, 1) .. Stub.class:sub(2):lower(), Stub.class
end
function UnitLevel()
  return Stub.level
end
function issecretvalue()
  return false
end

-- What the accounting reads. The calls it hooks do nothing here: a test moves
-- Stub.money and fires PLAYER_MONEY as the server would answer.

-- Stub.merchant[index] = { name, price, stack, link }: `price` buys `stack` items.
Stub.merchant = {}
function GetMerchantItemInfo(index)
  local entry = Stub.merchant[index]
  if entry then
    return entry[1], nil, entry[2], entry[3], -1, true, false
  end
end
function GetMerchantItemLink(index)
  return Stub.merchant[index] and Stub.merchant[index][4]
end
function GetMerchantNumItems()
  return #Stub.merchant
end
function GetMerchantItemID(index)
  local link = GetMerchantItemLink(index)
  return link and tonumber(link:match("item:(%d+)"))
end
function GetMerchantItemCostInfo()
  return 0
end
function BuyMerchantItem() end
-- Stub.buyback[index] = { name, count, price, link }.
Stub.buyback = {}
function GetNumBuybackItems()
  return #Stub.buyback
end
function GetBuybackItemInfo(index)
  local entry = Stub.buyback[index]
  if entry then
    return entry[1], nil, entry[3], entry[2]
  end
end
function GetBuybackItemLink(index)
  return Stub.buyback[index] and Stub.buyback[index][4]
end
function BuybackItem() end

-- Stub.taxi[index] = { name, cost }.
Stub.taxi = {}
function TaxiNodeName(index)
  return Stub.taxi[index][1]
end
function TaxiNodeCost(index)
  return Stub.taxi[index][2]
end
function TakeTaxiNode() end

-- Stub.trainer[index] = { name, rank, cost }.
Stub.trainer = {}
function GetTrainerServiceInfo(index)
  local entry = Stub.trainer[index]
  return entry[1], entry[2], "available"
end
function GetTrainerServiceCost(index)
  return Stub.trainer[index][3], 0, 0
end
function BuyTrainerService() end
function ConfirmTalentWipe() end

-- The mail being written: { postage, money }.
Stub.sending = { 30, 0 }
function GetSendMailPrice()
  return Stub.sending[1]
end
function GetSendMailMoney()
  return Stub.sending[2]
end
function SendMail() end


-- The trade window: who with, and each side's { items = { { name, count, link } }, money }.
Stub.trade = { player = { items = {}, money = 0 }, target = { items = {}, money = 0 } }
local function tradeItem(side, slot)
  local item = Stub.trade[side].items[slot]
  if item then
    return item[1], nil, item[2], 1, true
  end
end
function GetTradePlayerItemInfo(slot)
  return tradeItem("player", slot)
end
function GetTradeTargetItemInfo(slot)
  return tradeItem("target", slot)
end
function GetTradePlayerItemLink(slot)
  local item = Stub.trade.player.items[slot]
  return item and item[3]
end
function GetTradeTargetItemLink(slot)
  local item = Stub.trade.target.items[slot]
  return item and item[3]
end
function GetPlayerTradeMoney()
  return Stub.trade.player.money
end
function GetTargetTradeMoney()
  return Stub.trade.target.money
end

-- Stub.quests[questID] = its title; Stub.questTitle the one the quest frame shows.
Stub.quests = {}
C_QuestLog = {}
function C_QuestLog.GetTitleForQuestID(questID)
  return Stub.quests[questID]
end
function GetTitleText()
  return Stub.questTitle
end

function C_AuctionHouse.PostItem() end
function C_AuctionHouse.PostCommodity() end
function C_AuctionHouse.PlaceBid() end
function C_AuctionHouse.ConfirmCommoditiesPurchase() end
-- An item location is { bagID, slotIndex } in Stub.bags.
local function located(location)
  local bag = Stub.bags[location.bagID]
  return bag and bag[location.slotIndex]
end
function C_Item.DoesItemExist(location)
  return located(location) ~= nil
end
function C_Item.GetItemName(location)
  local info = located(location)
  return info and info.hyperlink:match("%[(.-)%]")
end

ERR_TRADE_COMPLETE = "Trade complete."
GOLD_AMOUNT = "%d Gold"
SILVER_AMOUNT = "%d Silver"
COPPER_AMOUNT = "%d Copper"

return Stub
