local _, ns = ...
local UI, House, Rules, Codec = ns.UI, ns.AuctionHouse, ns.AuctionRules, ns.Codec
local AuctionUI = {}
ns.AuctionUI = AuctionUI
local window, view, offset, selected, lastRows = nil, "browse", 0, nil, nil
local WIDTH, HEIGHT, ROWS, ROW_HEIGHT = 1020, 650, 15, 28
local refresh, editor
local TIME_LEFT = { "Short", "Medium", "Long", "Very long" }

local function label(parent, text, x, y, width, role, colour)
  local widget = UI.Label(parent, role or "body", colour or "text")
  widget:SetPoint("TOPLEFT", x, -y)
  widget:SetWidth(width)
  widget:SetJustifyH("LEFT")
  widget:SetText(text)
  return widget
end

local function button(parent, text, x, y, width, action)
  local widget = UI.Button(parent, text, width, 28)
  widget:SetPoint("TOPLEFT", x, -y)
  widget:SetScript("OnClick", action)
  return widget
end

local function field(parent, title, x, y, width, value)
  local caption = label(parent, title, x, y, width, "label", "muted")
  local box = CreateFrame("EditBox", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetPoint("TOPLEFT", x, -y - 18)
  box:SetSize(width, 28)
  UI.Box(box, "field", "line")
  box:SetFontObject(GoldbookFontBody)
  UI.Ink(box, "text")
  box:SetTextInsets(8, 8, 0, 0)
  box:SetAutoFocus(false)
  box:SetMaxLetters(2048)
  box:SetText(value or "")
  box:SetScript("OnEscapePressed", box.ClearFocus)
  box.caption = caption
  return box
end

local function showField(widget, shown)
  widget:SetShown(shown)
  widget.caption:SetShown(shown)
end

local function money(value)
  return Codec.Money(value or 0, UI.Palettes[UI.Theme()].coins)
end

local function resetSelection()
  selected, offset = nil, 0
  window.quantity:SetText("1")
  window.price:SetText("")
end

local function switch(mode)
  if Rules.running or House.Transacting() then return end
  House.Dismiss(true)
  view = mode
  resetSelection()
  if mode ~= "queue" then House.SetMode(mode) end
  refresh()
end

local function rows()
  if view == "queue" then return Rules.queue end
  if view == "browse" and House.context == "offers" then return House.offers end
  return House.rows
end

local function selectRow(row)
  if House.Busy() or Rules.running then return end
  selected = row
  if view == "queue" then
    refresh()
  elseif view == "browse" and House.context == "offers" then
    window.quantity:SetText(tostring(House.selected.commodity and 1 or row.quantity))
    refresh()
  else
    House.Select(row)
    if view == "sell" then
      window.quantity:SetText(tostring(row.commodity and row.quantity or 1))
      local key = Codec.ItemKey(row.itemKey.itemID, row.itemKey.itemSuffix)
      local record = ns.Database.Lookup(ns.db, ns.RealmKey(), key)
      window.price:SetText(record and record.min > 0 and ("%.4f"):format(record.min / 10000) or "")
    end
    refresh()
  end
end

local function reviewAction()
  if view == "queue" and selected then
    if selected.kind == "shop" then
      if Rules.Execute(selected) then view, selected, offset = "browse", nil, 0 end
    else Rules.Execute(selected) end
  elseif view == "browse" and selected then House.ReviewBuy(selected, tonumber(window.quantity:GetText()))
  elseif view == "sell" then House.ReviewPost(tonumber(window.quantity:GetText()), Rules.Price(window.price:GetText(), {}), window.duration.value)
  elseif view == "owned" then House.ReviewCancel() end
  refresh()
end

local function detail()
  local plan, item = House.Review(), House.selected
  local heading, body, action = "Select an item", "Search for items, choose a bag stack to sell, or review your auctions.", "Review"
  local quantity, pricing, actionable = false, false, false
  if view == "queue" then
    heading, body = "Action queue", Rules.message
    if selected then
      heading = selected.name
      body = "Group: " .. selected.rule .. "\n\n"
      if selected.done then body = body .. "Confirmed."
      elseif selected.kind == "skip" then body = body .. selected.reason
      elseif selected.kind == "post" then
        body = body .. "Post " .. selected.quantity .. " at " .. money(selected.unitPrice) .. " each.\n\n"
          .. "Buyout total: " .. money(selected.quantity * selected.unitPrice) .. "\nDuration: " .. ({ 12, 24, 48 })[selected.duration] .. " hours"
        actionable, action = true, "Review post"
      elseif selected.kind == "cancel" then
        body = body .. "A competitor is listed at " .. money(selected.competitor) .. " each.\n\nReview the cancellation fee before cancelling."
        actionable, action = true, "Review cancellation"
      else
        body = body .. selected.quantity .. " within " .. money(selected.ceiling) .. " each.\n\nOpen the current listings to choose what to buy."
        actionable, action = true, "Open listings"
      end
    end
  elseif item then
    heading = item.name
    if view == "sell" then
      quantity, pricing, actionable, action = true, true, true, "Review post"
      body = "Bag " .. item.bag .. ", slot " .. item.slot .. " · " .. item.quantity .. " available\n\n"
        .. "Set the price per item in gold. The review shows the total buyout and deposit.\n\n"
        .. (item.commodity and "The initial price is the last Goldbook minimum, when available."
          or "Ordinary items are posted one at a time. The initial price is Goldbook's last minimum.")
    elseif view == "owned" then
      actionable, action = true, "Review cancellation"
      body = item.quantity .. " items\nBuyout total: " .. money(item.total) .. "\nTime left: "
        .. (item.timeLeftSeconds and (math.ceil(item.timeLeftSeconds / 3600) .. " hours") or TIME_LEFT[item.timeLeft] or "Unknown")
        .. "\n\nCancelling loses the deposit. A bid may add a cancellation fee."
    elseif selected and selected.price and House.context == "offers" then
      quantity, actionable, action = item.commodity, not selected.owned, "Review purchase"
      body = money(selected.price) .. " per item\n" .. selected.quantity .. " in this listing\n\n"
        .. (selected.owned and "This listing belongs to you or your account." or (selected.owners ~= "" and "Seller: " .. selected.owners or "Seller names are unavailable."))
        .. "\n\n" .. (item.commodity and "The review requests a current quote for your quantity across the cheapest listings."
          or "You buy the whole listing for " .. money(selected.total) .. ".")
    else body = "Select a buyout listing on the left." end
  end
  window.detailTitle:SetText(heading)
  window.detailBody:SetText(body)
  showField(window.quantity, quantity and not plan)
  showField(window.price, pricing and not plan)
  window.duration:SetShown(pricing and not plan)
  window.durationLabel:SetShown(pricing and not plan)
  window.action.label:SetText(action)
  window.action:SetEnabled(actionable and House.open and not House.Busy() and not Rules.running)
  window.action:SetShown(not plan)
  window.history:SetShown(item ~= nil and view ~= "queue" and not plan)
  window.review:SetShown(plan ~= nil)
  if plan then
    local title, text, confirm = "Review purchase", "", "Buy now"
    if plan.kind == "post" then
      title, confirm = "Review post", "Post auction"
      text = plan.quantity .. " × " .. plan.name .. "\n\nUnit price: " .. money(plan.unitPrice)
        .. "\nBuyout total: " .. money(plan.total) .. "\nDeposit: " .. money(plan.deposit)
        .. "\nDuration: " .. ({ 12, 24, 48 })[plan.duration] .. " hours"
    elseif plan.kind == "cancel" then
      title, confirm = "Review cancellation", "Cancel auction"
      text = plan.quantity .. " × " .. plan.name .. "\n\nCancellation fee: " .. money(plan.total)
        .. "\n\nThe deposit is lost. Returned items arrive by mail."
    else
      text = plan.quantity .. " × " .. plan.name .. "\n\nTotal: " .. (plan.total and money(plan.total) or "Waiting for a quote...")
        .. "\n\n" .. (plan.kind == "commodity" and "Quotes expire after 10 seconds. Review again if the price changes." or "This buys the whole listing.")
    end
    window.review.title:SetText(title)
    window.review.body:SetText(text)
    window.review.confirm.label:SetText(confirm)
    window.review.confirm:SetEnabled(House.phase == "ready" and (plan.kind == "post" and plan.deposit or plan.total or math.huge) <= GetMoney())
    window.review.back:SetEnabled(not House.Transacting())
  end
end

refresh = function()
  if not window or not window:IsShown() then return end
  local listing = rows()
  if listing ~= lastRows then
    lastRows, selected, offset = listing, nil, 0
  end
  local busy = House.Busy() or Rules.running
  window.status:SetText(Rules.running and Rules.message or (view == "queue" and not House.Review() and Rules.message or House.message))
  window.balance:SetText("Available gold  " .. money(GetMoney()))
  for mode, tab in pairs(window.tabs) do
    tab:SetEnabled(not busy or (not Rules.running and not House.Transacting()))
    tab:SetAlpha(mode == view and 1 or 0.65)
  end
  window.search:SetShown(view == "browse")
  window.search.caption:SetShown(view == "browse")
  window.searchButton:SetShown(view == "browse")
  window.searchButton:SetEnabled(House.open and not busy)
  window.back:SetShown(view == "browse" and House.context == "offers")
  window.back:SetEnabled(not busy)
  window.refreshButton:SetShown(view == "sell" or view == "owned")
  window.refreshButton:SetEnabled(House.open and not busy)
  window.groupButton:SetEnabled(not busy)
  for _, scan in ipairs(window.scans) do scan:SetShown(view == "queue"); scan:SetEnabled(House.open and not busy) end
  window.stop:SetShown(Rules.running)
  window.more:SetShown(view == "browse" and House.more)
  window.more:SetEnabled(not busy)
  window.header:SetText(view == "queue" and "ITEM / GROUP" or "ITEM")
  window.priceHeader:SetText(view == "queue" and "ACTION / PRICE" or view == "sell" and "BAG" or "UNIT BUYOUT")
  offset = math.max(0, math.min(offset, math.max(0, #listing - ROWS)))
  for index, row in ipairs(window.rows) do
    local item = listing[index + offset]
    row:SetShown(item ~= nil)
    row.item = item
    if item then
      local text = item.name
      if view == "queue" then text = text .. " |cff" .. UI.Palettes[UI.Theme()].muted .. " / " .. item.rule .. "|r" end
      row.title:SetText(text)
      row.count:SetText(item.quantity or "")
      row.price:SetText(view == "queue" and (item.done and "Confirmed" or item.kind == "skip" and "Skipped" or item.kind == "cancel" and "Cancel" or money(item.unitPrice))
        or view == "sell" and (item.bag .. " / " .. item.slot) or (item.price and item.price > 0 and money(item.price) or "No buyout"))
      row.icon:SetTexture(item.icon or (item.item and item.item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.marker:SetShown(selected == item)
      row:SetEnabled(not busy)
    end
  end
  window.empty:SetShown(#listing == 0)
  window.empty:SetText(not House.open and "Open the auction house to get started."
    or Rules.running and "Reading current listings..."
    or view == "queue" and "Save your groups and rules, then run a scan."
    or view == "sell" and "No auctionable bag stacks."
    or view == "owned" and "No auctions to display."
    or "Search by item name to see live listings.")
  window.page:SetText(#listing == 0 and "0 items" or ((offset + 1) .. "–" .. math.min(#listing, offset + ROWS) .. " of " .. #listing))
  window.previous:SetEnabled(offset > 0)
  window.next:SetEnabled(offset + ROWS < #listing)
  detail()
end

local function createEditor()
  editor = CreateFrame("Frame", "GoldbookAuctionRules", window, BackdropTemplateMixin and "BackdropTemplate" or nil)
  editor:SetSize(740, 576)
  editor:SetPoint("CENTER")
  editor:SetFrameStrata("FULLSCREEN_DIALOG")
  editor:EnableMouse(true)
  UI.Box(editor, "bg", "edge")
  UI.TitleBar(editor, 42, "Groups and auction rules")
  tinsert(UISpecialFrames, "GoldbookAuctionRules")
  editor.fields = {}
  local definitions = {
    { "name", "Group name", 20, 58, 330, "" }, { "items", "Item IDs, separated by commas", 370, 58, 350, "" },
    { "minimum", "Minimum price", 20, 125, 220, "80% market" }, { "normal", "Normal price", 260, 125, 220, "100% market" },
    { "maximum", "Maximum price", 500, 125, 220, "150% market" }, { "shopping", "Shopping limit", 20, 192, 220, "70% market" },
    { "undercut", "Undercut, in copper", 260, 192, 220, "1" }, { "cap", "Post cap, total items", 500, 192, 220, "20" },
    { "stack", "Items per auction", 20, 259, 220, "1" },
  }
  for _, spec in ipairs(definitions) do editor.fields[spec[1]] = field(editor, spec[2], spec[3], spec[4], spec[5], spec[6]) end
  label(editor, "Duration", 260, 259, 220, "label", "muted")
  editor.duration = button(editor, "24 hours", 260, 277, 220, function(self)
    self.value = self.value % 3 + 1
    self.label:SetText(({ 12, 24, 48 })[self.value] .. " hours")
  end)
  editor.duration.value = 2
  editor.below = button(editor, "Below minimum: skip", 20, 330, 330, function(self)
    self.value = ({ skip = "minimum", minimum = "normal", normal = "skip" })[self.value]
    self.label:SetText("Below minimum: " .. self.value)
  end)
  editor.below.value = "skip"
  editor.above = button(editor, "Above maximum: normal", 370, 330, 350, function(self)
    self.value = self.value == "normal" and "maximum" or "normal"
    self.label:SetText("Above maximum: " .. self.value)
  end)
  editor.above.value = "normal"
  local help = label(editor, "Prices accept 12.50, 12g 50s, or 120% market, vendor or minbuyout.\nMarket uses Goldbook's market value or usual price. Missing sources skip the item.\nItem IDs include all variants. Each item belongs to one group. Post caps count your auctions.", 20, 380, 700, "small", "muted")
  help:SetWordWrap(true)
  help:SetHeight(62)
  editor.message = label(editor, "", 20, 454, 700, "small", "warn")
  editor.message:SetWordWrap(true)
  editor.message:SetHeight(36)
  button(editor, "Save group", 20, 518, 130, function()
    local input = {}
    for key, box in pairs(editor.fields) do input[key] = box:GetText(); box:ClearFocus() end
    input.below, input.above = editor.below.value, editor.above.value
    input.duration = editor.duration.value
    local ok, message = Rules.Save(input)
    editor.message:SetText(ok and "Group saved. Run a new scan to use these rules." or message)
    refresh()
  end)
  local loaded = 0
  button(editor, "Load next group", 170, 518, 170, function()
    local saved = Rules.Saved()
    if #saved == 0 then editor.message:SetText("No saved groups yet."); return end
    loaded = loaded % #saved + 1
    local rule = saved[loaded]
    for key, box in pairs(editor.fields) do box:SetText(key == "items" and table.concat(rule.items, ", ") or tostring(rule[key])) end
    editor.below.value, editor.above.value = rule.below, rule.above
    editor.duration.value = rule.duration
    editor.duration.label:SetText(({ 12, 24, 48 })[rule.duration] .. " hours")
    editor.below.label:SetText("Below minimum: " .. rule.below)
    editor.above.label:SetText("Above maximum: " .. rule.above)
    editor.message:SetText("Editing " .. rule.name .. ". Saving replaces this group by name.")
  end)
  editor.delete = button(editor, "Delete group", 360, 518, 150, function(self)
    local name = editor.fields.name:GetText()
    if self.pending ~= name then self.pending = name; self.label:SetText("Confirm delete"); return end
    Rules.Delete(name)
    self.pending = nil
    self.label:SetText("Delete group")
    editor.message:SetText("Deleted " .. name .. ".")
    refresh()
  end)
  button(editor, "Close", 580, 518, 140, function() editor:Hide() end)
end

local function createWindow()
  window = CreateFrame("Frame", "GoldbookAuctionHouse", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window:SetSize(WIDTH, HEIGHT)
  window:SetPoint("CENTER")
  window:SetScale(UI.Scale())
  window:SetClampedToScreen(true)
  window:SetFrameStrata("DIALOG")
  window:SetToplevel(true)
  window:EnableMouse(true)
  window:SetMovable(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetScript("OnHide", function()
    if Rules.running then Rules.Stop() end
    House.Dismiss()
    if editor then editor:Hide() end
  end)
  UI.Box(window, "bg", "edge")
  tinsert(UISpecialFrames, "GoldbookAuctionHouse")
  local title = UI.TitleBar(window, 46, "Goldbook  / Auction house")
  window.balance = label(title, "", 560, 16, 400, "number", "muted")
  window.balance:SetJustifyH("RIGHT")
  window.tabs = {}
  for index, tab in ipairs({ { "browse", "Browse" }, { "sell", "Sell" }, { "owned", "My auctions" }, { "queue", "Automation" } }) do
    window.tabs[tab[1]] = button(window, tab[2], 16 + (index - 1) * 140, 60, 130, function() switch(tab[1]) end)
  end
  window.groupButton = button(window, "Groups and rules", 688, 60, 190, function()
    if not editor then createEditor() end
    local item = view == "queue" and selected and selected.item or (view ~= "queue" and House.selected)
    if item and item.itemKey and editor.fields.items:GetText() == "" then
      editor.fields.items:SetText(tostring(item.itemKey.itemID))
    end
    editor:Show()
  end)
  button(window, "Theme", 888, 60, 116, function() UI.SetTheme(UI.Theme() == "dark" and "light" or "dark") end)
  window.search = field(window, "Search the auction house", 16, 103, 330, "")
  local function search()
    window.search:ClearFocus()
    resetSelection()
    House.Search(window.search:GetText())
  end
  window.search:SetScript("OnEnterPressed", search)
  window.searchButton = button(window, "Search", 356, 121, 108, search)
  window.back = button(window, "Back", 474, 121, 100, function() House.Search(window.search:GetText()) end)
  window.refreshButton = button(window, "Refresh", 16, 121, 140, function() House.SetMode(view) end)
  window.scans = {}
  for index, spec in ipairs({ { "post", "Posting scan" }, { "cancel", "Undercut scan" }, { "shop", "Shopping scan" } }) do
    window.scans[index] = button(window, spec[2], 16 + (index - 1) * 190, 121, 180, function()
      resetSelection()
      Rules.Start(spec[1])
      refresh()
    end)
  end
  window.stop = button(window, "Stop scan", 688, 121, 130, function() Rules.Stop(); refresh() end)
  local tableFrame = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
  tableFrame:SetPoint("TOPLEFT", 16, -166)
  tableFrame:SetSize(650, 448)
  UI.Box(tableFrame, "panel", "line")
  tableFrame:EnableMouseWheel(true)
  tableFrame:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta * 3; refresh() end)
  window.header = label(tableFrame, "ITEM", 12, 8, 360, "header", "muted")
  label(tableFrame, "QTY", 380, 8, 60, "header", "muted")
  window.priceHeader = label(tableFrame, "UNIT BUYOUT", 450, 8, 185, "header", "muted")
  window.priceHeader:SetJustifyH("RIGHT")
  window.rows = {}
  for index = 1, ROWS do
    local row = CreateFrame("Button", nil, tableFrame)
    row:SetPoint("TOPLEFT", 1, -27 - (index - 1) * ROW_HEIGHT)
    row:SetSize(648, ROW_HEIGHT)
    if index % 2 == 0 then
      local background = row:CreateTexture(nil, "BACKGROUND")
      background:SetAllPoints()
      UI.Fill(background, "rail")
    end
    row.marker = row:CreateTexture(nil, "BORDER")
    row.marker:SetAllPoints()
    UI.Fill(row.marker, "on")
    local hover = row:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    UI.Fill(hover, "gold", 0.1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("LEFT", 10, 0)
    row.icon:SetSize(20, 20)
    row.title = label(row, "", 38, 7, 330)
    row.count = label(row, "", 380, 6, 60, "number")
    row.price = label(row, "", 450, 6, 185, "number")
    row.price:SetJustifyH("RIGHT")
    row:SetScript("OnClick", function(self) selectRow(self.item) end)
    row:SetScript("OnEnter", function(self)
      local item = self.item
      if not item then return end
      local key = item.itemKey or (item.item and item.item.itemKey) or (House.selected and House.selected.itemKey)
      if key then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(item.link or ("item:" .. key.itemID))
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    window.rows[index] = row
  end
  window.empty = label(tableFrame, "", 40, 190, 570, "body", "muted")
  window.empty:SetJustifyH("CENTER")
  local side = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
  side:SetPoint("TOPLEFT", 680, -166)
  side:SetSize(324, 448)
  UI.Box(side, "panel", "line")
  window.detailTitle = label(side, "", 16, 18, 292, "heading", "gold")
  window.detailBody = label(side, "", 16, 54, 292)
  window.detailBody:SetWordWrap(true)
  window.detailBody:SetHeight(170)
  window.detailBody:SetJustifyV("TOP")
  window.quantity = field(side, "Quantity", 16, 236, 120, "1")
  window.price = field(side, "Unit price in gold", 152, 236, 156, "")
  window.durationLabel = label(side, "Duration", 16, 300, 120, "label", "muted")
  window.duration = button(side, "24 hours", 152, 294, 156, function(self)
    self.value = self.value % 3 + 1
    self.label:SetText(({ 12, 24, 48 })[self.value] .. " hours")
  end)
  window.duration.value = 2
  window.history = button(side, "Price history", 16, 350, 292, function()
    if House.selected then UI.ShowItem(Codec.ItemKey(House.selected.itemKey.itemID, House.selected.itemKey.itemSuffix)) end
  end)
  window.action = button(side, "Review", 16, 398, 292, reviewAction)
  window.review = CreateFrame("Frame", nil, side, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window.review:SetAllPoints()
  window.review:EnableMouse(true)
  UI.Box(window.review, "panel", "gold")
  window.review.title = label(window.review, "", 16, 18, 292, "heading", "gold")
  window.review.body = label(window.review, "", 16, 58, 292)
  window.review.body:SetWordWrap(true)
  window.review.body:SetHeight(300)
  window.review.body:SetJustifyV("TOP")
  window.review.back = button(window.review, "Back", 16, 398, 80, function() House.Dismiss(); refresh() end)
  window.review.confirm = button(window.review, "Confirm", 106, 398, 202, function() House.Confirm(); refresh() end)
  window.more = button(window, "Load more", 16, 616, 116, House.More)
  window.previous = button(window, "<", 142, 616, 30, function() offset = offset - ROWS; refresh() end)
  window.next = button(window, ">", 178, 616, 30, function() offset = offset + ROWS; refresh() end)
  window.page = label(window, "", 220, 623, 170, "small", "muted")
  window.status = label(window, "", 405, 622, 599, "status", "muted")
  window.status:SetJustifyH("RIGHT")
  window.status:SetWordWrap(true)
  window.status:SetHeight(26)
end

function AuctionUI.Show(text)
  if not window then createWindow() end
  window:Show()
  window:Raise()
  if text and text ~= "" and House.open and not Rules.running and not House.Busy() then
    view = "browse"
    window.search:SetText(text)
    House.Search(text)
  end
  refresh()
end

House.Subscribe(refresh)
Rules.Subscribe(refresh)
UI.Watch(function()
  if window then window:SetScale(UI.Scale()); refresh() end
end)
local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_CLOSED" then
    if window then window:Hide() end
  elseif AuctionHouseFrame and not GoldbookAuctionButton then
    local launch = UI.Button(AuctionHouseFrame, "Goldbook", 120, 22, "GoldbookAuctionButton")
    launch:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -160, 2)
    launch:SetScript("OnClick", function() AuctionUI.Show() end)
  end
end)
