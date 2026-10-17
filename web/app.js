const SVG = "http://www.w3.org/2000/svg";
const PAGE = 50;
const HOUR = 3600;
const DAY = 24 * HOUR;
const QUALITIES = ["Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom"];
const SCAN_NAMES = { browse: "Quick", replicate: "Full" };
const CLASSES = new Map([
  ["WARRIOR", "Warrior"],
  ["PALADIN", "Paladin"],
  ["HUNTER", "Hunter"],
  ["ROGUE", "Rogue"],
  ["PRIEST", "Priest"],
  ["DEATHKNIGHT", "Death Knight"],
  ["SHAMAN", "Shaman"],
  ["MAGE", "Mage"],
  ["WARLOCK", "Warlock"],
  ["MONK", "Monk"],
  ["DRUID", "Druid"],
  ["DEMONHUNTER", "Demon Hunter"],
  ["EVOKER", "Evoker"],
]);
const COINS = [
  { unit: "g", copper: 10000 },
  { unit: "s", copper: 100 },
  { unit: "c", copper: 1 },
];
// A change smaller than this, in percent, counts as flat.
const FLAT = 1;
const TRENDS = {
  up: { arrow: "↑", word: "up" },
  down: { arrow: "↓", word: "down" },
  flat: { arrow: "→", word: "flat" },
};
const SERIES = [
  { field: "minBuyout", name: "Min buyout", color: "var(--series-1)", area: true },
  { field: "marketValue", name: "Market value", color: "var(--series-2)" },
];
// Prices on top, the quantity listed in a band below that shares the time axis.
const CHART = { height: 300, left: 56, right: 64, price: [16, 192], supply: [214, 262], dates: 282 };
const LABEL_HEIGHT = 14;
const SPARK = { width: 56, height: 20, pad: 3, floor: 0.05 };
const WEEK = 7;
const NEWEST_SCANS = 5;
const WOWHEAD_ITEM = "https://www.wowhead.com/forever/item=";
const WIDE = matchMedia("(min-width: 1240px)");

const state = { realms: [], realm: null, q: "", profession: "", kind: "all", quality: "", sort: "name", order: "asc", offset: 0, selected: null };
const latest = { prices: 0, trends: 0, history: 0, sellers: 0, view: 0, session: 0 };
const STALE = Symbol("stale");
const $ = (id) => document.getElementById(id);

// Item and realm names come from uploads, so they only ever reach the page
// as text nodes.
function element(tag, properties = {}, children = []) {
  const node = Object.assign(document.createElement(tag), properties);
  node.append(...children);
  return node;
}

function svg(tag, attributes = {}, text, children = []) {
  const node = document.createElementNS(SVG, tag);
  for (const [name, value] of Object.entries(attributes)) {
    node.setAttribute(name, value);
  }
  if (text !== undefined) {
    node.textContent = text;
  }
  node.append(...children);
  return node;
}

