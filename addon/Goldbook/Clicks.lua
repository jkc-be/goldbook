local _, ns = ...
local Database, Scanner = ns.Database, ns.Scanner

-- At the auction house, Shift+click on an item Goldbook has a price for also
-- opens its history. The auction house and addons such as Auctionator pass
-- Shift+clicks through these functions; one click can pass through several,
-- so the same item within half a second opens once. Not while a chat message
-- is being written, where Shift+click links the item.
local shiftKey, shiftAt
local function shiftClick(link)
  if not link or (issecretvalue and issecretvalue(link)) or type(link) ~= "string" or not link:find("item:", 1, true) then
    return
  end
  if not (Scanner.open and IsShiftKeyDown() and not IsAltKeyDown() and not IsControlKeyDown())
    or ns.db.settings.shiftClick == false or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) then
    return
  end
  local realmKey = ns.RealmKey()
  local key = Database.KeyFromLink(ns.db, realmKey, link)
  if not (key and Database.Lookup(ns.db, realmKey, key)) or (key == shiftKey and GetTime() - shiftAt < 0.5) then
    return
  end
  shiftKey, shiftAt = key, GetTime()
  ns.UI.ShowItem(link)
end
if HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", shiftClick)
end
if ChatEdit_InsertLink then
  hooksecurefunc("ChatEdit_InsertLink", shiftClick)
end
if ChatFrameUtil and ChatFrameUtil.InsertLink then
  hooksecurefunc(ChatFrameUtil, "InsertLink", shiftClick)
end
