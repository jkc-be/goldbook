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

-- scans = { { at, { [key] = lowest buyout } } }, oldest first; merchant and
-- vendor prices by item id.
local function market(scans, merchant, vendor)
  local db = Database.Init(nil)
  for _, scan in ipairs(scans) do
    local rows = {}
    for key, min in pairs(scan[2]) do
      rows[#rows + 1] = { key = key, min = min, mv = 0, qty = 5, n = 1 }
    end
    Database.ApplyScan(db, { realm = "Faramon", faction = "Horde", region = "EU", at = scan[1], mode = "browse", by = "Test",
      build = "1", rows = rows, names = {} })
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

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
