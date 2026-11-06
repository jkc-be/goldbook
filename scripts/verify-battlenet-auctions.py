#!/usr/bin/env python3
"""Verify the Battle.net auction poller live: real API -> server -> export -> sync -> ServerData.lua.

Needs the server's Battle.net client in BNET_CLIENT_ID and BNET_CLIENT_SECRET,
and network access. Polls one house, then restarts the server on the same
database to show that an unchanged snapshot is not stored twice.

    scripts/verify-battlenet-auctions.py [HOUSE/FACTION=ID] [SHARD]
    scripts/verify-battlenet-auctions.py "EU PvP/Horde=113" CAMWOWEU4Realm6PvP
"""
from pathlib import Path
import base64
import gzip
import json
import math
import os
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


def blizzard(client, secret, url, since=None):
    basic = base64.b64encode(f"{client}:{secret}".encode()).decode()
    grant = urllib.request.Request("https://oauth.battle.net/token", data=b"grant_type=client_credentials",
                                   headers={"Authorization": f"Basic {basic}"})
    with urllib.request.urlopen(grant, timeout=30) as response:
        token = json.load(response)["access_token"]
    headers = {"Authorization": f"Bearer {token}", "Accept-Encoding": "gzip"}
    if since:
        headers["If-Modified-Since"] = since
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
            body = response.read()
            if response.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            return response.status, json.loads(body)
    except urllib.error.HTTPError as error:
        return error.code, None


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


def wait_for(log, needle, seconds=180):
    for _ in range(seconds * 10):
        text = log.read_text()
        if needle in text:
            return text
        if "failed" in text:
            raise RuntimeError(f"the poller failed\n{text}")
        time.sleep(.1)
    raise RuntimeError(f"no {needle!r} within {seconds} s\n{log.read_text()}")


def main():
    houses = sys.argv[1] if len(sys.argv) > 1 else "EU PvP/Horde=113"
    shard = sys.argv[2] if len(sys.argv) > 2 else "CAMWOWEU4Realm6PvP"
    client, secret = os.environ.get("BNET_CLIENT_ID"), os.environ.get("BNET_CLIENT_SECRET")
    if not client or not secret:
        sys.exit("BNET_CLIENT_ID and BNET_CLIENT_SECRET must be set")
    market, house_id = houses.split(",")[0].rsplit("=", 1)
    faction = market.rsplit("/", 1)[1]
    region = market.split()[0].lower()
    api = f"https://{region}.api.blizzard.com/data/wow/ruleset/1/auctions/{house_id}"
    namespace = f"?namespace=dynamic-forever-{region}"
    settings = lambda port: {"GOLDBOOK_BATTLENET_HOUSES": houses, "BNET_CLIENT_ID": client, "BNET_CLIENT_SECRET": secret}

    with tempfile.TemporaryDirectory(prefix="goldbook-battlenet-") as temporary:
        directory = Path(temporary)
        flavor = directory / "wow/_forever_"
        addon = flavor / "Interface/AddOns/Goldbook"
        (flavor / "Interface/AddOns").mkdir(parents=True)
        saved = flavor / "WTF/Account/TEST#1/SavedVariables/Goldbook.lua"
        saved.parent.mkdir(parents=True)
        saved.write_text(f'GoldbookDB = {{ ["characters"] = {{ ["Tester-{shard}"] = {{ ["name"] = "Tester", '
                         f'["realm"] = "{shard}", ["faction"] = "{faction}" }} }}, ["items"] = {{}}, ["scans"] = {{}} }}\n')
        helpers["run"]([SYNC, "install", "--wow", directory / "wow"])

        with helpers["server"](directory, None, SERVER, settings) as server:
            log = wait_for(directory / "server.log", "battlenet auctions: stored")
            stored = [line for line in log.splitlines() if "battlenet auctions: stored" in line]
            assert len(stored) == 1, log
            snapshot = int(stored[0].split(" snapshot ")[1].split()[0])
            query = urllib.parse.urlencode({"realm": shard, "faction": faction})
            export = server.request("GET", f"/api/export?{query}")[0]["body"]
            assert export["scannedAt"] == snapshot, (export["scannedAt"], snapshot)

            status, regular = blizzard(client, secret, api + namespace)
            assert status == 200, status
            _, commodities = blizzard(client, secret, f"{api}/commodities{namespace}")
            expected = expected_minimums(regular, commodities)
            exported = {key: item["price"][0] for key, item in export["items"].items() if item["price"][3] == snapshot}
            assert exported.keys() == expected.keys(), sorted(exported.keys() ^ expected.keys())[:10]
            wrong = {key: (exported[key], expected[key]) for key in expected if exported[key] != expected[key]}
            assert not wrong, list(wrong.items())[:10]

            since = time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(snapshot))
            assert blizzard(client, secret, api + namespace, since)[0] == 304, f"no 304 for {since}"

            output = helpers["run"]([SYNC, "--wow", directory / "wow", "--api", f"http://127.0.0.1:{server.port}",
                                     "--token", server.token, "--state", directory / "state.json", "--once"])
            assert f"server prices for {shard}-{faction} written to" in output, output
            script = directory / "dump.lua"
            script.write_text(DUMP)
            lines = helpers["run"](["luajit", script, addon / "ServerData.lua"]).splitlines()
            assert f"scannedAt\t{shard}-{faction}\t{snapshot}" in lines, lines[:5]
            written = sum(line.startswith(f"prices\t{shard}-{faction}\t") for line in lines)
            assert written == len(expected), (written, len(expected))

        with helpers["server"](directory, None, SERVER, settings):
            log = wait_for(directory / "server.log", "battlenet auctions: polling")
            time.sleep(20)
            log = (directory / "server.log").read_text()
            assert "battlenet auctions: stored" not in log and "failed" not in log, log

    print(f"Verified {houses} live: snapshot {snapshot} stored once with {len(expected)} items, every minimum matches "
          f"the API, Battle.net answers 304 to {since!r}, {shard}-{faction} gets the prices in ServerData.lua, "
          "and a restarted server stores nothing new.")


if __name__ == "__main__":
    main()
