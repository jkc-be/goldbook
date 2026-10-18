#!/usr/bin/env python3
"""Compare real HTTP responses with the pre-migration baseline using disposable databases."""
import argparse
import contextlib
import difflib
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "scripts/migration-baseline.json"
KEY = "7KQ2M9PXABCDEFGHJKMN"
NEW_KEY = "ABCDEFGHJKMNPQRSTVWX"
TOKEN = "dev-token"
SECURITY = ("x-content-type-options", "referrer-policy", "content-security-policy")


def run(command, **kwargs):
    answer = subprocess.run([str(x) for x in command], text=True, capture_output=True, **kwargs)
    if answer.returncode:
        raise RuntimeError(f"{' '.join(map(str, command))}\n{answer.stdout}\n{answer.stderr}")
    return answer.stdout


def key_hash(key):
    return hashlib.sha256(key.encode()).hexdigest()


class API:
    def __init__(self, port):
        self.port = port
        self.transcript = {}

    def request(self, method, path, body=None, *, cookie=None, token=None, headers=None):
        data = body if isinstance(body, bytes) else None if body is None else json.dumps(body).encode()
        fields = dict(headers or {})
        if body is not None:
            fields.setdefault("Content-Type", "application/json")
        if token:
            fields["Authorization"] = f"Bearer {token}"
        if cookie:
            fields["Cookie"] = cookie
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        try:
            connection.request(method, path, body=data, headers=fields)
            answer = connection.getresponse()
            raw = answer.read()
            response_headers = {name.lower(): value for name, value in answer.getheaders()}
            content_type = response_headers.get("content-type", "").split(";")[0]
            payload = json.loads(raw) if content_type == "application/json" and raw else None
            if payload is None:
                payload = {"sha256": hashlib.sha256(raw).hexdigest()} if raw else None
            normalized = {name: response_headers[name] for name in SECURITY if name in response_headers}
            normalized["content-type"] = content_type
            for name in ("set-cookie", "location", "cache-control"):
                if name in response_headers:
                    normalized[name] = re.sub(r"goldbook_session=[^;]+", "goldbook_session=<random>", response_headers[name])
            return {"status": answer.status, "body": payload, "headers": normalized}, response_headers
        finally:
            connection.close()

    def check(self, label, method, path, body=None, **kwargs):
        answer, headers = self.request(method, path, body, **kwargs)
        assert label not in self.transcript, label
        self.transcript[label] = answer
        return answer, headers


@contextlib.contextmanager
def server(directory, old_repo, binary):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    environment = local_environment(directory, port)
    if old_repo:
        code = """from wsgiref.simple_server import make_server, WSGIRequestHandler
from server.app import create_app
import os
class RequestHandler(WSGIRequestHandler):
    def get_environ(self):
        environ = super().get_environ()
        if 'content-type' not in self.headers:
            environ.pop('CONTENT_TYPE', None)
        return environ
make_server(os.environ['HOST'], int(os.environ['PORT']), create_app(os.environ['DATABASE'], os.environ['UPLOAD_TOKEN']), handler_class=RequestHandler).serve_forever()
"""
        command = [sys.executable, "-c", code]
    else:
        command = [str(binary)]
    with (directory / "server.log").open("w+") as log:
        process = subprocess.Popen(command, cwd=old_repo or ROOT, env=environment, stdout=log, stderr=log)
        try:
            api = API(port)
            for _ in range(200):
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f"server exited\n{log.read()}")
                try:
                    if api.request("GET", "/api/realms")[0]["status"] == 200:
                        break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                raise RuntimeError("server did not start within 10 seconds")
            yield api
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def local_environment(directory, port):
    """Use only local data and test credentials, regardless of the caller's shell."""
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GOLDBOOK_", "BNET_"))
                   and key not in ("WEB_DIR", "TRUSTED_PROXY")}
    environment.update(HOST="127.0.0.1", PORT=str(port),
                       DATABASE=str(directory / "goldbook.sqlite"),
                       UPLOAD_TOKEN="dev-token,friend-token", SELF_REGISTRATION="false")
    return environment


def synchronize(api, directory, fixture, old_repo, binary, state_name="state.json"):
    state = directory / state_name
    url = f"http://127.0.0.1:{api.port}"
    if old_repo:
        expression = "import { syncFile } from './sync/sync.ts'; console.log(JSON.stringify(await syncFile({file:process.argv[1],api:process.argv[2],token:process.argv[3],statePath:process.argv[4],log:()=>{}})));"
        return run(["node", "--input-type=module", "-e", expression, fixture, url, TOKEN, state], cwd=old_repo)
    return run([binary, "--file", fixture, "--api", url, "--token", TOKEN, "--state", state, "--once"], cwd=ROOT)


