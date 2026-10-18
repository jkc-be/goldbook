"""check-changes.py enforces the change file, version, changelog and release rules."""
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
RELEASE_FIX = ("To prepare a release, run make prepare-release VERSION=x.y.z on a branch from main "
               "and add the release label.")
MISSING = ("Change file rule: this pull request changes addon/Goldbook/Core.lua but adds no change file. "
           "Add changes/<section>-<slug>.md as changes/README.md describes, "
           "or the no-changes label if no player or user would notice.\n")
PASSED = "Change files are in order. The version and the CHANGELOG.md sections are unchanged.\n"
NO_CHANGES = ("The no-changes label is set, so no change file is needed. "
              "The version and the CHANGELOG.md sections are unchanged.\n")
CHANGELOG = """# Changelog

The changes in each Goldbook version, newest first.

## 1.2.9 - 2026-10-17

- An older entry.
"""


class CheckChangesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        # set-version.py ends with `cargo metadata --offline`, which needs every
        # crate of the real workspace downloaded; this copy holds only manifests.
        bin = Path(temporary.name) / "bin"
        bin.mkdir()
        (bin / "cargo").write_text("#!/bin/sh\nexit 0\n")
        (bin / "cargo").chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key != "GITHUB_ACTIONS"}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
                        PATH=f"{bin}{os.pathsep}{os.environ['PATH']}")
        for path in VERSIONED + ["scripts/check-changes.py", "scripts/prepare-release.py",
                                 "scripts/set-version.py", "changes/README.md"]:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        self.script("set-version.py", "1.2.9")
        self.write("CHANGELOG.md", CHANGELOG)
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\n")
        self.write("docs/notes.md", "Notes.\n")
        self.write("changes/app-sync.md", "- Sync every hour.\n")
        self.git("init", "-q", "-b", "main")
        self.base = self.commit("Base")
        self.git("checkout", "-q", "-b", "feature")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def script(self, name, *args):
        result = subprocess.run([sys.executable, self.root / "scripts" / name, *args], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def edit(self, path, old, new):
        text = (self.root / path).read_text()
        self.assertIn(old, text)
        self.write(path, text.replace(old, new, 1))

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, labels="[]"):
        self.commit("Change")
        result = subprocess.run([sys.executable, self.root / "scripts/check-changes.py"], cwd=self.root,
                                env=dict(self.env, BASE_SHA=self.base, LABELS=labels), capture_output=True, text=True)
        return result.returncode, result.stdout, result.stderr

    def prepare_release(self, version):
        self.script("prepare-release.py", version)

    # Change file rule.

    def test_fails_a_product_change_without_a_change_file(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.assertEqual(self.check(), (1, "", MISSING))

    def test_passes_a_feature_with_a_new_change_file(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/addon-x.md", "- Remember x.\n")
        self.assertEqual(self.check(), (0, PASSED, ""))

    def test_editing_an_existing_change_file_is_not_a_new_one(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/app-sync.md", "- Sync every hour, and show when.\n")
        self.assertEqual(self.check(), (1, "", MISSING))

    def test_the_no_changes_label_waives_the_change_file_rule(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/docs-x.md", "")
        self.assertEqual(self.check('["documentation", "no-changes"]'), (0, NO_CHANGES, ""))

    def test_passes_changes_outside_the_product_folders(self):
        self.write("docs/notes.md", "More notes.\n")
        self.write("scripts/other.py", "print()\n")
        self.assertEqual(self.check(), (0, PASSED, ""))

    def test_fails_an_unknown_section_or_an_empty_change_file(self):
        self.write("web/app.js", "app();\n")
        self.write("changes/docs-x.md", "- Reword.\n")
        self.write("changes/app-sync.md", "  \n")
        self.write("changes/website-chart.md", "- Draw the chart.\n")
        self.assertEqual(self.check(), (1, "", "Change file rule: changes/app-sync.md: the file is empty; "
                                                "write one or more Markdown bullets\n"
                                                "Change file rule: changes/docs-x.md: unknown section docs; "
                                                "use one of addon, app, website, server, build\n"))

    def test_ignores_what_main_gained_after_the_branch_left_it(self):
        self.git("checkout", "-q", "main")
        self.prepare_release("1.2.10")
        self.base = self.commit("Release 1.2.10")
        self.git("checkout", "-q", "feature")
        self.write("docs/notes.md", "More notes.\n")
        self.assertEqual(self.check(), (0, PASSED, ""))

    def test_annotates_problems_inside_github_actions(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.env["GITHUB_ACTIONS"] = "true"
        self.assertEqual(self.check(), (1, "::error::" + MISSING, ""))

    # Version and changelog rules.

    def test_refuses_a_version_change_without_the_release_label(self):
        self.script("set-version.py", "1.2.10")
        self.assertEqual(self.check('["no-changes"]'), (1, "", (
            "Version rule: this pull request changes the version from 1.2.9 to 1.2.10, "
            "but only a release pull request changes it. "
            f"Restore the version fields from main. {RELEASE_FIX}\n")))

    def test_refuses_one_version_field_out_of_line(self):
        self.edit("web/index.html", '<span class="version">1.2.9<', '<span class="version">1.3.0<')
        self.write("changes/website-title.md", "- Show the version.\n")
        self.assertEqual(self.check(), (1, "", (
            "Version rule: The version fields disagree with 1.2.9: web/index.html has 1.3.0. "
            f"Only a release pull request changes version fields. Restore them from main. {RELEASE_FIX}\n")))

    def test_refuses_a_changelog_edit_with_only_no_changes(self):
        self.edit("CHANGELOG.md", "- An older entry.", "- An older entry, reworded.")
        self.assertEqual(self.check('["no-changes"]'), (1, "", (
            "Changelog rule: this pull request edits the version sections of CHANGELOG.md, but only a release "
            "pull request does. Describe the change in a file under changes/ instead, as changes/README.md "
            f"describes. {RELEASE_FIX}\n")))

    def test_passes_a_reworded_changelog_introduction(self):
        self.edit("CHANGELOG.md", "newest first.", "newest first, one section per version.")
        self.assertEqual(self.check('["no-changes"]'), (0, NO_CHANGES, ""))

    def test_refuses_a_section_in_the_changelog_introduction(self):
        self.edit("CHANGELOG.md", "newest first.\n", "newest first.\n\n## Unreleased\n\n- Sync every hour.\n")
        self.assertEqual(self.check('["no-changes"]'), (1, "", (
            "Changelog rule: the introduction of CHANGELOG.md holds no sections. Describe unreleased changes "
            "in files under changes/, as changes/README.md describes.\n")))

    def test_passes_a_dependency_edit_to_package_json(self):
        self.edit("package.json", '"devDependencies": {', '"devDependencies": {\n    "left-pad": "1.3.0",')
        self.assertEqual(self.check('["no-changes"]'), (0, NO_CHANGES, ""))

    # Release rule.

    def test_passes_a_release_pull_request(self):
        self.prepare_release("1.2.10")
        self.edit("CHANGELOG.md", "- Sync every hour.", "- Sync every hour instead of every six.")
        self.assertEqual(self.check('["release"]'), (0, (
            "This release pull request sets 1.2.10, adds its changelog section "
            "and collects every change file.\n"), ""))

    def test_refuses_a_release_that_also_changes_the_addon(self):
        self.prepare_release("1.2.10")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.edit("package.json", '"devDependencies": {', '"devDependencies": {\n    "left-pad": "1.3.0",')
        self.assertEqual(self.check('["release", "no-changes"]'), (1, "", (
            "Release rule: a release pull request only edits CHANGELOG.md and the version fields "
            "and deletes change files, but this one also changes addon/Goldbook/Core.lua, package.json. "
            "Move those changes to their own pull request, and start the release from main "
            "with make prepare-release VERSION=x.y.z.\n")))

    def test_refuses_a_release_without_a_version_bump(self):
        self.edit("CHANGELOG.md", "- An older entry.", "- An older entry.\n- Sync every hour.")
        (self.root / "changes/app-sync.md").unlink()
        self.assertEqual(self.check('["release"]'), (1, "", (
            "Release rule: a release pull request raises the version above 1.2.9, but this one sets 1.2.9. "
            "Run make prepare-release VERSION=x.y.z with a higher version.\n")))

    def test_refuses_a_release_that_keeps_a_change_file(self):
        self.prepare_release("1.2.10")
        self.git("checkout", self.base, "--", "changes/app-sync.md")
        self.assertEqual(self.check('["release"]'), (1, "", (
            "Release rule: a release collects every change file, but this pull request keeps "
            "changes/app-sync.md. Add its bullets to the new CHANGELOG.md section and delete it, "
            "as make prepare-release does.\n")))

    def test_refuses_a_release_without_its_changelog_section(self):
        self.prepare_release("1.2.10")
        self.git("checkout", self.base, "--", "CHANGELOG.md")
        self.assertEqual(self.check('["release"]'), (1, "", (
            "Release rule: CHANGELOG.md has no \"## 1.2.10 - \" section. "
            "Add it above the newest release, as make prepare-release does.\n")))


if __name__ == "__main__":
    unittest.main()
