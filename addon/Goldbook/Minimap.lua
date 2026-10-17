local _, ns = ...
local Scanner = ns.Scanner

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local DEFAULT_ANGLE = math.rad(225)
local EDGE_OFFSET = 5

local button

local function activate(mouseButton)
  if mouseButton == "RightButton" then
    Scanner.Start("browse")
  else
    ns.UI.Toggle()
  end
end

-- The addon compartment calls this global by the name given in the .toc.
function Goldbook_OnAddonCompartmentClick(_, mouseButton)
  activate(mouseButton)
end

local function place()
  local angle = ns.db.settings.minimapAngle or DEFAULT_ANGLE
  local radius = Minimap:GetWidth() / 2 + EDGE_OFFSET
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function followCursor()
  local centerX, centerY = Minimap:GetCenter()
  local cursorX, cursorY = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  ns.db.settings.minimapAngle = math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)
  place()
end

local function showTooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Goldbook " .. ns.VERSION)
  GameTooltip:AddLine("Left click: price window.", 1, 1, 1)
  GameTooltip:AddLine("Right click: quick scan, at the auction house.", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button.", 1, 1, 1)
  GameTooltip:Show()
end

local function create()
  button = CreateFrame("Button", "GoldbookMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", 7, -5)

  local crest = ns.UI.Crest(button, 15)
  crest:SetPoint("CENTER", background)

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(_, mouseButton)
    activate(mouseButton)
  end)
  button:SetScript("OnDragStart", function()
    button:SetScript("OnUpdate", followCursor)
  end)
  button:SetScript("OnDragStop", function()
    button:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", showTooltip)
  button:SetScript("OnLeave", GameTooltip_Hide)
end

function MinimapButton.IsShown()
  return not ns.db.settings.hideMinimap
end

function MinimapButton.SetShown(shown)
  ns.db.settings.hideMinimap = not shown or nil
  button:SetShown(shown)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
  create()
  place()
  button:SetShown(MinimapButton.IsShown())
end)
