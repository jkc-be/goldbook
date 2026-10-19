-- The modern AH boundary used by auctionhouse.lua and the visual preview.
return function(Stub)
  local AH = C_AuctionHouse
  local server = { offers = {}, owned = {}, calls = {}, quote = { 125, 500 }, complete = true, silent = false }
  Enum.ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 }
  ItemLocation = {}
  function ItemLocation:CreateFromBagAndSlot(bag, slot) return { bagID = bag, slotIndex = slot } end
  local function info(location) return C_Container.GetContainerItemInfo(location.bagID, location.slotIndex) end
  function AH.IsSellItemValid(location) local item = info(location); return item and not item.isBound end
  function AH.GetItemKeyFromItem(location)
    local item = info(location)
    return item and { itemID = item.itemID, itemLevel = 0, itemSuffix = item.suffix or 0, battlePetSpeciesID = 0 }
  end
  function AH.GetItemCommodityStatus(location)
    local item = info(location)
    return item and item.commodity and 2 or 1
  end
  local function record(name, ...)
    server.calls[#server.calls + 1] = { name = name, args = { ... } }
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
  function server.seed()
    for bag = 1, 4 do Stub.bags[bag] = nil end
    Stub.money = 5000000
    Stub.items[2770] = { name = "Copper Ore", quality = 1, vendor = 5, cached = true }
    Stub.items[2771] = { name = "Tin Ore", quality = 1, vendor = 5, cached = true }
    Stub.items[1206] = { name = "Moss Agate", quality = 2, vendor = 50, cached = true }
    Stub.ah.keyInfo["2770:0"] = { itemName = "Copper Ore", quality = 1, isCommodity = true }
    Stub.ah.keyInfo["2771:0"] = { itemName = "Tin Ore", quality = 1, isCommodity = true }
    Stub.ah.keyInfo["1206:0"] = { itemName = "Moss Agate", quality = 2, isCommodity = false }
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
  return server
end
