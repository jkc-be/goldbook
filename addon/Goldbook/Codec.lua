local _, ns = ...

local Codec = {}
ns.Codec = Codec

local HOUR = 3600
local DAY = 24 * HOUR

-- %d overflows past 2^31 on Windows clients; %.0f does not.
local function int(n)
  return ("%.0f"):format(n)
end

function Codec.ItemKey(itemID, suffix)
  if suffix and suffix ~= 0 then
    return int(itemID) .. ":" .. int(suffix)
  end
  return int(itemID)
end

-- A classic item string carries the random suffix as its 7th field:
-- item:id:enchant:gem:gem:gem:gem:suffix. Newer clients leave that field empty
-- and list bonus ids instead, their count in field 13 and the ids after it.
-- A bonus id counts as the suffix when `known` has it: either the set of
-- suffixes the auction house reported for this item in a quick scan, or a
-- function asked about each bonus id.
local function isKnown(known, bonus)
  if type(known) == "function" then
    return known(bonus)
  end
  return known[bonus]
end

function Codec.KeyFromLink(link, known)
  local body = link:match("item:([%-%d:]+)")
  if not body then
    return nil
  end
  local fields = {}
  for field in (body .. ":"):gmatch("([^:]*):") do
    fields[#fields + 1] = field
  end
  local itemID = tonumber(fields[1])
  if not itemID then
    return nil
  end
  local suffix = tonumber(fields[7])
  if suffix and suffix ~= 0 then
    return Codec.ItemKey(itemID, suffix)
  end
  if known then
    for index = 14, 13 + (tonumber(fields[13]) or 0) do
      local bonus = tonumber(fields[index])
      if bonus and isKnown(known, bonus) then
        return Codec.ItemKey(itemID, bonus)
      end
    end
  end
  return Codec.ItemKey(itemID)
end

-- A scan travels as one string, "key,min,mv,qty,n;...", so the SavedVariables
-- file holds one value per scan instead of one table per item.
function Codec.EncodeRows(rows)
  local parts = {}
  for i, row in ipairs(rows) do
    parts[i] = row.key .. "," .. int(row.min) .. "," .. int(row.mv) .. "," .. int(row.qty) .. "," .. int(row.n)
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

function Codec.BaseID(key)
  return tonumber(key:match("^%d+"))
end

function Codec.ItemString(key)
  local itemID, suffix = key:match("^(%d+):?(%-?%d*)$")
  return "item:" .. itemID .. ":0:0:0:0:0:" .. (suffix ~= "" and suffix or "0")
end

-- A price record is "min,qty,n,seen,mv,mvAt;day,day,...;price:count,...":
-- the latest scan's lowest price, quantity and auction count, the last market
-- value a full scan measured and when, then the lowest price on each of the
-- last days the item was seen, oldest first, then the ladder of cheapest
-- price levels the latest scan saw, empty after a quick scan.
function Codec.EncodePrice(price)
  local days, ladder = {}, {}
  for index, value in ipairs(price.days) do
    days[index] = int(value)
  end
  for index, level in ipairs(price.ladder) do
    ladder[index] = int(level.price) .. ":" .. int(level.count)
  end
  return int(price.min) .. "," .. int(price.qty) .. "," .. int(price.n) .. "," .. int(price.seen) .. ","
    .. int(price.mv) .. "," .. int(price.mvAt) .. ";" .. table.concat(days, ",") .. ";" .. table.concat(ladder, ",")
end

-- Records written before the ladder existed end after the days.
function Codec.DecodePrice(packed)
  local min, qty, n, seen, mv, mvAt, dayList, levels =
    packed:match("^(%d+),(%d+),(%d+),(%d+),(%d+),(%d+);([^;]*);?(.*)$")
  local days, ladder = {}, {}
  for value in dayList:gmatch("%d+") do
    days[#days + 1] = tonumber(value)
  end
  for price, count in levels:gmatch("(%d+):(%d+)") do
    ladder[#ladder + 1] = { price = tonumber(price), count = tonumber(count) }
  end
  return {
    min = tonumber(min),
    qty = tonumber(qty),
    n = tonumber(n),
    seen = tonumber(seen),
    mv = tonumber(mv),
    mvAt = tonumber(mvAt),
    days = days,
    ladder = ladder,
  }
end

-- An item's price history is a list of points, oldest first, joined by
-- commas. A point is "day:min:qty:mv" for a whole UTC day number or
-- "h<hour>:min:qty:mv" for one hour of unix time: the item's lowest price and
-- quantity then, and the market value a full scan measured, 0 without one.
-- A day's own point comes before the hours of that day. A scan edits the
-- history as a string, so that it does not build a table per point for every
-- item. Decoded, a point is { at, day, hourly, min, qty, mv }, `at` the unix
-- time its hour or day starts and `hourly` true for an hour.
function Codec.HistoryPoint(point)
  local at = point.hourly and "h" .. int(math.floor(point.at / HOUR)) or int(point.day)
  return at .. ":" .. int(point.min) .. ":" .. int(point.qty) .. ":" .. int(point.mv)
end

function Codec.EncodeHistory(points)
  local parts = {}
  for index, point in ipairs(points) do
    parts[index] = Codec.HistoryPoint(point)
  end
  return table.concat(parts, ",")
end

local POINT = "^(h?)(%d+):(%d+):(%d+):(%d+)"

local function point(mark, number, min, qty, mv)
  number = tonumber(number)
  local hourly = mark == "h" or nil
  local at = hourly and number * HOUR or number * DAY
  return { at = at, day = math.floor(at / DAY), hourly = hourly, min = tonumber(min), qty = tonumber(qty), mv = tonumber(mv) }
end

local COMMA = (","):byte()

-- Where the point ending at `stop` starts in a history, and the point.
-- Searched backwards by hand: a pattern ending in $ tries every position of a
-- string that runs to kilobytes, and a scan reads the newest point of each
-- item.
function Codec.PointEndingAt(packed, stop)
  local start = stop
  while start > 1 and packed:byte(start - 1) ~= COMMA do
    start = start - 1
  end
  return start, point(packed:match(POINT, start))
end

-- A scan asks these two of every item, so they read no more than they must.
function Codec.OldestDay(packed)
  local mark, number = packed:match("^(h?)(%d+)")
  return mark == "h" and math.floor(tonumber(number) / 24) or tonumber(number)
end

-- Where the oldest hour starts and its day, nil without hours.
function Codec.OldestHour(packed)
  local at = packed:find("h", 1, true)
  if at then
    return at, math.floor(tonumber(packed:match("^%d+", at + 1)) / 24)
  end
end

-- The points from `init` on, oldest first, up to the first one on day
-- `before` or later when given, and where the points left undecoded start.
function Codec.DecodeHistory(packed, before, init)
  local points, at = {}, init or 1
  while true do
    local _, stop, mark, number, min, qty, mv = packed:find(POINT, at)
    if not stop then
      break
    end
    local decoded = point(mark, number, min, qty, mv)
    if before and decoded.day >= before then
      break
    end
    points[#points + 1] = decoded
    at = stop + 2
  end
  return points, at
end

-- Crockford's base32 leaves out I, L, O and U, so that a code read off the
-- screen is not typed as another.
local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

-- `length` characters of ALPHABET, each picked by `random(n)`, which answers
-- an integer from 1 to n.
function Codec.RandomCode(length, random)
  local characters = {}
  for index = 1, length do
    local pick = random(#ALPHABET)
    characters[index] = ALPHABET:sub(pick, pick)
  end
  return table.concat(characters)
end

-- "K7Q2M9PX" in groups of 4 is "K7Q2-M9PX".
function Codec.Grouped(code, size)
  return (code:gsub(("."):rep(size), "%0-"):gsub("-$", ""))
end

-- The colours of the coin letters, as chat and tooltips show them.
local COINS = { gold = "ffd700", silver = "c7c7cf", copper = "eda55f" }

-- "1,763g 05s 00c": a unit after a larger one has two digits. `coins`
-- recolours the letters, for a window drawn on another background.
function Codec.Money(copper, coins)
  coins = coins or COINS
  local gold = math.floor(copper / 10000)
  local silver = math.floor(copper / 100) % 100
  local parts = {}
  if gold > 0 then
    local digits = int(gold):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    parts[#parts + 1] = digits .. "|cff" .. coins.gold .. "g|r"
  end
  if gold > 0 or silver > 0 then
    parts[#parts + 1] = (gold > 0 and ("%02d"):format(silver) or silver) .. "|cff" .. coins.silver .. "s|r"
  end
  parts[#parts + 1] = (#parts > 0 and ("%02d"):format(copper % 100) or (copper % 100)) .. "|cff" .. coins.copper .. "c|r"
  return table.concat(parts, " ")
end

local AGE_UNITS = {
  { 86400, "d" },
  { 3600, "h" },
  { 60, "m" },
}

function Codec.Age(seconds)
  for _, unit in ipairs(AGE_UNITS) do
    if seconds >= unit[1] then
      return math.floor(seconds / unit[1]) .. unit[2] .. " ago"
    end
  end
  return "just now"
end