def exercise(api, directory, fixture, old_repo, sync_binary):
    check = api.check
    check("empty-realms", "GET", "/api/realms")
    for label, method, path in [
        ("static-index", "GET", "/"),
        ("static-js", "GET", "/app.js"),
        ("static-css", "GET", "/style.css"),
        ("static-head", "HEAD", "/"),
        ("static-missing", "GET", "/absent.html"),
        ("static-traversal", "GET", "/../Cargo.toml"),
        ("static-post", "POST", "/"),
    ]:
        check(label, method, path)
    scan = dict(realm="Parity", faction="Horde", region="EU", scannedAt=1760000000, mode="browse", scanner="Sultan", build="1.60.1", rows=[["2589", 110, 0, 42, 0]], items={"2589": ["Linen Cloth", 1]})
    check("wrong-upload-token", "POST", "/api/scans", scan, token="wrong")
    check("missing-upload-token", "POST", "/api/scans", scan)
    check("malformed-json", "POST", "/api/scans", b"{not json", token=TOKEN)
    check("invalid-price", "POST", "/api/scans", {**scan, "rows": [["2589", 0, 0, 1, 0]]}, token=TOKEN)
    check("duplicate-row", "POST", "/api/scans", {**scan, "rows": scan["rows"] * 2}, token=TOKEN)
    synchronize(api, directory, fixture, old_repo, sync_binary)
    synchronize(api, directory, fixture, old_repo, sync_binary)
    synchronize(api, directory, fixture, old_repo, sync_binary, "lost-state.json")
    api.transcript["sync-state"] = json.loads((directory / "state.json").read_text())
    for label, path in [
        ("fixture-realms", "/api/realms"),
        ("fixture-prices", "/api/prices?realm=Faramon&faction=Horde&sort=min&order=desc"),
        ("fixture-history", "/api/history?realm=Faramon&faction=Horde&itemKey=2589"),
        ("fixture-trends", "/api/trends?realm=Faramon&faction=Horde&items=2589,999999"),
        ("search-text", "/api/prices?realm=Faramon&faction=Horde&q=CINCH%20of"),
        ("search-key", "/api/prices?realm=Faramon&faction=Horde&q=7070"),
        ("literal-percent", "/api/prices?realm=Faramon&faction=Horde&q=%25"),
        ("literal-underscore", "/api/prices?realm=Faramon&faction=Horde&q=_"),
        ("pagination", "/api/prices?realm=Faramon&faction=Horde&q=e&limit=1&offset=1"),
        ("pagination-past-end", "/api/prices?realm=Faramon&faction=Horde&offset=20"),
        ("empty-page", "/api/prices?realm=Faramon&faction=Horde&limit=0"),
        ("missing-faction", "/api/prices?realm=Faramon"),
        ("bad-sort", "/api/prices?realm=Faramon&faction=Horde&sort=drop"),
        ("bad-limit", "/api/prices?realm=Faramon&faction=Horde&limit=201"),
        ("missing-trend-items", "/api/trends?realm=Faramon&faction=Horde"),
        ("missing-history-item", "/api/history?realm=Faramon&faction=Horde"),
        ("unknown-item-history", "/api/history?realm=Faramon&faction=Horde&itemKey=999999"),
        ("unknown-market", "/api/prices?realm=Absent&faction=Horde"),
        ("unknown-route", "/api/nope"),
        ("anonymous-account", "/api/account"),
        ("anonymous-character", "/api/character?name=Sultan&realm=Faramon"),
    ]:
        check(label, "GET", path)
    assert api.transcript["fixture-realms"]["body"]["realms"][0]["scans"] == 3, "sync lost scans or uploaded duplicates"
    for label, upload in [
        ("first-snapshot", scan),
        ("same-second-snapshot", {**scan, "rows": [["2589", 120, 0, 40, 0]]}),
        ("first-snapshot-retry", scan),
        ("full-scan", {**scan, "scannedAt": 1760086400, "mode": "replicate", "rows": [["2589", 100, 105, 100, 4], ["7070", 300, 320, 5, 2]], "items": {"7070": ["Elemental Water", 1]}}),
        ("quick-after-full", {**scan, "scannedAt": 1760172800, "rows": [["2589", 90, 0, 35, 0], ["7070", 290, 0, 4, 0]]}),
    ]:
        check(label, "POST", "/api/scans", upload, token=TOKEN)
    collision = directory / "Collision.lua"
    collision.write_text('GoldbookDB = { ["items"] = {}, ["scans"] = {'
        + ",".join('{ ["realm"] = "Collision", ["faction"] = "Horde", ["region"] = "EU", ["at"] = 1760000000, ["mode"] = "browse", ["by"] = "Sultan", ["build"] = "1.60.1", ["count"] = 1, ["data"] = "2589,%d,0,42,0" }' % price for price in (110, 120))
        + "} }")
    (directory / "collision-state.json").write_text('{"uploaded":["Collision|Horde|1760000000"]}')
    synchronize(api, directory, collision, old_repo, sync_binary, "collision-state.json")
    synchronize(api, directory, collision, old_repo, sync_binary, "collision-state.json")
    check("sync-same-second-history", "GET", "/api/history?realm=Collision&faction=Horde&itemKey=2589")
    check("sync-same-second-prices", "GET", "/api/prices?realm=Collision&faction=Horde")
    for day in range(30):
        full = day % 3 == 0
        rows = []
        names = {}
        for item in range(1, 8001):
            price = math.floor((100 + item * 37) * (1 + .25 * math.sin(day / 4 + item)) + .5)
            rows.append([str(100000 + item), price, math.floor(price * 1.08 + .5) if full else 0, 1 + (item * 7 + day) % 400, 1 + item % 30 if full else 0])
            names[str(100000 + item)] = [f"Loadtest Item {item}", item % 5]
        check(f"load-upload-{day}", "POST", "/api/scans", {**scan, "realm": "Loadtest", "scannedAt": 1757000000 + day * 86400, "mode": "replicate" if full else "browse", "rows": rows, "items": names}, token=TOKEN)
    check("load-pagination", "GET", "/api/prices?realm=Loadtest&faction=Horde&limit=200&offset=7900&sort=quantity")
    check("load-market-values", "GET", "/api/prices?realm=Loadtest&faction=Horde&limit=3&sort=market&order=desc")
    check("load-history", "GET", "/api/history?realm=Loadtest&faction=Horde&itemKey=104242")
    check("load-trends", "GET", "/api/trends?realm=Loadtest&faction=Horde&items=104242,999999")
    for sort in ("name", "min", "market", "quantity"):
        for order in ("asc", "desc"):
            check(f"borrowed-market-{sort}-{order}", "GET", f"/api/prices?realm=Parity&faction=Horde&sort={sort}&order={order}")
    check("same-second-history", "GET", "/api/history?realm=Parity&faction=Horde&itemKey=2589")
    check("daily-lows", "GET", "/api/trends?realm=Parity&faction=Horde&items=2589,7070,999999")
    login = {"id": "k7q2-m9px", "key": "7kq2m-9pxab-cdefg-hjkmn"}
    check("wrong-key", "POST", "/api/login", {**login, "key": NEW_KEY})
    check("login-form-rejected", "POST", "/api/login", b"id=K7Q2M9PX", headers={"Content-Type": "application/x-www-form-urlencoded"})
    check("oversize-login", "POST", "/api/login", b" " * 4097)
    _, headers = check("addon-login", "POST", "/api/login", login)
    cookie = headers.get("set-cookie", "").split(";")[0]
    assert cookie.startswith("goldbook_session="), "fixture account never reached server"
    check("addon-account", "GET", "/api/account", cookie=cookie)
    check("addon-character", "GET", "/api/character?name=Sultan&realm=Faramon", cookie=cookie)
    check("first-session-cookie-wins", "GET", "/api/account", cookie=f"theme=dark; {cookie}; goldbook_session=forged")
    check("missing-character", "GET", "/api/character?name=Absent&realm=Faramon", cookie=cookie)
    check("missing-character-name", "GET", "/api/character?realm=Faramon", cookie=cookie)
    check("https-cookie", "POST", "/api/login", login, headers={"X-Forwarded-Proto": "https"})
    check("desktop-bad-origin", "POST", "/api/desktop-login", b"id=K7Q2M9PX&key=" + KEY.encode(), headers={"Content-Type": "application/x-www-form-urlencoded", "Origin": "https://attacker.invalid"})
    check("desktop-login", "POST", "/api/desktop-login", b"id=K7Q2M9PX&key=" + KEY.encode(), headers={"Content-Type": "application/x-www-form-urlencoded", "Origin": "http://127.0.0.1:49152"})
    for label, origin, body in [
        ("desktop-port-out-of-range", "http://127.0.0.1:65536", b"id=K7Q2M9PX&key=" + KEY.encode()),
        ("desktop-origin-suffix", "http://127.0.0.1.evil.invalid:80", b"id=K7Q2M9PX&key=" + KEY.encode()),
        ("desktop-duplicate-fields", "http://127.0.0.1:49152", b"id=K7Q2M9PX&key=x&key=x"),
        ("desktop-body-too-big", "http://127.0.0.1:49152", b"x" * 4097),
    ]:
        check(label, "POST", "/api/desktop-login", body, headers={"Content-Type": "application/x-www-form-urlencoded", "Origin": origin})
    check("logout-form-rejected", "POST", "/api/logout", b"logout=true", cookie=cookie, headers={"Content-Type": "text/plain"})
    check("logout", "POST", "/api/logout", cookie=cookie)
    check("logged-out-account", "GET", "/api/account", cookie=cookie)
    character = dict(name="Owner", realm="Parity", faction=None, **{"class": None}, level=None, updatedAt=None, gold=[[1760000400, 100], [1759996800, 200], [1760000400, 300]], bags=None, bank=None)
    account = dict(id="E2E7TEST", keyHash=key_hash(KEY), characters=[character])
    check("account-upload", "POST", "/api/account", account, token=TOKEN)
    _, headers = check("owner-login", "POST", "/api/login", {"id": account["id"], "key": KEY})
    owner_cookie = headers.get("set-cookie", "").split(";")[0]
    check("gold-latest-hour", "GET", "/api/account", cookie=owner_cookie)
    check("gold-hour-deduplication", "GET", "/api/character?name=Owner&realm=Parity", cookie=owner_cookie)
    check("account-takeover", "POST", "/api/account", {**account, "keyHash": key_hash(NEW_KEY), "characters": []}, token="friend-token")
    check("owner-after-takeover", "GET", "/api/account", cookie=owner_cookie)
    rotated = {**account, "keyHash": key_hash(NEW_KEY), "previousKeyHash": key_hash(KEY)}
    check("rotate-key", "POST", "/api/account", rotated, token=TOKEN)
    check("rotation-revokes-session", "GET", "/api/account", cookie=owner_cookie)
    check("rotation-rejects-old-key", "POST", "/api/login", {"id": account["id"], "key": KEY})
    check("rotation-accepts-new-key", "POST", "/api/login", {"id": account["id"], "key": NEW_KEY})
    for attempt in range(6):
        check(f"login-rate-limit-{attempt + 1}", "POST", "/api/login", {"id": "RATETEST", "key": KEY})
    assert api.transcript["login-rate-limit-6"]["status"] == 429
    alias_fixture = ROOT / "crates/goldbook-sync/tests/data/RealmAliases.lua"
    synchronize(api, directory, alias_fixture, old_repo, sync_binary, state_name="alias-state.json")
    _, alias_headers = check("alias-login", "POST", "/api/login", {"id": "K7Q2M9PX", "key": KEY})
    alias_cookie = alias_headers.get("set-cookie", "").split(";")[0]
    check("alias-account", "GET", "/api/account", cookie=alias_cookie)
    check("alias-character", "GET", "/api/character?name=Faramon&realm=ClassicBetaPvP2", cookie=alias_cookie)
    return api.transcript


