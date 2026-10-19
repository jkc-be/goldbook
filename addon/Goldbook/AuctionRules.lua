local _, ns = ...
local House, Database = ns.AuctionHouse, ns.Database
local Rules = { queue = {}, running = false, message = "Create a group and save its posting rules." }
ns.AuctionRules = Rules
local generation, job, waiting, executing = 0, nil, false, nil
local listeners = {}

local function notify(message)
  if message then Rules.message = message end
  for _, listener in ipairs(listeners) do listener() end
end

function Rules.Subscribe(listener)
  listeners[#listeners + 1] = listener
end

function Rules.Saved()
  return ns.db.settings.auctionRules or {}
end

-- Price expressions are deliberately data, never Lua. A fixed gold amount,
-- coin amounts, or a percentage of one named source is enough for each bound.
function Rules.Price(expression, sources)
  local text = tostring(expression or ""):lower():match("^%s*(.-)%s*$")
  local percent, source = text:match("^(%d+%.?%d*)%%%s*(%a+)$")
  local value
  if percent then
    if source ~= "market" and source ~= "vendor" and source ~= "minbuyout" then return nil end
    if not sources[source] or sources[source] <= 0 then return nil end
    value = tonumber(percent) / 100 * sources[source]
  elseif tonumber(text) then value = tonumber(text) * 10000
  else
    local rest, amount = text, 0
    local seen = {}
    while rest ~= "" do
      local number, coin, tail = rest:match("^(%d+)%s*([gsc])%s*(.*)$")
      if not number or seen[coin] then return nil end
      seen[coin] = true
      amount = amount + tonumber(number) * ({ g = 10000, s = 100, c = 1 })[coin]
      rest = tail
    end
    value = amount
  end
  if not value or value ~= value or value <= 0 or value > 999999999999 then return nil end
  return math.floor(value + 0.5)
end

function Rules.Save(input)
  local name = (input.name or ""):match("^%s*(.-)%s*$")
  if name == "" or #name > 40 then return false, "Give the group a name of at most 40 characters." end
  local ids, seen = {}, {}
  local text = tostring(input.items or "")
  if text:find("[^%d,%s]") then return false, "Enter item IDs separated by spaces or commas." end
  for word in text:gmatch("%d+") do
    local id = tonumber(word)
    if id < 1 or id > 2147483647 then return false, "An item ID is outside the supported range." end
    if not seen[id] then ids[#ids + 1], seen[id] = id, true end
  end
  if #ids == 0 or #ids > 200 then return false, "A group needs between 1 and 200 item IDs." end
  local rule = { name = name, items = ids, minimum = input.minimum, normal = input.normal, maximum = input.maximum,
    shopping = input.shopping, below = input.below or "skip", above = input.above or "normal" }
  for _, field in ipairs({ "minimum", "normal", "maximum", "shopping" }) do
    if not Rules.Price(rule[field], { market = 10000, vendor = 10000, minbuyout = 10000 }) then
      return false, "Use gold, coin amounts, or a percentage of market, vendor or minbuyout."
    end
  end
  for field, range in pairs({ cap = { 1, 10000 }, stack = { 1, 1000 }, duration = { 1, 3 }, undercut = { 0, 1000000 } }) do
    local value = tonumber(input[field])
    if not value or value % 1 ~= 0 or value < range[1] or value > range[2] then return false, "Invalid " .. field .. "." end
    rule[field] = value
  end
  if rule.below ~= "skip" and rule.below ~= "minimum" and rule.below ~= "normal" then return false, "Invalid below-minimum rule." end
  if rule.above ~= "normal" and rule.above ~= "maximum" then return false, "Invalid above-maximum rule." end
  local saved, replacement = Rules.Saved(), {}
  for _, existing in ipairs(saved) do
    if existing.name ~= name then
      for _, id in ipairs(existing.items) do
        if seen[id] then return false, "Item " .. id .. " already belongs to " .. existing.name .. "." end
      end
      replacement[#replacement + 1] = existing
    end
  end
  replacement[#replacement + 1] = rule
  table.sort(replacement, function(a, b) return a.name < b.name end)
  ns.db.settings.auctionRules = replacement
  Rules.queue = {}
  notify("Saved " .. name .. ".")
  return true
end

function Rules.Delete(name)
  local saved = {}
  for _, rule in ipairs(Rules.Saved()) do if rule.name ~= name then saved[#saved + 1] = rule end end
  ns.db.settings.auctionRules = saved
  Rules.queue = {}
  notify("Deleted " .. name .. ".")
end

function Rules.ForItem(id)
  for _, rule in ipairs(Rules.Saved()) do
    for _, itemID in ipairs(rule.items) do if itemID == id then return rule end end
  end
end

function Rules.Evaluate(rule, sources, competitor, ownQuantity)
  local minimum, normal, maximum = Rules.Price(rule.minimum, sources), Rules.Price(rule.normal, sources), Rules.Price(rule.maximum, sources)
  if not minimum or not normal or not maximum then return nil, "Missing price source" end
  if minimum > normal or normal > maximum then return nil, "Minimum, normal and maximum are out of order" end
  local quantity = math.max(0, rule.cap - ownQuantity)
  if quantity == 0 then return nil, "Already at the post cap" end
  local price = competitor and math.max(1, competitor - rule.undercut) or normal
  if price < minimum then
    if rule.below == "skip" then return nil, "Competition is below the minimum" end
    price = rule.below == "minimum" and minimum or normal
  elseif price > maximum then price = rule.above == "maximum" and maximum or normal end
  return { price = price, quantity = quantity }
end

local function keyOf(key)
  return table.concat({ key.itemID, key.itemLevel or 0, key.itemSuffix or 0, key.battlePetSpeciesID or 0 }, ":")
end

function Rules.Stop(message)
  generation = generation + 1
  Rules.running, job, waiting = false, nil, false
  Rules.queue = {}
  if not House.Transacting() then House.Dismiss() end
  notify(message or "Scan stopped. Start a new scan to rebuild the queue.")
end

local function later(action)
  local token = generation
  C_Timer.After(0.1, function() if Rules.running and token == generation then action() end end)
end

local function sourcesFor(item, offers)
  local record = Database.Lookup(ns.db, ns.RealmKey(), ns.Codec.ItemKey(item.itemKey.itemID, item.itemKey.itemSuffix))
  local market = record and ((record.mv or 0) > 0 and record.mv or ns.Advisor.Usual(record))
  return { market = market, vendor = Database.Vendor(ns.db, ns.Codec.ItemKey(item.itemKey.itemID, item.itemKey.itemSuffix)),
    minbuyout = offers[1] and offers[1].price }
end

local function addPlan(item, values)
  values.item, values.name, values.rule, values.scannedAt = item, item.name, item.rule.name, time()
  values.external, values.session = House.external or 0, House.session
  Rules.queue[#Rules.queue + 1] = values
end

local function planItem(item)
  local offers, rule = House.offers, item.rule
  local sources, competitor = sourcesFor(item, offers), nil
  for _, offer in ipairs(offers) do
    if (item.commodity and offer.quantity > offer.ownQuantity) or (not item.commodity and not offer.owned) then
      competitor = offer.price; break
    end
  end
  if job.kind == "post" then
    local plan, reason = Rules.Evaluate(rule, sources, competitor, job.owned[keyOf(item.itemKey)] or 0)
    if not plan then addPlan(item, { kind = "skip", reason = reason }); return end
    local left = plan.quantity
    for _, stack in ipairs(item.stacks) do
      local remaining = math.min(stack.quantity, left)
      while remaining > 0 do
        local quantity = math.min(remaining, item.commodity and rule.stack or 1)
        addPlan(stack, { kind = "post", quantity = quantity, unitPrice = plan.price, duration = rule.duration })
        remaining, left = remaining - quantity, left - quantity
      end
    end
  elseif job.kind == "cancel" then
    for _, owned in ipairs(item.auctions) do
      if competitor and owned.price > competitor and C_AuctionHouse.CanCancelAuction(owned.auctionID) then
        addPlan(owned, { kind = "cancel", quantity = owned.quantity, reason = "Undercut", competitor = competitor })
      else addPlan(owned, { kind = "skip", reason = "Not undercut or no longer cancellable" }) end
    end
  else
    local ceiling = Rules.Price(rule.shopping, sources)
    if not ceiling then addPlan(item, { kind = "skip", reason = "Missing shopping price source" }); return end
    local quantity, lowest = 0, nil
    for _, offer in ipairs(offers) do
      if offer.price <= ceiling and not offer.owned then quantity, lowest = quantity + offer.quantity, lowest or offer.price end
    end
    if quantity > 0 then addPlan(item, { kind = "shop", quantity = quantity, unitPrice = lowest, ceiling = ceiling })
    else addPlan(item, { kind = "skip", reason = "No listings within the shopping limit" }) end
  end
end

local nextItem
nextItem = function()
  job.index = job.index + 1
  local item = job.items[job.index]
  if not item then
    Rules.running, job, waiting = false, nil, false
    House.Dismiss()
    notify("Scan complete. Review each queued action before confirming it.")
    return
  end
  job.stage, waiting = "offers", true
  notify("Scanning " .. job.index .. "/" .. #job.items .. ": " .. item.name)
  if not House.Find(item) then Rules.Stop("Could not search " .. item.name .. ". Start the scan again.") end
end

local function collectItems()
  job.owned = {}
  for _, item in ipairs(House.rows) do
    local key = keyOf(item.itemKey)
    if C_AuctionHouse.CanCancelAuction(item.auctionID) then job.owned[key] = (job.owned[key] or 0) + item.quantity end
  end
  local input = job.kind == "post" and House.Bags() or House.rows
  if job.kind == "shop" then
    input = {}
    for _, rule in ipairs(Rules.Saved()) do
      for _, id in ipairs(rule.items) do
        input[#input + 1] = { itemKey = { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } }
      end
    end
  end
  local grouped = {}
  for _, item in ipairs(input) do
    local rule = Rules.ForItem(item.itemKey.itemID)
    if rule then
      local key = keyOf(item.itemKey)
      if not grouped[key] then
        local info = C_AuctionHouse.GetItemKeyInfo(item.itemKey)
        if info then
          grouped[key] = { itemKey = item.itemKey, commodity = info.isCommodity, name = info.itemName,
            rule = rule, stacks = {}, auctions = {} }
          job.items[#job.items + 1] = grouped[key]
        else addPlan({ name = "Item " .. item.itemKey.itemID, rule = rule }, { kind = "skip", reason = "Item data not loaded. Search once and rescan." }) end
      end
      if grouped[key] then
        item.rule = rule
        table.insert(grouped[key].stacks, item)
        table.insert(grouped[key].auctions, item)
      end
    end
  end
  later(nextItem)
end

function Rules.Start(kind)
  if Rules.running or House.Busy() or not House.open or ns.Scanner.state ~= "idle" then
    notify("Open the auction house and wait for the current request to finish.")
    return false
  end
  if #Rules.Saved() == 0 then notify("Save a group and its rules first."); return false end
  generation = generation + 1
  Rules.queue, Rules.running, executing = {}, true, nil
  job = { kind = kind, items = {}, index = 0, stage = "owned", external = House.external or 0 }
  waiting = true
  notify("Loading your auctions before the scan...")
  if not House.SetMode("owned") then Rules.Stop(); return false end
  return true
end

function Rules.Execute(plan)
  if Rules.running or House.Busy() or plan.done or plan.kind == "skip" then return false end
  if time() - plan.scannedAt > 300 then notify("The scan is more than five minutes old. Scan again."); return false end
  if plan.session ~= House.session or plan.external ~= (House.external or 0) then
    notify("The auction session changed. Scan again."); return false
  end
  if plan.kind == "post" then
    if not House.SetMode("sell") then return false end
    House.Select(plan.item)
    if not House.ReviewPost(plan.quantity, plan.unitPrice, plan.duration) then notify(House.message); return false end
  elseif plan.kind == "cancel" then
    -- Cancellation still rechecks its current fee and eligibility on both clicks.
    House.mode, House.selected = "owned", plan.item
    if not House.ReviewCancel() then notify(House.message); return false end
  else
    return House.Find(plan.item)
  end
  executing = { plan = plan, completed = House.completed or 0 }
  return true
end

House.Subscribe(function()
  if executing and (House.completed or 0) > executing.completed then
    executing.plan.done, executing = true, nil
    notify("Action confirmed. Select the next queued action.")
  elseif executing and (House.phase == "idle" or not House.open) then
    executing = nil
  end
  if not Rules.running or not job then return end
  if not House.open or (House.external or 0) ~= job.external then
    Rules.Stop("The auction house closed or another window made a request. Scan again.")
    Rules.queue = {}
    return
  end
  if not waiting or House.phase ~= "idle" then return end
  waiting = false
  if House.failed then Rules.Stop(House.message)
  elseif job.stage == "owned" and House.context == "owned" then collectItems()
  elseif job.stage == "offers" and House.context == "offers" then
    if House.more then
      if job.loaded and #House.offers <= job.loaded then Rules.Stop("The auction house returned no additional listings. Scan again."); return end
      job.loaded = #House.offers
      later(function()
        waiting = true
        if not House.More() then Rules.Stop("Could not load all listings. Scan again.") end
      end)
    else
      planItem(job.items[job.index])
      job.loaded = nil
      later(nextItem)
    end
  else Rules.Stop("The scan request failed. Try again.") end
end)
