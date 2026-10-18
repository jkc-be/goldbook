local _, ns = ...
local Codec = ns.Codec

-- The mailbox as the Mail view lists it, and the collector that empties the
-- mails it shows. Every game function is looked up when it is called, so
-- that hooks other addons put on the take functions see each take.
local Mail = { open = false }
ns.Mail = Mail

-- The attachments a mail can hold, when the client does not say.
local ATTACHMENTS = 16
-- How long a take may go unanswered before the next one, and the pause after
-- an answer, which lets the client renumber the inbox first.
local WAIT_TIMEOUT = 1
local STEP_DELAY = 0.1
-- Takes of one mail that change nothing before the run leaves it alone.
local MAX_TRIES = 3
local COIN = "Interface\\Icons\\INV_Misc_Coin_01"
local LETTER = "Interface\\Icons\\INV_Letter_15"

-- What a mail is, in the order the view's segments list them: the first
-- category whose auction house invoice it carries, else the first whose
-- subject it has, else "other". Subjects are the client's own format
-- strings, so they match in any language.
Mail.CATEGORIES = {
  { key = "sold", label = "Sold", invoices = { seller = true, seller_temp_invoice = true }, subject = "AUCTION_SOLD_MAIL_SUBJECT" },
  { key = "bought", label = "Bought", invoices = { buyer = true }, subject = "AUCTION_WON_MAIL_SUBJECT" },
  { key = "cancelled", label = "Cancelled", subject = "AUCTION_REMOVED_MAIL_SUBJECT" },
  { key = "expired", label = "Expired", subject = "AUCTION_EXPIRED_MAIL_SUBJECT" },
  { key = "other", label = "Other" },
}

-- How a collecting run ends, as the view's status and chat say it.
Mail.ENDINGS = {
  done = "Collected the mail",
  bags = "Stopped: the bags are full",
  closed = "Stopped: the mailbox closed",
  stopped = "Stopped",
}

-- A format such as "Auction expired: %s" as a pattern that matches the
-- subjects it makes.
local function subjectPattern(format)
  local plain = format:gsub("%%%d+%$", "%%"):gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
  return "^" .. plain:gsub("%%s", ".+"):gsub("%%d", "%%d+") .. "$"
end

local function categoryOf(invoiceType, subject)
  for _, category in ipairs(Mail.CATEGORIES) do
    if category.invoices and category.invoices[invoiceType] then
      return category.key
    end
  end
  for _, category in ipairs(Mail.CATEGORIES) do
    local format = category.subject and _G[category.subject]
    if type(format) == "string" and subject:match(subjectPattern(format)) then
      return category.key
    end
  end
  return "other"
end

