-- A character on a WoW Forever shard, with the prices the Goldbook app brought
-- from the server: the window and /gb name the auction house the shards share.
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
local function printed(back)
  return (Stub.printed[#Stub.printed - (back or 0)]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

for realm, house in pairs({
  CAMWOWEU4Realm8PvP = "EU PvP", CAMWOWEU4Realm6PvP = "EU PvP", CAMWOWEU12Realm8PvP = "EU PvP",
  CAMWOWUS4Realm8PvP = "US PvP", CAMWOWEU4Realm2RP = "EU RP", CAMWOWEU4Realm8PvE = "EU PvE",
  CAMWOWEU4Realm3 = "EU Normal", CAMWOWUS1Realm3 = "US Normal",
  Faramon = "Faramon", ["Pyrewood Village"] = "Pyrewood Village", ClassicBetaPvP2 = "ClassicBetaPvP2",
  CAMWOWEU4RealmPvP = "CAMWOWEU4RealmPvP", CAMWOWEU4Realm = "CAMWOWEU4Realm", CAMWOWRealm8PvP = "CAMWOWRealm8PvP",
  CAMWOW4Realm8PvP = "CAMWOW4Realm8PvP", CAMWOWEURealm8PvP = "CAMWOWEURealm8PvP",
  CAMWOWEU4Realm8PvP2 = "CAMWOWEU4Realm8PvP2", ["CAMWOWEU4Realm8Pv-P"] = "CAMWOWEU4Realm8Pv-P",
  camwowEU4Realm8PvP = "camwowEU4Realm8PvP", [""] = "", ["EU PvP"] = "EU PvP",
}) do
  eq(ns.Database.House(realm), house, "the house of " .. realm)
end

function GetNormalizedRealmName()
  return Stub.loggedIn and "CAMWOWEU4Realm6PvP" or nil
end
function GetRealmName()
  return "CAMWOWEU4Realm6PvP"
end
local served = time() - 600
GoldbookServerData = {
  version = 1, server = "x",
  items = { ["2589"] = "1|Linen Cloth" },
  realms = { ["CAMWOWEU4Realm6PvP-Horde"] = { scannedAt = served, prices = { ["2589"] = "10000,50,3," .. served .. ",0,0" } } },
}
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
UIParent:SetSize(1920, 1080)

eq(ns.RealmKey(), "CAMWOWEU4Realm6PvP-Horde", "prices stay filed under the shard")
SlashCmdList.GOLDBOOK("show")
eq(GoldbookWindow.head.sub.text, "1 item scanned on EU PvP-Horde", "the price list names the auction house")
SlashCmdList.GOLDBOOK("item nothing like it")
eq(printed(), "Goldbook No item priced on EU PvP-Horde matches \"nothing like it\". Type /gb item <link or name>.",
  "/gb item names the auction house")
SlashCmdList.GOLDBOOK("status")
eq(printed(1):match("%d+ items priced on [^,]+"), "1 items priced on EU PvP-Horde", "/gb status names the auction house")

io.write(("%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
