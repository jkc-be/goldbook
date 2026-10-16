local _, ns = ...
local Professions = {}
ns.Professions = Professions
local byID, all = {}, { materials = {}, recipes = {}, crafted = {} }
for _, profession in ipairs(ns.ProfessionData) do
  local groups = { materials = {}, recipes = {}, crafted = {} }
  byID[profession.id] = groups
  for kind, ids in pairs(groups) do
    for _, id in ipairs(profession[kind]) do
      ids[id], all[kind][id] = true, true
    end
  end
end

function Professions.Matches(key, profession, kind)
  if (not profession or profession == "") and (not kind or kind == "all") then
    return true
  end
  local groups = profession and profession ~= "" and byID[profession] or all
  if not groups then return false end
  local id = ns.Codec.BaseID(key)
  return ((kind == "all" or kind == "materials-recipes" or kind == "materials") and groups.materials[id])
    or ((kind == "all" or kind == "materials-recipes" or kind == "recipes") and groups.recipes[id])
    or ((kind == "all" or kind == "crafted") and groups.crafted[id]) or false
end
