local ADDON, ns = ...
local Codec, Database = ns.Codec, ns.Database

-- The address of the Goldbook web page, and the ID and key that log in to its
-- character pages.
local WebLogin = {}
ns.WebLogin = WebLogin

local WIDTH, HEIGHT = 330, 156
local LEFT = 14
local BOX_LEFT = 50
local BOX_WIDTH = WIDTH - BOX_LEFT - LEFT
local ROW = 26
local BUTTON_WIDTH, BUTTON_GAP = 110, 6
-- Characters per group as the codes are shown.
local GROUPS = { id = 4, key = 5 }
local LOGIN_TEXT = "Open the Goldbook site and log in under Characters."
local WARNING_TEXT = "Old web logins stop working after the next sync."
-- From the .toc, so that one line there points the addon at another server.
local WEBSITE = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "X-Website")

local dialog

local function grouped(field)
  return Codec.Grouped(ns.db.account[field], GROUPS[field])
end

local function setConfirming(confirming)
  dialog.message:SetText(confirming and WARNING_TEXT or LOGIN_TEXT)
  dialog.newKey:SetShown(not confirming)
  dialog.replace:SetShown(confirming)
  dialog.cancel:SetShown(confirming)
end

local function refresh()
  for box, text in pairs(dialog.boxes) do
    box:SetText(text())
  end
  setConfirming(false)
end

-- Chat text cannot be copied, so the address and each code sit in a box that
-- selects all of it for Ctrl+C and puts it back when typed over. `text` gives
-- what the box shows.
local function addCopyBox(label, y, text)
  local caption = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  caption:SetPoint("TOPLEFT", LEFT, y)
  caption:SetText(label)
  local box = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
  box:SetSize(BOX_WIDTH, 20)
  box:SetPoint("LEFT", caption, "LEFT", BOX_LEFT - LEFT, 0)
  box:SetAutoFocus(false)
  -- Both handlers get more than the box, which HighlightText would take for
  -- where the selection starts.
  local function selectAll(self)
    self:HighlightText()
  end
  box:SetScript("OnEditFocusGained", selectAll)
  box:SetScript("OnMouseUp", selectAll)
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput then
      self:SetText(text())
      self:HighlightText()
    end
  end)
  box:SetScript("OnEscapePressed", box.ClearFocus)
  box:SetScript("OnEnterPressed", box.ClearFocus)
  dialog.boxes[box] = text
  return box
end

local function addButton(text, x, onClick)
  local button = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
  button:SetSize(BUTTON_WIDTH, 22)
  button:SetPoint("BOTTOMLEFT", x, 12)
  button:SetText(text)
  button:SetScript("OnClick", onClick)
  return button
end

local function create()
  dialog = CreateFrame("Frame", "GoldbookWebLogin", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  dialog:SetSize(WIDTH, HEIGHT + (WEBSITE and ROW or 0))
  dialog:SetPoint("CENTER")
  dialog:SetFrameStrata("DIALOG")
  dialog:SetToplevel(true)
  dialog:SetBackdrop(ns.UI.BACKDROP)
  dialog:EnableMouse(true)
  dialog:Hide()
  tinsert(UISpecialFrames, "GoldbookWebLogin")

  local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", LEFT, -12)
  title:SetText("Web login")

  local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  dialog.boxes = {}
  local top = -44
  if WEBSITE then
    dialog.site = addCopyBox("Site", top, function()
      return WEBSITE
    end)
    top = top - ROW
  end
  dialog.id = addCopyBox("ID", top, function()
    return grouped("id")
  end)
  dialog.key = addCopyBox("Key", top - ROW, function()
    return grouped("key")
  end)

  dialog.message = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dialog.message:SetPoint("TOPLEFT", LEFT, top - 54)
  dialog.message:SetWidth(WIDTH - 2 * LEFT)
  dialog.message:SetJustifyH("LEFT")

  dialog.newKey = addButton("New key", LEFT, function()
    setConfirming(true)
  end)
  dialog.replace = addButton("Replace key", LEFT, function()
    Database.NewKey(ns.db)
    refresh()
    ns.Print("New web key made. Type /reload or log out so Goldbook uploads it; until then the web page takes the old key.")
  end)
  dialog.cancel = addButton("Cancel", LEFT + BUTTON_WIDTH + BUTTON_GAP, function()
    setConfirming(false)
  end)
end

function WebLogin.Show()
  if not dialog then
    create()
  end
  refresh()
  dialog:Show()
  dialog:Raise()
end
