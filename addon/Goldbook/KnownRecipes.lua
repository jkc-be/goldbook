local _, ns = ...
local Crafting = ns.Crafting

-- The recipes each character knows, read from the profession windows the
-- player opens and from the spells the client says the character knows.
-- Recipes are only ever added: a window with collapsed headers or a filter
-- set lists part of what the character knows.
local KnownRecipes = {}
ns.KnownRecipes = KnownRecipes

-- Adds `spells` to what `character` knows; true when one of them is new.
function KnownRecipes.Record(db, character, spells)
  local added = false
  for _, spell in ipairs(spells) do
    local known = db.recipes[character] or {}
    db.recipes[character] = known
    added = added or not known[spell]
    known[spell] = true
  end
  return added
end

-- Whether `who` knows the recipe: "all" lets every recipe through, "any" is
-- any character, and anything else a character's key.
function KnownRecipes.Knows(db, who, spell)
  if who == "all" then
    return true
  elseif who == "any" then
    for _, known in pairs(db.recipes) do
      if known[spell] then
        return true
      end
    end
    return false
  end
  local known = db.recipes[who]
  return known ~= nil and known[spell] == true
end

function KnownRecipes.Characters(db)
  local characters = {}
  for character in pairs(db.recipes) do
    characters[#characters + 1] = character
  end
  table.sort(characters)
  return characters
end

-- A spell's name, from whichever call the client has.
local function spellName(spell)
  if C_Spell and C_Spell.GetSpellName then
    return C_Spell.GetSpellName(spell)
  end
  return GetSpellInfo and (GetSpellInfo(spell))
end

-- The rows of the open window as { name, link }, its headers left out.
-- `kindAt` is where the row info gives the row's kind.
local function listed(count, info, link, kindAt)
  local rows = {}
  if count and info and link then
    for index = 1, count() do
      local fields = { info(index) }
      if fields[kindAt] ~= "header" and fields[kindAt] ~= "subheader" then
        rows[#rows + 1] = { name = fields[1], link = link(index) }
      end
    end
  end
  return rows
end

-- An enchant link names its recipe's spell, an item link the item it makes.
local function spellsListed(rows)
  local spells, items = {}, {}
  for _, row in ipairs(rows) do
    local spell = row.link and tonumber(row.link:match("enchant:(%d+)"))
    local item = row.link and tonumber(row.link:match("item:(%d+)"))
    if spell and ns.CraftData[spell] then
      spells[#spells + 1] = spell
    elseif item then
      items[#items + 1] = { item = item, name = row.name }
    end
  end
  for _, spell in ipairs(Crafting.SpellsListed(items, spellName)) do
    spells[#spells + 1] = spell
  end
  return spells
end

local function playerSpells()
  local spells = {}
  if IsPlayerSpell then
    for spell in pairs(ns.CraftData) do
      if IsPlayerSpell(spell) then
        spells[#spells + 1] = spell
      end
    end
  end
  return spells
end

local function tradeSkills()
  return spellsListed(listed(GetNumTradeSkills, GetTradeSkillInfo, GetTradeSkillItemLink, 2))
end

-- Enchanting's window in the Classic client.
local function crafts()
  return spellsListed(listed(GetNumCrafts, GetCraftInfo, GetCraftItemLink, 3))
end

-- The recipe learned, and any the client now says the character knows.
local function learned(spell)
  local spells = playerSpells()
  if ns.CraftData[spell] then
    spells[#spells + 1] = spell
  end
  return spells
end

local READERS = {
  PLAYER_LOGIN = playerSpells,
  NEW_RECIPE_LEARNED = learned,
  TRADE_SKILL_SHOW = tradeSkills,
  TRADE_SKILL_UPDATE = tradeSkills,
  CRAFT_SHOW = crafts,
  CRAFT_UPDATE = crafts,
}

local frame = CreateFrame("Frame")
for event in pairs(READERS) do
  if not C_EventUtils or C_EventUtils.IsEventValid(event) then
    frame:RegisterEvent(event)
  end
end
frame:SetScript("OnEvent", function(_, event, ...)
  if KnownRecipes.Record(ns.db, ns.CharacterKey(), READERS[event](...)) then
    ns.UI.RefreshSoon()
  end
end)