async function api(path, parameters = {}, body = undefined) {
  // Relative to the page, so the site still works behind a path prefix such as /goldbook/.
  const url = new URL(path.replace(/^\//, ""), location.href);
  for (const [name, value] of Object.entries(parameters)) {
    url.searchParams.set(name, value);
  }
  const request =
    body === undefined ? {} : { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) };
  const response = await fetch(url, request).catch(() => {
    throw new Error("the server could not be reached");
  });
  if (response.ok) {
    return response.json();
  }
  // The API explains its errors in JSON. An error page from in front of it does not.
  const { error } = await response.json().catch(() => ({}));
  throw Object.assign(new Error(error ?? `the server answered ${response.status}`), { status: response.status });
}

// Settles like the request, unless a newer request of the same kind has
// started since. Then it rejects with STALE, so that a slow answer cannot
// replace what a later one put on the page.
function latestOnly(kind, request) {
  const turn = ++latest[kind];
  return request.finally(() => {
    if (turn !== latest[kind]) {
      throw STALE;
    }
  });
}

function coins(copper) {
  return COINS.map(({ unit, copper: size }, index) => ({
    unit,
    amount: index === 0 ? Math.floor(copper / size) : Math.floor(copper / size) % 100,
  }));
}

function moneyText(copper) {
  const shown = coins(copper).filter(({ amount }) => amount > 0);
  return shown.length === 0 ? "0c" : shown.map(({ unit, amount }) => `${amount.toLocaleString("en")}${unit}`).join(" ");
}

// Zero units are left out. In a column every unit keeps its slot, so that a
// lone "12g" cannot line up with the copper of the rows around it.
function money(copper, { aligned = false } = {}) {
  const parts = coins(copper).flatMap(({ unit, amount }, index) => {
    const shown = amount > 0 || (copper === 0 && index === COINS.length - 1);
    if (!shown && !aligned) {
      return [];
    }
    const part = element("span", { className: `coin ${unit}` });
    if (shown) {
      part.append(amount.toLocaleString("en"), element("span", { className: "unit", textContent: unit }));
    }
    return [part, " "];
  });
  return element("span", { className: aligned ? "money aligned" : "money" }, parts.slice(0, -1));
}

const optionalMoney = (copper, options) => (copper > 0 ? money(copper, options) : "–");
const rounded = (value) => String(Math.round(value * 100) / 100);

// Axis labels `step` apart keep to a unit whose hundredths tell them apart.
function compactMoney(copper, step = Infinity) {
  if (copper >= 10_000_000 && step >= 100_000) {
    return `${rounded(copper / 10_000_000)}Kg`;
  }
  if (copper >= 10_000 && step >= 100) {
    return `${rounded(copper / 10_000)}g`;
  }
  if (copper >= 100 && step >= 1) {
    return `${rounded(copper / 100)}s`;
  }
  return `${rounded(copper)}c`;
}

function when(seconds) {
  return new Date(seconds * 1000).toLocaleString(undefined, {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function shortDate(seconds, timeZone) {
  return new Date(seconds * 1000).toLocaleDateString(undefined, { day: "numeric", month: "short", timeZone });
}

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "always" });

function age(seconds) {
  const elapsed = Date.now() / 1000 - seconds;
  if (elapsed < 3600) {
    return relative.format(-Math.max(1, Math.round(elapsed / 60)), "minute");
  }
  if (elapsed < DAY) {
    return relative.format(-Math.round(elapsed / 3600), "hour");
  }
  return relative.format(-Math.round(elapsed / DAY), "day");
}

function itemName(item) {
  return item.name ?? `Item ${item.itemKey}`;
}

function quality(item) {
  return QUALITIES[item.quality] ? item.quality : 1;
}

function showMessage(text) {
  $("message").textContent = text;
  $("message").hidden = text === "";
}

// Each day's lowest price, oldest first: [{ day, low }]. Days are UTC days,
// as in the addon and in /api/trends.
function dailyLows(points) {
  const lows = new Map();
  for (const { scannedAt, minBuyout } of points) {
    const day = Math.floor(scannedAt / DAY) * DAY;
    lows.set(day, Math.min(lows.get(day) ?? minBuyout, minBuyout));
  }
  return [...lows].map(([day, low]) => ({ day, low }));
}

// The days of /api/trends on which the item was seen, as dailyLows has them.
function seenDays(days, lows) {
  return days.map((day, index) => ({ day, low: lows[index] })).filter(({ low }) => low !== null);
}

const percent = (from, to) => ((to - from) / from) * 100;

// The change from the lowest price of the newest day at least `days` before
// the newest one, or null when the item was not seen that far back.
function changeOver(lows, current, days) {
  const newest = lows.at(-1)?.day;
  const before = lows.findLast(({ day }) => day <= newest - days * DAY);
  return before ? percent(before.low, current) : null;
}

const percentText = (size) => `${size >= 100 ? Math.round(size) : size.toFixed(1)}%`;

function direction(change) {
  if (Math.abs(change) < FLAT) {
    return "flat";
  }
  return change > 0 ? "up" : "down";
}

function trend(change, span) {
  if (change === null) {
    return element("span", { className: "trend none", textContent: "–", title: "Not enough history" });
  }
  const kind = direction(change);
  const shown = percentText(Math.abs(change));
  return element("span", {
    className: `trend ${kind}`,
    textContent: `${TRENDS[kind].arrow} ${shown}`,
    title: `${TRENDS[kind].word} ${shown} ${span}`,
  });
}

// The days the 7-day change spans, the last at the price the row shows, so
// that the line ends where the change is measured.
function weekLows(lows, current) {
  const week = lows.slice(-(WEEK + 1));
  week[week.length - 1] = current;
  return week;
}

// One line per run of consecutive days with a price; a day without one leaves
// a gap. `kind` is the direction of the change beside it, so both read alike.
// The scale spans at least SPARK.floor of the price either way, so that a move
// of a few percent stays a small move, and a dashed rule marks the first price.
function sparkline(lows, kind) {
  const values = lows.filter((low) => low !== null);
  const root = svg("svg", { class: `spark ${kind}`, viewBox: `0 0 ${SPARK.width} ${SPARK.height}`, "aria-hidden": "true" });
  if (values.length === 0) {
    return root;
  }
  const [low, high] = [Math.min(...values), Math.max(...values)];
  const middle = (low + high) / 2;
  const reach = Math.max((high - low) / 2, middle * SPARK.floor);
  const x = (index) => SPARK.pad + (index / (lows.length - 1)) * (SPARK.width - 2 * SPARK.pad);
  const y = (value) => SPARK.height / 2 - ((value - middle) / reach) * (SPARK.height / 2 - SPARK.pad);
  const base = y(values[0]).toFixed(1);
  root.append(svg("path", { class: "spark-base", d: `M${SPARK.pad} ${base}H${SPARK.width - SPARK.pad}` }));
  let path = "";
  lows.forEach((value, index) => {
    if (value === null) {
      return;
    }
    const joined = index > 0 && lows[index - 1] !== null;
    path += `${joined ? "L" : "M"}${x(index).toFixed(1)} ${y(value).toFixed(1)}`;
    if (!joined && (lows[index + 1] ?? null) === null) {
      root.append(svg("circle", { class: "spark-point", cx: x(index), cy: y(value), r: 1.5 }));
    }
  });
  root.append(svg("path", { class: "spark-line", d: path }));
  const last = lows.length - 1;
  if (lows[last] !== null) {
    root.append(svg("circle", { class: "spark-end", cx: x(last), cy: y(lows[last]), r: 2 }));
  }
  return root;
}

function niceTicks(min, max) {
  if (min === max) {
    min *= 0.9;
    max = max * 1.1 || 1;
  }
  const rough = (max - min) / 4;
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const step = Math.max(
    1,
    [1, 2, 5, 10].map((multiple) => multiple * magnitude).find((candidate) => candidate >= rough),
  );
  const ticks = [];
  for (let tick = Math.floor(min / step) * step; tick < max + step; tick += step) {
    ticks.push(tick);
  }
  return ticks;
}

// Local midnights between start and end, at most about `most` of them.
function dayTicks(start, end, most = 6) {
  const step = Math.max(1, Math.ceil((end - start) / DAY / most));
  const day = new Date(start * 1000);
  day.setHours(0, 0, 0, 0);
  if (day.getTime() / 1000 < start) {
    day.setDate(day.getDate() + 1);
  }
  const ticks = [];
  for (; day.getTime() / 1000 <= end; day.setDate(day.getDate() + step)) {
    ticks.push(day.getTime() / 1000);
  }
  return ticks;
}

// Scans that cross no midnight are labelled with the times of the first and last.
function scanDates(start, end) {
  const midnights = start === end ? [] : dayTicks(start, end);
  if (midnights.length > 0) {
    return midnights.map((time) => [time, shortDate(time), "middle"]);
  }
  return start === end
    ? [[start, when(start), "middle"]]
    : [
        [start, when(start), "start"],
        [end, when(end), "end"],
      ];
}

// Drawn at the size it is shown, so that its text keeps its size on a phone.
const chartWidth = (chart) => Math.max(300, Math.round(chart.getBoundingClientRect().width));

const drawn = new Map();
// Gradient ids are page-wide, so each area gets its own.
let areas = 0;
const resized = new ResizeObserver((entries) => {
  for (const { target } of entries) {
    const { width, draw } = drawn.get(target);
    if (target.getBoundingClientRect().width > 0 && chartWidth(target) !== width) {
      draw();
    }
  }
});

function areaFill(root, color) {
  const id = `area-${++areas}`;
  const defs = root.querySelector("defs") ?? root.appendChild(svg("defs"));
  defs.append(svg("linearGradient", { id, x1: 0, x2: 0, y1: 0, y2: 1 }, undefined, [
    svg("stop", { offset: 0, "stop-color": color, "stop-opacity": 0.42 }),
    svg("stop", { offset: 1, "stop-color": color, "stop-opacity": 0.03 }),
  ]));
  return `url(#${id})`;
}

function placeTooltip(tooltip, left, width) {
  tooltip.hidden = false;
  tooltip.style.left = `${(left / width) * 100}%`;
  tooltip.style.transform = left < width / 2 ? "translateX(12px)" : "translateX(calc(-100% - 12px))";
}

// The pointer, a tap or the arrow keys rest on one of `count` points, found by
// its x position, and Escape clears it. Returns a way to rest on one from outside.
function inspect(chart, root, overlay, { count, x, width, start, show, hide }) {
  let active = start;
  const at = (index) => {
    active = index;
    show(index);
  };
  const nearest = (event) => {
    const box = root.getBoundingClientRect();
    const pointer = ((event.clientX - box.left) / box.width) * width;
    let closest = 0;
    for (let index = 1; index < count; index++) {
      if (Math.abs(x(index) - pointer) < Math.abs(x(closest) - pointer)) {
        closest = index;
      }
    }
    at(closest);
  };
  overlay.addEventListener("pointermove", nearest);
  overlay.addEventListener("pointerdown", nearest);
  // A finger leaves as it lifts, so what it tapped stays until focus moves on.
  overlay.addEventListener("pointerleave", (event) => {
    if (event.pointerType !== "touch") {
      hide();
    }
  });
  chart.onfocus = () => at(active);
  chart.onblur = hide;
  chart.onkeydown = (event) => {
    if (event.key === "Escape") {
      hide();
      return;
    }
    const move = { ArrowLeft: -1, ArrowRight: 1 }[event.key];
    if (move) {
      event.preventDefault();
      at(Math.min(count - 1, Math.max(0, active + move)));
    }
  };
  return at;
}

// Times in seconds, values per time with null where nothing was measured, and
// an optional band of amounts below that shares the time axis. With `steps`
// a line holds each value until the next one instead of sloping to it.
function drawChart(chart, options) {
  const { times, series, band, heading, label, dates, steps = false } = options;
  const values = series.flatMap((line) => line.values).filter((value) => value !== null);
  const ticks = niceTicks(Math.min(...values), Math.max(...values));
  const [low, high] = [ticks[0], ticks.at(-1)];
  const [start, end] = [times[0], times.at(-1)];
  const [top, bottom] = band ? CHART.price : [CHART.price[0], CHART.supply[1]];
  const width = chartWidth(chart);
  const right = width - CHART.right;
  const x = (time) => (start === end ? (CHART.left + right) / 2 : CHART.left + ((time - start) / (end - start)) * (right - CHART.left));
  const y = (value) => bottom - ((value - low) / (high - low)) * (bottom - top);
  const amounts = band?.values ?? [];
  const most = Math.max(1, ...amounts);
  const [supplyTop, supplyBottom] = CHART.supply;
  const barHeight = (amount) => (amount / most) * (supplyBottom - supplyTop);
  const barWidth = Math.max(1.5, Math.min(8, ((right - CHART.left) / times.length) * 0.5));

  const root = svg("svg", { viewBox: `0 0 ${width} ${CHART.height}` });
  const bars = amounts.map((amount, index) =>
    svg("rect", {
      class: "bar",
      x: x(times[index]) - barWidth / 2,
      y: supplyBottom - barHeight(amount),
      width: barWidth,
      height: barHeight(amount),
    }),
  );
  if (band) {
    root.append(
      svg("line", { class: "axis", x1: CHART.left, x2: right, y1: supplyBottom, y2: supplyBottom }),
      svg("text", { x: CHART.left - 8, y: supplyTop, dy: "0.32em", "text-anchor": "end" }, most.toLocaleString("en")),
      svg("text", { x: CHART.left - 8, y: supplyBottom, dy: "0.32em", "text-anchor": "end" }, "0"),
      ...bars,
    );
  }
  for (const tick of ticks) {
    root.append(
      svg("line", { class: "grid", x1: CHART.left, x2: right, y1: y(tick), y2: y(tick) }),
      svg("text", { x: CHART.left - 8, y: y(tick), dy: "0.32em", "text-anchor": "end" }, compactMoney(tick, ticks[1] - ticks[0])),
    );
  }
  root.append(svg("line", { class: "axis", x1: CHART.left, x2: right, y1: bottom, y2: bottom }));

  for (const [time, text, anchor] of dates(start, end, right - CHART.left)) {
    root.append(
      svg("line", { class: "axis", x1: x(time), x2: x(time), y1: CHART.dates - 18, y2: CHART.dates - 14 }),
      svg("text", { x: x(time), y: CHART.dates, "text-anchor": anchor }, text),
    );
  }

  // A line runs from one measured value to the next and passes over the
  // times in between that measured nothing.
  const ends = [];
  for (const line of series) {
    const measured = times.flatMap((time, index) => {
      const value = line.values[index];
      return value === null ? [] : [{ x: x(time), y: y(value), value }];
    });
    const path = measured
      .map((point, index) => (index === 0 ? `M${point.x} ${point.y}` : `${steps ? `H${point.x} V` : `L${point.x} `}${point.y}`))
      .join(" ");
    const last = measured.at(-1);
    if (line.area) {
      root.append(svg("path", { class: "area", d: `${path} V${bottom} H${measured[0].x} Z`, fill: areaFill(root, line.color) }));
    }
    root.append(
      svg("path", { class: "line", d: path, stroke: line.color }),
      svg("circle", { class: "dot", cx: last.x, cy: last.y, r: 4, fill: line.color }),
    );
    ends.push(last);
  }
  // Labels that would overlap are left to the legend and the tooltip.
  if (ends.every((end, index) => ends.slice(index + 1).every((other) => Math.abs(end.y - other.y) >= LABEL_HEIGHT))) {
    for (const last of ends) {
      root.append(svg("text", { class: "value", x: last.x + 10, y: last.y, dy: "0.32em" }, compactMoney(last.value)));
    }
  }

  const crosshair = svg("line", { class: "crosshair", y1: top, y2: CHART.supply[1], visibility: "hidden" });
  const markers = series.map(({ color }) => svg("circle", { class: "dot", r: 4, fill: color, visibility: "hidden" }));
  const overlay = svg("rect", {
    x: CHART.left,
    y: top,
    width: right - CHART.left,
    height: CHART.supply[1] - top,
    fill: "transparent",
  });
  root.append(crosshair, ...markers, overlay);

  const tooltip = element("div", { className: "tooltip", hidden: true });

  const show = (index) => {
    const left = x(times[index]);
    crosshair.setAttribute("x1", left);
    crosshair.setAttribute("x2", left);
    crosshair.setAttribute("visibility", "visible");
    bars.forEach((bar, position) => bar.classList.toggle("active", position === index));
    const rows = [element("div", { className: "when", textContent: heading(index) })];
    series.forEach((line, position) => {
      const value = line.values[index];
      const marker = markers[position];
      marker.setAttribute("visibility", value === null ? "hidden" : "visible");
      if (value !== null) {
        marker.setAttribute("cx", left);
        marker.setAttribute("cy", y(value));
        const key = element("span", { className: "key" });
        key.style.background = line.color;
        rows.push(
          element("div", { className: "row" }, [
            key,
            element("strong", {}, [money(value)]),
            element("span", { className: "name", textContent: line.name }),
          ]),
        );
      }
    });
    if (band) {
      rows.push(
        element("div", { className: "row" }, [
          element("span", { className: "key bar-key" }),
          element("strong", { textContent: amounts[index].toLocaleString("en") }),
          element("span", { className: "name", textContent: band.name }),
        ]),
      );
    }
    tooltip.replaceChildren(...rows);
    placeTooltip(tooltip, left, width);
  };
  const hide = () => {
    crosshair.setAttribute("visibility", "hidden");
    markers.forEach((marker) => marker.setAttribute("visibility", "hidden"));
    bars.forEach((bar) => bar.classList.remove("active"));
    tooltip.hidden = true;
  };
  const at = inspect(chart, root, overlay, {
    count: times.length,
    x: (index) => x(times[index]),
    width,
    start: times.length - 1,
    show,
    hide,
  });

  chart.setAttribute("aria-label", label);
  chart.replaceChildren(root, tooltip);
  drawn.set(chart, { width, draw: () => drawChart(chart, options), show: at, hide });
  resized.observe(chart);
}

// Only a full scan measures a market value; quick scans leave it at 0.
function drawItemChart(title, points) {
  const series = SERIES.map(({ field, ...line }) => ({
    ...line,
    values: points.map((point) => (point[field] > 0 ? point[field] : null)),
  })).filter(({ values }) => values.some((value) => value !== null));
  drawChart($("chart"), {
    times: points.map((point) => point.scannedAt),
    series,
    band: { name: "listed", values: points.map((point) => point.quantity) },
    heading: (index) => `${when(points[index].scannedAt)} · ${SCAN_NAMES[points[index].mode]} scan`,
    label: `${title}: min buyout from ${moneyText(points[0].minBuyout)} to ${moneyText(points.at(-1).minBuyout)} over ${points.length} ${points.length === 1 ? "scan" : "scans"}, with the quantity listed. Use the arrow keys to read each scan.`,
    dates: scanDates,
  });
  $("legend").replaceChildren(
    ...series.map(({ name, color }) => {
      const key = element("span", { className: "key" });
      key.style.background = color;
      return element("span", {}, [key, name]);
    }),
    element("span", {}, [element("span", { className: "key bar-key" }), "Listed"]),
  );
}

function stat(label, value, note) {
  return element("div", { className: "stat" }, [
    element("dt", { textContent: label }),
    element("dd", {}, [value, ...(note ? [element("span", { className: "note", textContent: note })] : [])]),
  ]);
}

function drawSummary(points) {
  const now = points.at(-1);
  const lows = dailyLows(points);
  const prices = points.map((point) => point.minBuyout);
  const market = points.findLast((point) => point.marketValue > 0);
  const range = lows.length > 1 ? percent(lows[0].low, now.minBuyout) : null;
  const since = shortDate(lows[0].day, "UTC");
  $("summary").replaceChildren(
    stat("Min buyout", money(now.minBuyout), age(now.scannedAt)),
    stat("1 day", trend(changeOver(lows, now.minBuyout, 1), "over 1 day")),
    stat("7 days", trend(changeOver(lows, now.minBuyout, 7), "over 7 days")),
    stat(`Since ${since}`, trend(range, `since ${since}`)),
    stat("Low", money(Math.min(...prices))),
    stat("High", money(Math.max(...prices))),
    stat("Market value", market ? money(market.marketValue) : "–", market ? age(market.scannedAt) : "no full scan yet"),
    stat("Listed now", now.quantity.toLocaleString("en")),
  );
}

function drawScans(points) {
  const newestFirst = points.toReversed();
  $("history").tBodies[0].replaceChildren(
    ...newestFirst.map((point, index) => {
      const row = element("tr", {}, [
        element("td", { textContent: when(point.scannedAt) }),
        element("td", { className: "number" }, [money(point.minBuyout, { aligned: true })]),
        element("td", { className: "number" }, [optionalMoney(point.marketValue, { aligned: true })]),
        element("td", { className: "number", textContent: point.quantity.toLocaleString("en") }),
        element("td", { className: "mode", textContent: SCAN_NAMES[point.mode] }),
      ]);
      row.hidden = index >= NEWEST_SCANS;
      return row;
    }),
  );
  const toggle = $("all-scans");
  toggle.hidden = points.length <= NEWEST_SCANS;
  toggle.setAttribute("aria-expanded", "false");
  toggle.textContent = `All ${points.length} scans`;
  toggle.onclick = () => {
    const expanded = toggle.getAttribute("aria-expanded") !== "true";
    toggle.setAttribute("aria-expanded", String(expanded));
    toggle.textContent = expanded ? `Newest ${NEWEST_SCANS} scans` : `All ${points.length} scans`;
    [...$("history").tBodies[0].rows].forEach((row, index) => {
      row.hidden = !expanded && index >= NEWEST_SCANS;
    });
  };
}

const unitsUpTo = (levels, price) => levels.findLast((level) => level.unitPrice <= price)?.cumulativeQuantity ?? 0;

// Price ticks inside the range, every other one dropped until their labels fit.
function priceLabels(low, high, width) {
  let ticks = niceTicks(low, high).filter((tick) => tick >= low && tick <= high);
  while (ticks.length > Math.max(2, labelRoom(width))) {
    ticks = ticks.filter((_, index) => index % 2 === 0);
  }
  const step = ticks.length > 1 ? ticks[1] - ticks[0] : Infinity;
  return ticks.map((tick) => [tick, compactMoney(tick, step)]);
}

// The units for sale up to each price, stepping up at every level of the
// book, with an earlier book faintly behind it on the same scales.
function drawDepthChart(chart, levels, earlier, highlight) {
  const books = [levels, ...(earlier ? [earlier.orderBook] : [])].flat();
  const prices = books.map((level) => level.unitPrice);
  const [low, high] = [Math.min(...prices), Math.max(...prices)];
  const ticks = niceTicks(0, Math.max(...books.map((level) => level.cumulativeQuantity)));
  const [top, bottom] = [CHART.price[0], CHART.supply[1]];
  const width = chartWidth(chart);
  const right = width - CHART.right;
  const x = (price) => CHART.left + ((price - low) / (high - low)) * (right - CHART.left);
  const y = (units) => bottom - (units / ticks.at(-1)) * (bottom - top);
  const steps = (book) =>
    `M${CHART.left} ${bottom} ${book.map((level) => `H${x(level.unitPrice)} V${y(level.cumulativeQuantity)}`).join(" ")} H${right}`;

  const root = svg("svg", { viewBox: `0 0 ${width} ${CHART.height}` });
  for (const tick of ticks) {
    root.append(
      svg("line", { class: "grid", x1: CHART.left, x2: right, y1: y(tick), y2: y(tick) }),
      svg("text", { x: CHART.left - 8, y: y(tick), dy: "0.32em", "text-anchor": "end" }, tick.toLocaleString("en")),
    );
  }
  root.append(svg("line", { class: "axis", x1: CHART.left, x2: right, y1: bottom, y2: bottom }));
  for (const [price, text] of priceLabels(low, high, right - CHART.left)) {
    root.append(
      svg("line", { class: "axis", x1: x(price), x2: x(price), y1: CHART.dates - 18, y2: CHART.dates - 14 }),
      svg("text", { x: x(price), y: CHART.dates, "text-anchor": "middle" }, text),
    );
  }

  const line = steps(levels);
  const total = levels.at(-1).cumulativeQuantity;
  root.append(svg("path", { class: "area", d: `${line} V${bottom} Z`, fill: areaFill(root, "var(--series-1)") }));
  if (earlier) {
    root.append(svg("path", { class: "line earlier", d: steps(earlier.orderBook) }));
  }
  root.append(
    svg("path", { class: "line", d: line, stroke: "var(--series-1)" }),
    ...levels.map((level) => svg("circle", { class: "depth-point", cx: x(level.unitPrice), cy: y(level.cumulativeQuantity), r: 2 })),
    svg("text", { class: "value", x: right + 10, y: y(total), dy: "0.32em" }, total.toLocaleString("en")),
  );

  const crosshair = svg("line", { class: "crosshair", y1: top, y2: bottom, visibility: "hidden" });
  const marker = svg("circle", { class: "dot", r: 4, fill: "var(--series-1)", visibility: "hidden" });
  const earlierMarker = svg("circle", { class: "dot earlier", r: 3.5, visibility: "hidden" });
  const overlay = svg("rect", { x: CHART.left, y: top, width: right - CHART.left, height: bottom - top, fill: "transparent" });
  root.append(crosshair, ...(earlier ? [earlierMarker] : []), marker, overlay);

  const tooltip = element("div", { className: "tooltip depth-tooltip", hidden: true });
  const row = (value, name, key) =>
    element("div", { className: "row" }, [
      ...(key ? [key] : []),
      element("strong", {}, [value]),
      element("span", { className: "name", textContent: name }),
    ]);
  const show = (index) => {
    const level = levels[index];
    const left = x(level.unitPrice);
    crosshair.setAttribute("x1", left);
    crosshair.setAttribute("x2", left);
    crosshair.setAttribute("visibility", "visible");
    marker.setAttribute("cx", left);
    marker.setAttribute("cy", y(level.cumulativeQuantity));
    marker.setAttribute("visibility", "visible");
    const key = element("span", { className: "key" });
    key.style.background = "var(--series-1)";
    const rows = [
      element("div", { className: "when", textContent: `Level ${index + 1} of ${levels.length}` }),
      row(money(level.unitPrice), "per unit"),
      row(level.quantity.toLocaleString("en"), "at this price"),
      row(level.cumulativeQuantity.toLocaleString("en"), "up to this price", key),
      row(money(level.cumulativeCost), "buys them all"),
    ];
    if (earlier) {
      const before = unitsUpTo(earlier.orderBook, level.unitPrice);
      earlierMarker.setAttribute("cx", left);
      earlierMarker.setAttribute("cy", y(before));
      earlierMarker.setAttribute("visibility", "visible");
      rows.push(row(before.toLocaleString("en"), "earlier", element("span", { className: "key earlier-key" })));
    }
    tooltip.replaceChildren(...rows);
    placeTooltip(tooltip, left, width);
    highlight(index);
  };
  const hide = () => {
    for (const node of [crosshair, marker, earlierMarker]) {
      node.setAttribute("visibility", "hidden");
    }
    tooltip.hidden = true;
    highlight(null);
  };
  const at = inspect(chart, root, overlay, {
    count: levels.length,
    x: (index) => x(levels[index].unitPrice),
    width,
    start: 0,
    show,
    hide,
  });

  chart.setAttribute(
    "aria-label",
    `Units for sale up to each price: ${total.toLocaleString("en")} over ${levels.length} price levels from ${moneyText(levels[0].unitPrice)} to ${moneyText(levels.at(-1).unitPrice)}${earlier ? `, drawn over the observation of ${when(earlier.scannedAt)}` : ""}. Use the arrow keys to read each level.`,
  );
  chart.replaceChildren(root, tooltip);
  drawn.set(chart, { width, draw: () => drawDepthChart(chart, levels, earlier, highlight), show: at, hide });
  resized.observe(chart);
}

function describeLevel(level) {
  return `${moneyText(level.unitPrice)} per unit: ${level.quantity.toLocaleString("en")} at this price, ${level.cumulativeQuantity.toLocaleString("en")} up to it for ${moneyText(level.cumulativeCost)}.`;
}

// Drawn into `container` after it is on the page, so that the chart can measure itself.
function drawBook(container, { scannedAt, summary, orderBook }, earlier) {
  const { totalQuantity } = summary;
  const children = [
    element("dl", { className: "summary book-summary" }, [
      stat("Best ask", orderBook.length ? money(orderBook[0].unitPrice) : "No listings"),
      stat("Listed units", totalQuantity.toLocaleString("en")),
      stat("Price levels", orderBook.length.toLocaleString("en")),
      stat("Observed", age(scannedAt), new Date(scannedAt * 1000).toLocaleString()),
    ]),
  ];
  const chart = orderBook.length > 1 ? element("div", { className: "chart depth-chart", tabIndex: 0 }) : null;
  const live = element("p", { className: "visually-hidden" });
  if (chart) {
    chart.setAttribute("role", "img");
    live.setAttribute("aria-live", "polite");
    const key = element("span", { className: "key" });
    key.style.background = "var(--series-1)";
    children.push(
      element("div", { className: "legend" }, [
        element("span", {}, [key, "Units for sale up to each price"]),
        ...(earlier ? [element("span", {}, [element("span", { className: "key earlier-key" }), `Earlier, ${when(earlier.scannedAt)}`])] : []),
      ]),
      chart,
      live,
    );
  } else if (orderBook.length === 1) {
    children.push(element("p", { className: "muted", textContent: "All of it is listed at one price, so there is no depth to chart." }));
  }
  const rows = orderBook.map((level, index) => {
    const cumulative = element("td", { className: "number depth-cell", textContent: level.cumulativeQuantity.toLocaleString("en") });
    cumulative.style.setProperty("--depth", `${(level.cumulativeQuantity / totalQuantity) * 100}%`);
    const row = element("tr", {}, [
      element("td", { className: "number ask-price" }, [money(level.unitPrice)]),
      element("td", { className: "number", textContent: level.quantity.toLocaleString("en") }),
      cumulative,
    ]);
    if (chart) {
      row.onpointerenter = () => drawn.get(chart).show(index);
      row.onpointerleave = () => drawn.get(chart).hide();
    }
    return row;
  });
  children.push(
    element("table", { className: "seller-table order-book" }, [
      element("caption", { textContent: "Sell orders · lowest ask first" }),
      element("thead", {}, [
        element("tr", {}, ["Ask / unit", "Units", "Cumulative"].map((text) =>
          element("th", { scope: "col", className: "number", textContent: text }))),
      ]),
      element("tbody", {}, rows),
    ]),
    element("p", {
      className: "muted",
      textContent: orderBook.length
        ? "Cumulative units include all stock up to that unit price. Completed searches and full scans are recorded; changes between observations are not tracked."
        : "No buyout stock was listed in this observation.",
    }),
  );
  container.replaceChildren(...children);
  if (chart) {
    drawDepthChart(chart, orderBook, earlier, (index) => {
      rows.forEach((row, position) => row.classList.toggle("active", position === index));
      if (index !== null) {
        live.textContent = describeLevel(orderBook[index]);
      }
    });
  }
}

function drawSellers(data) {
  const panel = $("sellers");
  const title = element("h3", { id: "sellers-title", textContent: "Order book" });
  if (!data.snapshot) {
    panel.replaceChildren(title, element("p", { className: "muted", textContent:
      "No order book has been uploaded for this item. With the updated addon, run /gb scan full at the auction house, then /reload with the desktop app open. A complete search for this item also records its book." }));
    return;
  }
  const { realm, faction } = state.realm;
  const { itemKey, id } = data.snapshot;
  const history = data.history ?? [];
  const book = element("div");
  const fetchBook = (snapshot) =>
    latestOnly("sellers", api("/api/sellers", { realm, faction, itemKey, snapshot })).then((result) => result.snapshot);
  // Each observation is drawn at once, and again over the one before it once that arrives.
  const show = (snapshot) => {
    drawBook(book, snapshot, null);
    const shown = history.findIndex((entry) => entry.id === snapshot.id);
    const before = shown === -1 ? undefined : history[shown + 1];
    if (before) {
      run(async () => drawBook(book, snapshot, await fetchBook(before.id)));
    }
  };
  const children = [title,
    element("p", { className: "muted", textContent: "Sell listings only. WoW does not expose a standing buy-order book. These are recorded snapshots, not a live market feed." }),
  ];
  if (history.length > 1) {
    const select = element("select", { id: "order-book-snapshot" }, history.map((snapshot, index) =>
      element("option", { value: snapshot.id, selected: snapshot.id === id,
        textContent: `#${history.length - index} · ${when(snapshot.scannedAt)}${index === 0 ? " · latest" : ""}` })));
    select.onchange = () => run(async () => show(await fetchBook(select.value)));
    children.push(element("label", { className: "order-book-history" }, [
      `Observation (${history.length.toLocaleString("en")} saved)`, element("span", { className: "chip" }, [select]),
    ]));
  }
  panel.replaceChildren(...children, book);
  show(data.snapshot);
}

async function loadHistory(itemKey) {
  const { realm, faction } = state.realm;
  ++latest.sellers;
  const [data, sellers] = await latestOnly("history", Promise.all([
    api("/api/history", { realm, faction, itemKey }),
    api("/api/sellers", { realm, faction, itemKey, history: 1 }),
  ]));
  state.selected = itemKey;
  for (const row of $("prices").tBodies[0].rows) {
    row.setAttribute("aria-selected", String(row.dataset.itemKey === itemKey));
  }
  $("detail").hidden = false;
  $("detail-title").textContent = itemName(data);
  $("detail-title").className = `quality-${quality(data)}`;
  $("detail-wowhead").href = `${WOWHEAD_ITEM}${itemKey.split(":")[0]}`;
  $("detail-subtitle").textContent = `Price per scan on ${realm} · ${faction}`;
  drawSummary(data.points);
  drawSellers(sellers);
  drawItemChart(itemName(data), data.points);
  drawScans(data.points);
  // Side by side the detail stays in view. Stacked, it sits below the list.
  if (!WIDE.matches) {
    $("detail").scrollIntoView();
  }
}

function weekTrend(days, lows, current) {
  const change = changeOver(seenDays(days, lows), current, WEEK);
  return [sparkline(weekLows(lows, current), change === null ? "none" : direction(change)), trend(change, "over 7 days")];
}

function priceRow(item, market, trends) {
  const open = element("button", {
    className: `quality-${quality(item)}`,
    textContent: itemName(item),
    title: QUALITIES[quality(item)],
    onclick: () => run(() => loadHistory(item.itemKey)),
  });
  const lows = trends && (trends.items[item.itemKey] ?? trends.days.map(() => null));
  const marketCell = element("td", { className: "number market" }, [optionalMoney(item.marketValue, { aligned: true })]);
  if (market.borrowed) {
    marketCell.title =
      item.marketValue > 0 ? `From the full scan of ${when(market.scannedAt)}` : `Not in the full scan of ${when(market.scannedAt)}`;
  }
  const row = element("tr", {}, [
    element("td", { className: "item" }, [open]),
    element("td", { className: "number" }, [money(item.minBuyout, { aligned: true })]),
    marketCell,
    element("td", { className: "number listed", textContent: item.quantity.toLocaleString("en") }),
    element("td", { className: "number week" }, trends ? weekTrend(trends.days, lows, item.minBuyout) : []),
  ]);
  const compare = element("button", {
    className: "compare-item",
    onclick: () => toggleComparison({ itemKey: item.itemKey, name: itemName(item), ...state.realm }),
  });
  compare.dataset.compareKey = item.itemKey;
  compare.setAttribute("aria-label", `Compare ${itemName(item)}`);
  compare.setAttribute("aria-pressed", String(comparisonItems.some((entry) => entry.itemKey === item.itemKey)));
  row.prepend(element("td", { className: "compare-column" }, [compare]));
  row.dataset.itemKey = item.itemKey;
  row.setAttribute("aria-selected", String(item.itemKey === state.selected));
  return row;
}

function drawPrices(data, trends) {
  const { scan, marketScan } = data;
  const market = { borrowed: marketScan !== null && marketScan.id !== scan.id, scannedAt: marketScan?.scannedAt };
  const marketNote = market.borrowed ? ` Market values are from the full scan of ${when(market.scannedAt)}.` : "";
  $("scan").textContent =
    `${SCAN_NAMES[scan.mode]} scan of ${scan.itemCount.toLocaleString("en")} items, ${when(scan.scannedAt)}, by ${scan.scanner}.${marketNote}`;
  $("market-age").textContent = market.borrowed ? age(market.scannedAt) : "";
  $("prices").tBodies[0].replaceChildren(...data.items.map((item) => priceRow(item, market, trends)));
}

async function loadPrices() {
  latest.trends++;
  const { realm, faction } = state.realm;
  const data = await latestOnly(
    "prices",
    api("/api/prices", {
      realm,
      faction,
      q: state.q,
      profession: state.profession,
      kind: state.kind,
      quality: state.quality,
      sort: state.sort,
      order: state.order,
      limit: PAGE,
      offset: state.offset,
    }),
  );
  drawPrices(data, null);
  $("range").textContent =
    data.total === 0 ? "No items match" : `${state.offset + 1}–${state.offset + data.items.length} of ${data.total.toLocaleString("en")}`;
  $("previous").disabled = state.offset === 0;
  $("next").disabled = state.offset + PAGE >= data.total;
  for (const button of document.querySelectorAll("[data-sort]")) {
    const sorted = button.dataset.sort === state.sort;
    button.parentElement.setAttribute("aria-sort", sorted ? `${state.order}ending` : "none");
  }
  if (data.items.length > 0) {
    const items = data.items.map((item) => item.itemKey).join(",");
    drawPrices(data, await latestOnly("trends", api("/api/trends", { realm, faction, items })));
  }
}

async function loadRealms() {
  const [{ realms }, { professions }] = await latestOnly("view", Promise.all([api("/api/realms"), api("/api/professions")]));
  $("profession").replaceChildren(element("option", { value: "", textContent: "All professions" }),
    ...professions.filter((p) => p.materials.length > 0).map((p) => element("option", { value: p.id, textContent: p.name })));
  $("profession").value = state.profession;
  $("item-quality").replaceChildren(element("option", { value: "", textContent: "All qualities" }),
    ...QUALITIES.map((name, index) => element("option", { value: String(index), textContent: name })));
  $("item-quality").value = state.quality;
  state.realms = realms;
  $("realm").replaceChildren(
    ...realms.map((entry, index) => element("option", { value: String(index), textContent: `${entry.realm} · ${entry.faction}` })),
  );
  if (realms.length === 0) {
    showMessage("No scans have been uploaded yet. Scan in game, type /reload, and leave the Goldbook app open. Get the app under Download.");
    return;
  }
  state.realm = realms[0];
  await loadPrices();
}

// Prices load on the first visit to them, so that a page opened on another
// view neither waits for them nor shows their messages.
async function openPrices() {
  if (state.realm === null) {
    await loadRealms();
  }
}

function showPanel(...ids) {
  for (const section of $("account-view").children) {
    section.hidden = !ids.includes(section.id);
  }
}

function classColor(token) {
  return CLASSES.has(token) ? `var(--class-${token.toLowerCase()})` : "";
}

// Spaces inside each part do not break, so that a phone wraps between parts only.
function about(character, { faction = false } = {}) {
  const { level, class: token, realm, updatedAt } = character;
  const kind = token === null ? null : (CLASSES.get(token) ?? `${token[0].toUpperCase()}${token.slice(1).toLowerCase()}`);
  return [
    [level === null ? null : `Level ${level}`, kind].filter(Boolean).join(" "),
    faction ? character.faction : null,
    realm,
    updatedAt === null ? null : `updated ${age(updatedAt)}`,
  ]
    .filter(Boolean)
    .map((part) => part.replaceAll(" ", "\u00a0"))
    .join(" · ");
}

function characterLink(character, current) {
  const route = { view: "character", name: character.name, realm: character.realm };
  const name = element("span", { className: "name", textContent: character.name });
  name.style.color = classColor(character.class);
  const link = element("a", { href: routeHash(route) }, [
    name,
    character.gold === null ? "–" : money(character.gold),
    element("span", { className: "about", textContent: about(character) }),
  ]);
  // "true", not "page": the rail's Characters link already marks the page.
  if (current?.name === character.name && current.realm === character.realm) {
    link.setAttribute("aria-current", "true");
  }
  return element("li", {}, [link]);
}

const groupedId = (id) => `${id.slice(0, 4)}-${id.slice(4)}`;

// The account in the rail, and the purse with the gold of all its characters.
// `account` is null when signed out and undefined while that is not known.
function drawSession(account) {
  // Newer than any answer still on its way.
  latest.session++;
  $("session").hidden = account === undefined;
  $("session").replaceChildren(
    ...(account ? ["Signed in as ", element("strong", { textContent: groupedId(account.id) })] : ["Not signed in"]),
  );
  $("log-in-link").hidden = account !== null;
  $("log-out").hidden = !account;
  const golds = (account?.characters ?? []).map(({ gold }) => gold).filter((gold) => gold !== null);
  $("purse").hidden = golds.length === 0;
  $("purse-gold").replaceChildren(...(golds.length ? [money(golds.reduce((total, gold) => total + gold, 0))] : []));
}

async function loadSession() {
  const account = await latestOnly("session", api("/api/account")).catch((error) => {
    if (error.status === 401) {
      return null;
    }
    throw error;
  });
  drawSession(account);
}

// The roster, with the character on show marked.
function drawAccount(account, current = null) {
  const linked = account.linked?.length ? `, linked with ${account.linked.map(groupedId).join(", ")}` : "";
  $("account-id").textContent = `ID ${groupedId(account.id)}${linked}`;
  $("character-list").replaceChildren(...account.characters.map((character) => characterLink(character, current)));
  drawSession(account);
}

async function loadAccount() {
  const [account, trades] = await latestOnly("view", Promise.all([api("/api/account"), loadTrades()]));
  drawAccount(account);
  drawTrades($("account-trades"), trades, { withCharacter: true });
  $("account-trades").hidden = false;
  showPanel("characters");
}

// Gold is [[time, copper]], oldest first: the balance at the end of the hour
// that starts at each time. An hour without one keeps the balance before it.

// A clock behind the game's still shows the newest balance.
const goldNow = (gold) => Math.max(Date.now() / 1000, gold.at(-1)[0]);

// The balance at the end of the hour that starts at each of `times`, ascending
// and none before the first one on record.
function hourlyGold(gold, times) {
  let next = 0;
  return times.map((time) => {
    while (next < gold.length && gold[next][0] <= time) {
      next++;
    }
    return gold[next - 1][1];
  });
}

// The balance as the hour that starts at `time` begins, else the first one, as
// balanceAt in Ledger.lua has it.
function balanceBy(gold, time) {
  return (gold.findLast(([at]) => at < time) ?? gold[0])[1];
}

// The balance at the end of each UTC day, oldest first: [{ day, copper }] with
// the time the day starts. From the day before the first one on record, which
// has the first balance, so that the first day's change counts.
function dailyGold(gold) {
  const [first, last] = [Math.floor(gold[0][0] / DAY) * DAY - DAY, goldNow(gold)];
  const days = [];
  for (let day = first; day <= last; day += DAY) {
    days.push({ day, copper: balanceBy(gold, day + DAY) });
  }
  return days;
}

// The value and note of a stat: the change, and in the note its share of the
// balance it started from.
function goldTrend(change, base, note) {
  const kind = change > 0 ? "up" : change < 0 ? "down" : "flat";
  const shown = element("span", { className: `trend ${kind}` }, [`${TRENDS[kind].arrow} `, money(Math.abs(change))]);
  const share = change !== 0 && base > 0 ? percentText(Math.abs(change / base) * 100) : null;
  return [shown, [note, share].filter(Boolean).join(" · ")];
}

// As Ledger.Performance has it in game: changes since the end of a UTC day.
// The balance before the first one on record is the first one, so that
// meeting a character is not a gain.
function goldSummary(gold) {
  if (gold.length === 0) {
    return ["Gold", "Today", "7 days", "30 days", "High", "Best day", "Worst day"].map((label) => stat(label, "–"));
  }
  const now = gold.at(-1)[1];
  const today = Math.floor(goldNow(gold) / DAY) * DAY;
  const date = (time) => shortDate(time, "UTC");
  const over = (span) => {
    const base = balanceBy(gold, today - (span - 1) * DAY);
    return goldTrend(now - base, base);
  };
  const days = dailyGold(gold);
  const moves = days.slice(1).map(({ day, copper }, index) => ({ day, change: copper - days[index].copper, base: days[index].copper }));
  const best = moves.reduce((most, move) => (move.change > (most?.change ?? 0) ? move : most), null);
  const worst = moves.reduce((most, move) => (move.change < (most?.change ?? 0) ? move : most), null);
  const [highAt, high] = gold.reduce((most, point) => (point[1] > most[1] ? point : most));
  const dayChange = (move) => (move ? goldTrend(move.change, move.base, date(move.day)) : ["–"]);
  return [
    stat("Gold", money(now)),
    stat("Today", ...over(1)),
    stat("7 days", ...over(7)),
    stat("30 days", ...over(30)),
    stat("High", money(high), date(highAt)),
    stat("Best day", ...dayChange(best)),
    stat("Worst day", ...dayChange(worst)),
  ];
}

// As many labels as keep apart on a phone.
const labelRoom = (width) => Math.min(6, Math.floor(width / 64));
const clock = (seconds) => new Date(seconds * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });

// Local whole hours between start and end, 1 to 12 hours apart, at most about
// `most` of them.
function hourTicks(start, end, most) {
  const step = [1, 2, 3, 4, 6, 12].find((hours) => (end - start) / HOUR / hours <= most);
  const ticks = [];
  const hour = new Date(start * 1000);
  hour.setMinutes(0, 0, 0);
  for (; hour.getTime() / 1000 <= end; hour.setHours(hour.getHours() + 1)) {
    if (hour.getTime() / 1000 >= start && hour.getHours() % step === 0) {
      ticks.push(hour.getTime() / 1000);
    }
  }
  return ticks;
}

// The hours of the day, and at midnight the date.
function hourDates(start, end, width) {
  return hourTicks(start, end, labelRoom(width)).map((time) => [
    time,
    new Date(time * 1000).getHours() === 0 ? shortDate(time) : clock(time),
    "middle",
  ]);
}

function dayDates(start, end, width) {
  return dayTicks(start, end, labelRoom(width)).map((time) => [time, shortDate(time), "middle"]);
}

const SPAN_NAMES = { 1: "day", 7: "7 days", 30: "30 days" };
let goldSpan = 7;

// The balance hour by hour over the last `goldSpan` days, or since the first
// one on record when that is later, with a button per span.
function drawGoldChart(name, gold) {
  for (const button of $("gold-range").querySelectorAll("button")) {
    const span = Number(button.dataset.days);
    button.setAttribute("aria-pressed", String(span === goldSpan));
    button.onclick = () => {
      goldSpan = span;
      drawGoldChart(name, gold);
    };
  }
  const end = Math.floor(goldNow(gold) / HOUR) * HOUR;
  const times = [];
  for (let time = Math.max(end - goldSpan * DAY, gold[0][0]); time <= end; time += HOUR) {
    times.push(time);
  }
  const balances = hourlyGold(gold, times);
  drawChart($("gold-chart"), {
    times,
    series: [{ name: "Gold", color: "var(--series-1)", values: balances, area: true }],
    steps: true,
    heading: (index) => `${when(times[index])}–${clock(times[index] + HOUR)}`,
    label: `${name}: gold over the last ${SPAN_NAMES[goldSpan]}, from ${moneyText(balances[0])} to ${moneyText(balances.at(-1))}. Use the arrow keys to read each hour.`,
    dates: goldSpan === 1 ? hourDates : dayDates,
  });
}

const ACTIONS = { auction: "Auction", vendor: "Vendor", unknown: "No price" };
const HOLDING_COLUMNS = [
  ["Item", ""],
  ["Count", "number count"],
  ["Action", "action"],
  ["Post", "number amount post"],
  ["Vendor", "number amount vendor"],
  ["Value", "number amount"],
];

function holdingRow(row) {
  return element("tr", {}, [
    element("td", { className: `quality-${quality(row)}`, textContent: row.name ?? `Item ${row.key}`, title: QUALITIES[quality(row)] }),
    element("td", { className: "number", textContent: row.count.toLocaleString("en") }),
    element("td", { className: "action", textContent: ACTIONS[row.action] }),
    element("td", { className: "number post" }, [optionalMoney(row.post, { aligned: true })]),
    element("td", { className: "number vendor" }, [optionalMoney(row.vendor, { aligned: true })]),
    element("td", { className: "number" }, [optionalMoney(row.value, { aligned: true })]),
  ]);
}

function holdings(title, snapshot, seen, missing) {
  const heading = element("h3", { textContent: title });
  if (snapshot === null) {
    return element("div", { className: "panel" }, [heading, element("p", { className: "muted", textContent: missing })]);
  }
  const table =
    snapshot.rows.length === 0
      ? element("p", { textContent: "No unbound items." })
      : element("table", { className: "holding" }, [
          element("thead", {}, [
            element("tr", {}, HOLDING_COLUMNS.map(([text, className]) => element("th", { scope: "col", className, textContent: text }))),
          ]),
          element("tbody", {}, snapshot.rows.map(holdingRow)),
        ]);
  return element("div", { className: "panel" }, [
    heading,
    element("p", { className: "muted" }, ["Total ", money(snapshot.total), ` · ${seen} ${age(snapshot.at)}`]),
    table,
  ]);
}

// Trades as the addon booked them: auction house sales ("sell") and
// purchases ("buy") from the mailbox, and sales to vendors ("vendor"):
// [{ name, realm, at, side, item, itemKey, quality, count, price, fee }],
// newest first. `price` is the whole stack's and `fee` the auction house cut.
const NEWEST_TRADES = 20;
const SIDES = { sell: "Sold", buy: "Bought", vendor: "Vendor" };

// What a trade added to the gold: the sale less the cut, or minus the price.
const tradeNet = (trade) => (trade.side === "buy" ? -trade.price : trade.price - trade.fee);

// A gain in green with a plus, a loss in red with a minus.
function signedMoney(copper, options) {
  if (copper === 0) {
    return money(0, options);
  }
  const kind = copper > 0 ? "up" : "down";
  return element("span", { className: `trend ${kind}` }, [copper > 0 ? "+" : "−", money(Math.abs(copper), options)]);
}

// One row per item, the most recently traded first. Sales count at auction
// and to vendors. Profit or loss is realized on the units both bought and
// sold, at the average sale less the average cost, so an item never bought,
// or never sold, has none.
function tradedItems(trades) {
  const items = new Map();
  for (const trade of trades) {
    const item = items.get(trade.item) ?? { name: trade.item, quality: null, bought: 0, cost: 0, sold: 0, proceeds: 0 };
    item.quality ??= trade.quality;
    if (trade.side === "buy") {
      item.bought += trade.count;
      item.cost += trade.price;
    } else {
      item.sold += trade.count;
      item.proceeds += trade.price - trade.fee;
    }
    items.set(trade.item, item);
  }
  return [...items.values()].map((item) => {
    const averageCost = item.bought > 0 ? item.cost / item.bought : null;
    const averageSale = item.sold > 0 ? item.proceeds / item.sold : null;
    const matched = Math.min(item.bought, item.sold);
    return {
      ...item,
      averageCost,
      averageSale,
      profit: matched > 0 ? Math.round(matched * (averageSale - averageCost)) : null,
    };
  });
}

function tradeTotals(trades, items) {
  const sold = trades.filter(({ side }) => side === "sell");
  const vendored = trades.filter(({ side }) => side === "vendor");
  const bought = trades.filter(({ side }) => side === "buy");
  const count = (list) => `${list.length} ${list.length === 1 ? "trade" : "trades"}`;
  const sum = (list, value) => list.reduce((total, trade) => total + value(trade), 0);
  const realized = items.filter(({ profit }) => profit !== null);
  return [
    stat("Auction sales", money(sum(sold, ({ price }) => price)), count(sold)),
    stat("Vendor sales", money(sum(vendored, ({ price }) => price)), count(vendored)),
    stat("Purchases", money(sum(bought, ({ price }) => price)), count(bought)),
    stat("Auction cut", money(sum(sold, ({ fee }) => fee))),
    stat("Net", signedMoney(sum(trades, tradeNet)), "sales less cut and purchases"),
    stat(
      "Profit or loss",
      realized.length > 0 ? signedMoney(sum(realized, ({ profit }) => profit)) : "–",
      "on items both bought and sold",
    ),
  ];
}

function tradedItemCell(name, itemQuality) {
  const quality = QUALITIES[itemQuality] ? itemQuality : 1;
  return element("td", { className: `item-name quality-${quality}`, textContent: name, title: QUALITIES[quality] });
}

function ledgerTable(className, columns, rows) {
  return element("table", { className }, [
    element("thead", {}, [element("tr", {}, columns.map(([text, name]) => element("th", { scope: "col", className: name, textContent: text })))]),
    element("tbody", {}, rows),
  ]);
}

function tradedItemsTable(items) {
  const optional = (copper) => (copper === null ? "–" : money(Math.round(copper), { aligned: true }));
  return ledgerTable(
    "traded-items",
    [
      ["Item", ""],
      ["Bought", "number"],
      ["Average cost", "number average"],
      ["Sold", "number"],
      ["Average sale", "number average"],
      ["Profit or loss", "number"],
    ],
    items.map((item) =>
      element("tr", {}, [
        tradedItemCell(item.name, item.quality),
        element("td", { className: "number", textContent: item.bought.toLocaleString("en") }),
        element("td", { className: "number average" }, [optional(item.averageCost)]),
        element("td", { className: "number", textContent: item.sold.toLocaleString("en") }),
        element("td", { className: "number average" }, [optional(item.averageSale)]),
        element("td", { className: "number" }, [item.profit === null ? "–" : signedMoney(item.profit, { aligned: true })]),
      ]),
    ),
  );
}

function tradesTable(trades, withCharacter) {
  const rows = trades.map((trade, index) => {
    const character = element("a", {
      href: routeHash({ view: "character", name: trade.name, realm: trade.realm }),
      textContent: trade.name,
    });
    const row = element("tr", {}, [
      element("td", { className: "when", textContent: when(trade.at) }),
      ...(withCharacter ? [element("td", { className: "character" }, [character])] : []),
      element("td", { className: `side ${trade.side}`, textContent: SIDES[trade.side] }),
      tradedItemCell(trade.item, trade.quality),
      element("td", { className: "number", textContent: trade.count.toLocaleString("en") }),
      element("td", { className: "number each" }, [money(Math.round(trade.price / trade.count), { aligned: true })]),
      element("td", { className: "number" }, [signedMoney(tradeNet(trade), { aligned: true })]),
    ]);
    row.hidden = index >= NEWEST_TRADES;
    return row;
  });
  return ledgerTable(
    "trade-list",
    [
      ["When", "when"],
      ...(withCharacter ? [["Character", "character"]] : []),
      ["", "side"],
      ["Item", ""],
      ["Qty", "number"],
      ["Each", "number each"],
      ["Net", "number"],
    ],
    rows,
  );
}

// The ledger of `trades` into `container`: totals, each item's profit, and the
// trades themselves, the newest NEWEST_TRADES until the rest are asked for.
function drawTrades(container, trades, { withCharacter = false } = {}) {
  const heading = element("h3", { textContent: "Trades" });
  if (trades === null) {
    container.replaceChildren();
    return;
  }
  if (trades.length === 0) {
    container.replaceChildren(
      heading,
      element("p", {
        className: "muted",
        textContent: "No auction sales or purchases yet. Open a mailbox in game to book them, then /reload or log out.",
      }),
    );
    return;
  }
  const items = tradedItems(trades);
  const list = tradesTable(trades, withCharacter);
  const toggle = element("button", { className: "disclosure", type: "button", hidden: trades.length <= NEWEST_TRADES });
  toggle.setAttribute("aria-expanded", "false");
  toggle.textContent = `All ${trades.length} trades`;
  toggle.onclick = () => {
    const expanded = toggle.getAttribute("aria-expanded") !== "true";
    toggle.setAttribute("aria-expanded", String(expanded));
    toggle.textContent = expanded ? `Newest ${NEWEST_TRADES} trades` : `All ${trades.length} trades`;
    [...list.tBodies[0].rows].forEach((row, index) => {
      row.hidden = !expanded && index >= NEWEST_TRADES;
    });
  };
  container.replaceChildren(
    heading,
    element("dl", { className: "summary" }, tradeTotals(trades, items)),
    element("h4", { textContent: "By item" }),
    tradedItemsTable(items),
    element("h4", { textContent: "History" }),
    list,
    toggle,
  );
}

// A server from before trades answers 404; it has none to show.
function loadTrades(parameters = {}) {
  return api("/api/trades", parameters).then(
    ({ trades }) => trades,
    (error) => {
      if (error.status === 404 && error.message === "not found") {
        return null;
      }
      throw error;
    },
  );
}

async function loadCharacter({ name, realm }) {
  const [character, trades, account] = await latestOnly(
    "view",
    Promise.all([
      api("/api/character", { name, realm }).catch((error) => {
        if (error.status === 404) {
          return null;
        }
        throw error;
      }),
      loadTrades({ name, realm }),
      api("/api/account"),
    ]),
  );
  // The roster leads to the other characters; the trades of all of them stay on the account's page.
  drawAccount(account, { name, realm });
  $("account-trades").hidden = true;
  if (character === null) {
    $("no-character-text").textContent = `No character ${name} on ${realm} in this account.`;
    showPanel("characters", "no-character");
    return;
  }
  showPanel("characters", "character");
  $("character-title").textContent = character.name;
  $("character-title").style.color = classColor(character.class);
  $("character-about").textContent = about(character, { faction: true });
  $("gold-summary").replaceChildren(...goldSummary(character.gold));
  $("gold-history").hidden = character.gold.length === 0;
  if (character.gold.length > 0) {
    drawGoldChart(character.name, character.gold);
  }
  $("holdings").replaceChildren(
    holdings("Bags", character.bags, "saved", "Log out or /reload in game to save the bags."),
    holdings("Bank", character.bank, "seen", "Open the bank once in game to see it here."),
  );
  drawTrades($("character-trades"), trades);
}

function loginError(error) {
  if (error.status === 401 || error.status === 403) {
    return "Wrong ID or key.";
  }
  if (error.status === 429) {
    return `${error.message[0].toUpperCase()}${error.message.slice(1)}.`;
  }
  return `Something went wrong: ${error.message}`;
}

// "#characters/<name>-<realm>" with each part URI-encoded. Names never
// contain "-", realms can.
function parseRoute(hash) {
  if (hash === "#characters" || hash === "#download") {
    return { view: hash.slice(1) };
  }
  const [, name, realm] = /^#characters\/([^-]+)-(.+)$/.exec(hash) ?? [];
  if (name) {
    try {
      return { view: "character", name: decodeURIComponent(name), realm: decodeURIComponent(realm) };
    } catch {
      // A broken escape is as unknown as any other hash.
    }
  }
  return { view: "prices" };
}

function routeHash(route) {
  return route.view === "character"
    ? `#characters/${encodeURIComponent(route.name)}-${encodeURIComponent(route.realm)}`
    : `#${route.view}`;
}

async function run(action) {
  try {
    showMessage("");
    await action();
  } catch (error) {
    if (error.status === 401) {
      drawSession(null);
      showPanel("login");
    } else if (error !== STALE) {
      showMessage(`Something went wrong: ${error.message}`);
    }
  }
}

let comparisonRequest = 0;
let comparisonItems = [];
const COMPARISON_COLORS = [1, 2, 3, 4, 5, 6].map((index) => `var(--compare-${index})`);

function updateCompareButtons() {
  for (const button of document.querySelectorAll("[data-compare-key]")) {
    button.setAttribute("aria-pressed", String(comparisonItems.some((item) => item.itemKey === button.dataset.compareKey)));
  }
}

function toggleComparison(item) {
  const selected = comparisonItems.some((entry) => entry.itemKey === item.itemKey);
  if (selected) comparisonItems = comparisonItems.filter((entry) => entry.itemKey !== item.itemKey);
  else if (comparisonItems.length < 6) comparisonItems.push(item);
  else {
    showMessage("Compare up to six items. Remove an item from the comparison to add another.");
    return;
  }
  updateCompareButtons();
  run(loadComparison);
}

async function loadComparison() {
  const request = ++comparisonRequest;
  const items = [...comparisonItems];
  $("comparison").hidden = false;
  $("comparison-chart").hidden = true;
  $("comparison-status").textContent = items.length < 2 ? "Use Compare on another item to add it to this graph." : "";
  $("comparison-legend").replaceChildren(...items.map((item, index) => {
    const key = element("span", { className: "key" });
    key.style.background = COMPARISON_COLORS[index];
    const remove = element("button", {
      className: "button comparison-chip",
      onclick: () => toggleComparison(item),
    }, [key, item.name, " ×"]);
    remove.setAttribute("aria-label", `Remove ${item.name} from comparison`);
    return remove;
  }));
  $("comparison-items").textContent = items.length ? "Loading latest observations…" : "Use an item’s Compare button to start.";
  const results = await Promise.allSettled(items.map((item) =>
    api("/api/history", { realm: item.realm, faction: item.faction, itemKey: item.itemKey })));
  if (request !== comparisonRequest) return;
  if (!items.length) return;
  const histories = results.flatMap((result, index) => {
    if (result.status !== "fulfilled") return [];
    const points = result.value.points.filter((point) => point.minBuyout > 0);
    return points.length ? [{ ...items[index], points, color: COMPARISON_COLORS[index] }] : [];
  });
  if (histories.length) {
    const times = [...new Set(histories.flatMap((item) => item.points.map((point) => point.scannedAt)))].sort((a, b) => a - b);
    const series = histories.map((item) => {
      const prices = new Map(item.points.map((point) => [point.scannedAt, point.minBuyout]));
      return { name: item.name, color: item.color, values: times.map((time) => prices.get(time) ?? null) };
    });
    $("comparison-chart").hidden = false;
    drawChart($("comparison-chart"), {
      times, series, heading: (index) => when(times[index]), dates: scanDates,
      label: `Minimum buyout per unit for ${histories.map((item) => item.name).join(", ")} on a shared price scale. Use arrow keys to inspect recorded scans.`,
    });
  }
  if (histories.length < items.length) {
    $("comparison-status").textContent = "Some items have no available price history. Their lines are omitted; refresh to retry.";
  }
  const headings = ["Item", "Min buyout", "Market value", "7 days", "Listed", "Last scan"];
  const table = element("table", { className: "comparison-table" }, [
    element("thead", {}, [element("tr", {}, headings.map((text, index) => {
      const heading = element("th", { textContent: text, className: index > 0 && index < 5 ? "number" : "" });
      heading.scope = "col";
      return heading;
    }))]),
    element("tbody", {}, results.map((result, index) => {
      const item = items[index];
      const row = element("tr", {}, [element("td", {}, [
        element("button", { textContent: item.name, onclick: () => run(() => loadHistory(item.itemKey)) }),
      ])]);
      if (result.status !== "fulfilled" || !result.value.points.length) {
        row.append(element("td", { colSpan: 5, textContent: "History unavailable. Refresh to retry." }));
        return row;
      }
      const points = result.value.points;
      const now = points.at(-1);
      const market = points.findLast((point) => point.marketValue > 0);
      row.append(
        element("td", { className: "number" }, [money(now.minBuyout)]),
        element("td", { className: "number", title: market ? `Market value scanned ${when(market.scannedAt)}` : "No market value" }, [market ? money(market.marketValue) : "–"]),
        element("td", { className: "number" }, [trend(changeOver(dailyLows(points), now.minBuyout, 7), "over 7 days")]),
        element("td", { className: "number", textContent: now.quantity.toLocaleString("en") }),
        element("td", { textContent: age(now.scannedAt), title: when(now.scannedAt) }),
      );
      return row;
    })),
  ]);
  $("comparison-items").replaceChildren(table);
}
$("close-comparison").onclick = () => { comparisonRequest++; $("comparison").hidden = true; };
$("refresh-comparison").onclick = () => run(loadComparison);

function firstPage() {
  state.offset = 0;
  return run(loadPrices);
}

$("realm").onchange = (event) => {
  state.realm = state.realms[Number(event.target.value)];
  comparisonRequest++;
  comparisonItems = [];
  $("comparison").hidden = true;
  state.selected = null;
  // A history still on its way belongs to the realm that was just left.
  latest.history++;
  $("detail").hidden = true;
  firstPage();
};

function filterChanged() {
  state.selected = null;
  latest.history++;
  $("detail").hidden = true;
  firstPage();
}
$("profession").onchange = (event) => {
  state.profession = event.target.value;
  state.kind = state.profession ? "materials" : "all";
  $("item-kind").value = state.kind;
  filterChanged();
};
$("item-kind").onchange = (event) => { state.kind = event.target.value; filterChanged(); };
$("item-quality").onchange = (event) => { state.quality = event.target.value; filterChanged(); };
$("clear-filters").onclick = () => {
  clearTimeout(searchTimer);
  state.q = state.profession = state.quality = "";
  state.kind = "all";
  $("search").value = $("profession").value = $("item-quality").value = "";
  $("item-kind").value = "all";
  filterChanged();
};

let searchTimer;
$("search").oninput = (event) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    state.q = event.target.value.trim();
    firstPage();
  }, 250);
};

