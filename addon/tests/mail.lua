-- Lists a simulated mailbox in the Mail view, filters it, and collects it
-- one take at a time until it is done or something stops it.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local Stub = dofile(here .. "/wowstub.lua")
local ns = Stub.loadAddon(here .. "/../Goldbook")
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.fire("PLAYER_LOGIN")
local Mail = ns.Mail

local checks, failures = 0, 0
local function eq(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    io.stderr:write(("FAIL %s\n  expected: %s\n  actual:   %s\n"):format(label, tostring(expected), tostring(actual)))
  end
end

local function plain(text)
  return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function lastPrint()
  return plain(Stub.printed[#Stub.printed])
end

-- A row as its cells and, in brackets, its tag.
local function row(index)
  local drawn = GoldbookWindow.rows[index]
  local texts = {}
  for _, cell in ipairs(drawn.cells) do
    if cell.shown then
      texts[#texts + 1] = plain(cell.text)
    end
  end
  return table.concat(texts, " | ") .. (drawn.tag.shown and (" [" .. drawn.tag.label.text .. "]") or "")
end

-- Every row with something in it, one per line.
local function rows()
  local lines = {}
  for index = 1, #GoldbookWindow.rows do
    if GoldbookWindow.rows[index].rule.shown then
      lines[#lines + 1] = row(index)
    end
  end
  return table.concat(lines, "\n")
end

local function head()
  local window = GoldbookWindow.head
  return plain(table.concat({ window.title.text, window.sub.text, window.aside.text }, " | "))
end

local function segments()
  local texts = {}
  for _, button in ipairs(GoldbookWindow.segments.buttons) do
    if button.shown then
      texts[#texts + 1] = button.picked.shown and ("[" .. plain(button.label.text) .. "]") or plain(button.label.text)
    end
  end
  return table.concat(texts, " ")
end

local function segment(index)
  local button = GoldbookWindow.segments.buttons[index]
  button.scripts.OnClick(button)
end

-- The button right of the status line, as its label and whether it can be clicked.
local function action()
  local button = GoldbookWindow.action
  if not button.shown then
    return "hidden"
  end
  return button.label.text .. (button.enabled == false and " (disabled)" or "")
end

local function click()
  GoldbookWindow.action.scripts.OnClick(GoldbookWindow.action)
end

-- The count by the Inventory hub in the rail, the Mail view's hub.
local function badge()
  local entry = GoldbookWindow.hubs.inventory
  return entry.count.shown and entry.pill.shown and entry.count.text or "none"
end

local function bags(free)
  Stub.bags[0] = { slots = free }
  for container = 1, 4 do
    Stub.bags[container] = nil
  end
end

local function takes()
  local list = table.concat(Stub.inbox.takes, " / ")
  Stub.inbox.takes = {}
  return list
end

local AH = "Auction House"
local function mailbox()
  return {
    { sender = AH, subject = "Auction successful: Runecloth", money = 131100, daysLeft = 29.5,
      invoice = { "seller", "Runecloth", "Alice", 138000, 138000, 0, 6900, 20 } },
    { sender = AH, subject = "Auction won: Essence of Undeath", daysLeft = 29.2,
      invoice = { "buyer", "Essence of Undeath", "Bob", 39000, 39000, 0, 0, 3 }, items = { { 12808, "Essence of Undeath", 3, 1 } } },
    { sender = AH, subject = "Auction cancelled: Major Healing Potion", daysLeft = 30, items = { { 13446, "Major Healing Potion", 5, 1 } } },
    { sender = AH, subject = "Auction expired: Black Lotus", daysLeft = 27.4, items = { { 13468, "Black Lotus", 1, 2 } } },
    { sender = "Mirelle", subject = "Mats", daysLeft = 3.5,
      items = { [1] = { 14047, "Runecloth", 20, 1 }, [2] = { 14047, "Runecloth", 20, 1 }, [4] = { 12359, "Thorium Bar", 10, 1 } } },
    { sender = "Mirelle", subject = "Gold for the mats", money = 150000, daysLeft = 3.2 },
    { sender = "Kargath", subject = "Arcanite", cod = 240000, daysLeft = 2.5, items = { { 12360, "Arcanite Bar", 2, 2 } } },
    { sender = "Grokk", subject = "Hello there", daysLeft = 0.5, text = "See you in Orgrimmar" },
  }
end

SlashCmdList.GOLDBOOK("mail")
eq(head() .. " / " .. GoldbookWindow.status.text, "Mail | The mailbox is closed |  / Open a mailbox to list your mail",
  "/gb mail away from a mailbox says to open one")
eq(action() .. " / " .. badge(), "Collect 0 mails (disabled) / none", "nothing can be collected and the rail shows no count")
GoldbookWindow:Hide()

bags(4)
Stub.inbox.mails = mailbox()
Stub.openMailbox()
eq(GoldbookWindow.shown, true, "the window opens when a mailbox opens")
eq(rows(), table.concat({
  "Runecloth x20 | Auction House | 29d | 13g 11s 00c [Sold]",
  "Essence of Undeath x3 | Auction House | 29d |  [Bought]",
  "Major Healing Potion x5 | Auction House | 30d |  [Cancelled]",
  "Black Lotus | Auction House | 27d |  [Expired]",
  "Runecloth x40 +1 more | Mirelle | 3d |  [Other]",
  "Gold for the mats | Mirelle | 3d | 15g 00s 00c [Other]",
  "Arcanite Bar x2 | Kargath | 2d | COD 24g 00s 00c [Other]",
  "Hello there | Grokk | 12h |  [Other]",
}, "\n"), "every mail in the inbox's order: its items or its subject, a tag for what it is, who sent it, days left and its gold")
local drawn = GoldbookWindow.rows
eq(drawn[1].icon.texture .. " " .. drawn[2].icon.texture .. " " .. drawn[8].icon.texture,
  "Interface\\Icons\\INV_Misc_Coin_01 142808 Interface\\Icons\\INV_Letter_15", "a mail of gold shows a coin, one of items its first item, a letter its envelope")
eq(drawn[1].cells[4].text:sub(1, 10) .. " " .. drawn[7].cells[4].text:sub(1, 10) .. " " .. drawn[5].cells[3].text:sub(1, 10) .. " "
  .. drawn[4].cells[3].text, "|cff5fd35a |cffff6d5a |cffff8000 27d", "money is green, COD red, and 3 days or less in the warning colour")
eq(drawn[2].tag.label.textColor[3] > 0.9 and drawn[4].tag.label.textColor[1] == 1, true, "Bought is tagged blue and Expired red")
eq(head(), "Mail | 8 mails · 7 items | 28g 11s 00c to collect", "the title counts mails and items and says what gold waits")
eq(segments(), "[All 8] Sold 1 Bought 1 Cancelled 1 Expired 1 Other 4", "each kind of mail is a segment with its count")
eq(GoldbookWindow.segments.anchors.RIGHT, GoldbookWindow.filters, "the segments sit on the toolbar, right of the search box")
eq(GoldbookWindow.status.text, "Showing all 8 mails · bags have 4 free slots · COD mails are skipped", "the status line")
eq(action() .. " / " .. badge(), "Collect 6 mails / 8", "the COD mail and the letter are not counted to collect; the rail counts the mail")
eq(tostring(GoldbookWindow.hubs.inventory.selected.shown) .. " " .. tostring(GoldbookWindow.tabs.mail.selected.shown) .. " "
  .. tostring(GoldbookWindow.tabs.bags.shown), "true true true", "the mailbox opens Inventory on its Mail tab, beside Bags")
GoldbookWindow.hubs.ledger.scripts.OnClick()
eq(badge() .. " " .. tostring(GoldbookWindow.hubs.ledger.count.shown), "8 false", "the count stays by Inventory while another hub is shown")
GoldbookWindow.hubs.inventory.scripts.OnClick()
eq(head(), "Mail | 8 mails · 7 items | 28g 11s 00c to collect", "Inventory opens again on Mail, the tab it showed last")
eq(GoldbookWindow.headers[1].text .. " " .. GoldbookWindow.headers[2].text .. " " .. GoldbookWindow.headers[3].text .. " "
  .. GoldbookWindow.headers[4].text .. " " .. GoldbookWindow.headers[5].text, "MAIL TYPE FROM LEFT GOLD", "the columns, in the inbox's order until one is sorted")

segment(6)
eq(segments() .. " / " .. action(), "All 8 Sold 1 Bought 1 Cancelled 1 Expired 1 [Other 4] / Collect 2 mails", "a segment shows its kind alone")
eq(GoldbookWindow.status.text, "Showing 4 of 8 mails · bags have 4 free slots · COD mails are skipped", "the status says how many are shown")
segment(1)
GoldbookWindow.search:SetText("runecloth")
eq(rows() .. " / " .. segments(),
  "Runecloth x20 | Auction House | 29d | 13g 11s 00c [Sold]\nRunecloth x40 +1 more | Mirelle | 3d |  [Other] / [All 2] Sold 1 Bought 0 Cancelled 0 Expired 0 Other 1",
  "the search matches item names, and the counts follow it")
eq(GoldbookWindow.filters.clear.shown, false, "no Clear filters chip over the segments")
GoldbookWindow.search:SetText("mirelle")
eq(action() .. " / " .. GoldbookWindow.status.text, "Collect 2 mails / Showing 2 of 8 mails · bags have 4 free slots",
  "the search matches the sender, and the COD note goes with the COD mail")
GoldbookWindow.search:SetText("")

GoldbookWindow.headerButtons[4].scripts.OnClick()
eq(GoldbookWindow.headers[4].text .. " " .. plain(drawn[1].cells[3].text) .. " " .. plain(drawn[8].cells[3].text), "LEFT ↓ 30d 12h",
  "sorted by days left, most first")
GoldbookWindow.headerButtons[4].scripts.OnClick()
eq(plain(drawn[1].cells[3].text) .. " " .. plain(drawn[8].cells[3].text), "12h 30d", "a second click puts the soonest to go first")
GoldbookWindow.headerButtons[5].scripts.OnClick()
eq(plain(drawn[1].cells[4].text) .. " / " .. plain(drawn[8].cells[4].text), "15g 00s 00c / COD 24g 00s 00c", "sorted by gold, COD last")

-- The Other mails: gold, then three stacks; the COD mail and the letter stay.
segment(6)
Stub.money = 1000
Stub.inbox.takes = {}
click()
ns.UI.Refresh()
eq(action() .. " / " .. GoldbookWindow.status.text:match("^[^·]+"), "Stop / Collecting ", "the button stops the run while it goes")
eq(takes(), "money 6", "the oldest mail wanted is taken first, its money in one take")
Stub.advance(5)
eq(takes(), "item 5:1 / item 5:2 / item 5:4", "then each item in turn, from the mail the inbox renumbered, waiting for the inbox each time")
eq(lastPrint(), "Goldbook Collected the mail. Took 15g 00s 00c and 3 items.", "the run says what it took")
eq(#Stub.inbox.mails .. " " .. Stub.money .. " " .. Stub.bags[0][3].stackCount, "6 151000 10", "the gold is in the purse and the items in the bags")
eq(rows(), "Hello there | Grokk | 12h |  [Other]\nArcanite Bar x2 | Kargath | 2d | COD 24g 00s 00c [Other]",
  "the COD mail and the letter stay, still sorted by gold")
eq(GoldbookWindow.status.text, "Collected the mail · Showing 2 of 6 mails · bags have 1 free slot · COD mails are skipped",
  "the status says how the run ended")
eq(action() .. " / " .. badge(), "Collect 0 mails (disabled) / 6", "nothing left to collect here; the rail follows the inbox")

-- Full bags: gold still comes, items wait.
bags(0)
Stub.inbox.mails = {
  { sender = AH, subject = "Auction expired: Black Lotus", daysLeft = 27, items = { { 13468, "Black Lotus", 1, 2 } } },
  { sender = AH, subject = "Auction successful: Black Lotus", money = 80000, daysLeft = 28,
    invoice = { "seller", "Black Lotus", "Alice", 84000, 84000, 0, 4000, 1 } },
  { sender = AH, subject = "Auction cancelled: Runecloth", daysLeft = 29, items = { { 14047, "Runecloth", 20, 1 } } },
}
segment(1)
click()
Stub.advance(5)
eq(takes() .. " / " .. lastPrint(), "money 2 / Goldbook Stopped: the bags are full. Took 8g 00s 00c and 0 items.",
  "with the bags full the run takes the gold and stops at the items")

-- A client that does not tell free slots: the game's error stops the run.
local freeSlots = C_Container.GetContainerNumFreeSlots
C_Container.GetContainerNumFreeSlots = nil
ns.UI.Refresh()
eq(GoldbookWindow.status.text, "Stopped: the bags are full · Showing all 2 mails", "without free slots to tell, the status leaves them out")
click()
Stub.advance(5)
eq(takes() .. " / " .. lastPrint(), "item 2:1 / Goldbook Stopped: the bags are full. Took 0c and 0 items.",
  "Inventory is full stops the run")
C_Container.GetContainerNumFreeSlots = freeSlots

-- The mailbox closes mid-run.
bags(4)
Stub.inbox.mails = mailbox()
Stub.openMailbox()
segment(1)
click()
Stub.advance(0.25)
Stub.fire("MAIL_CLOSED")
Stub.advance(5)
eq(takes() .. " / " .. lastPrint(), "money 6 / Goldbook Stopped: the mailbox closed. Took 15g 00s 00c and 0 items.",
  "closing the mailbox stops the run, and no take follows")
eq(tostring(GoldbookWindow.shown), "false", "the window the mailbox opened closes with it")
SlashCmdList.GOLDBOOK("mail")
eq(badge() .. " / " .. GoldbookWindow.status.text, "none / Open a mailbox to list your mail", "a closed mailbox has no count in the rail")

-- Clicking again stops it.
Stub.inbox.mails = mailbox()
Stub.openMailbox()
click()
eq(action(), "Stop", "the button turns into Stop at once")
click()
Stub.advance(5)
eq(takes() .. " / " .. lastPrint(), "money 6 / Goldbook Stopped. Took 15g 00s 00c and 0 items.", "Stop ends the run after the take under way")
eq(action(), "Collect 5 mails", "and the button collects again")

-- A take the client never answers or carries out: the run waits a moment,
-- tries a few times, and leaves that mail.
Stub.inbox.answer = nil
Stub.inbox.mails = { { sender = "Mirelle", subject = "Stuck", money = 500, daysLeft = 10, refuses = true } }
ns.UI.Refresh()
click()
Stub.advance(10)
eq(takes() .. " / " .. lastPrint(), "money 1 / money 1 / money 1 / Goldbook Collected the mail. Took 0c and 0 items.",
  "a mail that keeps what it holds is left after three tries")
Stub.inbox.answer = 0.2

-- The server holds back what does not fit.
Stub.inbox.shows = 2
Stub.inbox.mails = mailbox()
ns.UI.Refresh()
eq(GoldbookWindow.status.text, "Collected the mail · Showing all 2 mails · bags have 4 free slots · +6 more after collecting", "mail held back is mentioned")
Stub.inbox.shows = 50

-- What a mail is, by its invoice or its subject in the client's language.
local expired = AUCTION_EXPIRED_MAIL_SUBJECT
AUCTION_EXPIRED_MAIL_SUBJECT = "%1$s: Auktion abgelaufen (%d)"
Stub.inbox.mails = {
  { sender = AH, subject = "Auction won: Black Lotus" },
  { sender = AH, subject = "Black Lotus: Auktion abgelaufen (3)" },
  { sender = AH, subject = "Black Lotus: Auktion abgelaufen" },
  { sender = AH, subject = "Sale pending: Runecloth", invoice = { "seller_temp_invoice", "Runecloth", "Alice", 500, 500, 0, 25, 1 } },
}
local kinds = {}
for index, mail in ipairs((Mail.Read())) do
  kinds[index] = mail.category
end
eq(table.concat(kinds, " "), "bought expired other sold", "categories from the subject's own format, positional and numbered, and pending sales")
AUCTION_EXPIRED_MAIL_SUBJECT = expired

-- A client without a function the view relies on.
local takeMoney = TakeInboxMoney
TakeInboxMoney = nil
Stub.inbox.mails = mailbox()
ns.UI.Refresh()
eq(action(), "Collect 6 mails (disabled)", "a client that cannot take mail lists it without collecting")
TakeInboxMoney = takeMoney
local numItems = GetInboxNumItems
GetInboxNumItems = nil
eq(#Mail.Read(), 0, "a client without the inbox functions reads an empty inbox")
GetInboxNumItems = numItems

-- The option to leave the window shut.
local options = Stub.categories[1].frame
options.scripts.OnShow(options)
eq(options.checks.mailView.checked, true, "the option to open the Mail view is on at first")
Stub.fire("MAIL_CLOSED")
GoldbookWindow:Hide()
options.checks.mailView.checked = false
options.checks.mailView.scripts.OnClick(options.checks.mailView)
Stub.openMailbox()
eq(tostring(GoldbookWindow.shown) .. " " .. tostring(GoldbookDB.settings.mailView), "false false", "with it off a mailbox opens without the window")
Stub.fire("MAIL_CLOSED")

io.write(("%d mail checks, %d failed.\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
