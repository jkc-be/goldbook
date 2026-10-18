-- Shows the Goldbook window without the game. Loads the addon into the
-- simulated client with a few weeks of made-up prices, records what every
-- widget is told (anchors, sizes, text, colours, fonts), opens each view and
-- writes <outdir>/<view>.json, a page that lays the widgets out the way the
-- client would (<view>.html) and a screenshot of that page cropped to the
-- window (<view>.png). It approximates the game; it is not pixel-exact.
--
--   luajit addon/tests/preview.lua [--client] [--dpr <n>] [--addon <folder>] <outdir>
--
-- --client draws every pixel the way the game client measured in client.lua
-- does, --dpr renders at that many device pixels per point, as a Retina
-- screen does, and --addon previews another copy of the Goldbook folder.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local USAGE = "usage: luajit addon/tests/preview.lua [--client] [--dpr <n>] [--addon <folder>] <outdir>"
local flags = { dpr = 1, addon = here .. "/../Goldbook" }
local outdir
do
  local index = 1
  while arg[index] do
    local word = arg[index]
    if word == "--client" then
      flags.client = true
    elseif word == "--dpr" or word == "--addon" then
      index = index + 1
      flags[word:sub(3)] = assert(arg[index], USAGE)
    else
      assert(not outdir and word:sub(1, 2) ~= "--", USAGE)
      outdir = word
    end
    index = index + 1
  end
end
outdir = assert(outdir, USAGE)
local DPR = assert(tonumber(flags.dpr), USAGE)
local Stub = dofile(here .. "/wowstub.lua")
local Client = dofile(here .. "/client.lua")

local SCREEN_WIDTH, SCREEN_HEIGHT = 1280, 800
local DAY = 24 * 3600

-- Recording. records[widget] holds what the stub does not keep: kind, parent,
-- every anchor, sizes and looks. Text, shown and checked are read from the
-- stub's own fields when a snapshot is taken, with rawget, because the stub
-- answers any missing key with a no-op function.

local order, records = {}, {}

local function idOf(widget)
  if type(widget) == "string" then
    widget = _G[widget]
  end
  return type(widget) == "table" and records[widget] and records[widget].id or nil
end

-- Each recorder gets the stub's own method as `original` and must call it,
-- so that the addon reads back what the stub would have told it.
local recorders = {}

