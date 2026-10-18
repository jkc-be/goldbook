"""make release, with gh replaced by a simulated GitHub."""
import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).parents[1] / "release.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)

REVISION, HEAD = "1" * 40, "2" * 40
RUNS = "https://github.com/jkc-be/goldbook/actions/runs/"


def run(run_id, title):
    return {"id": run_id, "html_url": RUNS + str(run_id), "display_title": title,
            "created_at": "2026-10-18T12:00:00Z"}


class GitHub:
    """Answers the gh commands release.py runs. A dispatch adds the runs in
    `starts`, and every listing after it shows them."""

    def __init__(self, login="jkc-be", conclusions=None, built=REVISION, image_revision=None, head_sha=HEAD):
        self.login = login
        self.runs = {"release-build.yml": [run(100, "Release build of " + HEAD)],
                     "release-promote.yml": [run(200, "Release promote of build run 100")]}
        # A title's {request} is the request identifier of the dispatch that starts it.
        self.starts = {"release-build.yml": [[run(101, "Release build of " + REVISION + " [{request}]")]],
                       "release-promote.yml": [[run(201, "Release promote of build run 101 [{request}]")]]}
        self.conclusions = conclusions or {}
        self.built, self.image_revision = built, image_revision or built
        self.head_sha = head_sha
        self.commands = []

    def __call__(self, args, interactive=False):
        self.commands.append(args)
        match args[1:]:
            case ["api", "user", "--jq", ".login"]:
                return self.login + "\n"
            case ["workflow", "run", workflow, *fields]:
                request = next(field.split("=", 1)[1] for field in fields if field.startswith("request="))
                self.runs[workflow] += [dict(started, display_title=started["display_title"].format(request=request))
                                        for started in self.starts[workflow].pop(0)]
                return ""
            case ["api", path, "--jq", ".sha"] if "/commits/" in path:
                assert REVISION.startswith(path.split("/")[-1])
                return REVISION + "\n"
            case ["api", path] if path.endswith("/runs?branch=main&event=workflow_dispatch&per_page=20"):
                workflow = path.split("/")[-2]
                return json.dumps({"workflow_runs": list(reversed(self.runs[workflow]))})
            case ["run", "watch", run_id, *_]:
                assert interactive
                return ""
            case ["api", path] if path.endswith("/artifacts?per_page=100"):
                return json.dumps({"artifacts": [
                    {"name": "Goldbook-update-feed", "id": 7, "digest": "sha256:f"},
                    {"name": "Goldbook-server-image", "id": 6, "digest": "sha256:e"}]})
            case ["api", path] if "/actions/runs/" in path:
                run_id = int(path.split("/")[-1])
                return json.dumps({"conclusion": self.conclusions.get(run_id, "success"), "head_sha": self.head_sha})
            case ["run", "download", run_id, "--repo", _, "--dir", directory, *_]:
                (Path(directory) / "Goldbook-server-image").mkdir()
                (Path(directory) / "Goldbook-server-image/image.json").write_text(
                    json.dumps({"revision": self.image_revision, "digest": "sha256:" + "e" * 64}))
                payload = json.dumps({"version": "0.2.5", "sequence": 1, "revision": self.built, "files": {}})
                (Path(directory) / "Goldbook-addon-feed").mkdir()
                (Path(directory) / "Goldbook-addon-feed/addon.json").write_text(
                    json.dumps({"payload": base64.b64encode(payload.encode()).decode(), "signature": "s"}))
                return ""
        raise AssertionError(f"Unexpected command {args}")

    def dispatched(self):
        return [args[3:] for args in self.commands if args[1:3] == ["workflow", "run"]]


