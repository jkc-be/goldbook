"""Release outputs through every stage of a promotion, read from a simulated GitHub and feed."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import warnings
from unittest import mock
import zipfile

SPEC = importlib.util.spec_from_file_location("release_state", Path(__file__).parents[1] / "release-state.py")
STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE)

API = "https://api.github.com/repos/"
ADDON = API + "jkc-be/goldbook-addon"
SOURCE = API + "jkc-be/goldbook"
FEED = "https://app.jkc-be.com/goldbook/updates"
PREVIOUS, VERSION = "0.2.4", "0.2.5"
OLD, R1, R2 = "0" * 40, "1" * 40, "2" * 40  # the previous release, build run 1 and build run 2
MIRROR_OLD, MIRROR_R1 = "a" * 40, "b" * 40  # goldbook-addon commits


def feed(version, revision, signature):
    latest = json.dumps({"version": version, "notes": "Goldbook client update", "platforms": {
        "darwin-aarch64": {"url": f"{FEED}/{revision}/darwin-aarch64-Goldbook.app.tar.gz",
                           "signature": signature}}}, indent=2).encode() + b"\n"
    payload = json.dumps({"version": version, "sequence": 1, "revision": revision, "files": {}}).encode()
    addon = json.dumps({"payload": base64.b64encode(payload).decode(), "signature": signature}).encode()
    return {"latest.json": latest, "addon.json": addon}


OLD_FEED = feed(PREVIOUS, OLD, "old")
B1_FEED = feed(VERSION, R1, "build-1")
B2_FEED = feed(VERSION, R1, "build-2")  # the same commit, built and signed again
B3_FEED = feed(VERSION, R2, "build-3")  # a later commit under the same version


class World:
    """GitHub and the update feed as release-state.py reads them, keyed by URL."""

    def __init__(self):
        self.urls = {}
        self.token = "test-token"
        self.authenticated = []
        self.publish(OLD_FEED)
        self.mirror(MIRROR_OLD, OLD, PREVIOUS)
        self.addon_release(PREVIOUS, MIRROR_OLD)
        self.tag(PREVIOUS, OLD)

    def get(self, url, raw=False, authenticated=False):
        if authenticated:
            self.authenticated.append(url)
        value = self.urls.get(url)
        if value is None or isinstance(value, bytes):
            return value
        return json.dumps(value).encode()

    def publish(self, files, names=("latest.json", "addon.json")):
        for name in names:
            self.urls[f"{FEED}/{name}"] = files[name]

    def mirror(self, commit, revision, version):
        self.urls[f"{ADDON}/commits/main"] = {"sha": commit}
        self.urls[f"{ADDON}/contents/upstream.json?ref={commit}"] = json.dumps(
            {"repository": "jkc-be/goldbook", "revision": revision, "path": "addon"}).encode() + b"\n"
        self.urls[f"{ADDON}/contents/Goldbook/Goldbook.toc?ref={commit}"] = (
            f"## Interface: 16001\n## Title: Goldbook\n## Version: {version}\n").encode()

    def addon_release(self, version, commit):
        self.urls[f"{ADDON}/releases/tags/v{version}"] = {"tag_name": f"v{version}"}
        self.urls[f"{ADDON}/git/ref/tags/v{version}"] = {"object": {"type": "commit", "sha": commit}}

    def tag(self, version, commit):
        self.urls[f"{SOURCE}/git/ref/tags/v{version}"] = {"object": {"type": "commit", "sha": commit}}

    def downstream(self, commit, status, conclusion=None, curseforge=None, package="success"):
        self.urls[f"{ADDON}/actions/workflows/release.yml/runs?head_sha={commit}&per_page=100"] = {
            "workflow_runs": [{"id": 7, "status": status, "conclusion": conclusion,
                               "html_url": "https://github.com/jkc-be/goldbook-addon/actions/runs/7"}]}
        self.urls[f"{ADDON}/actions/runs/7/jobs?filter=all"] = {"jobs": [
            {"name": "package", "conclusion": package}, {"name": "curseforge", "conclusion": curseforge}]}

    def build_run(self, run_id, revision, files, **changes):
        run = {"id": run_id, "head_sha": revision, "head_branch": "main", "event": "workflow_dispatch",
               "path": ".github/workflows/release-build.yml", "status": "completed", "conclusion": "success",
               "run_attempt": 1, "repository": {"full_name": "jkc-be/goldbook"},
               "head_repository": {"full_name": "jkc-be/goldbook"}, "actor": {"id": 156444954},
               "triggering_actor": {"id": 156444954},
               "html_url": f"https://github.com/jkc-be/goldbook/actions/runs/{run_id}", **changes}
        self.urls[f"{SOURCE}/actions/runs/{run_id}"] = run
        artifacts = [{"id": run_id * 10 + index, "name": name, "expired": False, "digest": f"sha256:{index}"}
                     for index, name in enumerate(STATE.BUILD_ARTIFACTS)]
        self.urls[f"{SOURCE}/actions/runs/{run_id}/artifacts?per_page=100"] = {"artifacts": artifacts}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as bundle:
            for name, content in files.items():
                bundle.writestr(name, content)
        self.urls[f"{SOURCE}/actions/artifacts/{run_id * 10}/zip"] = archive.getvalue()
        listing = f"{SOURCE}/actions/workflows/release-build.yml/runs?head_sha={revision}&status=success&per_page=100"
        self.urls.setdefault(listing, {"workflow_runs": []})["workflow_runs"].append(run)
        return run


# The stages of a promotion of build run 1, each including the ones before it.
STAGES = ("fresh", "server deployed", "latest.json published", "both manifests published",
          "mirror pushed, downstream pending", "downstream failed", "downstream succeeded", "tagged")


def world_at(stage):
    world = World()
    reached = STAGES[:STAGES.index(stage) + 1]
    # A server deploy changes nothing release-state.py reads.
    if "latest.json published" in reached:
        world.publish(B1_FEED, ["latest.json"])
    if "both manifests published" in reached:
        world.publish(B1_FEED)
    if "mirror pushed, downstream pending" in reached:
        world.mirror(MIRROR_R1, R1, VERSION)
        world.downstream(MIRROR_R1, "waiting")
    if "downstream failed" in reached:
        # The package job created the release; the CurseForge upload failed.
        world.addon_release(VERSION, MIRROR_R1)
        world.downstream(MIRROR_R1, "completed", "failure", "failure")
    if "downstream succeeded" in reached:
        world.downstream(MIRROR_R1, "completed", "success", "success")
    if "tagged" in reached:
        world.tag(VERSION, R1)
    return world


def states(world, build):
    return {name: verdict.state for name, verdict in STATE.evaluate(build, STATE.observe(world, VERSION)).items()}


def row(client, addon, mirror, release, tag):
    return {"client-feed": client, "addon-feed": addon, "addon-mirror": mirror,
            "addon-release": release, "source-tag": tag}


A, M, C = "absent", "matches", "conflict"
# stage: (a new build of R1, promoting build run 1, promoting build run 2 of R1, promoting build run 3 of R2)
EXPECTED = {
    "fresh": (row(A, A, A, A, A), row(A, A, A, A, A), row(A, A, A, A, A), row(A, A, A, A, A)),
    "server deployed": (row(A, A, A, A, A), row(A, A, A, A, A), row(A, A, A, A, A), row(A, A, A, A, A)),
    "latest.json published": (row(C, A, A, A, A), row(M, A, A, A, A), row(C, A, A, A, A), row(C, A, A, A, A)),
    "both manifests published": (row(C, C, A, A, A), row(M, M, A, A, A), row(C, C, A, A, A), row(C, C, A, A, A)),
    "mirror pushed, downstream pending": (
        row(C, C, M, A, A), row(M, M, M, A, A), row(C, C, M, A, A), row(C, C, C, A, A)),
    "downstream failed": (row(C, C, M, M, A), row(M, M, M, M, A), row(C, C, M, M, A), row(C, C, C, C, A)),
    "downstream succeeded": (row(C, C, M, M, A), row(M, M, M, M, A), row(C, C, M, M, A), row(C, C, C, C, A)),
    "tagged": (row(C, C, M, M, M), row(M, M, M, M, M), row(C, C, M, M, M), row(C, C, C, C, C)),
}


class StageMatrix(unittest.TestCase):
    def test_every_stage_for_a_new_build_and_three_promotions(self):
        for stage in STAGES:
            with self.subTest(stage=stage):
                world = world_at(stage)
                new, own, rebuilt, later = EXPECTED[stage]
                self.assertEqual(states(world, STATE.Build(VERSION, R1)), new)
                self.assertEqual(states(world, STATE.Build(VERSION, R1, B1_FEED)), own)
                self.assertEqual(states(world, STATE.Build(VERSION, R1, B2_FEED)), rebuilt)
                self.assertEqual(states(world, STATE.Build(VERSION, R2, B3_FEED)), later)

    def test_a_new_build_may_start_only_before_anything_it_reads_is_released(self):
        allowed = [stage for stage in STAGES
                   if STATE.may_build(STATE.evaluate(STATE.Build(VERSION, R1), STATE.observe(world_at(stage), VERSION)))]
        self.assertEqual(allowed, ["fresh", "server deployed"])

    def test_the_matching_build_run_may_always_continue_and_the_others_only_before_publication(self):
        def promotable(files, revision):
            return [stage for stage in STAGES if STATE.may_promote(STATE.evaluate(
                STATE.Build(VERSION, revision, files), STATE.observe(world_at(stage), VERSION)))]
        self.assertEqual(promotable(B1_FEED, R1), list(STAGES))
        self.assertEqual(promotable(B2_FEED, R1), ["fresh", "server deployed"])
        self.assertEqual(promotable(B3_FEED, R2), ["fresh", "server deployed"])

    def test_the_downstream_wait_follows_goldbook_addon(self):
        expected = {"mirror pushed, downstream pending": "pending", "downstream failed": "failure",
                    "downstream succeeded": "success", "tagged": "success"}
        for stage, state in expected.items():
            with self.subTest(stage=stage):
                world = world_at(stage)
                runs = json.loads(world.get(f"{ADDON}/actions/workflows/release.yml/runs?head_sha={MIRROR_R1}"
                                            "&per_page=100"))["workflow_runs"]
                jobs = json.loads(world.get(f"{ADDON}/actions/runs/7/jobs?filter=all"))["jobs"]
                self.assertEqual(STATE.downstream_verdict(runs, lambda run_id: jobs)[0], state)


class Reasons(unittest.TestCase):
    def verdicts(self, world, build):
        return {name: str(verdict) for name, verdict in STATE.evaluate(build, STATE.observe(world, VERSION)).items()}

    def test_conflicts_name_what_was_found(self):
        self.assertEqual(self.verdicts(world_at("tagged"), STATE.Build(VERSION, R2, B3_FEED)), {
            "client-feed": "conflict (latest.json publishes 0.2.5 from 111111111111, which differs from this build's latest.json)",
            "addon-feed": "conflict (addon.json publishes 0.2.5 from 111111111111, which differs from this build's addon.json)",
            "addon-mirror": "conflict (goldbook-addon HEAD bbbbbbbbbbbb holds 0.2.5 from 111111111111, not 222222222222)",
            "addon-release": "conflict (goldbook-addon release v0.2.5 was built from bbbbbbbbbbbb, mirrored from 111111111111, not 222222222222)",
            "source-tag": "conflict (tag v0.2.5 points at 111111111111, not 222222222222)",
        })

    def test_the_previous_release_counts_as_absent(self):
        self.assertEqual(self.verdicts(world_at("fresh"), STATE.Build(VERSION, R1))["addon-mirror"],
                         "absent (goldbook-addon HEAD aaaaaaaaaaaa holds 0.2.4 from 000000000000, an older release)")

    def test_a_mirror_of_the_revision_under_an_older_version_is_not_this_release(self):
        self.assertEqual(self.verdicts(world_at("fresh"), STATE.Build(VERSION, OLD))["addon-mirror"],
                         "absent (goldbook-addon HEAD aaaaaaaaaaaa holds 0.2.4 from 000000000000, an older release)")

    def test_a_newer_release_conflicts_with_promoting_an_older_build(self):
        world = world_at("tagged")
        newer = feed("0.2.6", R2, "build-3")
        world.publish(newer)
        self.assertEqual(self.verdicts(world, STATE.Build(VERSION, R1, B1_FEED))["client-feed"],
                         "conflict (latest.json publishes 0.2.6 from 222222222222, newer than 0.2.5)")

    def test_an_annotated_tag_is_followed_to_its_commit(self):
        world = world_at("downstream succeeded")
        world.urls[f"{SOURCE}/git/ref/tags/v{VERSION}"] = {"object": {"type": "tag", "sha": "c" * 40}}
        world.urls[f"{SOURCE}/git/tags/{'c' * 40}"] = {"object": {"type": "commit", "sha": R1}}
        self.assertEqual(self.verdicts(world, STATE.Build(VERSION, R1, B1_FEED))["source-tag"], "matches")


class CommandLine(unittest.TestCase):
    def run_main(self, world, *argv, environment=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        # Other test modules leave SQLite connections for the garbage collector,
        # whose ResourceWarnings would otherwise land in the captured stderr.
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                mock.patch.dict(os.environ, environment or {}, clear=True), warnings.catch_warnings():
            warnings.simplefilter("ignore", ResourceWarning)
            code = STATE.main(list(argv), http=world)
        return code, stdout.getvalue(), stderr.getvalue().strip()

    def test_a_new_build_of_a_partly_released_version_names_the_build_run_to_promote(self):
        world = world_at("both manifests published")
        world.build_run(110, R1, B2_FEED)
        world.build_run(111, R1, B1_FEED)
        world.build_run(112, R1, B1_FEED, run_attempt=2)
        code, _, error = self.run_main(world, "state", "--version", VERSION, "--revision", R1, "--build")
        self.assertEqual(code, 1)
        self.assertEqual(error, "0.2.5 is already partly released. Run Release promote with build run 111 "
                                "(https://github.com/jkc-be/goldbook/actions/runs/111) to finish it; "
                                "build runs are never repeated.")

    def test_a_new_build_of_a_released_version_asks_for_a_new_version(self):
        world = world_at("tagged")
        world.build_run(111, R1, B1_FEED)
        code, _, error = self.run_main(world, "state", "--version", VERSION, "--revision", R2, "--build")
        self.assertEqual((code, error), (1, "0.2.5 is already released by build run 111 "
                                            "(https://github.com/jkc-be/goldbook/actions/runs/111). "
                                            "Prepare a new version for a new release."))

    def test_a_new_build_without_a_promotable_run_asks_for_a_new_version(self):
        code, _, error = self.run_main(world_at("latest.json published"),
                                       "state", "--version", VERSION, "--revision", R1, "--build")
        self.assertEqual((code, error), (1, "0.2.5 is already partly released and no build run that can finish "
                                            "it was found; its artifacts may have expired. Prepare a new version."))

    def test_a_new_build_below_a_released_version_is_refused(self):
        code, _, error = self.run_main(World(), "state", "--version", "0.2.3", "--revision", R1, "--build")
        self.assertEqual((code, error), (1, "A newer version than 0.2.3 is already released. Prepare a higher version."))

    def test_a_fresh_version_may_be_built_without_reading_actions(self):
        world = world_at("server deployed")
        code, out, _ = self.run_main(world, "state", "--version", VERSION, "--revision", R1, "--build")
        self.assertEqual(code, 0)
        self.assertIn("Nothing of 0.2.5 is released yet; the build may start.", out)
        self.assertEqual(world.authenticated, [])

    def promote(self, world, files):
        with tempfile.TemporaryDirectory() as directory:
            for name, content in files.items():
                (Path(directory) / name).write_bytes(content)
            output = Path(directory) / "output"
            output.touch()
            result = self.run_main(world, "state", "--version", VERSION, "--revision", R1, "--feed", directory,
                                   environment={"GITHUB_OUTPUT": str(output)})
            return result[0], result[2], output.read_text()

    def test_promotion_skips_the_server_deploy_once_its_feed_is_published(self):
        self.assertEqual(self.promote(world_at("server deployed"), B1_FEED), (0, "", "deploy_server=true\n"))
        self.assertEqual(self.promote(world_at("latest.json published"), B1_FEED), (0, "", "deploy_server=false\n"))
        self.assertEqual(self.promote(world_at("tagged"), B1_FEED), (0, "", "deploy_server=false\n"))

    def test_promotion_of_another_build_stops(self):
        self.assertEqual(self.promote(world_at("latest.json published"), B2_FEED),
                         (1, "An output belongs to another build. Decide what to do before promoting.", ""))

    def test_check_build_run_accepts_a_first_successful_maintainer_run_and_outputs_its_revision(self):
        world = World()
        world.build_run(111, R1, B1_FEED)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            code, out, _ = self.run_main(world, "check-build-run", "--run-id", "111",
                                         environment={"GITHUB_OUTPUT": str(output)})
            self.assertEqual((code, output.read_text()), (0, f"revision={R1}\n"))
        self.assertIn("| Goldbook-update-feed | 1110 | `sha256:0` |", out)

    def test_check_build_run_refuses_reruns_failures_other_workflows_and_expired_artifacts(self):
        world = World()
        world.build_run(111, R1, B1_FEED, run_attempt=2, conclusion="failure", event="push",
                        path=".github/workflows/deploy.yml@refs/heads/main", triggering_actor={"id": 1})
        world.urls[f"{SOURCE}/actions/runs/111/artifacts?per_page=100"]["artifacts"][0]["expired"] = True
        code, _, error = self.run_main(world, "check-build-run", "--run-id", "111")
        self.assertEqual((code, error), (1, (
            "Build run 111 cannot be promoted: it is a run of .github/workflows/deploy.yml@refs/heads/main, "
            "not .github/workflows/release-build.yml; it was not started by hand on main; it was not started by "
            "jkc-be; it is completed with conclusion failure, not a success; it is attempt 2; build runs are never "
            "rerun; it has 0 unexpired Goldbook-update-feed artifacts, not 1.")))

    def test_arguments_that_could_reach_a_url_are_validated(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            STATE.main(["check-build-run", "--run-id", "1/../2"], http=World())
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            STATE.main(["wait-addon-release", "--commit", "main"], http=World())


class DownstreamWait(unittest.TestCase):
    def wait(self, world, polls):
        """Runs the wait loop, letting goldbook-addon move on at each sleep."""
        clock = [0]

        def sleep(seconds):
            clock[0] += seconds
            if polls:
                polls.pop(0)(world)
        with contextlib.redirect_stdout(io.StringIO()):
            return STATE.wait_for_addon_release(world, MIRROR_R1, 180, 7200, sleep=sleep, clock=lambda: clock[0])

    def test_waits_for_the_run_to_appear_and_for_curseforge_approval(self):
        world = World()
        message = self.wait(world, [lambda w: w.downstream(MIRROR_R1, "waiting"),
                                    lambda w: w.downstream(MIRROR_R1, "completed", "success", "success")])
        self.assertEqual(message, "Package addon release succeeded: https://github.com/jkc-be/goldbook-addon/actions/runs/7")

    def test_an_already_uploaded_release_skips_curseforge_and_still_counts(self):
        world = World()
        world.downstream(MIRROR_R1, "completed", "success", "skipped")
        self.assertTrue(self.wait(world, []).startswith("Package addon release succeeded"))

    def test_a_run_whose_jobs_were_skipped_by_the_actor_condition_does_not_count(self):
        world = World()
        world.downstream(MIRROR_R1, "completed", "success", "skipped", package="skipped")
        with self.assertRaisesRegex(STATE.Failure, "^Package addon release ended with success: .*Rerun it"):
            self.wait(world, [])

    def test_a_failed_run_stops_the_wait_with_the_way_to_finish(self):
        world = World()
        world.downstream(MIRROR_R1, "completed", "failure", "failure")
        with self.assertRaises(STATE.Failure) as raised:
            self.wait(world, [])
        self.assertEqual(str(raised.exception), (
            "Package addon release ended with failure: https://github.com/jkc-be/goldbook-addon/actions/runs/7. "
            "Rerun it in goldbook-addon, then rerun this job."))

    def test_gives_up_after_the_timeout(self):
        world = World()
        world.downstream(MIRROR_R1, "waiting")
        with self.assertRaises(STATE.Failure) as raised:
            self.wait(world, [])
        self.assertEqual(str(raised.exception),
                         f"Package addon release did not finish within 120 minutes for {MIRROR_R1}")


class Feed(unittest.TestCase):
    def folder(self, files):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name, content in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_bytes(content)
        return root

    def test_a_complete_feed_passes(self):
        root = self.folder({**B1_FEED, f"{R1}/darwin-aarch64-Goldbook.app.tar.gz": b"package"})
        self.assertEqual(STATE.feed_problems(root, VERSION, R1), [])

    def test_a_feed_from_another_commit_or_version_is_refused(self):
        root = self.folder({**feed("0.2.4", R2, "x"), f"{R2}/darwin-aarch64-Goldbook.app.tar.gz": b"package"})
        self.assertEqual(STATE.feed_problems(root, VERSION, R1), [
            f"unexpected files: {R2}/darwin-aarch64-Goldbook.app.tar.gz",
            "latest.json has version 0.2.4, not 0.2.5",
            f"latest.json darwin-aarch64 points at {FEED}/{R2}/darwin-aarch64-Goldbook.app.tar.gz, which is not in the feed",
            f"addon.json holds 0.2.4 from {R2}, not 0.2.5 from {R1}",
        ])


class Version(unittest.TestCase):
    def source(self, check_output, code=0, version=VERSION):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "scripts").mkdir()
        (root / "scripts/set-version.py").write_text(
            f"import sys\nprint({check_output!r})\nsys.exit({code})\n")
        (root / "desktop/src-tauri").mkdir(parents=True)
        (root / "desktop/src-tauri/tauri.conf.json").write_text(json.dumps({"version": version}))
        return root

    def test_reads_the_version_that_set_version_confirms(self):
        self.assertEqual(STATE.read_version(self.source("0.2.5")), "0.2.5")

    def test_refuses_mismatched_fields(self):
        with self.assertRaisesRegex(STATE.Failure, "set-version.py --check failed:\nCargo.lock differs"):
            STATE.read_version(self.source("Cargo.lock differs", code=1))

    def test_refuses_a_check_that_reports_another_version(self):
        with self.assertRaisesRegex(STATE.Failure, "did not report 0.2.5: 0.2.50"):
            STATE.read_version(self.source("0.2.50"))


if __name__ == "__main__":
    unittest.main()
