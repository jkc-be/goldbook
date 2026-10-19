local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
assert(ns.Professions.Matches("2589", "tailoring", "materials"), "linen is a tailoring material")
assert(ns.Professions.Matches("2589", "first-aid", "materials"), "linen is also a first aid material")
assert(not ns.Professions.Matches("2589", "alchemy", "materials"), "cloth must not match alchemy")
assert(ns.Professions.Matches("2447", "alchemy", "materials"), "peacebloom is an alchemy material")
assert(ns.Professions.Matches("2881", "blacksmithing", "recipes"), "plans belong to their profession")
assert(ns.Professions.Matches("858", "alchemy", "crafted"), "potions are alchemy products")
assert(not ns.Professions.Matches("858", "alchemy", "materials-recipes"), "crafted goods must stay separate")
assert(ns.Professions.Matches("10504:584", "engineering", "crafted"), "suffix variants use the base item catalog")
assert(ns.Professions.Matches("999999", "", "all"), "unknown items stay visible without a filter")
assert(ns.Professions.Matches("2318", "skinning", "materials"), "light leather is a skinning material")
assert(ns.Professions.Matches("2318", "leatherworking", "materials"), "light leather is still a leatherworking material")
assert(not ns.Professions.Matches("2318", "skinning", "crafted"), "skinning crafts nothing")
assert(ns.Professions.Matches("2447", "herbalism", "materials"), "peacebloom is a herbalism material")
assert(ns.Professions.Matches("2447", "alchemy", "materials"), "peacebloom is still an alchemy material")
assert(not ns.Professions.Matches("2447", "herbalism", "crafted"), "herbalism crafts nothing")
local rows, names = {}, {}
for _, item in ipairs({ {"2589", "Linen Cloth", 1}, {"2447", "Peacebloom", 1}, {"2840", "Copper Bar", 1},
  {"2318", "Light Leather", 1}, {"2881", "Plans: Runed Copper Breastplate", 2}, {"858", "Lesser Healing Potion", 1},
  {"10504:584", "Green Lens variant", 2}, {"999999", "Unknown sample", 0} }) do
  rows[#rows + 1] = { key = item[1], min = 100, mv = 0, qty = 1, n = 0 }
  names[item[1]] = { name = item[2], quality = item[3] }
end
ns.Database.ApplyScan(ns.db, {realm="Faramon",faction="Horde",region="EU",by="Test",build="1.60.1",at=time(),mode="browse",rows=rows,names=names})
ns.UI.Show("prices")
local window = GoldbookWindow
local function choose(name, row)
  local button = window.filters.controls[name]
  button.scripts.OnClick()
  button.menu.options[row].scripts.OnClick()
end
local function shown()
  local out = {}
  for _, row in ipairs(window.rows) do
    local item = rawget(row.hit, "item")
    if item then out[#out + 1] = item.key end
  end
  table.sort(out)
  return table.concat(out, ",")
end
assert(shown() == "10504:584,2318,2447,2589,2840,2881,858,999999", "unfiltered list includes unknown items")
window.filters.controls.profession.scripts.OnClick()
local labels = {}
for _, option in ipairs(window.filters.controls.profession.menu.options) do
  if option.shown then labels[#labels + 1] = option.label.text end
end
assert(table.concat(labels, ", ") == "All professions, Alchemy, Blacksmithing, Cooking, Enchanting, Engineering, "
  .. "First Aid, Herbalism, Leatherworking, Mining, Poisons, Skinning, Tailoring", "the profession menu offers the gathering professions")
window.filters.controls.profession.menu:Hide()
window.filters.controls.quality.scripts.OnClick()
labels = {}
for _, option in ipairs(window.filters.controls.quality.menu.options) do
  if option.shown then labels[#labels + 1] = option.label.text end
end
assert(table.concat(labels, ", ") == "All qualities, Poor, Common, Uncommon, Rare, Epic",
  "the quality menu offers only what the auction house lists")
window.filters.controls.quality.menu:Hide()
choose("profession", 8)
assert(shown() == "2447", "choosing herbalism shows gathered herbs")
choose("profession", 12)
assert(shown() == "2318", "choosing skinning shows skinned leather")
choose("profession", 2)
assert(shown() == "2447", "choosing alchemy shows only materials")
choose("kind", 5)
assert(shown() == "858", "crafted selection shows the profession's products")
choose("quality", 4)
assert(shown() == "", "quality combines with profession and item type")
window.filters.clear.scripts.OnClick()
assert(shown() == "10504:584,2318,2447,2589,2840,2881,858,999999", "clear restores all items")
choose("quality", 4)
assert(shown() == "10504:584,2881", "uncommon quality filters the whole list")
-- By item has four chips; with a filter chosen, Clear filters joins them, and
-- the search box gives up width so the row still ends inside the page.
local function reach()
  local right = window.search.width
  for _, chip in pairs(window.filters.controls) do
    if chip:IsShown() then
      right = right + 17 + chip.label:GetStringWidth() + 9 + (chip.caret and 5 + chip.caret:GetStringWidth() or 0)
    end
  end
  if window.filters.clear:IsShown() then
    right = right + 17 + window.filters.clear.label:GetStringWidth() + 9
  end
  return right
end
window.filters.clear.scripts.OnClick()
ns.UI.Show("items")
local unfiltered = window.search.width
assert(reach() <= 681, "By item's chips end inside the page, " .. reach())
choose("profession", 2)
assert(window.filters.clear:IsShown() and window.search.width < unfiltered and reach() <= 681,
  "a filter on By item narrows the search box so Clear filters ends inside the page, " .. window.search.width .. " " .. reach())
ns.UI.Show("gold")
assert(not window.filters:IsShown(), "item filters are hidden on the gold view")
io.write("Profession filters passed: shared materials, recipes, crafted goods, suffixes, quality and UI dropdowns.\n")
