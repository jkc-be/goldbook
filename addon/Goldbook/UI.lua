local _, ns = ...
local Codec, Database, Scanner, Advisor, Ledger, Trades = ns.Codec, ns.Database, ns.Scanner, ns.Advisor, ns.Ledger, ns.Trades

local UI = {}
ns.UI = UI

local WINDOW_WIDTH = 700
local ROWS = 16
local ROW_HEIGHT = 18
local LEFT = 14
local GAP = 8
local WIDTHS = { 250, 105, 105, 105, 70 }
local ALIGN = { "LEFT", "RIGHT", "RIGHT", "RIGHT", "RIGHT" }
local TABLE_WIDTH = -GAP
for _, width in ipairs(WIDTHS) do
  TABLE_WIDTH = TABLE_WIDTH + width + GAP
end
local SELL_ACTIONS = { auction = "Auction", vendor = "Vendor", unknown = "No price" }
local CHART_DAYS = 30
local CHART_ROWS = 8
-- A view with a chart states its summary in a band under the tabs and lists
-- its rows that much lower.
local BAND_TOP, BAND = -38, 22
-- The plot sits right of its axis labels, with the highest and lowest
-- markers PLOT_PAD inside its edges.
local PLOT_HEIGHT, AXIS_WIDTH, PLOT_PAD = 90, 80, 5
local PLOT_WIDTH = TABLE_WIDTH - AXIS_WIDTH
local MARKER, NEWEST_MARKER = 5, 9
local GOLD = { 1, 0.82, 0 }
-- The game's own green and red.
local GAIN, LOSS = "|cff20ff20", "|cffff2020"
-- Status line, chart caption and axis labels: readable, but quieter than the figures.
local QUIET = { 0.75, 0.75, 0.75 }
local QUIET_TEXT = "|cffbfbfbf"
local REFRESH_DELAY = 0.2
local RELOAD_WIDTH = 80
-- Six tabs fit between the search box and the close button.
local TAB_LEFT, TAB_WIDTH, TAB_STEP = 284, 60, 63
local DAY = 24 * 3600
UI.BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local window, scanButton
local view, results, offset = "prices", {}, 0
-- The item the item view shows: { key, name, quality }.
local shownItem
-- sorting[view] = { column, descending } once a column header was clicked.
local sorting = {}
local refreshPending = false
local filters = { profession = "", kind = "all" }
local FILTER_HEIGHT = 34

local function itemText(row)
  local color = ITEM_QUALITY_COLORS[row.quality]
  return color and (color.hex .. row.name .. "|r") or row.name
end

-- The item's icon as inline text, or nothing on a client that cannot tell.
local function icon(key)
  local lookup = C_Item.GetItemIconByID or GetItemIcon
  local texture = lookup and lookup(Codec.BaseID(key))
  return texture and ("|T" .. texture .. ":14|t ") or ""
end

local function itemCell(row)
  return icon(row.key) .. itemText(row)
end

