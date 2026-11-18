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

    def test_refuses_a_committed_beta_stamp_with_either_label(self):
        refusals = {
            '["release"]': (
                "Release rule: a release pull request only edits CHANGELOG.md and the version fields and deletes "
                "change files, but this one also changes Cargo.lock, addon/Goldbook/Goldbook.toc, "
                "crates/goldbook-core/Cargo.toml, crates/goldbook-server/Cargo.toml, crates/goldbook-sync/Cargo.toml, "
                "desktop/src-tauri/Cargo.toml, desktop/src-tauri/tauri.conf.json, package-lock.json, package.json, "
                "web/index.html. Move those changes to their own pull request, and start the release from main "
                "with make prepare-release VERSION=x.y.z.\n"
                "Release rule: package.json: expected 1 version field(s), found 0. Set every field with "
                "make prepare-release VERSION=x.y.z, or python3 scripts/set-version.py x.y.z.\n"
                "Release rule: a release collects every change file, but this pull request keeps "
                "changes/app-sync.md. Add its bullets to the new CHANGELOG.md section and delete it, "
                "as make prepare-release does.\n"),
            '["no-changes"]': (
                "Version rule: this pull request changes the version from 1.2.9 to None, but only a release pull "
                f"request changes it. Restore the version fields from main. {RELEASE_FIX}\n"
                "Version rule: package.json: expected 1 version field(s), found 0. Only a release pull request "
                f"changes version fields. Restore them from main. {RELEASE_FIX}\n"),
        }
        for labels, refusal in refusals.items():
            with self.subTest(labels=labels):
                self.git("reset", "-q", "--hard", self.base)
                self.script("set-version.py", "--stamp", "1.2.10-beta.1")
                self.assertEqual(self.check(labels), (1, "", refusal))

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

    # Pick rule, and the release rule for a picked release.

    def start_picks(self):
        """Release 1.2.10 on main, then commit a with an addon change and b with
        a website change, each with its change file. Leaves release/1.2.11 checked
        out at the release with a picked."""
        self.git("checkout", "-q", "main")
        self.prepare_release("1.2.10")
        tag = self.commit("release 1.2.10")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.a = 1\n")
        self.write("changes/addon-a.md", "- Remember a.\n")
        self.a = self.commit("Add a (#1)")
        self.write("web/app.js", "app();\n")
        self.write("changes/website-b.md", "- Draw b.\n")
        self.b = self.commit("Add b (#2)")
        self.git("checkout", "-q", "-b", "release/1.2.11", tag)
        self.git("cherry-pick", "-x", self.a)
        self.pick = self.git("rev-parse", "HEAD")

    def merge(self, release, beta=False, adjust=None):
        """Checks out the commit make pick-release opens: main with the release
        commit applied, or main unchanged for a beta, merging the release."""
        self.git("checkout", "-q", "--detach", "main")
        if not beta:
            self.git("cherry-pick", "-n", release)
        if adjust:
            adjust()
        tree = self.git("write-tree")
        merged = self.git("commit-tree", tree, "-p", release, "-p", "main", "-m", "Merge")
        self.git("checkout", "-q", "--detach", merged)

    def run_check(self, labels):
        result = subprocess.run([sys.executable, self.root / "scripts/check-changes.py"], cwd=self.root,
                                env=dict(self.env, BASE_SHA=self.git("rev-parse", "main"), LABELS=labels),
                                capture_output=True, text=True)
        return result.returncode, result.stdout, result.stderr

    def release_commit(self, *edits):
        self.prepare_release("1.2.11")
        for path, text in edits:
            self.write(path, text)
        return self.commit("release 1.2.11")

    def test_passes_a_picked_release_that_keeps_what_it_does_not_pick(self):
        self.start_picks()
        self.merge(self.release_commit())
        self.assertEqual(self.run_check('["release"]'), (0, (
            "This release pull request sets 1.2.11, adds its changelog section "
            "and collects the change files of the commits it picks from main.\n"), ""))
        self.assertTrue((self.root / "changes/website-b.md").exists())
        self.assertFalse((self.root / "changes/addon-a.md").exists())

    def test_refuses_a_picked_release_that_keeps_a_picked_change_file(self):
        self.start_picks()
        self.merge(self.release_commit(), adjust=lambda: self.git("checkout", "main", "--", "changes/addon-a.md"))
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            "Release rule: the release picks the pull requests of changes/addon-a.md, but this pull request "
            "keeps those change files. Delete them, as make pick-release does.\n")))

    def test_refuses_a_picked_release_that_deletes_a_change_file_it_does_not_pick(self):
        self.start_picks()
        self.merge(self.release_commit(), adjust=lambda: self.git("rm", "-q", "changes/website-b.md"))
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            "Release rule: this pull request deletes changes/website-b.md, but the release does not pick "
            "their pull requests. Restore them from main.\n")))

    def test_refuses_a_pick_that_changes_more_than_its_commit_of_main(self):
        self.start_picks()
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.a = 2\n")
        self.git("commit", "-q", "--amend", "--no-edit", "-a")
        pick = self.git("rev-parse", "HEAD")
        self.merge(self.release_commit())
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            f"Pick rule: {pick[:12]} does not change exactly what {self.a[:12]} changes, which it picks. "
            "Start the release again with make pick-release.\n")))

    def test_refuses_a_release_commit_that_changes_code(self):
        self.start_picks()
        release = self.release_commit(("addon/Goldbook/Core.lua", "local _, ns = ...\nns.a = 3\n"))
        self.merge(release)
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            f"Pick rule: the release commit {release[:12]} only edits CHANGELOG.md and the version fields "
            "and deletes change files, but it also changes addon/Goldbook/Core.lua. "
            "Start the release again with make pick-release.\n"
            "Release rule: a release pull request only edits CHANGELOG.md and the version fields "
            "and deletes change files, but this one also changes addon/Goldbook/Core.lua. "
            "Move those changes to their own pull request, and start the release from main "
            "with make prepare-release VERSION=x.y.z.\n")))

    def test_refuses_a_pick_of_a_commit_that_is_not_on_main(self):
        self.start_picks()
        self.git("checkout", "-q", "-b", "elsewhere", self.a)
        self.write("docs/notes.md", "Other notes.\n")
        other = self.commit("Not on main")
        self.git("checkout", "-q", "release/1.2.11")
        self.git("cherry-pick", "-x", other)
        pick = self.git("rev-parse", "HEAD")
        self.merge(self.release_commit())
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            f"Pick rule: {pick[:12]} picks {other[:12]}, which is not a commit of main. "
            "Start the release again with make pick-release.\n")))

    def test_passes_a_picked_beta(self):
        self.start_picks()
        self.merge(self.pick, beta=True)
        self.assertEqual(self.run_check('["no-changes"]'), (0, (
            "This pull request merges a beta picked from the last release and changes nothing on main.\n"), ""))

    def test_refuses_a_picked_beta_with_a_commit_that_is_not_a_pick(self):
        self.start_picks()
        self.write("docs/notes.md", "Beta notes.\n")
        extra = self.commit("Edit notes")
        self.merge(extra, beta=True)
        self.assertEqual(self.run_check('["no-changes"]'), (1, "", (
            f"Pick rule: a picked beta holds only cherry-picks, but {extra[:12]} is not one. "
            "Start the release again with make pick-release.\n")))

    def test_refuses_a_picked_beta_merge_that_changes_main(self):
        self.start_picks()
        self.merge(self.pick, beta=True, adjust=lambda: (self.write("docs/notes.md", "Merged notes.\n"),
                                                          self.git("add", "docs/notes.md")))
        self.assertEqual(self.run_check('["no-changes"]'), (1, "", (
            "Pick rule: merging a picked beta changes nothing on main, but this pull request changes "
            "docs/notes.md. Start the release again with make pick-release.\n")))

    def test_refuses_a_pick_that_puts_other_bytes_in_a_binary_file(self):
        self.start_picks()
        self.git("checkout", "-q", "main")
        (self.root / "desktop/icon.png").write_bytes(b"\x89PNG\x00one")
        self.write("changes/app-icon.md", "- Draw the icon.\n")
        icon = self.commit("Add the icon (#4)")
        self.git("checkout", "-q", "release/1.2.11")
        self.git("cherry-pick", "-x", icon)
        (self.root / "desktop/icon.png").write_bytes(b"\x89PNG\x00two")
        self.git("commit", "-q", "--amend", "--no-edit", "-a")
        pick = self.git("rev-parse", "HEAD")
        self.merge(self.release_commit())
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            f"Pick rule: {pick[:12]} does not change exactly what {icon[:12]} changes, which it picks. "
            "Start the release again with make pick-release.\n")))

    def test_refuses_a_release_label_merge_whose_release_side_picks_nothing(self):
        self.start_picks()
        self.git("reset", "-q", "--hard", "HEAD^")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.hidden = true\n")
        self.write("changes/addon-hidden.md", "- Hide.\n")
        self.commit("Not on main")
        release = self.release_commit()
        self.merge(release, adjust=lambda: self.git("rm", "-q", "--cached", "--ignore-unmatch",
                                                    "changes/addon-hidden.md"))
        code, stdout, stderr = self.run_check('["release"]')
        self.assertEqual((code, stdout), (1, ""))
        self.assertTrue(stderr.startswith(
            f"Pick rule: this pull request merges {release[:12]}, but none of its commits since the last "
            "release is a cherry-pick of main."), stderr)

    def test_refuses_a_merge_that_changes_nothing_and_picks_nothing(self):
        self.start_picks()
        self.git("reset", "-q", "--hard", "HEAD^")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.hidden = true\n")
        hidden = self.commit("Not on main")
        self.merge(hidden, beta=True)
        self.assertEqual(self.run_check('["no-changes"]')[0], 1)

    def test_refuses_a_picked_release_whose_change_file_main_edited_later(self):
        self.start_picks()
        self.git("checkout", "-q", "main")
        self.write("changes/addon-a.md", "- Remember a.\n- And remember it twice.\n")
        self.commit("Remember a twice (#4)")
        self.git("checkout", "-q", "release/1.2.11")
        release = self.release_commit()
        self.git("checkout", "-q", "--detach", "main")
        subprocess.run(["git", "cherry-pick", "-n", release], cwd=self.root, env=self.env, capture_output=True)
        self.git("rm", "-q", "-f", "changes/addon-a.md")
        merged = self.git("commit-tree", self.git("write-tree"), "-p", release, "-p", "main", "-m", "Merge")
        self.git("checkout", "-q", "--detach", merged)
        self.assertEqual(self.run_check('["release"]'), (1, "", (
            "Release rule: main's changes/addon-a.md differs from the one the release picks, because a later "
            "pull request edited it. Pick that pull request too. Start the release again with "
            "make pick-release.\n")))

    def test_a_feature_branch_that_merged_main_is_not_a_picked_release(self):
        self.write("docs/notes.md", "Feature notes.\n")
        self.commit("Feature")
        self.git("checkout", "-q", "main")
        self.write("docs/other.md", "Main notes.\n")
        self.commit("Main")
        self.git("checkout", "-q", "feature")
        self.git("merge", "-q", "--no-edit", "main")
        self.assertEqual(self.run_check("[]"), (0, PASSED, ""))


if __name__ == "__main__":
    unittest.main()