def exercise_upgrade(directory, old_repo, server_binary):
    directory.mkdir()
    database = directory / "goldbook.sqlite"
    with sqlite3.connect(database) as db:
        db.execute("CREATE TABLE migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)")
        for path in sorted((ROOT / "server/migrations").glob("*.sql")):
            if path.name >= "0004":
                continue
            db.executescript(path.read_text())
            db.execute("INSERT INTO migrations VALUES (?, 0)", (path.name,))
        db.execute("INSERT INTO scans VALUES (7, 'Legacy', 'Horde', 'EU', 1760000000, 'browse', 'Sültan', '1.60.1', 2, 1760000010)")
        db.executemany("INSERT INTO prices VALUES (7, ?, ?, ?, ?, ?)", [("7070", 300, 0, 5, 0), ("2589", 110, 0, 42, 0)])
        db.execute("INSERT INTO accounts VALUES ('K7Q2M9PX', ?, 0)", (key_hash(KEY),))
        db.execute("INSERT INTO characters (account_id, name, realm, gold) VALUES ('K7Q2M9PX', 'Legacy', 'Legacy', '[[20000,100],[20000,200],[1728172800,300]]')")
        db.execute("INSERT INTO sessions VALUES (?, 'K7Q2M9PX', ?)", (key_hash("legacy-session"), int(time.time()) + 3600))
    with server(directory, old_repo, server_binary) as api:
        api.check("upgrade-character", "GET", "/api/character?name=Legacy&realm=Legacy", cookie="goldbook_session=legacy-session")
        retry = dict(realm="Legacy", faction="Horde", region="EU", scannedAt=1760000000, mode="browse", scanner="Sültan", build="1.60.1", rows=[["2589", 110, 0, 42, 0], ["7070", 300, 0, 5, 0]], items={})
        api.check("upgrade-scan-retry", "POST", "/api/scans", retry, token=TOKEN)
        api.check("upgrade-history", "GET", "/api/history?realm=Legacy&faction=Horde&itemKey=2589")
        api.check("upgrade-prices", "GET", "/api/prices?realm=Legacy&faction=Horde")
    with sqlite3.connect(database) as db:
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        assert db.execute("SELECT id, uploaded_at FROM scans").fetchall() == [(7, 1760000010)], "upgrade lost or duplicated a historical scan"
        assert db.execute("SELECT COUNT(*) FROM migrations").fetchone()[0] == (5 if old_repo else 12)
    with server(directory, old_repo, server_binary) as restarted:
        restarted.check("upgrade-restart", "GET", "/api/character?name=Legacy&realm=Legacy", cookie="goldbook_session=legacy-session")
        api.transcript.update(restarted.transcript)
    return api.transcript


