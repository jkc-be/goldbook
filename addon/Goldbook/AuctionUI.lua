local _, ns = ...
local UI, House, Rules, Codec = ns.UI, ns.AuctionHouse, ns.AuctionRules, ns.Codec
local Scanner, ItemFilters = ns.Scanner, ns.ItemFilters
local AuctionUI = {}
ns.AuctionUI = AuctionUI
local window, view, offset, selected, lastRows = nil, "browse", 0, nil, nil
local WIDTH, HEIGHT, ROW_HEIGHT = 1020, 690, 28
local MIN_WIDTH, MIN_HEIGHT = 940, 670
local visibleRows = 15
local DURATIONS = { 2, 8, 24 }
local refresh, editor
local TIME_LEFT = { "Short", "Medium", "Long", "Very long" }
local hiddenBlizzard
local filters, dealRows, variantItemID, scanMessage = ItemFilters.New(), {}, nil, nil

local function updateDeals()
  dealRows = ns.Advisor.Deals(ns.db, ns.RealmKey(), ns.MinProfit())
  for _, row in ipairs(dealRows) do
    local lookup = C_Item.GetItemIconByID or GetItemIcon
    row.icon = lookup and lookup(Codec.BaseID(row.key))
    row.quantity = row.units or 1
  end
end

local function restoreBlizzard()
  if not hiddenBlizzard then return end
  local saved = hiddenBlizzard
  hiddenBlizzard = nil
  saved.frame:SetScale(saved.scale)
  saved.frame:SetAlpha(saved.alpha)
  saved.frame:EnableMouse(saved.mouse)
end

local function syncBlizzard()
  if not (House.open and window and window:IsShown() and ns.db.settings.hideBlizzardAH ~= false) then
    restoreBlizzard()
  elseif not hiddenBlizzard and AuctionHouseFrame then
    local frame = AuctionHouseFrame
    hiddenBlizzard = { frame = frame, scale = frame:GetScale(), alpha = frame:GetAlpha(), mouse = frame:IsMouseEnabled() }
    -- Hiding this frame runs Blizzard's OnHide and closes the auction session.
    -- Keep it shown at a tiny scale, as TSM does, with no visible pixels.
    frame:SetScale(0.001)
    frame:SetAlpha(0)
    frame:EnableMouse(false)
  end
end

function AuctionUI.SetHideBlizzard(hidden)
  ns.db.settings.hideBlizzardAH = hidden and true or false
  syncBlizzard()
  if window then refresh() end
end

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
  selected, offset, scanMessage = nil, 0, nil
  window.quantity:SetText("1")
  window.price:SetText("")
end

local function switch(mode)
  if Rules.running or House.Transacting() or Scanner.state ~= "idle" then return end
  House.Dismiss(true)
  view, variantItemID = mode, nil
  resetSelection()
  if window.filterMenu then window.filterMenu:Hide() end
  if window.categoryMenus then window.categoryMenus[1]:Hide() end
  if mode == "deals" then updateDeals(); House.SetMode("browse")
  elseif mode == "browse" then House.Search(window.search:GetText())
  elseif mode ~= "queue" then House.SetMode(mode) end
  refresh()
end

local function sourceRows()
  if view == "queue" then return Rules.queue end
  if view == "deals" then return dealRows end
  if view == "browse" and House.context == "offers" then return House.offers end
  return House.rows
end