class Release(unittest.TestCase):
    def release(self, github, answers=(), argv=("--revision", REVISION)):
        answers, prompts, stdout, stderr = list(answers), [], io.StringIO(), io.StringIO()

        def ask(prompt):
            prompts.append(prompt)
            return answers.pop(0)
        requests = iter(["build-request", "promote-request"])
        release = RELEASE.Release(run=github, ask=ask, sleep=lambda seconds: None, request=lambda: next(requests))
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = RELEASE.main(list(argv), release=release)
        return code, prompts, stdout.getvalue(), stderr.getvalue().strip()

    def test_builds_the_revision_then_promotes_that_build_after_a_yes(self):
        github = GitHub()
        code, prompts, out, _ = self.release(github, ["y"])
        self.assertEqual(code, 0)
        self.assertEqual(github.dispatched(), [
            ["release-build.yml", "--repo", "jkc-be/goldbook", "--ref", "main", "-f", f"revision={REVISION}",
             "-f", "request=build-request"],
            ["release-promote.yml", "--repo", "jkc-be/goldbook", "--ref", "main", "-f", "build_run_id=101",
             "-f", "request=promote-request"]])
        self.assertEqual(prompts, [f"Promote build run 101 (version 0.2.5, revision {REVISION})? [y/N] "])
        self.assertIn(f"Release build run 101: {RUNS}101\n", out)
        self.assertIn(f"Build run 101 built Goldbook 0.2.5 from revision {REVISION}.\n"
                      "  Goldbook-server-image  ID 6  sha256:e\n  Goldbook-update-feed  ID 7  sha256:f\n", out)
        self.assertIn(f"Release promote run 201: {RUNS}201\n", out)
        self.assertTrue(out.endswith(f"Released Goldbook 0.2.5 from {REVISION}.\n"))

    def test_without_a_revision_builds_the_current_main(self):
        github = GitHub(head_sha=REVISION)
        code, prompts, _, _ = self.release(github, ["n"], argv=())
        self.assertEqual((code, len(prompts)), (0, 1))
        self.assertEqual(github.dispatched(),
                         [["release-build.yml", "--repo", "jkc-be/goldbook", "--ref", "main", "-f", "request=build-request"]])

    def test_an_abbreviated_revision_is_built_as_its_full_sha(self):
        github = GitHub()
        self.release(github, ["n"], argv=("--revision", REVISION[:7]))
        self.assertEqual(github.dispatched()[0][6], f"revision={REVISION}")

    def test_anything_but_yes_leaves_the_build_unpromoted_and_says_how_to_promote_it(self):
        github = GitHub()
        code, _, out, _ = self.release(github, [""])
        self.assertEqual(code, 0)
        self.assertEqual(len(github.dispatched()), 1)
        self.assertTrue(out.endswith("Not promoted. To promote this build later, run:\n  gh workflow run "
                                     "release-promote.yml --repo jkc-be/goldbook --ref main -f build_run_id=101\n"))

    def test_a_run_someone_else_started_meanwhile_is_not_taken(self):
        github = GitHub()
        # The other run is newer, so GitHub lists it first.
        github.starts["release-build.yml"] = [[run(101, f"Release build of {REVISION} [{{request}}]"),
                                               run(102, f"Release build of {HEAD} [another-request]")]]
        code, prompts, out, _ = self.release(github, ["n"])
        self.assertEqual(code, 0)
        self.assertIn(f"Release build run 101: {RUNS}101\n", out)
        self.assertEqual(prompts, [f"Promote build run 101 (version 0.2.5, revision {REVISION})? [y/N] "])

    def test_stops_when_its_run_does_not_appear(self):
        github = GitHub()
        github.starts["release-build.yml"] = [[run(102, f"Release build of {HEAD} [another-request]")]]
        self.assertEqual(self.release(github)[::3], (
            1, "No release-build.yml run named [build-request] appeared within a minute. "
               "Look for it under Actions on GitHub."))
        self.assertFalse(any(args[1:3] == ["run", "watch"] for args in github.commands))

    def test_a_build_of_another_revision_is_not_offered(self):
        code, prompts, _, error = self.release(GitHub(built=HEAD))
        self.assertEqual((code, prompts), (1, []))
        self.assertEqual(error, f"Build run 101 built {HEAD}, not {REVISION} as requested. Do not promote it.")

    def test_without_a_revision_the_build_must_take_the_commit_it_started_on(self):
        code, prompts, _, error = self.release(GitHub(head_sha=HEAD), argv=())
        self.assertEqual((code, prompts), (1, []))
        self.assertEqual(error, f"Build run 101 built {REVISION}, not {HEAD} as requested. Do not promote it.")

    def test_a_failed_build_stops_before_the_question(self):
        code, prompts, _, error = self.release(GitHub(conclusions={101: "failure"}))
        self.assertEqual((code, prompts), (1, []))
        self.assertEqual(error, f"Release build run 101 ended with failure: {RUNS}101\nRead the failed job, fix "
                                "the cause, and start a new build with make release. Build runs are never rerun.")

    def test_a_failed_promotion_says_how_to_finish_the_release(self):
        code, _, _, error = self.release(GitHub(conclusions={201: "failure"}), ["yes"])
        self.assertEqual(code, 1)
        self.assertEqual(error, (
            f"Release promote run 201 ended with failure: {RUNS}201\n"
            "Fix the cause, then finish the release by promoting the same build again:\n"
            "  gh workflow run release-promote.yml --repo jkc-be/goldbook --ref main -f build_run_id=101\n"
            "A second promotion skips what is already done. Do not use Re-run failed jobs."))

    def test_a_build_whose_image_and_addon_name_different_revisions_is_not_offered(self):
        code, prompts, _, error = self.release(GitHub(image_revision=HEAD))
        self.assertEqual((code, prompts), (1, []))
        self.assertEqual(error, f"Build run 101 built its image from {HEAD} but its addon from {REVISION}. "
                                "Do not promote it; start a new build.")

    def test_only_the_maintainer_starts_a_release(self):
        github = GitHub(login="jkc-be-agents")
        self.assertEqual(self.release(github)[::3], (1, "gh is signed in as jkc-be-agents. Only jkc-be starts releases."))
        self.assertEqual(github.dispatched(), [])

    def test_a_revision_must_be_a_sha(self):
        for revision in ("main", "HEAD~1", "abc", "A" * 40):
            with self.subTest(revision=revision), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                RELEASE.main(["--revision", revision], release=RELEASE.Release(run=GitHub()))


if __name__ == "__main__":
    unittest.main()
