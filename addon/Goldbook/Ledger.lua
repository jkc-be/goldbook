local _, ns = ...

-- Gold per character over time, to see whether the trading pays off.
-- db.gold[character][hour] is the character's gold at the end of that hour of
-- unix time; an hour without one keeps the balance before it. The figures are
-- per UTC day, each the balance at the end of that day.
local Ledger = {}
ns.Ledger = Ledger

local HOUR = 3600
local HOURS_PER_DAY = 24
local DAY = HOURS_PER_DAY * HOUR
local KEPT_DAYS = 60
local WEEK = 7
local MONTH = 30

function Ledger.Record(db, character, copper, now)
  local hour = math.floor(now / HOUR)
  local hours = db.gold[character]
  if not hours then
    -- The hour before stands in for the opening balance, so that the first
    -- day already shows what it earned.
    hours = { [hour - 1] = copper }
    db.gold[character] = hours
  end
  hours[hour] = copper
  -- Whole UTC days are kept, from the first hour of the day KEPT_DAYS ago.
  local oldest = (math.floor(now / DAY) - KEPT_DAYS) * HOURS_PER_DAY
  for at in pairs(hours) do
    if at < oldest then
      hours[at] = nil
    end
  end
end

-- The newest balance by the end of day `limit`, else the oldest one known.
local function balanceAt(hours, limit)
  local last = (limit + 1) * HOURS_PER_DAY
  local best, oldest
  for hour in pairs(hours) do
    if hour < last and (not best or hour > best) then
      best = hour
    end
    if not oldest or hour < oldest then
      oldest = hour
    end
  end
  return hours[best or oldest]
end

-- Total gold across characters at the end of each of the last `span` days,
-- oldest first. A character counts with its first known balance on the days
-- before it was first seen, so that meeting it is not booked as a gain.
function Ledger.History(db, now, span)
  local today = math.floor(now / DAY)
  local totals = {}
  for back = span - 1, 0, -1 do
    local total = 0
    for _, hours in pairs(db.gold) do
      total = total + balanceAt(hours, today - back)
    end
    totals[#totals + 1] = total
  end
  return totals
end

-- The account as a broker would state it: balance, change today, over a week
-- and a month, the highest balance and the best and worst day on record.
function Ledger.Performance(db, now)
  local history = Ledger.History(db, now, KEPT_DAYS)
  local last = #history
  local account = {
    gold = history[last],
    today = history[last] - history[last - 1],
    week = history[last] - history[last - WEEK],
    month = history[last] - history[last - MONTH],
    high = 0,
    bestDay = 0,
    worstDay = 0,
  }
  for index, total in ipairs(history) do
    account.high = math.max(account.high, total)
    if index > 1 then
      account.bestDay = math.max(account.bestDay, total - history[index - 1])
      account.worstDay = math.min(account.worstDay, total - history[index - 1])
    end
  end
  account.todayPercent = history[last - 1] > 0 and account.today / history[last - 1] * 100 or 0
  return account
end

-- One row per character, richest first: { name, gold, today, week, idle },
-- where `today` and `week` are changes and `idle` counts days not played.
function Ledger.Summary(db, now)
  local today = math.floor(now / DAY)
  local rows = {}
  for character, hours in pairs(db.gold) do
    local newest = 0
    for hour in pairs(hours) do
      newest = math.max(newest, hour)
    end
    local played = math.floor(newest / HOURS_PER_DAY)
    rows[#rows + 1] = {
      name = character,
      gold = hours[newest],
      today = played == today and hours[newest] - balanceAt(hours, today - 1) or 0,
      week = hours[newest] - balanceAt(hours, today - WEEK),
      idle = today - played,
    }
  end
  table.sort(rows, function(a, b)
    if a.gold ~= b.gold then
      return a.gold > b.gold
    end
    return a.name < b.name
  end)
  return rows
end
