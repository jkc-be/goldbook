local _, ns = ...
local AH = C_AuctionHouse
local House = { open = false, mode = "browse", phase = "idle", rows = {}, offers = {}, message = "Open the auction house to trade." }
ns.AuctionHouse = House

local listeners, serial, issuing = {}, 0, false
local request, review
local TIMEOUT = 20

local function notify(message)
  if message then House.message = message end
  for _, listener in ipairs(listeners) do listener() end
end

function House.Subscribe(listener)
  listeners[#listeners + 1] = listener
end

function House.Busy()
  return House.phase ~= "idle"
end

local function transaction()
  return House.phase == "buy" or House.phase == "post" or House.phase == "cancel" or House.phase == "uncertain"
end

function House.Review()
  return review
end

function House.Transacting()
  return transaction()
end

local function invoke(action)
  issuing = true
  local result = action()
  issuing = false
  return result
end

function House.Dismiss(silent)
  if transaction() then return false end
  local commodity = review and review.kind == "commodity"
  serial = serial + 1
  House.phase, request, review = "idle", nil, nil
  if commodity then AH.CancelCommoditiesPurchase() end
  if not silent then notify() end
  return true
end

local function fail(message)
  local commodity = review and review.kind == "commodity" and House.phase ~= "buy"
  serial = serial + 1
  House.phase, request, review, House.failed = "idle", nil, nil, true
  if commodity then AH.CancelCommoditiesPurchase() end
  notify(message)
  return false
end

local function available()
  if not House.open then return fail("Open the auction house first.") end
  if ns.Scanner.state ~= "idle" then
    notify("Wait for the Goldbook scan to finish.")
    return false
  end
  if transaction() then return false end
  return true
end

local function begin(phase, message)
  serial = serial + 1
  local token = serial
  House.phase, House.failed = phase, false
  C_Timer.After(TIMEOUT, function()
    if token ~= serial or House.phase == "idle" then return end
    if transaction() then
      House.phase = "uncertain"
      notify("No confirmation received. Check your mail and auctions, then reopen the auction house.")
    else
      fail("The request expired. Try again.")
    end
  end)
  notify(message)
end

local function send(phase, action, message)
  if not available() or not House.Dismiss(true) then return false end
  begin(phase, message)
  request = action
  if AH.IsThrottledMessageSystemReady() then
    request = nil
    invoke(action)
  end
  return true
end

local function readyToTrade()
  if not available() then return false end
  if not AH.IsThrottledMessageSystemReady() then
    notify("The auction house is busy. Try again in a moment.")
    return false
  end
  return true
end

local function integer(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function sameKey(a, b)
  if not a or not b then return false end
  for _, field in ipairs({ "itemID", "itemLevel", "itemSuffix", "battlePetSpeciesID" }) do
    if (a[field] or 0) ~= (b[field] or 0) then return false end
  end
  return true
end

local function describe(key, link)
  local info = AH.GetItemKeyInfo(key) or {}
  return info.itemName or (link and link:match("%[(.-)%]")) or ("Item " .. key.itemID), info.iconFileID, info.isCommodity
end

function House.Search(text)
  if not available() then return false end
  House.mode, House.context, House.selected, House.more = "browse", "browse", nil, false
  House.rows, House.offers, House.text = {}, {}, text or ""
  return send("browse", function()
    AH.SendBrowseQuery({ searchString = House.text, sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
      filters = {}, itemClassFilters = {} })
  end, "Searching the auction house...")
end

function House.Select(row)
  if not available() or House.Busy() then return false end
  if House.mode == "browse" then
    local info = AH.GetItemKeyInfo(row.itemKey)
    if not info then return fail("Item details are still loading. Select the item again in a moment.") end
    row.commodity, row.name, row.icon = info.isCommodity, info.itemName, info.iconFileID
  end
  House.selected, House.offers, House.more = row, {}, false
  if House.mode ~= "browse" then notify(); return true end
  House.context = "offers"
  return send("offers", function()
    AH.SendSearchQuery(row.itemKey, {}, true)
  end, "Loading listings for " .. row.name .. "...")
end

function House.Find(item)
  if not available() or not House.Dismiss(true) then return false end
  House.mode = "browse"
  return House.Select(item)
end

local function readBrowse()
  local rows = {}
  for _, result in ipairs(AH.GetBrowseResults()) do
    local name, icon, commodity = describe(result.itemKey)
    rows[#rows + 1] = { itemKey = result.itemKey, name = name, icon = icon, commodity = commodity,
      quantity = result.totalQuantity or 0, price = result.minPrice or 0 }
  end
  House.rows, House.more = rows, not AH.HasFullBrowseResults()
  House.phase = "idle"
  notify(#rows == 0 and "No matching items." or (#rows .. " items. Select one to see its listings."))
end

local function readOffers()
  local item, rows = House.selected, {}
  if not item then return end
  local count = item.commodity and AH.GetNumCommoditySearchResults(item.itemKey.itemID) or AH.GetNumItemSearchResults(item.itemKey)
  for index = 1, count do
    local info
    if item.commodity then info = AH.GetCommoditySearchResultInfo(item.itemKey.itemID, index)
    else info = AH.GetItemSearchResultInfo(item.itemKey, index) end
    if info and info.quantity and info.quantity > 0 then
      local price = item.commodity and info.unitPrice or info.buyoutAmount
      if price and price > 0 then
        rows[#rows + 1] = { auctionID = info.auctionID, quantity = info.quantity, total = price,
          price = item.commodity and price or math.ceil(price / info.quantity), link = info.itemLink,
          owned = info.containsOwnerItem or info.containsAccountItem, ownQuantity = info.numOwnerItems or 0,
          name = item.name, owners = table.concat(info.owners or {}, ", ") }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.price == b.price then return (a.auctionID or 0) < (b.auctionID or 0) end
    return a.price < b.price
  end)
  House.offers = rows
  local complete
  if item.commodity then complete = AH.HasFullCommoditySearchResults(item.itemKey.itemID)
  else complete = AH.HasFullItemSearchResults(item.itemKey) end
  House.more, House.phase = not complete, "idle"
  notify(#rows == 0 and "No buyout listings available." or "Select a listing to review a purchase.")
end

function House.More()
  if not House.more or House.Busy() then return false end
  local item = House.selected
  if House.context == "browse" then
    return send("browse", AH.RequestMoreBrowseResults, "Loading more items...")
  elseif item and item.commodity then
    return send("offers", function() AH.RequestMoreCommoditySearchResults(item.itemKey.itemID) end, "Loading more listings...")
  elseif item then
    return send("offers", function() AH.RequestMoreItemSearchResults(item.itemKey) end, "Loading more listings...")
  end
end

function House.Bags()
  local rows = {}
  if not House.open or not ItemLocation or not AH.IsSellItemValid then return rows end
  for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.hyperlink and not info.isBound and not info.isLocked then
        local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local status = AH.GetItemCommodityStatus(location)
        if AH.IsSellItemValid(location, false) and (status == Enum.ItemCommodityStatus.Item or status == Enum.ItemCommodityStatus.Commodity) then
          local key = AH.GetItemKeyFromItem(location)
          local name = describe(key, info.hyperlink)
          rows[#rows + 1] = { bag = bag, slot = slot, location = location, itemKey = key,
            name = name, link = info.hyperlink, icon = info.iconFileID, quantity = info.stackCount,
            commodity = status == Enum.ItemCommodityStatus.Commodity }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  return rows
end

local function readOwned()
  local rows = {}
  for index = 1, AH.GetNumOwnedAuctions() do
    local info = AH.GetOwnedAuctionInfo(index)
    if info then
      local name, icon = describe(info.itemKey, info.itemLink)
      rows[#rows + 1] = { auctionID = info.auctionID, itemKey = info.itemKey, name = name, icon = icon,
        quantity = info.quantity, total = info.buyoutAmount or 0, link = info.itemLink,
        price = math.ceil((info.buyoutAmount or 0) / math.max(1, info.quantity)),
        timeLeft = info.timeLeft, timeLeftSeconds = info.timeLeftSeconds, status = info.status }
    end
  end
  House.rows, House.phase = rows, "idle"
  notify(#rows == 0 and "You have no auctions." or "Select an auction to review its cancellation.")
end

function House.SetMode(mode)
  if not available() or not House.Dismiss(true) then return false end
  House.mode, House.context, House.selected, House.more = mode, nil, nil, false
  House.rows, House.offers = {}, {}
  if mode == "owned" then
    House.context = "owned"
    return send("owned", function() AH.QueryOwnedAuctions({}) end, "Loading your auctions...")
  elseif mode == "sell" then
    House.rows = House.Bags()
    notify("Select a bag stack. Each post uses at most that stack's quantity.")
  else
    notify("Enter an item name and search the auction house.")
  end
  return true
end

local function currentOffer(id)
  local item = House.selected
  if not item then return end
  for index = 1, AH.GetNumItemSearchResults(item.itemKey) do
    local info = AH.GetItemSearchResultInfo(item.itemKey, index)
    if info and info.auctionID == id then return info end
  end
end

function House.ReviewBuy(offer, quantity)
  if not readyToTrade() or House.Busy() or not House.selected then return false end
  local found = false
  for _, row in ipairs(House.offers) do if row == offer then found = true end end
  if not found or offer.owned then return fail("Choose an available listing from another seller.") end
  local item = House.selected
  if item.commodity then
    local totalAvailable = 0
    for _, row in ipairs(House.offers) do totalAvailable = totalAvailable + row.quantity end
    if not integer(quantity, 1, totalAvailable) then return fail("Enter a quantity within the loaded listings.") end
    review = { kind = "commodity", name = item.name, itemID = item.itemKey.itemID, quantity = quantity }
    begin("quote", "Requesting the current total for " .. quantity .. " " .. item.name .. "...")
    invoke(function() AH.StartCommoditiesPurchase(review.itemID, quantity) end)
  else
    local info = currentOffer(offer.auctionID)
    if not info or info.buyoutAmount ~= offer.total or info.quantity ~= offer.quantity
      or info.containsOwnerItem or info.containsAccountItem then return fail("The listing changed. Search again.") end
    review = { kind = "item", auctionID = offer.auctionID, name = item.name, quantity = info.quantity, total = info.buyoutAmount }
    begin("ready", "Review the quantity and total before buying.")
  end
  return true
end

local function postValid(plan)
  local item = plan.item
  local current = C_Container.GetContainerItemInfo(item.bag, item.slot)
  return current and current.hyperlink == item.link and not current.isLocked and not current.isBound
    and current.stackCount >= plan.quantity and AH.IsSellItemValid(item.location, false)
    and sameKey(AH.GetItemKeyFromItem(item.location), item.itemKey)
end

local function deposit(plan)
  if plan.item.commodity then
    return AH.CalculateCommodityDeposit(plan.item.itemKey.itemID, plan.duration, plan.quantity)
  end
  return AH.CalculateItemDeposit(plan.item.location, plan.duration, plan.quantity)
end

function House.ReviewPost(quantity, unitPrice, duration)
  if not readyToTrade() or House.Busy() or House.mode ~= "sell" or not House.selected then return false end
  local item = House.selected
  if not integer(quantity, 1, item.quantity) or not integer(unitPrice, 1, 999999999999)
    or not integer(duration, 1, 3) or quantity * unitPrice > 999999999999 then
    return fail("Enter a valid quantity, unit price and duration.")
  end
  if not item.commodity and quantity ~= 1 then return fail("Post ordinary items one at a time.") end
  local plan = { kind = "post", item = item, name = item.name, quantity = quantity,
    unitPrice = unitPrice, total = unitPrice * quantity, duration = duration }
  if not postValid(plan) then return fail("The bag stack changed. Select it again.") end
  plan.deposit = deposit(plan)
  if not plan.deposit then return fail("The deposit is not available yet. Try again.") end
  review = plan
  begin("ready", "Review the price, quantity and deposit before posting.")
  return true
end

function House.ReviewCancel()
  if not readyToTrade() or House.Busy() or House.mode ~= "owned" or not House.selected then return false end
  local item = House.selected
  if not AH.CanCancelAuction(item.auctionID) then return fail("That auction can no longer be cancelled. Refresh your auctions.") end
  review = { kind = "cancel", auctionID = item.auctionID, name = item.name, quantity = item.quantity,
    total = AH.GetCancelCost(item.auctionID) or 0 }
  begin("ready", "Cancelling loses the deposit. Returned items arrive by mail.")
  return true
end

function House.Confirm()
  if House.phase ~= "ready" or not review or not readyToTrade() then return false end
  local plan = review
  local cost = plan.kind == "post" and plan.deposit or plan.total
  if not cost or cost > GetMoney() then return fail("You do not have enough gold.") end
  if plan.kind == "commodity" then
    if GetTime() >= plan.expires then return fail("The price quote expired. Review the purchase again.") end
    begin("buy", "Waiting for the purchase confirmation...")
    invoke(function() AH.ConfirmCommoditiesPurchase(plan.itemID, plan.quantity) end)
  elseif plan.kind == "item" then
    local info = currentOffer(plan.auctionID)
    if not info or info.buyoutAmount ~= plan.total or info.quantity ~= plan.quantity
      or info.containsOwnerItem or info.containsAccountItem then return fail("The listing changed. Search again.") end
    begin("buy", "Waiting for the purchase confirmation...")
    invoke(function() AH.PlaceBid(plan.auctionID, plan.total) end)
  elseif plan.kind == "post" then
    if not postValid(plan) or deposit(plan) ~= plan.deposit then return fail("The stack or deposit changed. Review the post again.") end
    begin("post", "Waiting for the posting confirmation...")
    local params, sellFrame
    if plan.item.commodity then
      params = { plan.item.location, plan.duration, plan.quantity, plan.unitPrice }
      sellFrame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
    else
      params = { plan.item.location, plan.duration, plan.quantity, nil, plan.unitPrice }
      sellFrame = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
    end
    local needsConfirmation = invoke(function()
      if plan.item.commodity then return AH.PostCommodity(unpack(params, 1, 4)) end
      return AH.PostItem(unpack(params, 1, 5))
    end)
    if needsConfirmation and sellFrame and sellFrame.CachePendingPost then
      sellFrame:CachePendingPost(unpack(params, 1, plan.item.commodity and 4 or 5))
      notify("Complete the posting warning in the game's auction house.")
    end
  else
    if not AH.CanCancelAuction(plan.auctionID) or (AH.GetCancelCost(plan.auctionID) or 0) ~= plan.total then
      return fail("The cancellation changed. Refresh your auctions.")
    end
    begin("cancel", "Waiting for the cancellation confirmation...")
    invoke(function() AH.CancelAuction(plan.auctionID) end)
  end
  return true
end

local function completed(message)
  serial = serial + 1
  House.phase, review, House.selected, House.offers = "idle", nil, nil, {}
  if House.mode == "sell" then House.rows = House.Bags()
  elseif House.mode == "owned" then readOwned()
  else House.rows, House.context = {}, nil end
  House.completed = (House.completed or 0) + 1
  notify(message)
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE",
  "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED",
  "OWNED_AUCTIONS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_CANCELED",
  "AUCTION_HOUSE_POST_ERROR", "AUCTION_HOUSE_SHOW_ERROR", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
  if not C_EventUtils or C_EventUtils.IsEventValid(event) then frame:RegisterEvent(event) end
end
frame:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "AUCTION_HOUSE_SHOW" then
    House.open = true
    House.session = (House.session or 0) + 1
    notify("Enter an item name and search the auction house.")
  elseif event == "AUCTION_HOUSE_CLOSED" then
    House.open = false
    serial = serial + 1
    House.phase, request, review = "idle", nil, nil
    House.rows, House.offers, House.selected, House.context, House.more = {}, {}, nil, nil, false
    notify("Open the auction house to trade.")
  elseif not House.open then return
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" and request then
    local action = request
    request = nil
    invoke(action)
  elseif House.phase == "browse" and not request and event:match("^AUCTION_HOUSE_BROWSE_RESULTS_") then readBrowse()
  elseif House.phase == "offers" and not request and House.selected
    and (event:match("^COMMODITY_SEARCH_RESULTS_") or event:match("^ITEM_SEARCH_RESULTS_")) then
    local item = House.selected
    if item.commodity and event:match("^COMMODITY_SEARCH_RESULTS_") and arg1 == item.itemKey.itemID then readOffers()
    elseif not item.commodity and event:match("^ITEM_SEARCH_RESULTS_") and sameKey(arg1, item.itemKey) then readOffers() end
  elseif House.phase == "owned" and not request and event == "OWNED_AUCTIONS_UPDATED" then readOwned()
  elseif event == "COMMODITY_PRICE_UPDATED" and review and review.kind == "commodity"
    and (House.phase == "quote" or House.phase == "ready") then
    if not integer(arg1, 1, 999999999999) or not integer(arg2, 1, 999999999999) then fail("No price quote is available."); return end
    review.total, review.unitPrice, review.expires = arg2, arg1, GetTime() + 10
    begin("ready", "Current quote received. Review the total before buying.")
    local quoted = review
    C_Timer.After(10, function()
      if review == quoted and House.phase == "ready" and GetTime() >= quoted.expires then fail("The price quote expired. Review the purchase again.") end
    end)
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" and review and review.kind == "commodity" and not transaction() then
    fail("The requested quantity is no longer available. Search again.")
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and House.phase == "buy" and review.kind == "commodity" then
    completed("Purchase confirmed. Collect your items from the mailbox.")
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and House.phase == "buy" and review.auctionID == arg1 then
    completed("Purchase confirmed. Collect your items from the mailbox.")
  elseif event == "AUCTION_HOUSE_AUCTION_CREATED" and House.phase == "post" then completed("Auction posted.")
  elseif event == "AUCTION_CANCELED" and House.phase == "cancel" and review.auctionID == arg1 then
    completed("Auction cancelled. Returned items arrive by mail.")
  elseif (event == "COMMODITY_PURCHASE_FAILED" and House.phase == "buy")
    or (event == "AUCTION_HOUSE_POST_ERROR" and House.phase == "post")
    or (event == "AUCTION_HOUSE_BROWSE_FAILURE" and House.phase == "browse")
    or (event == "AUCTION_HOUSE_SHOW_ERROR" and House.Busy()) then
    fail("The auction house rejected the request. Check the game's error message and refresh.")
  elseif event == "BAG_UPDATE_DELAYED" and House.mode == "sell" and not transaction() then
    House.Dismiss()
    House.selected, House.rows = nil, House.Bags()
    notify("Bags updated. Select a stack to sell.")
  elseif event == "PLAYER_MONEY" then notify()
  elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" and House.phase == "idle" and House.context == "browse" then readBrowse() end
end)

-- All addons share Blizzard's result cache. A query from another window
-- invalidates our selection instead of making its results actionable here.
for _, name in ipairs({ "SendBrowseQuery", "SendSearchQuery", "SendSellSearchQuery", "ReplicateItems",
  "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "PlaceBid", "PostItem", "PostCommodity", "CancelAuction" }) do
  if AH[name] then
    hooksecurefunc(AH, name, function()
      if issuing or not House.open then return end
      House.external = (House.external or 0) + 1
      if transaction() then return end
      -- Another purchaser now owns the quote, so do not cancel its request.
      if name == "StartCommoditiesPurchase" then review = nil end
      House.Dismiss()
      House.selected, House.context, House.more = nil, nil, false
      House.rows, House.offers = {}, {}
      notify("Another auction window made a request. Search or refresh here to continue.")
    end)
  end
end
