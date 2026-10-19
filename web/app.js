const SVG = "http://www.w3.org/2000/svg";
const PAGE = 50;
const HOUR = 3600;
const DAY = 24 * HOUR;
const QUALITIES = ["Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom"];
// The qualities the auction house lists: legendaries are bound, and Classic
// has no artifacts or heirlooms.
const LISTED_QUALITIES = QUALITIES.slice(0, 5);
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
const SPARK = { width: 64, height: 16, pad: 2 };
const WEEK = 7;
const NEWEST_SCANS = 5;
const WOWHEAD_ITEM = "https://www.wowhead.com/forever/item=";
const WIDE = matchMedia("(min-width: 1240px)");

const state = { realms: [], realm: null, q: "", profession: "", kind: "all", quality: "", sort: "name", order: "asc", offset: 0, selected: null, character: "" };
const latest = { prices: 0, trends: 0, history: 0, sellers: 0, view: 0, session: 0, list: 0, listTrends: 0, pane: 0 };
// The account in the rail: null when signed out, undefined while that is not known.
const session = { account: undefined };
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

// As the addon's Codec.Money writes it: every unit from the largest down, the
// ones below it as two digits, so that "12g 00s 00c" ends where the rows
// around it end.
function money(copper) {
  const amounts = coins(copper);
  const largest = copper === 0 ? COINS.length - 1 : amounts.findIndex(({ amount }) => amount > 0);
  const parts = amounts.slice(largest).flatMap(({ unit, amount }, index) => [
    element("span", { className: `coin ${unit}` }, [
      index > 0 ? String(amount).padStart(2, "0") : amount.toLocaleString("en"),
      element("span", { className: "unit", textContent: unit }),
    ]),
    " ",
  ]);
  return element("span", { className: "money" }, parts.slice(0, -1));
}

const optionalMoney = (copper) => (copper > 0 ? money(copper) : "–");
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

