-- Hotfixes change what vendors pay. The weekly reset of 2026-11-10 cut Iron
-- Grenade on WoW Forever from 5s to 1s 25c, while Goldbook kept the 5s it had
-- stored and listed grenades at 3s 90c as a vendor deal.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")

local checks, failures = 0, 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(label, tostring(expected), tostring(actual)))
  end
end

local seen = time()
GoldbookDB = ns.Database.Init(nil)
GoldbookDB.vendor = { [4390] = 500, [2892] = 0, [2589] = 13, [5001] = 700 }
GoldbookDB.scanned["Faramon-Horde"] = seen
GoldbookDB.prices["Faramon-Horde"] = { ["4390"] = "390,4326,101," .. seen .. ",482," .. seen .. ";1900,896,769,550,390;" }
Stub.items[4390] = { name = "Iron Grenade", quality = 1, vendor = 125, cached = true }
Stub.items[2892] = { name = "Deadly Poison", quality = 1, vendor = 30, cached = true }
Stub.items[2589] = { name = "Linen Cloth", quality = 1, vendor = 13, cached = true }
Stub.items[5001] = { name = "Lost Item", quality = 1, vendor = 0, cached = false, delay = math.huge }

Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
Stub.advance(1)

local vendor = GoldbookDB.vendor
eq(vendor[4390], 125, "a vendor price a hotfix lowered is read again at login")
eq(vendor[2892], 30, "a vendor price a hotfix raised from nothing is read again at login")
eq(vendor[2589], 13, "an unchanged vendor price stays")
eq(vendor[5001], 700, "a vendor price whose item does not load keeps what was stored")
eq(#ns.Advisor.Deals(GoldbookDB, ns.RealmKey(), 1000), 0, "grenades at 3s 90c are no vendor deal once a vendor pays 1s 25c")

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
