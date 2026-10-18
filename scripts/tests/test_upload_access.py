from contextlib import closing
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/upload-access.py"


class UploadAccessTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.database = Path(directory.name) / "goldbook.sqlite"
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript((ROOT / "server/migrations/0010_upload_tokens.sql").read_text())
            db.executescript((ROOT / "server/migrations/0011_battlenet_oauth.sql").read_text())
            db.execute("INSERT INTO upload_identities (fingerprint) VALUES (?)", ("a" * 64,))
            db.execute("INSERT INTO upload_tokens VALUES (?,?,1,NULL)", ("secret-hash-never-print", "a" * 64))
            db.execute("INSERT INTO upload_tokens VALUES (?,?,1,2)", ("revoked-hash-never-print", "a" * 64))

    def run_cli(self, *args, database=None):
        return subprocess.run([sys.executable, str(SCRIPT), "--database", str(database or self.database), *args],
                              capture_output=True, text=True)

    def test_lists_counts_without_credentials(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fingerprint\tblocked\ttokens\tactive_tokens\tplayer_hash\n" + "a" * 64 + "\tno\t2\t1\t\n")
        self.assertNotIn("secret-hash", result.stdout)
        self.assertNotIn("revoked-hash", result.stdout)
        self.assertEqual(self.run_cli("list").stdout, result.stdout)

    def test_block_and_unblock_preserve_credentials_and_support_preemptive_blocks(self):
        for fingerprint in ("a" * 64, "b" * 64):
            self.assertEqual(self.run_cli("block", fingerprint).returncode, 0)
            self.assertEqual(self.run_cli("block", fingerprint).returncode, 0)
            with closing(sqlite3.connect(self.database)) as db, db:
                self.assertIsNotNone(db.execute("SELECT blocked_at FROM upload_identities WHERE fingerprint=?", (fingerprint,)).fetchone()[0])
            self.assertIn(fingerprint + "\tyes\t" + ("2" if fingerprint == "a" * 64 else "0") + "\t0\t\n", self.run_cli("list").stdout)
            self.assertEqual(self.run_cli("unblock", fingerprint).returncode, 0)
            with closing(sqlite3.connect(self.database)) as db, db:
                self.assertIsNone(db.execute("SELECT blocked_at FROM upload_identities WHERE fingerprint=?", (fingerprint,)).fetchone()[0])
        with closing(sqlite3.connect(self.database)) as db, db:
            self.assertEqual(db.execute("SELECT count(*) FROM upload_tokens").fetchone()[0], 2)

    def test_unknown_unblock_fails(self):
        result = self.run_cli("unblock", "f" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn("fingerprint is unknown", result.stderr)

    def test_player_block_covers_all_linked_fingerprints(self):
        player = "c" * 64
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("INSERT INTO battlenet_identities (identity_hash) VALUES (?)", (player,))
            db.execute("UPDATE upload_identities SET battlenet_identity=?", (player,))
            db.execute("INSERT INTO upload_identities (fingerprint,battlenet_identity) VALUES (?,?)", ("b" * 64, player))
            db.execute("INSERT INTO upload_tokens VALUES (?,?,1,NULL)", ("second-secret", "b" * 64))
        self.assertEqual(self.run_cli("--identity-type", "battlenet", "list").stdout,
                         "identity_hash\tblocked\ttokens\tactive_tokens\n" + player + "\tno\t3\t2\n")
        for _ in range(2):
            result = self.run_cli("--identity-type", "battlenet", "block", player)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(player + "\tyes\t3\t0\n", self.run_cli("--identity-type", "battlenet", "list").stdout)
        fingerprints = self.run_cli("list").stdout
        self.assertIn("a" * 64 + "\tyes\t2\t0\t" + player + "\n", fingerprints)
        self.assertIn("b" * 64 + "\tyes\t1\t0\t" + player + "\n", fingerprints)
        result = self.run_cli("--identity-type", "battlenet", "unblock", player)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(player + "\tno\t3\t2\n", self.run_cli("--identity-type", "battlenet", "list").stdout)

    def test_missing_database_and_invalid_fingerprints_do_not_create_files(self):
        missing = self.database.with_name("missing.sqlite")
        result = self.run_cli("list", database=missing)
        self.assertEqual(result.returncode, 2)
        self.assertIn("existing file", result.stderr)
        self.assertFalse(missing.exists())
        for value in ("a" * 63, "a" * 65, "A" * 64, "z" * 64, "../../path"):
            result = self.run_cli("block", value)
            self.assertEqual(result.returncode, 2)
            self.assertIn("64 lowercase hexadecimal", result.stderr)


if __name__ == "__main__":
    unittest.main()
