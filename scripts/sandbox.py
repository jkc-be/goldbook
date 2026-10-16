#!/usr/bin/env python3
"""Start a disposable local Goldbook server with synthetic game data."""
from pathlib import Path
import argparse
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true", help="Verify seeded data and exit")
    args = parser.parse_args()
    subprocess.run(["cargo", "build", "--locked"], cwd=ROOT, check=True)
    subprocess.run(["luajit", "addon/tests/run.lua"], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix="goldbook-sandbox-") as temporary:
        directory = Path(temporary)
        with helpers["server"](directory, None, ROOT / "target/debug/goldbook-server") as api:
            helpers["synchronize"](api, directory, ROOT / "fixtures/Goldbook.lua", None,
                                   ROOT / "target/debug/goldbook-sync")
            for name in ("sellers", "trades"):
                fixture = directory / f"{name}.lua"
                subprocess.run(["luajit", f"addon/tests/{name}.lua", str(fixture)], cwd=ROOT,
                               check=True, stdout=subprocess.DEVNULL)
                helpers["synchronize"](api, directory, fixture, None,
                                       ROOT / "target/debug/goldbook-sync", f"{name}-state.json")
            prices = api.request("GET", "/api/prices?realm=Faramon&faction=Horde")[0]
            assert prices["status"] == 200 and prices["body"]["items"], prices
            login, headers = api.request("POST", "/api/login", {"id": "K7Q2M9PX", "key": helpers["KEY"]})
            assert login["status"] == 200, login
            cookie = headers["set-cookie"].split(";")[0]
            trades = api.request("GET", "/api/trades", cookie=cookie)[0]
            assert trades["status"] == 200 and trades["body"]["trades"], trades
            sellers = api.request("GET", "/api/sellers?realm=Faramon&faction=Horde&itemKey=2589")[0]
            assert sellers["status"] == 200 and sellers["body"]["snapshot"], sellers
            print(f"\nLocal test server: http://127.0.0.1:{api.port}\n"
                  f"Realm: Faramon, Horde\nLogin ID: K7Q2M9PX\nLogin key: {helpers['KEY']}\n"
                  f"Temporary database: {directory / 'goldbook.sqlite'}\n"
                  "Ctrl-C stops the server and deletes its test data.", flush=True)
            if not args.smoke:
                try:
                    while True:
                        time.sleep(1)
                except KeyboardInterrupt:
                    pass


if __name__ == "__main__":
    main()