// As the addon's Codec.Age writes it in a table: "40m ago", "3h ago", "2d ago".
function ago(seconds) {
  const elapsed = Math.max(0, Date.now() / 1000 - seconds);
  const unit = [[DAY, "d"], [HOUR, "h"], [60, "m"]].find(([size]) => elapsed >= size);
  return unit ? `${Math.floor(elapsed / unit[0])}${unit[1]} ago` : "just now";
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

// As the addon draws it: a line through the days with a price, each at its
// place in the week, from the lowest to the highest of them; green when the
// newest is at least the oldest, else red. A single day draws nothing.
function sparkline(lows, label) {
  const points = lows.flatMap((low, index) => (low === null ? [] : [[index, low]]));
  const rising = points.length > 1 && points.at(-1)[1] >= points[0][1];
  const root = svg("svg", { class: `spark ${rising ? "up" : "down"}`, viewBox: `0 0 ${SPARK.width} ${SPARK.height}`, role: "img" });
  root.setAttribute("aria-label", label);
  if (points.length < 2) {
    return root;
  }
  const values = points.map(([, low]) => low);
  const [low, high] = [Math.min(...values), Math.max(...values)];
  const x = (index) => SPARK.pad + (index / (lows.length - 1)) * (SPARK.width - 2 * SPARK.pad);
  const y = (value) => SPARK.height - SPARK.pad - (high > low ? (value - low) / (high - low) : 0.5) * (SPARK.height - 2 * SPARK.pad);
  const path = points.map(([index, value], position) => `${position ? "L" : "M"}${x(index).toFixed(1)} ${y(value).toFixed(1)}`).join("");
  root.append(svg("path", { class: "spark-line", d: path }));
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

  // A rule up the plot at each date, as the addon's charts have.
  for (const [time, text, anchor] of dates(start, end, right - CHART.left)) {
    root.prepend(svg("line", { class: "grid", x1: x(time), x2: x(time), y1: top, y2: bottom }));
    root.append(
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

// A card as the addon draws one: its label, its figure, and a line under
// them, which is text or nodes.
function stat(label, value, note) {
  const detail = note ? [element("dd", { className: "note", title: typeof note === "string" ? note : "" }, [note].flat())] : [];
  return element("div", { className: "stat" }, [element("dt", { textContent: label }), element("dd", { className: "figure" }, [value]), ...detail]);
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
        element("td", { className: "number" }, [money(point.minBuyout)]),
        element("td", { className: "number" }, [optionalMoney(point.marketValue)]),
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

function drawSellers(data, place) {
  const panel = $("sellers");
  const title = element("h3", { id: "sellers-title", textContent: "Order book" });
  if (!data.snapshot) {
    panel.replaceChildren(title, element("p", { className: "muted", textContent:
      "No order book has been uploaded for this item. With the updated addon, run /gb scan full at the auction house, then /reload with the desktop app open. A complete search for this item also records its book." }));
    return;
  }
  const { realm, faction } = place;
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

async function loadHistory(itemKey, place = state.realm, name = undefined) {
  const { realm, faction } = place;
  ++latest.sellers;
  const [data, sellers] = await latestOnly("history", Promise.all([
    api("/api/history", { realm, faction, itemKey }),
    api("/api/sellers", { realm, faction, itemKey, history: 1 }),
  ]));
  const inPane = !$("item-pane").hidden;
  if (!inPane) {
    state.selected = itemKey;
    for (const row of $("prices-table").tBodies[0].rows) {
      row.setAttribute("aria-selected", String(row.dataset.itemKey === itemKey));
    }
  }
  const named = { name, ...data };
  $("detail").hidden = false;
  $("detail-title").textContent = itemName(named);
  $("detail-title").className = `quality-${quality(named)}`;
  $("detail-wowhead").href = `${WOWHEAD_ITEM}${itemKey.split(":")[0]}`;
  const item = { itemKey, name: itemName(named), ...place };
  $("detail-compare").dataset.compareKey = itemKey;
  $("detail-compare").onclick = () => toggleComparison(item);
  updateCompareButtons();
  const seen = data.points.length > 0;
  $("detail-subtitle").textContent = seen
    ? `Price per scan on ${realm} · ${faction}`
    : `No scan on ${realm} · ${faction} has listed this item.`;
  for (const id of ["summary", "legend", "chart", "sellers", "history"]) {
    $(id).hidden = !seen;
  }
  $("all-scans").hidden ||= !seen;
  if (seen) {
    drawSummary(data.points);
    drawSellers(sellers, place);
    drawItemChart(itemName(named), data.points);
    drawScans(data.points);
  }
  // Side by side the detail stays in view. Stacked, it sits below the list.
  if (!WIDE.matches && !inPane) {
    $("detail").scrollIntoView();
  }
}

// The week's sparkline, which names the change over it to a screen reader and
// on hover. Without the price now, the newest day seen ends it.
function weekTrend(days, lows, current = null) {
  const seen = seenDays(days, lows);
  const change = seen.length ? changeOver(seen, current ?? seen.at(-1).low, WEEK) : null;
  const text = change === null ? "Not enough history" : `${TRENDS[direction(change)].word} ${percentText(Math.abs(change))} over 7 days`;
  const line = sparkline(current === null ? lows.slice(-(WEEK + 1)) : weekLows(lows, current), text);
  line.append(svg("title", {}, text));
  return line;
}

function priceRow(item, market, trends) {
  const open = element("button", {
    className: `quality-${quality(item)}`,
    textContent: itemName(item),
    title: QUALITIES[quality(item)],
    onclick: () => run(() => loadHistory(item.itemKey)),
  });
  const lows = trends && (trends.items[item.itemKey] ?? trends.days.map(() => null));
  const marketCell = element("td", { className: "number market" }, [item.marketValue > 0 ? money(item.marketValue) : ""]);
  if (market.borrowed) {
    marketCell.title =
      item.marketValue > 0 ? `From the full scan of ${when(market.scannedAt)}` : `Not in the full scan of ${when(market.scannedAt)}`;
  }
  const row = element("tr", {}, [
    element("td", { className: "item" }, [open]),
    element("td", { className: "number" }, [money(item.minBuyout)]),
    marketCell,
    element("td", { className: "spark-column" }, trends ? [weekTrend(trends.days, lows, item.minBuyout)] : []),
    element("td", { className: "number listed", textContent: item.quantity.toLocaleString("en") }),
    element("td", { className: "number seen", textContent: ago(item.scannedAt ?? market.seen), title: when(item.scannedAt ?? market.seen) }),
  ]);
  row.dataset.itemKey = item.itemKey;
  row.setAttribute("aria-selected", String(item.itemKey === state.selected));
  return row;
}

// The line under a table, as the addon's status line: which rows of how many
// when they take more than a page, and a hint, joined by a middle dot. With
// `go`, Previous and Next turn the page.
function drawPager(nav, { offset = 0, count, total, hint = "", none = "", go = null }) {
  const range = total > count ? `${offset + 1}–${offset + count} of ${total.toLocaleString("en")}` : "";
  const text = total === 0 ? none : [range, hint].filter(Boolean).join(" · ");
  const turn = (to) => () => go(Math.max(0, to));
  nav.replaceChildren(
    element("span", { className: "range", textContent: text }),
    ...(go && total > count
      ? [
          element("button", { type: "button", textContent: "Previous", disabled: offset === 0, onclick: turn(offset - PAGE) }),
          element("button", { type: "button", textContent: "Next", disabled: offset + PAGE >= total, onclick: turn(offset + PAGE) }),
        ]
      : []),
  );
}

// Each of a table's columns as { label, className, cell(row), value(row) }:
// a column with a value sorts by it when its header is clicked, and the one
// `sort` names is marked, as the addon marks it, with an arrow.
function drawTable(table, columns, rows, { sort = null, onSort = null, empty = "" } = {}) {
  const head = columns.map(({ label, className = "", value }, index) => {
    const cell = element("th", { scope: "col", className });
    if (sort?.column === index) {
      cell.setAttribute("aria-sort", sort.descending ? "descending" : "ascending");
    }
    cell.append(value && onSort ? element("button", { type: "button", textContent: label, onclick: () => onSort(index) }) : label);
    return cell;
  });
  const body = rows.map((row) =>
    element("tr", {}, columns.map(({ className = "", cell }) => element("td", { className }, [cell(row)].flat()))));
  table.replaceChildren(
    element("thead", {}, [element("tr", {}, head)]),
    element("tbody", {}, body.length || !empty ? body : [element("tr", {}, [element("td", { colSpan: columns.length, className: "muted", textContent: empty })])]),
  );
  return body;
}

// Rows in the order of a column's value, names breaking ties; text sorts A to
// Z and anything else highest first, each the other way round when asked.
function sorted(rows, value, descending) {
  const name = (row) => row.name ?? "";
  return rows.toSorted((a, b) => {
    const [left, right] = [value(a), value(b)];
    const order = typeof left === "string" ? left.localeCompare(right) : (left ?? -Infinity) - (right ?? -Infinity);
    return (descending ? -order : order) || name(a).localeCompare(name(b));
  });
}

// A click on the column sorted already turns its order; another column
// starts with text A to Z and anything else highest first.
function nextSort(sort, column, columns, sample) {
  if (sort?.column === column) {
    return { column, descending: !sort.descending };
  }
  return { column, descending: sample === undefined || typeof columns[column].value(sample) !== "string" };
}

function drawPrices(data, trends) {
  const { scan, marketScan } = data;
  const market = { borrowed: marketScan !== null && marketScan.id !== scan.id, scannedAt: marketScan?.scannedAt, seen: scan.scannedAt };
  const where = `${state.realm.realm}-${state.realm.faction}`;
  $("scan").textContent = `${plural(data.total, "item")} scanned on ${where}${market.borrowed ? ` · market values from the full scan of ${when(market.scannedAt)}` : ""}`;
  $("prices-table").tBodies[0].replaceChildren(...data.items.map((item) => priceRow(item, market, trends)));
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
  drawPager($("prices-view").querySelector(".pager"), {
    offset: state.offset,
    count: data.items.length,
    total: data.total,
    hint: "Click an item to see its history",
    none: "No items match",
    go: (offset) => {
      state.offset = offset;
      run(loadPrices);
    },
  });
  for (const button of document.querySelectorAll("[data-sort]")) {
    const sorted = button.dataset.sort === state.sort;
    button.parentElement.setAttribute("aria-sort", sorted ? `${state.order}ending` : "none");
  }
  if (data.items.length > 0) {
    const items = data.items.map((item) => item.itemKey).join(",");
    drawPrices(data, await latestOnly("trends", api("/api/trends", { realm, faction, items })));
  }
}

// The realms and the filters' choices, once. False when no realm has a scan.
async function ensureRealms() {
  if (state.realm !== null) {
    return true;
  }
  const [{ realms }] = await latestOnly("view", Promise.all([api("/api/realms"), loadProfessions()]));
  state.realms = realms;
  $("realm").replaceChildren(
    ...realms.map((entry, index) => element("option", { value: String(index), textContent: `${entry.realm} · ${entry.faction}` })),
  );
  if (realms.length === 0) {
    showMessage("No scans have been uploaded yet. Scan in game, type /reload, and leave the Goldbook app open. Get the app under Download.");
    return false;
  }
  state.realm = realms[0];
  drawLastScan();
  return true;
}

// The professions, once, into every profession and quality chip, each of
// which keeps what it had chosen. A failure is tried again next time.
let professionList = null;
function loadProfessions() {
  professionList ??= api("/api/professions").then(({ professions }) => {
    const fill = (selector, first, options) => {
      for (const select of document.querySelectorAll(selector)) {
        const chosen = select.value;
        select.replaceChildren(element("option", { value: "", textContent: first }), ...options());
        select.value = chosen;
      }
    };
    fill("[data-profession-filter]", "All professions", () =>
      professions.filter((p) => p.materials.length > 0).map((p) => element("option", { value: p.id, textContent: p.name })));
    fill("[data-quality-filter]", "All qualities", () =>
      LISTED_QUALITIES.map((name, index) => element("option", { value: String(index), textContent: name })));
    return professions;
  }, (error) => {
    professionList = null;
    throw error;
  });
  return professionList;
}

// As Professions.Matches in the addon: whether an item is of the chosen
// profession, all of them for none, and of the chosen kind of its items.
function professionMatches(professions, itemKey, profession, kind) {
  if (profession === "" && kind === "all") {
    return true;
  }
  const id = Number(itemKey.split(":")[0]);
  const groups = professions.filter((p) => profession === "" || p.id === profession);
  const has = (group) => groups.some((p) => p[group].includes(id));
  return ((kind === "all" || kind === "materials-recipes" || kind === "materials") && has("materials"))
    || ((kind === "all" || kind === "materials-recipes" || kind === "recipes") && has("recipes"))
    || ((kind === "all" || kind === "crafted") && has("crafted"));
}

// The newest scan of the realm on show, else of any realm: the rail's line
// "Last scan 40m ago", as the addon's rail has it.
let realmList = null;
function drawLastScan() {
  const scans = state.realm ? [state.realm] : (realmList ?? []);
  const newest = Math.max(0, ...scans.map(({ lastScan }) => lastScan ?? 0));
  $("last-scan").hidden = newest === 0;
  $("last-scan").replaceChildren("Last scan ", element("strong", { textContent: ago(newest), title: when(newest) }));
}

// The realms load on the first visit to a market view, so that a page opened
// on another view neither waits for them nor shows their messages.
// An item another view asked for, which Prices opens once it has its realms.
let askedItem = null;

async function openPrices() {
  if (await ensureRealms()) {
    const asked = askedItem;
    askedItem = null;
    // Asked for before the list loads, so an item chosen meanwhile is newer.
    const opening = asked ? loadHistory(asked) : null;
    await loadPrices();
    await opening;
  }
}

const plural = (count, word) => `${count.toLocaleString("en")} ${count === 1 ? word : `${word}s`}`;

// An item of Deals or Movers opens in Prices, where its history is.
function openItem(itemKey) {
  if (location.hash !== "#prices") {
    askedItem = itemKey;
    location.hash = "#prices";
    return;
  }
  run(() => loadHistory(itemKey));
}

// Outside Market an item's prices open in a pane beside the view, which
// borrows Prices' detail panel and gives it back when the pane closes.
const detailHome = { parent: $("detail").parentElement, next: $("detail").nextElementSibling };
let paneRow = null;

function closePane() {
  // A pane still looking up its realm stays shut.
  latest.pane++;
  if ($("item-pane").hidden) {
    return;
  }
  // A history still on its way belongs to the pane.
  latest.history++;
  $("item-pane").hidden = true;
  document.body.classList.remove("pane-open");
  paneRow?.removeAttribute("aria-selected");
  paneRow = null;
  $("detail").hidden = true;
  $("detail-close").hidden = true;
  $("detail-compare").hidden = false;
  detailHome.parent.insertBefore($("detail"), detailHome.next);
}

// The realm and faction with scans that `place` names; a trade knows its
// realm but not the faction, which settles it only when one has scans there.
async function paneRealm(place) {
  const realms = state.realms.length ? state.realms : (await api("/api/realms")).realms;
  const there = place === null ? [] : realms.filter((entry) => entry.realm === place.realm && (place.faction ?? entry.faction) === entry.faction);
  return there.length === 1 ? there[0] : (state.realm ?? there[0] ?? realms[0] ?? null);
}

async function openPane(itemKey, place, row, name) {
  const ticket = ++latest.pane;
  const realm = await paneRealm(place);
  if (ticket !== latest.pane) {
    return;
  }
  if (realm === null) {
    showMessage("No scans have been uploaded yet, so there are no prices to show.");
    return;
  }
  paneRow?.removeAttribute("aria-selected");
  paneRow = row;
  paneRow?.setAttribute("aria-selected", "true");
  $("item-pane").append($("detail"));
  $("detail-close").hidden = false;
  $("detail-compare").hidden = true;
  $("item-pane").hidden = false;
  document.body.classList.add("pane-open");
  await loadHistory(itemKey, realm, name);
}

$("detail-close").onclick = closePane;
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closePane();
  }
});

// An item's name that opens its prices in the pane; plain text when the
// item has no key to look up.
function itemButton(name, qualityClass, itemKey, place) {
  return itemKey
    ? element("button", {
      className: qualityClass,
      textContent: name,
      title: "Show its prices",
      onclick: (event) => run(() => openPane(itemKey, place, event.currentTarget.closest("tr"), name)),
    })
    : element("span", { className: qualityClass, textContent: name });
}

const itemColumn = {
  label: "Item",
  className: "item",
  cell: (item) =>
    element("button", {
      className: `quality-${quality(item)}`,
      textContent: itemName(item),
      title: QUALITIES[quality(item)],
      onclick: () => openItem(item.itemKey),
    }),
};

const weekColumn = {
  label: "7 days",
  className: "spark-column",
  cell: (item, trends) =>
    trends ? weekTrend(trends.days, trends.items[item.itemKey] ?? trends.days.map(() => null), item.minBuyout) : [],
};


// A change in percent as the addon writes it, to a tenth with its sign, in
// green or red; one that rounds to nothing has neither.
function signedPercent(change) {
  const tenths = Math.round(change * 10);
  const kind = tenths > 0 ? "up" : tenths < 0 ? "down" : "flat";
  return element("span", { className: `trend ${kind}`, textContent: `${tenths > 0 ? "+" : ""}${(tenths / 10).toFixed(1)}%` });
}

// The market views that list what the server's copy of the addon's advice
// finds in the newest scan: each one's endpoint, columns, the column the
// server sorts by, sub-heading and hint.
const LISTS = {
  deals: {
    endpoint: "/api/deals",
    offset: 0,
    parameters: () => ({}),
    columns: [
      itemColumn,
      { label: "Buy from", className: "number", cell: (item) => money(item.minBuyout) },
      { label: "Sells for", className: "number sells", cell: (item) => money(item.sell) },
      weekColumn,
      { label: "Profit", className: "number", cell: (item) => signedMoney(item.profit) },
      // The server finds auction flips only; vendor deals need the addon.
      { label: "Sell to", className: "sell-to", cell: () => "Auction" },
    ],
    sort: () => ({ column: 4, descending: true }),
    heading: (data) => {
      $("min-profit").replaceChildren(element("span", { textContent: "Min profit" }), money(data.minProfit));
      return `${data.total.toLocaleString("en")} in the scan of ${ago(data.scan.scannedAt)}`;
    },
    hint: "Click a deal to see its history · Profit is per unit, after the 5% cut · Vendor deals are in game: /gb deals",
    none: "No deals match",
  },
  movers: {
    endpoint: "/api/movers",
    offset: 0,
    direction: "risers",
    parameters: () => ({ direction: LISTS.movers.direction }),
    columns: [
      itemColumn,
      { label: "Price", className: "number", cell: (item) => money(item.minBuyout) },
      { label: "Day before", className: "number before", cell: (item) => money(item.before) },
      weekColumn,
      { label: "Change", className: "number", cell: (item) => signedPercent(item.change) },
      { label: "Listed", className: "number listed", cell: (item) => item.quantity.toLocaleString("en") },
    ],
    sort: () => ({ column: 4, descending: LISTS.movers.direction === "risers" }),
    heading: (data) =>
      `${plural(data.total, "price")} ${LISTS.movers.direction === "risers" ? "rose" : "fell"} since the day before`,
    hint: "Click an item to see its history · Prices under a silver on both days are left out",
    none: "No prices match",
  },
};

const marketFilters = () => ({ q: state.q, profession: state.profession, kind: state.kind, quality: state.quality });

function drawList(name, data, trends) {
  const list = LISTS[name];
  $("scan").textContent = list.heading(data);
  const columns = list.columns.map((column) => ({ ...column, cell: (item) => column.cell(item, trends) }));
  drawTable($(`${name}-table`), columns, data.items, { sort: list.sort() });
  drawPager($(`${name}-view`).querySelector(".pager"), {
    offset: list.offset,
    count: data.items.length,
    total: data.total,
    hint: list.hint,
    none: list.none,
    go: (offset) => {
      list.offset = offset;
      run(() => loadList(name));
    },
  });
}

async function loadList(name) {
  if (!(await ensureRealms())) {
    return;
  }
  latest.listTrends++;
  const { realm, faction } = state.realm;
  const list = LISTS[name];
  const data = await latestOnly(
    "list",
    api(list.endpoint, { realm, faction, ...marketFilters(), ...list.parameters(), limit: PAGE, offset: list.offset }),
  );
  drawList(name, data, null);
  if (data.items.length > 0) {
    const items = data.items.map((item) => item.itemKey).join(",");
    drawList(name, data, await latestOnly("listTrends", api("/api/trends", { realm, faction, items })));
  }
}

for (const button of $("mover-direction").querySelectorAll("button")) {
  button.onclick = () => {
    LISTS.movers.direction = button.dataset.direction;
    LISTS.movers.offset = 0;
    for (const other of $("mover-direction").querySelectorAll("button")) {
      other.setAttribute("aria-pressed", String(other === button));
    }
    run(() => loadList("movers"));
  };
}

function classColor(token) {
  return CLASSES.has(token) ? `var(--class-${token.toLowerCase()})` : "";
}

// Spaces inside each part do not break, so that a phone wraps between parts only.
function about(character) {
  const { level, class: token, realm, updatedAt } = character;
  const kind = token === null ? null : (CLASSES.get(token) ?? `${token[0].toUpperCase()}${token.slice(1).toLowerCase()}`);
  return [
    [level === null ? null : `Level ${level}`, kind].filter(Boolean).join(" "),
    realm,
    updatedAt === null ? null : `updated ${age(updatedAt)}`,
  ]
    .filter(Boolean)
    .map((part) => part.replaceAll(" ", "\u00a0"))
    .join(" · ");
}

const groupedId = (id) => `${id.slice(0, 4)}-${id.slice(4)}`;

// A player signed in with Battle.net has no ID of their own: the account's id is null.
function signedIn(account) {
  if (!account) {
    return ["Not signed in"];
  }
  if (account.id === null) {
    return ["Signed in with ", element("strong", { textContent: "Battle.net" })];
  }
  return ["Signed in as ", element("strong", { textContent: groupedId(account.id) })];
}

// The account in the rail, and the purse with the gold of all its characters.
function drawSession(account) {
  // Newer than any answer still on its way.
  latest.session++;
  session.account = account;
  $("session").hidden = account === undefined;
  $("session").replaceChildren(...signedIn(account));
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

// The account and every character in it in full, as each one's page has it.
async function loadRoster() {
  const account = await api("/api/account");
  const characters = await Promise.all(account.characters.map(({ name, realm }) => api("/api/character", { name, realm })));
  return { account, characters };
}

const characterKey = (character) => `${character.name}-${character.realm}`;

// A character's name, which picks that character in the view's character
// chip, and once picked all of them again.
function characterPick(character, redraw) {
  const key = characterKey(character);
  const picked = state.character === key;
  return element("button", {
    type: "button",
    textContent: character.name,
    title: picked ? "Show all characters" : `Show only ${character.name}`,
    onclick: () => {
      state.character = picked ? "" : key;
      redraw();
    },
  });
}

// The character chips of Bags and Gold choose the same character. One the
// account no longer has is let go.
function drawCharacterFilter(characters) {
  const realms = new Set(characters.map(({ realm }) => realm)).size > 1;
  if (!characters.some((character) => characterKey(character) === state.character)) {
    state.character = "";
  }
  for (const select of document.querySelectorAll("[data-character-filter]")) {
    select.replaceChildren(
      element("option", { value: "", textContent: "All characters" }),
      ...characters.map((character) =>
        element("option", { value: characterKey(character), textContent: realms ? `${character.name} · ${character.realm}` : character.name })),
    );
    select.value = state.character;
  }
}

for (const select of document.querySelectorAll("[data-character-filter]")) {
  select.onchange = () => {
    state.character = select.value;
    render();
  };
}


const WHERE = { bags: "bags", bank: "bank" };

// What Bags shows: the roster it last loaded, the 7-day lows of the items on
// the page by realm, and the toolbar's choices.
const bags = { roster: null, professions: null, trends: new Map(), q: "", profession: "", kind: "all", quality: "", sort: { column: 4, descending: true }, offset: 0 };

// The items of the characters chosen as the addon's Bags lists them: one row
// per item, its stacks in every bag and bank added up, and where they are in
// its `from`. Prices differ by realm, so an item is a row per realm.
function bagRows(characters) {
  const rows = new Map();
  for (const character of characters) {
    for (const where of Object.keys(WHERE)) {
      for (const stack of character[where]?.rows ?? []) {
        const id = `${character.realm}-${character.faction}:${stack.key}`;
        const row = rows.get(id) ?? { ...stack, count: 0, value: 0, realm: character.realm, faction: character.faction, from: [] };
        row.count += stack.count;
        row.value += stack.value;
        row.from.push(`${character.name}, ${WHERE[where]} ${stack.count.toLocaleString("en")}`);
        rows.set(id, row);
      }
    }
  }
  return [...rows.values()];
}

const SELL_TO = { auction: "Auction", vendor: "Vendor", unknown: "No price" };

const BAG_COLUMNS = [
  {
    label: "Item in bags",
    className: "item",
    value: (row) => row.name ?? row.key,
    cell: (row) =>
      element("span", { className: `quality-${quality(row)}`, title: row.from?.join(" · ") ?? "" }, [
        itemButton(row.name ?? `Item ${row.key}`, "", row.key, { realm: row.realm, faction: row.faction }),
        element("span", { className: "count", textContent: ` x${row.count.toLocaleString("en")}` }),
      ]),
  },
  { label: "Post at", className: "number", value: (row) => row.post, cell: (row) => (row.post ? money(row.post) : "") },
  { label: "Vendor pays", className: "number vendor", value: (row) => row.vendor, cell: (row) => (row.vendor > 0 ? money(row.vendor) : "") },
  {
    label: "7 days",
    className: "spark-column",
    cell: (row) => {
      const trends = bags.trends.get(`${row.realm}-${row.faction}`);
      const lows = trends?.items[row.key];
      return lows ? [weekTrend(trends.days, lows)] : [];
    },
  },
  { label: "Brings in", className: "number", value: (row) => row.value, cell: (row) => money(row.value) },
  {
    label: "Sell to",
    className: "sell-to",
    value: (row) => SELL_TO[row.action],
    cell: (row) => element("span", { className: row.action === "auction" ? "" : "muted", textContent: SELL_TO[row.action] }),
  },
];

// Every unbound item in the bags and banks of the characters chosen, as the
// addon's Bags lists those of the character playing.
function drawBags() {
  const { account, characters } = bags.roster;
  drawSession(account);
  drawCharacterFilter(characters);
  const shown = characters.filter((character) => state.character === "" || characterKey(character) === state.character);
  const all = bagRows(shown);
  const needle = bags.q.toLowerCase();
  const kept = all.filter((row) =>
    (row.name ?? "").toLowerCase().includes(needle)
    && (bags.quality === "" || quality(row) === Number(bags.quality))
    && professionMatches(bags.professions ?? [], row.key, bags.profession, bags.kind));
  const rows = sorted(kept, BAG_COLUMNS[bags.sort.column].value, bags.sort.descending);
  bags.offset = Math.min(bags.offset, Math.max(0, Math.floor((rows.length - 1) / PAGE) * PAGE));
  const page = rows.slice(bags.offset, bags.offset + PAGE);
  $("bags-sub").textContent = `${plural(all.length, "item")} in ${state.character === "" ? "the bags and banks of " + plural(shown.length, "character") : "these bags and bank"}`;
  $("bags-worth").replaceChildren("Worth ", money(kept.reduce((total, row) => total + row.value, 0)), " after the cut");
  drawTable($("bags-table"), BAG_COLUMNS, page, {
    sort: bags.sort,
    onSort: (column) => {
      bags.sort = nextSort(bags.sort, column, BAG_COLUMNS, rows[0]);
      bags.offset = 0;
      drawBags();
    },
    empty: all.length ? "No items match" : "No unbound items",
  });
  const without = (where) => shown.filter((character) => character[where] === null).map(({ name }) => name);
  drawPager($("bags-status"), {
    offset: bags.offset,
    count: page.length,
    total: rows.length,
    hint: [
      "Auction prices undercut the lowest buyout, or hold the usual price when it is far off",
      without("bags").length ? `/reload in game to save the bags of ${without("bags").join(", ")}` : "",
      without("bank").length ? `open the bank in game to see that of ${without("bank").join(", ")}` : "",
    ].filter(Boolean).join(" · "),
    go: (offset) => {
      bags.offset = offset;
      run(loadBagTrends);
    },
  });
  return page;
}

// The 7-day lows of the items on the page, one request per realm they are on.
// A realm without scans has none.
async function loadBagTrends() {
  const realms = new Map();
  for (const row of drawBags()) {
    const where = `${row.realm}-${row.faction}`;
    realms.set(where, [...(realms.get(where) ?? []), row]);
  }
  const answers = await latestOnly("listTrends", Promise.all([...realms].map(([where, rows]) =>
    api("/api/trends", { realm: rows[0].realm, faction: rows[0].faction, items: rows.map((row) => row.key).join(",") })
      .then((trends) => [where, trends], () => [where, null]))));
  for (const [where, trends] of answers) {
    bags.trends.set(where, trends);
  }
  drawBags();
}

async function loadBags() {
  [bags.roster, bags.professions] = await latestOnly("view", Promise.all([loadRoster(), loadProfessions()]));
  bags.offset = 0;
  await loadBagTrends();
}

const bagsChanged = (change) => () => {
  change();
  bags.offset = 0;
  if (bags.roster) {
    run(loadBagTrends);
  }
};
let bagsTimer;
$("bags-search").oninput = (event) => {
  clearTimeout(bagsTimer);
  bagsTimer = setTimeout(bagsChanged(() => { bags.q = event.target.value.trim(); }), 150);
};
$("bags-profession").onchange = bagsChanged(() => {
  bags.profession = $("bags-profession").value;
  bags.kind = bags.profession ? "materials" : "all";
  $("bags-kind").value = bags.kind;
});
$("bags-kind").onchange = bagsChanged(() => { bags.kind = $("bags-kind").value; });
$("bags-quality").onchange = bagsChanged(() => { bags.quality = $("bags-quality").value; });

// The gold of all `characters` over time: at each time any of them recorded
// a balance, the sum of their balances then. Before its first balance a
// character counts with it, as Ledger.History has it, so that meeting one is
// no gain.
function accountGold(characters) {
  const series = characters.map(({ gold }) => gold).filter((gold) => gold.length > 0);
  const times = [...new Set(series.flatMap((gold) => gold.map(([time]) => time)))].sort((a, b) => a - b);
  const next = series.map(() => 0);
  return times.map((time) => [
    time,
    series.reduce((total, gold, index) => {
      while (next[index] < gold.length && gold[next[index]][0] <= time) {
        next[index]++;
      }
      return total + gold[Math.max(0, next[index] - 1)][1];
    }, 0),
  ]);
}

// A muted label before a figure, as the addon's cards and lists pair them.
const labelled = (text, figure) => [element("span", { className: "muted", textContent: text }), " ", figure];
const none = () => element("span", { className: "muted", textContent: "–" });

// Whole UTC days since the character last saved, as Ledger.Summary has them.
const idleDays = (character) => Math.floor(Date.now() / 1000 / DAY) - Math.floor(character.updatedAt / DAY);
const balance = (character) => character.gold.at(-1)?.[1] ?? null;
const todayChange = (character) => (character.gold.length ? goldChange(character.gold, 1).change : 0);

const GOLD_COLUMNS = [
  {
    label: "Name",
    className: "name",
    value: (character) => character.name,
    cell: (character) => {
      const pick = characterPick(character, drawGold);
      const colour = classColor(character.class);
      if (colour) {
        pick.classList.add("class-mark");
        pick.style.setProperty("--class", colour);
      }
      return pick;
    },
  },
  { label: "Gold", className: "number", value: balance, cell: (character) => (character.gold.length ? money(balance(character)) : none()) },
  {
    label: "Today",
    className: "number",
    value: todayChange,
    cell: (character) => (todayChange(character) === 0 ? none() : signedMoney(todayChange(character))),
  },
  {
    label: "Played",
    className: "number played",
    value: (character) => (character.updatedAt === null ? null : -idleDays(character)),
    cell: (character) =>
      element("span", {
        className: "muted",
        textContent: character.updatedAt === null ? "–" : idleDays(character) <= 0 ? "today" : `${idleDays(character)}d ago`,
        title: character.updatedAt === null ? "" : when(character.updatedAt),
      }),
  },
];

// The account as a broker would state it, as the addon's Gold cards do.
function goldCards(gold, worth, worthLabel) {
  if (gold.length === 0) {
    return ["Total gold", "Today", "30 days", "Net worth"].map((label) => stat(label, none()));
  }
  const now = gold.at(-1)[1];
  const high = Math.max(...gold.map(([, copper]) => copper));
  const today = goldChange(gold, 1);
  const tenths = today.base > 0 ? Math.round((today.change / today.base) * 1000) : 0;
  return [
    stat("Total gold", money(now), labelled("High", money(high))),
    stat("Today", signedMoney(today.change), element("span", {
      className: "muted",
      textContent: `${tenths > 0 ? "+" : ""}${(tenths / 10).toFixed(1)}% since yesterday`,
    })),
    stat("30 days", signedMoney(goldChange(gold, 30).change), labelled("7 days", signedMoney(goldChange(gold, 7).change))),
    stat("Net worth", money(now + worth), labelled(worthLabel, money(worth))),
  ];
}

// What Gold shows: the roster and the trades it last loaded, and the order of its table.
const ledger = { roster: null, trades: null, sort: { column: 1, descending: true } };

// The gold of the account, or of the character chosen, the characters with
// their gold, and the month's accounting beside them.
function drawGold() {
  const { account, characters } = ledger.roster;
  drawSession(account);
  drawCharacterFilter(characters);
  const chosen = characters.find((character) => characterKey(character) === state.character);
  const shown = chosen ? [chosen] : characters;
  const gold = chosen ? chosen.gold : accountGold(characters);
  const title = chosen ? chosen.name : "All characters";
  const held = (where) => shown.reduce((total, character) => total + (character[where]?.total ?? 0), 0);
  $("gold-sub").textContent = chosen ? about(chosen) : plural(characters.length, "character");
  $("account-gold-summary").replaceChildren(...goldCards(gold, held("bags") + held("bank"), "Bags and bank"));
  $("account-gold").hidden = gold.length === 0;
  $("account-gold-title").textContent = title;
  if (gold.length > 0) {
    drawGoldChart({ chart: $("account-gold-chart"), range: $("account-gold-range") }, title, gold);
  }
  const ordered = sorted(characters, GOLD_COLUMNS[ledger.sort.column].value, ledger.sort.descending);
  const rows = drawTable($("gold-characters"), GOLD_COLUMNS, ordered, {
    sort: ledger.sort,
    onSort: (column) => {
      ledger.sort = nextSort(ledger.sort, column, GOLD_COLUMNS, characters[0]);
      drawGold();
    },
  });
  ordered.forEach((character, index) => rows[index].setAttribute("aria-selected", String(character === chosen)));
  const player = account.id === null;
  const linked = account.linked?.length ? `, linked with ${account.linked.map(groupedId).join(", ")}` : "";
  $("account-id").textContent = player ? "Signed in with Battle.net" : `ID ${groupedId(account.id)}${linked}`;
  // A player sees every ID their installs uploaded, so has nothing to link.
  $("link-form").closest("details").hidden = player;
  drawMonth($("gold-month"), ledger.trades);
}

// The last 30 days of the account's accounting, as the addon's Gold has it beside its characters.
function drawMonth(list, trades) {
  const month = (trades ?? []).filter(({ at }) => at >= Date.now() / 1000 - 30 * DAY);
  const totals = tradeSums(month);
  const best = month
    .filter(({ side }) => SIDES[side].revenue && SIDES[side].goods)
    .reduce((most, trade) => (tradeNet(trade) > (most ? tradeNet(most) : -Infinity) ? trade : most), null);
  const line = (label, value) => element("div", {}, [element("dt", { textContent: label }), element("dd", {}, [value])]);
  list.replaceChildren(
    line("Revenue", money(totals.revenue)),
    line("Expenses", money(totals.expenses)),
    line("Net", signedMoney(totals.net)),
    line("Realized profit", totals.profit === null ? none() : signedMoney(totals.profit)),
    line("Best sale", best ? itemButton(best.item, `quality-${QUALITIES[best.quality] ? best.quality : 1}`, best.itemKey, { realm: best.realm }) : none()),
  );
}

async function loadGold() {
  [ledger.roster, ledger.trades] = await latestOnly("view", Promise.all([loadRoster(), loadTrades()]));
  drawGold();
}

async function loadAccounting() {
  drawTrades($("account-trades"), await latestOnly("view", loadTrades()));
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

// As Ledger.Performance has it in game: the change over the last `span` UTC
// days, since the end of the day before them. The balance before the first
// one on record is the first one, so that meeting a character is not a gain.
function goldChange(gold, span) {
  const today = Math.floor(goldNow(gold) / DAY) * DAY;
  const base = balanceBy(gold, today - (span - 1) * DAY);
  return { change: gold.at(-1)[1] - base, base };
}

// As many labels as keep apart on a phone.
const labelRoom = (width) => Math.min(6, Math.floor(width / 64));
const clock = (seconds) => new Date(seconds * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });

function dayDates(start, end, width) {
  return dayTicks(start, end, labelRoom(width)).map((time) => [time, shortDate(time), "middle"]);
}

const SPAN_NAMES = { 7: "7 days", 30: "30 days", 60: "60 days" };

// The balance hour by hour over the days chosen in `range`, or since the first
// one on record when that is later, into `chart`. Each range keeps its own
// choice, the button pressed in the page at first.
function drawGoldChart(panel, name, gold) {
  const buttons = [...panel.range.querySelectorAll("button")];
  panel.range.dataset.days ??= buttons.find((button) => button.getAttribute("aria-pressed") === "true").dataset.days;
  const goldSpan = Number(panel.range.dataset.days);
  for (const button of buttons) {
    button.setAttribute("aria-pressed", String(button.dataset.days === panel.range.dataset.days));
    button.onclick = () => {
      panel.range.dataset.days = button.dataset.days;
      drawGoldChart(panel, name, gold);
    };
  }
  // A month or more is drawn a point a day, as the addon draws every span.
  if (goldSpan >= 30) {
    const today = Math.floor(goldNow(gold) / DAY) * DAY;
    const days = dailyGold(gold).filter(({ day }) => day > today - goldSpan * DAY);
    drawChart(panel.chart, {
      times: days.map(({ day }) => day),
      series: [{ name: "Gold", color: "var(--series-1)", values: days.map(({ copper }) => copper), area: true }],
      heading: (index) => shortDate(days[index].day, "UTC"),
      label: `${name}: gold at the end of each day over the last ${SPAN_NAMES[goldSpan]}, from ${moneyText(days[0].copper)} to ${moneyText(days.at(-1).copper)}. Use the arrow keys to read each day.`,
      dates: dayDates,
    });
    return;
  }
  const end = Math.floor(goldNow(gold) / HOUR) * HOUR;
  const times = [];
  for (let time = Math.max(end - goldSpan * DAY, gold[0][0]); time <= end; time += HOUR) {
    times.push(time);
  }
  const balances = hourlyGold(gold, times);
  drawChart(panel.chart, {
    times,
    series: [{ name: "Gold", color: "var(--series-1)", values: balances, area: true }],
    steps: true,
    heading: (index) => `${when(times[index])}–${clock(times[index] + HOUR)}`,
    label: `${name}: gold over the last ${SPAN_NAMES[goldSpan]}, from ${moneyText(balances[0])} to ${moneyText(balances.at(-1))}. Use the arrow keys to read each hour.`,
    dates: dayDates,
  });
}

// The gold the addon booked, newest first:
// [{ name, realm, at, side, item, itemKey, quality, count, price, fee, party }].
// `price` is the whole stack's and never negative, `fee` the auction house cut
// and `party` the other player of a trade, mail or cash on delivery, or null.

// Every side an entry can have. Revenue adds its price less the cut to the
// gold and an expense takes its price away. A goods side moves an item and
// counts towards that item's profit; the others move gold alone. `party`
// joins the entry to the other player, as in "Thorium Ore x20 · to Kargath".
const SIDES = {
  sell: { label: "Auction sale", revenue: true, goods: true },
  buy: { label: "Auction purchase", revenue: false, goods: true },
  vendor: { label: "Vendor sale", revenue: true, goods: true },
  merchant: { label: "Merchant purchase", revenue: false, goods: true },
  tradeSell: { label: "Trade sale", revenue: true, goods: true, party: "to" },
  tradeBuy: { label: "Trade purchase", revenue: false, goods: true, party: "from" },
  tradeIn: { label: "Trade gold in", revenue: true, goods: false, party: "from" },
  tradeOut: { label: "Trade gold out", revenue: false, goods: false, party: "to" },
  mailIn: { label: "Mail gold in", revenue: true, goods: false, party: "from" },
  mailOut: { label: "Mail gold out", revenue: false, goods: false, party: "to" },
  cod: { label: "Cash on delivery", revenue: false, goods: true, party: "from" },
  quest: { label: "Quest reward", revenue: true, goods: false },
  loot: { label: "Looted gold", revenue: true, goods: false },
  repair: { label: "Repairs", revenue: false, goods: false },
  postage: { label: "Postage", revenue: false, goods: false },
  deposit: { label: "Auction deposit", revenue: false, goods: false },
  travel: { label: "Flight", revenue: false, goods: false },
  training: { label: "Training", revenue: false, goods: false },
  respec: { label: "Talent reset", revenue: false, goods: false },
  otherIn: { label: "Other income", revenue: true, goods: false },
  otherOut: { label: "Other expense", revenue: false, goods: false },
};

const ENTRY_FILTERS = {
  all: { label: "All", keep: () => true },
  revenue: { label: "Revenue", keep: (side) => side.revenue },
  expenses: { label: "Expenses", keep: (side) => !side.revenue },
};

// What an entry added to the gold: its price less the cut, or minus its price.
const tradeNet = (trade) => (SIDES[trade.side].revenue ? trade.price - trade.fee : -trade.price);

// A gain in green with a plus, a loss in red with a minus.
function signedMoney(copper) {
  if (copper === 0) {
    return money(0);
  }
  const kind = copper > 0 ? "up" : "down";
  return element("span", { className: `trend ${kind}` }, [copper > 0 ? "+" : "−", money(Math.abs(copper))]);
}

// One row per item moved, the most recently traded first, with the time of
// its latest entry in `last`. Every goods side counts: sales at auction, to
// vendors and in player trades, and purchases at auction, from merchants, in
// player trades and by cash on delivery. Profit or loss is realized on the
// units both bought and sold, at the average sale less the average cost, so
// an item never bought, or never sold, has none.
function tradedItems(trades) {
  const items = new Map();
  for (const trade of trades.filter(({ side }) => SIDES[side].goods)) {
    const item = items.get(trade.item) ?? { name: trade.item, quality: null, itemKey: null, realm: null, bought: 0, cost: 0, sold: 0, proceeds: 0, last: trade.at };
    item.quality ??= trade.quality;
    item.itemKey ??= trade.itemKey;
    item.realm ??= trade.realm;
    item.last = Math.max(item.last, trade.at);
    if (SIDES[trade.side].revenue) {
      item.sold += trade.count;
      item.proceeds += trade.price - trade.fee;
    } else {
      item.bought += trade.count;
      item.cost += trade.price;
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

const entries = (count) => `${count.toLocaleString("en")} ${count === 1 ? "entry" : "entries"}`;

// As Trades.Totals has them in game; profit is null when no goods were both bought and sold.
function tradeSums(trades) {
  const sum = (list, value) => list.reduce((total, trade) => total + value(trade), 0);
  const realized = tradedItems(trades).filter(({ profit }) => profit !== null);
  return {
    revenue: sum(trades.filter(({ side }) => SIDES[side].revenue), ({ price, fee }) => price - fee),
    expenses: sum(trades.filter(({ side }) => !SIDES[side].revenue), ({ price }) => price),
    net: sum(trades, tradeNet),
    profit: realized.length > 0 ? sum(realized, ({ profit }) => profit) : null,
  };
}

const itemQuality = (value) => (QUALITIES[value] ? value : 1);

const optionalAverage = (copper) => (copper === null ? none() : money(Math.round(copper)));
const optionalProfit = (copper) => (copper === null ? none() : signedMoney(copper));

const ITEM_COLUMNS = [
  {
    label: "Item",
    className: "item",
    value: (item) => item.name,
    cell: (item) => itemButton(item.name, `quality-${itemQuality(item.quality)}`, item.itemKey, item.realm ? { realm: item.realm } : null),
  },
  { label: "Bought", className: "number", value: (item) => item.bought, cell: (item) => item.bought.toLocaleString("en") },
  { label: "Avg cost", className: "number average", value: (item) => item.averageCost, cell: (item) => optionalAverage(item.averageCost) },
  { label: "Sold", className: "number", value: (item) => item.sold, cell: (item) => item.sold.toLocaleString("en") },
  { label: "Avg sale", className: "number average", value: (item) => item.averageSale, cell: (item) => optionalAverage(item.averageSale) },
  { label: "Profit", className: "number", value: (item) => item.profit, cell: (item) => optionalProfit(item.profit) },
  {
    label: "Last",
    className: "number when",
    value: (item) => item.last,
    cell: (item) => element("span", { className: "muted", textContent: ago(item.last), title: when(item.last) }),
  },
];

const PROFIT_HINT = "Profit counts the units both bought and sold, at the average sale less the average cost";
const NOTHING_BOOKED = "Nothing booked yet. Gold is booked as it moves in game: type /reload or log out to upload it.";

// What By item shows: the trades and professions it last loaded, and the toolbar's choices.
const byItem = { trades: null, professions: null, q: "", profession: "", kind: "all", quality: "", sort: { column: 6, descending: true }, offset: 0 };

// Each item the characters chosen bought or sold, as the addon's By item
// lists them: the search and the character choose the entries, the other
// chips the items.
function drawItems() {
  const { trades } = byItem;
  const characters = tradeCharacters(trades);
  const character = characters.some(([key]) => key === state.character) ? state.character : "";
  $("items-character").replaceChildren(
    ...[["", "All characters"], ...characters].map(([value, text]) => element("option", { value, textContent: text })),
  );
  $("items-character").value = character;
  const needle = byItem.q.toLowerCase();
  const entries = trades.filter((trade) =>
    trade.item.toLowerCase().includes(needle) && (character === "" || characterKey(trade) === character));
  const kept = tradedItems(entries).filter((item) =>
    (byItem.quality === "" || itemQuality(item.quality) === Number(byItem.quality))
    && ((byItem.profession === "" && byItem.kind === "all")
      || (item.itemKey !== null && professionMatches(byItem.professions ?? [], item.itemKey, byItem.profession, byItem.kind))));
  const rows = sorted(kept, ITEM_COLUMNS[byItem.sort.column].value, byItem.sort.descending);
  byItem.offset = Math.min(byItem.offset, Math.max(0, Math.floor((rows.length - 1) / PAGE) * PAGE));
  const page = rows.slice(byItem.offset, byItem.offset + PAGE);
  const sum = (value) => kept.reduce((total, item) => total + value(item), 0);
  const realized = kept.filter(({ profit }) => profit !== null);
  const best = realized.reduce((most, item) => (most === null || item.profit > most.profit ? item : most), null);

  $("items-sub").textContent = plural(kept.length, "item");
  $("items-cards").replaceChildren(
    stat("Bought", money(sum((item) => item.cost))),
    stat("Sold", money(sum((item) => item.proceeds))),
    stat("Realized profit", realized.length ? signedMoney(realized.reduce((total, item) => total + item.profit, 0)) : none()),
    best
      ? stat("Best item", signedMoney(best.profit), element("span", { className: `quality-${itemQuality(best.quality)}`, textContent: best.name, title: best.name }))
      : stat("Best item", none()),
  );
  drawTable($("items-table"), ITEM_COLUMNS, page, {
    sort: byItem.sort,
    onSort: (column) => {
      byItem.sort = nextSort(byItem.sort, column, ITEM_COLUMNS, rows[0]);
      byItem.offset = 0;
      drawItems();
    },
    empty: trades.length ? "No items match" : "",
  });
  drawPager($("items-status"), {
    offset: byItem.offset,
    count: page.length,
    total: trades.length ? rows.length : 0,
    hint: PROFIT_HINT,
    none: trades.length ? PROFIT_HINT : NOTHING_BOOKED,
    go: (offset) => {
      byItem.offset = offset;
      drawItems();
    },
  });
}

async function loadItems() {
  const [trades, professions] = await latestOnly("view", Promise.all([loadTrades(), loadProfessions()]));
  // A server from before trades has none.
  byItem.trades = trades ?? [];
  byItem.professions = professions;
  byItem.offset = 0;
  drawItems();
}

const itemsChanged = (change) => () => {
  change();
  byItem.offset = 0;
  if (byItem.trades) {
    drawItems();
  }
};
let itemsTimer;
$("items-search").oninput = (event) => {
  clearTimeout(itemsTimer);
  itemsTimer = setTimeout(itemsChanged(() => { byItem.q = event.target.value.trim(); }), 150);
};
$("items-profession").onchange = itemsChanged(() => {
  byItem.profession = $("items-profession").value;
  byItem.kind = byItem.profession ? "materials" : "all";
  $("items-kind").value = byItem.kind;
});
$("items-kind").onchange = itemsChanged(() => { byItem.kind = $("items-kind").value; });
$("items-quality").onchange = itemsChanged(() => { byItem.quality = $("items-quality").value; });
$("items-character").onchange = itemsChanged(() => { state.character = $("items-character").value; });

// "Runecloth x20 · to Kargath", as the addon names an entry: the goods and
// how many, or what the gold was for, and who it went to or came from.
function entryCell(trade) {
  const side = SIDES[trade.side];
  return element("span", { className: side.goods ? `quality-${itemQuality(trade.quality)}` : "" }, [
    side.goods ? itemButton(trade.item, "", trade.itemKey, { realm: trade.realm }) : trade.item,
    ...(side.goods ? [element("span", { className: "count", textContent: ` x${trade.count.toLocaleString("en")}` })] : []),
    ...(side.party && trade.party ? [element("span", { className: "count", textContent: ` · ${side.party} ${trade.party}` })] : []),
  ]);
}

// The columns of Accounting's entries; a character's name picks it with `redraw`.
function tradeColumns(redraw) {
  return [
    { label: "Entry", className: "item", value: (trade) => trade.item, cell: entryCell },
    {
      label: "Source",
      className: "source",
      value: (trade) => SIDES[trade.side].label,
      cell: (trade) => element("span", { className: "muted", textContent: SIDES[trade.side].label }),
    },
    { label: "Net", className: "number", value: tradeNet, cell: (trade) => signedMoney(tradeNet(trade)) },
    { label: "Character", className: "character", value: (trade) => trade.name, cell: (trade) => characterPick(trade, redraw) },
    {
      label: "When",
      className: "number when",
      value: (trade) => trade.at,
      cell: (trade) => element("span", { className: "muted", textContent: ago(trade.at), title: when(trade.at) }),
    },
  ];
}

// The characters with entries in `trades` as a chip's [key, name] pairs, A to Z.
const tradeCharacters = (trades) =>
  [...new Map(trades.map((trade) => [characterKey(trade), trade.name])).entries()].sort((a, b) => a[1].localeCompare(b[1]));

// A chip of choices: [value, label] pairs, the first for all of them.
function chip(label, choices, chosen, onchange) {
  const select = element("select", { onchange: () => onchange(select.value) },
    choices.map(([value, text]) => element("option", { value, textContent: text })));
  select.value = chosen;
  return element("label", { className: "chip" }, [element("span", { className: "visually-hidden", textContent: label }), select]);
}

// The accounting of `trades` into `container`, as the addon's Accounting view
// has it: a title with the choice of revenue or expenses, the cards of what
// is shown, a search and chips, and the entries. The container keeps its
// choices from one drawing to the next.
function drawTrades(container, trades) {
  if (trades === null) {
    container.replaceChildren();
    return;
  }
  const view = (container.choices ??= { segment: "all", q: "", source: "", sort: null, offset: 0 });
  const redraw = () => drawTrades(container, trades);
  const columns = tradeColumns(() => {
    view.offset = 0;
    redraw();
  });
  view.sort ??= { column: columns.length - 1, descending: true };
  const characters = tradeCharacters(trades);
  const character = characters.some(([key]) => key === state.character) ? state.character : "";
  const needle = view.q.trim().toLowerCase();
  const kept = trades.filter((trade) => {
    const side = SIDES[trade.side];
    return ENTRY_FILTERS[view.segment].keep(side)
      && (view.source === "" || trade.side === view.source)
      && (character === "" || characterKey(trade) === character)
      && [trade.item, trade.name, side.label, trade.party ?? ""].some((field) => field.toLowerCase().includes(needle));
  });
  const rows = sorted(kept, columns[view.sort.column].value, view.sort.descending);
  view.offset = Math.min(view.offset, Math.max(0, Math.floor((rows.length - 1) / PAGE) * PAGE));
  const page = rows.slice(view.offset, view.offset + PAGE);

  const segments = element("div", { className: "segmented", role: "group" }, Object.entries(ENTRY_FILTERS).map(([name, { label }]) => {
    const button = element("button", { type: "button", textContent: label, onclick: () => {
      view.segment = name;
      view.offset = 0;
      redraw();
    } });
    button.setAttribute("aria-pressed", String(name === view.segment));
    return button;
  }));
  segments.setAttribute("aria-label", "Entries");
  const totals = tradeSums(kept);
  const present = new Set(trades.map(({ side }) => side));
  const search = element("input", { type: "search", placeholder: "Search items or characters", autocomplete: "off", value: view.q });
  search.oninput = () => {
    clearTimeout(view.timer);
    view.timer = setTimeout(() => {
      // The box is drawn again with this text, so it keeps what was typed,
      // a space at its end too.
      view.q = search.value;
      view.offset = 0;
      redraw();
      const input = container.querySelector(".search input");
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }, 150);
  };
  const table = element("table", { className: "trade-list" });
  drawTable(table, columns, page, {
    sort: view.sort,
    onSort: (column) => {
      view.sort = nextSort(view.sort, column, columns, rows[0]);
      redraw();
    },
    empty: trades.length ? "No entries match" : "",
  });
  const pager = element("nav", { className: "pager" });
  pager.setAttribute("aria-label", "Pages");
  drawPager(pager, {
    offset: view.offset,
    count: page.length,
    total: trades.length ? rows.length : 0,
    hint: "Open a mailbox in game to book auction sales and purchases",
    none: NOTHING_BOOKED,
    go: (offset) => {
      view.offset = offset;
      redraw();
    },
  });
  container.replaceChildren(
    element("div", { className: "pagehead" }, [
      element("h1", { textContent: "Accounting" }),
      element("p", { className: "sub", textContent: entries(kept.length) }),
      segments,
    ]),
    element("dl", { className: "cards" }, [
      stat("Revenue", money(totals.revenue)),
      stat("Expenses", money(totals.expenses)),
      stat("Net", signedMoney(totals.net)),
      stat("Realized profit", totals.profit === null ? none() : signedMoney(totals.profit)),
    ]),
    element("div", { className: "toolbar" }, [
      element("label", { className: "search" }, [element("span", { className: "visually-hidden", textContent: "Entry" }), search]),
      chip("Source", [["", "All sources"], ...Object.entries(SIDES).filter(([side]) => present.has(side)).map(([side, { label }]) => [side, label])],
        view.source, (value) => {
          view.source = value;
          view.offset = 0;
          redraw();
        }),
      chip("Character", [["", "All characters"], ...characters], character, (value) => {
        state.character = value;
        view.offset = 0;
        redraw();
      }),
    ]),
    element("div", { className: "list" }, [element("section", { className: "panel list-panel" }, [table]), pager]),
  );
}

// A server from before trades answers 404; it has none to show.
function loadTrades() {
  return api("/api/trades").then(
    ({ trades }) => trades,
    (error) => {
      if (error.status === 404 && error.message === "not found") {
        return null;
      }
      throw error;
    },
  );
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

// "#<view>". `moved` marks a link to a page that has another address now:
// the Characters pages before 0.2.4, which Gold replaced, and any hash the
// site does not know, which shows Prices. A character page's link,
// "#character/<name>-<realm>" or before that "#characters/<name>-<realm>"
// with each part URI-encoded, also names the character Gold picks. Names
// never contain "-", realms can.
function parseRoute(hash) {
  const view = hash.slice(1);
  if (view === "") {
    return { view: "prices" };
  }
  if (ROUTES.has(view)) {
    return { view };
  }
  if (view === "characters") {
    return { view: "gold", moved: true };
  }
  const [, name, realm] = /^#characters?\/([^-]+)-(.+)$/.exec(hash) ?? [];
  if (name) {
    try {
      return { view: "gold", moved: true, character: characterKey({ name: decodeURIComponent(name), realm: decodeURIComponent(realm) }) };
    } catch {
      // A broken escape is as unknown as any other hash.
    }
  }
  return { view: "prices", moved: true };
}

const viewSections = () => NAV.flatMap(({ tabs }) => tabs.flatMap(({ shows }) => shows));

// The sign-in prompt in place of the view, whose tabs stay.
function showLogin() {
  for (const id of viewSections()) {
    $(id).hidden = true;
  }
  $("login-view").hidden = false;
}

async function run(action) {
  try {
    showMessage("");
    await action();
  } catch (error) {
    if (error.status === 401) {
      drawSession(null);
      showLogin();
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

// The realm and the filters are those of every market view, so each starts
// again at its first page, and the one on show loads again.
function marketChanged() {
  state.offset = 0;
  for (const list of Object.values(LISTS)) {
    list.offset = 0;
  }
  $("clear-filters").hidden = !(state.q || state.profession || state.quality || state.kind !== "all");
  render();
}

$("realm").onchange = (event) => {
  state.realm = state.realms[Number(event.target.value)];
  drawLastScan();
  comparisonRequest++;
  comparisonItems = [];
  $("comparison").hidden = true;
  state.selected = null;
  // A history still on its way belongs to the realm that was just left.
  latest.history++;
  $("detail").hidden = true;
  marketChanged();
};

function filterChanged() {
  state.selected = null;
  latest.history++;
  $("detail").hidden = true;
  marketChanged();
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
    marketChanged();
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
    await loadSession();
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
      showLogin();
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

const MARKET = ["realm-picker", "market-tools"];

// The site's navigation, as the addon's window has it: the hubs of the rail,
// each with the tabs at the top of the page, the route of each tab, what it
// shows and loads, and whether it needs sign-in. A tab without a name is a
// page of its hub that the tabs do not list. Mail is in game only.
const NAV = [
  {
    hub: "Market",
    icon: ["M2 2V14H14", "M4 11L7 6L10 9L14 3"],
    tabs: [
      { route: "prices", tab: "Prices", shows: [...MARKET, "prices-view"], load: openPrices },
      { route: "deals", tab: "Deals", shows: [...MARKET, "min-profit", "deals-view"], load: () => loadList("deals") },
      { route: "movers", tab: "Movers", shows: [...MARKET, "mover-direction", "movers-view"], load: () => loadList("movers") },
    ],
  },
  {
    hub: "Inventory",
    icon: ["M2 7H14V14H2Z", "M2 7L4 2.5H12L14 7", "M8 7V11"],
    tabs: [{ route: "bags", tab: "Bags", signIn: true, shows: ["bags-view"], load: loadBags }],
  },
  {
    hub: "Ledger",
    icon: ["M8 2V14", "M3 5H13", "M3 5L1 10H5Z", "M13 5L11 10H15Z"],
    tabs: [
      { route: "gold", tab: "Gold", signIn: true, shows: ["gold-view"], load: loadGold },
      { route: "accounting", tab: "Accounting", signIn: true, shows: ["accounting-view"], load: loadAccounting },
      { route: "items", tab: "By item", signIn: true, shows: ["items-view"], load: loadItems },
    ],
  },
  {
    hub: "Download",
    group: "Account",
    icon: ["M8 2v9M4 7l4 4 4-4M2 14h12"],
    tabs: [{ route: "download", shows: ["download-view"], load: loadDownload }],
  },
];
const ROUTES = new Map(NAV.flatMap((hub) => hub.tabs.map((tab) => [tab.route, { hub, tab }])));

// The rail, once: a link per hub to the tab of it last on show, the hubs of
// a group under its name.
function drawRail() {
  let group;
  for (const hub of NAV) {
    if (hub.group !== group && hub.group) {
      $("views").append(element("p", { className: "group", textContent: hub.group }));
    }
    group = hub.group;
    hub.link = element("a", { href: `#${hub.tabs[0].route}` }, [
      svg("svg", { viewBox: "0 0 16 16", "aria-hidden": "true" }, undefined, hub.icon.map((d) => svg("path", { d }))),
      hub.hub,
    ]);
    $("views").append(hub.link);
  }
}

function drawNav(current, tab) {
  for (const hub of NAV) {
    if (hub === current) {
      hub.link.setAttribute("aria-current", "page");
    } else {
      hub.link.removeAttribute("aria-current");
    }
  }
  if (tab.tab) {
    current.link.href = `#${tab.route}`;
  }
  const tabs = current.tabs.filter((entry) => entry.tab);
  $("tabs").hidden = tabs.length === 0;
  $("tabs").setAttribute("aria-label", current.hub);
  $("tabs").replaceChildren(
    ...tabs.map((entry) => {
      const link = element("a", { href: `#${entry.route}`, textContent: entry.tab });
      if (entry === tab) {
        link.setAttribute("aria-current", "page");
      }
      return link;
    }),
  );
  document.title = `${tab.tab ?? current.hub} · Goldbook`;
}

let shownHash;

function render() {
  const route = parseRoute(location.hash);
  if (route.moved) {
    state.character = route.character ?? state.character;
    location.replace(`#${route.view}`);
    return;
  }
  const { hub, tab } = ROUTES.get(route.view);
  // Another view starts at its top; a filter changed keeps the place.
  if (location.hash !== shownHash) {
    shownHash = location.hash;
    scrollTo(0, 0);
    closePane();
  }
  for (const id of viewSections()) {
    $(id).hidden = !tab.shows.includes(id);
  }
  $("login-view").hidden = true;
  drawNav(hub, tab);
  if (tab.shows.includes("market-tools")) {
    $("market-title").textContent = tab.tab;
    $("scan").textContent = "";
    $("search").placeholder = `Search ${tab.route === "prices" ? "items" : tab.route}`;
  }
  // An answer still on its way belongs to the view that was just left. The
  // market views share their heading, so theirs are dropped too.
  for (const kind of ["view", "prices", "trends", "list", "listTrends"]) {
    latest[kind]++;
  }
  if (tab.signIn && session.account === null) {
    showLogin();
    return;
  }
  run(tab.load);
}

// The title bar's button names the theme it switches to, as the addon's
// tooltip does; theme.js applied a stored choice before the first paint.
function drawTheme() {
  const other = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  $("theme").title = other === "light" ? "Light window" : "Dark window";
  $("theme").setAttribute("aria-label", `Switch to the ${other} window`);
}

$("theme").onclick = () => {
  const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = theme;
  try {
    localStorage.setItem("goldbook-theme", theme);
  } catch {
    // Without storage the choice lasts until the page is left.
  }
  drawTheme();
};

window.onhashchange = render;
drawRail();
drawTheme();
// The rail shows the session and the last scan on every view. A failure
// leaves them blank; the view reports its own.
loadSession().catch(() => {});
api("/api/realms").then(({ realms }) => {
  realmList = realms;
  drawLastScan();
}, () => {});
// A server without Battle.net, or one from before website sign-in, offers only
// the ID and key. With Battle.net they fold away under it.
api("/api/auth/battlenet/status").then(({ web }) => {
  const battlenet = web === true;
  $("battlenet").hidden = !battlenet;
  $("key-login").querySelector("summary").hidden = !battlenet;
  $("key-login").open = !battlenet;
}, () => {});
render();
