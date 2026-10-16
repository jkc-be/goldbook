local _, ns = ...

local Stats = {}
ns.Stats = Stats

local ALWAYS_SHARE = 0.15
local MAX_SHARE = 0.30
local MAX_STEP = 1.2
local OUTLIER_SIGMA = 1.5
local LADDER_LEVELS = 5

local function byPrice(a, b)
  return a.price < b.price
end

-- Per-unit price that ignores overpriced listings. The cheapest 15% of units
-- always count, units up to 30% count until the price steps up by more than
-- 20%, and prices beyond 1.5 standard deviations of that window are dropped.
-- Sorts `listings` ({ price, count }) in place.
function Stats.MarketValue(listings)
  local total = 0
  for _, listing in ipairs(listings) do
    total = total + listing.count
  end
  if total == 0 then
    return nil
  end
  table.sort(listings, byPrice)

  local always = math.max(1, math.ceil(total * ALWAYS_SHARE))
  local limit = math.max(1, math.ceil(total * MAX_SHARE))
  local window, seen, previous = {}, 0, nil
  for _, listing in ipairs(listings) do
    if seen >= limit then
      break
    end
    if seen >= always and listing.price > previous * MAX_STEP then
      break
    end
    local take = math.min(listing.count, limit - seen)
    window[#window + 1] = { price = listing.price, count = take }
    seen = seen + take
    previous = listing.price
  end

  local sum = 0
  for _, entry in ipairs(window) do
    sum = sum + entry.price * entry.count
  end
  local mean = sum / seen
  local variance = 0
  for _, entry in ipairs(window) do
    variance = variance + (entry.price - mean) ^ 2 * entry.count
  end
  local spread = math.sqrt(variance / seen) * OUTLIER_SIGMA

  local keptSum, kept = 0, 0
  for _, entry in ipairs(window) do
    if math.abs(entry.price - mean) <= spread then
      keptSum = keptSum + entry.price * entry.count
      kept = kept + entry.count
    end
  end
  return math.floor(keptSum / kept + 0.5)
end

function Stats.Median(values)
  if #values == 0 then
    return nil
  end
  local sorted = {}
  for index, value in ipairs(values) do
    sorted[index] = value
  end
  table.sort(sorted)
  local middle = math.ceil(#sorted / 2)
  if #sorted % 2 == 1 then
    return sorted[middle]
  end
  return math.floor((sorted[middle] + sorted[middle + 1]) / 2 + 0.5)
end

-- One item's auctions as a row: lowest price, market value, units, auction
-- count, and the ladder of its cheapest price levels as { price, count }.
function Stats.Summarize(listings)
  table.sort(listings, byPrice)
  local quantity, ladder = 0, {}
  for _, listing in ipairs(listings) do
    quantity = quantity + listing.count
    local top = ladder[#ladder]
    if top and top.price == listing.price then
      top.count = top.count + listing.count
    elseif #ladder < LADDER_LEVELS then
      ladder[#ladder + 1] = { price = listing.price, count = listing.count }
    end
  end
  return { min = listings[1].price, mv = Stats.MarketValue(listings), qty = quantity, n = #listings, ladder = ladder }
end
