"""Regression checks for shell settings leaking into disposable test servers."""
from pathlib import Path
import os
import runpy
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
local_environment = runpy.run_path(str(ROOT / "scripts/verify-migration.py"))["local_environment"]


class LocalEnvironmentTests(unittest.TestCase):
    def test_production_settings_are_replaced_or_removed(self):
        inherited = {
            "PATH": "/tools/bin", "DATABASE": "/production/database.sqlite",
            "HOST": "0.0.0.0", "PORT": "443", "UPLOAD_TOKEN": "production-token",
            "SELF_REGISTRATION": "true", "TRUSTED_PROXY": "0.0.0.0/0",
            "WEB_DIR": "/production/web", "BNET_CLIENT_ID": "production-id",
            "BNET_CLIENT_SECRET": "production-secret",
            "GOLDBOOK_PUBLIC_URL": "https://production.invalid",
            "GOLDBOOK_API": "https://production.invalid", "GOLDBOOK_TOKEN": "secret",
        }
        with patch.dict(os.environ, inherited, clear=True):
            environment = local_environment(Path("/temporary/test"), 12345)
            self.assertEqual(dict(os.environ), inherited)
        self.assertEqual(environment, {
            "PATH": "/tools/bin", "DATABASE": "/temporary/test/goldbook.sqlite",
            "HOST": "127.0.0.1", "PORT": "12345", "UPLOAD_TOKEN": "dev-token,friend-token",
            "SELF_REGISTRATION": "false",
        })


if __name__ == "__main__":
    unittest.main()
