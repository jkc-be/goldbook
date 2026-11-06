#!/usr/bin/env python3
"""Verify the Battle.net auction poller live: real API -> server -> export -> sync -> ServerData.lua.

Needs the server's Battle.net client in BNET_CLIENT_ID and BNET_CLIENT_SECRET,
and network access. Polls the EU PvP houses of both factions, then restarts
the server on the same database to show that unchanged snapshots are not
stored twice.

    scripts/verify-battlenet-auctions.py [SHARD]
    scripts/verify-battlenet-auctions.py CAMWOWEU4Realm6PvP
"""
from email.utils import parsedate_to_datetime
from pathlib import Path
import base64
import gzip
import json
import math
import os
import re
import runpy
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))
SERVER = ROOT / "target/debug/goldbook-server"
SYNC = ROOT / "target/debug/goldbook-sync"
DUMP = runpy.run_path(str(ROOT / "scripts/verify-server-data.py"))["DUMP"]
API = "https://eu.api.blizzard.com/data/wow/ruleset/1/auctions/{}{}?namespace=dynamic-forever-eu"
STORED = re.compile(r"battlenet auctions: stored EU PvP/(\w+) \(house (\d+)\) snapshot (\d+) with")


def token(client, secret):
    basic = base64.b64encode(f"{client}:{secret}".encode()).decode()
    grant = urllib.request.Request("https://oauth.battle.net/token", data=b"grant_type=client_credentials",
                                   headers={"Authorization": f"Basic {basic}"})
    with urllib.request.urlopen(grant, timeout=30) as response:
        return json.load(response)["access_token"]


def blizzard(bearer, url, since=None):
    """The status, Last-Modified as Unix seconds, and JSON body of a GET."""
    headers = {"Authorization": f"Bearer {bearer}", "Accept-Encoding": "gzip"}
    if since:
        headers["If-Modified-Since"] = since
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
            body = response.read()
            if response.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            modified = int(parsedate_to_datetime(response.headers["Last-Modified"]).timestamp())
            return response.status, modified, json.loads(body)
    except urllib.error.HTTPError as error:
        return error.code, None, None


def expected_minimums(regular, commodities):
    """Each plain item's lowest unit price, computed apart from the server's code."""
    low = {}
    for listing, unit in [(a, math.ceil(a.get("buyout", 0) / a["quantity"])) for a in regular.get("auctions", [])] + \
                         [(a, a["unit_price"]) for a in commodities.get("auctions", [])]:
        if not unit or listing["item"].get("bonus_lists"):
            continue
        key = str(listing["item"]["id"])
        low[key] = min(low.get(key, unit), unit)
    return low


def wait_for(log, needle, count=1, seconds=300):
    for _ in range(seconds * 10):
        text = log.read_text()
        if "failed" in text:
            raise RuntimeError(f"the poller failed\n{text}")
        if text.count(needle) >= count:
            return text
        time.sleep(.1)
    raise RuntimeError(f"no {count} x {needle!r} within {seconds} s\n{log.read_text()}")


def main():
    shard = sys.argv[1] if len(sys.argv) > 1 else "CAMWOWEU4Realm6PvP"
    client, secret = os.environ.get("BNET_CLIENT_ID"), os.environ.get("BNET_CLIENT_SECRET")
    if not client or not secret:
        sys.exit("BNET_CLIENT_ID and BNET_CLIENT_SECRET must be set")
    settings = lambda port: {"GOLDBOOK_BATTLENET_AUCTIONS": "1", "BNET_CLIENT_ID": client, "BNET_CLIENT_SECRET": secret}
    bearer = token(client, secret)

    with tempfile.TemporaryDirectory(prefix="goldbook-battlenet-") as temporary:
        directory = Path(temporary)
        flavor = directory / "wow/_forever_"
        addon = flavor / "Interface/AddOns/Goldbook"
        (flavor / "Interface/AddOns").mkdir(parents=True)
        saved = flavor / "WTF/Account/TEST#1/SavedVariables/Goldbook.lua"
        saved.parent.mkdir(parents=True)
        characters = ", ".join(f'["{faction}tester-{shard}"] = {{ ["name"] = "{faction}tester", ["realm"] = "{shard}", '
                               f'["faction"] = "{faction}" }}' for faction in ("Horde", "Alliance"))
        saved.write_text(f'GoldbookDB = {{ ["characters"] = {{ {characters} }}, ["items"] = {{}}, ["scans"] = {{}} }}\n')
        helpers["run"]([SYNC, "install", "--wow", directory / "wow"])

        with helpers["server"](directory, None, SERVER, settings) as server:
            log = wait_for(directory / "server.log", "battlenet auctions: stored", 2)
            stored = {faction: (house, int(snapshot)) for faction, house, snapshot in STORED.findall(log)}
            assert sorted(stored) == ["Alliance", "Horde"], log
            checked = {}
            for faction, (house, snapshot) in stored.items():
                query = urllib.parse.urlencode({"realm": shard, "faction": faction})
                export = server.request("GET", f"/api/export?{query}")[0]["body"]
                assert export["scannedAt"] == snapshot, (faction, export["scannedAt"], snapshot)

                status, modified, regular = blizzard(bearer, API.format(house, ""))
                assert status == 200, (faction, status)
                _, commodities_modified, commodities = blizzard(bearer, API.format(house, "/commodities"))
                if modified != snapshot or commodities_modified != snapshot:
                    sys.exit(f"house {house} published a new snapshot during the check; run it again")
                expected = expected_minimums(regular, commodities)
                exported = {key: item["price"][0] for key, item in export["items"].items() if item["price"][3] == snapshot}
                assert exported.keys() == expected.keys(), (faction, sorted(exported.keys() ^ expected.keys())[:10])
                wrong = {key: (exported[key], expected[key]) for key in expected if exported[key] != expected[key]}
                assert not wrong, (faction, list(wrong.items())[:10])

                since = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(snapshot))
                assert blizzard(bearer, API.format(house, ""), since)[0] == 304, f"no 304 for {since} from house {house}"
                checked[faction] = (house, snapshot, len(expected), since)

            output = helpers["run"]([SYNC, "--wow", directory / "wow", "--api", f"http://127.0.0.1:{server.port}",
                                     "--token", server.token, "--state", directory / "state.json", "--once"])
            script = directory / "dump.lua"
            script.write_text(DUMP)
            lines = helpers["run"](["luajit", script, addon / "ServerData.lua"]).splitlines()
            written_for = next((line for line in output.splitlines() if line.startswith("server prices for ")), "")
            for faction, (house, snapshot, items, _) in checked.items():
                assert f"{shard}-{faction}" in written_for.split(" written to ")[0], output
                assert f"scannedAt\t{shard}-{faction}\t{snapshot}" in lines, (faction, lines[:5])
                written = sum(line.startswith(f"prices\t{shard}-{faction}\t") for line in lines)
                assert written == items, (faction, written, items)

        with helpers["server"](directory, None, SERVER, settings):
            wait_for(directory / "server.log", "battlenet auctions: polling")
            time.sleep(30)
            log = (directory / "server.log").read_text()
            assert "battlenet auctions: stored" not in log and "failed" not in log, log

    for faction, (house, snapshot, items, since) in sorted(checked.items(), reverse=True):
        print(f"Verified EU PvP/{faction} from house {house}: snapshot {snapshot} stored once with {items} items, "
              f"every minimum matches the API, Battle.net answers 304 to {since!r}, and {shard}-{faction} gets the "
              "prices in ServerData.lua.")
    print("A restarted server stores nothing new.")


if __name__ == "__main__":
    main()
