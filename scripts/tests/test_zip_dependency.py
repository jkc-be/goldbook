"""The dependency guard rejects vulnerable archives before the build starts."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ZipDependencyTests(unittest.TestCase):
    def check(self, versions):
        with tempfile.TemporaryDirectory() as temporary:
            lockfile = Path(temporary) / "Cargo.lock"
            lockfile.write_text('[[package]]\nname = "goldbook-desktop"\nversion = "0.0.0"\n' +
                                ''.join(f'[[package]]\nname = "zip"\nversion = "{version}"\n'
                                        for version in versions))
            return subprocess.run([sys.executable, ROOT / "scripts/check-zip-dependency.py", lockfile],
                                  capture_output=True, text=True)

    def test_rejects_the_old_updater_dependency_and_unpatched_nine_releases(self):
        for version in ("4.6.1", "9.0.0", "9.0.4", "9.0.5-rc.1"):
            with self.subTest(version=version):
                result = self.check([version])
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"Unsafe zip {version}", result.stderr)
                self.assertIn("require stable zip 9.0.5 or newer", result.stderr)

    def test_rejects_a_vulnerable_copy_alongside_a_patched_copy(self):
        result = self.check(["9.0.5", "4.6.1"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Unsafe zip 4.6.1", result.stderr)

    def test_accepts_patched_dependencies_and_removal_of_zip(self):
        for versions in (["9.0.5"], ["9.0.6"], ["10.0.0"], []):
            with self.subTest(versions=versions):
                result = self.check(versions)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("ZIP security check passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
