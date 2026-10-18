#!/usr/bin/env python3
"""Verify the trade ledger through the real Lua addon, sync CLI, SQLite and HTTP API."""
from pathlib import Path
import runpy
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))


def main():
    with tempfile.TemporaryDirectory(prefix="goldbook-trades-") as temporary:
        directory = Path(temporary)
        fixture = directory / "Trades.lua"
        subprocess.run(["luajit", "addon/tests/trades.lua", str(fixture)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            for state in ("state.json", "state.json", "lost-state.json"):
                helpers["synchronize"](api, directory, fixture, None, ROOT / "target/debug/goldbook-sync", state)
            login, headers = api.request("POST", "/api/login", {"id": "K7Q2M9PX", "key": helpers["KEY"]})
            assert login["status"] == 200, login
            cookie = headers["set-cookie"].split(";")[0]
            everything = api.request("GET", "/api/trades", cookie=cookie)[0]["body"]["trades"]
            assert len(everything) == 11, everything
            vendor = sorted((t["item"], t["price"], t["fee"]) for t in everything if t["side"] == "vendor")
            assert vendor == [("Broken Fang", 85, 0), ("Broken Fang", 85, 0), ("Jagged Star of the Eagle", 3100, 0),
                              ("Ruined Pelt", 55, 0)], vendor
            star = [t for t in everything if t["item"] == "Jagged Star of the Eagle"]
            assert {(t["side"], t["itemKey"]) for t in star} == {("buy", "15301:1019"), ("vendor", "15301:1019")}, star
            trades = [t for t in everything if t["side"] != "vendor" and t["item"] != "Jagged Star of the Eagle"]
            assert [(t["name"], t["side"], t["item"]) for t in trades] == [
                ("Sultan", "sell", "Linen Cloth"),
                ("Sultan", "sell", "Linen Cloth"),
                ("Sultan", "buy", "Bandit Cinch of the Monkey"),
                ("Sultan", "sell", "Linen Cloth"),
                ("Mirelle", "buy", "Linen Cloth"),
                ("Sultan", "sell", "Gnomish Widget"),
            ], trades
            assert trades[2] == {"name": "Sultan", "realm": "Faramon", "at": 1760000000, "side": "buy",
                                 "item": "Bandit Cinch of the Monkey", "itemKey": "9775:584", "quality": None,
                                 "count": 1, "price": 9000, "fee": 0, "party": None}, trades[2]
            assert trades[5]["itemKey"] is None and trades[5]["fee"] == 35
            mirelle = api.request("GET", "/api/trades?name=Mirelle&realm=Faramon", cookie=cookie)[0]["body"]["trades"]
            assert [(t["side"], t["price"], t["count"]) for t in mirelle if t["item"] == "Linen Cloth"] == [("buy", 1500, 20)], mirelle
            assert len(mirelle) == 6, mirelle
            assert api.request("GET", "/api/trades")[0]["status"] == 401
            names = [c["name"] for c in api.request("GET", "/api/account", cookie=cookie)[0]["body"]["characters"]]
            assert sorted(names) == ["Mirelle", "Sultan"], names
            with sqlite3.connect(directory / "goldbook.sqlite") as db:
                assert db.execute("SELECT COUNT(*) FROM trades").fetchone()[0] == 11
                assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        print("Verified Lua mailbox and vendor booking -> SavedVariables -> sync -> API: equal trades kept apart, retries add none, private per account.")


if __name__ == "__main__":
    main()
