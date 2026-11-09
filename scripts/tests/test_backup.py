import hashlib
import importlib.util
import io
import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
from contextlib import closing, redirect_stdout
from unittest import mock
from xml.sax.saxutils import escape

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/backup-ovh.py"
spec = importlib.util.spec_from_file_location("backup_ovh", SCRIPT)
backups = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backups)

BUCKET = backups.Bucket("https://s3.gra.io.cloud.ovh.net", "gra", "goldbook-backups",
                        "EXAMPLEACCESS", "example/secret+key")
NOW = datetime(2026, 11, 9, 7, 5, 0, tzinfo=timezone.utc)


class SignatureTest(unittest.TestCase):
    # The expected values come from botocore's S3SigV4Auth for the same requests.
    def test_upload_signature_matches_botocore(self):
        request = backups.signed_request(BUCKET, "PUT", "goldbook/goldbook-20261109T070500Z.sqlite.zst.age",
                                         body=b"sealed bytes", now=NOW)
        self.assertEqual(request.full_url, "https://s3.gra.io.cloud.ovh.net/goldbook-backups/"
                                           "goldbook/goldbook-20261109T070500Z.sqlite.zst.age")
        self.assertEqual(request.get_header("Authorization"),
                         "AWS4-HMAC-SHA256 Credential=EXAMPLEACCESS/20261109/gra/s3/aws4_request, "
                         "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                         "Signature=ed99083800e636ec6116b2d12e89eafec555ba80f3525cca318edcacbcee7568")
        self.assertEqual(request.get_header("X-amz-content-sha256"),
                         "f35cf5b361b0eaf7b0c02e75808e260e3f379c4745abe45552ba768e85687749")

    def test_listing_signature_matches_botocore(self):
        request = backups.signed_request(BUCKET, "GET", query=[("prefix", "goldbook/"), ("list-type", "2"),
                                                               ("continuation-token", "1/ab+=")], now=NOW)
        self.assertEqual(request.full_url, "https://s3.gra.io.cloud.ovh.net/goldbook-backups"
                                           "?continuation-token=1%2Fab%2B%3D&list-type=2&prefix=goldbook%2F")
        self.assertEqual(request.get_header("Authorization"),
                         "AWS4-HMAC-SHA256 Credential=EXAMPLEACCESS/20261109/gra/s3/aws4_request, "
                         "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                         "Signature=ed9096c806e4b73b1309fda2a50d4beee257731bdb01f430cc3a8b0cf61a0e17")


class FakeS3(BaseHTTPRequestHandler):
    """Keeps uploaded objects in memory and answers ListObjectsV2 a page at a time."""
    objects = {}
    page_size = 2

    def log_message(self, *args):
        pass

    def path_parts(self):
        url = urllib.parse.urlsplit(self.path)
        bucket, _, key = urllib.parse.unquote(url.path).lstrip("/").partition("/")
        return bucket, key, dict(urllib.parse.parse_qsl(url.query))

    def answer(self, status, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        bucket, key, _ = self.path_parts()
        body = self.rfile.read(int(self.headers["Content-Length"]))
        # S3 refuses a body whose hash differs from the signed one.
        if (bucket != "goldbook-backups" or not self.headers["Authorization"].startswith("AWS4-HMAC-SHA256 ")
                or self.headers["x-amz-content-sha256"] != hashlib.sha256(body).hexdigest()):
            self.answer(400)
            return
        self.objects[key] = body
        self.answer(200)

    def do_GET(self):
        bucket, key, query = self.path_parts()
        if key:
            self.answer(200, self.objects[key]) if key in self.objects else self.answer(404)
            return
        names = sorted(name for name in self.objects if name.startswith(query["prefix"]))
        start = int(query.get("continuation-token", "0"))
        page = names[start:start + self.page_size]
        truncated = start + self.page_size < len(names)
        body = ('<?xml version="1.0" encoding="UTF-8"?>'
                '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                + "".join(f"<Contents><Key>{escape(name)}</Key></Contents>" for name in page)
                + f"<IsTruncated>{'true' if truncated else 'false'}</IsTruncated>"
                + (f"<NextContinuationToken>{start + self.page_size}</NextContinuationToken>" if truncated else "")
                + "</ListBucketResult>")
        self.answer(200, body.encode())


class BackupTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        patch = mock.patch.object(backups, "ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)
        (self.root / "data").mkdir()
        # The running server keeps its connection open, so committed rows may
        # still be in the write-ahead log when the backup starts.
        self.database = sqlite3.connect(self.root / "data/goldbook.sqlite")
        self.addCleanup(self.database.close)
        self.database.execute("PRAGMA journal_mode=WAL")
        self.database.execute("CREATE TABLE realms (name TEXT)")
        self.database.execute("INSERT INTO realms VALUES ('Silvermoon')")
        self.database.commit()

        FakeS3.objects = {}
        server = ThreadingHTTPServer(("127.0.0.1", 0), FakeS3)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        self.identity = self.root / "backup.agekey"
        subprocess.run(["age-keygen", "-o", str(self.identity)], check=True, capture_output=True)
        recipient = subprocess.run(["age-keygen", "-y", str(self.identity)], check=True,
                                   capture_output=True, text=True).stdout.strip()
        self.config = self.root / "backup.env"
        self.config.write_text(f"# OVH Object Storage\nS3_ENDPOINT=http://127.0.0.1:{server.server_port}/\n"
                               f"S3_REGION=gra\nS3_BUCKET=goldbook-backups\nS3_ACCESS_KEY=EXAMPLEACCESS\n"
                               f"S3_SECRET_KEY=example/secret+key\nAGE_RECIPIENT={recipient}\n")

    def run_command(self, *argv):
        output = io.StringIO()
        with redirect_stdout(output):
            backups.main(["--config", str(self.config), *argv])
        return output.getvalue()

    def back_up_at(self, moment):
        with mock.patch.object(backups, "datetime") as clock:
            clock.now.return_value = moment
            return json.loads(self.run_command("backup"))

    def test_backup_uploads_an_encrypted_copy_that_opens_to_the_database(self):
        result = self.back_up_at(NOW)

        key = "goldbook/goldbook-20261109T070500Z.sqlite.zst.age"
        self.assertEqual(result, {"uploaded": key, "bytes": len(FakeS3.objects[key])})
        self.assertTrue(FakeS3.objects[key].startswith(b"age-encryption.org/v1\n"))
        self.assertNotIn(b"Silvermoon", FakeS3.objects[key])

        sealed = self.root / "fetched.age"
        self.assertEqual(json.loads(self.run_command("fetch", str(sealed))),
                         {"fetched": key, "output": str(sealed)})
        restored = self.root / "restored.sqlite"
        self.assertEqual(json.loads(self.run_command("open", "--identity", str(self.identity),
                                                     str(sealed), str(restored))),
                         {"restored": str(restored), "integrity": "ok", "tables": 1})
        with closing(sqlite3.connect(restored)) as connection:
            self.assertEqual(connection.execute("SELECT name FROM realms").fetchall(), [("Silvermoon",)])

    def test_fetch_takes_the_newest_backup_across_listing_pages(self):
        for hour in (4, 6, 5, 7, 3):
            self.back_up_at(datetime(2026, 11, 9, hour, 5, 0, tzinfo=timezone.utc))
        FakeS3.objects["goldbook/notes.txt"] = b"not a backup"

        self.assertEqual(self.run_command("list").split(), [
            f"goldbook/goldbook-20261109T0{hour}0500Z.sqlite.zst.age" for hour in (3, 4, 5, 6, 7)])
        fetched = json.loads(self.run_command("fetch", str(self.root / "newest.age")))
        self.assertEqual(fetched["fetched"], "goldbook/goldbook-20261109T070500Z.sqlite.zst.age")

    def test_open_refuses_to_overwrite_a_file(self):
        self.back_up_at(NOW)
        sealed = self.root / "fetched.age"
        self.run_command("fetch", str(sealed))
        live = self.root / "data/goldbook.sqlite"
        with self.assertRaisesRegex(SystemExit, "already exists"):
            self.run_command("open", "--identity", str(self.identity), str(sealed), str(live))

    def test_a_bad_age_key_fails_with_ages_message_and_uploads_nothing(self):
        self.config.write_text(self.config.read_text().replace("AGE_RECIPIENT=age1", "AGE_RECIPIENT=age9"))
        with self.assertRaisesRegex(SystemExit, "^age failed: .*recipient"):
            self.run_command("backup")
        self.assertEqual(FakeS3.objects, {})

    def test_a_missing_setting_is_named(self):
        self.config.write_text("S3_ENDPOINT=https://s3.gra.io.cloud.ovh.net\nS3_REGION=gra\n")
        with self.assertRaisesRegex(SystemExit, "missing S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY, AGE_RECIPIENT"):
            self.run_command("backup")


if __name__ == "__main__":
    unittest.main()
