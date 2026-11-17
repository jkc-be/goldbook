local _, ns = ...
local Codec, Database, Advisor = ns.Codec, ns.Database, ns.Advisor

-- What crafting costs and brings in, per craft: the reagents of a recipe in
-- ns.CraftData at the cheaper of their lowest buyout and a merchant's price,
-- against what the items made sell for as Advisor.SaleValue judges it.
local Crafting = {}
ns.Crafting = Crafting

-- makers[itemID] = the spells that make the item, and taught[profession]
-- those of a profession, taught[""] of them all; lowest first.
local makers, taught = {}, { [""] = {} }
for spell, recipe in pairs(ns.CraftData) do
  makers[recipe.item] = makers[recipe.item] or {}
  table.insert(makers[recipe.item], spell)
  taught[recipe.profession] = taught[recipe.profession] or {}
  table.insert(taught[recipe.profession], spell)
  table.insert(taught[""], spell)
end
for _, index in ipairs({ makers, taught }) do
  for _, spells in pairs(index) do
    table.sort(spells)
  end
end

function Crafting.SpellsFor(key)
  return makers[Codec.BaseID(key)] or {}
end

function Crafting.Spells(profession)
  return taught[profession] or {}
end

-- The professions with recipes, as their ns.ProfessionData entries.
function Crafting.Professions()
  local professions = {}
  for _, profession in ipairs(ns.ProfessionData) do
    if taught[profession.id] then
      professions[#professions + 1] = profession
    end
  end
  return professions
end

-- The spells a profession window lists, from its rows: { item, name }, the
-- item each makes and the row's name. Of the recipes for an item several
-- make, a row is the one `nameOf` (spell) names as the row is named, or
-- else that of the profession most of the window's items belong to.
function Crafting.SpellsListed(rows, nameOf)
  local votes, window = {}, nil
  for _, row in ipairs(rows) do
    for _, spell in ipairs(makers[row.item] or {}) do
      local profession = ns.CraftData[spell].profession
      votes[profession] = (votes[profession] or 0) + 1
    end
  end
  for profession, count in pairs(votes) do
    if not window or count > votes[window] or (count == votes[window] and profession < window) then
      window = profession
    end
  end
  local spells = {}
  for _, row in ipairs(rows) do
    local candidates, found = makers[row.item] or {}, {}
    for _, spell in ipairs(candidates) do
      if #candidates == 1 or nameOf(spell) == row.name then
        found[#found + 1] = spell
      end
    end
    for _, spell in ipairs(#found == 0 and candidates or {}) do
      if ns.CraftData[spell].profession == window then
        found[#found + 1] = spell
      end
    end
    for _, spell in ipairs(found) do
      spells[#spells + 1] = spell
    end
  end
  return spells
end

local names = {}
for _, profession in ipairs(ns.ProfessionData) do
  names[profession.id] = profession.name
end

function Crafting.ProfessionName(id)
  return names[id]
end

-- A buyout of any age counts, but one missing from the newest scan is `stale`.
local function priced(db, realmKey, newestScan, itemID, count)
  local key = Codec.ItemKey(itemID)
  local reagent = { key = key, count = count, stale = false }
  local record = Database.Lookup(db, realmKey, key)
  local merchant = Database.MerchantPrice(db, key)
  if record and not (merchant and merchant <= record.min) then
    reagent.each, reagent.source, reagent.seen, reagent.stale = record.min, "auction", record.seen, record.seen ~= newestScan
  elseif merchant then
    reagent.each, reagent.source = merchant, "merchant"
  end
  reagent.cost = reagent.each and reagent.each * count
  return reagent
end

-- One craft of `spell`: { spell, key, profession, skill, makes, reagents =
-- { { key, count, each, source = "auction" or "merchant", seen, stale, cost } },
-- cost, unpriced, stale, action, post, each, sale, profit, margin }. `cost`
-- adds up the reagents with a price and `unpriced` counts the others; `sale`
-- is what the `makes` items bring in, from Advisor.SaleValue's `action`,
-- `post` and `each`. Profit and margin, a share of the sale, need both.
function Crafting.Estimate(db, realmKey, spell)
  local recipe = ns.CraftData[spell]
  local newestScan = Database.NewestScan(db, realmKey)
  local estimate = { spell = spell, key = Codec.ItemKey(recipe.item), profession = recipe.profession, skill = recipe.skill,
    makes = recipe.makes, reagents = {}, cost = 0, unpriced = 0, stale = false }
  for index, pair in ipairs(recipe.reagents) do
    local reagent = priced(db, realmKey, newestScan, pair[1], pair[2])
    estimate.reagents[index] = reagent
    estimate.cost = estimate.cost + (reagent.cost or 0)
    estimate.unpriced = estimate.unpriced + (reagent.cost and 0 or 1)
    estimate.stale = estimate.stale or reagent.stale
  end
  local sale = Advisor.SaleValue(db, realmKey, estimate.key, newestScan)
  estimate.action, estimate.post, estimate.each = sale.action, sale.post, sale.each
  estimate.sale = sale.each and sale.each * recipe.makes
  if estimate.sale and estimate.unpriced == 0 then
    estimate.profit = estimate.sale - estimate.cost
    estimate.margin = estimate.profit / estimate.sale
  end
  return estimate
end

-- Of two recipes for one item, the one to go by: priced in full, then cheaper.
local function better(a, b)
  if (a.unpriced == 0) ~= (b.unpriced == 0) then
    return a.unpriced == 0
  elseif a.cost ~= b.cost then
    return a.cost < b.cost
  end
  return a.spell < b.spell
end

-- An estimate per item the `spells` make, from the item's better recipe,
-- lowest spell first.
function Crafting.Estimates(db, realmKey, spells)
  local best = {}
  for _, spell in ipairs(spells) do
    local estimate = Crafting.Estimate(db, realmKey, spell)
    local held = best[estimate.key]
    if not held or better(estimate, held) then
      best[estimate.key] = estimate
    end
  end
  local list = {}
  for _, estimate in pairs(best) do
    list[#list + 1] = estimate
  end
  table.sort(list, function(a, b)
    return a.spell < b.spell
  end)
  return list
end

-- The estimate of the better recipe for the item, nil when nothing makes it.
function Crafting.ForItem(db, realmKey, key)
  return Crafting.Estimates(db, realmKey, Crafting.SpellsFor(key))[1]
end
