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
  "/gb movers lists the prices that rose and fell most since the day before.",
  "/gb gold shows your account: gold per character, gains, a 30 day chart and net worth.",
  "/gb show [text] opens the price list.",
  "/gb item <link or name>, or Alt+click any item, shows how its price moved day by day.",
  "/gb status shows what is priced and what is waiting for sync.",
  "/gb web shows the Goldbook site's address, and the ID and key to log in there.",
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

local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
open:SetSize(160, 22)
open:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -12)
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

panel:SetScript("OnShow", function()
  for _, definition in ipairs(CHECKS) do
    panel.checks[definition.name]:SetChecked(definition.get())
  end
end)

Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "Goldbook"))
