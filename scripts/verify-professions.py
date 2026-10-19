#!/usr/bin/env python3
"""Check the generated profession catalog, addon dropdowns and paginated HTTP filters."""
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))


def main():
    subprocess.run(["python3", "scripts/generate-profession-catalog.py", "--check"], cwd=ROOT, check=True)
    subprocess.run(["luajit", "addon/tests/professions.lua"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="goldbook-professions-") as temporary:
        with helpers["server"](Path(temporary), None, ROOT / "target/debug/goldbook-server") as api:
            items = {"2589": ["Linen Cloth", 1], "2447": ["Peacebloom", 1], "2840": ["Copper Bar", 1],
                     "2318": ["Light Leather", 1],
                     "2881": ["Plans: Runed Copper Breastplate", 2], "858": ["Lesser Healing Potion", 1],
                     "10504:584": ["Green Lens variant", 2], "999999": ["Unknown sample", 0]}
            scan = dict(realm="Filter", faction="Horde", region="EU", scannedAt=1760000000,
                        mode="browse", scanner="Test", build="1.60.1", items=items,
                        rows=[[key, 100, 0, 1, 0] for key in items])
            assert api.request("POST", "/api/scans", scan, token=api.token)[0]["status"] == 200
            base = "/api/prices?realm=Filter&faction=Horde"

            def check(parameters, keys, total=None):
                result = api.request("GET", base + parameters)[0]
                assert result["status"] == 200, result
                data = result["body"]
                assert sorted(row["itemKey"] for row in data["items"]) == sorted(keys), data
                assert data["total"] == (len(keys) if total is None else total), data

            check("", list(items))
            check("&profession=alchemy&kind=materials", ["2447"])
            check("&profession=blacksmithing&kind=recipes", ["2881"])
            check("&profession=alchemy&kind=crafted", ["858"])
            check("&profession=engineering&kind=crafted", ["10504:584"])
            check("&profession=tailoring&kind=materials", ["2589", "2318"])
            check("&profession=skinning&kind=materials", ["2318"])
            check("&profession=skinning&kind=crafted", [])
            check("&profession=leatherworking&kind=materials", ["2318"])
            check("&profession=herbalism&kind=materials", ["2447"])
            check("&profession=herbalism&kind=crafted", [])
            check("&profession=first-aid&kind=materials", ["2589"])
            check("&quality=2", ["2881", "10504:584"])
            check("&quality=2&limit=1&offset=1&sort=name", ["2881"], 2)
            check("&profession=alchemy&kind=materials&q=linen", [])
            check("&profession=alchemy&kind=materials&offset=99", [], 1)
            check("&profession=alchemy&kind=materials&limit=0", [], 1)
            check("&profession=fishing&kind=materials", [])
            for query in ("&profession=unknown", "&kind=unknown", "&quality=-1", "&quality=8"):
                assert api.request("GET", base + query)[0]["status"] == 400
            catalog = api.request("GET", "/api/professions")[0]["body"]["professions"]
            alchemy = next(p for p in catalog if p["id"] == "alchemy")
            assert 2447 in alchemy["materials"] and 118 in alchemy["crafted"]
            skinning = next(p for p in catalog if p["id"] == "skinning")
            assert 2318 in skinning["materials"] and skinning["crafted"] == [], skinning["crafted"]
            herbalism = next(p for p in catalog if p["id"] == "herbalism")
            assert 2447 in herbalism["materials"] and herbalism["crafted"] == [], herbalism["crafted"]
    print("Verified profession lists, quality, text search, pagination, empty pages and invalid filters.")


if __name__ == "__main__":
    main()