-- The mails the client shows, newest first as it numbers them, each
--   { index, category, sender, subject, money, cod, daysLeft, attachments,
--     slot, items, name, count, quality, icon, gold }
-- `items` groups the attachments by name as { name, count, quality, icon },
-- and `slot` is the first attachment slot holding one. `name`, `count`,
-- `quality` and `icon` are the first item's; a mail without items is named
-- after the item its auction house invoice is for, or else its subject, and
-- shows a coin or a letter. `gold` is the money, or minus the COD, to sort by.
-- Also returns how many more mails the server holds back until some are taken.
function Mail.Read()
  local mails = {}
  if not (GetInboxNumItems and GetInboxHeaderInfo) then
    return mails, 0
  end
  local shown, total = GetInboxNumItems()
  shown = shown or 0
  for index = 1, shown do
    local package, _, sender, subject, money, cod, daysLeft, hasItem = GetInboxHeaderInfo(index)
    subject, money, cod = subject or "", money or 0, cod or 0
    local invoiceType, invoiceItem, invoiceCount
    if GetInboxInvoiceInfo then
      local invoice = { GetInboxInvoiceInfo(index) }
      invoiceType, invoiceItem, invoiceCount = invoice[1], invoice[2], invoice[11]
    end
    local mail = {
      index = index,
      category = categoryOf(invoiceType, subject),
      sender = sender or "",
      subject = subject,
      money = money,
      cod = cod,
      daysLeft = daysLeft or 0,
      attachments = 0,
      items = {},
      gold = money > 0 and money or -cod,
    }
    if hasItem and GetInboxItem then
      local byName = {}
      for slot = 1, ATTACHMENTS_MAX_RECEIVE or ATTACHMENTS do
        local name, _, icon, count, quality = GetInboxItem(index, slot)
        if name then
          mail.attachments = mail.attachments + 1
          mail.slot = mail.slot or slot
          local item = byName[name]
          if not item then
            item = { name = name, count = 0, quality = quality or 1, icon = icon }
            byName[name] = item
            mail.items[#mail.items + 1] = item
          end
          item.count = item.count + math.max(count or 1, 1)
        end
      end
    end
    local first = mail.items[1]
    local invoiced = invoiceItem ~= nil and invoiceItem ~= ""
    mail.name = first and first.name or invoiced and invoiceItem or subject
    mail.count = first and first.count or invoiced and invoiceCount or nil
    mail.quality = first and first.quality or 1
    mail.icon = first and first.icon or (money > 0 and COIN) or package or LETTER
    mails[index] = mail
  end
  return mails, math.max(0, (total or shown) - shown)
end

-- In `category` ("all" for any) and naming `text` in its name, subject,
-- sender or one of its items.
function Mail.Matches(mail, text, category)
  if category ~= "all" and mail.category ~= category then
    return false
  end
  local needle = text:lower()
  for _, field in ipairs({ mail.name, mail.subject, mail.sender }) do
    if field:lower():find(needle, 1, true) then
      return true
    end
  end
  for _, item in ipairs(mail.items) do
    if item.name:lower():find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- How many of `mails` match `text`, in all and per category.
function Mail.Counts(mails, text)
  local counts = { all = 0 }
  for _, category in ipairs(Mail.CATEGORIES) do
    counts[category.key] = 0
  end
  for _, mail in ipairs(mails) do
    if Mail.Matches(mail, text, "all") then
      counts.all = counts.all + 1
      counts[mail.category] = counts[mail.category] + 1
    end
  end
  return counts
end

-- Holds money or items and asks no COD: what a run takes.
function Mail.Collectable(mail)
  return mail.cod == 0 and (mail.money > 0 or mail.attachments > 0)
end

-- Whether this client lets an addon take mail at all.
function Mail.CanCollect()
  return TakeInboxMoney ~= nil and (TakeInboxItem ~= nil or AutoLootMailItem ~= nil)
end

-- Free slots in the bags that take any item, or nil when the client does not say.
function Mail.FreeSlots()
  local count = C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
  if not count then
    return nil
  end
  local free = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local slots, family = count(bag)
    if (family or 0) == 0 then
      free = free + (slots or 0)
    end
  end
  return free
end

-- The collector, a small state machine:
--   idle     nothing running; `ending` says how the last run ended (a key of
--            Mail.ENDINGS, nil before the first) and `took` what it took
--   taking   the next take is due
--   waiting  a take was sent; the inbox answering, or WAIT_TIMEOUT passing
--            without an answer, moves on to the next
-- A run takes the oldest mail it wants first, the highest index, so the
-- mails the client renumbers after a take are ones already done.
local collector = { state = "idle" }
-- The run going on: { wanted, tries, skipped, money, items, left, token }.
local run

function Mail.Collector()
  return collector
end

local function signature(mail)
  return table.concat({ mail.index, mail.sender, mail.subject, mail.money, mail.attachments, mail.daysLeft }, "|")
end

local function attachments(mails)
  local count = 0
  for _, mail in ipairs(mails) do
    count = count + mail.attachments
  end
  return count
end

-- The next take the run wants, oldest mail first: its money, then its items
-- one at a time while the bags have room. Without one, how the run ends.
local function nextTake(mails, full)
  local blocked = false
  for index = #mails, 1, -1 do
    local mail = mails[index]
    if run.wanted(mail) and Mail.Collectable(mail) and not run.skipped[signature(mail)] then
      if mail.money > 0 then
        return mail, "money"
      elseif not full then
        return mail, "item"
      end
      blocked = true
    end
  end
  return nil, blocked and "bags" or "done"
end

local function finish(ending)
  if collector.state == "idle" then
    return
  end
  collector.state, collector.ending = "idle", ending
  collector.took = { money = math.max(0, GetMoney() - run.money), items = run.items }
  run = nil
  local items = collector.took.items
  ns.Print(Mail.ENDINGS[ending] .. ". Took " .. Codec.Money(collector.took.money) .. " and " .. items
    .. (items == 1 and " item." or " items."))
  -- At once, so that the button is never left saying Stop.
  ns.UI.Refresh()
end

-- Runs `action` after `delay` unless the run moved on or ended meanwhile.
local function after(delay, action)
  run.token = run.token + 1
  local token = run.token
  C_Timer.After(delay, function()
    if run and run.token == token then
      action()
    end
  end)
end

local step

-- The inbox answered the take, or did not in time.
local function answered()
  if collector.state ~= "waiting" then
    return
  end
  collector.state = "taking"
  after(STEP_DELAY, step)
end

function step()
  local mails = Mail.Read()
  local left = attachments(mails)
  run.items = run.items + math.max(0, run.left - left)
  run.left = left
  local mail, take = nextTake(mails, Mail.FreeSlots() == 0)
  if not mail then
    finish(take)
    return
  end
  local key = signature(mail)
  run.tries[key] = (run.tries[key] or 0) + 1
  if run.tries[key] >= MAX_TRIES then
    run.skipped[key] = true
  end
  if take == "money" then
    TakeInboxMoney(mail.index)
  elseif TakeInboxItem then
    TakeInboxItem(mail.index, mail.slot)
  else
    AutoLootMailItem(mail.index)
  end
  -- An error the take raised may have ended the run already.
  if not run then
    return
  end
  collector.state = "waiting"
  after(WAIT_TIMEOUT, answered)
end

-- Takes the money and items of every mail in `category` naming `text`, one
-- take at a time, skipping COD mails. Returns false when it cannot start.
function Mail.Collect(text, category)
  if collector.state ~= "idle" or not Mail.open or not Mail.CanCollect() then
    return false
  end
  local mails = Mail.Read()
  collector.state, collector.ending, collector.took = "taking", nil, nil
  run = {
    wanted = function(mail)
      return Mail.Matches(mail, text, category)
    end,
    tries = {},
    skipped = {},
    money = GetMoney(),
    items = 0,
    left = attachments(mails),
    token = 0,
  }
  step()
  ns.UI.Refresh()
  return true
end

function Mail.Stop()
  finish("stopped")
end

-- Whether the Mail view was opened by the mailbox, and so closes with it.
local openedByMailbox = false

local EVENTS = {
  MAIL_SHOW = function()
    Mail.open, collector.ending, collector.took = true, nil, nil
    if CheckInbox then
      CheckInbox()
    end
    if ns.db.settings.mailView ~= false then
      openedByMailbox = true
      ns.UI.Show("mail", "")
    end
  end,
  MAIL_CLOSED = function()
    Mail.open = false
    finish("closed")
    if openedByMailbox then
      openedByMailbox = false
      ns.UI.Close("mail")
    end
    ns.UI.RefreshSoon()
  end,
  MAIL_INBOX_UPDATE = function()
    answered()
    ns.UI.RefreshSoon()
  end,
  MAIL_SUCCESS = answered,
  -- Older clients pass the message alone, newer ones its type first.
  UI_ERROR_MESSAGE = function(first, second)
    local message = type(first) == "string" and first or second
    if collector.state ~= "idle" and ERR_INV_FULL and message == ERR_INV_FULL then
      finish("bags")
    end
  end,
}

local frame = CreateFrame("Frame")
for event in pairs(EVENTS) do
  frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, ...)
  EVENTS[event](...)
end)
