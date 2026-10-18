"""The website's page and style sheets agree with its routes and the addon."""
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WebPageTests(unittest.TestCase):
    def test_no_element_is_named_like_a_route(self):
        # The browser scrolls to the element whose id is the address's
        # fragment, so a route sharing an element's id opens scrolled down.
        routes = set(re.findall(r'route: "([a-z]+)"', (ROOT / "web/app.js").read_text()))
        self.assertIn("prices", routes)
        ids = set(re.findall(r'\bid="([^"]+)"', (ROOT / "web/index.html").read_text()))
        self.assertEqual(routes & ids, set())

    def test_style_sheets_have_the_addons_palettes(self):
        result = subprocess.run([sys.executable, "scripts/web-palette.py", "--check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
