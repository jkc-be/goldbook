#!/usr/bin/env python3
"""Read Goldbook's release outputs and decide whether a build may create or finish them.

    release-state.py version [--source DIR]
    release-state.py state --version X --revision SHA (--build | --feed DIR)
    release-state.py check-feed --feed DIR --version X --revision SHA
    release-state.py check-build-run --run-id N
    release-state.py wait-addon-release --commit SHA

`state` reports each release output as `absent`, `matches` or `conflict`.
A new build (`--build`) may start only when every output is absent. A
promotion (`--feed`, the build run's `Goldbook-update-feed`) may continue
when no output conflicts. The server deploy is not an output here: deploying
the same image again is harmless, so nothing reads it (docs/releasing.md).

goldbook-addon and the public feed are read without credentials, because the
workflow token only reaches its own repository. GH_TOKEN, when set, is used
only for this repository's Actions runs and artifacts.
"""
import argparse
import base64
from dataclasses import dataclass
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

REPOSITORY = "jkc-be/goldbook"
ADDON_REPOSITORY = "jkc-be/goldbook-addon"
API = "https://api.github.com"
FEED = "https://app.jkc-be.com/goldbook/updates"
MAINTAINER_ID = 156444954
BUILD_WORKFLOW = ".github/workflows/release-build.yml"
ADDON_WORKFLOW = "release.yml"
# The artifacts a promotion depends on, as release-build.yml names them.
BUILD_ARTIFACTS = ("Goldbook-update-feed", "Goldbook-addon-feed", "Goldbook-updater-macOS-ARM64",
                   "Goldbook-updater-Windows-X64", "Goldbook-updater-Linux-X64", "Goldbook-server-image")
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
REVISION = re.compile(r"[0-9a-f]{40}")


class Failure(Exception):
    """A refusal with a message for the operator."""


# Network. Kept thin so tests replace it with a dictionary of URLs.

class _DropAuthorizationOnRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, *args, **kwargs):
        redirected = super().redirect_request(request, *args, **kwargs)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


class Http:
    """GET requests. Returns None for 404 and raises for any other error."""

    def __init__(self, token=None):
        self.token = token
        self.opener = urllib.request.build_opener(_DropAuthorizationOnRedirect())

    def get(self, url, raw=False, authenticated=False):
        headers = {"Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "Cache-Control": "no-cache",
                   "User-Agent": "goldbook-release-state"}
        if authenticated:
            if not self.token:
                raise Failure(f"GH_TOKEN is required to read {url}")
            headers["Authorization"] = "Bearer " + self.token
        try:
            with self.opener.open(urllib.request.Request(url, headers=headers), timeout=120) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            limit = error.headers.get("X-RateLimit-Remaining")
            hint = " (GitHub rate limit reached; rerun later)" if limit == "0" else ""
            raise Failure(f"GET {url} failed with HTTP {error.code}{hint}") from None
        except urllib.error.URLError as error:
            raise Failure(f"GET {url} failed: {error.reason}") from None


def get_json(http, url, authenticated=False):
    body = http.get(url, authenticated=authenticated)
    return None if body is None else json.loads(body)


# What each output holds and how a build is compared with it.

@dataclass(frozen=True)
class Found:
    """An output that exists. `version` is the release it belongs to, `revision`
    the goldbook commit it names, and `content` its bytes when compared byte for byte."""
    version: str
    revision: str | None
    detail: str
    content: bytes | None = None


@dataclass(frozen=True)
class Build:
    """What is being released. `feed` holds the build run's manifests, or is
    None for a build that has not run yet."""
    version: str
    revision: str
    feed: dict | None = None


@dataclass(frozen=True)
class Verdict:
    state: str
    reason: str = ""

    def __str__(self):
        return self.state + (f" ({self.reason})" if self.reason else "")


def short(revision):
    return (revision or "no revision")[:12]


def addon_payload(content):
    return json.loads(base64.b64decode(json.loads(content)["payload"]))


def read_client_feed(http, version):
    content = http.get(FEED + "/latest.json")
    if content is None:
        return None
    manifest = json.loads(content)
    urls = [platform["url"] for platform in manifest.get("platforms", {}).values()]
    revisions = {url.removeprefix(FEED + "/").split("/", 1)[0] for url in urls}
    revision = revisions.pop() if len(revisions) == 1 else None
    return Found(manifest["version"], revision,
                 f"latest.json publishes {manifest['version']} from {short(revision)}", content)


