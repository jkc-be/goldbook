local _, ns = ...
local Codec, Database, Scanner, Advisor, Ledger, Trades = ns.Codec, ns.Database, ns.Scanner, ns.Advisor, ns.Ledger, ns.Trades

local UI = {}
ns.UI = UI

local WINDOW_WIDTH, WINDOW_HEIGHT = 860, 640
local TITLE_HEIGHT, RAIL_WIDTH, RAIL_STEP = 46, 148, 36
-- The page right of the rail, inside its padding and the window's border.
local PAGE_LEFT, PAGE_TOP, PAGE_WIDTH, PAGE_BOTTOM = RAIL_WIDTH + 16, TITLE_HEIGHT + 13, 681, 11
local GAP = 10
local HEAD_HEIGHT, TOOLBAR_HEIGHT, STATUS_HEIGHT, HEADING_HEIGHT = 28, 28, 16, 30
local CARD_GAP, CARD_HEIGHT, CARD_DETAIL_HEIGHT = 8, 54, 72
local HEADER_HEIGHT, ROW_HEIGHT, MAX_ROWS, MAX_COLUMNS = 27, 23, 20, 6
local CELL_PAD, ICON_SIZE = 10, 18
local SPARK_WIDTH, SPARK_HEIGHT, SPARK_DAYS = 64, 16, 7
local SEARCH_WIDTH, CHIP_HEIGHT, MENU_WIDTH, MENU_ROW = 240, 24, 200, 22
local SIDE_ROW = 26
-- The plot sits right of its axis labels and left of the latest values'
-- labels, under its legend, over the band of amounts and the dates.
local AXIS_WIDTH, AXIS_HEIGHT, VALUE_WIDTH, CHART_PAD = 50, 20, 58, 4
local PLOT_TOP, LEGEND_TOP, BAND_HEIGHT, BAND_GAP = 8, 28, 30, 14
local AXIS_STEPS, MAX_GRID, MAX_DATES = 4, 8, 10
-- The area under a chart line is drawn as vertical strips this wide.
local STRIP = 3
local CHART_DAYS = 30
-- A chart of few days still spans this many, so its points do not crowd one edge.
local MIN_SPAN_DAYS = 3
local SELL_ACTIONS = { auction = "Auction", vendor = "Vendor", unknown = "No price" }
local REFRESH_DELAY = 0.2
-- The window's own scale, over the game's UI scale.
local MIN_SCALE, MAX_SCALE = 0.7, 1.4
local DAY = 24 * 3600
local MONTH = 30
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

