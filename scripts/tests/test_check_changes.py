"""check-changes.py requires a change file for product changes unless the PR is labelled."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MISSING = ("This pull request changes addon/Goldbook/Core.lua but adds no change file. "
           "Add changes/<section>-<slug>.md as changes/README.md describes, "
           "or the no-changes label if no player or user would notice.\n")


class CheckChangesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key != "GITHUB_ACTIONS"}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid")
        for path in ("scripts/check-changes.py", "scripts/prepare-release.py", "changes/README.md"):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\n")
        self.write("docs/notes.md", "Notes.\n")
        self.write("changes/app-sync.md", "- Sync every hour.\n")
        self.git("init", "-q", "-b", "main")
        self.base = self.commit("Base")
        self.git("checkout", "-q", "-b", "feature")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, labels="[]"):
        self.commit("Change")
        result = subprocess.run([sys.executable, self.root / "scripts/check-changes.py"], cwd=self.root,
                                env=dict(self.env, BASE_SHA=self.base, LABELS=labels), capture_output=True, text=True)
        return result.returncode, result.stdout, result.stderr

    def test_fails_a_product_change_without_a_change_file(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.assertEqual(self.check(), (1, "", MISSING))

    def test_passes_a_product_change_with_a_new_change_file(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/addon-x.md", "- Remember x.\n")
        self.assertEqual(self.check(), (0, "Change files are in order.\n", ""))

    def test_editing_an_existing_change_file_is_not_a_new_one(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/app-sync.md", "- Sync every hour, and show when.\n")
        self.assertEqual(self.check(), (1, "", MISSING))

    def test_the_no_changes_label_passes_anything(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.write("changes/docs-x.md", "")
        self.assertEqual(self.check('["documentation", "no-changes"]'),
                         (0, "The no-changes label is set, so no change file is needed.\n", ""))

    def test_passes_changes_outside_the_product_folders(self):
        self.write("docs/notes.md", "More notes.\n")
        self.write("scripts/other.py", "print()\n")
        self.assertEqual(self.check(), (0, "Change files are in order.\n", ""))

    def test_fails_an_unknown_section_or_an_empty_change_file(self):
        self.write("web/app.js", "app();\n")
        self.write("changes/docs-x.md", "- Reword.\n")
        self.write("changes/app-sync.md", "  \n")
        self.write("changes/website-chart.md", "- Draw the chart.\n")
        self.assertEqual(self.check(), (1, "", "changes/app-sync.md: the file is empty; write one or more Markdown bullets\n"
                                                "changes/docs-x.md: unknown section docs; use one of addon, app, website, server, build\n"))

    def test_ignores_what_main_gained_after_the_branch_left_it(self):
        self.git("checkout", "-q", "main")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.y = 2\n")
        self.base = self.commit("Main moves on")
        self.git("checkout", "-q", "feature")
        self.write("docs/notes.md", "More notes.\n")
        self.assertEqual(self.check(), (0, "Change files are in order.\n", ""))

    def test_annotates_problems_inside_github_actions(self):
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.x = 1\n")
        self.env["GITHUB_ACTIONS"] = "true"
        self.assertEqual(self.check(), (1, "::error::" + MISSING, ""))


if __name__ == "__main__":
    unittest.main()