def read_addon_feed(http, version):
    content = http.get(FEED + "/addon.json")
    if content is None:
        return None
    payload = addon_payload(content)
    return Found(payload["version"], payload.get("revision"),
                 f"addon.json publishes {payload['version']} from {short(payload.get('revision'))}", content)


def addon_upstream(http, commit):
    """The goldbook revision a goldbook-addon commit was mirrored from."""
    body = http.get(f"{API}/repos/{ADDON_REPOSITORY}/contents/upstream.json?ref={commit}", raw=True)
    if body is None:
        return None
    upstream = json.loads(body)
    return upstream.get("revision") if upstream.get("repository") == REPOSITORY else None


def read_addon_mirror(http, version):
    head = get_json(http, f"{API}/repos/{ADDON_REPOSITORY}/commits/main")
    if head is None:
        return None
    commit = head["sha"]
    toc = http.get(f"{API}/repos/{ADDON_REPOSITORY}/contents/Goldbook/Goldbook.toc?ref={commit}", raw=True)
    found = re.search(r"^## Version: (\S+)\s*$", (toc or b"").decode(), re.MULTILINE)
    mirrored = found[1] if found else "an unknown version"
    revision = addon_upstream(http, commit)
    return Found(mirrored, revision,
                 f"goldbook-addon HEAD {short(commit)} holds {mirrored} from {short(revision)}")


def tag_commit(http, repository, tag):
    ref = get_json(http, f"{API}/repos/{repository}/git/ref/tags/{tag}")
    if ref is None:
        return None
    target = ref["object"]
    while target["type"] == "tag":
        target = get_json(http, f"{API}/repos/{repository}/git/tags/{target['sha']}")["object"]
    return target["sha"]


def read_addon_release(http, version):
    if get_json(http, f"{API}/repos/{ADDON_REPOSITORY}/releases/tags/v{version}") is None:
        return None
    commit = tag_commit(http, ADDON_REPOSITORY, f"v{version}")
    revision = addon_upstream(http, commit) if commit else None
    return Found(version, revision,
                 f"goldbook-addon release v{version} was built from {short(commit)}, mirrored from {short(revision)}")


def read_source_tag(http, version):
    commit = tag_commit(http, REPOSITORY, f"v{version}")
    if commit is None:
        return None
    return Found(version, commit, f"tag v{version} points at {short(commit)}")


@dataclass(frozen=True)
class Output:
    name: str
    read: object
    file: str | None = None  # compared byte for byte with this feed file, otherwise by revision

    def expected(self, build):
        if self.file is None:
            return build.revision
        return None if build.feed is None else build.feed.get(self.file)


# Appendix A of the release plan, in promotion order.
OUTPUTS = (
    Output("client-feed", read_client_feed, "latest.json"),
    Output("addon-feed", read_addon_feed, "addon.json"),
    Output("addon-mirror", read_addon_mirror),
    Output("addon-release", read_addon_release),
    Output("source-tag", read_source_tag),
)


def version_key(version):
    return tuple(int(part) for part in version.split(".")) if VERSION.fullmatch(version or "") else None


def judge(output, found, build):
    """Compares one output with the build. An older release in the output's
    place is not this release's output, so it counts as absent."""
    if found is None:
        return Verdict("absent")
    expected = output.expected(build)
    actual = found.revision if output.file is None else found.content
    if expected is not None and actual == expected and found.version == build.version:
        return Verdict("matches")
    published, wanted = version_key(found.version), version_key(build.version)
    if published is not None and published < wanted:
        return Verdict("absent", f"{found.detail}, an older release")
    if published is None:
        return Verdict("conflict", f"{found.detail}, which is not a release version")
    if published > wanted:
        return Verdict("conflict", f"{found.detail}, newer than {build.version}")
    if expected is None:
        return Verdict("conflict", f"{found.detail}; this version is already published")
    if output.file is None:
        return Verdict("conflict", f"{found.detail}, not {short(build.revision)}")
    return Verdict("conflict", f"{found.detail}, which differs from this build's {output.file}")


def observe(http, version):
    return {output.name: output.read(http, version) for output in OUTPUTS}


