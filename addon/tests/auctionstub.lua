-- The modern AH boundary used by auctionhouse.lua and the visual preview.
return function(Stub)
  local AH = C_AuctionHouse
  local server = { offers = {}, owned = {}, calls = {}, quote = { 125, 500 }, complete = true, silent = false }
  Enum.ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 }
  ItemLocation = {}
  local function info(location) return C_Container.GetContainerItemInfo(location.bagID, location.slotIndex) end
  function ItemLocation:CreateFromBagAndSlot(bag, slot)
    return { bagID = bag, slotIndex = slot,
      IsBagAndSlot = function() return true end,
      IsValid = function(self) return info(self) ~= nil end,
      GetBagAndSlot = function(self) return self.bagID, self.slotIndex end }
  end
  function AH.IsSellItemValid(location) local item = info(location); return item and not item.isBound end
  function AH.GetItemKeyFromItem(location)
    local item = info(location)
    return item and { itemID = item.itemID, itemLevel = item.level or 0, itemSuffix = item.suffix or 0, battlePetSpeciesID = item.species or 0 }
  end
  function AH.GetItemCommodityStatus(location)
    local item = info(location)
    return item and item.commodity and 2 or 1
  end
  local function record(name, ...)
    server.calls[#server.calls + 1] = { name = name, args = { ... } }
  end
  function HideUIPanel(frame) frame:Hide() end
  function AH.CloseAuctionHouse()
    record("close")
    Stub.fire("AUCTION_HOUSE_CLOSED")
  end
  AuctionHouseFrame:SetScript("OnHide", AH.CloseAuctionHouse)
  local fire = Stub.fire
  function Stub.fire(event, ...)
    if event == "AUCTION_HOUSE_SHOW" then AuctionHouseFrame:Show()
    elseif event == "AUCTION_HOUSE_CLOSED" then AuctionHouseFrame.shown = false end
    fire(event, ...)
  end
  local function query(event, key)
    if server.silent then return end
    Stub.ah.ready = false
    C_Timer.After(0.05, function() Stub.fire(event, key) end)
    C_Timer.After(0.1, function() Stub.ah.ready = true; Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY") end)
  end
  function AH.SendSearchQuery(key)
    record("search", key)
    local data = AH.GetItemKeyInfo(key)
    query(data and data.isCommodity and "COMMODITY_SEARCH_RESULTS_UPDATED" or "ITEM_SEARCH_RESULTS_UPDATED", data and data.isCommodity and key.itemID or key)
  end
  function AH.GetNumCommoditySearchResults(id) return #(server.offers[id] or {}) end
  function AH.GetCommoditySearchResultInfo(id, index) return (server.offers[id] or {})[index] end
  function AH.GetNumItemSearchResults(key) return #(server.offers[key.itemID] or {}) end
  function AH.GetItemSearchResultInfo(key, index) return (server.offers[key.itemID] or {})[index] end
  function AH.HasFullCommoditySearchResults() return server.complete end
  function AH.HasFullItemSearchResults() return server.complete end
  function AH.RequestMoreCommoditySearchResults(id) server.complete = true; query("COMMODITY_SEARCH_RESULTS_ADDED", id) end
  function AH.RequestMoreItemSearchResults(key) server.complete = true; query("ITEM_SEARCH_RESULTS_ADDED", key) end
  function AH.QueryOwnedAuctions() record("owned"); query("OWNED_AUCTIONS_UPDATED") end
  function AH.GetNumOwnedAuctions() return #server.owned end
  function AH.GetOwnedAuctionInfo(index) return server.owned[index] end
  function AH.CanCancelAuction(id)
    for _, item in ipairs(server.owned) do if item.auctionID == id then return item.status == 0 end end
    return false
  end
  function AH.GetCancelCost() return server.cancelCost or 0 end
  function AH.CancelAuction(id) record("cancel", id) end
  function AH.CalculateCommodityDeposit() return server.deposit or 100 end
  function AH.CalculateItemDeposit() return server.deposit or 100 end
  function AH.StartCommoditiesPurchase(id, quantity)
    record("quote", id, quantity)
    if not server.silent then C_Timer.After(0.1, function() Stub.fire("COMMODITY_PRICE_UPDATED", unpack(server.quote)) end) end
  end
  function AH.CancelCommoditiesPurchase() record("release-quote") end
  function AH.ConfirmCommoditiesPurchase(id, quantity) record("buy-commodity", id, quantity) end
  function AH.PlaceBid(id, total) record("buy-item", id, total) end
  function AH.PostCommodity(location, duration, quantity, price) record("post-commodity", location, duration, quantity, price); return server.warning end
  function AH.PostItem(location, duration, quantity, bid, buyout) record("post-item", location, duration, quantity, bid, buyout); return server.warning end
  function server.count(name)
    local count = 0
    for _, call in ipairs(server.calls) do if call.name == name then count = count + 1 end end
    return count
  end
  function C_Item.GetItemIconByID(id)
    for key, item in pairs(Stub.ah.keyInfo) do if tonumber(key:match("^(%d+)")) == id then return item.iconFileID end end
  end
  function C_Item.GetItemInfoInstant(id)
    local item = Stub.items[id]
    if not item then return end
    return id, nil, nil, nil, C_Item.GetItemIconByID(id), item.classID or 7, item.subClassID or 0
  end
  function C_Item.GetItemInventoryTypeByID(id) return Stub.items[id] and Stub.items[id].inventoryType end
  AuctionCategories = {
    { name = "Weapons", filters = { { classID = 2 } }, subCategories = {
      { name = "Daggers", filters = { { classID = 2, subClassID = 15 } } },
      { name = "One-Handed Swords", filters = { { classID = 2, subClassID = 7 } } },
    } },
    { name = "Armor", filters = { { classID = 4 } }, subCategories = {
      { name = "Cloth", filters = { { classID = 4, subClassID = 1 } }, subCategories = {
        { name = "Chest", filters = { { classID = 4, subClassID = 1, inventoryType = 5 }, { classID = 4, subClassID = 1, inventoryType = 20 } } },
        { name = "Head", filters = { { classID = 4, subClassID = 1, inventoryType = 1 } } },
      } },
    } },
    { name = "Trade Goods", filters = { { classID = 7 } } },
  }
  function server.cache(ns)
    local rows, names = {}, {}
    for _, item in ipairs(Stub.ah.browse) do
      local key = ns.Codec.ItemKey(item.itemKey.itemID, item.itemKey.itemSuffix)
      local info = AH.GetItemKeyInfo(item.itemKey) or {}
      rows[#rows + 1] = { key = key, min = item.minPrice, mv = item.minPrice, qty = item.totalQuantity, n = 1 }
      names[key] = { name = info.itemName or ("Item " .. item.itemKey.itemID), quality = info.quality or 1 }
    end
    ns.db.prices[ns.RealmKey()] = {}
    ns.Database.ApplyScan(ns.db, { realm = "Faramon", faction = "Horde", region = "EU", by = "Test", build = "1", at = time(), mode = "browse",
      rows = rows, names = names })
  end
  function server.seed()
    for bag = 1, 4 do Stub.bags[bag] = nil end
    Stub.money = 5000000
    Stub.items[2770] = { name = "Copper Ore", quality = 1, vendor = 5, cached = true }
    Stub.items[2771] = { name = "Tin Ore", quality = 1, vendor = 5, cached = true }
    Stub.items[1206] = { name = "Moss Agate", quality = 2, vendor = 50, cached = true }
    Stub.ah.keyInfo["2770:0"] = { itemName = "Copper Ore", quality = 1, isCommodity = true, iconFileID = 134566 }
    Stub.ah.keyInfo["2771:0"] = { itemName = "Tin Ore", quality = 1, isCommodity = true, iconFileID = 134579 }
    Stub.ah.keyInfo["1206:0"] = { itemName = "Moss Agate", quality = 2, isCommodity = false, iconFileID = 134105 }
    Stub.ah.browse = {
      { itemKey = { itemID = 2770 }, minPrice = 125, totalQuantity = 50 },
      { itemKey = { itemID = 1206 }, minPrice = 50000, totalQuantity = 2 },
      { itemKey = { itemID = 2771 }, minPrice = 250, totalQuantity = 60 },
    }
    server.offers[2770] = { { unitPrice = 125, quantity = 20, numOwnerItems = 0, owners = { "Miner" } },
      { unitPrice = 150, quantity = 30, numOwnerItems = 0, owners = { "Prospector" } } }
    server.offers[1206] = { { auctionID = 101, itemKey = { itemID = 1206 }, buyoutAmount = 100000, quantity = 2, owners = { "Jeweller" } } }
    server.offers[2771] = { { unitPrice = 250, quantity = 60, numOwnerItems = 0, owners = { "Miner" } } }
    server.owned = { { auctionID = 201, itemKey = { itemID = 2770 }, quantity = 3, buyoutAmount = 600, timeLeft = 3, status = 0 } }
    Stub.bags[0] = { slots = 3,
      { itemID = 2770, hyperlink = "|Hitem:2770|h[Copper Ore]|h", stackCount = 12, commodity = true },
      { itemID = 1206, hyperlink = "|Hitem:1206|h[Moss Agate]|h", stackCount = 2 },
      { itemID = 2771, hyperlink = "|Hitem:2771|h[Tin Ore]|h", stackCount = 8, commodity = true },
    }
  end
  function server.seedVariants()
    server.seed()
    Stub.items[15241] = { name = "Battle Knife", quality = 2, cached = true, classID = 2, subClassID = 15 }
    Stub.ah.pageSize, Stub.ah.browse = 50, {}
    for index = 1, 3 do
      local key = { itemID = 15241, itemSuffix = 100 + index, itemLevel = 20 + index, battlePetSpeciesID = 0 }
      Stub.ah.browse[index] = { itemKey = key, minPrice = index * 100, totalQuantity = index }
      Stub.ah.keyInfo["15241:" .. key.itemSuffix] = { itemName = "Battle Knife of " .. ({ "Strength", "Agility", "Stamina" })[index],
        quality = 2, iconFileID = 135641, isCommodity = false }
    end
    Stub.ah.browse[4] = { itemKey = { itemID = 2770 }, minPrice = 125, totalQuantity = 20 }
    server.offers[15241] = { { auctionID = 555, quantity = 1, buyoutAmount = 200 } }
  end
  return server
end
