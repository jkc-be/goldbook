#!/usr/bin/env python3
"""Verify seller capture through the real Lua addon, sync CLI, SQLite and HTTP API."""
from pathlib import Path
import json
import runpy
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))


def main():
    with tempfile.TemporaryDirectory(prefix="goldbook-full-books-") as temporary:
        directory = Path(temporary)
        fixture = directory / "FullBooks.lua"
        subprocess.run(["luajit", "addon/tests/orderbook.lua", str(fixture)], cwd=ROOT, check=True)
        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            for state in ("full-state.json", "full-state.json", "recovered-state.json"):
                helpers["synchronize"](api, directory, fixture, None, ROOT / "target/debug/goldbook-sync", state)
            query = "/api/sellers?realm=Faramon&faction=Horde&itemKey=2770&history=1"
            ore = api.request("GET", query)[0]["body"]
            assert len(ore["history"]) == 2 and ore["snapshot"]["orderBook"] == []
            first = api.request("GET", query + "&snapshot=" + ore["history"][1]["id"])[0]["body"]["snapshot"]
            assert first["orderBook"] == [
                {"unitPrice": 100, "quantity": 15, "cumulativeQuantity": 15, "cumulativeCost": 1500, "owners": ["Alice-Faramon"], "hasUnnamedOwners": False},
                {"unitPrice": 200, "quantity": 7, "cumulativeQuantity": 22, "cumulativeCost": 2900, "owners": [], "hasUnnamedOwners": True},
            ]
            bar = api.request("GET", query.replace("2770", "2840"))[0]["body"]
            assert len(bar["history"]) == 2
            assert bar["snapshot"]["orderBook"][0]["unitPrice"] == 600
            assert bar["snapshot"]["orderBook"][0]["quantity"] == 2
            with sqlite3.connect(directory / "goldbook.sqlite") as db:
                assert db.execute("SELECT COUNT(*) FROM seller_snapshots").fetchone()[0] == 4
        print("Verified full scan -> saved variables -> sync -> HTTP order book, including retries and empty stock.")
    with tempfile.TemporaryDirectory(prefix="goldbook-sellers-") as temporary:
        directory = Path(temporary)
        fixture = directory / "Sellers.lua"
        subprocess.run(["luajit", "addon/tests/sellers.lua", str(fixture)], cwd=ROOT, check=True)
        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            query = "/api/sellers?realm=Faramon&faction=Horde&itemKey=2589"
            assert api.request("GET", query)[0]["body"] == {"snapshot": None}
            for state in ("state.json", "state.json", "lost-state.json"):
                helpers["synchronize"](api, directory, fixture, None, ROOT / "target/debug/goldbook-sync", state)
            response = api.request("GET", query)[0]
            assert response["status"] == 200
            snapshot = response["body"]["snapshot"]
            summary = snapshot["summary"]
            assert (summary["totalQuantity"], summary["attributedQuantity"], summary["unattributedQuantity"]) == (100, 70, 30)
            assert summary["sellers"] == [
                {"name": "Alice", "quantity": 60, "minPrice": 100, "maxPrice": 100, "share": 0.6},
                {"name": "Bob", "quantity": 10, "minPrice": 120, "maxPrice": 120, "share": 0.1},
            ]
            assert summary["sharedOffers"] == [
                {"unitPrice": 130, "quantity": 20, "owners": ["Alice", "Carol"], "totalOwners": 2},
                {"unitPrice": 140, "quantity": 10, "owners": [], "totalOwners": 2},
            ]
            history = api.request("GET", query + "&history=1")[0]["body"]
            assert len(history["history"]) == 4
            assert history["snapshot"]["orderBook"] == [
                {"unitPrice": 100, "quantity": 60, "cumulativeQuantity": 60, "cumulativeCost": 6000, "owners": ["Alice"], "hasUnnamedOwners": False},
                {"unitPrice": 120, "quantity": 10, "cumulativeQuantity": 70, "cumulativeCost": 7200, "owners": ["Bob"], "hasUnnamedOwners": False},
                {"unitPrice": 130, "quantity": 20, "cumulativeQuantity": 90, "cumulativeCost": 9800, "owners": ["Alice", "Carol"], "hasUnnamedOwners": False},
                {"unitPrice": 140, "quantity": 10, "cumulativeQuantity": 100, "cumulativeCost": 11200, "owners": [], "hasUnnamedOwners": True},
            ]
            for observation, units in zip(history["history"], [60, 40, 60, 60], strict=True):
                old = api.request("GET", query + "&snapshot=" + observation["id"])[0]["body"]["snapshot"]
                assert old["id"] == observation["id"]
                assert old["orderBook"][0]["quantity"] == units
            assert api.request("GET", query + "&snapshot=missing")[0]["body"] == {"snapshot": None}
            assert api.request("GET", query.replace("faction=Horde", "faction=Alliance") +
                               "&snapshot=" + history["snapshot"]["id"])[0]["body"] == {"snapshot": None}
            assert api.request("POST", "/api/sellers", {})[0]["status"] == 401
            invalid = {"realm": "Faramon", "faction": "Horde", "itemKey": "2589", "scannedAt": 1,
                       "offers": [{"quantity": 1, "unitPrice": 1, "owners": ["Alice"], "totalOwners": 0}]}
            assert api.request("POST", "/api/sellers", invalid, token=api.token)[0]["status"] == 400
            empty = api.request("GET", query.replace("2589", "9999"))[0]["body"]["snapshot"]["summary"]
            assert empty["totalQuantity"] == 0 and empty["sellers"] == []
            own = api.request("GET", query.replace("2589", "7070"))[0]["body"]["snapshot"]["summary"]
            assert own["sellers"][0]["name"] == "Sultan-Faramon"
            assert own["sellers"][0]["quantity"] == 8 and own["sellers"][0]["share"] == 1.0
            assert api.request("GET", query.replace("faction=Horde", "faction=Alliance"))[0]["body"] == {"snapshot": None}
            repeated = {"realm": "Faramon", "faction": "Horde", "itemKey": "1111", "scannedAt": 2,
                        "offers": [{"unitPrice": 100, "quantity": 2, "owners": ["Alice"], "totalOwners": 1},
                                   {"unitPrice": 200, "quantity": 3, "owners": ["Alice"], "totalOwners": 1},
                                   {"unitPrice": 150, "quantity": 5, "owners": ["Bob"], "totalOwners": 1}]}
            assert api.request("POST", "/api/sellers", repeated, token=api.token)[0]["status"] == 200
            merged = api.request("GET", query.replace("2589", "1111"))[0]["body"]["snapshot"]["summary"]
            assert merged["sellers"][0] == {"name": "Alice", "quantity": 5, "minPrice": 100, "maxPrice": 200, "share": 0.5}
            repeated["offers"].reverse()
            assert api.request("POST", "/api/sellers", repeated, token=api.token)[0]["body"] == {"stored": False}
            with sqlite3.connect(directory / "goldbook.sqlite") as db:
                assert db.execute("SELECT COUNT(*) FROM seller_snapshots").fetchone()[0] == 8
                assert db.execute("PRAGMA foreign_key_check").fetchall() == []
            repeated["scannedAt"] = 4
            repeated["offers"] = [
                {"unitPrice": 200, "quantity": 3, "owners": ["Alice"], "totalOwners": 1},
                {"unitPrice": 100, "quantity": 2, "owners": ["Alice"], "totalOwners": 1},
                {"unitPrice": 100, "quantity": 5, "owners": ["Bob"], "totalOwners": 2},
                {"unitPrice": 100, "quantity": 4, "owners": [], "totalOwners": 0},
            ]
            api.request("POST", "/api/sellers", repeated, token=api.token)
            item_query = query.replace("2589", "1111")
            book = api.request("GET", item_query)[0]["body"]["snapshot"]
            assert book["orderBook"] == [
                {"unitPrice": 100, "quantity": 11, "cumulativeQuantity": 11, "cumulativeCost": 1100, "owners": ["Alice", "Bob"], "hasUnnamedOwners": True},
                {"unitPrice": 200, "quantity": 3, "cumulativeQuantity": 14, "cumulativeCost": 1700, "owners": ["Alice"], "hasUnnamedOwners": False},
            ]
            repeated["scannedAt"], repeated["offers"] = 3, []
            api.request("POST", "/api/sellers", repeated, token=api.token)
            assert api.request("GET", item_query)[0]["body"]["snapshot"] == book, "late uploads must not replace the latest observation"
            repeated["scannedAt"] = 5
            api.request("POST", "/api/sellers", repeated, token=api.token)
            empty_book = api.request("GET", item_query + "&history=1")[0]["body"]
            assert empty_book["snapshot"]["orderBook"] == []
            assert [row["scannedAt"] for row in empty_book["history"]] == [5, 4, 3, 2]
        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            assert api.request("GET", item_query + "&history=1")[0]["body"] == empty_book
            assert api.request("GET", item_query + "&snapshot=" + book["id"])[0]["body"]["snapshot"] == book
        print("Verified Lua capture -> sync -> API, order book aggregation, historical selection, empty books, isolation, retry deduplication and persistence after restart.")


if __name__ == "__main__":
    main()
