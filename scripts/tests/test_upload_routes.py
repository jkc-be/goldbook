"""Upload routes must bypass the proxy's small public-request body limit."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UploadRoutes(unittest.TestCase):
    def test_upload_paths_have_the_large_body_allowance_on_both_hosts(self):
        for name, router, prefix in (
            ('compose.traefik.yaml', 'goldbook-upload', ''),
            ('compose.path.yaml', 'goldbook-path-upload', '/goldbook'),
        ):
            with self.subTest(config=name):
                text = (ROOT / 'server' / name).read_text()
                rule = next(line for line in text.splitlines()
                            if f'routers.{router}.rule:' in line)
                for path in ('scans', 'account', 'sellers', 'sellers/batch'):
                    self.assertIn(f'Path(`{prefix}/api/{path}`)', rule)
                middleware = next(line for line in text.splitlines()
                                  if f'routers.{router}.middlewares:' in line)
                self.assertIn('goldbook-upload-buffer', middleware)
        self.assertIn('maxrequestbodybytes: "20971520"',
                      (ROOT / 'server/compose.traefik.yaml').read_text())
