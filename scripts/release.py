#!/usr/bin/env python3
"""Release Goldbook from this computer, as the signed-in gh user.

    release.py [--revision SHA]

Starts Release build on main for the revision, or for the current main when
none is given, and watches it while you approve its environments in the
browser. Then it asks whether to promote that build and watches Release
promote. The two runs stay separate on GitHub, so a build can also be
promoted later on its own (docs/releasing.md).
"""
import argparse
import base64
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time

REPOSITORY = "jkc-be/goldbook"
MAINTAINER = "jkc-be"
BUILD, PROMOTE = "release-build.yml", "release-promote.yml"
REVISION = re.compile(r"[0-9a-f]{7,40}")


class Failure(Exception):
    """A stop, with a message that says what to do next."""


def run_command(args, interactive=False):
    """Runs a command and returns its output. An interactive command writes to
    the terminal instead."""
    pipe = None if interactive else subprocess.PIPE
    result = subprocess.run(args, text=True, stdout=pipe, stderr=pipe)
    if result.returncode != 0:
        raise Failure(f"{' '.join(args)} failed" + (f":\n{result.stderr.strip()}" if result.stderr else "."))
    return result.stdout or ""


def promote_command(build_id):
    return f"gh workflow run {PROMOTE} --repo {REPOSITORY} --ref main -f build_run_id={build_id}"


class Release:
    def __init__(self, run=run_command, ask=input, sleep=time.sleep, say=print,
                 request=lambda: secrets.token_hex(6)):
        self.run, self.ask, self.sleep, self.say, self.request = run, ask, sleep, say, request

    def api(self, path):
        return json.loads(self.run(["gh", "api", path]))

    def dispatch_runs(self, workflow):
        return self.api(f"repos/{REPOSITORY}/actions/workflows/{workflow}/runs"
                        "?branch=main&event=workflow_dispatch&per_page=20")["workflow_runs"]

    def dispatch(self, workflow, fields):
        """Starts a workflow on main and returns the run it created as (ID, URL).
        The run is found by a request identifier that both workflows put in
        their run name, so a run someone else starts at the same time is never
        taken for this one."""
        request = self.request()
        command = ["gh", "workflow", "run", workflow, "--repo", REPOSITORY, "--ref", "main"]
        for name, value in {**fields, "request": request}.items():
            command += ["-f", f"{name}={value}"]
        self.run(command)
        for _ in range(20):
            self.sleep(3)
            mine = [run for run in self.dispatch_runs(workflow) if run["display_title"].endswith(f"[{request}]")]
            if mine:
                return mine[0]["id"], mine[0]["html_url"]
        raise Failure(f"No {workflow} run named [{request}] appeared within a minute. "
                      "Look for it under Actions on GitHub.")

    def watch(self, run_id):
        """Shows the run until it ends and returns it."""
        self.run(["gh", "run", "watch", str(run_id), "--repo", REPOSITORY, "--interval", "10"], interactive=True)
        return self.api(f"repos/{REPOSITORY}/actions/runs/{run_id}")

    def built(self, run_id):
        """The version and revision a build run built, from its two small artifacts."""
        with tempfile.TemporaryDirectory() as directory:
            self.run(["gh", "run", "download", str(run_id), "--repo", REPOSITORY, "--dir", directory,
                      "--name", "Goldbook-server-image", "--name", "Goldbook-addon-feed"])
            image = json.loads(next(Path(directory).rglob("image.json")).read_text())
            envelope = json.loads(next(Path(directory).rglob("addon.json")).read_text())
        addon = json.loads(base64.b64decode(envelope["payload"]))
        if image["revision"] != addon["revision"]:
            raise Failure(f"Build run {run_id} built its image from {image['revision']} but its addon "
                          f"from {addon['revision']}. Do not promote it; start a new build.")
        return addon["version"], image["revision"]

    def release(self, revision):
        login = self.run(["gh", "api", "user", "--jq", ".login"]).strip()
        if login != MAINTAINER:
            raise Failure(f"gh is signed in as {login}. Only {MAINTAINER} starts releases.")
        requested = self.run(["gh", "api", f"repos/{REPOSITORY}/commits/{revision}", "--jq", ".sha"]).strip() \
            if revision else None
        build_id, build_url = self.dispatch(BUILD, {"revision": requested} if requested else {})
        self.say(f"Release build run {build_id}: {build_url}")
        self.say("Approve release-signing, then production, in the browser.")
        build = self.watch(build_id)
        if build["conclusion"] != "success":
            raise Failure(f"Release build run {build_id} ended with {build['conclusion']}: {build_url}\n"
                          "Read the failed job, fix the cause, and start a new build with make release. "
                          "Build runs are never rerun.")
        version, built = self.built(build_id)
        # Without a revision the build takes the commit main pointed at when it started.
        expected = requested or build["head_sha"]
        if built != expected:
            raise Failure(f"Build run {build_id} built {built}, not {expected} as requested. Do not promote it.")
        self.say(f"\nBuild run {build_id} built Goldbook {version} from revision {built}.")
        artifacts = self.api(f"repos/{REPOSITORY}/actions/runs/{build_id}/artifacts?per_page=100")["artifacts"]
        for artifact in sorted(artifacts, key=lambda a: a["name"]):
            self.say(f"  {artifact['name']}  ID {artifact['id']}  {artifact.get('digest')}")
        answer = self.ask(f"Promote build run {build_id} (version {version}, revision {built})? [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            self.say(f"Not promoted. To promote this build later, run:\n  {promote_command(build_id)}")
            return
        promote_id, promote_url = self.dispatch(PROMOTE, {"build_run_id": build_id})
        self.say(f"Release promote run {promote_id}: {promote_url}")
        self.say("Approve production for server and for publish, then addon-mirror, "
                 "then curseforge in jkc-be/goldbook-addon.")
        conclusion = self.watch(promote_id)["conclusion"]
        if conclusion != "success":
            raise Failure(f"Release promote run {promote_id} ended with {conclusion}: {promote_url}\n"
                          "Fix the cause, then finish the release by promoting the same build again:\n"
                          f"  {promote_command(build_id)}\n"
                          "A second promotion skips what is already done. Do not use Re-run failed jobs.")
        self.say(f"Released Goldbook {version} from {built}.")


def main(argv=None, release=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--revision", help="Commit of main to build, as a full or abbreviated SHA")
    args = parser.parse_args(argv)
    if args.revision is not None and not REVISION.fullmatch(args.revision):
        parser.error(f"--revision {args.revision!r} is not a commit SHA")
    try:
        (release or Release()).release(args.revision)
    except Failure as error:
        print(error, file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("\nStopped. Runs already started continue on GitHub.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
