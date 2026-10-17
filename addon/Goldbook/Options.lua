local _, ns = ...

-- The entry under Options > AddOns. Clients without the Settings panel API
-- simply get no entry.
if not (Settings and Settings.RegisterCanvasLayoutCategory) then
  return
end

local HELP = {
  "Scans the auction house, shows prices in tooltips, and queues scans for cloud sync.",
  "",
  "Goldbook scan button at the auction house: left click for a quick scan, right click for a full scan.",
  "/gb scan and /gb scan full do the same from chat.",
  "/gb deals lists what is listed below its resale or vendor value.",
  "/gb sell says what to auction and what to vendor from your bags.",
  "/gb movers lists the prices that rose most since the day before, and under Fallers those that fell.",
  "/gb gold shows your account: gold per character, gains, net worth, a chart and this month's trades.",
  "/gb show [text] opens the price list.",
  "/gb item <link or name>, or Alt+click any item, shows how its price moved day by day.",
  "/gb status shows what is priced and what is waiting for sync.",
  "/gb web shows the Goldbook site's address, and the ID and key to log in there.",
  "/gb theme dark or /gb theme light draws the window in dark ink, the default, or on light parchment, as does the button by its close button.",
  "/gb scale 0.7 to /gb scale 1.4 sizes the window, apart from the game's UI scale; so does the slider below.",
  "",
  "Type /reload or log out after a scan so Goldbook can upload it.",
}

local panel = CreateFrame("Frame")
panel.checks = {}

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Goldbook " .. ns.VERSION)

local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
help:SetWidth(560)
help:SetJustifyH("LEFT")
help:SetText(table.concat(HELP, "\n"))

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
}

local anchor, offset = help, -16
for _, definition in ipairs(CHECKS) do
  local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  check:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == help and -2 or 0, offset)
  check:SetScript("OnClick", function(self)
    definition.set(self:GetChecked())
  end)
  local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("LEFT", check, "RIGHT", 4, 0)
  label:SetText(definition.label)
  panel.checks[definition.name] = check
  anchor, offset = check, -4
end

-- The window's size, apart from the game's own UI scale.
local scaleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
scaleLabel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -14)
local scale = CreateFrame("Slider", "GoldbookScaleSlider", panel, "OptionsSliderTemplate")
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

local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
open:SetSize(160, 22)
open:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", -6, -24)
open:SetText("Open Goldbook")
open:SetScript("OnClick", function()
  ns.UI.Show("prices", "")
end)

local webHeading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
webHeading:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -24)
webHeading:SetText("Web login")

local webHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
webHelp:SetPoint("TOPLEFT", webHeading, "BOTTOMLEFT", 0, -8)
webHelp:SetText("The Goldbook site's address, and your ID and key for its character pages.")

panel.webLogin = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
panel.webLogin:SetSize(160, 22)
panel.webLogin:SetPoint("TOPLEFT", webHelp, "BOTTOMLEFT", 0, -10)
panel.webLogin:SetText("Show ID and key")
panel.webLogin:SetScript("OnClick", function()
  ns.WebLogin.Show()
end)

local function showSettings()
  for _, definition in ipairs(CHECKS) do
    panel.checks[definition.name]:SetChecked(definition.get())
  end
  scale:SetValue(ns.UI.Scale())
  showScale(ns.UI.Scale())
end
panel:SetScript("OnShow", showSettings)
ns.UI.Watch(showSettings)

Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "Goldbook"))
