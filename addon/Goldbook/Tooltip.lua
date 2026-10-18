local _, ns = ...
local Codec, Database, Advisor = ns.Codec, ns.Database, ns.Advisor

local TOOLTIPS = { GameTooltip = true, ItemRefTooltip = true }

-- Hold Shift over a stack to price the whole stack.
local function stackSize(tooltip)
  local owner = IsShiftKeyDown() and tooltip:GetOwner()
  local count = owner and owner.count
  return type(count) == "number" and count > 1 and count or 1
end

local function addPrices(tooltip, link)
  -- In restricted content the link can be a secret value that must not be read.
  if not link or (issecretvalue and issecretvalue(link)) then
    return
  end
  local realmKey = ns.RealmKey()
  local key = Database.KeyFromLink(ns.db, realmKey, link)
  if not key then
    return
  end
  local record = Database.Lookup(ns.db, realmKey, key)
  local vendor = Database.Vendor(ns.db, key) or ns.SellPrice(link) or 0
  local stocked = Database.MerchantSells(ns.db, key)
  if not record and vendor == 0 then
    return
  end

  local stack = stackSize(tooltip)
  local function row(label, copper)
    tooltip:AddDoubleLine("  " .. label, Codec.Money(copper * stack), 1, 1, 1, 1, 1, 1)
  end

  tooltip:AddLine(" ")
  tooltip:AddDoubleLine(
    "Goldbook" .. (stack > 1 and (" x" .. stack) or ""),
    record and (record.qty .. " listed, seen " .. Codec.Age(time() - record.seen)
      .. (Database.FromServer(ns.db, realmKey, key) and ", from the server" or "")) or "",
    1, 0.82, 0, 0.6, 0.6, 0.6
  )
  if record then
    row("Min buyout", record.min)
    if record.mv > 0 then
      local stale = record.mvAt ~= record.seen and (" (" .. Codec.Age(time() - record.mvAt) .. ")") or ""
      row("Market value" .. stale, record.mv)
    end
    local usual = Advisor.Usual(record)
    if usual then
      row("Usual over " .. #record.days .. " days", usual)
    end
    if not stocked then
      row("Post at", Advisor.PostPrice(record, vendor, ns.db.scanned[realmKey]))
    end
  end
  if vendor > 0 then
    row("Vendor", vendor)
  end
  if stocked then
    local price = Database.MerchantPrice(ns.db, key)
    if price then
      row("Merchant sells", price)
    else
      tooltip:AddLine("  Sold by merchants", 0.6, 0.6, 0.6)
    end
  end

  local deal = record and Advisor.Deal(record, vendor, ns.db.scanned[realmKey], stocked)
  if deal then
    local target = deal.kind == "vendor" and "a vendor pays " or "resells for "
    local scope = deal.units and (" on " .. deal.units .. (deal.units == 1 and " unit" or " units")) or " each"
    tooltip:AddLine("  Deal: " .. target .. Codec.Money(deal.sell) .. ", profit " .. Codec.Money(deal.total) .. scope, 0.25, 1, 0.25)
  end
  if record and ns.db.settings.altClick ~= false then
    tooltip:AddLine("  Alt+click: price history", 0.6, 0.6, 0.6)
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
    if TOOLTIPS[tooltip:GetName() or ""] then
      local _, link = TooltipUtil.GetDisplayedItem(tooltip)
      addPrices(tooltip, link)
    end
  end)
else
  for name in pairs(TOOLTIPS) do
    _G[name]:HookScript("OnTooltipSetItem", function(tooltip)
      local _, link = tooltip:GetItem()
      addPrices(tooltip, link)
    end)
  end
end
