#!/usr/bin/env python3
"""Backs up Goldbook's database to OVH Object Storage, and gets backups back.

backup  copies the live database through SQLite's backup API, checks the copy,
        compresses it with zstd, encrypts it to an age public key and uploads
        it. The goldbook-backup systemd timer runs this every hour.
list    prints the key of every backup, oldest first.
fetch   downloads a backup, the newest unless --key names one. It stays
        encrypted.
open    decrypts and decompresses a fetched backup with the age private key,
        and checks the database it holds.

backup, list and fetch read the bucket and its keys from the --config file,
/opt/goldbook/backup.env by default. Only the standard library, zstd and age
are needed.
"""

import argparse
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree

ROOT = Path("/opt/goldbook")
PREFIX = "goldbook/"
SUFFIX = ".sqlite.zst.age"
S3_NAMESPACE = "{http://s3.amazonaws.com/doc/2006-03-01/}"
SETTINGS = ("S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY", "AGE_RECIPIENT")


@dataclass(frozen=True)
class Bucket:
    endpoint: str
    region: str
    name: str
    access_key: str
    secret_key: str


def read_config(path):
    settings = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            name, separator, value = line.partition("=")
            if not separator:
                raise SystemExit(f"{path}: expected NAME=value, got {line!r}")
            settings[name.strip()] = value.strip()
    missing = [name for name in SETTINGS if not settings.get(name)]
    if missing:
        raise SystemExit(f"{path} is missing " + ", ".join(missing))
    return settings


def bucket_from(settings):
    return Bucket(settings["S3_ENDPOINT"].rstrip("/"), settings["S3_REGION"], settings["S3_BUCKET"],
                  settings["S3_ACCESS_KEY"], settings["S3_SECRET_KEY"])


def signed_request(bucket, method, key="", query=(), body=b"", now=None):
    """Returns a path-style request signed with AWS Signature Version 4."""
    now = now or datetime.now(timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    scope = f"{now:%Y%m%d}/{bucket.region}/s3/aws4_request"
    endpoint = urllib.parse.urlsplit(bucket.endpoint)
    path = urllib.parse.quote(f"/{bucket.name}/{key}" if key else f"/{bucket.name}", safe="/~")
    query_string = "&".join(f"{urllib.parse.quote(name, safe='~')}={urllib.parse.quote(value, safe='~')}"
                            for name, value in sorted(query))
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {"host": endpoint.netloc, "x-amz-content-sha256": payload_hash, "x-amz-date": stamp}
    signed_headers = ";".join(sorted(headers))
    canonical_request = "\n".join([
        method, path, query_string,
        "".join(f"{name}:{headers[name]}\n" for name in sorted(headers)),
        signed_headers, payload_hash])
    string_to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope,
                                hashlib.sha256(canonical_request.encode()).hexdigest()])
    signing_key = ("AWS4" + bucket.secret_key).encode()
    for part in (f"{now:%Y%m%d}", bucket.region, "s3", "aws4_request"):
        signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={bucket.access_key}/{scope}, "
                                f"SignedHeaders={signed_headers}, Signature={signature}")
    url = f"{endpoint.scheme}://{endpoint.netloc}{path}" + (f"?{query_string}" if query_string else "")
    headers.pop("host")
    if method == "PUT":
        # Unsigned, but urllib would otherwise label the upload as a form.
        headers["content-type"] = "application/octet-stream"
    return urllib.request.Request(url, data=body if method == "PUT" else None, method=method, headers=headers)


def send(request):
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:2000]
        raise SystemExit(f"{request.get_method()} {request.full_url} failed with {error.code}: {detail}") from None


def list_keys(bucket):
    keys, token = [], None
    while True:
        query = [("list-type", "2"), ("prefix", PREFIX)] + ([("continuation-token", token)] if token else [])
        page = ElementTree.fromstring(send(signed_request(bucket, "GET", query=query)))
        keys += [element.text for element in page.iter(S3_NAMESPACE + "Key")]
        if page.findtext(S3_NAMESPACE + "IsTruncated") != "true":
            # Each key holds its UTC time stamp, so name order is time order.
            return sorted(key for key in keys if key.endswith(SUFFIX))
        token = page.findtext(S3_NAMESPACE + "NextContinuationToken")


def pipe(command, data=None, source=None):
    """Runs zstd or age on bytes or a file, and fails with the tool's own message."""
    result = subprocess.run(command, input=data, stdin=source, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"{command[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def snapshot(database, destination):
    """Copies the database through SQLite's backup API, which a write in progress cannot tear."""
    source = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    copy = sqlite3.connect(destination)
    try:
        source.backup(copy)
        integrity = copy.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        source.close()
        copy.close()
    if integrity != "ok":
        raise SystemExit(f"The copy of {database} failed its integrity check: {integrity}")


def backup(settings):
    now = datetime.now(timezone.utc)
    database = ROOT / "data/goldbook.sqlite"
    if not database.is_file():
        raise SystemExit(f"Expected the database at {database}")
    with tempfile.TemporaryDirectory(prefix="goldbook-backup-") as temporary:
        copy = Path(temporary) / "goldbook.sqlite"
        snapshot(database, copy)
        compressed = pipe(["zstd", "-q", "-c", str(copy)])
    sealed = pipe(["age", "--encrypt", "--recipient", settings["AGE_RECIPIENT"]], compressed)
    key = f"{PREFIX}goldbook-{now:%Y%m%dT%H%M%SZ}{SUFFIX}"
    send(signed_request(bucket_from(settings), "PUT", key, body=sealed))
    print(json.dumps({"uploaded": key, "bytes": len(sealed)}), flush=True)


def open_backup(identity, sealed, output):
    if output.exists():
        raise SystemExit(f"{output} already exists")
    with sealed.open("rb") as source:
        decrypted = pipe(["age", "--decrypt", "--identity", str(identity)], source=source)
    database = pipe(["zstd", "-q", "-d", "-c"], decrypted)
    output.write_bytes(database)
    with closing(sqlite3.connect(output.as_uri() + "?mode=ro", uri=True)) as connection:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        tables = connection.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table'").fetchone()[0]
    if integrity != "ok":
        raise SystemExit(f"{output} failed its integrity check: {integrity}")
    print(json.dumps({"restored": str(output), "integrity": integrity, "tables": tables}), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=ROOT / "backup.env")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("backup")
    commands.add_parser("list")
    fetch = commands.add_parser("fetch")
    fetch.add_argument("--key", help="the backup to fetch; the newest by default")
    fetch.add_argument("output", type=Path)
    opening = commands.add_parser("open")
    opening.add_argument("--identity", type=Path, required=True, help="the age private key file")
    opening.add_argument("sealed", type=Path)
    opening.add_argument("output", type=Path)
    args = parser.parse_args(argv)

    if args.command == "open":
        open_backup(args.identity, args.sealed, args.output)
        return
    settings = read_config(args.config)
    if args.command == "backup":
        backup(settings)
        return
    bucket = bucket_from(settings)
    if args.command == "list":
        print("\n".join(list_keys(bucket)))
        return
    key = args.key
    if key is None:
        keys = list_keys(bucket)
        if not keys:
            raise SystemExit(f"Bucket {bucket.name} has no backups under {PREFIX}")
        key = keys[-1]
    args.output.write_bytes(send(signed_request(bucket, "GET", key)))
    print(json.dumps({"fetched": key, "output": str(args.output)}), flush=True)


if __name__ == "__main__":
    sys.exit(main())