local function rows(source)
  if view == "queue" or (view == "browse" and House.context ~= "browse") then return source end
  local listing, grouped = {}, {}
  local needle = window.search:GetText():lower()
  for _, item in ipairs(source) do
    local key = item.key or Codec.ItemKey(item.itemKey.itemID, item.itemKey.itemSuffix)
    if ItemFilters.Matches(key, item.quality, filters)
      and (view ~= "deals" or item.name:lower():find(needle, 1, true))
      and (not variantItemID or item.itemKey.itemID == variantItemID) then
      if view == "browse" and not variantItemID and ns.db.settings.groupAuctionVariants then
        local id = item.itemKey.itemID
        local group = grouped[id]
        if not group then
          group = { name = C_Item.GetItemInfo(id) or item.name, icon = item.icon, itemKey = { itemID = id },
            quantity = 0, price = item.price, variants = {} }
          grouped[id], listing[#listing + 1] = group, group
        end
        group.variants[#group.variants + 1] = item
        group.quantity, group.price = group.quantity + item.quantity, math.min(group.price, item.price)
      else listing[#listing + 1] = item end
    end
  end
  for index, item in ipairs(listing) do
    if item.variants and #item.variants == 1 then listing[index] = item.variants[1] end
  end
  return listing
end

local function selectRow(row)
  if House.Busy() or Rules.running or Scanner.state ~= "idle" then return end
  if row.variants then
    variantItemID = row.itemKey.itemID
    resetSelection()
    refresh()
    return
  end
  selected = row
  if view == "queue" or view == "deals" then
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
  if view == "deals" and selected then
    local item = House.CachedItem(selected)
    local name = item.name
    view, variantItemID = "browse", nil
    resetSelection()
    window.search:SetText(name)
    House.text = name
    House.Find(item)
  elseif view == "queue" and selected then
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
  local heading, body, action = "Scan prices", "Browse your saved scan prices immediately. Open an item to fetch its current listings.\n\nRun at least a Quick scan to refresh this reference.", "Review"
  local quantity, pricing, actionable = false, false, false
  if view == "deals" then
    heading, body = "Deals", "Quick scan finds current low prices. Full scan also records market values and order books.\n\nSelect a deal to see its estimated return."
    if selected then
      heading = selected.name
      body = "Buy from " .. money(selected.min) .. " each.\nSell for " .. money(selected.sell)
        .. (selected.kind == "vendor" and " to a vendor." or " at auction.")
        .. "\n\nEstimated profit: " .. money(selected.total)
        .. "\nSeen " .. Codec.Age(time() - selected.seen)
        .. "\n\nCheck live listings before buying. Auction resale prices can change."
      actionable, action = true, "Find live listings"
    end
  elseif view == "queue" then
    heading, body = "Action queue", Rules.message
    if selected then
      heading = selected.name
      body = "Group: " .. selected.rule .. "\n\n"
      if selected.done then body = body .. "Confirmed."
      elseif selected.kind == "skip" then body = body .. selected.reason
      elseif selected.kind == "post" then
        body = body .. "Post " .. selected.quantity .. " at " .. money(selected.unitPrice) .. " each.\n\n"
          .. "Buyout total: " .. money(selected.quantity * selected.unitPrice) .. "\nDuration: " .. DURATIONS[selected.duration] .. " hours"
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
  window.detailBody:SetHeight(view == "deals" and 250 or 170)
  showField(window.quantity, quantity and not plan)
  showField(window.price, pricing and not plan)
  window.duration:SetShown(pricing and not plan)
  window.durationLabel:SetShown(pricing and not plan)
  window.action.label:SetText(action)
  window.action:SetEnabled(actionable and House.open and not House.Busy() and not Rules.running and Scanner.state == "idle")
  window.action:SetShown(not plan)
  window.history:SetShown((view == "deals" and selected ~= nil or view ~= "deals" and item ~= nil) and view ~= "queue" and not plan)
  window.review:SetShown(plan ~= nil)
  if plan then
    local title, text, confirm = "Review purchase", "", "Buy now"
    if plan.kind == "post" then
      title, confirm = "Review post", "Post auction"
      text = plan.quantity .. " × " .. plan.name .. "\n\nUnit price: " .. money(plan.unitPrice)
        .. "\nBuyout total: " .. money(plan.total) .. "\nDeposit: " .. money(plan.deposit)
        .. "\nDuration: " .. DURATIONS[plan.duration] .. " hours"
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
  syncBlizzard()
  local source = sourceRows()
  if source ~= lastRows then
    lastRows, selected, offset = source, nil, 0
  end
  local listing = rows(source)
  local scanning = Scanner.state ~= "idle"
  local busy = House.Busy() or Rules.running or scanning
  window.status:SetText(scanMessage or (Rules.running and Rules.message or (view == "queue" and not House.Review() and Rules.message
    or view == "deals" and "Deals from your latest scan. Verify live prices before buying." or House.message)))
  window.balance:SetText("Available gold  " .. money(GetMoney()))
  for mode, tab in pairs(window.tabs) do
    tab:SetEnabled(not scanning and (not busy or (not Rules.running and not House.Transacting())))
    tab:SetAlpha(mode == view and 1 or 0.65)
  end
  window.search:SetShown(view == "browse" or view == "deals")
  window.search.caption:SetShown(view == "browse" or view == "deals")
  window.search.caption:SetText(view == "deals" and "Search deals" or "Search scan prices")
  local scanned = ns.db.scanned[ns.RealmKey()]
  window.scanTime:SetShown(view == "browse" or view == "deals")
  window.scanTime:SetText((scanned and ("Last scan: " .. date("%d %b %H:%M", scanned) .. " (" .. Codec.Age(time() - scanned) .. ")")
    or "Last scan: never") .. "\nRun at least a Quick scan for a fresh reference.")
  window.searchButton:SetShown(view == "browse")
  window.searchButton:SetEnabled(House.open and not busy)
  window.back:SetShown(view == "browse" and (House.context ~= "browse" or variantItemID ~= nil))
  window.back:SetEnabled(not busy)
  window.refreshButton:SetShown(view == "sell" or view == "owned")
  window.refreshButton:SetEnabled(House.open and not busy)
  window.groupButton:SetEnabled(not busy)
  window.groupButton:SetShown(view == "queue")
  for _, scan in ipairs(window.scans) do scan:SetShown(view == "queue"); scan:SetEnabled(House.open and not busy) end
  window.stop:SetShown(Rules.running)
  window.quickScan:SetEnabled(House.open and not busy)
  window.fullScan:SetEnabled(House.open and not busy)
  local filtering = view ~= "queue" and not (view == "browse" and House.context ~= "browse")
  window.filters:SetShown(filtering)
  for name, control in pairs(window.filters.controls) do
    control:SetEnabled(not busy)
    for _, option in ipairs(ItemFilters.Options[name]()) do
      if option[1] == filters[name] then control.label:SetText(option[2] .. "  v") end
    end
  end
  window.filters.category:SetEnabled(not busy)
  window.filters.category.label:SetText((filters.category and filters.category.name or "All categories") .. "  v")
  window.filters.clear:SetEnabled(not busy)
  window.stack:SetShown(view == "browse" and filtering)
  window.stack:SetEnabled(not busy)
  window.stack.selected:SetShown(ns.db.settings.groupAuctionVariants == true)
  if busy and window.filterMenu then window.filterMenu:Hide() end
  if busy and window.categoryMenus then window.categoryMenus[1]:Hide() end
  window.more:SetShown(view == "browse" and House.more)
  window.more:SetEnabled(not busy)
  window.header:SetText(view == "queue" and "ITEM / GROUP" or "ITEM")
  window.priceHeader:SetText(view == "queue" and "ACTION / PRICE" or view == "deals" and "EST. PROFIT" or view == "sell" and "BAG" or view == "browse" and House.context == "browse" and "SCAN UNIT PRICE" or "UNIT BUYOUT")
  offset = math.max(0, math.min(offset, math.max(0, #listing - visibleRows)))
  for index, row in ipairs(window.rows) do
    local item = index <= visibleRows and listing[index + offset] or nil
    row:SetShown(item ~= nil)
    row.item = item
    if item then
      local text = item.name
      if item.variants then text = text .. " (" .. #item.variants .. " variants)" end
      if view == "browse" and House.context == "variants" and (item.itemKey.itemLevel or 0) > 0 then
        text = text .. " (item level " .. item.itemKey.itemLevel .. ")"
      end
      if view == "queue" then text = text .. " |cff" .. UI.Palettes[UI.Theme()].muted .. " / " .. item.rule .. "|r" end
      row.title:SetText(text)
      row.count:SetText(item.quantity or "")
      row.price:SetText(view == "queue" and (item.done and "Confirmed" or item.kind == "skip" and "Skipped" or item.kind == "cancel" and "Cancel" or money(item.unitPrice))
        or view == "deals" and money(item.total) or view == "sell" and (item.bag .. " / " .. item.slot) or (item.price and item.price > 0 and money(item.price) or "No buyout"))
      row.icon:SetTexture(item.icon or (item.item and item.item.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.marker:SetShown(selected == item)
      row:SetEnabled(not busy)
    end
  end
  window.empty:SetShown(#listing == 0)
  window.empty:SetText(not House.open and "Open the auction house to get started."
    or Rules.running and "Reading current listings..."
    or view == "queue" and "Save your groups and rules, then run a scan."
    or view == "deals" and "No matching deals. Run a scan to update prices."
    or view == "sell" and "No auctionable bag stacks."
    or view == "owned" and "No auctions to display."
    or view == "browse" and House.context ~= "browse" and "No current listings. Try another item or refresh your scan."
    or not ns.db.scanned[ns.RealmKey()] and "No scan yet. Run at least a Quick scan to see reference prices."
    or "No matching scan prices. Clear filters or run a Quick scan.")
  window.page:SetText(#listing == 0 and "0 items" or ((offset + 1) .. "–" .. math.min(#listing, offset + visibleRows) .. " of " .. #listing))
  window.previous:SetEnabled(offset > 0)
  window.next:SetEnabled(offset + visibleRows < #listing)
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
  editor.duration = button(editor, "8 hours", 260, 277, 220, function(self)
    self.value = self.value % 3 + 1
    self.label:SetText(DURATIONS[self.value] .. " hours")
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
    editor.duration.label:SetText(DURATIONS[rule.duration] .. " hours")
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

local function addRow(tableFrame, index)
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
    if key or item.key then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(item.link or (item.key and Codec.ItemString(item.key)) or ("item:" .. key.itemID))
      if item.cached and item.seen then GameTooltip:AddLine("Scan price seen " .. Codec.Age(time() - item.seen), 0.7, 0.7, 0.7) end
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", GameTooltip_Hide)
  window.rows[index] = row
end

local function layout()
  local width, height = window:GetWidth(), window:GetHeight()
  local tableWidth, tableHeight = width - 370, height - 242
  visibleRows = math.max(1, math.floor((tableHeight - 28) / ROW_HEIGHT))
  window.tableFrame:SetSize(tableWidth, tableHeight)
  window.side:SetPoint("TOPLEFT", width - 340, -206)
  window.side:SetSize(324, tableHeight)
  window.header:SetWidth(tableWidth - 290)
  window.quantityHeader:SetPoint("TOPLEFT", tableWidth - 270, -8)
  window.priceHeader:SetPoint("TOPLEFT", tableWidth - 200, -8)
  for index = #window.rows + 1, visibleRows do addRow(window.tableFrame, index) end
  for _, row in ipairs(window.rows) do
    row:SetSize(tableWidth - 2, ROW_HEIGHT)
    row.title:SetWidth(tableWidth - 320)
    row.count:SetPoint("TOPLEFT", tableWidth - 270, -6)
    row.price:SetPoint("TOPLEFT", tableWidth - 200, -6)
  end
  window.empty:SetWidth(tableWidth - 80)
  window.empty:SetPoint("TOPLEFT", 40, -math.floor(tableHeight / 2))
  window.groupButton:SetPoint("TOPLEFT", width - 206, -121)
  window.quickScan:SetPoint("TOPLEFT", width - 252, -60)
  window.fullScan:SetPoint("TOPLEFT", width - 130, -60)
  window.stop:SetPoint("TOPLEFT", width - 346, -121)
  window.stack:SetPoint("TOPLEFT", width - 44, -164)
  window.scanTime:SetWidth(width - 606)
  window.balance:ClearAllPoints()
  window.balance:SetPoint("TOPRIGHT", -59, -16)
  window.history:SetPoint("TOPLEFT", 16, -(tableHeight - 98))
  window.action:SetPoint("TOPLEFT", 16, -(tableHeight - 50))
  window.review.body:SetHeight(tableHeight - 120)
  window.review.back:SetPoint("TOPLEFT", 16, -(tableHeight - 50))
  window.review.confirm:SetPoint("TOPLEFT", 106, -(tableHeight - 50))
  window.more:SetPoint("TOPLEFT", 16, -(height - 34))
  window.previous:SetPoint("TOPLEFT", 142, -(height - 34))
  window.next:SetPoint("TOPLEFT", 178, -(height - 34))
  window.page:SetPoint("TOPLEFT", 220, -(height - 27))
  window.status:SetPoint("TOPLEFT", 405, -(height - 28))
  window.status:SetWidth(width - 437)
end

local function fitSize()
  local maxWidth = math.max(MIN_WIDTH, UIParent:GetWidth() / UI.Scale())
  local maxHeight = math.max(MIN_HEIGHT, UIParent:GetHeight() / UI.Scale())
  if window.SetResizeBounds then
    window:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, maxWidth, maxHeight)
  else
    window:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
    window:SetMaxResize(maxWidth, maxHeight)
  end
  local saved = ns.db.settings.auctionSize or {}
  window:SetSize(math.max(MIN_WIDTH, math.min(maxWidth, tonumber(saved[1]) or WIDTH)),
    math.max(MIN_HEIGHT, math.min(maxHeight, tonumber(saved[2]) or HEIGHT)))
end

local function addResizeGrip()
  local grip = CreateFrame("Button", nil, window)
  grip:SetSize(18, 18)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  for _, inset in ipairs({ 3, 7, 11 }) do
    for _, style in ipairs({ { "ARTWORK", "muted" }, { "HIGHLIGHT", "gold" } }) do
      local line = grip:CreateLine(nil, style[1])
      line:SetThickness(1.5)
      line:SetStartPoint("BOTTOMRIGHT", grip, -inset, 2)
      line:SetEndPoint("BOTTOMRIGHT", grip, -2, inset)
      UI.Fill(line, style[2])
    end
  end
  grip:SetScript("OnMouseDown", function(_, mouseButton)
    if mouseButton == "LeftButton" then window:StartSizing("BOTTOMRIGHT") end
  end)
  grip:SetScript("OnMouseUp", function()
    window:StopMovingOrSizing()
    ns.db.settings.auctionSize = { math.floor(window:GetWidth() + 0.5), math.floor(window:GetHeight() + 0.5) }
  end)
  grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Drag to resize")
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", GameTooltip_Hide)
  window.resizeGrip = grip
end

local function openFilter(control, name)
  if window.categoryMenus then window.categoryMenus[1]:Hide() end
  if not window.filterMenu then
    local menu = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
    menu:SetFrameStrata("TOOLTIP")
    menu:EnableMouse(true)
    UI.Box(menu, "panel", "edge")
    menu.options = {}
    menu:Hide()
    window.filterMenu = menu
  end
  local menu = window.filterMenu
  if menu.owner == control and menu:IsShown() then menu:Hide(); return end
  menu.owner = control
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", control, "BOTTOMLEFT", 0, -2)
  local options = ItemFilters.Options[name]()
  local columns = math.ceil(#options / 10)
  local count = math.ceil(#options / columns)
  menu:SetSize(columns * 210, count * 26 + 8)
  for index = 1, math.max(#options, #menu.options) do
    local choice = menu.options[index]
    if not choice then
      choice = button(menu, "", 0, 0, 208, function() end)
      choice:SetHeight(24)
      menu.options[index] = choice
    end
    local option = options[index]
    choice:SetShown(option ~= nil)
    if option then
      choice:SetPoint("TOPLEFT", 1 + math.floor((index - 1) / count) * 210, -4 - (index - 1) % count * 26)
      choice.label:SetText(option[2])
      choice:SetScript("OnClick", function()
        ItemFilters.Select(filters, name, option[1])
        variantItemID, House.selected = nil, nil
        resetSelection()
        menu:Hide()
        refresh()
      end)
    end
  end
  menu:Show()
end

local function openCategories(control)
  if window.filterMenu then window.filterMenu:Hide() end
  local menus = window.categoryMenus or {}
  window.categoryMenus = menus
  if menus[1] and menus[1]:IsShown() then menus[1]:Hide(); return end
  local showMenu
  local function choose(category)
    filters.category, variantItemID, House.selected = category, nil, nil
    menus[1]:Hide()
    resetSelection()
    refresh()
  end
  showMenu = function(depth, category, anchor)
    local menu = menus[depth]
    if not menu then
      menu = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
      menu:SetFrameStrata("TOOLTIP")
      menu:SetFrameLevel(window:GetFrameLevel() + depth * 10)
      menu:EnableMouse(true)
      UI.Box(menu, "panel", "edge")
      menu.options = {}
      menu:SetScript("OnHide", function() if menus[depth + 1] then menus[depth + 1]:Hide() end end)
      menus[depth] = menu
    end
    if menus[depth + 1] then menus[depth + 1]:Hide() end
    menu:ClearAllPoints()
    if depth == 1 then menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    elseif anchor:GetRight() + 220 > UIParent:GetWidth() / window:GetScale() then
      menu:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 0)
    else menu:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0) end
    local entries = { { name = category and ("All " .. category.name) or "All categories", category = category } }
    for _, child in ipairs(category and category.subCategories or AuctionCategories or {}) do
      if not (child.flags and child.flags.WOW_TOKEN_FLAG) then
        entries[#entries + 1] = { name = child.name, category = child, children = child.subCategories }
      end
    end
    menu:SetSize(220, #entries * 26 + 8)
    for index = 1, math.max(#entries, #menu.options) do
      local choice = menu.options[index]
      if not choice then
        choice = button(menu, "", 2, 4 + (index - 1) * 26, 216, function() end)
        choice:SetHeight(24)
        menu.options[index] = choice
      end
      local entry = entries[index]
      choice:SetShown(entry ~= nil)
      if entry then
        choice.label:SetText(entry.name .. (entry.children and "  >" or ""))
        choice:SetScript("OnEnter", function()
          if entry.children then showMenu(depth + 1, entry.category, menu)
          elseif menus[depth + 1] then menus[depth + 1]:Hide() end
        end)
        choice:SetScript("OnClick", function()
          if entry.children then showMenu(depth + 1, entry.category, menu) else choose(entry.category) end
        end)
      end
    end
    menu:Show()
  end
  showMenu(1, nil, control)
end

local function addFilters()
  window.filters = CreateFrame("Frame", nil, window)
  window.filters:SetPoint("TOPLEFT", 16, -164)
  window.filters:SetSize(832, 28)
  window.filters.controls = {}
  for _, spec in ipairs({ { "profession", 0, 160 }, { "kind", 168, 180 }, { "quality", 356, 130 } }) do
    window.filters.controls[spec[1]] = button(window.filters, "", spec[2], 0, spec[3], function(self) openFilter(self, spec[1]) end)
  end
  window.filters.category = button(window.filters, "All categories", 494, 0, 210, openCategories)
  window.filters.clear = button(window.filters, "Clear filters", 712, 0, 120, function()
    filters, variantItemID, House.selected = ItemFilters.New(), nil, nil
    resetSelection()
    if window.filterMenu then window.filterMenu:Hide() end
    if window.categoryMenus then window.categoryMenus[1]:Hide() end
    refresh()
  end)
  local stack = button(window, "", 976, 164, 28, function()
    ns.db.settings.groupAuctionVariants = not ns.db.settings.groupAuctionVariants
    variantItemID = nil
    resetSelection()
    refresh()
  end)
  for index = 1, 3 do
    local sheet = CreateFrame("Frame", nil, stack, BackdropTemplateMixin and "BackdropTemplate" or nil)
    sheet:SetPoint("TOPLEFT", 12 - index * 2, -3 - index * 2)
    sheet:SetSize(12, 14)
    UI.Box(sheet, "field", "gold")
  end
  stack.selected = stack:CreateTexture(nil, "OVERLAY")
  stack.selected:SetPoint("BOTTOMLEFT", 2, 2)
  stack.selected:SetPoint("BOTTOMRIGHT", -2, 2)
  stack.selected:SetHeight(2)
  UI.Fill(stack.selected, "gold")
  stack:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Group item variants")
    GameTooltip:AddLine("Expand a stack to choose the exact suffix or item level.", 1, 1, 1)
    GameTooltip:Show()
  end)
  stack:SetScript("OnLeave", GameTooltip_Hide)
  window.stack = stack
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
  window:SetResizable(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetScript("OnHide", function()
    window:StopMovingOrSizing()
    restoreBlizzard()
    if Rules.running then Rules.Stop() end
    House.Dismiss()
    if editor then editor:Hide() end
    if window.filterMenu then window.filterMenu:Hide() end
    if window.categoryMenus then window.categoryMenus[1]:Hide() end
    if House.open then
      if AuctionHouseFrame and AuctionHouseFrame:IsShown() then HideUIPanel(AuctionHouseFrame)
      else C_AuctionHouse.CloseAuctionHouse() end
    end
  end)
  UI.Box(window, "bg", "edge")
  tinsert(UISpecialFrames, "GoldbookAuctionHouse")
  local title = UI.TitleBar(window, 46, "Goldbook  / Auction house")
  window.balance = label(title, "", 560, 16, 400, "number", "muted")
  window.balance:SetJustifyH("RIGHT")
  window.tabs = {}
  for index, tab in ipairs({ { "browse", "Browse" }, { "deals", "Deals" }, { "sell", "Sell" }, { "owned", "My auctions" }, { "queue", "Automation" } }) do
    window.tabs[tab[1]] = button(window, tab[2], 16 + (index - 1) * 120, 60, 110, function() switch(tab[1]) end)
  end
  window.groupButton = button(window, "Groups and rules", 688, 60, 190, function()
    if not editor then createEditor() end
    local item = view == "queue" and selected and selected.item or (view ~= "queue" and House.selected)
    if item and item.itemKey and editor.fields.items:GetText() == "" then
      editor.fields.items:SetText(tostring(item.itemKey.itemID))
    end
    editor:Show()
  end)
  window.quickScan = button(window, "Quick scan", 768, 60, 112, function() resetSelection(); Scanner.Start("browse") end)
  window.fullScan = button(window, "Full scan", 890, 60, 114, function() resetSelection(); Scanner.Start("replicate") end)
  window.scanTime = label(window, "", 590, 105, 414, "small", "muted")
  window.scanTime:SetHeight(42)
  window.scanTime:SetWordWrap(true)
  window.search = field(window, "Search scan prices", 16, 103, 330, "")
  local function search()
    window.search:ClearFocus()
    variantItemID = nil
    resetSelection()
    if view == "deals" then refresh() else House.Search(window.search:GetText()) end
  end
  window.search:SetScript("OnEnterPressed", search)
  window.search:SetScript("OnTextChanged", function()
    if view == "deals" then selected, offset = nil, 0; refresh() end
  end)
  window.searchButton = button(window, "Search", 356, 121, 108, search)
  window.back = button(window, "Back", 474, 121, 100, function()
    if House.context ~= "browse" then variantItemID = nil; House.Search(window.search:GetText())
    else variantItemID = nil; resetSelection(); refresh() end
  end)
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
  addFilters()
  local tableFrame = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window.tableFrame = tableFrame
  tableFrame:SetPoint("TOPLEFT", 16, -206)
  tableFrame:SetSize(650, 448)
  UI.Box(tableFrame, "panel", "line")
  tableFrame:EnableMouseWheel(true)
  tableFrame:SetScript("OnMouseWheel", function(_, delta) offset = offset - delta * 3; refresh() end)
  window.header = label(tableFrame, "ITEM", 12, 8, 360, "header", "muted")
  window.quantityHeader = label(tableFrame, "QTY", 380, 8, 60, "header", "muted")
  window.priceHeader = label(tableFrame, "UNIT BUYOUT", 450, 8, 185, "header", "muted")
  window.priceHeader:SetJustifyH("RIGHT")
  window.rows = {}
  window.empty = label(tableFrame, "", 40, 190, 570, "body", "muted")
  window.empty:SetJustifyH("CENTER")
  local side = CreateFrame("Frame", nil, window, BackdropTemplateMixin and "BackdropTemplate" or nil)
  window.side = side
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
  window.duration = button(side, "8 hours", 152, 294, 156, function(self)
    self.value = self.value % 3 + 1
    self.label:SetText(DURATIONS[self.value] .. " hours")
  end)
  window.duration.value = 2
  window.history = button(side, "Price history", 16, 350, 292, function()
    if view == "deals" and selected then UI.ShowItem(selected.key)
    elseif House.selected then UI.ShowItem(Codec.ItemKey(House.selected.itemKey.itemID, House.selected.itemKey.itemSuffix)) end
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
  window.previous = button(window, "<", 142, 616, 30, function() offset = offset - visibleRows; refresh() end)
  window.next = button(window, ">", 178, 616, 30, function() offset = offset + visibleRows; refresh() end)
  window.page = label(window, "", 220, 623, 170, "small", "muted")
  window.status = label(window, "", 405, 622, 599, "status", "muted")
  window.status:SetJustifyH("RIGHT")
  window.status:SetWordWrap(true)
  window.status:SetHeight(26)
  addResizeGrip()
  fitSize()
  layout()
  window:SetScript("OnSizeChanged", function()
    layout()
    refresh()
  end)
end

function AuctionUI.Show(text)
  if view ~= "queue" and view ~= "deals" then view = House.mode end
  if not window then createWindow() end
  fitSize()
  window:Show()
  window:Raise()
  if text and text ~= "" and House.open and not Rules.running and not House.Busy() then
    view, variantItemID = "browse", nil
    window.search:SetText(text)
    House.Search(text)
  end
  refresh()
end

function AuctionUI.SearchItem(location)
  if not House.open or House.Busy() or Rules.running or ns.Scanner.state ~= "idle"
    or not location or not location:IsBagAndSlot() or not location:IsValid() then return false end
  local bag = location:GetBagAndSlot()
  if bag < 0 or bag > (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) then return false end
  local key = C_AuctionHouse.GetItemKeyFromItem(location)
  if not key or key.itemID == 0 then return false end
  AuctionUI.Show()
  view, variantItemID = "browse", nil
  resetSelection()
  local info = C_AuctionHouse.GetItemKeyInfo(key)
  window.search:SetText(info and info.itemName or "")
  window.search:ClearFocus()
  return House.Find({ itemKey = key })
end

House.Subscribe(refresh)
Rules.Subscribe(refresh)
Scanner.Subscribe(function(kind, payload)
  if kind == "progress" then scanMessage = "Scanning: " .. payload
  elseif kind == "fail" or kind == "refused" then scanMessage = "Scan: " .. payload
  elseif kind == "done" then
    C_Timer.After(0, function()
      scanMessage = "Scan complete."
      if window and window:IsShown() and view == "browse" then
        variantItemID = nil
        House.Search(window.search:GetText())
      elseif window and window:IsShown() and view == "deals" then
        updateDeals()
        scanMessage = "Scan complete. " .. #dealRows .. (#dealRows == 1 and " deal found." or " deals found.")
      end
      refresh()
    end)
  end
  refresh()
end)
UI.Watch(function()
  if window then window:SetScale(UI.Scale()); fitSize(); refresh() end
end)
local frame = CreateFrame("Frame")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_CLOSED" then
    variantItemID, scanMessage = nil, nil
    restoreBlizzard()
    if window then window:Hide() end
  elseif AuctionHouseFrame and not GoldbookAuctionButton then
    local launch = UI.Button(AuctionHouseFrame, "Goldbook", 120, 22, "GoldbookAuctionButton")
    launch:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "TOPRIGHT", -160, 2)
    launch:SetScript("OnClick", function() AuctionUI.Show() end)
  end
end)
