local _, ns = ...

-- The entry under Options > AddOns. Clients without the Settings panel API
-- simply get no entry.
if not (Settings and Settings.RegisterCanvasLayoutCategory) then
  return
end

local INTRO = "Scans the auction house, shows prices in tooltips, and tells you what to buy, sell and vendor."

local ABOUT = {
  "The Goldbook desktop app syncs both ways. It uploads your scans, characters and accounting when you type /reload"
    .. " or log out, and brings the latest prices everyone scanned on your realm back into Goldbook, so tooltips,"
    .. " deals and movers are current without a scan of your own.",
  "It also keeps this addon up to date, in every game in your World of Warcraft folder.",
  "The Goldbook website shows the prices, deals and movers of every realm Goldbook players scan, and your"
    .. " characters' gold, bags and accounting, in any browser, also on your phone.",
  "Get the app from the website's Download page. /gb web shows the site's address.",
}

local HELP = {
  "Goldbook scan button at the auction house: left click for a quick scan, right click for a full scan.",
  "/gb scan and /gb scan full do the same from chat.",
  "/gb deals lists what is listed below its resale or vendor value.",
  "/gb bags says what to auction and what to vendor from your bags.",
  "/gb movers lists the prices that rose most since the day before, and under Fallers those that fell.",
  "/gb gold shows your account: gold per character, gains, net worth, a chart and this month's trades.",
  "/gb mail lists the open mailbox and collects the mails it shows; it opens by itself at a mailbox.",
  "/gb show [text] opens the price list.",
  "/gb item <link or name>, or Alt+click any item, shows how its price moved day by day.",
  "/gb status shows what is priced and what is waiting for sync.",
  "/gb web shows the Goldbook site's address, and the ID and key to log in there.",
  "/gb theme dark or /gb theme light draws the window in dark ink, the default, or on light parchment, as does the button by its close button.",
  "/gb scale 0.7 to /gb scale 1.4 sizes the window, apart from the game's UI scale; so does the slider above.",
  "",
  "Type /reload or log out after a scan so Goldbook can upload it.",
}

local WIDTH = 560

local panel = CreateFrame("Frame")
panel.checks = {}

-- The panel is shorter than its page, so the page scrolls.
local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 0, -4)
scroll:SetPoint("BOTTOMRIGHT", -28, 4)
local page = CreateFrame("Frame", nil, scroll)
page:SetSize(WIDTH + 32, 1)
scroll:SetScrollChild(page)
panel.page = page

local function heading(anchor, text, offset)
  local label = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offset or -24)
  label:SetText(text)
  return label
end

local function paragraph(anchor, text, offset)
  local label = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offset or -8)
  label:SetWidth(WIDTH)
  label:SetJustifyH("LEFT")
  label:SetText(text)
  return label
end

local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Goldbook " .. ns.VERSION)
local intro = paragraph(title, INTRO, -12)
local settings = heading(intro, "Settings")

local CHECKS = {
  {
    name = "minimap",
    label = "Show the minimap button",
    get = function()
      return ns.MinimapButton.IsShown()
    end,
    set = function(checked)
      ns.MinimapButton.SetShown(checked)
    end,
  },
  {
    name = "autoScan",
    label = "Quick scan when the auction house opens, at most every 15 minutes",
    get = function()
      return ns.db.settings.autoScan == true
    end,
    set = function(checked)
      ns.db.settings.autoScan = checked or nil
    end,
  },
  {
    name = "mailView",
    label = "Open the Mail view when a mailbox opens",
    get = function()
      return ns.db.settings.mailView ~= false
    end,
    set = function(checked)
      ns.db.settings.mailView = checked and true or false
    end,
  },
  {
    name = "light",
    label = "Draw the Goldbook window light, on parchment, instead of dark",
    get = function()
      return ns.UI.Theme() == "light"
    end,
    set = function(checked)
      ns.UI.SetTheme(checked and "light" or "dark")
    end,
  },
  {
    name = "altClick",
    label = "Alt+click an item to show its price history",
    get = function()
      return ns.db.settings.altClick ~= false
    end,
    set = function(checked)
      ns.db.settings.altClick = checked and true or false
    end,
  },
  {
    name = "shiftClick",
    label = "Shift+click an item at the auction house to open its history in Goldbook",
    get = function()
      return ns.db.settings.shiftClick ~= false
    end,
    set = function(checked)
      ns.db.settings.shiftClick = checked and true or false
    end,
  },
}

local anchor, offset = settings, -6
for _, definition in ipairs(CHECKS) do
  local check = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
  check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == settings and -2 or 0, offset)
  check:SetScript("OnClick", function(self)
    definition.set(self:GetChecked())
  end)
  local label = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("LEFT", check, "RIGHT", 4, 0)
  label:SetText(definition.label)
  panel.checks[definition.name] = check
  anchor, offset = check, -4
end

-- The window's size, apart from the game's own UI scale.
local scaleLabel = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
scaleLabel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -14)
local scale = CreateFrame("Slider", "GoldbookScaleSlider", page, "OptionsSliderTemplate")
scale:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 4, -10)
scale:SetWidth(220)
scale:SetMinMaxValues(ns.UI.MIN_SCALE, ns.UI.MAX_SCALE)
scale:SetValueStep(0.05)
scale:SetObeyStepOnDrag(true)
-- The template's end labels, by global name in older clients and as fields in newer ones.
for _, part in ipairs({ { "Low", ns.UI.MIN_SCALE }, { "High", ns.UI.MAX_SCALE }, { "Text" } }) do
  local text = _G["GoldbookScaleSlider" .. part[1]] or scale[part[1]]
  if type(text) == "table" then
    text:SetText(part[2] and ("%d%%"):format(part[2] * 100) or "")
  end
end
local function showScale(value)
  scaleLabel:SetText(("Window size: %d%%, apart from the game's UI scale"):format(math.floor(value * 100 + 0.5)))
end
scale:SetScript("OnValueChanged", function(_, value, userInput)
  if userInput then
    ns.UI.SetScale(value)
  end
  showScale(value)
end)
panel.scale = scale

local open = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
open:SetSize(160, 22)
open:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", -6, -24)
open:SetText("Open Goldbook")
open:SetScript("OnClick", function()
  ns.UI.Show("prices", "")
end)

panel.about = paragraph(heading(open, "Website and desktop app"), table.concat(ABOUT, "\n\n"))

local webHelp = paragraph(heading(panel.about, "Web login"),
  "The Goldbook site's address, and your ID and key for its character pages.")

panel.webLogin = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
panel.webLogin:SetSize(160, 22)
panel.webLogin:SetPoint("TOPLEFT", webHelp, "BOTTOMLEFT", 0, -10)
panel.webLogin:SetText("Show ID and key")
panel.webLogin:SetScript("OnClick", function()
  ns.WebLogin.Show()
end)

local help = paragraph(heading(panel.webLogin, "Commands"), table.concat(HELP, "\n"))

-- The page is as tall as what it holds, once the client has laid out its text.
local function fit()
  local top, bottom = page:GetTop(), help:GetBottom()
  if top and bottom then
    page:SetHeight(top - bottom + 16)
  end
end
scroll:SetScript("OnSizeChanged", function(_, width)
  page:SetWidth(width)
  fit()
end)

local function showSettings()
  for _, definition in ipairs(CHECKS) do
    panel.checks[definition.name]:SetChecked(definition.get())
  end
  scale:SetValue(ns.UI.Scale())
  showScale(ns.UI.Scale())
  fit()
end
panel:SetScript("OnShow", showSettings)
ns.UI.Watch(showSettings)

Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "Goldbook"))