def evaluate(build, observed):
    return {output.name: judge(output, observed[output.name], build) for output in OUTPUTS}


def may_build(verdicts):
    return all(verdict.state == "absent" for verdict in verdicts.values())


def may_promote(verdicts):
    return all(verdict.state != "conflict" for verdict in verdicts.values())


# Build runs of this repository.

def build_run_problems(run, artifacts):
    """Why a workflow run cannot be promoted; empty when it can."""
    problems = []
    if run["path"].split("@", 1)[0] != BUILD_WORKFLOW:
        problems.append(f"it is a run of {run['path']}, not {BUILD_WORKFLOW}")
    if run["repository"]["full_name"] != REPOSITORY or run["head_repository"]["full_name"] != REPOSITORY:
        problems.append(f"it did not run on {REPOSITORY}")
    if run["head_branch"] != "main" or run["event"] != "workflow_dispatch":
        problems.append("it was not started by hand on main")
    if run["actor"]["id"] != MAINTAINER_ID or run["triggering_actor"]["id"] != MAINTAINER_ID:
        problems.append("it was not started by jkc-be")
    if run["status"] != "completed" or run["conclusion"] != "success":
        problems.append(f"it is {run['status']} with conclusion {run['conclusion']}, not a success")
    if run["run_attempt"] != 1:
        problems.append(f"it is attempt {run['run_attempt']}; build runs are never rerun")
    for name in BUILD_ARTIFACTS:
        count = sum(1 for artifact in artifacts if artifact["name"] == name and not artifact["expired"])
        if count != 1:
            problems.append(f"it has {count} unexpired {name} artifacts, not 1")
    return problems


def load_build_run(http, run_id):
    run = get_json(http, f"{API}/repos/{REPOSITORY}/actions/runs/{run_id}", authenticated=True)
    if run is None:
        raise Failure(f"Build run {run_id} does not exist in {REPOSITORY}")
    listing = get_json(http, f"{API}/repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?per_page=100",
                       authenticated=True)
    return run, listing["artifacts"]


def download_feed(http, artifacts):
    """The manifests of a build run's Goldbook-update-feed artifact."""
    artifact, = [a for a in artifacts if a["name"] == "Goldbook-update-feed" and not a["expired"]]
    archive = http.get(f"{API}/repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip", authenticated=True)
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        names = set(bundle.namelist())
        return {name: bundle.read(name) for name in ("latest.json", "addon.json") if name in names}


def find_promotable_run(http, version, observed):
    """The build run whose promotion would finish the release already started
    for `version`, as (run, verdicts), or None."""
    revisions = []
    for found in observed.values():
        if found and found.version == version and found.revision and found.revision not in revisions:
            revisions.append(found.revision)
    for revision in revisions:
        listing = get_json(http, f"{API}/repos/{REPOSITORY}/actions/workflows/release-build.yml/runs"
                                 f"?head_sha={revision}&status=success&per_page=100", authenticated=True)
        for run in sorted((listing or {}).get("workflow_runs", []), key=lambda r: r["id"], reverse=True):
            run, artifacts = load_build_run(http, run["id"])
            if build_run_problems(run, artifacts):
                continue
            verdicts = evaluate(Build(version, revision, download_feed(http, artifacts)), observed)
            if may_promote(verdicts):
                return run, verdicts
    return None


# The downstream addon release in goldbook-addon.

def downstream_verdict(runs, read_jobs):
    """Whether goldbook-addon's Package addon release finished for a mirror
    commit: ('success' | 'pending' | 'failure', message)."""
    for run in sorted(runs, key=lambda r: r["id"], reverse=True):
        # A successful run ended with CurseForge uploaded or already recorded.
        # Its package job must have run, in this or an earlier attempt, rather
        # than been skipped by the job's actor condition.
        if run["status"] == "completed" and run["conclusion"] == "success":
            if any(job["name"] == "package" and job["conclusion"] == "success" for job in read_jobs(run["id"])):
                return "success", f"Package addon release succeeded: {run['html_url']}"
    if not runs:
        return "pending", "Package addon release has not started for this commit yet"
    active = [run for run in runs if run["status"] != "completed"]
    if active:
        newest = max(active, key=lambda r: r["id"])
        return "pending", f"Package addon release is {newest['status']}: {newest['html_url']}"
    newest = max(runs, key=lambda r: r["id"])
    return "failure", (f"Package addon release ended with {newest['conclusion']}: {newest['html_url']}. "
                       "Rerun it in goldbook-addon, then re-run all jobs of this promote run or start a new one.")