local function matching(rows, text)
  local needle = text:lower()
  if needle == "" then
    return rows
  end
  local matches = {}
  for _, row in ipairs(rows) do
    if row.name:lower():find(needle, 1, true) then
      matches[#matches + 1] = row
    end
  end
  return matches
end

local function plural(count, noun)
  return count .. " " .. noun .. (count == 1 and "" or "s")
end

-- Green for a gain, red for a loss. Codec.Money colours its units, and colour
-- codes do not nest in every client, so each stretch of text between the
-- units is coloured on its own.
local function signed(value, text)
  local color = value > 0 and GAIN or value < 0 and LOSS
  if not color then
    return text
  end
  local tinted = ("|r" .. text):gsub("|r([^|]+)", "|r" .. color .. "%1|r")
  return tinted:sub(3)
end

local function change(copper)
  if copper == 0 then
    return ""
  end
  return signed(copper, (copper > 0 and "+" or "-") .. Codec.Money(math.abs(copper)))
end

-- To a tenth; a change that rounds to nothing has no sign.
local function percent(value)
  local tenths = math.floor(value * 10 + 0.5)
  if tenths == 0 then
    return "0.0%"
  end
  return signed(tenths, ("%+.1f%%"):format(tenths / 10))
end

local function dayText(day)
  return date("!%a %d %b", day * DAY)
end

-- Trades whose item or character contains the text.
local function matchingTrades(text)
  local needle, matches = text:lower(), {}
  for _, row in ipairs(Trades.Rows(ns.db)) do
    if row.name:lower():find(needle, 1, true) or row.character:lower():find(needle, 1, true) then
      matches[#matches + 1] = row
    end
  end
  return matches
end

local function shownHistory()
  return Database.History(ns.db, ns.RealmKey(), shownItem.key)
end

-- The account as a broker would state it, and its total per day.
local function goldChart()
  local now = time()
  local account = Ledger.Performance(ns.db, now)
  local _, bags = Advisor.Sell(ns.db, ns.RealmKey(), ns.BagItems())
  local history = Ledger.History(ns.db, now, CHART_DAYS)
  local today = math.floor(now / DAY)
  local days = {}
  for index, total in ipairs(history) do
    days[index] = { value = total, tip = { dayText(today - CHART_DAYS + index), "Total " .. Codec.Money(total) } }
  end
  local todayText = account.today ~= 0 and ("   Today " .. change(account.today) .. " (" .. percent(account.todayPercent) .. ")") or ""
  return {
    summary = "Total " .. Codec.Money(account.gold) .. todayText
      .. (account.week ~= 0 and ("   7 days " .. change(account.week)) or "")
      .. (account.month ~= 0 and ("   30 days " .. change(account.month)) or ""),
    detail = "High " .. Codec.Money(account.high)
      .. (account.bestDay > 0 and ("   Best day " .. change(account.bestDay)) or "")
      .. (account.worstDay < 0 and ("   Worst day " .. change(account.worstDay)) or "")
      .. "   Bags " .. Codec.Money(bags)
      .. "   Net worth " .. Codec.Money(account.gold + bags),
    caption = "Total gold over the last " .. CHART_DAYS .. " days",
    days = days,
  }
end

local function changes(evolution)
  local text = ""
  for _, span in ipairs({ { "1 day", evolution.day }, { "7 days", evolution.week }, { "30 days", evolution.month } }) do
    if span[2] then
      text = text .. "   " .. span[1] .. " " .. percent(span[2])
    end
  end
  return text
end

-- The shown item's latest prices and its lowest price per day it was seen.
local function itemChart()
  local evolution = Advisor.Evolution(shownHistory(), time(), CHART_DAYS)
  local days = {}
  for index, entry in ipairs(evolution.chart) do
    days[index] = entry and {
      value = entry.min,
      tip = {
        dayText(entry.day),
        "Min buyout " .. Codec.Money(entry.min),
        "Listed " .. entry.qty,
        entry.mv > 0 and ("Market value " .. Codec.Money(entry.mv)) or nil,
      },
    }
  end
  if #evolution.rows == 0 then
    return { summary = icon(shownItem.key) .. itemText(shownItem), detail = "", caption = "", days = days, key = shownItem.key }
  end
  local record = Database.Lookup(ns.db, ns.RealmKey(), shownItem.key)
  local usual = Advisor.Usual(record)
  return {
    summary = icon(shownItem.key) .. itemText(shownItem) .. "   " .. Codec.Money(record.min) .. changes(evolution),
    detail = (record.mv > 0 and ("Market value " .. Codec.Money(record.mv) .. " (" .. Codec.Age(time() - record.mvAt) .. ")   ") or "")
      .. (usual and ("Usual " .. Codec.Money(usual) .. "   ") or "")
      .. "Listed " .. record.qty,
    caption = (evolution.low and "Lowest price over the last " or "Not seen in the last ") .. CHART_DAYS .. " days",
    days = days,
    key = shownItem.key,
  }
end

-- What the window can list. Each view fills the same five columns from the
-- row fields named in `fields`, which is also what a header click sorts by.
-- A view of items lets its rows be hovered and clicked. `status` gets the rows
-- and count(noun), which says how many there are and which of them show. A
-- view with a `chart` shows its summary above fewer rows and the chart below
-- them; see drawChart for what it returns.
local VIEWS = {
  prices = {
    tab = "Prices",
    items = true,
    columns = { "Item", "Min buyout", "Market value", "Listed", "Seen" },
    fields = { "name", "min", "mv", "qty", "seen" },
    rows = function(text)
      return Database.Search(ns.db, ns.RealmKey(), text)
    end,
    cells = function(row)
      return itemCell(row), Codec.Money(row.min), row.mv > 0 and Codec.Money(row.mv) or "", tostring(row.qty),
        Codec.Age(time() - row.seen)
    end,
    status = function(_, count)
      return count("item") .. " on " .. ns.RealmKey()
    end,
  },
  deals = {
    tab = "Deals",
    items = true,
    columns = { "Item", "Buy from", "Sells for", "Profit", "Sell to" },
    fields = { "name", "min", "sell", "total", "kind" },
    rows = function(text)
      return matching(Advisor.Deals(ns.db, ns.RealmKey(), ns.MinProfit()), text)
    end,
    cells = function(row)
      return itemCell(row) .. (row.units and (" x" .. row.units) or ""), Codec.Money(row.min), Codec.Money(row.sell),
        Codec.Money(row.total), row.kind == "vendor" and (row.confirmed and "Vendor" or "Vendor?") or "Auction"
    end,
    status = function(rows, count)
      local scanned = ns.db.scanned[ns.RealmKey()]
      if not scanned then
        return "Scan the auction house to find deals."
      end
      local unconfirmed = ""
      for _, row in ipairs(rows) do
        if row.kind == "vendor" and not row.confirmed then
          unconfirmed = " Vendor? prices are unconfirmed."
          break
        end
      end
      return count("deal") .. " in the scan of " .. Codec.Age(time() - scanned) .. ". Click one to search for it." .. unconfirmed
    end,
  },
  sell = {
    tab = "Sell",
    items = true,
    columns = { "Item in bags", "Post at", "Vendor pays", "Brings in", "Sell to" },
    fields = { "name", "post", "vendor", "value", "action" },
    rows = function(text)
      return matching((Advisor.Sell(ns.db, ns.RealmKey(), ns.BagItems())), text)
    end,
    cells = function(row)
      return itemCell(row) .. " x" .. row.count, row.post and Codec.Money(row.post) or "",
        row.vendor > 0 and Codec.Money(row.vendor) or "", Codec.Money(row.value), SELL_ACTIONS[row.action]
    end,
    status = function(rows, count)
      local total = 0
      for _, row in ipairs(rows) do
        total = total + row.value
      end
      return count("item") .. " worth " .. Codec.Money(total) .. " after the auction house cut"
    end,
  },
  movers = {
    tab = "Movers",
    items = true,
    columns = { "Item", "Price", "Day before", "Change", "Listed" },
    fields = { "name", "min", "before", "change", "qty" },
    rows = function(text)
      return matching(Advisor.Movers(ns.db, ns.RealmKey()), text)
    end,
    cells = function(row)
      return itemCell(row), Codec.Money(row.min), Codec.Money(row.before), percent(row.change), tostring(row.qty)
    end,
    status = function(_, count)
      return count("price") .. " moved since the day before. Top gains first; click Change for the losses."
    end,
  },
  gold = {
    tab = "Gold",
    columns = { "Character", "Gold", "Today", "7 days", "Played" },
    fields = { "name", "gold", "today", "week", "idle" },
    rows = function(text)
      return matching(Ledger.Summary(ns.db, time()), text)
    end,
    cells = function(row)
      return row.name, Codec.Money(row.gold), change(row.today), change(row.week),
        row.idle == 0 and "today" or (row.idle .. "d ago")
    end,
    status = function(_, count)
      return count("character")
    end,
    chart = goldChart,
  },
  trades = {
    tab = "Trades",
    columns = { "Item", "Each", "Net", "Character", "When" },
    fields = { "name", "each", "net", "character", "at" },
    rows = matchingTrades,
    cells = function(row)
      return itemText(row) .. " x" .. row.count .. (row.side == "vendor" and (QUIET_TEXT .. "  vendor|r") or ""),
        Codec.Money(row.each), change(row.net), row.character:match("^[^-]+"), Codec.Age(time() - row.at)
    end,
    status = function(rows, count)
      if #rows == 0 then
        return "No trades booked. Open a mailbox or sell to a vendor to book them."
      end
      local totals = Trades.Totals(rows)
      local signedMoney = function(copper)
        return copper == 0 and Codec.Money(0) or change(copper)
      end
      return count("trade") .. ": sold " .. Codec.Money(totals.sold) .. ", bought " .. Codec.Money(totals.bought)
        .. ", net " .. signedMoney(totals.net) .. (totals.profit and (", profit/loss " .. signedMoney(totals.profit)) or "")
    end,
  },
  item = {
    columns = { "Day", "Min buyout", "Market value", "Listed", "Change" },
    fields = { "day", "min", "mv", "qty", "change" },
    rows = function()
      return Advisor.Evolution(shownHistory(), time(), CHART_DAYS).rows
    end,
    cells = function(row)
      return dayText(row.day), Codec.Money(row.min), row.mv > 0 and Codec.Money(row.mv) or "", tostring(row.qty),
        row.change and percent(row.change) or ""
    end,
    status = function(rows, count)
      if #rows == 0 then
        return "No prices recorded for " .. itemText(shownItem) .. " yet. Scan the auction house."
      end
      local hint = ns.db.settings.altClick ~= false and " Alt+click any item for its history." or ""
      return count("day") .. " recorded for " .. itemText(shownItem) .. "." .. hint
    end,
    chart = itemChart,
  },
}
local VIEW_ORDER = { "prices", "deals", "sell", "movers", "gold", "trades" }

local function visibleRows()
  return VIEWS[view].chart and CHART_ROWS or ROWS
end

-- spec = { summary, detail, caption, days, key }, with a slot in `days` per
-- chart day: { value, tip = { line, ... } }, or false for a day without a
-- value. The summary fills the band under the tabs; with an item `key` the
-- band is that item's header. The line runs from the lowest value at the
-- bottom of the plot to the highest at the top, and breaks where a day has
-- no value.
local function drawChart(spec)
  local chart = window.chart
  chart.summary:SetText(spec.summary)
  chart.detail:SetText(spec.detail)
  chart.caption:SetText(spec.caption)
  chart.header.key = spec.key
  chart.header:SetShown(spec.key ~= nil)

  local low, high, newest = math.huge, -math.huge, nil
  for index, slot in ipairs(spec.days) do
    if slot then
      low, high, newest = math.min(low, slot.value), math.max(high, slot.value), index
    end
  end
  chart.high:SetText(newest and Codec.Money(high) or "")
  chart.low:SetText(newest and high > low and Codec.Money(low) or "")

  local column = PLOT_WIDTH / CHART_DAYS
  -- Values that are all the same sit at the top, beside their one label.
  local function spot(index)
    local share = high > low and (spec.days[index].value - low) / (high - low) or 1
    return (index - 0.5) * column, PLOT_PAD + share * (PLOT_HEIGHT - 2 * PLOT_PAD)
  end
  for index, day in ipairs(chart.days) do
    local slot, before = spec.days[index], spec.days[index - 1]
    day.marker:SetShown(slot and true or false)
    day.hit:SetShown(slot and true or false)
    if day.line then
      day.line:SetShown(slot and before and true or false)
    end
    if slot then
      local x, y = spot(index)
      local size = index == newest and NEWEST_MARKER or MARKER
      day.marker:SetSize(size, size)
      day.marker:SetPoint("CENTER", chart.plot, "BOTTOMLEFT", x, y)
      day.hit.tip = slot.tip
      if day.line and before then
        day.line:SetStartPoint("BOTTOMLEFT", chart.plot, spot(index - 1))
        day.line:SetEndPoint("BOTTOMLEFT", chart.plot, x, y)
      end
    end
  end
end

local function placeScrollMarker(visible)
  local track, total = window.scroll, #results
  track:SetShown(total > visible)
  if total > visible then
    local height = visible * ROW_HEIGHT
    local thumb = math.max(ROW_HEIGHT, height * visible / total)
    track:SetHeight(height)
    track.thumb:SetHeight(thumb)
    track.thumb:SetPoint("TOP", track, "TOP", 0, -(height - thumb) * offset / (total - visible))
  end
end

local function render()
  local definition = VIEWS[view]
  local visible = visibleRows()
  for index, row in ipairs(window.rows) do
    local item = index <= visible and results[offset + index] or nil
    local cells = item and { definition.cells(item) } or {}
    for column, cell in ipairs(row.cells) do
      cell:SetText(cells[column] or "")
    end
    row.stripe:SetShown(item ~= nil and index % 2 == 0)
    row.hit.item = item
    row.hit:SetShown(item ~= nil and definition.items == true)
  end
  placeScrollMarker(visible)
  local function count(noun)
    local text = plural(#results, noun)
    if #results > visible then
      text = (offset + 1) .. "-" .. (offset + visible) .. " of " .. text
    end
    return text
  end
  window.status:SetText(definition.status(results, count))
end

-- Rows missing the field sort as the lowest value.
local function sortBy(rows, field, descending)
  table.sort(rows, function(a, b)
    local left, right = a[field], b[field]
    if left == nil then
      left = type(right) == "string" and "" or 0
    end
    if right == nil then
      right = type(left) == "string" and "" or 0
    end
    if left == right then
      return (a.key or a.name or a.day) < (b.key or b.name or b.day)
    elseif descending then
      return left > right
    end
    return left < right
  end)
end

local function refresh()
  local definition = VIEWS[view]
  local sort = sorting[view]
  for column, header in ipairs(window.headers) do
    local arrow = sort and sort.column == column and (sort.descending and " v" or " ^") or ""
    header:SetText(definition.columns[column] .. arrow)
  end
  for name, tab in pairs(window.tabs) do
    if name == view then
      tab:LockHighlight()
    else
      tab:UnlockHighlight()
    end
  end
  results = definition.rows(window.search:GetText() or "")
  window:SetHeight(110 + ROWS * ROW_HEIGHT + (definition.items and FILTER_HEIGHT or 0))
  if not definition.items and window.filterMenu then window.filterMenu:Hide() end
  window.filters:SetShown(definition.items == true)
  if definition.items then
    local filtered = {}
    for _, row in ipairs(results) do
      if ns.Professions.Matches(row.key, filters.profession, filters.kind)
        and (filters.quality == nil or row.quality == filters.quality) then
        filtered[#filtered + 1] = row
      end
    end
    results = filtered
  end
  if sort then
    sortBy(results, definition.fields[sort.column], sort.descending)
  end
  offset = 0
  render()
  window.body:SetPoint("TOPLEFT", 0, -(definition.chart and BAND or 0) - (definition.items and FILTER_HEIGHT or 0))
  window.chart:SetShown(definition.chart ~= nil)
  if definition.chart then
    drawChart(definition.chart())
  end
end

-- First click sorts text upward and numbers downward; a second click flips.
local function sortColumn(column)
  local sort = sorting[view]
  if sort and sort.column == column then
    sort.descending = not sort.descending
  else
    sorting[view] = { column = column, descending = column > 1 }
  end
  refresh()
end

local function scroll(_, delta)
  local last = math.max(0, #results - visibleRows())
  offset = math.max(0, math.min(last, offset - delta * 3))
  render()
end

local function searchAuctionHouse(name)
  local bar = AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame.SearchBar
  if bar and bar.SetSearchText and bar.StartSearch then
    bar:SetSearchText(name)
    bar:StartSearch()
  else
    ns.Print("Open the auction house and search for " .. name .. ".")
  end
end

-- Beside the window rather than over its rows and close button: right of it,
-- or left of it when the screen ends first. Owners span the table's width.
local function showItemTip(owner, key)
  GameTooltip:SetOwner(owner, "ANCHOR_NONE")
  GameTooltip:SetHyperlink(Codec.ItemString(key))
  GameTooltip:Show()
  GameTooltip:ClearAllPoints()
  if window:GetRight() + GameTooltip:GetWidth() <= UIParent:GetRight() then
    GameTooltip:SetPoint("TOPLEFT", owner, "TOPRIGHT", WINDOW_WIDTH - LEFT - TABLE_WIDTH, 0)
  else
    GameTooltip:SetPoint("TOPRIGHT", owner, "TOPLEFT", -LEFT, 0)
  end
end

local function addColumns(parent, top, font)
  local cells, left = {}, LEFT
  for index, width in ipairs(WIDTHS) do
    local cell = parent:CreateFontString(nil, "OVERLAY", font)
    cell:SetPoint("TOPLEFT", parent, "TOPLEFT", left, top)
    cell:SetWidth(width)
    cell:SetJustifyH(ALIGN[index])
    cell:SetWordWrap(false)
    cells[index] = cell
    left = left + width + GAP
  end
  return cells
end

local function addHeaders(top)
  window.headers = addColumns(window.body, top, "GameFontNormalSmall")
  window.headerButtons = {}
  local left = LEFT
  for column, width in ipairs(WIDTHS) do
    local button = CreateFrame("Button", nil, window.body)
    button:SetPoint("TOPLEFT", window.body, "TOPLEFT", left, top + 2)
    button:SetSize(width, ROW_HEIGHT)
    button:SetScript("OnClick", function()
      sortColumn(column)
    end)
    window.headerButtons[column] = button
    left = left + width + GAP
  end
end

local function addRow(top)
  local stripe = window.body:CreateTexture(nil, "ARTWORK")
  stripe:SetColorTexture(1, 1, 1, 0.04)
  stripe:SetPoint("TOPLEFT", window.body, "TOPLEFT", LEFT, top + 2)
  stripe:SetSize(TABLE_WIDTH, ROW_HEIGHT)
  local hit = CreateFrame("Button", nil, window.body)
  hit:SetPoint("TOPLEFT", window.body, "TOPLEFT", LEFT, top + 2)
  hit:SetSize(TABLE_WIDTH, ROW_HEIGHT)
  hit:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  hit:SetScript("OnEnter", function(self)
    showItemTip(self, self.item.key)
  end)
  hit:SetScript("OnLeave", GameTooltip_Hide)
  hit:SetScript("OnClick", function(self)
    if IsAltKeyDown() then
      UI.ShowItem(self.item.key)
    else
      searchAuctionHouse(self.item.name)
    end
  end)
  return { cells = addColumns(window.body, top, "GameFontHighlightSmall"), stripe = stripe, hit = hit }
end

local function addScrollMarker(top)
  local track = CreateFrame("Frame", nil, window.body)
  track:SetPoint("TOPLEFT", window.body, "TOPLEFT", LEFT + TABLE_WIDTH + 6, top)
  track:SetWidth(3)
  local groove = track:CreateTexture(nil, "BACKGROUND")
  groove:SetAllPoints()
  groove:SetColorTexture(1, 1, 1, 0.08)
  track.thumb = track:CreateTexture(nil, "ARTWORK")
  track.thumb:SetWidth(3)
  track.thumb:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.7)
  window.scroll = track
end

local function showDayTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(self.tip[1])
  for index = 2, #self.tip do
    GameTooltip:AddLine(self.tip[index], 1, 1, 1)
  end
  GameTooltip:Show()
end

-- Over the band of an item's chart, which names the item: hover for its
-- tooltip, Shift+click to link it in chat.
local function addItemHeader(chart)
  local header = CreateFrame("Button", nil, chart)
  header:SetPoint("TOPLEFT", window, "TOPLEFT", LEFT, BAND_TOP + 2)
  header:SetSize(TABLE_WIDTH, ROW_HEIGHT)
  header:SetScript("OnEnter", function(self)
    showItemTip(self, self.key)
  end)
  header:SetScript("OnLeave", GameTooltip_Hide)
  header:SetScript("OnClick", function(self)
    local _, link = C_Item.GetItemInfo(Codec.ItemString(self.key))
    if IsShiftKeyDown() and link and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
    end
  end)
  return header
end

-- A label left of the plot for its highest or lowest value, and a faint
-- guide across the plot at that height.
local function addAxisLabel(plot, corner, y)
  local guide = plot:CreateTexture(nil, "BACKGROUND")
  guide:SetColorTexture(1, 1, 1, 0.1)
  guide:SetPoint("LEFT", plot, corner, 0, y)
  guide:SetSize(PLOT_WIDTH, 1)
  local label = plot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("RIGHT", plot, corner, -6, y)
  label:SetWidth(AXIS_WIDTH - 6)
  label:SetJustifyH("RIGHT")
  label:SetWordWrap(false)
  label:SetTextColor(unpack(QUIET))
  return label
end

local function addChart()
  local chart = CreateFrame("Frame", nil, window)
  chart:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", LEFT, 34)
  chart:SetSize(TABLE_WIDTH, PLOT_HEIGHT + 38)

  chart.summary = chart:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  chart.summary:SetPoint("TOPLEFT", window, "TOPLEFT", LEFT, BAND_TOP)
  chart.header = addItemHeader(chart)
  chart.detail = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chart.detail:SetPoint("TOPLEFT")
  chart.caption = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chart.caption:SetPoint("TOPLEFT", 0, -18)
  chart.caption:SetTextColor(unpack(QUIET))

  local plot = CreateFrame("Frame", nil, chart)
  plot:SetPoint("BOTTOMRIGHT")
  plot:SetSize(PLOT_WIDTH, PLOT_HEIGHT)
  chart.plot = plot
  chart.high = addAxisLabel(plot, "TOPLEFT", -PLOT_PAD)
  chart.low = addAxisLabel(plot, "BOTTOMLEFT", PLOT_PAD)

  local column = PLOT_WIDTH / CHART_DAYS
  chart.days = {}
  for index = 1, CHART_DAYS do
    local day = {}
    -- The segment from the day before. A client without lines draws the markers alone.
    day.line = plot.CreateLine and plot:CreateLine(nil, "ARTWORK")
    if day.line then
      day.line:SetThickness(2)
      day.line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.6)
    end
    day.marker = plot:CreateTexture(nil, "OVERLAY")
    day.marker:SetColorTexture(unpack(GOLD))
    -- The day's full height, so that a low marker is as easy to hover as a high one.
    day.hit = CreateFrame("Frame", nil, plot)
    day.hit:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (index - 1) * column, 0)
    day.hit:SetSize(column, PLOT_HEIGHT)
    day.hit:EnableMouse(true)
    day.hit:SetScript("OnEnter", showDayTip)
    day.hit:SetScript("OnLeave", GameTooltip_Hide)
    chart.days[index] = day
  end
  window.chart = chart
end

local function addFilters()
  local bar = CreateFrame("Frame", nil, window)
  bar:SetPoint("TOPLEFT", LEFT, -36)
  bar:SetSize(WINDOW_WIDTH - LEFT * 2, FILTER_HEIGHT)
  window.filters = bar
  local controls = {}
  local options = {
    profession = { { "", "All professions" } },
    kind = { { "all", "All items" }, { "materials-recipes", "Materials and recipes" },
      { "materials", "Materials" }, { "recipes", "Recipes" }, { "crafted", "Crafted items" } },
    quality = { { nil, "All qualities" } },
  }
  for _, profession in ipairs(ns.ProfessionData) do
    if #profession.materials > 0 then
      options.profession[#options.profession + 1] = { profession.id, profession.name }
    end
  end
  for id, name in ipairs({ "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }) do
    options.quality[#options.quality + 1] = { id - 1, name }
  end
  local function labels()
    for name, button in pairs(controls) do
      for _, option in ipairs(options[name]) do
        if option[1] == filters[name] then
          button:SetText(option[2] .. " v")
          break
        end
      end
    end
  end
  for index, name in ipairs({ "profession", "kind", "quality" }) do
    local button = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    button:SetSize(175, 22)
    button:SetPoint("TOPLEFT", (index - 1) * 183, 0)
    controls[name] = button
    button:SetScript("OnClick", function()
      if window.filterMenu then
        local same = window.filterMenu.owner == button and window.filterMenu:IsShown()
        window.filterMenu:Hide()
        if same then return end
      end
      local menu = button.menu
      if not menu then
        menu = CreateFrame("Frame", nil, button, BackdropTemplateMixin and "BackdropTemplate" or nil)
        menu.owner = button
        menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
        menu:SetSize(200, #options[name] * 22 + 8)
        menu:SetFrameStrata("TOOLTIP")
        menu:SetBackdrop(UI.BACKDROP)
        menu.options = {}
        for row, option in ipairs(options[name]) do
          local choice = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
          choice:SetPoint("TOPLEFT", 4, -4 - (row - 1) * 22)
          choice:SetSize(192, 22)
          choice:SetText(option[2])
          choice:SetScript("OnClick", function()
            filters[name] = option[1]
            if name == "profession" then
              filters.kind = option[1] ~= "" and "materials" or "all"
            end
            labels()
            menu:Hide()
            refresh()
          end)
          menu.options[row] = choice
        end
        button.menu = menu
      end
      window.filterMenu = menu
      menu:Show()
    end)
  end
  local clear = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
  clear:SetPoint("TOPLEFT", 549, 0)
  clear:SetSize(85, 22)
  clear:SetText("Clear filters")
  clear:SetScript("OnClick", function()
    filters = { profession = "", kind = "all" }
    if window.filterMenu then window.filterMenu:Hide() end
    window.search:SetText("")
    labels()
    refresh()
  end)
  bar.controls = controls
  bar.clear = clear
  labels()
end

local function createWindow()
  window = CreateFrame("Frame", "GoldbookWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window:SetSize(WINDOW_WIDTH, 110 + ROWS * ROW_HEIGHT + FILTER_HEIGHT)
  local saved = ns.db.settings.window
  if saved then
    window:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
  else
    window:SetPoint("CENTER")
  end
  window:SetClampedToScreen(true)
  -- Above the game's own panels, so it is not opened behind the Options window.
  window:SetFrameStrata("DIALOG")
  window:SetToplevel(true)
  window:SetBackdrop(UI.BACKDROP)
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    ns.db.settings.window = { point, relativePoint, x, y }
  end)
  window:EnableMouseWheel(true)
  window:SetScript("OnMouseWheel", scroll)
  window:Hide()
  window:SetScript("OnHide", function()
    if window.filterMenu then window.filterMenu:Hide() end
  end)
  tinsert(UISpecialFrames, "GoldbookWindow")

  local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", LEFT, -12)
  title:SetText("Goldbook")
  window.version = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  window.version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 4, 1)
  window.version:SetTextColor(unpack(QUIET))
  window.version:SetText(ns.VERSION)

  local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local search = CreateFrame("EditBox", nil, window, "InputBoxTemplate")
  search:SetSize(146, 20)
  search:SetPoint("TOPLEFT", 124, -10)
  search:SetAutoFocus(false)
  search.hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  search.hint:SetPoint("LEFT")
  search.hint:SetText("Search items")
  -- Typing a name leaves the item view for the price list.
  search:SetScript("OnTextChanged", function(self, userInput)
    self.hint:SetShown(self:GetText() == "" and not self:HasFocus())
    if userInput and view == "item" then
      view = "prices"
    end
    refresh()
  end)
  search:SetScript("OnEditFocusGained", function(self)
    self.hint:Hide()
  end)
  search:SetScript("OnEditFocusLost", function(self)
    self.hint:SetShown(self:GetText() == "")
  end)
  search:SetScript("OnEscapePressed", search.ClearFocus)
  window.search = search

  window.tabs = {}
  for index, name in ipairs(VIEW_ORDER) do
    local tab = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    tab:SetSize(TAB_WIDTH, 22)
    tab:SetPoint("TOPLEFT", TAB_LEFT + (index - 1) * TAB_STEP, -9)
    tab:SetText(VIEWS[name].tab)
    tab:SetScript("OnClick", function()
      UI.Show(name)
    end)
    window.tabs[name] = tab
  end

  addFilters()

  window.body = CreateFrame("Frame", nil, window)
  window.body:SetPoint("TOPLEFT")
  window.body:SetSize(WINDOW_WIDTH, 58 + ROWS * ROW_HEIGHT)
  addHeaders(-40)
  window.rows = {}
  for index = 1, ROWS do
    window.rows[index] = addRow(-58 - (index - 1) * ROW_HEIGHT)
  end
  addScrollMarker(-56)
  addChart()

  window.reload = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
  window.reload:SetSize(RELOAD_WIDTH, 22)
  window.reload:SetPoint("BOTTOMRIGHT", LEFT + TABLE_WIDTH - WINDOW_WIDTH, 6)
  window.reload:SetText("Reload")
  -- Without the click's arguments, which a client function may refuse.
  window.reload:SetScript("OnClick", function()
    ReloadUI()
  end)
  window.reload:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Saves Goldbook's data so the sync agent can upload it.", 1, 1, 1)
    GameTooltip:Show()
  end)
  window.reload:SetScript("OnLeave", GameTooltip_Hide)

  window.status = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  window.status:SetPoint("BOTTOMLEFT", LEFT, 12)
  window.status:SetWidth(TABLE_WIDTH - RELOAD_WIDTH - GAP)
  window.status:SetJustifyH("LEFT")
  window.status:SetWordWrap(false)
  window.status:SetTextColor(unpack(QUIET))
end

-- Opens the window on a view. Without `text` the search box keeps its text.
function UI.Show(name, text)
  if not window then
    createWindow()
  end
  view = name
  window:Show()
  window:Raise()
  if text and text ~= window.search:GetText() then
    window.search:SetText(text)
  else
    refresh()
  end
end

-- Opens the price history of an item, given its link or its key.
function UI.ShowItem(linkOrKey)
  local key = Database.KeyFromLink(ns.db, ns.RealmKey(), linkOrKey) or linkOrKey
  local name, quality = Database.Item(ns.db, key)
  if not name then
    local infoName, _, infoQuality = C_Item.GetItemInfo(linkOrKey)
    name, quality = infoName, infoQuality
  end
  shownItem = { key = key, name = name or ("item " .. key), quality = quality or 1 }
  UI.Show("item")
end

function UI.Toggle()
  if window and window:IsShown() then
    window:Hide()
  else
    UI.Show(view)
  end
end

function UI.Refresh()
  if window and window:IsShown() then
    refresh()
  end
end

-- Changes that come in bursts, like gold changing for each of ten deals
-- bought or item names arriving, redraw the window once.
function UI.RefreshSoon()
  if refreshPending or not (window and window:IsShown()) then
    return
  end
  refreshPending = true
  C_Timer.After(REFRESH_DELAY, function()
    refreshPending = false
    UI.Refresh()
  end)
end

local function createScanButton()
  scanButton = CreateFrame("Button", "GoldbookScanButton", AuctionHouseFrame, "UIPanelButtonTemplate")
  scanButton:SetSize(150, 22)
  scanButton:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -4, 2)
  scanButton:SetText("Goldbook scan")
  scanButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  scanButton:SetScript("OnClick", function(_, button)
    Scanner.Start(button == "RightButton" and "replicate" or "browse")
  end)
  scanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Goldbook")
    GameTooltip:AddLine("Left click: quick scan of lowest prices.", 1, 1, 1)
    GameTooltip:AddLine("Right click: full scan with market values and order books, once per 15 minutes.", 1, 1, 1)
    GameTooltip:Show()
  end)
  scanButton:SetScript("OnLeave", GameTooltip_Hide)
end

-- Bags, the bank, chat links, loot and the auction house pass every modified
-- click on an item through HandleModifiedItemClick.
if HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    -- In restricted content the link can be a secret value that must not be read.
    if not link or (issecretvalue and issecretvalue(link)) or type(link) ~= "string" then
      return
    end
    if IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() and link:find("item:", 1, true)
      and ns.db.settings.altClick ~= false then
      UI.ShowItem(link)
    end
  end)
end

Scanner.Subscribe(function(kind, payload)
  if not scanButton or kind == "refused" then
    return
  end
  scanButton:SetText(kind == "progress" and payload or "Goldbook scan")
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:SetScript("OnEvent", function()
  if not scanButton and AuctionHouseFrame then
    createScanButton()
  end
end)