# The original addon booked only auction house and vendor trades. Accounting
# entries of any other side (the run test books gold it cannot explain as
# other income) are left out of the fixture, so that the account upload still
# compares with the original; verify-trades.py and the sync tests cover them.
ORIGINAL_SIDES = ("buy", "sell", "vendor")


def original_trades(saved):
    entry = re.compile(r'^\{\n(?:(?!^\}).*\n)*?\["side"\] = "(\w+)",\n(?:(?!^\}).*\n)*?^\}, -- \[\d+\]\n', re.M)
    return entry.sub(lambda match: match.group(0) if match.group(1) in ORIGINAL_SIDES else "", saved)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old-repo", type=Path, help="Run the original Python server and TypeScript sync from this checkout")
    parser.add_argument("--server", type=Path, default=ROOT / "target/debug/goldbook-server")
    parser.add_argument("--sync", type=Path, default=ROOT / "target/debug/goldbook-sync")
    parser.add_argument("--capture-baseline", action="store_true", help="Replace baseline; requires --old-repo")
    args = parser.parse_args()
    if args.capture_baseline and not args.old_repo:
        parser.error("--capture-baseline requires --old-repo")
    run(["luajit", "addon/tests/run.lua"], cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="goldbook-verify-") as temporary:
        directory = Path(temporary)
        fixture = directory / "Goldbook.lua"
        fixture.write_text(original_trades((ROOT / "fixtures/Goldbook.lua").read_text()))
        with server(directory, args.old_repo, args.server.resolve()) as api:
            transcript = exercise(api, directory, fixture, args.old_repo, args.sync.resolve())
        transcript.update(exercise_upgrade(directory / "upgrade", args.old_repo, args.server.resolve()))
    rendered = json.dumps(transcript, indent=2, sort_keys=True) + "\n"
    if args.capture_baseline:
        BASELINE.write_text(rendered)
        print(f"Captured {len(transcript)} original observations in {BASELINE.relative_to(ROOT)}")
        return
    expected = json.loads(BASELINE.read_text())
    if not args.old_repo:
        # The migration baseline fixes API behavior, not the evolving web UI.
        # Still require the server to serve the exact current, versioned assets.
        index = (ROOT / "web/index.html").read_text()
        for name, label in (("app.js", "static-js"), ("theme.js", None), ("style.css", "static-css")):
            digest = hashlib.sha256((ROOT / "web" / name).read_bytes()).hexdigest()
            if label:
                expected[label]["body"] = {"sha256": digest}
            index = index.replace(f'"{name}"', f'"{name}?v={digest[:12]}"')
        expected["static-index"]["body"] = {"sha256": hashlib.sha256(index.encode()).hexdigest()}
        # Full scans now also upload seller snapshots. verify-sellers.py checks
        # that stream end to end; preserve the original scan/account comparison.
        transcript["sync-state"]["uploaded"] = [
            entry for entry in transcript["sync-state"]["uploaded"]
            if not entry.startswith("sellers:")
        ]
        rendered = json.dumps(transcript, indent=2, sort_keys=True) + "\n"
    if transcript != expected:
        difference = difflib.unified_diff(json.dumps(expected, indent=2, sort_keys=True).splitlines(), rendered.splitlines(), fromfile="original Python API", tofile="current API", lineterm="")
        print("\n".join(difference), file=sys.stderr)
        raise SystemExit(1)
    print(f"Verified {len(transcript)} observations, Lua fixture through sync, retry after lost state, login, ownership, and key rotation")


if __name__ == "__main__":
    main()