-- Two palettes with the same keys, as hex. Every coloured widget is painted
-- from the active one, and painted again when the theme changes.
--
-- A client's brightness and contrast settings brighten every pixel, and can
-- turn anything lighter than about c0c0c0 white (tests/client.lua has the
-- transfer one player's game showed). So the light palette draws its
-- structure with lines dark enough to survive that, and its text dark enough
-- to keep its contrast; tests/run.lua checks both palettes plainly and through
-- that transfer.
local PALETTES = {
  light = {
    bg = "f0e4c4", rail = "e2cc96", panel = "fcf7e8", line = "b19c70", edge = "a08a5c", field = "fffbf0",
    text = "211a10", muted = "4e412d", railText = "3a2e1c", gold = "8a5a06", goldhi = "684202", brand = "80520a",
    on = "e2cd92", gain = "0f5214", loss = "8e1a10",
    titleTop = "e4cf98", titleBottom = "d2b574",
    buttonTop = "eed59a", buttonBottom = "d8b464", buttonEdge = "8a6a24", buttonText = "2a1e04",
    hover = 0.14, area = 0.65, bar = 1, second = "464650",
    coins = { gold = "674800", silver = "464650", copper = "843114" },
    quality = { [0] = "4d4d4d", "211a10", "0e5208", "003ea1", "671da1", "803100", "57420c", "004a63" },
  },
  dark = {
    bg = "120f0b", rail = "191510", panel = "1d1914", line = "3a3123", edge = "54472f", field = "0d0b08",
    text = "f2ebdd", muted = "ab9f89", railText = "d8cdb6", gold = "e9b949", goldhi = "ffe08a", brand = "ecb94a",
    on = "3a2d14", gain = "5fd35a", loss = "ff6d5a",
    titleTop = "2c2418", titleBottom = "221c13",
    buttonTop = "3a2d14", buttonBottom = "261d0d", buttonEdge = "8a6a24", buttonText = "ffe08a",
    hover = 0.08, area = 0.42, bar = 0.6, second = "c7c7cf",
    coins = { gold = "ffd34d", silver = "c7c7cf", copper = "eda55f" },
    quality = { [0] = "a3a3a3", "f3eee4", "1eff00", "3d9bff", "c27df8", "ff8000", "e6cc80", "00ccff" },
  },
}
UI.Palettes = PALETTES
local DEFAULT_THEME = "dark"

-- The game's own faces: Friz Quadrata for names and headings, Arial Narrow
-- for figures. Taken from the client, which swaps them for faces with the
-- letters of its language.
local FRIZ, NARROW = STANDARD_TEXT_FONT, NumberFontNormal:GetFont()
-- Words in Friz, which the game draws with even, firm strokes down to small
-- sizes; figures in Arial Narrow, as the game's own number fonts are, so that
-- money fits its columns. Column headers too, as Friz may lack their sort
-- arrows.
local TYPE = {
  brand = { FRIZ, 22 },
  rail = { FRIZ, 16 },
  title = { FRIZ, 22 },
  dialog = { FRIZ, 18 },
  heading = { FRIZ, 15 },
  button = { FRIZ, 14 },
  body = { FRIZ, 13 },
  number = { NARROW, 15 },
  figure = { NARROW, 19 },
  small = { FRIZ, 12 },
  status = { FRIZ, 12 },
  label = { FRIZ, 11 },
  header = { NARROW, 12 },
  axis = { NARROW, 12 },
  close = { NARROW, 20 },
  caret = { NARROW, 8 },
}
local FONT = {}
for role, face in pairs(TYPE) do
  FONT[role] = CreateFont("GoldbookFont" .. role:sub(1, 1):upper() .. role:sub(2))
  FONT[role]:SetFont(face[1], face[2], "")
end

local palette
local painted = {}

local function hexRGB(hex, alpha)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255, alpha or 1
end

local function rgb(key, alpha)
  return hexRGB(palette[key], alpha)
end

-- Runs `apply` now and again whenever the theme changes.
local function paint(apply)
  palette = palette or PALETTES[UI.Theme()]
  painted[#painted + 1] = apply
  apply()
end

function UI.Fill(texture, key, alpha)
  paint(function()
    texture:SetColorTexture(rgb(key, alpha))
  end)
end

function UI.Ink(text, key)
  paint(function()
    text:SetTextColor(rgb(key))
  end)
end

function UI.Box(frame, background, edge)
  frame:SetBackdrop(BACKDROP)
  paint(function()
    frame:SetBackdropColor(rgb(background))
    frame:SetBackdropBorderColor(rgb(edge))
  end)
end

-- Shades the texture's own colours. Clients from before SetGradient took
-- colour objects have SetGradientAlpha.
local function setGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
  if texture.SetGradientAlpha then
    texture:SetGradientAlpha(orientation, r1, g1, b1, a1, r2, g2, b2, a2)
  else
    texture:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
  end
end

-- From `from` at the bottom or left to `to` at the top or right, each a
-- palette key and an alpha.
local function shade(texture, orientation, from, fromAlpha, to, toAlpha)
  texture:SetColorTexture(1, 1, 1, 1)
  paint(function()
    local r1, g1, b1 = rgb(from)
    local r2, g2, b2 = rgb(to)
    setGradient(texture, orientation, r1, g1, b1, fromAlpha, r2, g2, b2, toAlpha)
  end)
end

local function label(parent, font, colour, layer)
  local text = parent:CreateFontString(nil, layer or "OVERLAY")
  text:SetFontObject(FONT[font])
  text:SetWordWrap(false)
  UI.Ink(text, colour)
  return text
end
UI.Label = label

local function tint(key, text)
  return "|cff" .. palette[key] .. text .. "|r"
end

local function money(copper)
  return Codec.Money(copper, palette.coins)
end

-- A round mark: the portrait mask is a white disc, so it takes the colour
-- it is given.
local function disc(texture, size)
  texture:SetTexture(CIRCLE)
  texture:SetSize(size, size)
end

local function fillDisc(texture, key)
  paint(function()
    texture:SetVertexColor(rgb(key))
  end)
end

-- A button in the gold of the reload button, its text in `button.label`.
function UI.Button(parent, text, width, height, name)
  local button = CreateFrame("Button", name, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  button:SetSize(width, height)
  button:SetBackdrop(BACKDROP)
  local face = button:CreateTexture(nil, "BACKGROUND")
  face:SetPoint("TOPLEFT", 1, -1)
  face:SetPoint("BOTTOMRIGHT", -1, 1)
  shade(face, "VERTICAL", "buttonBottom", 1, "buttonTop", 1)
  local glow = button:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints(face)
  UI.Fill(glow, "gold", 0.15)
  paint(function()
    button:SetBackdropColor(0, 0, 0, 0)
    button:SetBackdropBorderColor(rgb("buttonEdge"))
  end)
  button.label = label(button, "button", "buttonText")
  button.label:SetPoint("CENTER")
  button.label:SetText(text)
  return button
end

-- The rail's icons as strokes in a 16 by 16 box, y growing downward. The
-- client leaves out lines much shorter than 4, so curves are a few long
-- strokes rather than many short ones.
local GLYPHS = {
  prices = { { 2, 8, 8, 2, 14, 2, 14, 8, 8, 14, 2, 8 } },
  deals = { { 8, 1, 10, 5.5, 15, 6, 11.2, 9.3, 12.3, 14.2, 8, 11.7, 3.7, 14.2, 4.8, 9.3, 1, 6, 6, 5.5, 8, 1 } },
  sell = { { 3, 5, 13, 5, 12, 14, 4, 14, 3, 5 }, { 4.5, 5, 5.5, 0.8, 10.5, 0.8, 11.5, 5 } },
  movers = { { 1, 12, 5, 8, 8, 11, 14, 4 }, { 10, 4, 14, 4, 14, 8 } },
  -- Two coins stacked, their rims as flat hexagons.
  gold = {
    { 1.5, 5, 5, 2, 11, 2, 14.5, 5, 11, 8, 5, 8, 1.5, 5 },
    { 1.5, 5, 1.5, 10, 5, 13, 11, 13, 14.5, 10, 14.5, 5 },
    { 1.5, 7.5, 5, 10.5, 11, 10.5, 14.5, 7.5 },
  },
  trades = { { 8, 2, 8, 14 }, { 3, 5, 13, 5 }, { 3, 5, 1, 10, 5, 10, 3, 5 }, { 13, 5, 11, 10, 15, 10, 13, 5 } },
}

local window, scanButton
local view, results, offset = "prices", {}, 0
-- The item the item view shows: { key, name, quality }.
local shownItem
-- Where the item view's Back button returns to: { view, search, filters,
-- sort, segment, offset } as they were when the item was opened, or nil for
-- an item opened with the window closed.
local origin
-- sorting[view] = { column, descending }, from the view's own order until a header is clicked.
local sorting = {}
-- chosen[view] = the key of the segment picked in a view with segments.
local chosen = {}
local refreshPending = false
local refresh
local function noFilters()
  return { profession = "", kind = "all" }
end
local filters = noFilters()

local function copy(list)
  local copied = {}
  for key, value in pairs(list) do
    copied[key] = value
  end
  return copied
end

local function plural(count, noun)
  return count .. " " .. noun .. (count == 1 and "" or "s")
end

local function qualityHex(quality)
  return palette.quality[quality] or palette.quality[1]
end

local function itemText(row)
  return "|cff" .. qualityHex(row.quality) .. row.name .. "|r"
end

local function itemIcon(key)
  local lookup = C_Item.GetItemIconByID or GetItemIcon
  return key and lookup and lookup(Codec.BaseID(key)) or QUESTION_MARK
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

-- Colours each stretch of text between the coloured money units, because
-- colour codes do not nest in every client.
local function stretches(hex, text)
  local tinted = ("|r" .. text):gsub("|r([^|]+)", "|r|cff" .. hex .. "%1|r")
  return tinted:sub(3)
end

-- Green for a gain, red for a loss.
local function signed(value, text)
  if value == 0 then
    return text
  end
  return stretches(palette[value > 0 and "gain" or "loss"], text)
end

local function change(copper)
  return signed(copper, (copper > 0 and "+" or copper < 0 and "-" or "") .. money(math.abs(copper)))
end

-- To a tenth; a change that rounds to nothing has no sign.
local function percentText(value)
  local tenths = math.floor(value * 10 + 0.5)
  return tenths == 0 and "0.0%" or ("%+.1f%%"):format(tenths / 10), tenths
end

local function percent(value)
  local text, tenths = percentText(value)
  return signed(tenths, text)
end

local function dayText(day)
  return date("!%a %d %b", day * DAY)
end

local function dateText(day)
  return (date("!%b %d", day * DAY):gsub(" 0", " "))
end

-- A muted label before a figure, as the cards and lists pair them.
local function labelled(text, figure)
  return tint("muted", text) .. " " .. figure
end

local function scrollRange(rows, visible)
  if #rows > visible then
    return (offset + 1) .. "–" .. math.min(offset + visible, #rows) .. " of " .. #rows
  end
end

-- The parts given, skipping the missing ones, joined by a middle dot.
local function joinedStatus(...)
  local parts = {}
  for index = 1, select("#", ...) do
    local part = select(index, ...)
    if part then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, " · ")
end

local function itemHint()
  return ns.db.settings.altClick ~= false and "Alt+click for its history" or nil
end

local function shownHistory()
  return Database.History(ns.db, ns.RealmKey(), shownItem.key)
end

local function keepItem(row)
  return ns.Professions.Matches(row.key, filters.profession, filters.kind)
    and (filters.quality == nil or row.quality == filters.quality)
end

-- Trades within the last month, and the sale that brought in the most.
local function monthOfTrades(now)
  local rows, best = {}, nil
  for _, row in ipairs(Trades.Rows(ns.db)) do
    if row.at >= now - MONTH * DAY then
      rows[#rows + 1] = row
      if row.side ~= "buy" and (not best or row.net > best.net) then
        best = row
      end
    end
  end
  return rows, best
end

local function tradeCards(rows)
  local totals = Trades.Totals(rows)
  return {
    { "Sold", money(totals.sold) },
    { "Bought", money(totals.bought) },
    { "Net", change(totals.net) },
    { "Realized profit", totals.profit and change(totals.profit) or tint("muted", "–") },
  }
end

-- The account as a broker would state it.
local function goldCards()
  local account = Ledger.Performance(ns.db, time())
  local _, bags = Advisor.Sell(ns.db, ns.RealmKey(), ns.BagItems())
  return {
    { "Total gold", money(account.gold), labelled("High", money(account.high)) },
    { "Today", change(account.today), tint("muted", percentText(account.todayPercent) .. " since yesterday") },
    { "30 days", change(account.month), labelled("7 days", change(account.week)) },
    { "Net worth", money(account.gold + bags), labelled("Bags", money(bags)) },
  }
end

-- Total gold per day over the chosen range.
local function goldChart(span)
  local now = time()
  local today = math.floor(now / DAY)
  local points = {}
  for index, total in ipairs(Ledger.History(ns.db, now, span)) do
    local day = today - span + index
    points[index] = { at = day * DAY, values = { total }, when = dayText(day) }
  end
  return { from = (today - span + 1) * DAY, to = today * DAY, points = points, series = { { name = "Total", colour = "gold", area = true } } }
end

local function monthLines()
  local rows, best = monthOfTrades(time())
  local totals = Trades.Totals(rows)
  return {
    { "Sold, after the cut", money(totals.sold) },
    { "Bought", money(totals.bought) },
    { "Net", change(totals.net) },
    { "Realized profit", totals.profit and change(totals.profit) or tint("muted", "–") },
    { "Best sale", best and itemText(best) or tint("muted", "–") },
  }
end

local function evolution()
  return Advisor.Evolution(shownHistory(), time(), CHART_DAYS)
end

-- The shown item's prices over the chosen range of days, as the web's item
-- chart has them: the lowest buyout over an area, the market value, and the
-- amount listed below, by the hour for the last week and by the day before.
-- The time axis starts at the first price in the range, so that an item
-- seen on a few days fills the plot.
local function itemChart(range)
  local now = time()
  local today = math.floor(now / DAY)
  local start = range == 1 and now - DAY or (today - range + 1) * DAY
  local points = {}
  for _, entry in ipairs(Database.Points(ns.db, ns.RealmKey(), shownItem.key)) do
    if entry.at >= start then
      local day = math.floor(entry.at / DAY)
      points[#points + 1] = {
        at = entry.at,
        values = { entry.min, entry.mv > 0 and entry.mv or nil },
        amount = entry.qty,
        when = entry.hourly and date("%a %d %b %H:%M", entry.at) or dayText(day),
      }
    end
  end
  local to = math.max(today * DAY, points[#points] and points[#points].at or 0)
  local from = math.max(start, points[1] and points[1].at or start)
  from = math.max(start, math.min(from, to - MIN_SPAN_DAYS * DAY))
  return {
    from = from,
    to = to,
    points = points,
    series = { { name = "Min buyout", colour = "gold", area = true }, { name = "Market value", colour = "second" } },
    band = { name = "Listed" },
  }
end

local function itemHead()
  local head = { title = itemText(shownItem), icon = shownItem.key, quality = shownItem.quality, tags = {} }
  local record = Database.Lookup(ns.db, ns.RealmKey(), shownItem.key)
  if not record then
    return head
  end
  local moved = evolution()
  head.figure = money(record.min)
  for _, span in ipairs({ { "1 day", moved.day }, { "7 days", moved.week } }) do
    if span[2] then
      head.tags[#head.tags + 1] = labelled(span[1], percent(span[2]))
    end
  end
  return head
end

local function itemCards()
  local none = tint("muted", "–")
  local now = time()
  local record = Database.Lookup(ns.db, ns.RealmKey(), shownItem.key)
  if not record then
    return { { "Market value", none }, { "Usual", none }, { "Listed", none }, { "30-day low", none } }
  end
  local usual = Advisor.Usual(record)
  local vendor = Database.Vendor(ns.db, shownItem.key) or 0
  local moved = evolution()
  return {
    { "Market value", record.mv > 0 and money(record.mv) or none, record.mv > 0 and tint("muted", Codec.Age(now - record.mvAt)) or nil },
    { "Usual", usual and money(usual) or none, vendor > 0 and labelled("Vendor", money(vendor)) or nil },
    { "Listed", tostring(record.qty), tint("muted", (Database.FromServer(ns.db, ns.RealmKey(), shownItem.key) and "From the server, " or "Seen ")
      .. Codec.Age(now - record.seen)) },
    { "30-day low", moved.low and money(moved.low) or none, moved.high and labelled("High", money(moved.high)) or nil },
  }
end

-- The column of 7 day sparklines, which has no field to sort by.
local SPARK = { "7 days", nil, 87, spark = true }

-- What the window can show, one entry per view.
--   blocks    what stacks under the title, top to bottom; the table takes the height left over
--   columns   { label, field, width }; a header click sorts by the field
--   cells     the text of a row's columns, the sparkline column left out
--   rows      (search text, segment) -> the rows; `keep` then filters them by the toolbar's chips
--   items     rows are items to hover and click; `icons` puts the item's icon before its name
--   sort      { column, descending }, the order rows come in; a segment may set its own
--   segments  { key, label } choices at the right of the title, `segment` the first one picked;
--             `badge` instead shows a label and a value there, `aside` a line of text;
--             `rangesOnChart` puts the segments at the right of the chart's legend instead
--   head      (rows) -> { title, sub, figure, icon, quality, tags } for the title line;
--             `back` puts a button before it that returns to the view the item came from
--   cards     (rows) -> up to four { key, value, detail }
--   chart     { height, spec(segment) }, see drawChart
--   heading   a heading over the table; `side` a panel of { label, value } lines beside it
--   status    (rows, visible rows) -> the line under the page
local VIEWS = {
  prices = {
    tab = "Prices",
    items = true,
    icons = true,
    blocks = { "toolbar", "table" },
    search = "Search items",
    chips = { "profession", "kind", "quality" },
    keep = keepItem,
    columns = { { "Item", "name", 250 }, { "Min buyout", "min", 100 }, { "Market value", "mv", 100 }, SPARK, { "Listed", "qty", 56 }, { "Seen", "seen", 86 } },
    sort = { 1, false },
    rows = function(text)
      return Database.Search(ns.db, ns.RealmKey(), text)
    end,
    cells = function(row)
      return itemText(row), money(row.min), row.mv > 0 and money(row.mv) or "", tostring(row.qty),
        tint("muted", Codec.Age(time() - row.seen))
    end,
    head = function(rows)
      return { sub = plural(#rows, "item") .. " on " .. ns.RealmKey() }
    end,
    status = function(rows, visible)
      return joinedStatus(scrollRange(rows, visible), "Click an item to search the auction house", itemHint())
    end,
  },
  deals = {
    tab = "Deals",
    items = true,
    icons = true,
    blocks = { "toolbar", "table" },
    search = "Search deals",
    chips = { "profession", "kind", "quality" },
    keep = keepItem,
    columns = { { "Item", "name", 245 }, { "Buy from", "min", 92 }, { "Sells for", "sell", 93 }, SPARK, { "Profit", "total", 93 }, { "Sell to", "kind", 69 } },
    sort = { 5, true },
    rows = function(text)
      return matching(Advisor.Deals(ns.db, ns.RealmKey(), ns.MinProfit()), text)
    end,
    cells = function(row)
      local sellTo = row.kind == "vendor" and (row.confirmed and "Vendor" or tint("muted", "Vendor?")) or "Auction"
      return itemText(row) .. (row.units and tint("muted", " x" .. row.units) or ""), money(row.min), money(row.sell),
        stretches(palette.gain, money(row.total)), sellTo
    end,
    head = function(rows)
      local scanned = ns.db.scanned[ns.RealmKey()]
      return { sub = scanned and (#rows .. " in the scan of " .. Codec.Age(time() - scanned)) or "Scan the auction house to find deals" }
    end,
    badge = function()
      return { "Min profit", money(ns.MinProfit()) }
    end,
    status = function(rows, visible)
      local unconfirmed
      for _, row in ipairs(rows) do
        if row.kind == "vendor" and not row.confirmed then
          unconfirmed = "Vendor? prices are unconfirmed"
          break
        end
      end
      return joinedStatus(scrollRange(rows, visible), "Click a deal to search for it", unconfirmed)
    end,
  },
  sell = {
    tab = "Sell",
    items = true,
    icons = true,
    blocks = { "toolbar", "table" },
    search = "Search your bags",
    chips = { "profession", "kind", "quality" },
    keep = keepItem,
    columns = { { "Item in bags", "name", 245 }, { "Post at", "post", 90 }, { "Vendor pays", "vendor", 97 }, SPARK, { "Brings in", "value", 91 }, { "Sell to", "action", 69 } },
    sort = { 5, true },
    rows = function(text)
      return matching((Advisor.Sell(ns.db, ns.RealmKey(), ns.BagItems())), text)
    end,
    cells = function(row)
      local action = SELL_ACTIONS[row.action]
      return itemText(row) .. tint("muted", " x" .. row.count), row.post and money(row.post) or "",
        row.vendor > 0 and money(row.vendor) or "", money(row.value), row.action == "auction" and action or tint("muted", action)
    end,
    head = function(rows)
      return { sub = plural(#rows, "item") .. " in your bags" }
    end,
    aside = function(rows)
      local total = 0
      for _, row in ipairs(rows) do
        total = total + row.value
      end
      return "Worth " .. money(total) .. " after the cut"
    end,
    status = function(rows, visible)
      return joinedStatus(scrollRange(rows, visible), "Auction prices undercut the lowest buyout, or hold the usual price when it is far off")
    end,
  },
  movers = {
    tab = "Movers",
    items = true,
    icons = true,
    blocks = { "toolbar", "table" },
    search = "Search movers",
    chips = { "profession", "kind", "quality" },
    keep = keepItem,
    columns = { { "Item", "name", 245 }, { "Price", "min", 96 }, { "Day before", "before", 98 }, SPARK, { "Change", "change", 78 }, { "Listed", "qty", 75 } },
    segments = { { "risers", "Risers", sort = { 5, true } }, { "fallers", "Fallers", sort = { 5, false } } },
    rows = function(text, segment)
      local rows = {}
      for _, row in ipairs(matching(Advisor.Movers(ns.db, ns.RealmKey()), text)) do
        if (row.change > 0) == (segment == "risers") then
          rows[#rows + 1] = row
        end
      end
      return rows
    end,
    cells = function(row)
      return itemText(row), money(row.min), money(row.before), percent(row.change), tostring(row.qty)
    end,
    head = function(rows)
      return { sub = plural(#rows, "price") .. (chosen.movers == "risers" and " rose" or " fell") .. " since the day before" }
    end,
    status = function(rows, visible)
      return joinedStatus(scrollRange(rows, visible), "Click an item to search the auction house", itemHint())
    end,
  },
  gold = {
    tab = "Gold",
    blocks = { "cards", "chart", "table" },
    heading = "Characters",
    columns = { { "Name", "name", 96 }, { "Gold", "gold", 110 }, { "Today", "today", 84 }, { "Played", "idle", 82 } },
    sort = { 2, true },
    segments = { { 7, "1W" }, { 30, "1M" }, { 60, "2M" } },
    segment = 30,
    rows = function()
      return Ledger.Summary(ns.db, time())
    end,
    cells = function(row)
      return row.name:match("^[^-]+"), money(row.gold), row.today ~= 0 and change(row.today) or tint("muted", "–"),
        tint("muted", row.idle == 0 and "today" or (row.idle .. "d ago"))
    end,
    head = function(rows)
      return { sub = plural(#rows, "character") }
    end,
    cards = goldCards,
    chart = { height = 186, spec = goldChart },
    side = { title = "Trades this month", lines = monthLines },
  },
  trades = {
    tab = "Trades",
    icons = true,
    blocks = { "cards", "toolbar", "table" },
    search = "Search items or characters",
    chips = { "character" },
    keep = function(row)
      return filters.character == nil or row.character == filters.character
    end,
    columns = { { "Item", "name", 272 }, { "Each", "each", 104 }, { "Net", "net", 113 }, { "Character", "character", 108 }, { "When", "at", 82 } },
    sort = { 5, true },
    segments = { { "all", "All" }, { "sell", "Sales" }, { "buy", "Purchases" }, { "vendor", "Vendor" } },
    rows = function(text, segment)
      local needle, rows = text:lower(), {}
      for _, row in ipairs(Trades.Rows(ns.db)) do
        if (segment == "all" or row.side == segment)
          and (row.name:lower():find(needle, 1, true) or row.character:lower():find(needle, 1, true)) then
          rows[#rows + 1] = row
        end
      end
      return rows
    end,
    cells = function(row)
      return itemText(row) .. tint("muted", " x" .. row.count .. (row.side == "vendor" and " · vendor" or "")),
        money(row.each), change(row.net), row.character:match("^[^-]+"), tint("muted", Codec.Age(time() - row.at))
    end,
    head = function(rows)
      return { sub = #rows .. " booked" }
    end,
    cards = tradeCards,
    status = function(rows, visible)
      if #Trades.Rows(ns.db) == 0 then
        return "No trades booked. Open a mailbox or sell to a vendor to book them."
      end
      return joinedStatus(scrollRange(rows, visible), "Open a mailbox or sell to a vendor to book more trades")
    end,
  },
  item = {
    back = true,
    blocks = { "toolbar", "chart", "cards", "table" },
    search = "Search items",
    columns = { { "Day", "day", 150 }, { "Min buyout", "min", 150 }, { "Market value", "mv", 150 }, { "Listed", "qty", 100 }, { "Change", "change", 129 } },
    sort = { 1, true },
    segments = { { 1, "1D" }, { 7, "1W" }, { 30, "1M" }, { 60, "2M" } },
    segment = 30,
    rangesOnChart = true,
    rows = function()
      return evolution().rows
    end,
    cells = function(row)
      return dayText(row.day), money(row.min), row.mv > 0 and money(row.mv) or "", tostring(row.qty),
        row.change and percent(row.change) or ""
    end,
    head = itemHead,
    cards = itemCards,
    chart = { height = 200, spec = itemChart },
    status = function(rows, visible)
      if #rows == 0 then
        return "No prices recorded for " .. itemText(shownItem) .. " yet. Scan the auction house."
      end
      return joinedStatus(scrollRange(rows, visible), plural(#rows, "day") .. " recorded for " .. itemText(shownItem),
        "Shift+click its name to link it in chat")
    end,
  },
}
local VIEW_ORDER = { "prices", "deals", "sell", "movers", "gold", "trades" }

-- The chips a toolbar can show: what each offers, as { value, label }.
local FILTERS = {
  profession = function()
    local options = { { "", "All professions" } }
    for _, profession in ipairs(ns.ProfessionData) do
      if #profession.materials > 0 then
        options[#options + 1] = { profession.id, profession.name }
      end
    end
    return options
  end,
  kind = function()
    return { { "all", "All items" }, { "materials-recipes", "Materials and recipes" }, { "materials", "Materials" },
      { "recipes", "Recipes" }, { "crafted", "Crafted items" } }
  end,
  quality = function()
    local options = { { nil, "All qualities" } }
    for id, name in ipairs({ "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }) do
      options[#options + 1] = { id - 1, name }
    end
    return options
  end,
  character = function()
    local characters, seen = {}, {}
    for _, row in ipairs(Trades.Rows(ns.db)) do
      if not seen[row.character] then
        seen[row.character] = true
        characters[#characters + 1] = row.character
      end
    end
    table.sort(characters)
    local options = { { nil, "All characters" } }
    for _, character in ipairs(characters) do
      options[#options + 1] = { character, character:match("^[^-]+") }
    end
    return options
  end,
}

local function filtered()
  local defaults = noFilters()
  for name, value in pairs(filters) do
    if value ~= defaults[name] then
      return true
    end
  end
  return window.search:GetText() ~= ""
end

local function visibleRows()
  return window.table.visible
end

-- A row's sparkline: its lowest price on each of the last 7 days it was
-- seen, green when the newest is at least the oldest.
local function drawSpark(row, key)
  local points = {}
  for index, entry in ipairs(Advisor.Evolution(Database.History(ns.db, ns.RealmKey(), key), time(), SPARK_DAYS).chart) do
    if entry then
      points[#points + 1] = { index, entry.min }
    end
  end
  local low, high = math.huge, -math.huge
  for _, point in ipairs(points) do
    low, high = math.min(low, point[2]), math.max(high, point[2])
  end
  local hex = #points > 1 and palette[points[#points][2] >= points[1][2] and "gain" or "loss"]
  for index, line in ipairs(row.spark.lines) do
    local from, to = points[index], points[index + 1]
    line:SetShown(to ~= nil)
    if to then
      local function spot(point)
        local share = high > low and (point[2] - low) / (high - low) or 0.5
        return (point[1] - 1) / (SPARK_DAYS - 1) * SPARK_WIDTH, 2 + share * (SPARK_HEIGHT - 4)
      end
      line:SetStartPoint("BOTTOMLEFT", row.spark, spot(from))
      line:SetEndPoint("BOTTOMLEFT", row.spark, spot(to))
      line:SetColorTexture(hexRGB(hex))
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
    row.rule:SetShown(item ~= nil)
    row.icon:SetShown(item ~= nil and definition.icons == true)
    row.frame:SetShown(item ~= nil and definition.icons == true)
    if item and definition.icons then
      row.icon:SetTexture(itemIcon(item.key))
      -- Common and poor items get a plain frame, better ones their quality's colour.
      row.frame:SetColorTexture(hexRGB((item.quality or 1) >= 2 and qualityHex(item.quality) or palette.edge))
    end
    local spark = item and window.table.spark
    row.spark:SetShown(spark and true or false)
    if spark then
      drawSpark(row, item.key)
    end
    row.hit.item = item
    row.hit:SetShown(item ~= nil and definition.items == true)
  end
  placeScrollMarker(visible)
  window.status:SetText(definition.status and definition.status(results, visible) or "")
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

local function segmentOf(definition, key)
  for _, segment in ipairs(definition.segments or {}) do
    if segment[1] == key then
      return segment
    end
  end
end

-- Choices side by side from the right edge of the title line, each a
-- button framing its text; `on` is the one drawn picked. Without
-- `onClick` they are a label.
local function showSegments(labels, on, onClick)
  local control = window.segments
  for index = #labels, 1, -1 do
    local button = control.buttons[index]
    button.label:SetText(labels[index])
    if index == #labels then
      button.label:SetPoint("RIGHT", control, "RIGHT", -12, 0)
    else
      button.label:SetPoint("RIGHT", control.buttons[index + 1], "LEFT", -11, 0)
    end
    button.picked:SetShown(index == on)
    button.label:SetTextColor(rgb(index == on and "goldhi" or "muted"))
    button.divider:SetShown(index < #labels)
    button.choice, button.onClick = index, onClick
  end
  for index, button in ipairs(control.buttons) do
    button:SetShown(index <= #labels)
  end
  control:SetShown(#labels > 0)
  if #labels > 0 then
    control.edge:SetPoint("LEFT", control.buttons[1], "LEFT", -1, 0)
  end
end

local function placeChips(definition)
  local toolbar, previous = window.filters, window.search
  for _, chip in pairs(toolbar.controls) do
    chip:SetShown(false)
  end
  for _, name in ipairs(definition.chips or {}) do
    local chip = toolbar.controls[name]
    chip:SetShown(true)
    chip.label:SetPoint("LEFT", previous, "RIGHT", 17, 0)
    previous = chip
  end
  local clear = toolbar.clear
  clear:SetShown(filtered())
  clear.label:SetPoint("LEFT", previous, "RIGHT", 17, 0)
end

local function chipLabels()
  for name, chip in pairs(window.filters.controls) do
    for _, option in ipairs(FILTERS[name]()) do
      if option[1] == filters[name] then
        chip.label:SetText(option[2])
        break
      end
    end
  end
end

-- Stacks the view's blocks under its title and gives the table what is left.
local function layout(definition)
  local top = PAGE_TOP + HEAD_HEIGHT + GAP
  local bottom = WINDOW_HEIGHT - PAGE_BOTTOM - (definition.status and (STATUS_HEIGHT + GAP) or 0)
  local placed = {}
  for _, block in ipairs(definition.blocks) do
    placed[block] = top
    if block == "toolbar" then
      top = top + TOOLBAR_HEIGHT + GAP
    elseif block == "cards" then
      top = top + window.cards.height + GAP
    elseif block == "chart" then
      top = top + definition.chart.height + GAP
    end
  end
  window.filters:SetShown(placed.toolbar ~= nil)
  window.filters:SetPoint("TOPLEFT", window, "TOPLEFT", PAGE_LEFT, -(placed.toolbar or 0))
  window.cards:SetShown(placed.cards ~= nil)
  window.cards:SetPoint("TOPLEFT", window, "TOPLEFT", PAGE_LEFT, -(placed.cards or 0))
  window.chart:SetShown(placed.chart ~= nil)
  if placed.chart then
    window.chart:SetPoint("TOPLEFT", window, "TOPLEFT", PAGE_LEFT, -placed.chart)
    window.chart:SetHeight(definition.chart.height)
  end

  local tableFrame, width = window.table, 2
  for _, column in ipairs(definition.columns) do
    width = width + column[3]
  end
  local height = bottom - placed.table
  tableFrame:SetPoint("TOPLEFT", window, "TOPLEFT", PAGE_LEFT, -placed.table)
  tableFrame:SetSize(width, height)
  local heading = definition.heading and HEADING_HEIGHT or 0
  tableFrame.heading:SetShown(definition.heading ~= nil)
  tableFrame.heading.label:SetText(definition.heading or "")
  tableFrame.columns:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 1, -1 - heading)
  tableFrame.visible = math.min(MAX_ROWS, math.floor((height - 2 - heading - HEADER_HEIGHT) / ROW_HEIGHT))
  window.side:SetShown(definition.side ~= nil)
  if definition.side then
    window.side:SetPoint("TOPLEFT", tableFrame, "TOPRIGHT", CARD_GAP, 0)
    window.side:SetSize(PAGE_WIDTH - width - CARD_GAP, height)
  end

  local left, cellIndex, sort = 0, 0, sorting[view]
  tableFrame.spark = false
  for column = 1, MAX_COLUMNS do
    local spec = definition.columns[column]
    local header, button = window.headers[column], window.headerButtons[column]
    header:SetShown(spec ~= nil)
    button:SetShown(spec ~= nil and spec[2] ~= nil)
    if spec then
      local sorted = sort and sort[1] == column
      header:SetText(spec[1]:upper() .. (sorted and (sort[2] and " ↓" or " ↑") or ""))
      header:SetTextColor(rgb(sorted and "goldhi" or "muted"))
      header:SetJustifyH(column == 1 and "LEFT" or spec.spark and "CENTER" or "RIGHT")
      header:SetPoint("LEFT", tableFrame.columns, "TOPLEFT", left + CELL_PAD, -HEADER_HEIGHT / 2)
      header:SetWidth(spec[3] - 2 * CELL_PAD)
      button:SetPoint("TOPLEFT", tableFrame.columns, "TOPLEFT", left, 0)
      button:SetSize(spec[3], HEADER_HEIGHT)
      for _, row in ipairs(window.rows) do
        if spec.spark then
          row.spark:SetPoint("LEFT", row.hit, "LEFT", left + (spec[3] - SPARK_WIDTH) / 2, 0)
        else
          local cell = row.cells[cellIndex + 1]
          local inset = column == 1 and definition.icons and ICON_SIZE + 7 or 0
          cell:SetPoint("LEFT", row.hit, "LEFT", left + CELL_PAD + inset, 0)
          cell:SetWidth(spec[3] - 2 * CELL_PAD - inset)
          cell:SetJustifyH(column == 1 and "LEFT" or "RIGHT")
          cell:SetFontObject(FONT[column == 1 and "body" or "number"])
        end
      end
      if spec.spark then
        tableFrame.spark = true
      else
        cellIndex = cellIndex + 1
      end
      left = left + spec[3]
    end
  end
  for _, row in ipairs(window.rows) do
    row.hit:SetWidth(width - 2)
    for index, cell in ipairs(row.cells) do
      cell:SetShown(index <= cellIndex)
    end
  end
  tableFrame.rule:SetWidth(width - 2)
  window.scroll:SetPoint("TOPLEFT", tableFrame.columns, "TOPLEFT", width - 7, -HEADER_HEIGHT)
end

local function drawHead(definition)
  local head = window.head
  local spec = definition.head(results)
  local item = spec.icon ~= nil
  head.title:SetText(spec.title or definition.tab)
  head.icon:SetShown(item)
  head.frame:SetShown(item)
  head.link:SetShown(item)
  head.link.key = spec.icon
  head.back:SetShown(definition.back == true)
  head.back.label:SetText("Back to " .. VIEWS[origin and origin.view or "prices"].tab)
  head.frame:ClearAllPoints()
  if definition.back then
    head.frame:SetPoint("LEFT", head.back, "RIGHT", 12, 0)
  else
    head.frame:SetPoint("LEFT", head, "LEFT", 0, 0)
  end
  head.title:ClearAllPoints()
  if item then
    head.title:SetPoint("LEFT", head.frame, "RIGHT", 6, 0)
  else
    head.title:SetPoint("LEFT", window, "TOPLEFT", PAGE_LEFT, -(PAGE_TOP + HEAD_HEIGHT / 2))
  end
  if item then
    head.icon:SetTexture(itemIcon(spec.icon))
    head.frame:SetColorTexture(hexRGB(qualityHex(spec.quality)))
  end
  head.figure:SetText(spec.figure or "")
  head.sub:SetText(spec.sub or "")
  head.sub:SetPoint("BOTTOMLEFT", spec.figure and head.figure or head.title, "BOTTOMRIGHT", 12, spec.figure and 2 or 3)
  local previous = spec.figure and head.figure or head.sub
  for index, tag in ipairs(head.tags) do
    local text = spec.tags and spec.tags[index]
    tag:SetShown(text ~= nil)
    tag.label:SetText(text or "")
    tag.label:SetPoint("LEFT", previous, "RIGHT", 18, 0)
    previous = tag
  end
  head.aside:SetText(definition.aside and definition.aside(results) or "")

  if definition.segments then
    local labels, on = {}, 1
    for index, segment in ipairs(definition.segments) do
      labels[index] = segment[2]
      if segment[1] == chosen[view] then
        on = index
      end
    end
    showSegments(labels, on, function(choice)
      chosen[view] = definition.segments[choice][1]
      sorting[view] = definition.segments[choice].sort and { unpack(definition.segments[choice].sort) } or sorting[view]
      refresh()
    end)
  elseif definition.badge then
    showSegments(definition.badge(), 2)
  else
    showSegments({}, 0)
  end
  local control = window.segments
  control:ClearAllPoints()
  if definition.rangesOnChart then
    control:SetParent(window.chart)
    control:SetPoint("RIGHT", window.chart, "TOPRIGHT", -1 - CHART_PAD, -1 - LEGEND_TOP / 2)
  else
    control:SetParent(head)
    control:SetPoint("RIGHT", head, "RIGHT", 0, 0)
  end
end

local function drawCards(definition)
  local cards = definition.cards and definition.cards(results) or {}
  local detail = false
  for _, card in ipairs(cards) do
    detail = detail or card[3] ~= nil
  end
  window.cards.height = detail and CARD_DETAIL_HEIGHT or CARD_HEIGHT
  for index, card in ipairs(window.cards.cards) do
    local spec = cards[index] or {}
    card:SetHeight(window.cards.height)
    card.key:SetText((spec[1] or ""):upper())
    card.value:SetText(spec[2] or "")
    card.detail:SetText(spec[3] or "")
  end
end

local function drawSide(definition)
  local side = window.side
  side.heading.label:SetText(definition.side and definition.side.title or "")
  local lines = definition.side and definition.side.lines() or {}
  for index, line in ipairs(side.lines) do
    local spec = lines[index]
    line.key:SetText(spec and spec[1] or "")
    line.value:SetText(spec and spec[2] or "")
    line.rule:SetShown(spec ~= nil and index < #lines)
  end
end

-- The hovered point: a rule down through the band, a ring on each line and
-- its bar lit.
local function showMarker(hit)
  local chart = window.chart
  local marker = chart.marker
  marker.rule:SetShown(hit ~= nil)
  for index, ring in ipairs(marker.rings) do
    local y = hit and hit.ys[index]
    ring.ring:SetShown(y ~= nil)
    ring.hole:SetShown(y ~= nil)
    if y then
      ring.ring:SetPoint("CENTER", chart.plot, "BOTTOMLEFT", hit.x, y)
    end
  end
  for index, bar in ipairs(chart.bars) do
    bar:SetAlpha(hit and hit.index == index and 1 or 0.6)
  end
  if hit then
    marker.rule:SetPoint("TOPLEFT", chart.plot, "TOPLEFT", hit.x, 0)
    marker.rule:SetPoint("BOTTOMLEFT", chart.bottom, "BOTTOMLEFT", hit.x, 0)
  end
end

-- An axis step of 1, 2, 2.5 or 5 times a power of ten that splits the
-- range into about AXIS_STEPS.
local function niceStep(range)
  local raw = range / AXIS_STEPS
  local magnitude = 10 ^ math.floor(math.log10(raw))
  for _, factor in ipairs({ 1, 2, 2.5, 5, 10 }) do
    if factor * magnitude >= raw then
      return factor * magnitude
    end
  end
end

-- Money on an axis: its largest unit, and the next one only when it is not zero.
local function axisMoney(copper)
  local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if gold > 0 then
    local text = money(gold * 10000):match("^(.-) ")
    return silver > 0 and (text .. " " .. money(silver * 100):match("^(.-) ")) or text
  end
  return silver > 0 and money(silver * 100):match("^(.-) ") or money(rest)
end

-- A latest value right of a chart: its two largest units, enough to tell
-- two lines close together apart.
local function latestMoney(copper)
  local text = money(copper)
  return copper >= 10000 and text:match("^(.*) ") or text
end

-- The date marks between `from` and `to`, counted back from `to`'s day so
-- that it always has one: hours for a day or so, else every 1, 2, 7 or 14 days.
-- Days are UTC days, as the history keeps them; hours read in local time.
local function dateMarks(from, to)
  local marks = {}
  if to - from <= 2 * DAY then
    local hour = 3600 * 6
    for at = math.floor(to / hour) * hour, from, -hour do
      marks[#marks + 1] = { at = at, text = date("%H:%M", at) }
    end
    return marks
  end
  local days = (to - from) / DAY
  local every = days <= 8 and 1 or days <= 16 and 2 or days <= 35 and 7 or 14
  for day = math.floor(to / DAY), math.ceil(from / DAY), -every do
    marks[#marks + 1] = { at = day * DAY, text = dateText(day) }
  end
  return marks
end

local showPointTip, hidePointTip

-- spec = { from, to, points, series, band }. Times in seconds; `points`
-- oldest first, each { at, values = { [series] = value or nil }, amount,
-- when }; `series` = { { name, colour, area } }, a line per series joining
-- the points that have its value, `area` filling under it; `band` = { name }
-- draws each point's amount as a bar below the plot. A legend names them
-- when there is more than one line or a band.
local function drawChart(spec)
  local chart = window.chart
  local plot, points, series, band = chart.plot, spec.points, spec.series, spec.band
  local width = chart.plotWidth
  local legend = #series > 1 or band ~= nil
  local top = legend and LEGEND_TOP or PLOT_TOP
  local height = chart:GetHeight() - 2 - CHART_PAD - top - AXIS_HEIGHT - (band and BAND_HEIGHT + BAND_GAP or 0)
  plot:SetPoint("TOPLEFT", chart, "TOPLEFT", 1 + CHART_PAD + AXIS_WIDTH, -1 - top)
  plot:SetHeight(height)
  chart.band:SetShown(band ~= nil)
  chart.bottom = band and chart.band or plot

  local low, high = math.huge, -math.huge
  for _, point in ipairs(points) do
    for index = 1, #series do
      local value = point.values[index]
      if value then
        low, high = math.min(low, value), math.max(high, value)
      end
    end
  end
  if high < low then
    low, high = 0, 4
  elseif high == low then
    local pad = math.max(high * 0.1, 2)
    low, high = math.max(0, low - pad), high + pad
  end
  local step = math.max(1, niceStep(high - low))
  low, high = math.floor(low / step) * step, math.ceil(high / step) * step
  local function x(at)
    return (at - spec.from) / (spec.to - spec.from) * width
  end
  local function y(value)
    return (value - low) / (high - low) * height
  end

  for index, grid in ipairs(chart.grid) do
    local value = low + (index - 1) * step
    local shown = value <= high + step / 2
    grid.rule:SetShown(shown)
    grid.label:SetShown(shown)
    if shown then
      grid.rule:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y(value))
      grid.label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y(value))
      grid.label:SetText(axisMoney(value))
    end
  end
  local marks = dateMarks(spec.from, spec.to)
  for index, mark in ipairs(chart.dates) do
    local spot = marks[index]
    mark.rule:SetShown(spot ~= nil)
    mark.label:SetShown(spot ~= nil)
    if spot then
      local at = x(spot.at)
      mark.rule:SetPoint("TOPLEFT", plot, "TOPLEFT", at, 0)
      mark.rule:SetPoint("BOTTOMLEFT", chart.bottom, "BOTTOMLEFT", at, 0)
      mark.label:ClearAllPoints()
      mark.label:SetPoint(at > width - 24 and "TOPRIGHT" or at < 24 and "TOPLEFT" or "TOP", chart.bottom, "BOTTOMLEFT", at, -5)
      mark.label:SetText(spot.text)
    end
  end

  -- Each line's points, and the value under the line at any spot along it.
  local measured = {}
  for index = 1, #series do
    measured[index] = {}
    for _, point in ipairs(points) do
      if point.values[index] then
        measured[index][#measured[index] + 1] = { x = x(point.at), y = y(point.values[index]), value = point.values[index] }
      end
    end
  end
  local area = measured[1]
  local strips, cursor = math.floor(width / STRIP), 1
  local r, g, b = rgb(series[1].colour)
  for index = 1, math.max(strips, #chart.strips) do
    local strip = chart.strips[index]
    if not strip and index <= strips then
      strip = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
      strip:SetWidth(STRIP)
      strip:SetColorTexture(1, 1, 1, 1)
      chart.strips[index] = strip
    end
    local at, level = (index - 0.5) * STRIP
    while area[cursor + 1] and area[cursor + 1].x < at do
      cursor = cursor + 1
    end
    local left, right = area[cursor], area[cursor + 1]
    if series[1].area and index <= strips and left and right and left.x <= at then
      level = left.y + (right.y - left.y) * (at - left.x) / (right.x - left.x)
    end
    strip:SetShown(level ~= nil)
    if level then
      local reach = math.max(1, level)
      strip:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (index - 1) * STRIP, 0)
      strip:SetHeight(reach)
      setGradient(strip, "VERTICAL", r, g, b, 0.03, r, g, b, 0.03 + palette.area * reach / height)
    end
  end

  local ends = {}
  for index, line in ipairs(chart.lines) do
    local spots = measured[index] or {}
    -- A client without lines draws the area and the dots alone.
    for segment = 1, math.max(#line.segments, #spots - 1) do
      local from, to = spots[segment], spots[segment + 1]
      local stroke = line.segments[segment]
      if not stroke and to and plot.CreateLine then
        -- The first line over the second where they meet, as the area is its.
        stroke = plot:CreateLine(nil, "ARTWORK", nil, 3 - index)
        stroke:SetThickness(1.8)
        line.segments[segment] = stroke
      end
      if stroke then
        stroke:SetShown(to ~= nil)
      end
      if stroke and to then
        stroke:SetColorTexture(rgb(series[index].colour))
        stroke:SetStartPoint("BOTTOMLEFT", plot, from.x, from.y)
        stroke:SetEndPoint("BOTTOMLEFT", plot, to.x, to.y)
      end
    end
    local last = spots[#spots]
    line.dot:SetShown(last ~= nil)
    line.value:SetShown(last ~= nil)
    if last then
      line.dot:SetPoint("CENTER", plot, "BOTTOMLEFT", last.x, last.y)
      line.dot:SetVertexColor(rgb(series[index].colour))
      line.value:SetText(latestMoney(last.value))
      ends[#ends + 1] = { label = line.value, y = last.y }
    end
  end
  -- The latest values' labels, moved apart where they would overlap.
  if ends[2] and math.abs(ends[1].y - ends[2].y) < 13 then
    local middle, upper = (ends[1].y + ends[2].y) / 2, ends[1].y >= ends[2].y and 1 or 2
    ends[upper].y, ends[3 - upper].y = middle + 6.5, middle - 6.5
  end
  for _, spot in ipairs(ends) do
    spot.label:SetPoint("LEFT", plot, "BOTTOMLEFT", width + 8, spot.y)
  end

  local most = 0
  for _, point in ipairs(points) do
    most = math.max(most, point.amount or 0)
  end
  chart.most:SetText(band and most > 0 and tostring(most) or "")
  local barWidth = math.max(1.5, math.min(8, width / math.max(1, #points) * 0.5))
  for index = 1, math.max(#points, #chart.hits) do
    local point, before, after = points[index], points[index - 1], points[index + 1]
    local hit, bar = chart.hits[index], chart.bars[index]
    if not hit and point then
      -- Through the plot and the band, so that a low value is as easy to hover as a high one.
      hit = CreateFrame("Frame", nil, plot)
      hit:EnableMouse(true)
      hit:SetScript("OnEnter", showPointTip)
      hit:SetScript("OnLeave", hidePointTip)
      chart.hits[index] = hit
    end
    if not bar and point then
      bar = chart.band:CreateTexture(nil, "ARTWORK")
      paint(function()
        bar:SetColorTexture(rgb("gold", palette.bar))
      end)
      chart.bars[index] = bar
    end
    if hit then
      hit:SetShown(point ~= nil)
    end
    if bar then
      bar:SetShown(point ~= nil and band ~= nil and (point.amount or 0) > 0)
    end
    if point then
      local at = x(point.at)
      local left = before and (x(before.at) + at) / 2 or math.max(0, at - 6)
      local right = after and (x(after.at) + at) / 2 or math.min(width, at + 6)
      hit:SetPoint("TOPLEFT", plot, "TOPLEFT", left, 0)
      hit:SetPoint("BOTTOMRIGHT", chart.bottom, "BOTTOMLEFT", right, 0)
      hit.point, hit.series, hit.band, hit.index, hit.x, hit.ys = point, series, band, index, at, {}
      for line = 1, #series do
        hit.ys[line] = point.values[line] and y(point.values[line])
      end
    end
    if point and band and (point.amount or 0) > 0 then
      bar:SetPoint("BOTTOMLEFT", chart.band, "BOTTOMLEFT", x(point.at) - barWidth / 2, 0)
      bar:SetSize(barWidth, math.max(1, point.amount / most * BAND_HEIGHT))
    end
  end

  for index, key in ipairs(chart.legend) do
    local entry = series[index] or (index == #series + 1 and band) or nil
    key.swatch:SetShown(legend and entry ~= nil)
    key.label:SetShown(legend and entry ~= nil)
    if legend and entry then
      key.label:SetText(entry.name)
      key.swatch:SetSize(entry == band and 8 or 14, entry == band and 10 or 2)
      key.swatch:SetColorTexture(rgb(entry == band and "gold" or entry.colour, entry == band and palette.bar or 1))
    end
  end
  showMarker(nil)
end

-- The view's rows, filtered by the toolbar and sorted, and every part of
-- the page drawn for them.
function refresh()
  local definition = VIEWS[view]
  if definition.segments and not segmentOf(definition, chosen[view]) then
    chosen[view] = definition.segment or definition.segments[1][1]
  end
  local segment = segmentOf(definition, chosen[view])
  sorting[view] = sorting[view] or ((segment and segment.sort or definition.sort) and { unpack(segment and segment.sort or definition.sort) })
  results = definition.rows(window.search:GetText() or "", chosen[view])
  if definition.keep then
    local kept = {}
    for _, row in ipairs(results) do
      if definition.keep(row) then
        kept[#kept + 1] = row
      end
    end
    results = kept
  end
  local sort = sorting[view]
  if sort then
    sortBy(results, definition.columns[sort[1]][2], sort[2])
  end
  offset = 0
  if not definition.chips and window.menu then
    window.menu:Hide()
  end
  window.search.hint:SetText(definition.search or "")
  placeChips(definition)
  drawHead(definition)
  drawCards(definition)
  layout(definition)
  drawSide(definition)
  if definition.chart then
    drawChart(definition.chart.spec(chosen[view]))
  end
  for name, tab in pairs(window.tabs) do
    local active = name == view
    tab.selected:SetShown(active)
    tab.bar:SetShown(active)
    tab.label:SetTextColor(rgb(active and "goldhi" or "railText"))
    for _, line in ipairs(tab.glyph) do
      line:SetColorTexture(rgb(active and "goldhi" or "railText", 0.85))
    end
  end
  local scanned = ns.db.scanned[ns.RealmKey()]
  window.lastScan:SetText(scanned and ("Last scan " .. tint("text", Codec.Age(time() - scanned))) or "No scan yet")
  window.queued:SetText(#ns.db.scans == 0 and "Nothing waiting to sync" or (plural(#ns.db.scans, "scan") .. " waiting to sync"))
  window.purse:SetText(money(Ledger.History(ns.db, time(), 1)[1] or 0))
  render()
end

-- First click sorts text upward and numbers downward; a second click flips.
local function sortColumn(column)
  local sort = sorting[view]
  if sort and sort[1] == column then
    sort[2] = not sort[2]
  else
    local field = VIEWS[view].columns[column][2]
    sorting[view] = { column, type(results[1] and results[1][field]) ~= "string" }
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
local OWNER_LEFT = PAGE_LEFT + 1
local OWNER_RIGHT = WINDOW_WIDTH - PAGE_LEFT - PAGE_WIDTH + 1
local function showItemTip(owner, key)
  GameTooltip:SetOwner(owner, "ANCHOR_NONE")
  GameTooltip:SetHyperlink(Codec.ItemString(key))
  GameTooltip:Show()
  GameTooltip:ClearAllPoints()
  if window:GetRight() + GameTooltip:GetWidth() <= UIParent:GetRight() then
    GameTooltip:SetPoint("TOPLEFT", owner, "TOPRIGHT", OWNER_RIGHT, 0)
  else
    GameTooltip:SetPoint("TOPRIGHT", owner, "TOPLEFT", -OWNER_LEFT, 0)
  end
end

-- A point's time, then each line's value in its colour and the amount
-- listed. Tooltips are dark in either theme, so their keys take the dark
-- palette's colours.
function showPointTip(self)
  local point = self.point
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(point.when)
  for index, line in ipairs(self.series) do
    local value = point.values[index]
    if value then
      local r, g, b = hexRGB(PALETTES.dark[line.colour])
      GameTooltip:AddDoubleLine(line.name, Codec.Money(value), r, g, b, 1, 1, 1)
    end
  end
  if self.band and point.amount then
    local r, g, b = hexRGB(PALETTES.dark.gold)
    GameTooltip:AddDoubleLine(self.band.name, tostring(point.amount), r, g, b, 1, 1, 1)
  end
  GameTooltip:Show()
  showMarker(self)
end

function hidePointTip()
  GameTooltip_Hide()
  showMarker(nil)
end

-- A frame drawn as a panel: the panel colour inside a line.
local function panel(parent, background, edge)
  local frame = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  UI.Box(frame, background or "panel", edge or "line")
  return frame
end

-- A heading across the top of a panel, under a rule.
local function addHeading(parent)
  local heading = CreateFrame("Frame", nil, parent)
  heading:SetPoint("TOPLEFT", 1, -1)
  heading:SetPoint("TOPRIGHT", -1, -1)
  heading:SetHeight(HEADING_HEIGHT - 1)
  heading.label = label(heading, "heading", "goldhi")
  heading.label:SetPoint("LEFT", 9, 0)
  local rule = heading:CreateTexture(nil, "ARTWORK")
  rule:SetPoint("BOTTOMLEFT")
  rule:SetPoint("BOTTOMRIGHT")
  rule:SetHeight(1)
  UI.Fill(rule, "line")
  return heading
end

-- An icon framed in its quality's colour.
local function addIcon(parent, size)
  local frame = parent:CreateTexture(nil, "ARTWORK")
  frame:SetSize(size + 2, size + 2)
  local icon = parent:CreateTexture(nil, "ARTWORK", nil, 1)
  icon:SetPoint("CENTER", frame)
  icon:SetSize(size, size)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  return icon, frame
end

-- A choice framed like a tag, its caret after it. The frame follows the
-- text, so the text is what gets placed.
local function addChip(parent, text, caret)
  local chip = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  UI.Box(chip, "bg", "edge")
  chip.label = label(chip, "small", "railText")
  chip.label:SetText(text)
  local last = chip.label
  if caret then
    chip.caret = label(chip, "caret", "gold")
    chip.caret:SetPoint("LEFT", chip.label, "RIGHT", 5, 0)
    chip.caret:SetText("▼")
    last = chip.caret
  end
  chip:SetPoint("LEFT", chip.label, "LEFT", -9, 0)
  chip:SetPoint("RIGHT", last, "RIGHT", 9, 0)
  chip:SetHeight(CHIP_HEIGHT)
  local glow = chip:CreateTexture(nil, "HIGHLIGHT")
  glow:SetPoint("TOPLEFT", 1, -1)
  glow:SetPoint("BOTTOMRIGHT", -1, 1)
  UI.Fill(glow, "gold", 0.1)
  return chip
end

local function addMenu()
  local menu = panel(window, "panel", "edge")
  menu:SetFrameStrata("TOOLTIP")
  menu:SetWidth(MENU_WIDTH)
  menu:EnableMouse(true)
  menu.options = {}
  menu:Hide()
  window.menu = menu
  return menu
end

-- One menu serves every chip; its options are those of the chip clicked.
local function openMenu(chip, name)
  local menu = window.menu or addMenu()
  local same = menu.owner == chip and menu:IsShown()
  menu:Hide()
  if same then
    return
  end
  menu.owner, chip.menu = chip, menu
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", chip, "BOTTOMLEFT", 0, -2)
  local options = FILTERS[name]()
  menu:SetHeight(#options * MENU_ROW + 8)
  for row = 1, math.max(#options, #menu.options) do
    local choice = menu.options[row]
    if not choice then
      choice = CreateFrame("Button", nil, menu)
      choice:SetPoint("TOPLEFT", 1, -4 - (row - 1) * MENU_ROW)
      choice:SetSize(MENU_WIDTH - 2, MENU_ROW)
      choice.label = label(choice, "body", "text")
      choice.label:SetPoint("LEFT", 9, 0)
      local glow = choice:CreateTexture(nil, "HIGHLIGHT")
      glow:SetAllPoints()
      paint(function()
        glow:SetColorTexture(rgb("gold", palette.hover))
      end)
      menu.options[row] = choice
    end
    local option = options[row]
    choice:SetShown(option ~= nil)
    if option then
      choice.label:SetText(option[2])
      choice.label:SetTextColor(rgb(option[1] == filters[name] and "goldhi" or "text"))
      choice:SetScript("OnClick", function()
        filters[name] = option[1]
        if name == "profession" then
          filters.kind = option[1] ~= "" and "materials" or "all"
        end
        chipLabels()
        menu:Hide()
        refresh()
      end)
    end
  end
  menu:Show()
end

local function addToolbar()
  local bar = CreateFrame("Frame", nil, window)
  bar:SetSize(PAGE_WIDTH, TOOLBAR_HEIGHT)
  window.filters = bar

  local search = CreateFrame("EditBox", nil, bar, BackdropTemplateMixin and "BackdropTemplate" or nil)
  search:SetSize(SEARCH_WIDTH, TOOLBAR_HEIGHT)
  search:SetPoint("LEFT")
  search:SetFontObject(FONT.body)
  search:SetTextInsets(9, 9, 0, 0)
  search:SetAutoFocus(false)
  UI.Box(search, "field", "edge")
  UI.Ink(search, "text")
  search.hint = label(search, "body", "muted")
  search.hint:SetPoint("LEFT", 9, 0)
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

  bar.controls = {}
  for name in pairs(FILTERS) do
    local chip = addChip(bar, "", true)
    chip:SetScript("OnClick", function()
      openMenu(chip, name)
    end)
    bar.controls[name] = chip
  end
  bar.clear = addChip(bar, "Clear filters")
  bar.clear:SetScript("OnClick", function()
    filters = noFilters()
    if window.menu then
      window.menu:Hide()
    end
    window.search:SetText("")
    chipLabels()
    refresh()
  end)
  chipLabels()
end

local function addHead()
  local head = CreateFrame("Frame", nil, window)
  window.head = head
  head:SetPoint("TOPLEFT", window, "TOPLEFT", PAGE_LEFT, -PAGE_TOP)
  head:SetSize(PAGE_WIDTH, HEAD_HEIGHT)
  head.title = label(head, "title", "text")
  head.icon, head.frame = addIcon(head, 24)
  head.figure = label(head, "figure", "text")
  head.figure:SetPoint("BOTTOMLEFT", head.title, "BOTTOMRIGHT", 14, 1)
  head.sub = label(head, "small", "muted")
  head.tags = {}
  for index = 1, 2 do
    local tag = addChip(head, "")
    tag.label:SetFontObject(FONT.status)
    tag:SetHeight(20)
    tag:EnableMouse(false)
    head.tags[index] = tag
  end
  head.aside = label(head, "small", "muted")
  head.aside:SetPoint("RIGHT", head, "RIGHT", 0, 0)

  -- Over the name of the item the item view shows: hover for its tooltip,
  -- Shift+click to link it in chat. As wide as the table's rows.
  local link = CreateFrame("Button", nil, head)
  link:SetPoint("TOPLEFT", window, "TOPLEFT", OWNER_LEFT, -PAGE_TOP)
  link:SetSize(PAGE_WIDTH - 2, HEAD_HEIGHT)
  link:SetScript("OnEnter", function(self)
    showItemTip(self, self.key)
  end)
  link:SetScript("OnLeave", GameTooltip_Hide)
  link:SetScript("OnClick", function(self)
    local _, itemLink = C_Item.GetItemInfo(Codec.ItemString(self.key))
    if IsShiftKeyDown() and itemLink and ChatEdit_InsertLink then
      ChatEdit_InsertLink(itemLink)
    end
  end)
  head.link = link

  -- On the link, so that it takes the clicks over the item's name.
  local back = UI.Button(link, "", 1, 24)
  -- The label hangs on the head before the button is sized from it: hung on
  -- the button, as UI.Button left it, it would depend on what it sizes.
  back.label:ClearAllPoints()
  back.label:SetPoint("LEFT", head, "LEFT", 23, 0)
  back:SetPoint("LEFT", head, "LEFT", 0, 0)
  back:SetPoint("RIGHT", back.label, "RIGHT", 11, 0)
  -- A chevron pointing back, drawn as the rail's icons are.
  if back.CreateLine then
    for _, stroke in ipairs({ { 13, 7, 8.5, 12 }, { 8.5, 12, 13, 17 } }) do
      local line = back:CreateLine(nil, "ARTWORK")
      line:SetThickness(1.6)
      line:SetStartPoint("TOPLEFT", back, stroke[1], -stroke[2])
      line:SetEndPoint("TOPLEFT", back, stroke[3], -stroke[4])
      UI.Fill(line, "buttonText")
    end
  end
  back:SetScript("OnClick", function()
    UI.Back()
  end)
  head.back = back

  -- The segmented control: a line around buttons that frame their text.
  local control = CreateFrame("Frame", nil, head)
  control:SetPoint("RIGHT", head, "RIGHT", 0, 0)
  control:SetSize(1, 22)
  control.edge = control:CreateTexture(nil, "BACKGROUND")
  control.edge:SetPoint("TOPRIGHT")
  control.edge:SetPoint("BOTTOMRIGHT")
  UI.Fill(control.edge, "edge")
  local fill = control:CreateTexture(nil, "BACKGROUND", nil, 1)
  fill:SetPoint("TOPLEFT", control.edge, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", control.edge, "BOTTOMRIGHT", -1, 1)
  UI.Fill(fill, "bg")
  control.buttons = {}
  for index = 1, 4 do
    local button = CreateFrame("Button", nil, control)
    button.label = label(button, "status", "muted")
    button:SetPoint("LEFT", button.label, "LEFT", -11, 0)
    button:SetPoint("RIGHT", button.label, "RIGHT", 11, 0)
    button:SetHeight(20)
    button.picked = button:CreateTexture(nil, "BACKGROUND")
    button.picked:SetAllPoints()
    UI.Fill(button.picked, "on")
    button.divider = button:CreateTexture(nil, "ARTWORK")
    button.divider:SetPoint("TOPRIGHT", button, "TOPRIGHT", 1, 0)
    button.divider:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, 0)
    button.divider:SetWidth(1)
    UI.Fill(button.divider, "edge")
    button:SetScript("OnClick", function(self)
      if self.onClick then
        self.onClick(self.choice)
      end
    end)
    control.buttons[index] = button
  end
  window.segments = control
end

local function addCards()
  local row = CreateFrame("Frame", nil, window)
  row:SetSize(PAGE_WIDTH, CARD_HEIGHT)
  row.cards, row.height = {}, CARD_HEIGHT
  local width = (PAGE_WIDTH - 3 * CARD_GAP) / 4
  for index = 1, 4 do
    local card = panel(row)
    card:SetPoint("TOPLEFT", (index - 1) * (width + CARD_GAP), 0)
    card:SetSize(width, CARD_HEIGHT)
    card.key = label(card, "label", "muted")
    card.key:SetPoint("TOPLEFT", 10, -9)
    card.value = label(card, "figure", "text")
    card.value:SetPoint("TOPLEFT", 10, -25)
    card.detail = label(card, "status", "text")
    card.detail:SetPoint("TOPLEFT", 10, -49)
    row.cards[index] = card
  end
  window.cards = row
end

local function addRow(columns, index)
  local top = -HEADER_HEIGHT - (index - 1) * ROW_HEIGHT
  local hit = CreateFrame("Button", nil, columns)
  hit:SetPoint("TOPLEFT", columns, "TOPLEFT", 0, top)
  hit:SetHeight(ROW_HEIGHT - 1)
  local glow = hit:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  paint(function()
    glow:SetColorTexture(rgb("gold", palette.hover))
  end)
  local bar = hit:CreateTexture(nil, "HIGHLIGHT")
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("BOTTOMLEFT")
  bar:SetWidth(3)
  UI.Fill(bar, "gold")
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

  local rule = columns:CreateTexture(nil, "BORDER")
  rule:SetPoint("TOPLEFT", hit, "BOTTOMLEFT")
  rule:SetPoint("TOPRIGHT", hit, "BOTTOMRIGHT")
  rule:SetHeight(1)
  UI.Fill(rule, "line")
  local icon, frame = addIcon(columns, ICON_SIZE - 2)
  frame:SetPoint("LEFT", hit, "LEFT", CELL_PAD, 0)
  local cells = {}
  for column = 1, MAX_COLUMNS do
    cells[column] = label(columns, "body", "text")
  end
  local spark = CreateFrame("Frame", nil, columns)
  spark:SetSize(SPARK_WIDTH, SPARK_HEIGHT)
  spark.lines = {}
  -- A client without lines draws no sparklines.
  if spark.CreateLine then
    for segment = 1, SPARK_DAYS - 1 do
      local line = spark:CreateLine(nil, "ARTWORK")
      line:SetThickness(1.5)
      spark.lines[segment] = line
    end
  end
  return { cells = cells, rule = rule, icon = icon, frame = frame, spark = spark, hit = hit }
end

local function addTable()
  local frame = panel(window)
  window.table = frame
  frame.heading = addHeading(frame)
  frame.columns = CreateFrame("Frame", nil, frame)
  frame.columns:SetSize(1, 1)
  frame.rule = frame.columns:CreateTexture(nil, "BORDER")
  frame.rule:SetPoint("TOPLEFT", frame.columns, "TOPLEFT", 0, -HEADER_HEIGHT + 1)
  frame.rule:SetHeight(1)
  UI.Fill(frame.rule, "edge")
  window.headers, window.headerButtons = {}, {}
  for column = 1, MAX_COLUMNS do
    window.headers[column] = label(frame.columns, "header", "muted")
    local button = CreateFrame("Button", nil, frame.columns)
    button:SetScript("OnClick", function()
      sortColumn(column)
    end)
    window.headerButtons[column] = button
  end
  window.rows = {}
  for index = 1, MAX_ROWS do
    window.rows[index] = addRow(frame.columns, index)
  end

  local track = CreateFrame("Frame", nil, frame.columns)
  track:SetWidth(3)
  local groove = track:CreateTexture(nil, "BACKGROUND")
  groove:SetAllPoints()
  UI.Fill(groove, "line")
  track.thumb = track:CreateTexture(nil, "ARTWORK")
  track.thumb:SetWidth(3)
  UI.Fill(track.thumb, "gold", 0.7)
  window.scroll = track

  local side = panel(window)
  side.heading = addHeading(side)
  side.lines = {}
  for index = 1, 5 do
    local line = CreateFrame("Frame", nil, side)
    line:SetPoint("TOPLEFT", 1, -HEADING_HEIGHT - (index - 1) * SIDE_ROW)
    line:SetPoint("TOPRIGHT", -1, -HEADING_HEIGHT - (index - 1) * SIDE_ROW)
    line:SetHeight(SIDE_ROW - 1)
    line.key = label(line, "body", "text")
    line.key:SetPoint("LEFT", 10, 0)
    line.value = label(line, "number", "text")
    line.value:SetPoint("RIGHT", -10, 0)
    line.rule = line:CreateTexture(nil, "BORDER")
    line.rule:SetPoint("TOPLEFT", line, "BOTTOMLEFT")
    line.rule:SetPoint("TOPRIGHT", line, "BOTTOMRIGHT")
    line.rule:SetHeight(1)
    UI.Fill(line.rule, "line")
    side.lines[index] = line
  end
  window.side = side
end

local function addChart()
  local chart = panel(window)
  chart:SetWidth(PAGE_WIDTH)
  local plot = CreateFrame("Frame", nil, chart)
  chart.plotWidth = PAGE_WIDTH - 2 - 2 * CHART_PAD - AXIS_WIDTH - VALUE_WIDTH
  plot:SetWidth(chart.plotWidth)
  chart.plot = plot
  local band = CreateFrame("Frame", nil, chart)
  band:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -BAND_GAP)
  band:SetSize(chart.plotWidth, BAND_HEIGHT)
  local base = band:CreateTexture(nil, "BORDER")
  base:SetPoint("BOTTOMLEFT")
  base:SetPoint("BOTTOMRIGHT")
  base:SetHeight(1)
  UI.Fill(base, "edge")
  chart.most = label(band, "axis", "muted")
  chart.most:SetPoint("RIGHT", band, "TOPLEFT", -6, -4)
  chart.band, chart.bottom = band, plot

  chart.grid = {}
  for index = 1, MAX_GRID do
    local rule = plot:CreateTexture(nil, "BACKGROUND")
    rule:SetSize(chart.plotWidth, 1)
    UI.Fill(rule, "line")
    local value = label(plot, "axis", "muted")
    value:SetJustifyH("RIGHT")
    chart.grid[index] = { rule = rule, label = value }
  end
  chart.dates = {}
  for index = 1, MAX_DATES do
    local rule = plot:CreateTexture(nil, "BACKGROUND")
    rule:SetWidth(1)
    UI.Fill(rule, "line")
    local day = label(plot, "axis", "muted")
    chart.dates[index] = { rule = rule, label = day }
  end
  chart.strips, chart.hits, chart.bars = {}, {}, {}

  -- Two lines at most: segments made as points need them, a dot on the
  -- latest point and its value right of the plot.
  chart.lines = {}
  for index = 1, 2 do
    local dot = plot:CreateTexture(nil, "OVERLAY")
    disc(dot, 7)
    local value = label(chart, "axis", "text")
    chart.lines[index] = { segments = {}, dot = dot, value = value }
  end

  chart.legend = {}
  local previous
  for index = 1, 3 do
    local swatch = chart:CreateTexture(nil, "ARTWORK")
    if previous then
      swatch:SetPoint("LEFT", previous, "RIGHT", 16, 0)
    else
      swatch:SetPoint("LEFT", chart, "TOPLEFT", 1 + CHART_PAD + AXIS_WIDTH, -1 - LEGEND_TOP / 2)
    end
    local text = label(chart, "label", "muted")
    text:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
    chart.legend[index] = { swatch = swatch, label = text }
    previous = text
  end

  local marker = { rings = {} }
  marker.rule = plot:CreateTexture(nil, "OVERLAY")
  marker.rule:SetWidth(1)
  UI.Fill(marker.rule, "muted", 0.8)
  for index = 1, 2 do
    local ring = plot:CreateTexture(nil, "OVERLAY", nil, 1)
    disc(ring, 9)
    local hole = plot:CreateTexture(nil, "OVERLAY", nil, 2)
    disc(hole, 5)
    hole:SetPoint("CENTER", ring)
    fillDisc(hole, "panel")
    marker.rings[index] = { ring = ring, hole = hole }
  end
  fillDisc(marker.rings[1].ring, "gold")
  fillDisc(marker.rings[2].ring, "second")
  chart.marker = marker
  window.chart = chart
end

local function addRail()
  local rail = CreateFrame("Frame", nil, window)
  rail:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -1 - TITLE_HEIGHT)
  rail:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 1, 1)
  rail:SetWidth(RAIL_WIDTH)
  local background = rail:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints()
  UI.Fill(background, "rail")
  local edge = rail:CreateTexture(nil, "BORDER")
  edge:SetPoint("TOPLEFT", rail, "TOPRIGHT")
  edge:SetPoint("BOTTOMLEFT", rail, "BOTTOMRIGHT")
  edge:SetWidth(1)
  UI.Fill(edge, "edge")

  window.tabs = {}
  for index, name in ipairs(VIEW_ORDER) do
    local tab = CreateFrame("Button", nil, rail)
    tab:SetPoint("TOPLEFT", 0, -10 - (index - 1) * RAIL_STEP)
    tab:SetSize(RAIL_WIDTH, RAIL_STEP)
    tab.selected = tab:CreateTexture(nil, "BACKGROUND")
    tab.selected:SetAllPoints()
    shade(tab.selected, "HORIZONTAL", "gold", 0.16, "gold", 0)
    tab.bar = tab:CreateTexture(nil, "ARTWORK")
    tab.bar:SetPoint("TOPLEFT")
    tab.bar:SetPoint("BOTTOMLEFT")
    tab.bar:SetWidth(3)
    UI.Fill(tab.bar, "gold")
    tab.label = label(tab, "rail", "railText")
    tab.label:SetPoint("LEFT", 40, 0)
    tab.label:SetText(VIEWS[name].tab)
    local box = CreateFrame("Frame", nil, tab)
    box:SetPoint("LEFT", 14, 0)
    box:SetSize(16, 16)
    tab.glyph = {}
    -- A client without lines shows the labels alone.
    if tab.CreateLine then
      for _, stroke in ipairs(GLYPHS[name]) do
        for point = 3, #stroke, 2 do
          local line = tab:CreateLine(nil, "ARTWORK")
          line:SetThickness(1.5)
          line:SetStartPoint("TOPLEFT", box, stroke[point - 2], -stroke[point - 1])
          line:SetEndPoint("TOPLEFT", box, stroke[point], -stroke[point + 1])
          tab.glyph[#tab.glyph + 1] = line
        end
      end
    end
    tab:SetScript("OnClick", function()
      UI.Show(name)
    end)
    window.tabs[name] = tab
  end

  local rule = rail:CreateTexture(nil, "BORDER")
  rule:SetPoint("BOTTOMLEFT", 0, 92)
  rule:SetPoint("BOTTOMRIGHT", 0, 92)
  rule:SetHeight(1)
  UI.Fill(rule, "line")
  window.lastScan = label(rail, "status", "muted")
  window.lastScan:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 14, -12)
  window.queued = label(rail, "status", "muted")
  window.queued:SetPoint("TOPLEFT", window.lastScan, "BOTTOMLEFT", 0, -3)

  window.reload = UI.Button(rail, "Reload", RAIL_WIDTH - 28, 26)
  window.reload:SetPoint("BOTTOMLEFT", 14, 13)
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
end

-- The band across the top of a Goldbook frame, gilded along its top edge,
-- with a close button and, given `text`, a title.
function UI.TitleBar(frame, height, text)
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", -1, -1)
  bar:SetHeight(height)
  local background = bar:CreateTexture(nil, "BACKGROUND")
  background:SetPoint("TOPLEFT")
  background:SetPoint("BOTTOMRIGHT", 0, 1)
  shade(background, "VERTICAL", "titleBottom", 1, "titleTop", 1)
  local rule = bar:CreateTexture(nil, "BORDER")
  rule:SetPoint("BOTTOMLEFT")
  rule:SetPoint("BOTTOMRIGHT")
  rule:SetHeight(1)
  UI.Fill(rule, "edge")
  local gilt = bar:CreateTexture(nil, "OVERLAY")
  gilt:SetPoint("TOPLEFT")
  gilt:SetPoint("TOPRIGHT")
  gilt:SetHeight(2)
  UI.Fill(gilt, "gold", 0.8)

  local close = CreateFrame("Button", nil, bar, BackdropTemplateMixin and "BackdropTemplate" or nil)
  close:SetSize(24, 24)
  close:SetPoint("RIGHT", -12, 0)
  UI.Box(close, "bg", "edge")
  close.label = label(close, "close", "muted")
  close.label:SetPoint("CENTER", 0, 1)
  close.label:SetText("×")
  local glow = close:CreateTexture(nil, "HIGHLIGHT")
  glow:SetPoint("TOPLEFT", 1, -1)
  glow:SetPoint("BOTTOMRIGHT", -1, 1)
  UI.Fill(glow, "gold", 0.15)
  close:SetScript("OnClick", function()
    frame:Hide()
  end)
  bar.close = close

  if text then
    local title = label(bar, "dialog", "brand")
    title:SetPoint("LEFT", 14, 0)
    title:SetText(text)
  end
  return bar
end

local function showThemeTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine(UI.Theme() == "dark" and "Light window" or "Dark window")
  GameTooltip:AddLine("Click to draw Goldbook " .. (UI.Theme() == "dark" and "on light parchment." or "in dark ink."), 1, 1, 1)
  GameTooltip:AddLine("/gb theme and the Options panel switch it too.", 1, 1, 1)
  GameTooltip:Show()
end

-- Left of the close button, a half-filled ring: the usual sign for light and
-- dark. Drawn from discs, as the client draws them in any size.
local function addThemeToggle(bar)
  local toggle = CreateFrame("Button", nil, bar, BackdropTemplateMixin and "BackdropTemplate" or nil)
  toggle:SetSize(24, 24)
  toggle:SetPoint("RIGHT", bar.close, "LEFT", -8, 0)
  UI.Box(toggle, "bg", "edge")
  local ring = toggle:CreateTexture(nil, "ARTWORK")
  disc(ring, 14)
  ring:SetPoint("CENTER")
  fillDisc(ring, "railText")
  local hole = toggle:CreateTexture(nil, "ARTWORK", nil, 1)
  disc(hole, 10)
  hole:SetPoint("CENTER")
  fillDisc(hole, "bg")
  local half = toggle:CreateTexture(nil, "ARTWORK", nil, 2)
  disc(half, 10)
  half:SetWidth(5)
  half:SetTexCoord(0, 0.5, 0, 1)
  half:SetPoint("RIGHT", hole, "CENTER")
  fillDisc(half, "railText")
  local glow = toggle:CreateTexture(nil, "HIGHLIGHT")
  glow:SetPoint("TOPLEFT", 1, -1)
  glow:SetPoint("BOTTOMRIGHT", -1, 1)
  UI.Fill(glow, "gold", 0.15)
  toggle:SetScript("OnClick", function(self)
    UI.SetTheme(UI.Theme() == "dark" and "light" or "dark")
    showThemeTip(self)
  end)
  toggle:SetScript("OnEnter", showThemeTip)
  toggle:SetScript("OnLeave", GameTooltip_Hide)
  return toggle
end

local function addTitleBar()
  local bar = UI.TitleBar(window, TITLE_HEIGHT)
  local rim = bar:CreateTexture(nil, "ARTWORK")
  disc(rim, 22)
  rim:SetPoint("LEFT", 14, 0)
  rim:SetVertexColor(0.66, 0.46, 0.1, 1)
  local coin = bar:CreateTexture(nil, "ARTWORK", nil, 1)
  disc(coin, 18)
  coin:SetPoint("CENTER", rim)
  setGradient(coin, "VERTICAL", 0.6, 0.4, 0.07, 1, 1, 0.94, 0.7, 1)

  local brand = label(bar, "brand", "brand")
  brand:SetPoint("LEFT", rim, "RIGHT", 12, 0)
  brand:SetText("Goldbook")
  window.version = label(bar, "label", "muted")
  window.version:SetPoint("BOTTOMLEFT", brand, "BOTTOMRIGHT", 12, 2)
  window.version:SetText(ns.VERSION)
  window.close = bar.close
  window.themeToggle = addThemeToggle(bar)

  -- The account's gold in a box sized to it.
  local purse = panel(bar, "field", "edge")
  window.purse = label(purse, "number", "text")
  window.purse:SetPoint("RIGHT", window.themeToggle, "LEFT", -21, 0)
  local caption = label(purse, "label", "muted")
  caption:SetPoint("RIGHT", window.purse, "LEFT", -8, 0)
  caption:SetText("ACCOUNT")
  purse:SetPoint("LEFT", caption, "LEFT", -11, 0)
  purse:SetPoint("RIGHT", window.purse, "RIGHT", 11, 0)
  purse:SetHeight(27)
end

local function createWindow()
  window = CreateFrame("Frame", "GoldbookWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
  -- Before the position, which counts in the scaled window's units.
  window:SetScale(UI.Scale())
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
  UI.Box(window, "bg", "edge")
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
    if window.menu then
      window.menu:Hide()
    end
  end)
  tinsert(UISpecialFrames, "GoldbookWindow")

  addTitleBar()
  addRail()
  addHead()
  addToolbar()
  addCards()
  addChart()
  addTable()

  window.status = label(window, "status", "muted")
  window.status:SetPoint("BOTTOMLEFT", PAGE_LEFT, PAGE_BOTTOM + 2)
  window.status:SetWidth(PAGE_WIDTH)
  window.status:SetJustifyH("LEFT")
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
  -- One item after another keeps the view the first came from.
  if not (window and window:IsShown()) then
    origin = nil
  elseif view ~= "item" then
    local sort = sorting[view]
    origin = { view = view, search = window.search:GetText(), filters = copy(filters), sort = sort and { unpack(sort) },
      segment = chosen[view], offset = offset }
  end
  UI.Show("item")
end

-- From the item view to where it was opened from, as it was left; to the
-- price list when it was opened with the window closed.
function UI.Back()
  local back = origin or { view = "prices" }
  origin = nil
  view = back.view
  if back.filters then
    filters = back.filters
    chipLabels()
  end
  sorting[view] = back.sort or sorting[view]
  chosen[view] = back.segment or chosen[view]
  if back.search and back.search ~= window.search:GetText() then
    window.search:SetText(back.search)
  else
    refresh()
  end
  offset = math.max(0, math.min(back.offset or 0, #results - visibleRows()))
  render()
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

-- Whatever shows the window's settings elsewhere, such as the Options panel,
-- hears of each change made from the window or a command.
local watchers = {}
function UI.Watch(watcher)
  watchers[#watchers + 1] = watcher
end

local function changed()
  for _, watcher in ipairs(watchers) do
    watcher()
  end
end

-- Repaints every Goldbook frame in the light or dark palette and keeps the
-- choice. Returns false for a theme it does not know.
function UI.SetTheme(name)
  if not PALETTES[name] then
    return false
  end
  ns.db.settings.theme = name
  palette = PALETTES[name]
  for _, apply in ipairs(painted) do
    apply()
  end
  UI.Refresh()
  changed()
  return true
end

function UI.Theme()
  return PALETTES[ns.db.settings.theme] and ns.db.settings.theme or DEFAULT_THEME
end

function UI.Scale()
  return ns.db.settings.scale or 1
end

-- Where the window's centre may go, in its own units at `scale`: wholly on
-- the screen, or, when it is larger than the screen, with its title bar on it.
local function onScreen(x, y, scale)
  local width, height = UIParent:GetWidth() / scale, UIParent:GetHeight() / scale
  local function within(at, size, room)
    return size >= room and room / 2 or math.max(size / 2, math.min(room - size / 2, at))
  end
  x = within(x, WINDOW_WIDTH, width)
  y = WINDOW_HEIGHT >= height and height - WINDOW_HEIGHT / 2 or within(y, WINDOW_HEIGHT, height)
  return x, y
end

-- Sizes the window, from MIN_SCALE to MAX_SCALE times, and keeps the choice.
-- Its centre stays where it was on the screen, moved only as far as keeps it
-- there. Returns false for a size out of range.
function UI.SetScale(scale)
  -- Rounded first: a slider hands back its ends as single floats, 0.7 as 0.69999998.
  scale = type(scale) == "number" and math.floor(scale * 100 + 0.5) / 100
  if not scale or scale < MIN_SCALE or scale > MAX_SCALE then
    return false
  end
  local old = UI.Scale()
  ns.db.settings.scale = scale
  local x, y
  if window then
    x, y = window:GetCenter()
    window:SetScale(scale)
  end
  if x then
    x, y = onScreen(x * old / scale, y * old / scale, scale)
    window:ClearAllPoints()
    window:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    ns.db.settings.window = { "CENTER", "BOTTOMLEFT", x, y }
  elseif ns.db.settings.window then
    -- A window not drawn yet opens where it was left, in the new size's units.
    local saved = ns.db.settings.window
    saved[3], saved[4] = saved[3] * old / scale, saved[4] * old / scale
  end
  changed()
  return true
end
UI.MIN_SCALE, UI.MAX_SCALE = MIN_SCALE, MAX_SCALE

local function createScanButton()
  scanButton = UI.Button(AuctionHouseFrame, "Goldbook scan", 150, 22, "GoldbookScanButton")
  scanButton:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -4, 2)
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
  scanButton.label:SetText(kind == "progress" and payload or "Goldbook scan")
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:SetScript("OnEvent", function()
  if not scanButton and AuctionHouseFrame then
    createScanButton()
  end
end)
