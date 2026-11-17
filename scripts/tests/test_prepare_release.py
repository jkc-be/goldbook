"""prepare-release.py turns change files into a changelog section and sets the version."""
import datetime
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERSIONED = ["package.json", "package-lock.json", "desktop/src-tauri/tauri.conf.json", "addon/Goldbook/Goldbook.toc",
             "web/index.html", "Cargo.lock", "crates/goldbook-core/Cargo.toml", "crates/goldbook-server/Cargo.toml",
             "crates/goldbook-sync/Cargo.toml", "desktop/src-tauri/Cargo.toml"]
SET_VERSION_USAGE = ("usage: scripts/set-version.py <major.minor.patch>, such as 0.1.5, "
                     "--stamp <major.minor.patch[-beta.N]>, such as 0.2.0-beta.1, or --check\n")
CHANGELOG = """# Changelog

The changes in each Goldbook version, newest first.

## 1.2.9 - 2026-10-17

- An older entry.
"""


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        for path in VERSIONED + ["scripts/set-version.py", "scripts/prepare-release.py", "changes/README.md"]:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        (self.root / "CHANGELOG.md").write_text(CHANGELOG)
        # set-version.py ends with `cargo metadata --offline`, which needs every
        # crate of the real workspace downloaded; this copy holds only manifests.
        bin = Path(temporary.name) / "bin"
        bin.mkdir()
        (bin / "cargo").write_text("#!/bin/sh\nexit 0\n")
        (bin / "cargo").chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin}{os.pathsep}{os.environ['PATH']}")
        self.assertEqual(self.run_script("set-version.py", "1.2.9").returncode, 0)

    def run_script(self, script, *args):
        return subprocess.run([sys.executable, self.root / "scripts" / script, *args],
                              env=self.env, capture_output=True, text=True)

    def add(self, name, text):
        (self.root / "changes" / name).write_text(text)

    def files(self):
        return {path.relative_to(self.root).as_posix(): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def assert_refused(self, version, error):
        before = self.files()
        result = self.run_script("prepare-release.py", version)
        self.assertEqual((result.returncode, result.stderr), (1, error + "\n"))
        self.assertEqual(self.files(), before)

    def test_groups_change_files_by_section_in_release_order_and_by_name_within_one(self):
        self.add("server-uploads.md", "- Accept larger uploads.\n")
        self.add("build-ci.md", "- Pin the runners.\n")
        self.add("addon-zeta.md", "- Zeta comes second.\n")
        self.add("app-sync.md", "- Sync every hour instead of every six,\n  and say when the last one ran.\n")
        self.add("addon-alpha.md", "\n- Alpha comes first.\n- With a second bullet.\n\n")
        self.add("website-chart.md", "- Draw the chart in the dark theme.\n")

        result = self.run_script("prepare-release.py", "1.2.10")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), f"""# Changelog

The changes in each Goldbook version, newest first.

## 1.2.10 - {datetime.date.today().isoformat()}

### Addon

- Alpha comes first.
- With a second bullet.
- Zeta comes second.

### Desktop app

- Sync every hour instead of every six,
  and say when the last one ran.

### Website

- Draw the chart in the dark theme.

### Server

- Accept larger uploads.

### Build

- Pin the runners.

## 1.2.9 - 2026-10-17

- An older entry.
""")
        self.assertEqual(sorted(path.name for path in (self.root / "changes").iterdir()), ["README.md"])
        self.assertEqual(self.run_script("set-version.py", "--check").stdout, "1.2.10\n")

    def test_refuses_without_change_files(self):
        self.assert_refused("1.2.10", "changes/ holds no change files; there is nothing to release")

    def test_refuses_a_version_that_is_not_higher(self):
        self.add("addon-alpha.md", "- Alpha.\n")
        self.assert_refused("1.2.8", "1.2.8 is not higher than the current version 1.2.9")
        self.assert_refused("1.2.9", "1.2.9 is not higher than the current version 1.2.9")

    def test_refuses_a_beta_version(self):
        self.add("addon-alpha.md", "- Alpha.\n")
        self.assert_refused("1.2.10-beta.1", "usage: scripts/prepare-release.py <major.minor.patch>, such as 0.2.5")

    def test_refuses_when_the_version_fields_disagree(self):
        self.add("addon-alpha.md", "- Alpha.\n")
        index = self.root / "web/index.html"
        index.write_text(index.read_text().replace('<span class="version">1.2.9<', '<span class="version">1.2.8<'))
        self.assert_refused("1.2.10", "The version fields disagree with 1.2.9: web/index.html has 1.2.8")

    def test_refuses_an_unknown_section_or_an_empty_file(self):
        self.add("addon-alpha.md", "- Alpha.\n")
        self.add("docs-readme.md", "- Reword the readme.\n")
        self.add("server-blank.md", "\n")
        self.assert_refused("1.2.10", "changes/docs-readme.md: unknown section docs; use one of addon, app, website, server, build\n"
                                      "changes/server-blank.md: the file is empty; write one or more Markdown bullets")


class SetVersionStampTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        for path in VERSIONED + ["scripts/set-version.py"]:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        bin = Path(temporary.name) / "bin"
        bin.mkdir()
        cargo = bin / "cargo"
        cargo.write_text("#!/bin/sh\nexit 0\n")
        cargo.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin}{os.pathsep}{os.environ['PATH']}")
        self.assertEqual(self.set_version("1.2.9").returncode, 0)
        # From here cargo fails, so a stamp that ran it would fail too.
        cargo.write_text("#!/bin/sh\nexit 1\n")
        self.release = self.files()

    def set_version(self, *args):
        return subprocess.run([sys.executable, self.root / "scripts/set-version.py", *args],
                              env=self.env, capture_output=True, text=True)

    def files(self):
        return {path.relative_to(self.root).as_posix(): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_stamps_a_beta_in_every_version_field_without_running_cargo(self):
        result = self.set_version("--stamp", "1.2.10-beta.1")
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, "Stamped the client and addon version 1.2.10-beta.1.\n", ""))
        stamped = self.files()
        self.assertEqual({path: stamped[path].count(b"1.2.10-beta.1") for path in VERSIONED}, {
            "package.json": 1, "package-lock.json": 2, "desktop/src-tauri/tauri.conf.json": 1,
            "addon/Goldbook/Goldbook.toc": 1, "web/index.html": 1, "Cargo.lock": 4,
            "crates/goldbook-core/Cargo.toml": 1, "crates/goldbook-server/Cargo.toml": 1,
            "crates/goldbook-sync/Cargo.toml": 1, "desktop/src-tauri/Cargo.toml": 1})
        self.assertEqual({path: content.replace(b"1.2.10-beta.1", b"1.2.9") for path, content in stamped.items()},
                         self.release)

    def test_stamps_a_release(self):
        self.assertEqual(self.set_version("--stamp", "1.2.10").returncode, 0)
        result = self.set_version("--check")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "1.2.10\n", ""))

    def test_refuses_any_other_version_without_changing_a_file(self):
        for version in ("1.2.10-beta", "1.2.10-beta.0", "1.2.10-beta.01", "1.2.10-rc.1", "1.2.10-beta.1.2", "1.2"):
            with self.subTest(version=version):
                result = self.set_version("--stamp", version)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (1, "", SET_VERSION_USAGE))
                self.assertEqual(self.files(), self.release)

    def test_the_committed_form_still_refuses_a_beta(self):
        result = self.set_version("1.2.10-beta.1")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (1, "", SET_VERSION_USAGE))
        self.assertEqual(self.files(), self.release)

    def test_check_refuses_a_stamped_tree(self):
        self.assertEqual(self.set_version("--stamp", "1.2.10-beta.1").returncode, 0)
        result = self.set_version("--check")
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, "", "package.json: expected 1 version field(s), found 0\n"))


class SetVersionCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for path in VERSIONED + ["scripts/set-version.py"]:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)

    def check(self):
        return subprocess.run([sys.executable, self.root / "scripts/set-version.py", "--check"],
                              capture_output=True, text=True)

    def test_prints_the_version_when_every_field_matches(self):
        version = (self.root / "desktop/src-tauri/tauri.conf.json").read_text().split('"version": "')[1].split('"')[0]
        result = self.check()
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, version + "\n", ""))

    def test_names_the_file_whose_field_differs(self):
        version = self.check().stdout.strip()
        lock = self.root / "Cargo.lock"
        field = f'name = "goldbook-sync"\nversion = "{version}"'
        self.assertIn(field, lock.read_text())
        lock.write_text(lock.read_text().replace(field, 'name = "goldbook-sync"\nversion = "0.0.1"'))
        result = self.check()
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, "", f"The version fields disagree with {version}: Cargo.lock has 0.0.1\n"))


if __name__ == "__main__":
    unittest.main()