def wait_for_addon_release(http, commit, interval, timeout, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + timeout
    while True:
        listing = get_json(http, f"{API}/repos/{ADDON_REPOSITORY}/actions/workflows/{ADDON_WORKFLOW}/runs"
                                 f"?head_sha={commit}&per_page=100")
        runs = listing["workflow_runs"] if listing else []
        state, message = downstream_verdict(
            runs, lambda run_id: get_json(http, f"{API}/repos/{ADDON_REPOSITORY}/actions/runs/{run_id}/jobs?filter=all")["jobs"])
        print(message, flush=True)
        if state == "success":
            return message
        if state == "failure":
            raise Failure(message)
        if clock() + interval > deadline:
            raise Failure(f"Package addon release did not finish within {timeout // 60} minutes for {commit}")
        sleep(interval)


# The version, the feed and the command line.

def read_version(source):
    """The version at `source`, after set-version.py --check confirms every field agrees."""
    # Absolute, because the check runs with `source` as its working directory.
    source = source.resolve()
    check = subprocess.run([sys.executable, str(source / "scripts/set-version.py"), "--check"],
                           cwd=source, text=True, capture_output=True)
    if check.returncode != 0:
        raise Failure("set-version.py --check failed:\n" + check.stdout + check.stderr)
    version = json.loads((source / "desktop/src-tauri/tauri.conf.json").read_text())["version"]
    if not VERSION.fullmatch(version):
        raise Failure(f"tauri.conf.json has no release version: {version!r}")
    if not re.search(rf"(?<![0-9.]){re.escape(version)}(?![0-9.])", check.stdout):
        raise Failure(f"set-version.py --check did not report {version}: {check.stdout.strip()}")
    return version


def feed_problems(feed, version, revision):
    """Why an update-feed folder is not a complete release of `version` at `revision`."""
    problems = []
    files = {path.relative_to(feed).as_posix() for path in feed.rglob("*") if path.is_file()}
    for name in ("latest.json", "addon.json"):
        if name not in files:
            problems.append(f"{name} is missing")
    stray = sorted(name for name in files - {"latest.json", "addon.json"}
                   if not name.startswith(revision + "/") or name.count("/") != 1)
    if stray:
        problems.append("unexpected files: " + ", ".join(stray))
    if "latest.json" in files:
        manifest = json.loads((feed / "latest.json").read_text())
        if manifest.get("version") != version:
            problems.append(f"latest.json has version {manifest.get('version')}, not {version}")
        for target, platform in manifest.get("platforms", {}).items():
            name = platform["url"].removeprefix(f"{FEED}/{revision}/")
            if name == platform["url"] or f"{revision}/{name}" not in files:
                problems.append(f"latest.json {target} points at {platform['url']}, which is not in the feed")
    if "addon.json" in files:
        payload = addon_payload((feed / "addon.json").read_bytes())
        if payload.get("version") != version or payload.get("revision") != revision:
            problems.append(f"addon.json holds {payload.get('version')} from {payload.get('revision')}, "
                            f"not {version} from {revision}")
    return problems


def summary(text):
    print(text, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(text + "\n")


def outputs(**values):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.writelines(f"{key}={value}\n" for key, value in values.items())


def command_state(http, args):
    feed = None
    if args.feed:
        feed = {name: (args.feed / name).read_bytes() for name in ("latest.json", "addon.json")}
    build = Build(args.version, args.revision, feed)
    observed = observe(http, args.version)
    verdicts = evaluate(build, observed)
    summary(f"Release outputs for {args.version} at `{args.revision}`:\n")
    summary("\n".join(f"- {name}: {verdict}" for name, verdict in verdicts.items()) + "\n")
    if feed is not None:
        if not may_promote(verdicts):
            raise Failure("An output belongs to another build. Decide what to do before promoting.")
        summary("Every output is absent or belongs to this build; the promotion may continue.")
        # The feed is published only after this build's server deploy succeeded,
        # so a published feed means the server step is done. Deploying again could
        # replace a later server-only deploy with this older image.
        deployed = verdicts["client-feed"].state == "matches"
        if deployed:
            summary("This build's latest.json is published, so its server deploy already succeeded and is skipped.")
        outputs(deploy_server=str(not deployed).lower())
        return
    if may_build(verdicts):
        summary(f"Nothing of {args.version} is released yet; the build may start.")
        return
    wanted = version_key(args.version)
    if any(found and (version_key(found.version) or wanted) > wanted for found in observed.values()):
        raise Failure(f"A newer version than {args.version} is already released. Prepare a higher version.")
    if not http.token:
        raise Failure(f"{args.version} is already partly released. Set GH_TOKEN to find the build run to promote.")
    promotable = find_promotable_run(http, args.version, observed)
    if promotable is None:
        raise Failure(f"{args.version} is already partly released and no build run that can finish it was found; "
                      "its artifacts may have expired. Prepare a new version.")
    run, run_verdicts = promotable
    if all(verdict.state == "matches" for verdict in run_verdicts.values()):
        raise Failure(f"{args.version} is already released by build run {run['id']} ({run['html_url']}). "
                      "Prepare a new version for a new release.")
    raise Failure(f"{args.version} is already partly released. Run Release promote with build run "
                  f"{run['id']} ({run['html_url']}) to finish it; build runs are never repeated.")


def command_check_build_run(http, args):
    run, artifacts = load_build_run(http, args.run_id)
    problems = build_run_problems(run, artifacts)
    if problems:
        raise Failure(f"Build run {args.run_id} cannot be promoted: " + "; ".join(problems) + ".")
    summary(f"Promoting build run [{run['id']}]({run['html_url']}) of revision `{run['head_sha']}`.\n")
    summary("| Artifact | ID | Digest |\n| --- | --- | --- |")
    summary("\n".join(f"| {a['name']} | {a['id']} | `{a.get('digest')}` |"
                      for a in sorted(artifacts, key=lambda a: a["name"]) if not a["expired"]) + "\n")
    outputs(revision=run["head_sha"])


def main(argv=None, http=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("version", help="Print the checked-out version")
    version.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    state = commands.add_parser("state", help="Report each release output")
    state.add_argument("--version", required=True)
    state.add_argument("--revision", required=True)
    mode = state.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build", action="store_true", help="Judge a build that has not run yet")
    mode.add_argument("--feed", type=Path, help="The build run's Goldbook-update-feed folder")
    feed = commands.add_parser("check-feed", help="Check an update-feed folder before it is uploaded")
    feed.add_argument("--feed", type=Path, required=True)
    feed.add_argument("--version", required=True)
    feed.add_argument("--revision", required=True)
    build_run = commands.add_parser("check-build-run", help="Check that a build run can be promoted")
    build_run.add_argument("--run-id", required=True)
    wait = commands.add_parser("wait-addon-release", help="Wait for goldbook-addon to release a mirror commit")
    wait.add_argument("--commit", required=True)
    wait.add_argument("--interval", type=int, default=180)
    wait.add_argument("--timeout", type=int, default=7200)
    args = parser.parse_args(argv)
    for name, pattern in (("version", VERSION), ("revision", REVISION), ("commit", REVISION)):
        if isinstance(getattr(args, name, None), str) and not pattern.fullmatch(getattr(args, name)):
            parser.error(f"--{name} {getattr(args, name)!r} is not valid")
    if getattr(args, "run_id", None) is not None and not args.run_id.isdigit():
        parser.error(f"--run-id {args.run_id!r} is not a run ID")
    http = http or Http(os.environ.get("GH_TOKEN") or None)
    try:
        if args.command == "version":
            version = read_version(args.source)
            print(version)
            outputs(version=version)
        elif args.command == "state":
            command_state(http, args)
        elif args.command == "check-feed":
            problems = feed_problems(args.feed, args.version, args.revision)
            if problems:
                raise Failure("The update feed is incomplete: " + "; ".join(problems) + ".")
            print(f"The update feed holds {args.version} from {args.revision}.")
        elif args.command == "check-build-run":
            command_check_build_run(http, args)
        else:
            wait_for_addon_release(http, args.commit, args.interval, args.timeout)
    except Failure as error:
        print(f"::error::{error}" if os.environ.get("GITHUB_ACTIONS") else str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