local function track(widget, kind)
  local rec = { id = #order + 1, kind = kind, points = {} }
  order[rec.id], records[widget] = widget, rec
  local stubIndex = getmetatable(widget).__index
  setmetatable(widget, {
    __index = function(_, key)
      local record = recorders[key]
      if record then
        return function(self, ...)
          return record(self, stubIndex(self, key), ...)
        end
      end
      return stubIndex(widget, key)
    end,
  })
  return rec
end

-- Setters kept as given: their one argument, or the list of them.
local SETTERS = {
  SetWidth = "width",
  SetHeight = "height",
  SetJustifyH = "justifyH",
  SetWordWrap = "wordWrap",
  SetTextColor = "textColor",
  SetTextInsets = "insets",
  SetVertexColor = "vertexColor",
  SetTexture = "texture",
  SetDrawLayer = "layer",
  SetBackdrop = "backdrop",
  SetBackdropColor = "backdropColor",
  SetBackdropBorderColor = "borderColor",
  SetAlpha = "alpha",
  SetFrameStrata = "strata",
  SetFrameLevel = "level",
  SetThickness = "thickness",
  SetScale = "scale",
  SetTexCoord = "texCoord",
  SetMinMaxValues = "range",
  SetValue = "value",
}
for method, field in pairs(SETTERS) do
  recorders[method] = function(self, original, ...)
    records[self][field] = select("#", ...) > 1 and { ... } or (...)
    return original(self, ...)
  end
end
-- A font object is kept as its widget's id, a template font as its name.
local function fontRecorder(self, original, font)
  records[self].font = idOf(font) or font
  return original(self, font)
end
recorders.SetFontObject = fontRecorder
recorders.SetNormalFontObject = fontRecorder
function recorders.SetFont(self, original, file, size, outline)
  records[self].face = { file = file, size = size, outline = outline ~= "" and outline or nil }
  return original(self, file, size, outline)
end
-- Colour objects or, from older clients, plain numbers, kept as two { r, g, b, a }.
function recorders.SetGradient(self, original, orientation, from, to, ...)
  local function rgba(color)
    return { color.r, color.g, color.b, color.a or 1 }
  end
  records[self].gradient = { orientation = orientation, from = rgba(from), to = rgba(to) }
  return original(self, orientation, from, to, ...)
end
function recorders.SetGradientAlpha(self, original, orientation, ...)
  local r1, g1, b1, a1, r2, g2, b2, a2 = ...
  records[self].gradient = { orientation = orientation, from = { r1, g1, b1, a1 }, to = { r2, g2, b2, a2 } }
  return original(self, orientation, ...)
end
function recorders.SetColorTexture(self, original, ...)
  records[self].color, records[self].gradient = { ... }, nil
  return original(self, ...)
end
function recorders.SetParent(self, original, parent)
  records[self].parent = idOf(parent)
  return original(self, parent)
end

local FLAGS = {
  LockHighlight = { "highlight", true },
  UnlockHighlight = { "highlight", false },
  Enable = { "enabled", true },
  Disable = { "enabled", false },
}
for method, flag in pairs(FLAGS) do
  recorders[method] = function(self, original, ...)
    records[self][flag[1]] = flag[2]
    return original(self, ...)
  end
end
function recorders.SetEnabled(self, original, enabled)
  records[self].enabled = enabled and true or false
  return original(self, enabled)
end

function recorders.SetSize(self, original, width, height)
  local rec = records[self]
  rec.width, rec.height = width, height
  return original(self, width, height)
end

-- SetPoint(point [, relativeTo [, relativePoint]] [, x, y]); a missing
-- relativeTo means the parent. A point replaces the one of the same name.
function recorders.SetPoint(self, original, ...)
  local point, relativeTo, relativePoint, x, y = ...
  if type(relativeTo) == "number" then
    relativeTo, relativePoint, x, y = nil, nil, relativeTo, relativePoint
  elseif type(relativePoint) == "number" then
    relativePoint, x, y = nil, relativePoint, x
  end
  local points = records[self].points
  for index, old in ipairs(points) do
    if old.point == point then
      table.remove(points, index)
      break
    end
  end
  points[#points + 1] = {
    point = point,
    relativeTo = idOf(relativeTo),
    relativePoint = relativePoint or point,
    x = x or 0,
    y = y or 0,
  }
  return original(self, ...)
end
-- The client places a scroll frame's child at its top left, scrolled to the top.
function recorders.SetScrollChild(self, original, child)
  recorders.SetPoint(child, function() end, "TOPLEFT", self, "TOPLEFT", 0, 0)
  return original(self, child)
end
function recorders.ClearAllPoints(self, original)
  records[self].points = {}
  return original(self)
end
function recorders.SetAllPoints(self, original, target)
  local relativeTo = idOf(target)
  records[self].points = {
    { point = "TOPLEFT", relativeTo = relativeTo, relativePoint = "TOPLEFT", x = 0, y = 0 },
    { point = "BOTTOMRIGHT", relativeTo = relativeTo, relativePoint = "BOTTOMRIGHT", x = 0, y = 0 },
  }
  return original(self, target)
end

-- The stub may not make a kind of region yet (lines); the preview then makes it.
local function region(kind)
  return function(self, original, name, layer, template, sublevel)
    local widget = original(self, name, layer, template, sublevel) or Stub.widget()
    local rec = records[widget]
    rec.kind, rec.parent, rec.layer, rec.template, rec.sublevel = kind, records[self].id, layer, template, sublevel
    return widget
  end
end
recorders.CreateTexture = region("Texture")
recorders.CreateFontString = region("FontString")
recorders.CreateLine = region("Line")

-- Line:SetStartPoint(relativePoint [, relativeTo] [, x, y]), relativeTo
-- defaulting to the parent; the end point likewise.
local function lineEnd(field)
  return function(self, original, ...)
    local relativePoint, relativeTo, x, y = ...
    if type(relativeTo) == "number" then
      relativeTo, x, y = nil, relativeTo, x
    end
    records[self][field] = { relativePoint = relativePoint, relativeTo = idOf(relativeTo), x = x or 0, y = y or 0 }
    return original(self, ...)
  end
end
recorders.SetStartPoint = lineEnd("startPoint")
recorders.SetEndPoint = lineEnd("endPoint")

-- Tooltips: where SetOwner anchors them, and their lines with colours.
local TOOLTIP_ANCHORS = {
  ANCHOR_RIGHT = { "BOTTOMLEFT", "TOPRIGHT" },
  ANCHOR_LEFT = { "BOTTOMRIGHT", "TOPLEFT" },
  ANCHOR_TOP = { "BOTTOM", "TOP" },
  ANCHOR_BOTTOM = { "TOP", "BOTTOM" },
}
local NORMAL_COLOR = { 1, 0.82, 0 }

function recorders.SetOwner(self, original, owner, anchor)
  local points = TOOLTIP_ANCHORS[anchor] or TOOLTIP_ANCHORS.ANCHOR_RIGHT
  local rec = records[self]
  rec.points = { { point = points[1], relativeTo = idOf(owner), relativePoint = points[2], x = 0, y = 0 } }
  rec.lines = {}
  return original(self, owner, anchor)
end
function recorders.ClearLines(self, original)
  records[self].lines = {}
  return original(self)
end
function recorders.AddLine(self, original, text, r, g, b)
  local rec = records[self]
  rec.lines = rec.lines or {}
  rec.lines[#rec.lines + 1] = { left = text, leftColor = r and { r, g, b } or NORMAL_COLOR }
  return original(self, text, r, g, b)
end
function recorders.AddDoubleLine(self, original, left, right, lr, lg, lb, rr, rg, rb)
  local rec = records[self]
  rec.lines = rec.lines or {}
  rec.lines[#rec.lines + 1] = {
    left = left,
    right = right,
    leftColor = lr and { lr, lg, lb } or NORMAL_COLOR,
    rightColor = rr and { rr, rg, rb } or NORMAL_COLOR,
  }
  return original(self, left, right, lr, lg, lb, rr, rg, rb)
end
-- The client fills an item tooltip with the item's name, then runs the
-- post-calls addons registered; Goldbook's lines come from those.
function recorders.SetHyperlink(self, original, link)
  local result = original(self, link)
  local name, _, quality = C_Item.GetItemInfo(link)
  local color = ITEM_QUALITY_COLORS[quality]
  records[self].lines = { { left = name and ((color and color.hex or "") .. name .. "|r") or "Retrieving item information" } }
  self.itemName, self.itemLink = name, link
  for _, call in ipairs(Stub.tooltipCalls) do
    call(self)
  end
  return result
end

for _, widget in ipairs(Stub.frames) do
  local name = rawget(widget, "name")
  track(widget, name and name:find("Tooltip$") and "GameTooltip" or "Frame")
end
local stubWidget, stubCreateFrame = Stub.widget, CreateFrame
function Stub.widget(name)
  local widget = stubWidget(name)
  track(widget, "Frame")
  return widget
end
function CreateFrame(kind, name, parent, template)
  local widget = stubCreateFrame(kind, name, parent, template)
  local rec = records[widget]
  rec.kind, rec.parent, rec.template = kind, idOf(parent), template
  return widget
end

-- The parts of the screen the stub leaves out.
UIParent:SetSize(SCREEN_WIDTH, SCREEN_HEIGHT)
AuctionHouseFrame:SetSize(800, 450)
AuctionHouseFrame:SetPoint("CENTER")
Minimap:SetSize(140, 140)
Minimap:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -17, -22)
GameTooltip:SetFrameStrata("TOOLTIP")
ITEM_QUALITY_COLORS[0] = { hex = "|cff9d9d9d" }
ITEM_QUALITY_COLORS[3] = { hex = "|cff0070dd" }
ITEM_QUALITY_COLORS[4] = { hex = "|cffa335ee" }
-- Any file ID will do: the page draws every icon the same.
function C_Item.GetItemIconByID()
  return 134400
end

-- Output.

local function json(value)
  local kind = type(value)
  if kind == "table" then
    local parts = {}
    if #value > 0 or next(value) == nil then
      for index, item in ipairs(value) do
        parts[index] = json(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for index, key in ipairs(keys) do
      parts[index] = json(tostring(key)) .. ":" .. json(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(char)
      return ("\\u%04x"):format(char:byte())
    end) .. '"'
  elseif kind == "number" then
    return ("%.14g"):format(value)
  end
  return tostring(value)
end

-- Lays a snapshot out the way the client would and draws it into `screen`.
-- WoW y grows upward from the bottom of UIParent; a point says "my P sits on
-- relativeTo's RP, plus (x, y)". Leaves the crop box (the focus widgets plus
-- 20px) and any layout warnings on <body> for preview.lua to read.
local LAYOUT = [==[
function layout(snapshot, screen) {
  const [W, H] = snapshot.screen;
  const STRATA = ["BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"];
  const GOLD = "rgb(255,209,0)", WHITE = "rgb(255,255,255)", GREY = "rgb(128,128,128)";
  const FACE = '"Friz Quadrata TT", Georgia, serif';
  // Marcellus stands in for Friz Quadrata, which a browser does not have,
  // with Optima's digits, as Friz has lining figures and Marcellus has not.
  const FACES = { friz: '"Friz digits", "Marcellus", "Friz Quadrata TT", Georgia, serif', narrow: '"Arial Narrow", "Roboto Condensed", sans-serif' };
  const LAYERS = ["BACKGROUND", "BORDER", "ARTWORK", "OVERLAY", "HIGHLIGHT"];
  const PANEL = { background: "rgba(0,0,0,0.85)", border: "2px solid rgb(150,135,100)", borderRadius: "4px" };
  const TEMPLATE_SIZE = { UIPanelCloseButton: [24, 24], UICheckButtonTemplate: [20, 20] };
  const SCREEN_RECT = { left: 0, bottom: 0, right: W, top: H };
  const byId = new Map(snapshot.widgets.map(w => [w.id, w]));
  const measured = new Map(), rects = new Map(), elements = new Map(), warnings = [];
  const describe = w => `${w.kind} ${w.name || "#" + w.id}${w.template ? " (" + w.template + ")" : ""}`;
  const rgba = c => `rgba(${c.slice(0, 3).map(v => Math.round(v * 255)).join(",")},${c[3] ?? 1})`;
  const escape = s => s.replace(/[&<>]/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[ch]);
  const isIcon = w => typeof w.texture === "number" || /^Interface[\\/]Icons[\\/]/i.test(w.texture || "");
  // A frame's sizes and offsets count in its own units: its scale times its parent's.
  const scaleOf = w => (w.scale ?? 1) * (byId.has(w.parent) ? scaleOf(byId.get(w.parent)) : 1);

  // A template font by its name, or a font object made with CreateFont by
  // its id: that one has its own face and size, white and without a shadow.
  function font(name = "GameFontNormal") {
    const object = typeof name === "number" ? byId.get(name) : null;
    if (object && object.face) {
      const family = /FRIZ/i.test(object.face.file) ? FACES.friz : FACES.narrow;
      return { size: object.face.size, color: WHITE, family, flat: true, outline: object.face.outline };
    }
    const size = /Small/.test(name) ? 10 : /Large/.test(name) ? 16 : 12;
    const color = /Disable/.test(name) ? GREY : /Highlight|Chat|Tooltip/.test(name) ? WHITE : GOLD;
    return { size, color };
  }
  function setFont(el, size, color, family = FACE, flat = false, outline = null) {
    const shadow = outline ? "-1px 0 0 #000, 1px 0 0 #000, 0 -1px 0 #000, 0 1px 0 #000" : flat ? "none" : "1px 1px 0 #000";
    Object.assign(el.style, { font: `${size}px/${size + 2}px ${family}`, color, textShadow: shadow });
  }
  // |T path or fileID:height[:width...]|t. A height of 0 follows the text.
  // Money icons are coins; anything else is an icon square.
  function inlineTexture(spec) {
    const [path, height, width] = spec.split(":");
    const h = Number(height) ? `${Number(height)}px` : "1em", w = Number(width) ? `${Number(width)}px` : h;
    const coin = /gold/i.test(path) ? "#e8c34a" : /silver/i.test(path) ? "#c7c7cf" : /copper/i.test(path) ? "#c8763a" : null;
    const look = coin ? `border-radius:50%;background:${coin}` : "background:linear-gradient(135deg,#7a6440,#2b2116);box-shadow:inset 0 0 0 1px #9d9d9d";
    return `<span style="display:inline-block;width:${w};height:${h};vertical-align:middle;${look}"></span>`;
  }
  function markup(text) {
    let html = "", open = 0;
    const tokens = /\|c([0-9a-fA-F]{8})|\|r|\|T([^|]*)\|t|\|H[^|]*\|h|\|h|\|\||\|n|[^|]+|\|/g;
    for (const [token, color, texture] of String(text ?? "").matchAll(tokens)) {
      if (color) { html += `<span style="color:#${color.slice(2)}">`; open++; }
      else if (token === "|r") { if (open) { html += "</span>"; open--; } }
      else if (texture !== undefined) html += inlineTexture(texture);
      else if (token === "||") html += "|";
      else if (token === "|n") html += "\n";
      else if (!token.startsWith("|H") && token !== "|h") html += escape(token);
    }
    return html + "</span>".repeat(open);
  }
  function text(el, w, fontName, color) {
    const f = font(fontName);
    setFont(el, f.size * scaleOf(w), color || f.color, f.family, f.flat, f.outline);
    const inner = document.createElement("div");
    inner.style.whiteSpace = "pre";
    inner.innerHTML = markup(w.text);
    el.append(inner);
    return inner;
  }
  function frame(el, w) {
    if (!w.backdrop) return;
    Object.assign(el.style, PANEL);
    if (/WHITE8X8/i.test(w.backdrop.edgeFile || "")) Object.assign(el.style, { border: `${w.backdrop.edgeSize * scaleOf(w)}px solid`, borderRadius: "0" });
    if (w.backdropColor) el.style.background = rgba(w.backdropColor);
    if (w.borderColor) el.style.borderColor = rgba(w.borderColor);
  }
  const centred = { display: "flex", alignItems: "center", justifyContent: "center" };
  const DRAW = {
    FontString(el, w) {
      const inner = text(el, w, w.font || w.template, w.textColor && rgba(w.textColor));
      Object.assign(el.style, { display: "flex", flexDirection: "column", justifyContent: "center" });
      inner.style.textAlign = (w.justifyH || "CENTER").toLowerCase();
      if (w.width) {
        if (w.wordWrap !== false) inner.style.whiteSpace = "pre-wrap";
        Object.assign(inner.style, { overflow: "hidden", textOverflow: "ellipsis" });
      }
    },
    // A highlight shows only on the frame the preview hovers. The portrait
    // mask is a white disc, tinted by its vertex colour or gradient.
    Texture(el, w) {
      const owner = byId.get(w.parent);
      if (w.layer === "HIGHLIGHT" && !(owner && (owner.hover || owner.highlight))) { el.style.display = "none"; return; }
      const disc = /AlphaMask/i.test(w.texture || "");
      if (disc) el.style.borderRadius = "50%";
      // Part of a disc, as SetTexCoord crops it: the whole disc inside a clipping box.
      if (disc && w.texCoord) {
        const [l, r, t, b] = w.texCoord, whole = document.createElement("div");
        Object.assign(whole.style, { position: "absolute", borderRadius: "50%", background: rgba(w.vertexColor || [1, 1, 1]),
          width: `${100 / (r - l)}%`, height: `${100 / (b - t)}%`, left: `${-100 * l / (r - l)}%`, top: `${-100 * t / (b - t)}%` });
        Object.assign(el.style, { borderRadius: "0", overflow: "hidden" });
        el.append(whole);
        return;
      }
      const g = w.gradient;
      if (g) el.style.background = `linear-gradient(${g.orientation === "HORIZONTAL" ? "to right" : "to top"}, ${rgba(g.from)}, ${rgba(g.to)})`;
      else if (disc) el.style.background = rgba(w.vertexColor || [1, 1, 1]);
      else if (w.color) el.style.background = rgba(w.color);
      else if (isIcon(w)) Object.assign(el.style, { background: "linear-gradient(135deg,#7a6440,#2b2116)", border: `1px solid ${w.vertexColor ? rgba(w.vertexColor) : GREY}` });
      else if (w.texture) Object.assign(el.style, { background: "rgba(255,255,255,0.08)", border: "1px solid rgba(255,255,255,0.35)" });
    },
    Line(el, w) {
      el.style.background = rgba(w.color || w.vertexColor || [1, 1, 1]);
    },
    GameTooltip(el, w) {
      Object.assign(el.style, PANEL, { padding: "6px 9px" });
      (w.lines || []).forEach((line, index) => {
        const row = document.createElement("div");
        Object.assign(row.style, { display: "flex", justifyContent: "space-between", gap: "16px", whiteSpace: "pre" });
        for (const [part, color] of [[line.left, line.leftColor], [line.right, line.rightColor]]) {
          if (part === undefined) continue;
          const span = document.createElement("span");
          setFont(span, index === 0 ? 14 : 12, color ? rgba(color) : WHITE);
          span.innerHTML = markup(part);
          row.append(span);
        }
        el.append(row);
      });
    },
    UIPanelButtonTemplate(el, w) {
      const enabled = w.enabled !== false;
      const background = !enabled ? "linear-gradient(#5a5a5a,#303030)"
        : w.highlight ? "linear-gradient(#c8321f,#7c160d)" : "linear-gradient(#8e1d12,#4c0b06)";
      Object.assign(el.style, centred, { background, border: "1px solid #1c0402", borderRadius: "4px" });
      text(el, w, !enabled ? "GameFontDisable" : w.highlight ? "GameFontHighlight" : w.font || "GameFontNormal");
    },
    UIPanelCloseButton(el) {
      Object.assign(el.style, centred, { background: "#8e1d12", border: "1px solid #d4b05a", borderRadius: "3px", fontWeight: "bold" });
      setFont(el, 14, WHITE);
      el.textContent = "X";
    },
    // An edit box without a template: its backdrop, and its text past the insets.
    EditBox(el, w) {
      frame(el, w);
      Object.assign(el.style, { display: "flex", alignItems: "center", paddingLeft: `${(w.insets || [0])[0]}px` });
      text(el, w, w.font, w.textColor && rgba(w.textColor));
    },
    // The template's border reaches 5px left of the box; its text starts at the box's edge.
    InputBoxTemplate(el, w) {
      const border = document.createElement("div");
      Object.assign(border.style, { position: "absolute", left: "-5px", right: "0", top: "0", bottom: "0", background: "rgba(0,0,0,0.6)", border: "1px solid rgba(220,220,220,0.6)", borderRadius: "3px" });
      el.append(border);
      Object.assign(el.style, { display: "flex", alignItems: "center" });
      text(el, w, w.font || "ChatFontNormal").style.position = "relative";
    },
    // A track with its thumb at the value.
    OptionsSliderTemplate(el, w) {
      const [low, high] = w.range || [0, 1], share = ((w.value ?? low) - low) / (high - low || 1);
      const track = document.createElement("div"), thumb = document.createElement("div");
      Object.assign(track.style, { position: "absolute", left: "0", right: "0", top: "50%", height: "6px", marginTop: "-3px", background: "rgba(0,0,0,0.6)", border: "1px solid rgb(120,120,120)", borderRadius: "3px" });
      Object.assign(thumb.style, { position: "absolute", top: "50%", width: "10px", height: "18px", marginTop: "-9px", left: `calc(${share * 100}% - 5px)`, background: "linear-gradient(#d8d8d8,#8a8a8a)", borderRadius: "2px" });
      el.append(track, thumb);
    },
    UICheckButtonTemplate(el, w) {
      Object.assign(el.style, centred, { background: "rgba(0,0,0,0.6)", border: "1px solid rgb(170,170,170)", borderRadius: "3px" });
      if (w.checked) { setFont(el, 16, GOLD); el.textContent = "✓"; }
    },
  };

  // On the screen: text is measured there already.
  function ownSize(w) {
    const natural = measured.get(w.id) || [];
    const fallback = TEMPLATE_SIZE[w.template] || (w.kind === "Texture" && isIcon(w) ? [16, 16] : [0, 0]);
    const scale = scaleOf(w);
    return [w.width !== undefined ? w.width * scale : natural[0] ?? fallback[0] * scale,
      w.height !== undefined ? w.height * scale : natural[1] ?? fallback[1] * scale];
  }
  const hFraction = p => p.includes("LEFT") ? 0 : p.includes("RIGHT") ? 1 : 0.5;
  const vFraction = p => p.startsWith("TOP") ? 1 : p.startsWith("BOTTOM") ? 0 : 0.5;
  // Each constraint is [fraction, at]: the spot `fraction` of the way along
  // the widget sits at `at`. Two different spots fix the length.
  function axis(constraints, length) {
    const [fraction, at] = constraints[0];
    const other = constraints.find(([f]) => f !== fraction);
    if (other) length = (other[1] - at) / (other[0] - fraction);
    const start = at - fraction * length;
    return [start, start + length];
  }
  // Where a point's relativePoint on relativeTo (or w's parent) is, plus (x, y).
  function spot(p, w) {
    const target = rect(p.relativeTo ?? w.parent);
    if (!target) { warnings.push(`${describe(w)} is anchored to a widget without a place`); return null; }
    const scale = scaleOf(w);
    return [target.left + (target.right - target.left) * hFraction(p.relativePoint) + p.x * scale,
      target.bottom + (target.top - target.bottom) * vFraction(p.relativePoint) + p.y * scale];
  }
  function rect(id) {
    if (id === undefined) return SCREEN_RECT;
    if (rects.has(id)) return rects.get(id);
    rects.set(id, null);
    const w = byId.get(id);
    let result = null;
    if (w.name === "UIParent") result = SCREEN_RECT;
    else if (!w.points.length) warnings.push(`${describe(w)} has no anchor`);
    else {
      const xs = [], ys = [];
      for (const p of w.points) {
        const at = spot(p, w);
        if (!at) continue;
        xs.push([hFraction(p.point), at[0]]);
        ys.push([vFraction(p.point), at[1]]);
      }
      if (xs.length) {
        const [width, height] = ownSize(w);
        const [left, right] = axis(xs, width), [bottom, top] = axis(ys, height);
        result = { left, right, bottom, top };
      }
    }
    rects.set(id, result);
    return result;
  }
  function strata(w) {
    return w.strata || (byId.has(w.parent) ? strata(byId.get(w.parent)) : "MEDIUM");
  }
  // A frame sits a level above its parent; regions draw at their frame's level.
  function level(w) {
    const parent = byId.has(w.parent) ? level(byId.get(w.parent)) : 0;
    if (["Texture", "FontString", "Line"].includes(w.kind)) return parent;
    return w.level ?? parent + 1;
  }
  function placeRect(el, w) {
    const r = rect(w.id);
    if (!r) return false;
    Object.assign(el.style, { left: `${r.left}px`, top: `${H - r.top}px`, width: `${r.right - r.left}px`, height: `${r.top - r.bottom}px` });
    return true;
  }
  // A thin div from the start point, rotated to reach the end point.
  function placeLine(el, w) {
    if (!w.startPoint || !w.endPoint) { warnings.push(`${describe(w)} lacks a start or end point`); return false; }
    const from = spot(w.startPoint, w), to = spot(w.endPoint, w);
    if (!from || !to) return false;
    const [dx, dy] = [to[0] - from[0], from[1] - to[1]], thickness = (w.thickness ?? 1) * scaleOf(w);
    Object.assign(el.style, {
      left: `${from[0]}px`, top: `${H - from[1] - thickness / 2}px`, width: `${Math.hypot(dx, dy)}px`, height: `${thickness}px`,
      transformOrigin: `0 ${thickness / 2}px`, transform: `rotate(${Math.atan2(dy, dx)}rad)`,
    });
    return true;
  }

  const drawn = snapshot.widgets.filter(w => w.draw);
  for (const w of drawn) {
    const el = document.createElement("div");
    el.title = describe(w);
    Object.assign(el.style, { position: "absolute", boxSizing: "border-box", visibility: "hidden" });
    (DRAW[w.template] || DRAW[w.kind] || frame)(el, w);
    if (w.alpha !== undefined) el.style.opacity = w.alpha;
    screen.append(el);
    elements.set(w.id, el);
    if (w.kind === "FontString" || w.kind === "GameTooltip") {
      if (w.width) el.style.width = `${w.width * scaleOf(w)}px`;
      const box = el.getBoundingClientRect();
      measured.set(w.id, [Math.ceil(box.width), Math.ceil(box.height)]);
    }
  }
  // Regions draw over their frame's backdrop, by layer and sublevel.
  const layer = w => ["Texture", "FontString", "Line"].includes(w.kind) ? LAYERS.indexOf(w.layer || "ARTWORK") : -1;
  const stacking = w => [STRATA.indexOf(strata(w)), level(w), layer(w), w.sublevel ?? 0, w.id];
  const below = (a, b) => {
    const [x, y] = [stacking(a), stacking(b)];
    return x[0] - y[0] || x[1] - y[1] || x[2] - y[2] || x[3] - y[3] || x[4] - y[4];
  };
  [...drawn].sort(below).forEach((w, index) => {
    const el = elements.get(w.id);
    if (!(w.kind === "Line" ? placeLine : placeRect)(el, w)) { el.remove(); return; }
    Object.assign(el.style, { zIndex: index + 1, visibility: "visible" });
  });

  const focus = snapshot.focus.map(rect).filter(Boolean);
  const x0 = Math.max(0, Math.floor(Math.min(...focus.map(r => r.left)) - 20));
  const y0 = Math.max(0, Math.floor(H - Math.max(...focus.map(r => r.top)) - 20));
  const x1 = Math.min(W, Math.ceil(Math.max(...focus.map(r => r.right)) + 20));
  const y1 = Math.min(H, Math.ceil(H - Math.min(...focus.map(r => r.bottom)) + 20));
  document.body.dataset.crop = [x0, y0, x1 - x0, y1 - y0].join(",");
  if (warnings.length) document.body.dataset.warnings = warnings.join("; ");
}
]==]

-- The client's transfer as an SVG filter over the whole screen, on sRGB
-- values as it was measured.
local function clientFilter()
  local channel = ('type="linear" slope="%g" intercept="%g"'):format(Client.gain, Client.offset)
  return table.concat({
    '<svg width="0" height="0" style="position:absolute"><filter id="client" color-interpolation-filters="sRGB">',
    "<feComponentTransfer><feFuncR ", channel, "/><feFuncG ", channel, "/><feFuncB ", channel, "/></feComponentTransfer>",
    "</filter></svg>\n",
  })
end

local function page(view, data)
  return table.concat({
    '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>Goldbook preview: ', view, "</title>\n",
    "<style>body { margin: 0; background: #777; } #screen { position: relative; overflow: hidden; width: ",
    SCREEN_WIDTH, "px; height: ", SCREEN_HEIGHT, "px;", flags.client and " filter: url(#client);" or "", " }\n",
    '@font-face { font-family: "Friz digits"; src: local("Optima Regular"), local("Optima"); unicode-range: U+0030-0039; }</style>\n',
    '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Marcellus&display=block">\n',
    "</head><body>", flags.client and clientFilter() or "", '<div id="screen"></div>\n<script>\n', LAYOUT,
    -- Text is measured for the layout, so the faces must have loaded first.
    '\nPromise.all([document.fonts.load(\'16px "Marcellus"\'), document.fonts.load(\'14px "Arial Narrow"\'), document.fonts.load(\'14px "Friz digits"\', "0")])',
    '.catch(() => {}).then(() => layout(', (data:gsub("</", "<\\/")),
    ', document.getElementById("screen")));\n</script></body></html>\n',
  })
end

local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function sh(command)
  local status = os.execute(command)
  assert(status == 0 or status == true, "failed: " .. command)
end

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function output(command)
  local pipe = io.popen(command)
  local text = pipe:read("*a")
  pipe:close()
  return text
end

local CHROME = ("google-chrome --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=10000 --window-size=%d,%d --force-device-scale-factor=%g ")
  :format(SCREEN_WIDTH, SCREEN_HEIGHT, DPR)
local root = outdir:sub(1, 1) == "/" and outdir or (output("pwd"):match("[^\n]+") .. "/" .. outdir)
sh("mkdir -p " .. quote(root))

-- The visible widgets under `roots`, plus the widgets they are placed by
-- (parents and anchor targets), which are laid out but not drawn.
local function snapshot(roots, focus)
  local isRoot, drawn, included = {}, {}, {}
  for _, widget in ipairs(roots) do
    isRoot[widget] = true
  end
  local function isDrawn(widget)
    if drawn[widget] == nil then
      local parent = order[records[widget].parent or 0]
      drawn[widget] = rawget(widget, "shown") and (isRoot[widget] or (parent ~= nil and isDrawn(parent))) or false
    end
    return drawn[widget]
  end
  local function include(widget)
    if included[widget] then
      return
    end
    included[widget] = true
    local rec = records[widget]
    if rec.parent then
      include(order[rec.parent])
    end
    if type(rec.font) == "number" then
      include(order[rec.font])
    end
    for _, point in pairs({ rec.startPoint, rec.endPoint, unpack(rec.points) }) do
      if point.relativeTo then
        include(order[point.relativeTo])
      end
    end
  end
  for _, widget in ipairs(order) do
    if isDrawn(widget) then
      include(widget)
    end
  end

  local widgets, focusIds = {}, {}
  for _, widget in ipairs(order) do
    if included[widget] then
      local entry = {}
      for key, value in pairs(records[widget]) do
        entry[key] = value
      end
      local text = rawget(widget, "text")
      entry.name, entry.checked, entry.draw = rawget(widget, "name"), rawget(widget, "checked"), drawn[widget] or nil
      entry.text = text ~= "" and text or nil
      widgets[#widgets + 1] = entry
    end
  end
  for index, widget in ipairs(focus) do
    focusIds[index] = records[widget].id
  end
  return { screen = { SCREEN_WIDTH, SCREEN_HEIGHT }, focus = focusIds, widgets = widgets }
end

-- Draws the visible widgets under `roots` and crops to the `focus` widgets.
local function capture(view, roots, focus)
  local data = snapshot(roots, focus)
  data.view = view
  local base = root .. "/" .. view
  local encoded = json(data)
  write(base .. ".json", encoded)
  write(base .. ".html", page(view, encoded))

  local url = quote("file://" .. base .. ".html")
  -- Chrome is sometimes killed when memory runs short, so each step gets three tries.
  local dom, x, y, width, height
  for _ = 1, 3 do
    dom = output(CHROME .. "--dump-dom " .. url .. " 2>/dev/null")
    x, y, width, height = dom:match('data%-crop="(%d+),(%d+),(%d+),(%d+)"')
    if x then
      break
    end
  end
  assert(x, view .. ": the page did not lay out; open " .. base .. ".html in a browser to see why")
  x, y, width, height = x * DPR, y * DPR, width * DPR, height * DPR
  local shot = CHROME .. "--screenshot=" .. quote(base .. ".png") .. " " .. url .. " >/dev/null 2>&1"
  local status = os.execute(shot)
  for _ = 2, 3 do
    if status == 0 or status == true then
      break
    end
    status = os.execute(shot)
  end
  assert(status == 0 or status == true, "failed: " .. shot)
  -- Without dates in the file, two runs of an unchanged UI give identical PNGs.
  sh(("magick %s -crop %dx%d+%d+%d +repage -strip -define png:exclude-chunks=date,time %s")
    :format(quote(base .. ".png"), width, height, x, y, quote(base .. ".png")))
  io.write(("%s/%s.png %dx%d\n"):format(outdir, view, width, height))
  local warnings = dom:match('data%-warnings="([^"]*)"')
  if warnings then
    io.write("  warning: " .. warnings .. "\n")
  end
end

-- The addon, as run.lua loads it.

local ns = Stub.loadAddon(flags.addon)
local Codec, Database = ns.Codec, ns.Database

-- A realm after four weeks of scanning. Prices in copper.
-- { key, name, quality, vendor, price, listed } plus, optionally: base (the
-- name GetItemInfo gives a suffixed item), trend (change per day), deal (today's
-- lowest price as a share of the usual), absent (days since last seen),
-- vendorDeal (first seen today, listed under what a vendor pays), seen (the
-- days it was seen, as { days ago, lowest price, listed, market value }),
-- scans (each day seen in the last week as that many scans, so many hours
-- apart: { count, every }). Items without a price are only in the bags.
local ITEMS = {
  -- The four days of the in-game screenshot client.lua was measured from.
  { "2776", "Gold Ore", 2, 500, 1024, 183, seen = { { 4, 860, 262, 860 }, { 2, 1188, 241, 1191 }, { 1, 799, 241, 800 }, { 0, 1958, 183, 1959 } },
    scans = { 3, 3 } },
  { "2589", "Linen Cloth", 1, 13, 140, 400 },
  { "2592", "Wool Cloth", 1, 33, 210, 300 },
  { "4306", "Silk Cloth", 1, 150, 380, 260 },
  { "4338", "Mageweave Cloth", 1, 250, 520, 340 },
  { "14047", "Runecloth", 1, 400, 690, 900, trend = 0.006 },
  { "14256", "Felcloth", 1, 2000, 21500, 14 },
  { "4305", "Bolt of Silk Cloth", 1, 600, 720, 6, vendorDeal = true },
  { "2770", "Copper Ore", 1, 5, 95, 180 },
  { "2771", "Tin Ore", 1, 25, 160, 90 },
  { "2772", "Iron Ore", 1, 150, 410, 120 },
  { "3858", "Mithril Ore", 1, 250, 520, 200 },
  { "10620", "Thorium Ore", 1, 250, 1250, 420, trend = -0.008 },
  { "7911", "Truesilver Ore", 1, 500, 5200, 35 },
  { "12359", "Thorium Bar", 1, 600, 1700, 160, deal = 0.52 },
  { "12360", "Arcanite Bar", 2, 2000, 345000, 12 },
  { "2447", "Peacebloom", 1, 4, 38, 260 },
  { "765", "Silverleaf", 1, 4, 42, 300 },
  { "3356", "Kingsblood", 1, 30, 260, 120 },
  { "4625", "Firebloom", 1, 50, 310, 80 },
  { "8831", "Purple Lotus", 1, 60, 420, 140 },
  { "13464", "Golden Sansam", 1, 50, 1500, 110 },
  { "13463", "Dreamfoil", 1, 50, 2100, 90, trend = 0.012 },
  { "13465", "Mountain Silversage", 1, 60, 3200, 75 },
  { "13467", "Icecap", 1, 60, 2600, 40, absent = 3 },
  { "8846", "Gromsblood", 1, 30, 850, 95 },
  { "13468", "Black Lotus", 2, 1000, 860000, 4, deal = 0.58, trend = 0.01, scans = { 14, 1 } },
  { "13446", "Major Healing Potion", 1, 250, 2600, 60 },
  { "13444", "Major Mana Potion", 1, 300, 3100, 45 },
  { "3928", "Superior Healing Potion", 1, 250, 820, 70 },
  { "13452", "Elixir of the Mongoose", 1, 1000, 41000, 18, trend = 0.009 },
  { "13457", "Greater Fire Protection Potion", 1, 1000, 24500, 22, absent = 5 },
  { "13510", "Flask of the Titans", 1, 3000, 1050000, 3 },
  { "12808", "Essence of Undeath", 1, 1000, 14500, 30 },
  { "7078", "Essence of Fire", 1, 1000, 39000, 12, deal = 0.6 },
  { "16204", "Illusion Dust", 1, 250, 9800, 140 },
  { "14344", "Large Brilliant Shard", 3, 0, 61000, 26 },
  { "12364", "Huge Emerald", 2, 7500, 205000, 3 },
  { "8170", "Rugged Leather", 1, 75, 430, 300 },
  { "9775:584", "Bandit Cinch of the Monkey", 2, 625, 21000, 1, base = "Bandit Cinch" },
  { "15487:1182", "Bloodspattered Wristbands of the Monkey", 2, 950, 35000, 2, base = "Bloodspattered Wristbands" },
  { "10159:1035", "Mercurial Greaves of the Tiger", 2, 2850, 120000, 1, base = "Mercurial Greaves", deal = 0.45 },
  { "9797:850", "Ivycloth Robe of Intellect", 2, 1100, 46000, 1, base = "Ivycloth Robe", absent = 4 },
  { "13047", "Twig of the World Tree", 3, 10400, 280000, 1 },
  { "2099", "Dwarven Hand Cannon", 3, 7200, 335000, 1, absent = 2 },
  { "14551", "Edgemaster's Handguards", 4, 4300, 3150000, 1 },
  { "1728", "Teebu's Blazing Longsword", 4, 8200, 2400000, 1, absent = 6 },
  { "6948", "Hearthstone", 1, 0 },
  { "2318", "Light Leather", 1, 15 },
  { "1524", "Bloodscalp Tusk", 1, 0 },
}

-- { key, count, bound }
local BAGS = {
  [0] = { { "2589", 20 }, { "2589", 13 }, { "14047", 20 }, { "10620", 9 }, { "6948", 1, true }, { "13446", 5 } },
  [1] = { { "9775:584", 1 }, { "12808", 3 }, { "13468", 1 }, { "2318", 7 }, { "1524", 4 }, { "15487:1182", 1 } },
}

-- { character, gold 30 days ago, gold on the last day played, share of days played, days since last played }
local CHARACTERS = {
  { "Sultan-Faramon", 8200000, 12400000, 0.8, 0 },
  { "Mirelle-Faramon", 3150000, 4580000, 0.35, 2 },
  { "Grokk-Faramon", 702000, 655000, 0.3, 12 },
}

-- Same numbers every run, so that previews before and after a change compare.
local seed = 20370
local function random()
  seed = seed * 16807 % 2147483647
  return seed / 2147483647
end

local TODAY = math.floor(time() / DAY)
local NOW_HOUR = math.floor(time() / 3600)
local SCAN = time() - 40 * 60
-- GetNormalizedRealmName answers only after login, which is too late to seed.
local REALM = Database.RealmKey("Faramon", UnitFactionGroup("player"))

local function scanTime(day)
  return day == TODAY and SCAN or day * DAY + 19 * 3600
end

-- Per day seen: the lowest price drifting along the trend, and a market value
-- on the days of a full scan, today's included.
local function priceHistory(item)
  if item.seen then
    local entries = {}
    for index, day in ipairs(item.seen) do
      entries[index] = { day = TODAY - day[1], min = day[2], qty = day[3], mv = day[4] }
    end
    return entries
  end
  local _, _, _, vendor, price, listed = unpack(item)
  local last = TODAY - (item.absent or 0)
  local trend = item.trend or (random() - 0.5) * 0.02
  local entries = {}
  for day = item.vendorDeal and last or TODAY - 29, last do
    if day == last or random() > 0.3 then
      local factor = (1 + trend * (day - TODAY)) * (0.92 + random() * 0.16)
      local entry = {
        day = day,
        min = math.max(1, math.floor(price * factor)),
        qty = math.max(1, math.floor(listed * (0.6 + random() * 0.8))),
        mv = (day == TODAY or day % 3 == 0) and math.floor(price * factor * 1.06) or 0,
      }
      if day == TODAY and item.deal then
        entry.min = math.floor(price * item.deal)
      end
      if item.vendorDeal then
        entry.min, entry.mv = math.floor(vendor * 0.7), math.floor(vendor * 0.7)
      end
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- A day's entry as `count` scans `every` hours apart, up to that day's scan,
-- as { hour, min, qty, mv }: the last scan is the entry, and the ones before
-- it list a little dearer and measure no market value, so that the day's
-- lowest is still the entry's. `wobble` is the item's own random stream, so
-- that the other items keep their numbers.
local function scansOf(entry, count, every, wobble)
  local last = math.floor(scanTime(entry.day) / 3600)
  local hours = {}
  for hour = last, math.max(entry.day * 24, last - (count - 1) * every), -every do
    table.insert(hours, 1, hour == last and { hour, entry.min, entry.qty, entry.mv }
      or { hour, entry.min + 1 + math.floor(entry.min * wobble() * 0.1), math.max(1, math.floor(entry.qty * (0.8 + wobble() * 0.4))), 0 })
  end
  return hours
end

-- Today's cheapest price levels; a deal is two cheap units below the usual
-- price. Items with set days have none, so they draw no random numbers.
local function ladder(item, newest)
  if newest.day ~= TODAY or item.seen then
    return {}
  end
  local usual = item[5]
  local levels = { { price = newest.min, count = item.deal and 2 or math.max(1, math.floor(newest.qty * 0.2)) } }
  local price = item.deal and math.floor(usual * 0.97) or newest.min
  for _ = 2, 5 do
    price = math.floor(price * (1.02 + random() * 0.05)) + 1
    levels[#levels + 1] = { price = price, count = math.max(1, math.floor(newest.qty * 0.15)) }
  end
  return levels
end

local function seededDB()
  local db = {
    version = 5,
    prices = { [REALM] = {} },
    history = { [REALM] = {} },
    hours = { [REALM] = {} },
    scanned = { [REALM] = SCAN },
    items = {},
    vendor = {},
    gold = {},
    scans = {},
    settings = {},
    account = { id = "K7Q2M9PX", key = "7KQ2M9PXABCDEFGHJKMN" },
  }
  for _, item in ipairs(ITEMS) do
    local key, name, quality, vendor, price = unpack(item)
    local itemID = Codec.BaseID(key)
    Stub.items[itemID] = { name = item.base or name, quality = quality, vendor = vendor, cached = true }
    Database.SetItem(db, key, name, quality)
    db.vendor[itemID] = vendor
    if price then
      local entries = priceHistory(item)
      local newest, daily, hours, recent, measured = entries[#entries], {}, {}, {}, nil
      local wobbleSeed = itemID
      local function wobble()
        wobbleSeed = wobbleSeed * 16807 % 2147483647
        return wobbleSeed / 2147483647
      end
      -- The hours the addon keeps: the 168 up to the item's newest scan.
      local firstHour = math.floor(scanTime(newest.day) / 3600) - 167
      for index, entry in ipairs(entries) do
        daily[index] = Codec.HistoryDay(entry.day, entry.min, entry.qty, entry.mv)
        if item.scans and entry.day >= TODAY - 7 then
          for _, hour in ipairs(scansOf(entry, item.scans[1], item.scans[2], wobble)) do
            if hour[1] >= firstHour then
              hours[#hours + 1] = Codec.HistoryDay(unpack(hour))
            end
          end
        end
        if index > #entries - 14 then
          recent[#recent + 1] = entry.min
        end
        if entry.mv > 0 then
          measured = entry
        end
      end
      db.history[REALM][key] = table.concat(daily, ",")
      db.hours[REALM][key] = #hours > 0 and table.concat(hours, ",") or nil
      db.prices[REALM][key] = Codec.EncodePrice({
        min = newest.min,
        qty = newest.qty,
        n = math.ceil(newest.qty / 5),
        seen = scanTime(newest.day),
        mv = measured and measured.mv or 0,
        mvAt = measured and scanTime(measured.day) or 0,
        days = recent,
        ladder = ladder(item, newest),
      })
    end
  end
  for _, character in ipairs(CHARACTERS) do
    local name, from, to, plays, idle = unpack(character)
    local first, last, hours = TODAY - 29, TODAY - idle, {}
    for day = first, last do
      if day == first or day == last or random() < plays then
        local share = (day - first) / (last - first)
        -- Played at this time of day.
        hours[NOW_HOUR - (TODAY - day) * 24] = day == last and to
          or math.floor((from + (to - from) * share) * (0.97 + random() * 0.06))
      end
    end
    db.gold[name] = hours
  end
  -- An entry of every side: { character, hours ago, side, item, key, count, price, cut, party }.
  local now = time()
  db.trades = {}
  for _, trade in ipairs({
    { "Sultan-Faramon", 1, "sell", "Runecloth", "14047", 20, 13800, 690 },
    { "Sultan-Faramon", 1.5, "tradeBuy", "Arcanite Bar", "12360", 2, 240000, 0, "Kargath" },
    { "Sultan-Faramon", 2, "repair", "Repairs", nil, 1, 4320, 0 },
    { "Sultan-Faramon", 2.5, "quest", "The Battle of Darrowshire", nil, 1, 9000, 0 },
    { "Sultan-Faramon", 3, "vendor", "Jagged Star of the Eagle", nil, 1, 3100, 0 },
    { "Mirelle-Faramon", 4, "tradeSell", "Thorium Ore", "10620", 20, 150000, 0, "Kargath" },
    { "Mirelle-Faramon", 4.5, "travel", "Everlook, Winterspring", nil, 1, 4000, 0 },
    { "Mirelle-Faramon", 5, "buy", "Essence of Undeath", "12808", 3, 39000, 0 },
    { "Sultan-Faramon", 5.5, "deposit", "Runecloth", nil, 1, 1260, 0 },
    { "Sultan-Faramon", 6, "postage", "Postage", nil, 1, 30, 0 },
    { "Sultan-Faramon", 6, "mailOut", "Gold", nil, 1, 500000, 0, "Mirelle" },
    { "Mirelle-Faramon", 6.5, "mailIn", "For the bags", nil, 1, 500000, 0, "Sultan" },
    { "Mirelle-Faramon", 7, "cod", "Large Brilliant Shard", "14344", 4, 220000, 0, "Grokk" },
    { "Mirelle-Faramon", 9, "merchant", "Simple Flour", nil, 10, 500, 0 },
    { "Sultan-Faramon", 10, "loot", "Looted gold", nil, 46, 18250, 0 },
    { "Sultan-Faramon", 11, "training", "Mining (Artisan)", nil, 1, 50000, 0 },
    { "Sultan-Faramon", 12, "tradeIn", "Gold", nil, 1, 20000, 0, "Kargath" },
    { "Sultan-Faramon", 13, "tradeOut", "Gold", nil, 1, 5000, 0, "Grokk" },
    { "Sultan-Faramon", 14, "respec", "Talent reset", nil, 1, 100000, 0 },
    { "Sultan-Faramon", 15, "otherIn", "Other", nil, 3, 1240, 0 },
    { "Sultan-Faramon", 16, "otherOut", "Other", nil, 2, 300, 0 },
    { "Sultan-Faramon", 20, "buy", "Jagged Star of the Eagle", nil, 1, 2300, 0 },
    { "Sultan-Faramon", 26, "sell", "Major Healing Potion", "13446", 5, 13000, 650 },
    { "Mirelle-Faramon", 30, "buy", "Runecloth", "14047", 40, 24800, 0 },
    { "Sultan-Faramon", 52, "sell", "Bandit Cinch of the Monkey", "9775:584", 1, 21000, 1050 },
  }) do
    local character, hours, side, item, key, count, price, cut, party = unpack(trade, 1, 9)
    db.trades[character] = db.trades[character] or {}
    table.insert(db.trades[character], 1,
      { at = now - math.floor(hours * 3600), side = side, item = item, key = key, count = count, price = price, fee = cut, party = party })
  end
  return db
end

local byKey = {}
for _, item in ipairs(ITEMS) do
  byKey[item[1]] = item
end
for container, slots in pairs(BAGS) do
  local bag = { slots = 16 }
  for slot, held in ipairs(slots) do
    local key, count, bound = unpack(held)
    local _, name, quality = unpack(byKey[key])
    local link = ITEM_QUALITY_COLORS[quality].hex .. "|H" .. Codec.ItemString(key) .. "|h[" .. name .. "]|h|r"
    bag[slot] = { hyperlink = link, stackCount = count, isBound = bound }
  end
  Stub.bags[container] = bag
end

-- A mailbox with mail of every kind; the server holds back three more.
local AH = "Auction House"
local function sale(item, count, money, days)
  return { sender = AH, subject = "Auction successful: " .. item, money = money, daysLeft = days,
    invoice = { "seller", item, "Kargath", money, money, 0, math.floor(money / 19), count } }
end
local function returned(kind, itemID, item, count, quality, days)
  return { sender = AH, subject = "Auction " .. kind .. ": " .. item, daysLeft = days, items = { { itemID, item, count, quality } } }
end
Stub.inbox.mails = {
  sale("Runecloth", 20, 131100, 29.6),
  sale("Runecloth", 20, 131100, 29.4),
  sale("Bandit Cinch of the Monkey", 1, 19950, 28.2),
  { sender = AH, subject = "Auction won: Essence of Undeath", daysLeft = 29.1,
    invoice = { "buyer", "Essence of Undeath", "Mirelle", 39000, 39000, 0, 0, 3 }, items = { { 12808, "Essence of Undeath", 3, 1 } } },
  returned("expired", 13468, "Black Lotus", 1, 2, 27.5),
  returned("cancelled", 13446, "Major Healing Potion", 5, 1, 30),
  { sender = "Mirelle", subject = "Thorium for you", daysLeft = 3.6, items = { { 10620, "Thorium Ore", 20, 1 } } },
  { sender = "Mirelle", subject = "Gold for the mats", money = 150000, daysLeft = 3.3 },
  { sender = "Kargath", subject = "Arcanite", cod = 240000, daysLeft = 2.4, items = { { 12360, "Arcanite Bar", 2, 2 } } },
  sale("Major Healing Potion", 5, 123500, 26.3),
  sale("Light Leather", 7, 1050, 25.8),
  returned("expired", 10620, "Thorium Ore", 9, 1, 24.7),
  { sender = "Mirelle", subject = "Mats", daysLeft = 12.2,
    items = { { 14047, "Runecloth", 20, 1 }, { 14047, "Runecloth", 20, 1 }, { 12359, "Thorium Bar", 10, 1 } } },
  { sender = "Postmaster", subject = "Recovered items", daysLeft = 1.5, items = { { 2589, "Linen Cloth", 12, 1 } } },
  sale("Runecloth", 20, 131100, 23.1),
  returned("cancelled", 12808, "Essence of Undeath", 3, 1, 22.9),
  sale("Black Lotus", 1, 812000, 21.4),
  sale("Runecloth", 20, 131100, 20.2),
}
Stub.inbox.shows = 15

GoldbookDB = seededDB()
Stub.fire("ADDON_LOADED", "Goldbook")
Stub.money = CHARACTERS[1][3]
Stub.fire("PLAYER_LOGIN")

-- Driving the window. A command that makes the addon say something did not
-- open the view it was meant to.

local function run(command)
  local said = #Stub.printed
  SlashCmdList.GOLDBOOK(command)
  assert(#Stub.printed == said, "/gb " .. command .. ": " .. tostring(Stub.printed[#Stub.printed]))
end

local function rowFor(name)
  for _, row in ipairs(GoldbookWindow.rows) do
    if row.hit.item and row.hit.item.name == name then
      return row.hit
    end
  end
  error(name .. " is not in the list")
end

local function captureWindow(view, extra)
  capture(view, { GoldbookWindow, GoldbookMinimapButton, extra }, { GoldbookWindow, extra })
end

-- Drawn as if the mouse were over it: its highlight shows.
local function hover(widget, on)
  records[widget].hover = on or nil
end

-- The chart's marker on a point, counted from the newest when negative,
-- and the tooltip that comes with it, which `capture` then draws.
local function hoverPoint(index)
  local shown = 0
  for _, hit in ipairs(GoldbookWindow.chart.hits) do
    shown = shown + (rawget(hit, "shown") and 1 or 0)
  end
  local hit = GoldbookWindow.chart.hits[index < 0 and shown + 1 + index or index]
  hit.scripts.OnEnter(hit)
end

-- Every view, the web login and its confirmation, as <name><suffix>.png.
local function captureViews(suffix)
  run("show")
  local lotus = rowFor("Black Lotus")
  hover(lotus, true)
  captureWindow("prices" .. suffix)
  hover(lotus, false)
  local chip = GoldbookWindow.filters.controls.profession
  chip.scripts.OnClick(chip)
  captureWindow("menu" .. suffix)
  chip.scripts.OnClick(chip)
  run("deals")
  hover(GoldbookWindow.rows[1].hit, true)
  captureWindow("deals" .. suffix)
  hover(GoldbookWindow.rows[1].hit, false)
  for _, view in ipairs({ "bags", "movers", "accounting" }) do
    run(view)
    captureWindow(view .. suffix)
  end
  local expenses = GoldbookWindow.segments.buttons[3]
  expenses.scripts.OnClick(expenses)
  captureWindow("accounting-expenses" .. suffix)
  local sources = GoldbookWindow.filters.controls.source
  sources.scripts.OnClick(sources)
  captureWindow("accounting-sources" .. suffix)
  sources.scripts.OnClick(sources)
  local all = GoldbookWindow.segments.buttons[1]
  all.scripts.OnClick(all)
  run("items")
  captureWindow("items" .. suffix)
  -- The mailbox opens the Mail view, and closing it closes the window. Its
  -- invoices book trades; the seeded ones are kept, so both themes match.
  local trades = ns.db.trades
  ns.db.trades = {}
  Stub.openMailbox()
  captureWindow("mail" .. suffix)
  Stub.fire("MAIL_CLOSED")
  ns.db.trades = trades
  run("gold")
  hoverPoint(22)
  captureWindow("gold" .. suffix, GameTooltip)
  GameTooltip:Hide()
  run("item Black Lotus")
  hoverPoint(-4)
  captureWindow("item" .. suffix, GameTooltip)
  GameTooltip:Hide()
  -- The last week, by the hour.
  local ranges = GoldbookWindow.segments.buttons
  ranges[2].scripts.OnClick(ranges[2])
  hoverPoint(-6)
  captureWindow("item-week" .. suffix, GameTooltip)
  GameTooltip:Hide()
  ranges[3].scripts.OnClick(ranges[3])
  run("item Gold Ore")
  hoverPoint(-2)
  captureWindow("item-sparse" .. suffix, GameTooltip)
  GameTooltip:Hide()
  local toggle = GoldbookWindow.themeToggle
  hover(toggle, true)
  toggle.scripts.OnEnter(toggle)
  captureWindow("toggle" .. suffix, GameTooltip)
  GameTooltip:Hide()
  hover(toggle, false)
  GoldbookWindow:Hide()

  run("web")
  capture("web" .. suffix, { GoldbookWebLogin }, { GoldbookWebLogin })
  GoldbookWebLogin.newKey.scripts.OnClick(GoldbookWebLogin.newKey)
  capture("web-confirm" .. suffix, { GoldbookWebLogin }, { GoldbookWebLogin })
  GoldbookWebLogin:Hide()

  Stub.fire("AUCTION_HOUSE_SHOW")
  capture("scan" .. suffix, { GoldbookScanButton }, { GoldbookScanButton })
end

captureViews("")
-- The window at other sizes, its centre where it was: the middle of the screen.
run("show")
local function centred()
  GoldbookWindow.center = { SCREEN_WIDTH / 2 / GoldbookWindow:GetScale(), SCREEN_HEIGHT / 2 / GoldbookWindow:GetScale() }
end
for _, scale in ipairs({ 0.8, 1.2 }) do
  centred()
  ns.UI.SetScale(scale)
  captureWindow(("scale-%.1f"):format(scale))
end
centred()
ns.UI.SetScale(1)
GoldbookWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
-- An item tooltip goes right of the window, or left where the screen ends
-- first. The addon asks how far right the window and the screen reach and
-- how wide the tooltip is; the stub lays nothing out, so the preview answers.
-- 310 is about what the page measures for this tooltip.
run("show")
UIParent.right, GameTooltip.width = SCREEN_WIDTH, 310
local hovered = rowFor("Black Lotus")
hover(hovered, true)
for _, place in ipairs({ { "tooltip", -260 }, { "tooltip-left", 260 } }) do
  GoldbookWindow:SetPoint("CENTER", UIParent, "CENTER", place[2], 0)
  GoldbookWindow.right = (SCREEN_WIDTH + GoldbookWindow.width) / 2 + place[2]
  hovered.scripts.OnEnter(hovered)
  captureWindow(place[1], GameTooltip)
end
hover(hovered, false)
GameTooltip:Hide()
GoldbookWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
GoldbookWindow:Hide()

ns.UI.SetTheme(ns.UI.Theme() == "dark" and "light" or "dark")
captureViews("-" .. ns.UI.Theme())

-- Options > AddOns puts the panel in a canvas of about this size.
local canvas = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
canvas:SetSize(640, 520)
canvas:SetPoint("CENTER")
canvas:SetBackdrop({})
local options = Stub.categories[1].frame
options:SetParent(canvas)
options:SetAllPoints(canvas)
options.scripts.OnShow(options)
capture("options", { canvas }, { canvas })
