#!/usr/bin/env python3
"""Write the addon's two palettes into the website's and the app's style sheets.

    python3 scripts/web-palette.py           rewrites both style sheets
    python3 scripts/web-palette.py --check   fails when either one differs

The addon's window is the reference. Its colours come from PALETTES in
addon/Goldbook/UI.lua, as the game client shows them: the client brightens
every pixel by the transfer in addon/tests/client.lua, and a browser does not.
So each colour here is the addon's colour through that transfer, and the web
page looks on screen as the window does in the game.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "addon/Goldbook/UI.lua"
CLIENT = ROOT / "addon/tests/client.lua"
SHEETS = [ROOT / "web/style.css", ROOT / "desktop/ui/style.css"]
START = "/* The addon's palettes, written by scripts/web-palette.py. Edit UI.lua and run it again. */"
END = "/* End of the addon's palettes. */"

# Each custom property and the addon palette key it takes, with an alpha for
# a tint: a number, or the name of the palette's own alpha.
TOKENS = [
    ("--page", "bg"),
    ("--rail", "rail"),
    ("--panel", "panel"),
    ("--field", "field"),
    ("--line", "line"),
    ("--edge", "edge"),
    ("--ink", "text"),
    ("--ink-soft", "railText"),
    ("--muted", "muted"),
    ("--gold", "gold"),
    ("--gold-ink", "goldhi"),
    ("--gold-edge", "buttonEdge"),
    ("--brand", "brand"),
    ("--tint", "gold", "hover"),
    ("--tint-strong", "gold", 0.16),
    ("--press", "on"),
    ("--top-1", "titleTop"),
    ("--top-2", "titleBottom"),
    ("--button-1", "buttonTop"),
    ("--button-2", "buttonBottom"),
    ("--button-ink", "buttonText"),
    ("--series-1", "gold"),
    ("--series-2", "second"),
    ("--compare-1", "gold"),
    ("--compare-2", "info"),
    ("--compare-3", "gain"),
    ("--compare-4", "quality.4"),
    ("--compare-5", "loss"),
    ("--compare-6", "second"),
    ("--up", "gain"),
    ("--down", "loss"),
    ("--warn", "warn"),
    ("--info", "info"),
    ("--coin-g", "coins.gold"),
    ("--coin-s", "coins.silver"),
    ("--coin-c", "coins.copper"),
    ("--q-poor", "quality.0"),
    ("--q-common", "quality.1"),
    ("--q-uncommon", "quality.2"),
    ("--q-rare", "quality.3"),
    ("--q-epic", "quality.4"),
    ("--q-legendary", "quality.5"),
    ("--q-artifact", "quality.6"),
    ("--q-heirloom", "quality.7"),
]


def balanced(text, start):
    """The text of the Lua table whose opening brace is at `start`."""
    depth = 0
    for index in range(start, len(text)):
        depth += {"{": 1, "}": -1}.get(text[index], 0)
        if depth == 0:
            return text[start + 1:index]
    raise ValueError("unbalanced table in UI.lua")


def palettes():
    """{theme: {key: hex or number}}, nested tables flattened as "coins.gold"
    and "quality.0"; the quality list starts at [0]."""
    text = UI.read_text()
    body = balanced(text, text.index("{", text.index("local PALETTES = {") + len("local PALETTES =")))
    found = {}
    for theme in ("light", "dark"):
        table = balanced(body, body.index("{", body.index(f"{theme} = {{")))
        values = {}
        for name in ("coins", "quality"):
            nested = balanced(table, table.index("{", table.index(f"{name} = {{")))
            table = table.replace(nested, "")
            if name == "quality":
                hexes = re.findall(r'"([0-9a-f]{6})"', nested)
                values.update({f"quality.{index}": value for index, value in enumerate(hexes)})
            else:
                values.update({f"coins.{key}": value for key, value in re.findall(r'(\w+) = "([0-9a-f]{6})"', nested)})
        values.update(re.findall(r'(\w+) = "([0-9a-f]{6})"', table))
        values.update((key, float(value)) for key, value in re.findall(r"(\w+) = ([0-9.]+),", table))
        found[theme] = values
    return found


def transfer():
    text = CLIENT.read_text()
    gain = float(re.search(r"gain = ([0-9.]+)", text).group(1))
    offset = float(re.search(r"offset = ([0-9.]+)", text).group(1))
    return lambda channel: min(255, max(0, round((gain * channel / 255 + offset) * 255)))


def seen(hex_colour, shown):
    return [shown(int(hex_colour[index:index + 2], 16)) for index in (0, 2, 4)]


def block(selector, values, shown):
    lines = [f"{selector} {{"]
    for name, key, *alpha in TOKENS:
        red, green, blue = seen(values[key], shown)
        if alpha:
            amount = values[alpha[0]] if isinstance(alpha[0], str) else alpha[0]
            lines.append(f"  {name}: rgb({red} {green} {blue} / {round(amount * 100)}%);")
        else:
            lines.append(f"  {name}: #{red:02x}{green:02x}{blue:02x};")
    return "\n".join(lines + ["}"])


def generated():
    found, shown = palettes(), transfer()
    return "\n\n".join([
        START,
        block(":root", found["light"], shown),
        block(':root[data-theme="dark"]', found["dark"], shown),
        END,
    ])


def rewritten(text):
    start, end = text.index(START), text.index(END) + len(END)
    return text[:start] + generated() + text[end:]


def main():
    check = sys.argv[1:] == ["--check"]
    stale = []
    for sheet in SHEETS:
        text = sheet.read_text()
        updated = rewritten(text)
        if updated != text:
            stale.append(sheet.relative_to(ROOT))
            if not check:
                sheet.write_text(updated)
    if check and stale:
        raise SystemExit(f"{', '.join(map(str, stale))} differ from the addon's palettes: run python3 scripts/web-palette.py")
    print(f"Wrote {', '.join(map(str, stale))}" if stale else "Palettes are current")


if __name__ == "__main__":
    main()
