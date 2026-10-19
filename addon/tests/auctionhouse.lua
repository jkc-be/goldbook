local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local server = dofile(here .. "/auctionstub.lua")(Stub)
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
server.seed(); server.cache(ns)
UIParent:SetSize(1920, 1080)
local House, Rules = ns.AuctionHouse, ns.AuctionRules
local checks = 0
local function eq(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function click(widget)
  assert(widget.enabled ~= false, "button is disabled: " .. (widget.label and widget.label.text or ""))
  widget.scripts.OnClick(widget)
end
local function search(id)
  House.Dismiss()
  House.Search("")
  Stub.advance(0.3)
  for _, item in ipairs(House.rows) do if item.itemKey.itemID == id then House.Select(item); Stub.advance(1); return end end
  error("item not found")
end
local function reopen()
  Stub.fire("AUCTION_HOUSE_CLOSED")
  Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.ah.ready = true
end

eq(House.Search(""), false, "closed house cannot search")
Stub.fire("AUCTION_HOUSE_SHOW")
SlashCmdList.GOLDBOOK("ah")
local panel = GoldbookAuctionHouse
eq(panel.shown, true, "slash command opens auction panel")
eq(AuctionHouseFrame:GetAlpha(), 0, "Blizzard window is hidden by default")
eq(panel.themeButton, nil, "theme button is removed")
eq(panel.blizzardToggle, nil, "Blizzard toolbar button is removed")
eq(panel.groupButton.shown, false, "groups are absent from the main toolbar")
local preferences = Stub.categories[1].frame
preferences.scripts.OnShow()
eq(preferences.checks.hideBlizzardAH:GetChecked(), true, "hide option is checked by default")
preferences.checks.hideBlizzardAH:SetChecked(ns.db.settings.hideBlizzardAH == false)
click(preferences.checks.hideBlizzardAH)
eq(ns.db.settings.hideBlizzardAH, false, "showing Blizzard saves an explicit opt-out")
eq(AuctionHouseFrame:GetAlpha(), 1, "default can be switched off")
panel:Hide()
reopen()
ns.AuctionUI.Show()
eq(AuctionHouseFrame:GetAlpha(), 1, "explicit show preference survives reopening")
local savedPrices, savedScan = ns.db.prices[ns.RealmKey()], ns.db.scanned[ns.RealmKey()]
ns.db.prices[ns.RealmKey()], ns.db.scanned[ns.RealmKey()] = {}, nil
click(panel.searchButton)
eq(panel.empty.text, "No scan yet. Run at least a Quick scan to see reference prices.", "empty cache suggests a quick scan")
eq(panel.scanTime.text:find("Last scan: never", 1, true) ~= nil, true, "missing scan time is explicit")
ns.db.prices[ns.RealmKey()], ns.db.scanned[ns.RealmKey()] = savedPrices, savedScan
panel.search:SetText("ore")
local browseCalls, offerCalls = #Stub.ah.queries, server.count("search")
click(panel.searchButton)
eq(#House.rows, 2, "cached name search is immediate")
eq(House.Busy(), false, "cached browsing does not wait on the auction server")
eq(#Stub.ah.queries, browseCalls, "cached search sends no browse query")
eq(server.count("search"), offerCalls, "cached search sends no listing query")
eq(House.more, false, "scan rows need no server pagination")
eq(panel.priceHeader.text, "SCAN UNIT PRICE", "reference prices are labelled")
eq(panel.scanTime.text:find(date("%d %b %H:%M", savedScan), 1, true) ~= nil, true, "last scan timestamp is displayed")
Stub.fire("ITEM_KEY_ITEM_INFO_RECEIVED", { itemID = 2770 })
eq(#House.rows, 2, "background metadata does not replace cached results")
eq(panel.rows[1].icon.texture, 134566, "browse shows the item icon")
click(panel.rows[1])
Stub.advance(1)
eq(#Stub.ah.queries, browseCalls + 1, "opening an item resolves its current variant")
eq(server.count("search"), offerCalls + 1, "opening an item fetches live listings")
eq(#House.offers, 2, "commodity listings loaded")
eq(panel.rows[1].icon.texture, 134566, "commodity order book keeps the item icon")
eq(panel.rows[2].icon.texture, 134566, "each commodity listing keeps the icon")
click(panel.rows[1])
panel.quantity:SetText("4")
click(panel.action)
eq(server.count("buy-commodity"), 0, "review does not purchase")
Stub.advance(0.2)
eq(House.Review().total, 500, "review uses server total")
eq(panel.review.confirm.enabled, true, "quote is confirmable")
Stub.advance(10)
eq(House.Review(), nil, "expired quote is removed")
eq(server.count("buy-commodity"), 0, "expiry does not purchase")
House.ReviewBuy(House.offers[1], 4)
Stub.advance(0.2)
House.Confirm()
House.Confirm()
eq(server.count("buy-commodity"), 1, "double click purchases once")
Stub.fire("COMMODITY_PURCHASE_SUCCEEDED")
eq(House.phase, "idle", "purchase completes on server event")

search(1206)
eq(panel.rows[1].icon.texture, 134105, "item order book keeps the item icon")
eq(House.ReviewBuy(House.offers[1], 1), true, "whole item listing can be reviewed")
eq(House.Review().quantity, 2, "item quantity is whole listing")
server.offers[1206][1].buyoutAmount = 110000
eq(House.Confirm(), false, "changed listing cannot be bought")
eq(server.count("buy-item"), 0, "changed listing never submitted")
search(1206)
House.ReviewBuy(House.offers[1], 1)
Stub.money = 0
eq(House.Confirm(), false, "insufficient gold")
Stub.money = 5000000

House.SetMode("sell")
House.Select(House.rows[1])
eq(House.ReviewPost(5, 200, 2), true, "posting review")
eq(House.Review().total, 1000, "posting unit price multiplied")
Stub.bags[0][1].hyperlink = "|Hitem:2771|h[Tin Ore]|h"
eq(House.Confirm(), false, "bag slot replacement refused")
eq(server.count("post-commodity"), 0, "replacement never posted")
server.seed(); server.cache(ns)
House.SetMode("sell")
House.Select(House.rows[1])
House.ReviewPost(5, 200, 2)
House.Confirm()
eq(server.count("post-commodity"), 1, "explicit click posts commodity")
ns.Scanner.Start("browse")
eq(ns.Scanner.state, "idle", "scan cannot interrupt transaction")
Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 300)
eq(House.phase, "idle", "post finishes on server event")
House.SetMode("owned")
Stub.advance(0.2)
House.Select(House.rows[1])
House.ReviewCancel()
server.cancelCost = 100
eq(House.Confirm(), false, "changed cancellation cost refused")
House.ReviewCancel()
House.Confirm()
eq(server.count("cancel"), 1, "cancellation submitted once")
Stub.fire("AUCTION_CANCELED", 999)
eq(House.phase, "cancel", "unrelated cancellation ignored")
Stub.fire("AUCTION_CANCELED", 201)
eq(House.phase, "idle", "matching cancellation accepted")

search(2770)
House.ReviewBuy(House.offers[1], 4)
Stub.advance(0.2)
C_AuctionHouse.SendSearchQuery({ itemID = 1206 })
eq(House.Review(), nil, "another addon invalidates quote")
eq(#House.offers, 0, "another addon's results cannot be purchased")
Stub.advance(0.3)
server.silent = true
House.Find({ itemKey = { itemID = 2770 }, name = "Copper Ore", commodity = true })
Stub.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2771)
eq(House.phase, "offers", "unrelated results ignored")
Stub.advance(21)
eq(House.phase, "idle", "search timeout recovers")
server.silent = false
search(2770)
House.ReviewBuy(House.offers[1], 4)
Stub.advance(0.2)
House.Confirm()
Stub.advance(21)
eq(House.phase, "uncertain", "unacknowledged transaction stays locked")
eq(House.Dismiss(), false, "uncertain transaction cannot be retried")
reopen()
eq(House.phase, "idle", "new auction session resets lock")

local input = { name = "Ore", items = "2770,2771", minimum = "1s", normal = "2s", maximum = "5s", shopping = "3s",
  undercut = "1", cap = "10", stack = "4", duration = "2", below = "skip", above = "normal" }
eq(Rules.Price("12g 34s 56c", {}), 123456, "coin expression")
eq(Rules.Price("120% market", { market = 1000 }), 1200, "percentage expression")
eq(Rules.Price("120% market", {}), nil, "missing source is not zero")
eq(Rules.Price("os.execute('bad')", {}), nil, "no executable expressions")
eq(Rules.Save(input), true, "save posting rule")
local rule = Rules.Saved()[1]
local plan = Rules.Evaluate(rule, {}, 125, 3)
eq(plan.price, 124, "undercut by copper")
eq(plan.quantity, 7, "post cap subtracts existing quantity")
eq(Rules.Evaluate(rule, {}, 50, 0), nil, "below minimum skips")
eq(Rules.Evaluate(rule, {}, 200, 10), nil, "cap skips")
eq(Rules.Evaluate(rule, {}, 999, 0).price, 200, "above maximum returns normal")
input.name = "Duplicate"
eq(Rules.Save(input), false, "overlapping groups rejected")
input.name = "Ore"

server.seed(); server.cache(ns)
ns.AuctionUI.Show()
click(panel.tabs.queue)
click(panel.scans[1])
Stub.advance(2)
eq(Rules.running, false, "posting scan completes")
eq(#Rules.queue, 4, "queue splits stacks and honors post cap")
eq(Rules.queue[1].quantity, 4, "first posting stack")
eq(Rules.queue[2].quantity, 3, "remaining quantity under cap")
eq(Rules.queue[1].unitPrice, 124, "queue uses live competitor")
eq(server.count("post-commodity"), 1, "scan itself posts nothing")
click(panel.rows[1])
click(panel.action)
eq(House.phase, "ready", "queue action is reviewed")
click(panel.review.confirm)
eq(server.count("post-commodity"), 2, "queue confirm posts")
Stub.bags[0][1].stackCount = 8
Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 301)
eq(Rules.queue[1].done, true, "completed queue row marked")
eq(Rules.Execute(Rules.queue[1]), false, "completed row cannot run again")

Rules.Start("cancel")
Stub.advance(2)
eq(#Rules.queue, 1, "undercut scan queues owned auction")
eq(Rules.queue[1].kind, "cancel", "undercut action")
Rules.Start("shop")
Stub.advance(2)
eq(#Rules.queue, 2, "shopping scans group items")
eq(Rules.queue[1].kind, "shop", "shopping finds matching listings")

Rules.Start("post")
Rules.Stop()
local searches = server.count("search")
Stub.advance(2)
eq(server.count("search"), searches, "stop cancels scheduled scan requests")
Rules.Start("post")
Stub.advance(0.2)
C_AuctionHouse.SendSearchQuery({ itemID = 1206 })
Stub.advance(1)
eq(Rules.running, false, "external query stops automated scan")
eq(#Rules.queue, 0, "interrupted scan clears queue")

-- A mixed commodity price level still contains competitors when some of its
-- items are ours. Fully owned cheaper levels must not cause self-undercuts.
server.seed(); server.cache(ns)
server.offers[2770] = {
  { unitPrice = 110, quantity = 3, numOwnerItems = 3, containsOwnerItem = true, owners = { "player" } },
  { unitPrice = 125, quantity = 20, numOwnerItems = 2, containsOwnerItem = true, owners = { "player", "Miner" } },
}
Rules.Start("post")
Stub.advance(2)
eq(Rules.queue[1].unitPrice, 124, "mixed commodity level includes competing quantity")
local queued = Rules.queue[1]
eq(Rules.Execute(queued), true, "review queued post")
House.Dismiss()
House.SetMode("sell")
House.Select(House.rows[2])
eq(House.ReviewPost(2, 60000, 3), false, "ordinary items cannot trigger a multisell")
House.ReviewPost(1, 60000, 3)
House.Confirm()
local last = server.calls[#server.calls]
eq(last.name, "post-item", "ordinary item posting uses item API")
eq(last.args[5], 60000, "ordinary item API receives per-item buyout")
Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 400)
eq(queued.done, nil, "abandoned queue review is not completed by a manual post")

Rules.Start("post")
Stub.advance(2)
queued = Rules.queue[1]
Stub.advance(301)
eq(Rules.Execute(queued), false, "old queue action expires")
Rules.Start("post")
Stub.advance(2)
queued = Rules.queue[1]
reopen()
eq(Rules.Execute(queued), false, "queue cannot survive a new auction session")

-- Complete pagination is required before producing a rule action.
server.seed(); server.cache(ns)
server.complete = false
Rules.Start("post")
Stub.advance(2)
eq(Rules.running, false, "rule scan loads remaining search pages")
eq(#Rules.queue, 4, "completed search produces queue")
server.silent = true
Rules.Start("post")
Stub.advance(21)
eq(Rules.running, false, "owned auction timeout stops scan")
eq(#Rules.queue, 0, "timed out scan has no actionable rows")
server.silent = false
House.Find({ itemKey = { itemID = 999999 }, name = "Uncached item" })
eq(House.phase, "idle", "uncached item waits for metadata before searching")

-- Throttled read requests may defer; trade actions never run from timers.
server.seed(); server.cache(ns)
Stub.ah.ready = false
local calls = server.count("search")
House.Find({ itemKey = { itemID = 2770 }, name = "Copper Ore" })
eq(server.count("search"), calls, "throttled search deferred")
Stub.ah.ready = true
Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
Stub.advance(0.3)
eq(server.count("search"), calls + 1, "search resumes when ready")
House.ReviewBuy(House.offers[1], 4)
Stub.advance(0.2)
local purchases = server.count("buy-commodity")
Stub.ah.ready = false
eq(House.Confirm(), false, "throttled confirmation requires another click")
Stub.ah.ready = true
Stub.fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
eq(server.count("buy-commodity"), purchases, "readiness event never purchases")
House.Dismiss()
ns.AuctionUI.Show()

-- The same inventory shortcut works with Command on Mac and Ctrl on Windows.
local function inventoryClick(slot)
  HandleModifiedItemClick(Stub.bags[0][slot] and Stub.bags[0][slot].hyperlink,
    ItemLocation:CreateFromBagAndSlot(0, slot))
end
for _, platform in ipairs({ "Mac", "Windows" }) do
  Stub.mac, Stub.meta, Stub.ctrl = platform == "Mac", platform == "Mac", platform == "Windows"
  click(panel.tabs.sell)
  panel:Hide()
  reopen()
  calls = server.count("search")
  inventoryClick(1)
  eq(panel.shown, true, platform .. " shortcut opens the panel")
  eq(server.count("search"), calls + 1, platform .. " shortcut searches the bag item")
  inventoryClick(1)
  eq(server.count("search"), calls + 1, platform .. " duplicate hooks do not repeat a pending search")
  Stub.advance(0.3)
  eq(panel.search.text, "Copper Ore", platform .. " shortcut updates the search field")
  eq(panel.rows[1].item.price, 125, platform .. " shortcut displays live offers")
end

calls = server.count("search")
Stub.ctrl = false
inventoryClick(1)
Stub.meta = true
inventoryClick(1)
eq(server.count("search"), calls, "plain click and Windows key do not search")
Stub.ctrl, Stub.meta, Stub.shift = true, false, true
inventoryClick(1)
Stub.shift, Stub.alt = false, true
inventoryClick(1)
Stub.alt, Stub.mouseButton = false, "RightButton"
inventoryClick(1)
Stub.mouseButton = "LeftButton"
HandleModifiedItemClick(Stub.bags[0][1].hyperlink)
inventoryClick(99)
HandleModifiedItemClick(Stub.bags[0][1].hyperlink, { IsBagAndSlot = function() return false end })
eq(server.count("search"), calls, "other chords, links, empty slots and equipment do not search")

House.ReviewBuy(House.offers[1], 1)
Stub.advance(0.2)
local quote = House.Review()
inventoryClick(2)
eq(House.Review(), quote, "shortcut preserves the purchase review")
eq(server.count("search"), calls, "shortcut does not query during a review")
House.Dismiss()
Rules.Start("post")
calls = server.count("search")
inventoryClick(2)
eq(Rules.running, true, "shortcut leaves automation running")
eq(server.count("search"), calls, "shortcut does not interrupt automation")
Rules.Stop()
Stub.advance(0.3)
ns.Scanner.state = "browse"
inventoryClick(2)
eq(server.count("search"), calls, "shortcut does not interrupt a price scan")
ns.Scanner.state = "idle"

Stub.bags[0][2].suffix, Stub.bags[0][2].level, Stub.bags[0][2].species = 7, 80, 42
Stub.ah.keyInfo["1206:7"] = Stub.ah.keyInfo["1206:0"]
local bagButton = { GetBagID = function() return 0 end, GetID = function() return 2 end }
ContainerFrameItemButton_OnClick(bagButton, "LeftButton")
Stub.advance(0.3)
local searchedKey = server.calls[#server.calls].args[1]
eq(searchedKey.itemID, 1206, "container shortcut searches the selected item")
eq(searchedKey.itemSuffix, 7, "shortcut retains suffix")
eq(searchedKey.itemLevel, 80, "shortcut retains item level")
eq(searchedKey.battlePetSpeciesID, 42, "shortcut retains pet species")
Stub.fire("AUCTION_HOUSE_CLOSED")
calls = server.count("search")
inventoryClick(1)
eq(panel.shown, false, "shortcut outside the auction house does not open the panel")
eq(server.count("search"), calls, "shortcut outside the auction house does not query")
Stub.ctrl = false
reopen()
server.seed(); server.cache(ns)
ns.AuctionUI.Show()

-- Duration labels, reviews and posting arguments stay aligned.
click(panel.tabs.sell)
click(panel.rows[1])
panel.quantity:SetText("1")
panel.price:SetText("2s")
for _, duration in ipairs({ { 8, 2 }, { 24, 3 }, { 2, 1 } }) do
  eq(panel.duration.label.text, duration[1] .. " hours", "sell duration label")
  click(panel.action)
  eq(panel.review.body.text:match("Duration: (%d+) hours"), tostring(duration[1]), "review duration label")
  click(panel.review.confirm)
  eq(server.calls[#server.calls].args[2], duration[2], "posting uses the matching duration enum")
  Stub.fire("AUCTION_HOUSE_AUCTION_CREATED", 500 + duration[2])
  click(panel.duration)
  click(panel.rows[1])
  panel.quantity:SetText("1")
  panel.price:SetText("2s")
end
click(panel.tabs.queue)
eq(panel.groupButton.shown, true, "groups remain available inside Automation")
click(panel.groupButton)
for _, duration in ipairs({ { 8, 2 }, { 24, 3 }, { 2, 1 } }) do
  eq(GoldbookAuctionRules.duration.label.text, duration[1] .. " hours", "rule duration label")
  eq(GoldbookAuctionRules.duration.value, duration[2], "rule duration enum")
  click(GoldbookAuctionRules.duration)
end
GoldbookAuctionRules:Hide()

-- Resizing adds visible rows, keeps pagination usable, and survives reopening.
UIParent:SetSize(1920, 1080)
ns.AuctionUI.Show()
Stub.ah.pageSize, Stub.ah.browse = 40, {}
for index = 1, 30 do
  local id = 90000 + index
  Stub.ah.browse[index] = { itemKey = { itemID = id }, minPrice = index, totalQuantity = index }
  Stub.ah.keyInfo[id .. ":0"] = { itemName = ("Test item %02d"):format(index), quality = 1 }
end
server.cache(ns)
panel.search:SetText("")
click(panel.tabs.browse)
click(panel.searchButton)
Stub.advance(0.3)
eq(panel.resizable, true, "auction window can resize")
panel.resizeGrip.scripts.OnMouseDown(panel.resizeGrip, "LeftButton")
eq(panel.sizing, "BOTTOMRIGHT", "grip starts resizing")
panel:SetSize(1300, 900)
panel.resizeGrip.scripts.OnMouseUp(panel.resizeGrip, "LeftButton")
eq(panel.sizing, nil, "release stops resizing")
eq(panel.page.text, "1–22 of 30", "taller window shows more listings")
eq(panel.rows[22].shown, true, "new row is visible")
eq(panel.rows[22].item.price, 22, "new row has the correct listing")
click(panel.next)
eq(panel.rows[22].item.price, 30, "resized pagination reaches the final listing")
panel:Hide()
reopen()
ns.AuctionUI.Show()
eq(panel:GetWidth(), 1300, "saved width restored")
eq(panel:GetHeight(), 900, "saved height restored")
click(panel.searchButton)
Stub.advance(0.3)
panel:SetSize(940, 670)
eq(panel.rows[15].shown, false, "shrinking hides surplus rows")
eq(panel.tableFrame:GetWidth(), 570, "table follows window width")
eq(panel.rows[1].price.point[2], 370, "price column follows window width")
eq(panel.action.point[3], -378, "review button follows sidebar height")
ns.db.settings.auctionSize = { 1, 9999 }
ns.AuctionUI.Show()
eq(panel:GetWidth(), 940, "saved width is clamped to minimum")
eq(panel:GetHeight(), 1080, "saved height is clamped to screen")
ns.db.settings.auctionSize = nil
ns.AuctionUI.Show()
Stub.ah.pageSize = 2
server.seed(); server.cache(ns)

-- Suppressing the native frame must never run its session-closing OnHide.
local nativeHides = 0
AuctionHouseFrame:SetScript("OnHide", function() nativeHides = nativeHides + 1; C_AuctionHouse.CloseAuctionHouse() end)
AuctionHouseFrame:SetScale(0.9)
AuctionHouseFrame:SetAlpha(0.75)
AuctionHouseFrame:EnableMouse(true)
preferences.checks.hideBlizzardAH:SetChecked(ns.db.settings.hideBlizzardAH == false)
click(preferences.checks.hideBlizzardAH)
eq(ns.db.settings.hideBlizzardAH, true, "hide preference is saved")
eq(AuctionHouseFrame:GetAlpha(), 0, "native auction house is invisible")
eq(AuctionHouseFrame:IsMouseEnabled(), false, "native auction house cannot intercept clicks")
eq(AuctionHouseFrame:IsShown(), true, "native auction session stays open")
eq(nativeHides, 0, "hide preference never calls native OnHide")
Stub.ctrl = true
inventoryClick(1)
Stub.advance(0.3)
eq(panel.rows[1].item.price, 125, "inventory shortcut works with Blizzard hidden")
Stub.ctrl = false
panel:Hide()
eq(AuctionHouseFrame:GetScale(), 0.9, "closing Goldbook restores original native scale")
eq(AuctionHouseFrame:GetAlpha(), 0.75, "closing Goldbook restores original native alpha")
eq(AuctionHouseFrame:IsMouseEnabled(), true, "closing Goldbook restores native mouse input")
eq(House.open, false, "closing Goldbook ends the auction session")
eq(AuctionHouseFrame:IsShown(), false, "closing Goldbook closes Blizzard too")
reopen()
ns.AuctionUI.Show()
eq(AuctionHouseFrame:GetAlpha(), 0, "reopening applies saved hide preference")
preferences.checks.hideBlizzardAH:SetChecked(ns.db.settings.hideBlizzardAH == false)
click(preferences.checks.hideBlizzardAH)
eq(ns.db.settings.hideBlizzardAH, false, "show button clears hide preference")
eq(AuctionHouseFrame:GetAlpha(), 0.75, "show button restores native window")
local options = Stub.categories[1].frame
options.checks.hideBlizzardAH:SetChecked(true)
click(options.checks.hideBlizzardAH)
eq(AuctionHouseFrame:GetAlpha(), 0, "options checkbox applies immediately")
Stub.fire("AUCTION_HOUSE_CLOSED")
eq(AuctionHouseFrame:GetAlpha(), 0.75, "leaving auction house restores native window")
reopen()
eq(AuctionHouseFrame:GetAlpha(), 0.75, "native window stays visible until Goldbook opens")
ns.AuctionUI.Show()
eq(AuctionHouseFrame:GetAlpha(), 0, "new session applies saved hide preference when Goldbook opens")
eq(nativeHides, 1, "only closing Goldbook invokes native OnHide")
ns.AuctionUI.SetHideBlizzard(false)

-- Auction filters use the same choices and combinations as Market.
local function chooseFilter(name, text)
  click(panel.filters.controls[name])
  for _, option in ipairs(panel.filterMenu.options) do
    if option.shown and option.label.text == text then click(option); return end
  end
  error("missing filter option: " .. text)
end
local function visibleNames()
  local names = {}
  for _, row in ipairs(panel.rows) do if row.shown then names[#names + 1] = row.item.name end end
  return table.concat(names, ", ")
end
server.seed(); server.cache(ns)
Stub.ah.pageSize = 50
panel.search:SetText("")
click(panel.tabs.browse)
click(panel.searchButton)
Stub.advance(0.3)
chooseFilter("profession", "Mining")
eq(visibleNames(), "Copper Ore, Tin Ore", "profession filters cached browse results")
eq(panel.filters.controls.kind.label.text, "Materials  v", "profession defaults to materials like Market")
chooseFilter("quality", "Uncommon")
eq(visibleNames(), "", "quality combines with profession")
chooseFilter("profession", "All professions")
eq(visibleNames(), "Moss Agate", "uncommon quality works across professions")
chooseFilter("quality", "All qualities")
chooseFilter("kind", "Crafted items")
eq(visibleNames(), "", "crafted filter excludes raw materials")
click(panel.filters.clear)
eq(visibleNames(), "Copper Ore, Moss Agate, Tin Ore", "clear filters restores cached browse results")
click(panel.tabs.sell)
chooseFilter("quality", "Uncommon")
eq(visibleNames(), "Moss Agate", "quality filters inventory stacks")
click(panel.tabs.owned)
Stub.advance(0.3)
eq(visibleNames(), "", "quality filters owned auctions")
click(panel.filters.clear)
eq(visibleNames(), "Copper Ore", "clear restores owned auctions")

-- Grouping only affects browsing. Each expanded row keeps its exact key.
server.seedVariants(); server.cache(ns)
click(panel.tabs.browse)
click(panel.searchButton)
Stub.advance(0.3)
click(panel.stack)
eq(ns.db.settings.groupAuctionVariants, true, "stack preference is saved")
eq(panel.page.text, "1–2 of 2", "variants collapse to one row")
eq(panel.rows[1].item.name, "Battle Knife", "group uses the base item name")
eq(panel.rows[1].item.quantity, 6, "group adds quantities")
eq(panel.rows[1].item.price, 100, "group shows cheapest variant")
calls = server.count("search")
click(panel.rows[1])
eq(panel.page.text, "1–3 of 3", "stack expands into individual variants")
eq(server.count("search"), calls, "expanding a stack does not choose an arbitrary variant")
click(panel.rows[2])
Stub.advance(1)
local exactKey = server.calls[#server.calls].args[1]
eq(exactKey.itemSuffix, 103, "expanded variant search preserves suffix")
eq(exactKey.itemLevel, 23, "expanded variant search preserves item level")
Stub.advance(0.3)
eq(panel.rows[1].icon.texture, 135641, "expanded variant order book has the icon")
eq(panel.stack.shown, false, "stack toggle is absent from an exact order book")
click(panel.back)
Stub.advance(0.3)
click(panel.rows[1])
click(panel.back)
eq(panel.page.text, "1–2 of 2", "back returns to grouped browse results")
click(panel.stack)
eq(panel.page.text, "1–4 of 4", "stack toggle restores individual browse rows")

-- Classic categories filter locally and preserve the hierarchy through armor slots.
local function categoryChoice(depth, text, hover)
  for _, option in ipairs(panel.categoryMenus[depth].options) do
    if option.shown and option.label.text == text then
      if hover then option.scripts.OnEnter(option) else click(option) end
      return
    end
  end
  error("missing category: " .. text)
end
local categoryQueries = #Stub.ah.queries
click(panel.filters.category)
categoryChoice(1, "Weapons  >", true)
categoryChoice(2, "Daggers")
eq(visibleNames(), "Battle Knife of Agility, Battle Knife of Stamina, Battle Knife of Strength", "weapon submenu filters variants")
eq(panel.filters.category.label.text, "Daggers  v", "selected category is visible")
eq(panel.categoryMenus[1].shown, false, "choosing a category closes the menu")
eq(panel.categoryMenus[2].shown, false, "choosing a category closes submenus")
chooseFilter("profession", "Mining")
eq(visibleNames(), "", "category combines with profession")
click(panel.filters.clear)
eq(panel.filters.category.label.text, "All categories  v", "clear resets category too")
click(panel.filters.category)
categoryChoice(1, "Weapons  >")
categoryChoice(2, "All Weapons")
eq(panel.page.text, "1–3 of 3", "parent category includes all its subclasses")
click(panel.filters.clear)
for index, item in ipairs({ { "Cloth Shirt", 1, 5 }, { "Cloth Robe", 1, 20 }, { "Cloth Hat", 1, 1 }, { "Leather Vest", 2, 5 } }) do
  local id = 91000 + index
  Stub.items[id] = { name = item[1], quality = 1, cached = true, classID = 4, subClassID = item[2], inventoryType = item[3] }
  Stub.ah.keyInfo[id .. ":0"] = { itemName = item[1], quality = 1 }
  Stub.ah.browse[#Stub.ah.browse + 1] = { itemKey = { itemID = id }, minPrice = 500, totalQuantity = 1 }
end
server.cache(ns)
click(panel.searchButton)
click(panel.filters.category)
categoryChoice(1, "Armor  >")
categoryChoice(2, "Cloth  >", true)
categoryChoice(3, "Chest")
eq(visibleNames(), "Cloth Robe, Cloth Shirt", "armor slot includes robes and excludes head and leather")
eq(#Stub.ah.queries, categoryQueries, "category navigation sends no auction query")
click(panel.filters.category)
chooseFilter("quality", "Common")
eq(panel.categoryMenus[1].shown, false, "opening another filter closes categories")
click(panel.filters.clear)

-- Cached prices never authorize a purchase and never substitute a different suffix.
server.seedVariants(); server.cache(ns)
click(panel.searchButton)
local stale = House.rows[1]
eq(stale.price, 200, "scan reference retains its observed price")
server.offers[15241][1].buyoutAmount = 900
House.Select(stale)
Stub.advance(1)
eq(House.offers[1].price, 900, "opening an item replaces scan reference with current price")
eq(House.Review(), nil, "live lookup does not create a purchase review")
House.Search("")
local missing = House.rows[1]
Stub.ah.browse[2] = { itemKey = { itemID = 2770 }, minPrice = 125, totalQuantity = 20 }
House.Select(missing)
Stub.advance(1)
eq(#House.rows, 0, "missing suffix does not fall back to a different variant")
eq(#House.offers, 0, "stale scan has no actionable offers")
eq(House.message, "No current listings for this item. Scan prices may be out of date.", "missing live listing is explained")
server.seedVariants(); server.cache(ns)
local duplicate = { itemKey = { itemID = 15241, itemSuffix = 102, itemLevel = 55 }, minPrice = 700, totalQuantity = 1 }
Stub.ah.browse[#Stub.ah.browse + 1] = duplicate
House.Search("")
House.Select(House.rows[1])
Stub.advance(1)
eq(House.context, "variants", "multiple current item levels require a choice")
eq(#House.rows, 2, "only matching item and suffix are offered")
eq(panel.rows[2].title.text, "Battle Knife of Agility (item level 55)", "live variant choice identifies its item level")
House.Select(House.rows[2])
Stub.advance(0.3)
eq(server.calls[#server.calls].args[1].itemLevel, 55, "chosen live level is preserved in listing query")
click(panel.back)
eq(House.context, "browse", "back restores scan references")

-- Deals share the advisor and minimum profit with Market; buying starts live.
server.seed(); server.cache(ns)
ns.db.settings.minProfit = 0
ns.Database.ApplyScan(ns.db, { realm = "Faramon", faction = "Horde", region = "EU", by = "Test", build = "1", at = time(), mode = "replicate",
  rows = { { key = "2770", min = 125, mv = 500, qty = 50, n = 2 }, { key = "1206", min = 100, mv = 500, qty = 2, n = 1 } },
  names = { ["2770"] = { name = "Copper Ore", quality = 1 }, ["1206"] = { name = "Moss Agate", quality = 2 } } })
click(panel.tabs.deals)
panel.search:SetText("")
eq(visibleNames(), "Moss Agate, Copper Ore", "deals use Market profit ordering")
eq(panel.priceHeader.text, "EST. PROFIT", "deal rows show estimated profit")
chooseFilter("quality", "Uncommon")
eq(visibleNames(), "Moss Agate", "quality filters deals")
click(panel.filters.clear)
panel.search:SetText("copper")
eq(visibleNames(), "Copper Ore", "deals filter as names are typed")
click(panel.rows[1])
eq(panel.action.label.text, "Find live listings", "deal requires current listing search")
local buysBefore = server.count("buy-commodity") + server.count("buy-item")
click(panel.action)
Stub.advance(1)
eq(House.context, "offers", "opening a deal fetches live listings")
eq(House.text, "Copper Ore", "opening a deal keeps its item name")
eq(server.count("buy-commodity") + server.count("buy-item"), buysBefore, "opening a deal never buys from saved prices")

-- Scan controls feed the same database and refresh the open Deals view.
click(panel.tabs.deals)
panel.search:SetText("")
ns.db.vendor[2770] = 1000
click(panel.quickScan)
eq(ns.Scanner.state, "scanning", "quick scan starts from auction panel")
eq(panel.fullScan.enabled, false, "second scan is disabled while scanning")
eq(panel.action.enabled, false, "deal action is disabled while scanning")
Stub.advance(2)
eq(ns.Scanner.state, "idle", "quick scan finishes")
eq(visibleNames(), "Copper Ore", "scan refreshes open Deals from new data")
eq(panel.rows[1].item.total, 875, "deal profit reflects fresh scan")
eq(panel.status.text, "Scan complete. 1 deal found.", "scan completion is visible")
Stub.ah.replicate = { { itemID = 2770, count = 5, buyout = 500, quality = 1, link = "|Hitem:2770|h[Copper Ore]|h" } }
ns.db.settings.lastReplicate = nil
click(panel.fullScan)
Stub.advance(2)
eq(ns.Scanner.state, "idle", "full scan finishes from auction panel")
eq(ns.db.scans[#ns.db.scans].mode, "replicate", "full button records a full scan")
click(panel.fullScan)
eq(ns.Scanner.state, "idle", "full scan cooldown is preserved")
eq(panel.status.text:find("available again", 1, true) ~= nil, true, "full scan cooldown is explained")
click(panel.tabs.browse)
panel.search:SetText("ore")
click(panel.searchButton)
Stub.ah.browse[1].minPrice = 175
click(panel.quickScan)
Stub.advance(2)
eq(House.rows[1].price, 175, "completed quick scan refreshes the open cached browse list")
eq(House.context, "browse", "scan completion stays in reference browse")
eq(panel.scanTime.text:find(date("%d %b %H:%M", ns.db.scanned[ns.RealmKey()]), 1, true) ~= nil, true, "completed scan updates the timestamp")
Stub.ah.silent = true
click(panel.quickScan)
panel:Hide()
eq(ns.Scanner.state, "idle", "closing panel stops its scan through auction close")
eq(House.open, false, "closing during a scan closes the session")
Stub.ah.silent = false
reopen()
ns.AuctionUI.Show()

ns.UI.SetTheme("light")
eq(GoldbookAuctionHouse.scale, ns.UI.Scale(), "panel follows shared scale")
ns.UI.SetScale(0.8)
eq(GoldbookAuctionHouse.scale, 0.8, "scale change reaches auction panel")
Stub.fire("AUCTION_HOUSE_CLOSED")
eq(panel.shown, false, "auction close hides panel")
eq(#House.rows, 0, "auction close clears actionable results")
io.write(checks .. " auction house checks passed.\n")
