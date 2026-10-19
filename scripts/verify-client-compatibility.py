#!/usr/bin/env python3
"""Replay the requests of every supported client version against the current server."""
import argparse
import contextlib
import gzip
import http.client
import json
from pathlib import Path
import re
import runpy
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))
# Both upload setups the released app supports. The README sets up production with Battle.net.
SERVERS = {
    "default": lambda port: {"SELF_REGISTRATION": "true", "UPLOAD_TOKEN": "dev-token", "BNET_CLIENT_ID": "",
                             "BNET_CLIENT_SECRET": "", "GOLDBOOK_PUBLIC_URL": ""},
    "battlenet": lambda port: {"SELF_REGISTRATION": "true", "BNET_CLIENT_ID": "compatibility-client",
                               "BNET_CLIENT_SECRET": "compatibility-secret",
                               "GOLDBOOK_PUBLIC_URL": f"http://127.0.0.1:{port}"},
}
TYPES = {
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    "unsigned": lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 0,
    "positive": lambda v: isinstance(v, int) and not isinstance(v, bool) and v > 0,
}
VARIABLE = re.compile(r"\{\{(\w+)\}\}")


def fill(value, variables, escape=False):
    if isinstance(value, str):
        def replace(match):
            if match.group(1) not in variables:
                raise LookupError(f"uses {{{{{match.group(1)}}}}}, which no earlier request captured")
            text = variables[match.group(1)]
            return re.escape(text) if escape else text
        return VARIABLE.sub(replace, value)
    if isinstance(value, list):
        return [fill(v, variables, escape) for v in value]
    if isinstance(value, dict):
        return {k: fill(v, variables, escape) for k, v in value.items()}
    return value


def mismatch(value, shape, where="body"):
    """How value differs from shape, or None. See fixtures/clients/README.md."""
    if isinstance(shape, str):
        if unknown := set(shape.split("|")) - TYPES.keys():
            raise LookupError(f"names unknown types {', '.join(sorted(unknown))}")
        if any(TYPES[kind](value) for kind in shape.split("|")):
            return None
        return f"{where} is {json.dumps(value)[:100]}, expected {shape}"
    if isinstance(shape, list):
        if not isinstance(value, list):
            return f"{where} is {json.dumps(value)[:100]}, expected a list"
        if len(shape) > 1 and len(value) != len(shape):
            return f"{where} has {len(value)} entries, expected {len(shape)}"
        pairs = zip(value, shape) if len(shape) > 1 else ((v, shape[0]) for v in value)
        return next((m for i, (v, s) in enumerate(pairs) if (m := mismatch(v, s, f"{where}[{i}]"))), None)
    if "$match" in shape:
        if isinstance(value, str) and re.fullmatch(shape["$match"], value):
            return None
        return f"{where} is {json.dumps(value)[:100]}, expected text matching {shape['$match']}"
    if not isinstance(value, dict):
        return f"{where} is {json.dumps(value)[:100]}, expected an object"
    for key, inner in shape.items():
        if key == "*":
            if not value:
                return f"{where} is empty"
            entries = value.items()
        elif key.endswith("?"):
            entries = [(key[:-1], value[key[:-1]])] if key[:-1] in value else []
        elif key in value:
            entries = [(key, value[key])]
        else:
            return f"{where} has no {key}"
        for name, item in entries:
            if found := mismatch(item, inner, f"{where}.{name}"):
                return found
    return None


def send(port, request):
    body = request.get("body")
    if "json" in request:
        body = json.dumps(request["json"], ensure_ascii=False)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    try:
        connection.request(request["method"], request["path"], None if body is None else body.encode(),
                           request.get("headers", {}))
        response = connection.getresponse()
        raw = response.read()
        if response.getheader("content-encoding") == "gzip":
            raw = gzip.decompress(raw)
        return response, raw
    finally:
        connection.close()


def check(fixture, response, raw):
    expect = fixture["expect"]
    allowed = expect["status"] if isinstance(expect["status"], list) else [expect["status"]]
    if not any(response.status == s or s == f"{response.status // 100}xx" for s in allowed):
        return f"answered {response.status}, expected {' or '.join(map(str, allowed))}: {raw[:200]!r}"
    if len(raw) > expect.get("maxBytes", len(raw)):
        return f"answered {len(raw)} bytes, the client reads at most {expect['maxBytes']}"
    for name, pattern in expect.get("headers", {}).items():
        value = response.getheader(name)
        if value is None or not re.fullmatch(pattern, value):
            return f"header {name} is {value!r}, expected {pattern}"
    if "body" in expect:
        try:
            body = json.loads(raw)
        except ValueError:
            return f"body is not JSON: {raw[:200]!r}"
        return mismatch(body, expect["body"])
    return None


def replay(version, directory):
    servers, variables, failures = {}, {}, []
    files = sorted(version.glob("*.json"))
    with contextlib.ExitStack() as stack:
        for file in files:
            label = f"{version.name}/{file.name}"
            fixture = json.loads(file.read_text())
            profile = fixture.get("server", "default")
            if profile not in servers:
                data = directory / version.name / profile
                data.mkdir(parents=True)
                servers[profile] = (data, stack.enter_context(helpers["server"](
                    data, None, ROOT / "target/debug/goldbook-server", SERVERS[profile])))
            data, api = servers[profile]
            variables["base"] = f"http://127.0.0.1:{api.port}"
            for name, content in fixture.get("files", {}).items():
                path = data / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content if isinstance(content, str) else json.dumps(content))
            try:
                request = fill(fixture["request"], variables)
                fixture["expect"] = fill(fixture["expect"], variables, escape=True)
                response, raw = send(api.port, request)
                if problem := check(fixture, response, raw):
                    raise LookupError(f"{request['method']} {request['path']} {problem}")
                for name, key in fixture.get("capture", {}).items():
                    variables[name] = json.loads(raw)[key]
            except (LookupError, OSError) as error:
                failures.append(f"{label}: {error}")
    return len(files), failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, default=ROOT / "fixtures/clients",
                        help="One folder per client version, as in fixtures/clients")
    args = parser.parse_args()
    versions = sorted((p for p in args.fixtures.iterdir() if p.is_dir()),
                      key=lambda p: tuple(int(n) for n in p.name.split(".")))
    if not versions:
        raise SystemExit(f"No client versions in {args.fixtures}")
    total, failures = 0, []
    with tempfile.TemporaryDirectory(prefix="goldbook-clients-") as temporary:
        for version in versions:
            count, found = replay(version, Path(temporary))
            total += count
            failures += found
    if failures:
        print("The current server breaks released clients:", *failures, sep="\n  ", file=sys.stderr)
        raise SystemExit(1)
    print(f"Verified {total} requests of client {', '.join(p.name for p in versions)} against the current server; "
          f"the support floor is {versions[0].name}.")


if __name__ == "__main__":
    main()