for (const button of document.querySelectorAll("[data-sort]")) {
  button.onclick = () => {
    const { sort } = button.dataset;
    if (state.sort === sort) {
      state.order = state.order === "asc" ? "desc" : "asc";
    } else {
      state.sort = sort;
      state.order = sort === "name" ? "asc" : "desc";
    }
    firstPage();
  };
}

$("previous").onclick = () => {
  state.offset = Math.max(0, state.offset - PAGE);
  run(loadPrices);
};
$("next").onclick = () => {
  state.offset += PAGE;
  run(loadPrices);
};

$("show-key").onclick = () => {
  const shown = $("show-key").getAttribute("aria-pressed") !== "true";
  $("show-key").setAttribute("aria-pressed", String(shown));
  $("login-key").type = shown ? "text" : "password";
};

$("log-out").onclick = () =>
  run(async () => {
    await api("/api/logout", {}, {});
    drawSession(null);
    render();
  });

$("login-form").onsubmit = async (event) => {
  event.preventDefault();
  $("login-error").textContent = "";
  $("log-in").disabled = true;
  try {
    await api("/api/login", {}, { id: $("login-id").value, key: $("login-key").value });
    $("login-key").value = "";
    $("login-key").type = "password";
    $("show-key").setAttribute("aria-pressed", "false");
    render();
  } catch (error) {
    $("login-error").textContent = loginError(error);
  } finally {
    $("log-in").disabled = false;
  }
};

