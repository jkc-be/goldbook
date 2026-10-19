local _, ns = ...
local ItemFilters = {}
ns.ItemFilters = ItemFilters

function ItemFilters.New()
  return { profession = "", kind = "all" }
end

function ItemFilters.Matches(key, quality, filters)
  return ns.Professions.Matches(key, filters.profession, filters.kind)
    and (filters.quality == nil or quality == filters.quality)
    and ItemFilters.InCategory(key, filters.category)
end

function ItemFilters.InCategory(key, category)
  if not category then return true end
  local id = ns.Codec.BaseID(key)
  local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(id)
  local inventoryType = C_Item.GetItemInventoryTypeByID(id)
  for _, filter in ipairs(category.filters or {}) do
    if (filter.classID == nil or filter.classID == classID)
      and (filter.subClassID == nil or filter.subClassID == subClassID)
      and (filter.inventoryType == nil or filter.inventoryType == inventoryType) then return true end
  end
  return false
end

function ItemFilters.Select(filters, name, value)
  filters[name] = value
  if name == "profession" then filters.kind = value ~= "" and "materials" or "all" end
end

ItemFilters.Options = {
  profession = function()
    local options = { { "", "All professions" } }
    for _, profession in ipairs(ns.ProfessionData) do
      if #profession.materials > 0 then
        options[#options + 1] = { profession.id, profession.name }
      end
    end
    return options
  end,
  kind = function()
    return { { "all", "All items" }, { "materials-recipes", "Materials and recipes" }, { "materials", "Materials" },
      { "recipes", "Recipes" }, { "crafted", "Crafted items" } }
  end,
  quality = function()
    local options = { { nil, "All qualities" } }
    -- The qualities the auction house lists: legendaries are bound, and
    -- Classic has no artifacts or heirlooms.
    for id, name in ipairs({ "Poor", "Common", "Uncommon", "Rare", "Epic" }) do
      options[#options + 1] = { id - 1, name }
    end
    return options
  end,
}
