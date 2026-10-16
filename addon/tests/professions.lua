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
local rows, names = {}, {}
for _, item in ipairs({ {"2589", "Linen Cloth", 1}, {"2447", "Peacebloom", 1}, {"2840", "Copper Bar", 1},
  {"2881", "Plans: Runed Copper Breastplate", 2}, {"858", "Lesser Healing Potion", 1},
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
assert(shown() == "10504:584,2447,2589,2840,2881,858,999999", "unfiltered list includes unknown items")
choose("profession", 2)
assert(shown() == "2447", "choosing alchemy shows only materials")
choose("kind", 5)
assert(shown() == "858", "crafted selection shows the profession's products")
choose("quality", 4)
assert(shown() == "", "quality combines with profession and item type")
window.filters.clear.scripts.OnClick()
assert(shown() == "10504:584,2447,2589,2840,2881,858,999999", "clear restores all items")
choose("quality", 4)
assert(shown() == "10504:584,2881", "uncommon quality filters the whole list")
ns.UI.Show("gold")
assert(not window.filters:IsShown(), "item filters are hidden on the gold view")
io.write("Profession filters passed: shared materials, recipes, crafted goods, suffixes, quality and UI dropdowns.\n")
