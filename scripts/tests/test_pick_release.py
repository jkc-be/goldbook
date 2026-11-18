"""pick-release.py picks pull requests onto the last release and opens the pull request that merges it."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pick_release", ROOT / "scripts/pick-release.py")
PICK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PICK)
VERSIONED = ["package.json", "package-lock.json", "desktop/src-tauri/tauri.conf.json", "addon/Goldbook/Goldbook.toc",
             "web/index.html", "Cargo.lock", "crates/goldbook-core/Cargo.toml", "crates/goldbook-server/Cargo.toml",
             "crates/goldbook-sync/Cargo.toml", "desktop/src-tauri/Cargo.toml"]
SCRIPTS = ["scripts/set-version.py", "scripts/prepare-release.py", "scripts/check-changes.py", "changes/README.md"]
CHECK = "on:\n  push:\n    branches: [main, 'release/**']\n"
CHANGELOG = "# Changelog\n\nThe changes in each Goldbook version, newest first.\n\n## 1.2.9 - 2026-10-17\n\n- Older.\n"


class GitHub:
    """Answers the gh commands pick-release.py runs."""

    def __init__(self):
        self.descriptions = {}
        self.pulls = []
        self.edits = []

    def __call__(self, *args):
        if args[:2] == ("pr", "list") and "merged" in args:
            return json.dumps([{"number": n, "body": body} for n, body in self.descriptions.items()])
        if args[:2] == ("pr", "list"):
            head = args[args.index("--head") + 1]
            return json.dumps([{"url": pull["url"]} for pull in self.pulls if pull["head"] == head])
        if args[:2] == ("pr", "create"):
            options = dict(zip(args[2::2], args[3::2]))
            url = f"https://github.com/jkc-be/goldbook/pull/{100 + len(self.pulls)}"
            self.pulls.append({"url": url, "head": options["--head"], "title": options["--title"],
                               "label": options["--label"], "body": options["--body"]})
            return url + "\n"
        if args[:2] == ("pr", "edit"):
            self.edits.append((args[2], args[args.index("--body") + 1]))
            return ""
        raise AssertionError(f"unexpected gh {args}")


class PickReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.top = Path(temporary.name)
        # set-version.py ends with `cargo metadata --offline`, which needs every
        # crate of the real workspace downloaded; this copy holds only manifests.
        bin = self.top / "bin"
        bin.mkdir()
        (bin / "cargo").write_text("#!/bin/sh\nexit 0\n")
        (bin / "cargo").chmod(0o755)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                           GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                           GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
                           PATH=f"{bin}{os.pathsep}{os.environ['PATH']}")
        patcher = mock.patch.dict(os.environ, environment, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.git("init", "-q", "--bare", "-b", "main", str(self.top / "origin.git"), cwd=self.top)
        self.root = self.top / "goldbook"
        self.git("clone", "-q", str(self.top / "origin.git"), str(self.root), cwd=self.top)
        self.github = GitHub()
        self.output = io.StringIO()
        self.picker = PICK.Picker(self.root, gh=self.github, say=lambda text: print(text, file=self.output))

    # The repository.

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.root, check=True, capture_output=True,
                              text=True).stdout.strip()

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def script(self, *args, cwd=None):
        result = subprocess.run([sys.executable, *args], cwd=cwd or self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout

    def release_on_main(self, check=CHECK):
        """main holds release 1.2.10, tagged, then pull requests #1 (addon), #2
        (website) and #3 (addon again, after #1), each with a change file."""
        for path in VERSIONED + SCRIPTS:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        self.write(".github/workflows/check.yml", check)
        self.write("CHANGELOG.md", CHANGELOG)
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\n")
        self.write("changes/app-old.md", "- Released before.\n")
        self.script("scripts/set-version.py", "1.2.9")
        self.commit("Start")
        self.script("scripts/prepare-release.py", "1.2.10")
        self.release = self.commit("release 1.2.10 (#9)")
        self.git("tag", "v1.2.10")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.a = 1\n")
        self.write("changes/addon-a.md", "- Remember a.\n")
        self.a = self.commit("feat(addon): remember a (#1)")
        self.write("web/app.js", "app();\n")
        self.write("changes/website-b.md", "- Draw b.\n")
        self.b = self.commit("feat(web): draw b (#2)")
        self.write("addon/Goldbook/Core.lua", "local _, ns = ...\nns.a = 1\nns.c = ns.a + 1\n")
        self.write("changes/addon-c.md", "- Count c.\n")
        self.c = self.commit("feat(addon): count c (#3)")
        self.github.descriptions = {1: "Adds a.", 2: "Adds b.", 3: "Adds c.\n\nDepends on #1."}
        self.push()

    def push(self):
        self.git("push", "-q", "origin", "main", "--tags")

    def run_picker(self, command, *args):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            code = PICK.main([command, *args], picker=self.picker)
        return code, self.output.getvalue(), error.getvalue()

    def remote(self, branch):
        return self.git("rev-parse", f"refs/heads/{branch}", cwd=self.top / "origin.git")

    def run_check(self, head, labels):
        """check-changes.py on the pull request make pick-release opened, as the changes workflow runs it."""
        self.git("fetch", "-q", "origin")
        self.git("checkout", "-q", "--detach", head)
        result = subprocess.run([sys.executable, "scripts/check-changes.py"], cwd=self.root, capture_output=True,
                                text=True, env=dict(os.environ, BASE_SHA=self.git("rev-parse", "origin/main"),
                                                    LABELS=json.dumps(labels)))
        self.git("checkout", "-q", "main")
        return result.returncode, result.stdout + result.stderr

    def tree(self, commit):
        return set(self.git("ls-tree", "-r", "--name-only", commit).split())

    # list

    def test_lists_what_main_gained_since_the_last_release(self):
        self.release_on_main()
        self.assertEqual(self.run_picker("list"), (0, (
            "Not released since v1.2.10, oldest first:\n\n"
            f"      #1  {self.a[:9]}  feat(addon): remember a (#1)\n"
            "          changes/addon-a.md\n"
            f"      #2  {self.b[:9]}  feat(web): draw b (#2)\n"
            "          changes/website-b.md\n"
            f"      #3  {self.c[:9]}  feat(addon): count c (#3)\n"
            "          changes/addon-c.md\n"
            "          depends on #1\n\n"
            'Pick some with: make pick-release VERSION=<x.y.z or x.y.z-beta.n> PRS="<numbers>"\n'), ""))

    # A picked release.

    def test_a_picked_release_ships_only_its_picks_and_its_merge_changes_only_the_bookkeeping(self):
        self.release_on_main()
        code, output, error = self.run_picker("start", "1.2.11", "2")
        self.assertEqual((code, error), (0, ""))
        worktree = self.root / ".release/1.2.11"
        changelog = (worktree / "CHANGELOG.md").read_text()
        self.assertIn("## 1.2.11 - ", changelog)
        self.assertIn("### Website\n\n- Draw b.\n", changelog)
        self.assertNotIn("Remember a", changelog)
        self.assertIn("make pick-release-pr VERSION=1.2.11", output)

        code, output, error = self.run_picker("finish", "1.2.11")
        self.assertEqual((code, error), (0, ""))
        release = self.remote("release/1.2.11")
        pick = self.git("rev-parse", f"{release}^")
        self.assertEqual(self.git("rev-parse", f"{pick}^"), self.release)
        self.assertIn(f"(cherry picked from commit {self.b})", self.git("log", "-1", "--format=%B", pick))
        self.assertEqual(self.git("show", f"{release}:web/app.js"), "app();")
        self.assertEqual(self.git("show", f"{release}:addon/Goldbook/Core.lua"), "local _, ns = ...")
        self.assertFalse({"changes/addon-a.md", "changes/website-b.md"} & self.tree(release))

        merge = self.remote("release-pr/1.2.11")
        self.assertEqual(self.git("rev-list", "--parents", "-n", "1", merge).split()[1:],
                         [release, self.c])
        self.assertEqual(self.git("diff", "--name-status", self.c, merge).splitlines(), [
            "M\tCHANGELOG.md", "M\tCargo.lock", "M\taddon/Goldbook/Goldbook.toc",
            "D\tchanges/website-b.md", "M\tcrates/goldbook-core/Cargo.toml",
            "M\tcrates/goldbook-server/Cargo.toml", "M\tcrates/goldbook-sync/Cargo.toml",
            "M\tdesktop/src-tauri/Cargo.toml", "M\tdesktop/src-tauri/tauri.conf.json",
            "M\tpackage-lock.json", "M\tpackage.json", "M\tweb/index.html"])
        self.assertEqual(self.git("show", f"{merge}:CHANGELOG.md"), self.git("show", f"{release}:CHANGELOG.md"))

        pull, = self.github.pulls
        self.assertEqual((pull["head"], pull["title"], pull["label"]), ("release-pr/1.2.11", "release 1.2.11", "release"))
        self.assertIn("Release 1.2.11 of #2, picked on top of v1.2.10.", pull["body"])
        self.assertIn(f"make release REVISION={release}\n", pull["body"])
        self.assertIn(f"make release REVISION={release}\n", output)
        self.assertEqual(self.run_check("origin/release-pr/1.2.11", ["release"]), (0, (
            "This release pull request sets 1.2.11, adds its changelog section "
            "and collects the change files of the commits it picks from main.\n")))

    def test_finishing_again_after_a_prose_edit_moves_both_branches_and_updates_the_pull_request(self):
        self.release_on_main()
        self.run_picker("start", "1.2.11", "2")
        self.run_picker("finish", "1.2.11")
        first = self.remote("release/1.2.11")
        changelog = self.root / ".release/1.2.11/CHANGELOG.md"
        changelog.write_text(changelog.read_text().replace("- Draw b.", "- Draw b on the Prices page."))
        self.assertEqual(self.run_picker("finish", "1.2.11")[0], 0)
        second = self.remote("release/1.2.11")
        self.assertNotEqual(first, second)
        self.assertEqual(self.git("rev-parse", f"{second}^"), self.git("rev-parse", f"{first}^"))
        self.assertIn("- Draw b on the Prices page.", self.git("show", "origin/release-pr/1.2.11:CHANGELOG.md"))
        self.assertEqual(len(self.github.pulls), 1)
        (url, body), = self.github.edits
        self.assertEqual(url, self.github.pulls[0]["url"])
        self.assertIn(f"make release REVISION={second}\n", body)
        self.assertEqual(self.run_check("origin/release-pr/1.2.11", ["release"])[0], 0)

    def test_after_the_merge_and_the_tag_main_lists_only_what_the_release_did_not_pick(self):
        self.release_on_main()
        self.run_picker("start", "1.2.11", "1", "3")
        self.run_picker("finish", "1.2.11")
        release = self.remote("release/1.2.11")
        self.git("fetch", "-q", "origin")
        self.git("merge", "-q", "--no-ff", "-m", "Merge pull request #100", "origin/release-pr/1.2.11")
        self.git("tag", "v1.2.11", release)
        self.push()
        self.output = io.StringIO()
        code, output, _ = self.run_picker("list")
        self.assertEqual(code, 0)
        self.assertIn("Not released since v1.2.11", output)
        self.assertIn("#2", output)
        self.assertNotIn("#1 ", output)
        self.assertNotIn("#3 ", output)
        self.assertEqual(sorted(path.name for path in (self.root / "changes").iterdir()),
                         ["README.md", "website-b.md"])

    # A picked beta.

    def test_a_picked_beta_opens_a_merge_that_changes_no_file(self):
        self.release_on_main()
        code, output, error = self.run_picker("start", "1.2.11-beta.1", "1")
        self.assertEqual((code, error), (0, ""))
        beta = self.remote("release/1.2.11-beta.1")
        self.assertIn(f"(cherry picked from commit {self.a})", self.git("log", "-1", "--format=%B", beta))
        self.assertEqual(self.git("rev-parse", f"{beta}^"), self.release)
        merge = self.remote("release-pr/1.2.11-beta.1")
        self.assertEqual(self.git("diff", "--name-only", self.c, merge), "")
        pull, = self.github.pulls
        self.assertEqual((pull["title"], pull["label"]), ("beta 1.2.11-beta.1", "no-changes"))
        self.assertIn(f"make release REVISION={beta} BETA=1.2.11-beta.1\n", pull["body"])
        self.assertEqual(self.run_check("origin/release-pr/1.2.11-beta.1", ["no-changes"]), (0, (
            "This pull request merges a beta picked from the last release and changes nothing on main.\n")))

    # Refusals.

    def test_refuses_a_pull_request_without_the_one_it_depends_on(self):
        self.release_on_main()
        self.assertEqual(self.run_picker("start", "1.2.11", "3")[0::2], (1, (
            "#3 depends on #1, which this release does not pick. Pick #1 too, or leave #3 out.\n")))
        self.assertFalse((self.root / ".release/1.2.11").exists())

    def test_a_conflicting_pick_names_the_pull_request_it_needs_and_leaves_nothing_behind(self):
        self.release_on_main()
        self.github.descriptions[3] = "Adds c."
        self.assertEqual(self.run_picker("start", "1.2.11", "3")[0::2], (1, (
            "#3 does not apply on top of the last release: addon/Goldbook/Core.lua conflict. "
            "It probably needs #1, which this release does not pick. Pick them too, or leave #3 out.\n")))
        self.assertFalse((self.root / ".release/1.2.11").exists())
        self.assertFalse(self.git("branch", "--list", "release/1.2.11"))

    def test_refuses_a_number_that_main_does_not_hold_unreleased(self):
        self.release_on_main()
        self.assertEqual(self.run_picker("start", "1.2.11", "9", "4")[0::2], (1, (
            "#9, #4: not a pull request merged into main since v1.2.10 and not yet released. "
            "make pick-release lists them.\n")))

    def test_refuses_a_version_that_is_not_above_the_last_release(self):
        self.release_on_main()
        self.assertEqual(self.run_picker("start", "1.2.10-beta.1", "2")[0::2], (1, (
            "1.2.10-beta.1 is not above 1.2.10, the newest release or beta. After a beta x.y.z-beta.n, "
            "the next release is at least x.y.z.\n")))

    def test_refuses_a_release_below_a_promoted_beta(self):
        self.release_on_main()
        self.git("tag", "v1.3.0-beta.1", self.c)
        self.push()
        self.assertEqual(self.run_picker("start", "1.2.11", "2")[0::2], (1, (
            "1.2.11 is not above 1.3.0-beta.1, the newest release or beta. After a beta x.y.z-beta.n, "
            "the next release is at least x.y.z.\n")))
        self.assertEqual(self.run_picker("start", "1.3.0", "2")[0], 0)

    def test_lists_and_picks_a_pull_request_merged_with_a_merge_commit(self):
        self.release_on_main()
        self.git("checkout", "-q", "-b", "feature", self.c)
        self.write("docs/notes.md", "Notes.\n")
        self.write("changes/app-notes.md", "- Write notes.\n")
        self.commit("docs: write notes")
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-ff", "-m", "Merge pull request #7 from jkc-be/feature", "feature")
        self.push()
        code, output, _ = self.run_picker("list")
        self.assertIn("#7", output)
        self.assertIn("changes/app-notes.md", output)
        self.assertEqual(self.run_picker("start", "1.2.11", "7")[0::2], (0, ""))
        self.assertEqual(self.run_picker("finish", "1.2.11")[0::2], (0, ""))
        self.assertEqual(self.git("show", "origin/release/1.2.11^:docs/notes.md"), "Notes.")
        self.assertEqual(self.run_check("origin/release-pr/1.2.11", ["release"])[0], 0)

    def test_refuses_a_pick_whose_change_file_a_later_pull_request_edits(self):
        self.release_on_main()
        self.write("changes/addon-a.md", "- Remember a.\n- And remember it twice.\n")
        self.commit("docs(changes): remember a twice (#6)")
        self.push()
        self.assertEqual(self.run_picker("start", "1.2.11", "1")[0::2], (1, (
            "#6 changes changes/addon-a.md, which #1 adds. Pick #6 too, or leave #1 out.\n")))
        self.assertEqual(self.run_picker("start", "1.2.11", "1", "6")[0], 0)

    def test_finish_refuses_a_change_beyond_the_bookkeeping(self):
        self.release_on_main()
        self.run_picker("start", "1.2.11", "2")
        (self.root / ".release/1.2.11/web/app.js").write_text("app(); hidden();\n")
        self.assertEqual(self.run_picker("finish", "1.2.11")[0::2], (1, (
            "release/1.2.11 has changes beyond the changelog, the version and the change files: web/app.js. "
            "Undo them; a picked release ships only the picked pull requests.\n")))

    def test_finish_refuses_to_replace_a_release_another_clone_pushed(self):
        self.release_on_main()
        self.run_picker("start", "1.2.11", "2")
        self.run_picker("finish", "1.2.11")
        other = self.top / "other"
        self.git("clone", "-q", "-b", "release/1.2.11", str(self.top / "origin.git"), str(other), cwd=self.top)
        (other / "docs").mkdir(exist_ok=True)
        (other / "docs/other.md").write_text("Another clone.\n")
        self.git("add", "-A", cwd=other)
        self.git("commit", "-q", "-m", "Another clone's release", cwd=other)
        self.git("push", "-q", "origin", "release/1.2.11", cwd=other)
        theirs = self.remote("release/1.2.11")
        changelog = self.root / ".release/1.2.11/CHANGELOG.md"
        changelog.write_text(changelog.read_text().replace("- Draw b.", "- Draw b again."))
        code, _, error = self.run_picker("finish", "1.2.11")
        self.assertEqual(code, 1)
        self.assertIn("If someone else pushed release/1.2.11 since this clone last did", error)
        self.assertEqual(self.remote("release/1.2.11"), theirs)

    def test_a_beta_whose_pull_request_fails_keeps_its_picks_and_says_how_to_retry(self):
        self.release_on_main()
        github = self.github

        def failing(*args):
            if args[:2] == ("pr", "create"):
                raise PICK.Failure("gh pr create failed:\nHTTP 502")
            return github(*args)
        self.picker.gh = failing
        self.assertEqual(self.run_picker("start", "1.2.11-beta.1", "2")[0::2], (1, (
            "gh pr create failed:\nHTTP 502\nThe beta's picks stay on release/1.2.11-beta.1 in "
            ".release/1.2.11-beta.1. Run make pick-release-pr VERSION=1.2.11-beta.1 to try again.\n")))
        self.picker.gh = github
        self.assertEqual(self.run_picker("finish", "1.2.11-beta.1")[0::2], (0, ""))

    def test_refuses_while_main_holds_a_release_that_is_not_tagged(self):
        self.release_on_main()
        self.script("scripts/prepare-release.py", "1.2.11")
        self.commit("release 1.2.11 (#4)")
        self.push()
        self.assertEqual(self.run_picker("start", "1.2.12", "2")[0::2], (1, (
            "main holds version 1.2.11, but the last release tag is v1.2.10. "
            "Release 1.2.11 with make release first, or finish its promotion.\n")))

    def test_refuses_a_release_whose_check_workflow_does_not_run_on_release_branches(self):
        self.release_on_main(check="on:\n  push:\n    branches: [main]\n")
        self.write(".github/workflows/check.yml", CHECK)
        self.commit("feat(release): run Check on release branches (#5)")
        self.push()
        self.assertEqual(self.run_picker("start", "1.2.11", "2")[0::2], (1, (
            "This release cannot be built: its .github/workflows/check.yml predates the change that "
            "runs Check on release branches. Pick #5 too, which adds it.\n")))
        self.assertFalse((self.root / ".release/1.2.11").exists())


if __name__ == "__main__":
    unittest.main()
