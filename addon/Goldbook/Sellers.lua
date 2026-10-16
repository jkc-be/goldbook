local _, ns = ...
local AH = C_AuctionHouse
local frame = CreateFrame("Frame")
local pending = {}
local MAX_SNAPSHOTS, MAX_OFFERS = 10000, 50000
local MAX_SAVED_OFFERS = 200000
local MAX_AGE = 14 * 24 * 3600

local function offer(result, commodity)
  if not result or not result.quantity or result.quantity <= 0 then
    return nil
  end
  local price = commodity and result.unitPrice or result.buyoutAmount
  if not price or price <= 0 then
    return nil
  end
  local owners, seen = {}, {}
  for _, name in ipairs(result.owners or {}) do
    if name == "player" then
      name = UnitName("player") .. "-" .. (GetNormalizedRealmName() or GetRealmName())
    end
    if name ~= "" and not seen[name] then
      owners[#owners + 1], seen[name] = name, true
    end
  end
  table.sort(owners)
  return {
    unitPrice = commodity and price or math.ceil(price / result.quantity),
    quantity = result.quantity,
    owners = owners,
    totalOwners = math.max(result.totalNumberOfOwners or 0, #owners),
  }
end

local function saveSnapshot(snapshot)
  local saved = ns.db.sellerScans
  local id = snapshot.realm .. "|" .. snapshot.faction .. "|" .. snapshot.itemKey .. "|" .. snapshot.scannedAt
  local suffix, base = 0, id
  while saved[id] do
    suffix = suffix + 1
    id = base .. "|" .. string.format("%06d", suffix)
  end
  saved[id] = snapshot
end

local function pruneSnapshots()
  local saved = ns.db.sellerScans

  local kept = {}
  for id, scan in pairs(saved) do
    if time() - scan.scannedAt > MAX_AGE then
      saved[id] = nil
    else
      kept[#kept + 1] = { id = id, at = scan.scannedAt, offers = #scan.offers }
    end
  end
  table.sort(kept, function(a, b)
    if a.at == b.at then return a.id > b.id end
    return a.at > b.at
  end)
  local totalOffers = 0
  for index, entry in ipairs(kept) do
    totalOffers = totalOffers + entry.offers
    if index > MAX_SNAPSHOTS or totalOffers > MAX_SAVED_OFFERS then
      saved[entry.id] = nil
    end
  end
end

local function capture(item, commodity)
  if not ns.db or not ns.Scanner.open then
    return
  end
  local complete = commodity and AH.HasFullCommoditySearchResults(item) or
    (not commodity and AH.HasFullItemSearchResults(item))
  if not complete then
    return
  end
  local count = commodity and AH.GetNumCommoditySearchResults(item) or AH.GetNumItemSearchResults(item)
  if count > MAX_OFFERS then
    return
  end
  local offers = {}
  for index = 1, count do
    local result = commodity and AH.GetCommoditySearchResultInfo(item, index) or
      (not commodity and AH.GetItemSearchResultInfo(item, index))
    -- A missing row means the snapshot is not ready yet.
    if not result then
      return
    end
    local row = offer(result, commodity)
    if row then
      offers[#offers + 1] = row
    end
  end
  local identity = ns.Scanner.Identity()
  local key = commodity and ns.Codec.ItemKey(item) or ns.Codec.ItemKey(item.itemID, item.itemSuffix)
  local snapshot = {
    realm = identity.realm, faction = identity.faction, itemKey = key,
    scannedAt = time(), offers = offers,
  }
  saveSnapshot(snapshot)
  pruneSnapshots()
end

for _, event in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED" }) do
  frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, item)
  local commodity = event:find("COMMODITY", 1, true) ~= nil
  if not item then
    return
  end
  local key = commodity and tostring(item) or ns.Codec.ItemKey(item.itemID, item.itemSuffix)
  local request = {}
  pending[key] = request
  -- Let seller names arrive, and combine the update events for the same search.
  C_Timer.After(1, function()
    if pending[key] == request then
      pending[key] = nil
      capture(item, commodity)
    end
  end)
end)


ns.Scanner.Subscribe(function(kind, scan)
  if kind ~= "done" or not scan.orderBooks or not ns.db then return end
  local books, skipped = 0, 0
  local seen = {}
  for key, listings in pairs(scan.orderBooks) do
    if not scan.incompleteItems[ns.Codec.BaseID(key)] then
      local grouped, offers = {}, {}
      for _, listing in ipairs(listings) do
        local owner = listing.owner or ""
        if owner == "player" then owner = scan.by .. "-" .. scan.realm end
        grouped[listing.price] = grouped[listing.price] or {}
        local row = grouped[listing.price][owner]
        if not row then
          row = { unitPrice = listing.price, quantity = 0,
            owners = owner ~= "" and { owner } or {}, totalOwners = owner ~= "" and 1 or 0 }
          grouped[listing.price][owner] = row
          offers[#offers + 1] = row
        end
        row.quantity = row.quantity + listing.count
      end
      if #offers <= MAX_OFFERS then
        saveSnapshot({ realm = scan.realm, faction = scan.faction, itemKey = key,
          scannedAt = scan.at, offers = offers })
        books, seen[key] = books + 1, true
      else
        skipped = skipped + 1
      end
    else
      skipped = skipped + 1
    end
  end
  -- Only a scan without unresolved listings can establish that an item disappeared.
  if scan.skipped == 0 then
    local absent = {}
    for _, old in pairs(ns.db.sellerScans) do
      if old.realm == scan.realm and old.faction == scan.faction
        and not scan.orderBooks[old.itemKey] and not seen[old.itemKey] then
        absent[old.itemKey] = true
      end
    end
    for key in pairs(absent) do
      saveSnapshot({ realm = scan.realm, faction = scan.faction, itemKey = key,
        scannedAt = scan.at, offers = {} })
      books = books + 1
    end
  end
  pruneSnapshots()
  scan.bookCount, scan.bookSkipped = books, skipped
  scan.orderBooks, scan.incompleteItems = nil, nil
end)
