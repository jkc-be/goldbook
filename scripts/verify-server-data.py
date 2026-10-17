#!/usr/bin/env python3
"""Verify server data end to end: seeded server -> sync CLI -> ServerData.lua -> LuaJIT."""
from pathlib import Path
import json
import runpy
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))
SYNC = ROOT / "target/debug/goldbook-sync"
HOSTILE = 'Evil "Blade"\\\n]] os.exit(1) --[['

DUMP = r"""
assert(loadfile(arg[1]))("Goldbook", {})
local data = GoldbookServerData
local lines = { "version\t" .. data.version, "server\t" .. data.server }
local function esc(text)
  return (tostring(text):gsub("\\", "\\\\"):gsub("\n", "\\n"))
end
local function add(prefix, t)
  for key, value in pairs(t) do
    lines[#lines + 1] = prefix .. "\t" .. esc(key) .. "\t" .. esc(value)
  end
end
add("items", data.items)
for realm, r in pairs(data.realms) do
  lines[#lines + 1] = "scannedAt\t" .. realm .. "\t" .. r.scannedAt
  for _, kind in ipairs({ "prices", "hours", "days" }) do
    add(kind .. "\t" .. realm, r[kind])
  end
end
table.sort(lines)
io.write(table.concat(lines, "\n"), "\n")
"""


def esc(text):
    return str(text).replace("\\", "\\\\").replace("\n", "\\n")


def expected_lines(api_url, exports):
    lines = ["version\t1", f"server\t{api_url}"]
    for realm_key, export in exports.items():
        lines.append(f"scannedAt\t{realm_key}\t{export['scannedAt']}")
        for key, item in export["items"].items():
            if item["name"] is not None:
                lines.append(f"items\t{key}\t" + esc(f"{item['quality']}|{item['name']}"))
            lines.append(f"prices\t{realm_key}\t{key}\t" + ",".join(map(str, item["price"])))
            if item["hours"]:
                lines.append(f"hours\t{realm_key}\t{key}\t" + ",".join(":".join(map(str, h)) for h in item["hours"]))
            lines.append(f"days\t{realm_key}\t{key}\t" + ",".join(":".join(map(str, d)) for d in item["days"]))
    return sorted(set(lines))


def dump(directory, file):
    script = directory / "dump.lua"
    script.write_text(DUMP)
    return helpers["run"](["luajit", script, file]).splitlines()


def main():
    with tempfile.TemporaryDirectory(prefix="goldbook-server-data-") as temporary:
        directory = Path(temporary)
        flavor = directory / "wow/_classic_"
        addon = flavor / "Interface/AddOns/Goldbook"
        (flavor / "Interface/AddOns").mkdir(parents=True)
        saved = flavor / "WTF/Account/TEST#1/SavedVariables/Goldbook.lua"
        saved.parent.mkdir(parents=True)
        shutil.copy(ROOT / "fixtures/Goldbook.lua", saved)
        other = flavor / "WTF/Account/TEST#2/SavedVariables/Goldbook.lua"
        other.parent.mkdir(parents=True)
        other.write_text('GoldbookDB = { ["characters"] = { ["Mira-Mirage"] = { ["name"] = "Mira", '
                         '["realm"] = "Mirage", ["faction"] = "Alliance" } }, '
                         '["scanned"] = { ["Nowhere-Horde"] = 1760000000 }, ["items"] = {}, ["scans"] = {} }\n')
        before = {path: path.read_bytes() for path in (saved, other)}
        helpers["run"]([SYNC, "install", "--wow", directory / "wow"])
        stub = (addon / "ServerData.lua").read_bytes()
        assert stub == (ROOT / "addon/Goldbook/ServerData.lua").read_bytes(), "the installer ships the stub"
        toc = (addon / "Goldbook.toc").read_text().splitlines()
        assert toc.index("ServerData.lua") < toc.index("Database.lua"), toc

        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            url = f"http://127.0.0.1:{api.port}"
            scans = [
                dict(realm="Faramon", faction="Horde", region="EU", scannedAt=1760003600, mode="replicate",
                     scanner="Someone", build="1.15.7", rows=[["2589", 90, 95, 30, 3], ["12345", 70000, 71000, 1, 1]],
                     items={"12345": [HOSTILE, 4]}),
                dict(realm="Mirage", faction="Alliance", region="EU", scannedAt=1760007200, mode="browse",
                     scanner="Else", build="1.15.7", rows=[["7070", 250, 0, 9, 0]], items={"7070": ["Elemental Water", 1]}),
            ]
            for scan in scans:
                answer = api.request("POST", "/api/scans", scan, token=helpers["TOKEN"])[0]
                assert answer["status"] == 200, answer
            command = [SYNC, "--wow", directory / "wow", "--api", url, "--token", helpers["TOKEN"],
                       "--state", directory / "state.json", "--once"]
            output = helpers["run"](command)
            assert "server prices for Faramon-Horde, Mirage-Alliance written to" in output, output

            exports = {}
            for realm, faction in (("Faramon", "Horde"), ("Mirage", "Alliance")):
                answer = api.request("GET", f"/api/export?realm={realm}&faction={faction}")[0]
                assert answer["status"] == 200, answer
                exports[f"{realm}-{faction}"] = answer["body"]
            assert api.request("GET", "/api/export?realm=Nowhere&faction=Horde")[0]["status"] == 404

            written = addon / "ServerData.lua"
            lines = dump(directory, written)
            assert lines == expected_lines(url, exports), "\n".join(
                sorted(set(lines) ^ set(expected_lines(url, exports))))
            for line in (
                "items\t12345\t" + esc(f"4|{HOSTILE}"),
                "prices\tFaramon-Horde\t12345\t70000,1,1,1760003600,71000,1760003600",
                "prices\tFaramon-Horde\t2589\t90,30,3,1760003600,95,1760003600",
                "hours\tFaramon-Horde\t2589\t488888:100:100:105,488889:90:30:95",
                "days\tMirage-Alliance\t7070\t20370:250:9:0",
            ):
                assert line in lines, (line, [l for l in lines if l.split("\t")[:3] == line.split("\t")[:3]])
            assert not any("Nowhere" in line for line in lines), "a realm the server does not know stays out"

            content, modified = written.read_bytes(), written.stat().st_mtime_ns
            output = helpers["run"](command)
            assert "unchanged" in output and "written to" not in output, output
            assert (written.read_bytes(), written.stat().st_mtime_ns) == (content, modified), "an unchanged file is not rewritten"
            helpers["run"]([SYNC, "install", "--wow", directory / "wow"])
            assert written.read_bytes() == content, "an addon update keeps the written ServerData.lua"
            assert not [p for p in addon.iterdir() if p.name.startswith(".")], list(addon.iterdir())
            assert {path: path.read_bytes() for path in (saved, other)} == before, "SavedVariables are never written"
        print(f"Verified seeded server -> sync -> ServerData.lua ({len(content)} bytes) -> LuaJIT: "
              "every exported item matches, names are escaped, unchanged data is not rewritten, updates keep the file.")


if __name__ == "__main__":
    main()
