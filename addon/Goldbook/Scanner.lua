local _, ns = ...
local Codec, Stats = ns.Codec, ns.Stats

-- One scan at a time: idle -> scanning -> idle. Listeners hear "progress"
-- while it runs and exactly one "done" or "fail" when it ends. A start that
-- is turned down is a "refused" and leaves any running scan alone. `run`
-- changes whenever a scan starts or ends, so a timer left over from an
-- earlier scan can tell it is stale.
local Scanner = { state = "idle", open = false, run = 0 }
ns.Scanner = Scanner

local REPLICATE_COOLDOWN = 15 * 60
local STALL_TIMEOUT = 60
-- The full list is one answer, which a large realm takes a while to assemble.
local REPLICATE_TIMEOUT = 180
local BATCH = 500
local LINK_RETRIES = 10
local LINK_RETRY_DELAY = 0.5
local BROWSE_NAME_TIMEOUT = 3
local QUALITY_FILTERS = {
  "PoorQuality",
  "CommonQuality",
  "UncommonQuality",
  "RareQuality",
  "EpicQuality",
  "LegendaryQuality",
  "ArtifactQuality",
}

local frame = CreateFrame("Frame")
local subscribers = {}
local MODES = {}
local job

function Scanner.Subscribe(listener)
  subscribers[#subscribers + 1] = listener
end

local function notify(kind, payload)
  for _, listener in ipairs(subscribers) do
    listener(kind, payload)
  end
end

function Scanner.Identity()
  local version, build = GetBuildInfo()
  return {
    realm = GetNormalizedRealmName() or GetRealmName(),
    faction = UnitFactionGroup("player") or "Neutral",
    region = GetCurrentRegionName and GetCurrentRegionName() or "",
    by = UnitName("player"),
    build = version .. "." .. build,
  }
end

local function stop()
  for event in pairs(MODES[job.mode].on) do
    frame:UnregisterEvent(event)
  end
  Scanner.state = "idle"
  Scanner.run = Scanner.run + 1
  job = nil
end

local function fail(reason)
  stop()
  notify("fail", reason)
end

local function finish(rows, names)
  if #rows == 0 then
    fail("the auction house returned no items")
    return
  end
  local scan = Scanner.Identity()
  scan.at = job.at or time()
  scan.mode = job.mode
  scan.rows = rows
  scan.names = names
  scan.skipped = job.skipped or 0
  scan.samples = job.samples
  scan.orderBooks = job.mode == "replicate" and job.listings or nil
  scan.incompleteItems = job.incompleteItems
  stop()
  notify("done", scan)
end

-- Called on every sign of life; the scan fails if none follows in time.
local function touch(progress, timeout)
  local run = Scanner.run
  job.beat = job.beat + 1
  local beat = job.beat
  C_Timer.After(timeout or STALL_TIMEOUT, function()
    if Scanner.run == run and job.beat == beat then
      fail("the auction house stopped responding")
    end
  end)
  if progress then
    notify("progress", progress)
  end
end

-- Auction house requests are dropped while the client throttles them.
local function whenReady(request)
  if C_AuctionHouse.IsThrottledMessageSystemReady() then
    request()
  else
    job.deferred = request
  end
end

local function runDeferred()
  local request = job.deferred
  if request then
    job.deferred = nil
    request()
  end
end

local function browseQuery()
  local filters = {}
  for _, name in ipairs(QUALITY_FILTERS) do
    local filter = Enum.AuctionHouseFilter[name]
    if filter then
      filters[#filters + 1] = filter
    end
  end
  return {
    searchString = "",
    sorts = {
      { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
      { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
    },
    filters = filters,
  }
end

-- Only its item key names a random-suffix variant; C_Item.GetItemInfo gives
-- the base item's name. The call answers nil until the client has the info,
-- which the call requests, so each page asks as it arrives.
local function variantInfo(result)
  local suffix = result.itemKey.itemSuffix
  if suffix and suffix ~= 0 then
    return C_AuctionHouse.GetItemKeyInfo(result.itemKey)
  end
end

local function resolveBrowseNames(itemID)
  if not job.pendingNames then
    return
  end
  for key, result in pairs(job.pendingNames) do
    if result.itemKey.itemID == itemID then
      local info = variantInfo(result)
      if info and info.itemName then
        job.names[key] = { name = info.itemName, quality = info.quality }
        job.pendingNames[key] = nil
      end
    end
  end
  if next(job.pendingNames) == nil then
    finish(job.rows, job.names)
  end
end

local function finishBrowse()
  local rows, byKey, names, pending = {}, {}, {}, {}
  for _, result in ipairs(C_AuctionHouse.GetBrowseResults()) do
    if result.minPrice > 0 and result.totalQuantity > 0 then
      local key = Codec.ItemKey(result.itemKey.itemID, result.itemKey.itemSuffix)
      local row = byKey[key]
      if not row then
        row = { key = key, min = result.minPrice, mv = 0, qty = 0, n = 0 }
        byKey[key] = row
        rows[#rows + 1] = row
      end
      row.min = math.min(row.min, result.minPrice)
      row.qty = row.qty + result.totalQuantity
      local info = variantInfo(result)
      if info and info.itemName then
        names[key] = { name = info.itemName, quality = info.quality }
      elseif result.itemKey.itemSuffix and result.itemKey.itemSuffix ~= 0 then
        pending[key] = result
      end
    end
  end
  if next(pending) == nil then
    finish(rows, names)
    return
  end
  job.rows, job.names, job.pendingNames = rows, names, pending
  -- Keep the time the prices arrived while the final page's names load.
  job.at = time()
  touch("loading item names")
  local run = Scanner.run
  C_Timer.After(BROWSE_NAME_TIMEOUT, function()
    if Scanner.run == run then
      finish(job.rows, job.names)
    end
  end)
end

-- Pages that arrive before the scan's own query was answered belong to a
-- search the player made.
local function browsePage(loaded, fresh)
  if not job.answered then
    return
  end
  job.loaded = loaded
  for _, result in ipairs(fresh) do
    variantInfo(result)
  end
  touch(loaded .. " items")
  if C_AuctionHouse.HasFullBrowseResults() then
    finishBrowse()
  else
    whenReady(C_AuctionHouse.RequestMoreBrowseResults)
  end
end

-- Summary scan: one row per item with its lowest price and total quantity.
MODES.browse = {
  start = function()
    whenReady(function()
      job.sent = true
      C_AuctionHouse.SendBrowseQuery(browseQuery())
    end)
  end,
  on = {
    -- A fresh result set answers a new query: the scan's own, or later a
    -- search that replaced it, whose pages would otherwise be saved as the scan.
    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function()
      if job.answered then
        fail("another search replaced the scan; scan again")
      elseif job.sent then
        job.answered = true
        local results = C_AuctionHouse.GetBrowseResults()
        browsePage(#results, results)
      end
    end,
    AUCTION_HOUSE_BROWSE_RESULTS_ADDED = function(added)
      browsePage(job.loaded + #added, added)
    end,
    AUCTION_HOUSE_BROWSE_FAILURE = function()
      fail("the auction house rejected the query")
    end,
    AUCTION_HOUSE_THROTTLED_SYSTEM_READY = runDeferred,
    ITEM_KEY_ITEM_INFO_RECEIVED = resolveBrowseNames,
  },
}

local function addListing(key, name, quality, buyout, count, owner)
  local listings = job.listings[key]
  if not listings then
    listings = {}
    job.listings[key] = listings
    if name then
      job.names[key] = { name = name, quality = quality }
    end
  end
  listings[#listings + 1] = { price = math.ceil(buyout / count), count = count, owner = owner }
end

-- A listing of a random-suffix variant whose suffix could not be read is
-- left out: filed under the base item it would mix the variants' prices.
-- A few such links are kept so the link format can be checked.
local SAMPLES = 5

local function skip(link, itemID)
  job.incompleteItems[itemID] = true
  job.skipped = job.skipped + 1
  if link and #job.samples < SAMPLES then
    job.samples[#job.samples + 1] = link
  end
end

-- The suffixes quick scans have seen, per item id.
local function knownSuffixes()
  local identity = Scanner.Identity()
  local suffixes = {}
  for key in pairs(ns.db.prices[ns.Database.RealmKey(identity.realm, identity.faction)] or {}) do
    local itemID, suffix = key:match("^(%d+):(%-?%d+)$")
    if itemID then
      itemID = tonumber(itemID)
      suffixes[itemID] = suffixes[itemID] or {}
      suffixes[itemID][tonumber(suffix)] = true
    end
  end
  return suffixes
end

-- Returns false and the item id while the listing cannot be filed yet: its
-- link, which carries the suffix, or its base item's name, which tells a
-- variant apart, has not loaded. With `final` a listing without a link falls
-- back to its bare item id, unless the item is known to come in variants.
local function readListing(index, final)
  local _, _, count, quality, _, _, _, _, _, buyout, _, _, _, owner, ownerFullName, _, itemID, hasAllInfo =
    C_AuctionHouse.GetReplicateItemInfo(index)
  if not itemID or itemID == 0 or count == 0 or buyout == 0 then
    return true
  end
  owner = ownerFullName and ownerFullName ~= "" and ownerFullName or owner
  local link = hasAllInfo and C_AuctionHouse.GetReplicateItemLink(index)
  if link then
    local key = Codec.KeyFromLink(link, job.suffixes[itemID]) or Codec.ItemKey(itemID)
    local name = link:match("%[(.-)%]")
    if key:find(":") then
      addListing(key, name, quality, buyout, count, owner)
      return true
    end
    -- Named unlike its base item, the listing is a variant whose suffix
    -- could not be read.
    local baseName = C_Item.GetItemInfo(itemID)
    if not baseName and not final then
      return false, itemID
    end
    if baseName and name == baseName then
      addListing(key, name, quality, buyout, count, owner)
    else
      skip(link, itemID)
    end
    return true
  end
  if final then
    if job.suffixes[itemID] then
      skip(nil, itemID)
    else
      addListing(Codec.ItemKey(itemID), nil, nil, buyout, count, owner)
    end
    return true
  end
  return false, itemID
end

local function finishReplicate()
  local rows = {}
  for key, listings in pairs(job.listings) do
    local row = Stats.Summarize(listings)
    row.key = key
    rows[#rows + 1] = row
  end
  finish(rows, job.names)
end

local function later(delay, step)
  local run = Scanner.run
  C_Timer.After(delay, function()
    if Scanner.run == run then
      step()
    end
  end)
end

-- Re-reads the listings whose links were still loading, a batch per frame.
local function resolvePending(retries, from, waiting)
  local to = math.min(from + BATCH - 1, #job.pending)
  for position = from, to do
    local index = job.pending[position]
    if not readListing(index, retries == 0) then
      waiting[#waiting + 1] = index
    end
  end
  if to < #job.pending then
    later(0, function()
      resolvePending(retries, to + 1, waiting)
    end)
    return
  end
  job.pending = waiting
  if #waiting == 0 then
    finishReplicate()
    return
  end
  touch("loading " .. #waiting .. " items")
  later(LINK_RETRY_DELAY, function()
    resolvePending(retries - 1, 1, {})
  end)
end

local function collect(from, total)
  local to = math.min(from + BATCH, total)
  for index = from, to - 1 do
    local read, itemID = readListing(index, false)
    if not read then
      job.pending[#job.pending + 1] = index
      C_Item.RequestLoadItemDataByID(itemID)
    end
  end
  touch(to .. " / " .. total .. " auctions")
  if to == total then
    resolvePending(LINK_RETRIES, 1, {})
    return
  end
  later(0, function()
    collect(to, total)
  end)
end

-- Full dump: every auction, so each item gets a market value. The server
-- allows one per 15 minutes per account.
MODES.replicate = {
  refuse = function()
    local wait = (ns.db.settings.lastReplicate or 0) + REPLICATE_COOLDOWN - time()
    if wait > 0 then
      return "a full scan is available again in " .. math.ceil(wait / 60) .. " min"
    end
  end,
  timeout = REPLICATE_TIMEOUT,
  start = function()
    job.listings, job.names, job.pending = {}, {}, {}
    job.suffixes, job.skipped, job.samples = knownSuffixes(), 0, {}
    job.incompleteItems = {}
    C_AuctionHouse.ReplicateItems()
  end,
  on = {
    REPLICATE_ITEM_LIST_UPDATE = function()
      -- Fires again for every item that loads afterwards.
      frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
      -- A request the server ignored should not cost the cooldown.
      ns.db.settings.lastReplicate = time()
      collect(0, C_AuctionHouse.GetNumReplicateItems())
    end,
  },
}

function Scanner.Start(mode)
  local definition = MODES[mode]
  local refusal
  if Scanner.state ~= "idle" then
    refusal = "a scan is already running"
  elseif not Scanner.open then
    refusal = "open the auction house first"
  elseif definition.refuse then
    refusal = definition.refuse()
  end
  if refusal then
    notify("refused", refusal)
    return
  end

  Scanner.state = "scanning"
  Scanner.run = Scanner.run + 1
  job = { mode = mode, beat = 0, loaded = 0 }
  for event in pairs(definition.on) do
    frame:RegisterEvent(event)
  end
  touch("starting", definition.timeout)
  definition.start()
end

frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "AUCTION_HOUSE_SHOW" then
    Scanner.open = true
  elseif event == "AUCTION_HOUSE_CLOSED" then
    Scanner.open = false
    if job then
      fail("the auction house was closed")
    end
  elseif job then
    local handler = MODES[job.mode].on[event]
    if handler then
      handler(...)
    end
  end
end)
