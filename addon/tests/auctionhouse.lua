local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local server = dofile(here .. "/auctionstub.lua")(Stub)
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
server.seed()
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
  House.Search("ore")
  Stub.advance(0.3)
  for _, item in ipairs(House.rows) do if item.itemKey.itemID == id then House.Select(item); Stub.advance(0.3); return end end
  error("item not found")
end
local function reopen()
  Stub.fire("AUCTION_HOUSE_CLOSED")
  Stub.fire("AUCTION_HOUSE_SHOW")
  Stub.ah.ready = true
end

eq(House.Search("ore"), false, "closed house cannot search")
Stub.fire("AUCTION_HOUSE_SHOW")
SlashCmdList.GOLDBOOK("ah")
local panel = GoldbookAuctionHouse
eq(panel.shown, true, "slash command opens auction panel")
panel.search:SetText("ore")
click(panel.searchButton)
Stub.advance(0.3)
eq(#House.rows, 2, "browse first page")
eq(House.more, true, "browse exposes pagination")
click(panel.more)
Stub.advance(0.3)
eq(#House.rows, 3, "browse second page")
click(panel.rows[1])
Stub.advance(0.3)
eq(#House.offers, 2, "commodity listings loaded")
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
server.seed()
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

server.seed()
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
server.seed()
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
server.seed()
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
server.seed()
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

ns.UI.SetTheme("light")
eq(GoldbookAuctionHouse.scale, ns.UI.Scale(), "panel follows shared scale")
ns.UI.SetScale(0.8)
eq(GoldbookAuctionHouse.scale, 0.8, "scale change reaches auction panel")
Stub.fire("AUCTION_HOUSE_CLOSED")
eq(panel.shown, false, "auction close hides panel")
eq(#House.rows, 0, "auction close clears actionable results")
io.write(checks .. " auction house checks passed.\n")
