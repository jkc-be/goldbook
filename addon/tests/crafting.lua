-- Crafting estimates: what a recipe's reagents cost and what its items sell
-- for, at prices set up the way scans and merchants record them.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
local Database, Crafting = ns.Database, ns.Crafting

local checks, failures = 0, 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(label, tostring(expected), tostring(actual)))
  end
end

local REALM, NOW, DAY = "Faramon-Horde", time(), 24 * 3600
local FLASK, BRONZE, WATER = 17635, 2659, "7080"

-- prices = { [key] = lowest buyout }.
local function scan(db, at, prices)
  local rows = {}
  for key, min in pairs(prices) do
    rows[#rows + 1] = { key = key, min = min, mv = 0, qty = 5, n = 1 }
  end
  Database.ApplyScan(db, { realm = "Faramon", faction = "Horde", region = "EU", at = at, mode = "browse", by = "Test",
    build = "1", rows = rows, names = {} })
end

-- scans = { { at, prices } }, oldest first; merchant and vendor prices by item id.
local function market(scans, merchant, vendor)
  local db = Database.Init(nil)
  for _, prices in ipairs(scans) do
    scan(db, prices[1], prices[2])
  end
  for itemID, price in pairs(merchant or {}) do
    db.merchant[itemID] = price
  end
  for itemID, price in pairs(vendor or {}) do
    db.vendor[itemID] = price
  end
  return db
end

-- "cost unpriced sale profit margin action post", the margin to four places.
local function summary(estimate)
  return table.concat({ estimate.cost, estimate.unpriced, tostring(estimate.sale), tostring(estimate.profit),
    estimate.margin and ("%.4f"):format(estimate.margin) or "nil", estimate.action, tostring(estimate.post) }, " ")
end

-- Each reagent as "key count each source cost stale".
local function reagents(estimate)
  local parts = {}
  for index, reagent in ipairs(estimate.reagents) do
    parts[index] = table.concat({ reagent.key, reagent.count, tostring(reagent.each), tostring(reagent.source),
      tostring(reagent.cost), tostring(reagent.stale) }, " ")
  end
  return table.concat(parts, " / ")
end

local TITANS = { ["8846"] = 850, ["13423"] = 6200, ["13468"] = 498799, ["13510"] = 1084130 }
local flask = Crafting.Estimate(market({ { NOW, TITANS } }, { [8925] = 100 }), REALM, FLASK)
eq(summary(flask), "586399 0 1029922 443523 0.4306 auction 1084129",
  "Flask of the Titans costs 58g 63s 99c and sells for its post price after the cut")
eq(reagents(flask), "8846 30 850 auction 25500 false / 13423 10 6200 auction 62000 false / 13468 1 498799 auction 498799 false"
  .. " / 8925 1 100 merchant 100 false", "each reagent is priced from the auction house or the merchant that sells it")

local listed = {}
for key, min in pairs(TITANS) do
  listed[key] = min
end
listed["8925"] = 150
local cheaper = Crafting.Estimate(market({ { NOW, listed } }, { [8925] = 100, [8846] = 900 }), REALM, FLASK)
eq(reagents(cheaper), "8846 30 850 auction 25500 false / 13423 10 6200 auction 62000 false / 13468 1 498799 auction 498799 false"
  .. " / 8925 1 100 merchant 100 false", "a reagent costs the cheaper of its lowest buyout and a merchant's price")

local noLotus = {}
for key, min in pairs(TITANS) do
  noLotus[key] = key ~= "13468" and min or nil
end
local unpriced = Crafting.Estimate(market({ { NOW, noLotus } }, { [8925] = 100 }), REALM, FLASK)
eq(summary(unpriced), "87600 1 1029922 nil nil auction 1084129", "with a reagent unpriced the cost is partial and there is no profit")
eq(reagents(unpriced):match("13468 [^/]*"), "13468 1 nil nil nil false ", "the unpriced reagent has no price or source")

local bronze = Crafting.Estimate(market({ { NOW, { ["2840"] = 150, ["3576"] = 200, ["2841"] = 400 } } }), REALM, BRONZE)
eq(bronze.makes .. " " .. summary(bronze), "2 350 0 758 408 0.5383 auction 399", "a smelt that makes two bars sells both")

local vendored = Crafting.Estimate(market({ { NOW, { ["2840"] = 150, ["3576"] = 200, ["2841"] = 100 } } }, nil, { [2841] = 120 }),
  REALM, BRONZE)
eq(summary(vendored), "350 0 240 -110 -0.4583 vendor nil", "bars listed under what a vendor pays are valued at the vendor price")

local stale = Crafting.Estimate(market({ { NOW - DAY, { ["3576"] = 200 } }, { NOW, { ["2840"] = 150, ["2841"] = 400 } } }),
  REALM, BRONZE)
eq(tostring(stale.stale) .. " " .. reagents(stale) .. " " .. stale.reagents[2].seen,
  "true 2840 1 150 auction 150 false / 3576 1 200 auction 200 true " .. (NOW - DAY),
  "a buyout missing from the newest scan still prices its reagent, marked stale with when it was seen")

local essences = market({ { NOW, { ["7076"] = 5000, ["12808"] = 1500, [WATER] = 9000 } } })
local water = Crafting.ForItem(essences, REALM, WATER)
eq(water.spell .. " " .. water.cost, "17563 1500", "an item two recipes make goes by the cheaper one")
local partly = Crafting.ForItem(market({ { NOW, { ["7076"] = 5000, [WATER] = 9000 } } }), REALM, WATER)
eq(partly.spell .. " " .. partly.cost .. " " .. partly.unpriced, "17561 5000 0", "a recipe priced in full beats a cheaper one with a reagent unpriced")
eq(tostring(Crafting.ForItem(essences, REALM, "2589")) .. " " .. tostring(Crafting.ForItem(essences, REALM, "13510") ~= nil),
  "nil true", "an item no recipe makes has no estimate")

local function plain(text)
  return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The text of the row's cells the view uses.
local function cells(index)
  local texts = {}
  for _, cell in ipairs(GoldbookWindow.rows[index].cells) do
    if cell.shown then
      texts[#texts + 1] = plain(cell.text)
    end
  end
  return table.concat(texts, " | ")
end

-- The cards above the list, as "KEY value detail".
local function cards()
  local texts = {}
  for index, card in ipairs(GoldbookWindow.cards.cards) do
    texts[index] = plain(card.key.text .. " " .. card.value.text .. " " .. card.detail.text)
  end
  return table.concat(texts, " / ")
end

-- The title line: its title, figure, text after them and tags.
local function head()
  local window = GoldbookWindow.head
  local parts = { window.title.text, window.figure.text }
  for _, tag in ipairs(window.tags) do
    if tag.shown then
      parts[#parts + 1] = tag.label.text
    end
  end
  return plain(table.concat(parts, " | "))
end

-- A segmented control's choices, the picked one in brackets.
local function choices(control)
  local texts = {}
  for _, button in ipairs(control.buttons) do
    if button.shown and control.shown then
      texts[#texts + 1] = button.picked.shown and ("[" .. button.label.text .. "]") or button.label.text
    end
  end
  return table.concat(texts, " ")
end

local function click(widget)
  widget.scripts.OnClick(widget)
end

local NAMES = {
  [13510] = { "Flask of the Titans", 1, 0 }, [8846] = { "Gromsblood", 1, 0 }, [13423] = { "Stonescale Oil", 1, 0 },
  [13468] = { "Black Lotus", 2, 0 }, [8925] = { "Crystal Vial", 1, 5 }, [2589] = { "Linen Cloth", 1, 13 },
}
for itemID, item in pairs(NAMES) do
  Stub.items[itemID] = { name = item[1], quality = item[2], vendor = item[3], cached = true }
end
local priced = {}
for key, min in pairs(TITANS) do
  priced[key] = min
end
priced["2589"] = 120
GoldbookDB = market({ { NOW, priced } }, { [8925] = 100 })
ns.db = GoldbookDB

SlashCmdList.GOLDBOOK("show")
ns.UI.ShowItem("13510")
eq(head(), "Flask of the Titans | 108g 41s 30c | Alchemy +43%", "the item page tags a crafted item with its profession and margin")
eq(choices(GoldbookWindow.modes), "[History] Crafting", "the item page opens on the history, with crafting beside it")
click(GoldbookWindow.modes.buttons[2])
eq(choices(GoldbookWindow.modes) .. " / " .. GoldbookWindow.head.back.label.text, "History [Crafting] / Back to Prices",
  "Crafting shows the recipe and Back still returns to the list")
eq(cards(), "INPUT COST 58g 63s 99c 4 reagents / SELLS FOR 102g 99s 22c Posts at 108g 41s 29c"
  .. " / PROFIT +44g 35s 23c After the 5% cut / MARGIN +43% Alchemy 300", "the cards add up one craft")
eq(GoldbookWindow.headers[1].text .. " " .. GoldbookWindow.headers[5].text, "REAGENT COST ↓", "the reagents come dearest first")
eq(cells(1) .. " / " .. cells(4), "Black Lotus | 1 | 49g 87s 99c | Auction | 49g 87s 99c / Crystal Vial | 1 | 1s 00c | Merchant | 1s 00c",
  "each reagent shows its count, price, where to buy it and its cost, named once the client answers")
eq(plain(GoldbookWindow.status.text), "Reagents cost the cheaper of the auction house and a merchant · Click a reagent to search for it",
  "the status says how reagents are priced")
click(GoldbookWindow.head.back)
eq(GoldbookWindow.headers[1].text .. " " .. tostring(GoldbookWindow.modes.shown), "ITEM ↑ false", "Back leaves the item page for the list")

ns.UI.ShowItem("2589")
eq(head() .. " / " .. choices(GoldbookWindow.modes), "Linen Cloth | 1s 20c / ", "an item nothing crafts has no crafting mode")

GameTooltip.lines, GameTooltip.itemLink = {}, "|Hitem:13510::::::|h[Flask of the Titans]|h"
Stub.tooltipCalls[1](GameTooltip)
eq(plain(table.concat(GameTooltip.lines, " / ")):match("Crafting.*%)"), "Crafting cost = 58g 63s 99c /   Craft profit = +44g 35s 23c (+43%)",
  "the tooltip adds what crafting costs and makes")
GoldbookDB.prices["Faramon-Horde"]["13468"] = nil
GameTooltip.lines = {}
Stub.tooltipCalls[1](GameTooltip)
eq(plain(GameTooltip.lines[#GameTooltip.lines - 1]), "  Crafting cost: 1 reagent has no price", "a reagent without a price makes it say so instead")
scan(GoldbookDB, NOW, { ["2840"] = 150, ["3576"] = 200, ["2841"] = 400 })
Stub.shift, GameTooltip.owner, GameTooltip.lines, GameTooltip.itemLink = true, { count = 20 }, {}, "|Hitem:2841::::::|h[Bronze Bar]|h"
Stub.tooltipCalls[1](GameTooltip)
Stub.shift, GameTooltip.owner = false, nil
eq(plain(table.concat(GameTooltip.lines, " / ")):match("Crafting.*%)"), "Crafting cost = 35s 00c /   Craft profit = +40s 80c (+54%)",
  "Shift over 20 bars prices 20 of the two a smelt makes")

-- The recipes recorded for a character, lowest spell first.
local function known(character)
  local spells = {}
  for spell in pairs(GoldbookDB.recipes[character] or {}) do
    spells[#spells + 1] = spell
  end
  table.sort(spells)
  return table.concat(spells, " ")
end

-- The side panel's title and aside, then each line as "key = value".
local function side()
  local panel = GoldbookWindow.side
  local texts = { plain(panel.heading.label.text .. " | " .. panel.heading.aside.text) }
  for _, line in ipairs(panel.lines) do
    if line.key.text ~= "" then
      texts[#texts + 1] = plain(line.key.text .. " = " .. line.value.text)
    end
  end
  return table.concat(texts, " / ")
end

-- A chip's menu as its labels, or picks the option labelled `choice`.
local function chip(name, choice)
  local control = GoldbookWindow.filters.controls[name]
  click(control)
  local labels = {}
  for _, option in ipairs(GoldbookWindow.menu.options) do
    if option.shown then
      labels[#labels + 1] = option.label.text
      if option.label.text == choice then
        click(option)
        return
      end
    end
  end
  click(control)
  return table.concat(labels, " / ")
end

local function picked()
  local rows = {}
  for index, row in ipairs(GoldbookWindow.rows) do
    if row.pick.shown and row.pickBar.shown then
      rows[#rows + 1] = index
    end
  end
  return table.concat(rows, " ")
end

for itemID, item in pairs({ [3577] = { "Gold Bar", 1 }, [3575] = { "Iron Bar", 1 }, [13512] = { "Flask of Supreme Power", 1 },
  [13463] = { "Dreamfoil", 1 }, [13465] = { "Mountain Silversage", 1 }, [11287] = { "Lesser Magic Wand", 2 },
  [2997] = { "Bolt of Woolen Cloth", 1 } }) do
  Stub.items[itemID] = { name = item[1], quality = item[2], vendor = 0, cached = true }
end
local stocked = {}
for key, min in pairs(TITANS) do
  stocked[key] = min
end
stocked["3577"], stocked["3575"], stocked["13465"], stocked["13512"] = 900, 500, 3200, 920000
scan(GoldbookDB, NOW, stocked)

SlashCmdList.GOLDBOOK("crafting")
eq(GoldbookWindow.filters.controls.known.label.text .. " / " .. cells(1), "Known by Sultan /  |  | ",
  "the Crafting tab starts on the recipes of the character playing, none recorded yet")
eq(GoldbookWindow.status.text, "No recipes recorded for Sultan yet. Open a profession window, or pick All recipes.",
  "the status says how to record them")

Stub.spellNames = { [3308] = "Smelt Gold", [11479] = "Transmute: Iron to Gold" }
Stub.tradeSkills = {
  { "Flasks", "header" },
  { "Flask of the Titans", "optimal", "|cffffffff|Hitem:13510::::::::60:::::|h[Flask of the Titans]|h|r" },
  { "Transmutes", "header" },
  { "Transmute: Iron to Gold", "medium", "|cffffffff|Hitem:3577::::::::60:::::|h[Gold Bar]|h|r" },
}
Stub.fire("TRADE_SKILL_SHOW")
eq(known("Sultan-Faramon"), "11479 17635",
  "a profession window records its recipes by the items they make, a bar both smelted and transmuted by the row's name")
local SPELLS = { [17561] = "Transmute: Earth to Water", [17563] = "Transmute: Undeath to Water", [3308] = "Smelt Gold",
  [11479] = "Transmute: Iron to Gold", [10098] = "Smelt Truesilver", [11480] = "Transmute: Mithril to Truesilver" }
local function listed(rows, names)
  return table.concat(Crafting.SpellsListed(rows, function(spell)
    return names[spell]
  end), " ")
end
eq(listed({ { item = 7080, name = "Transmute: Undeath to Water" } }, SPELLS), "17563",
  "of two transmutes making one essence, only the one the window lists is recorded")
eq(listed({ { item = 3577, name = "Smelt Gold" }, { item = 6037, name = "Smelt Truesilver" } }, SPELLS), "3308 10098",
  "a smelting window listing only bars an alchemist can also transmute records the smelts")
eq(listed({ { item = 3577, name = "Goldbarren" }, { item = 13510, name = "Fläschchen der Titanen" } }, {}), "11479 17635",
  "without the recipes' names, the profession most of the window's items belong to decides")
Stub.advance(0.3)
eq(cells(1) .. " / " .. cells(2), "Flask of the Titans | +44g 35s 23c | +43% / Gold Bar | +3s 54c | +41%",
  "the tab lists the recorded recipes, most profit first")
eq(plain(GoldbookWindow.head.sub.text), "2 recipes · 2 in profit", "the title counts the recipes and those in profit")
eq(picked() .. " / " .. side(), "1 / Flask of the Titans | Alchemy 300 / Gromsblood x30 = 2g 55s 00c / Stonescale Oil x10 = 6g 20s 00c"
  .. " / Black Lotus x1 = 49g 87s 99c / Crystal Vial x1 · merchant = 1s 00c / Input cost = 58g 63s 99c"
  .. " / Sells for = 102g 99s 22c / Profit = +44g 35s 23c / Margin = +43%",
  "the first recipe is picked and broken down beside the list")
click(GoldbookWindow.rows[2].hit)
eq(picked() .. " / " .. side(), "2 / Gold Bar | Alchemy 225 / Iron Bar x1 = 5s 00c / Input cost = 5s 00c / Sells for = 8s 54c"
  .. " / Profit = +3s 54c / Margin = +41%", "a click picks another recipe")

Stub.crafts = {
  { "Wands", "header" },
  { "Lesser Magic Wand", "optimal", "|cffffffff|Henchant:14293|h[Lesser Magic Wand]|h|r" },
  { "Enchant Bracer - Minor Health", "optimal", "|cffffffff|Henchant:7418|h[Enchant Bracer - Minor Health]|h|r" },
}
Stub.fire("CRAFT_SHOW")
eq(known("Sultan-Faramon"), "11479 14293 17635", "Enchanting's window records the recipe its link names, not an enchant that makes no item")
Stub.fire("NEW_RECIPE_LEARNED", 17637)
eq(known("Sultan-Faramon"), "11479 14293 17635 17637", "the recipe learned is recorded")
Stub.advance(0.3)
eq(cells(3) .. " / " .. cells(4) .. " / " .. picked(), "Lesser Magic Wand | – | – / Flask of Supreme Power | – | – / 2",
  "recipes with a reagent unpriced have no profit and come last, and the picked recipe stays picked")
GoldbookWindow.headerButtons[2].scripts.OnClick()
eq(cells(1) .. " / " .. cells(3), "Gold Bar | +3s 54c | +41% / Lesser Magic Wand | – | –", "they stay last in the other order")
GoldbookWindow.headerButtons[2].scripts.OnClick()

GoldbookDB.recipes["Mirelle-Faramon"] = { [2964] = true }
eq(chip("known"), "All recipes / Known by my characters / Known by Sultan / Known by Mirelle",
  "the chip offers every recipe, all characters', the playing character's and each other's")
chip("known", "Known by Mirelle")
eq(cells(1) .. " / " .. cells(2), "Bolt of Woolen Cloth | – | – /  |  | ", "another character's recipes")
chip("known", "Known by my characters")
eq(cells(5) .. " / " .. cells(6), "Bolt of Woolen Cloth | – | – /  |  | ", "every character's recipes together")
chip("known", "All recipes")
chip("craft", "Alchemy")
eq(plain(GoldbookWindow.head.sub.text), "131 Alchemy recipes · 2 in profit", "All recipes lists every recipe of the profession picked")
Stub.advance(10)
GoldbookWindow.scripts.OnMouseWheel(GoldbookWindow, -3)
local top = cells(1)
click(GoldbookWindow.rows[5].hit)
Stub.advance(0.3)
eq(cells(1) .. " / " .. picked(), top .. " / 5", "picking a recipe further down keeps the list where it is")
GoldbookWindow.search:SetText("gold")
eq(cells(1) .. " / " .. cells(2), "Gold Bar | +3s 54c | +41% /  |  | ", "the search matches the crafted item's name")
click(GoldbookWindow.filters.clear)
eq(GoldbookWindow.filters.controls.known.label.text .. " / " .. GoldbookWindow.filters.controls.craft.label.text,
  "Known by Sultan / All professions", "Clear filters returns to the playing character's recipes")

GoldbookDB.recipes = {}
chip("known", "Known by my characters")
eq(GoldbookWindow.status.text, "No recipes recorded yet. Open a profession window on each character, or pick All recipes.",
  "with no character's recipes recorded the status says how to record them")
click(GoldbookWindow.filters.clear)
Stub.fire("TRADE_SKILL_UPDATE")
Stub.advance(0.3)
chip("craft", "Alchemy")
GoldbookWindow.search:SetText("a")
click(GoldbookWindow.rows[2].hit)
Stub.alt = true
click(GoldbookWindow.rows[1].hit)
Stub.alt = false
eq(head() .. " / " .. choices(GoldbookWindow.modes) .. " / " .. GoldbookWindow.head.back.label.text,
  "Flask of the Titans | 108g 41s 30c | Alchemy +43% / History [Crafting] / Back to Crafting",
  "Alt+click opens the recipe on the item page")
click(GoldbookWindow.modes.buttons[1])
click(GoldbookWindow.head.back)
eq(tostring(GoldbookWindow.tabs.crafting.selected.shown) .. " / " .. GoldbookWindow.filters.controls.craft.label.text .. " / "
  .. GoldbookWindow.search.text .. " / " .. picked(), "true / Alchemy / a / 2", "Back from either mode returns to the tab as it was left")

Stub.spells = { [17571] = true }
Stub.fire("NEW_RECIPE_LEARNED")
eq(known("Sultan-Faramon"), "11479 17571 17635", "a recipe the client says the character knows is recorded")

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