$("link-form").onsubmit = async (event) => {
  event.preventDefault();
  $("link-error").textContent = "";
  $("link-in").disabled = true;
  try {
    await api("/api/link", {}, { id: $("link-id").value, key: $("link-key").value });
    $("link-form").reset();
    $("link-form").closest("details").open = false;
    render();
  } catch (error) {
    // A session that ran out shows the login, as any other view does.
    if (error.status === 401) {
      drawSession(null);
      showPanel("login");
    } else {
      $("link-error").textContent = loginError(error);
    }
  } finally {
    $("link-in").disabled = false;
  }
};

// The keys are the targets of the update feed's latest.json.
const PLATFORMS = {
  "darwin-aarch64": {
    name: "macOS",
    note: () =>
      "For Macs with Apple silicon. Open the download to unpack Goldbook.app and move it to Applications. The first time, right-click it and choose Open.",
  },
  "windows-x86_64": { name: "Windows", note: () => "For 64-bit Windows. Run the setup." },
  "linux-x86_64-deb": { name: "Ubuntu or Debian", note: (file) => `Install it with sudo apt install ./${file}` },
  "linux-x86_64-rpm": { name: "Fedora", note: (file) => `Install it with sudo dnf install ./${file}` },
};

// A phone or a tablet gets no guess: the app is for the computer the game runs on.
function detectPlatform() {
  const agent = navigator.userAgent;
  const platform = navigator.userAgentData?.platform ?? navigator.platform ?? "";
  if (/iPhone|iPad|Android|CrOS/.test(agent) || navigator.maxTouchPoints > 1) {
    return null;
  }
  if (/Mac/.test(platform) || /Macintosh/.test(agent)) {
    return "darwin-aarch64";
  }
  if (/Win/.test(platform)) {
    return "windows-x86_64";
  }
  if (/Linux/.test(platform) || /Linux/.test(agent)) {
    return /Fedora|Red Hat|CentOS|Rocky|AlmaLinux|SUSE/i.test(agent) ? "linux-x86_64-rpm" : "linux-x86_64-deb";
  }
  return null;
}

// release is undefined while loading and null when this server has no update feed.
const download = { platform: detectPlatform(), release: undefined };

function drawDownload() {
  const { platform, release } = download;
  for (const button of document.querySelectorAll("#platforms [data-platform]")) {
    button.setAttribute("aria-pressed", String(button.dataset.platform === platform));
  }
  const feedUrl = release?.platforms?.[platform]?.url;
  const link = $("download-link");
  link.hidden = !feedUrl;
  let note;
  if (release === undefined) {
    note = "Looking for the newest version…";
  } else if (release === null) {
    note = "This server has no downloads.";
  } else if (!platform) {
    note = "Choose your system.";
  } else if (!feedUrl) {
    note = `There is no download for ${PLATFORMS[platform].name} yet.`;
  } else {
    // From this server, whichever address it was opened at, so that the
    // browser keeps the file name without the feed's platform prefix.
    const [, path] = /\/updates\/(.+)$/.exec(feedUrl) ?? [];
    const file = decodeURIComponent(feedUrl.split("/").pop()).replace(`${platform}-`, "");
    link.href = path ? new URL(`updates/${path}`, location.href).href : feedUrl;
    link.download = file;
    link.textContent = `Download for ${PLATFORMS[platform].name}`;
    note = `Version ${release.version}. ${PLATFORMS[platform].note(file)}`;
  }
  $("download-note").textContent = note;
}

for (const button of document.querySelectorAll("#platforms [data-platform]")) {
  button.onclick = () => {
    download.platform = button.dataset.platform;
    drawDownload();
  };
}

async function loadDownload() {
  if (!download.release) {
    download.release = undefined;
    drawDownload();
    // Revalidated, so that a new release shows at once.
    const feed = fetch(new URL("updates/latest.json", location.href), { cache: "no-cache" }).then((response) =>
      response.ok ? response.json() : null,
    );
    download.release = await latestOnly("view", feed).catch((error) => {
      if (error === STALE) {
        throw error;
      }
      return null;
    });
  }
  drawDownload();
}

const VIEWS = {
  prices: { shows: ["realm-picker", "price-tools", "prices-view"], link: "#prices", load: openPrices },
  characters: { shows: ["account-view"], link: "#characters", load: loadAccount },
  character: { shows: ["account-view"], link: "#characters", load: loadCharacter },
  download: { shows: ["download-view"], link: "#download", load: loadDownload },
};

function render() {
  const route = parseRoute(location.hash);
  const view = VIEWS[route.view];
  for (const id of Object.values(VIEWS).flatMap(({ shows }) => shows)) {
    $(id).hidden = !view.shows.includes(id);
  }
  for (const link of document.querySelectorAll(".views a")) {
    if (link.getAttribute("href") === view.link) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }
  // An answer still on its way belongs to the view that was just left.
  latest.view++;
  run(() => view.load(route));
}

// Marks the theme on show; theme.js applied a stored choice before the first paint.
function drawTheme() {
  for (const button of document.querySelectorAll("[data-theme-choice]")) {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === document.documentElement.dataset.theme));
  }
}

for (const button of document.querySelectorAll("[data-theme-choice]")) {
  button.onclick = () => {
    document.documentElement.dataset.theme = button.dataset.themeChoice;
    try {
      localStorage.setItem("goldbook-theme", button.dataset.themeChoice);
    } catch {
      // Without storage the choice lasts until the page is left.
    }
    drawTheme();
  };
}

window.onhashchange = render;
drawTheme();
// The rail shows the session on every view. A failure leaves it blank; the view reports its own.
loadSession().catch(() => {});
render();
