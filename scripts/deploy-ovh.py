#!/usr/bin/env python3
"""Forced SSH command for Goldbook's GitHub Actions deployment key."""

import base64
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import shutil
import sqlite3
import urllib.request
import zipfile
from datetime import datetime, timezone

ROOT = Path("/opt/goldbook")
REPOSITORY = "ghcr.io/jkc-be/goldbook-server"
GITHUB_REPOSITORY = "jkc-be/goldbook"
DEPLOY_WORKFLOWS = (".github/workflows/deploy.yml", ".github/workflows/release-build.yml")
# The manifests each feed workflow must publish, in publication order.
FEED_MANIFESTS = {
    ".github/workflows/release-desktop.yml": ("latest.json",),
    ".github/workflows/update-addon.yml": ("addon.json",),
    ".github/workflows/release-build.yml": ("latest.json", "addon.json"),
}


class ArtifactRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, *args, **kwargs):
        redirected = super().redirect_request(request, *args, **kwargs)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


OPENER = urllib.request.build_opener(ArtifactRedirect())


def atomic_write(path, text):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
            os.chmod(temporary, path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def built_image(run_id, revision, token):
    """Returns the image, by digest, that the run built for the revision."""
    with tempfile.TemporaryDirectory(prefix="goldbook-image-") as temporary:
        archive = Path(temporary) / "image.zip"
        download_artifact(run_id, "Goldbook-server-image", token, archive)
        with zipfile.ZipFile(archive) as bundle:
            if bundle.namelist() != ["image.json"] or bundle.getinfo("image.json").file_size > 4096:
                raise RuntimeError(f"Run {run_id}'s Goldbook-server-image artifact must hold only image.json")
            record = json.loads(bundle.read("image.json"))
    if not isinstance(record, dict) or record.keys() != {"revision", "digest"}:
        raise RuntimeError(f"Run {run_id}'s image.json must hold exactly a revision and a digest")
    if record["revision"] != revision:
        raise RuntimeError(f"Run {run_id}'s image.json is for revision {record['revision']}, not {revision}")
    if not isinstance(record["digest"], str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", record["digest"]):
        raise RuntimeError(f"Run {run_id}'s image.json has an invalid digest")
    return REPOSITORY + "@" + record["digest"]


def deploy(run_id, revision, token, verify_only=False):
    image = built_image(run_id, revision, token)
    with tempfile.TemporaryDirectory(prefix="goldbook-registry-") as docker_config:
        env = dict(os.environ, DOCKER_CONFIG=docker_config)

        def run(*args, capture=False, **kwargs):
            return subprocess.run(args, env=env, text=True, check=True,
                                  capture_output=capture, **kwargs)

        def inspect(*args):
            return run("docker", "inspect", *args, capture=True).stdout.strip()

        run("docker", "login", "ghcr.io", "--username", "jkc-be",
            "--password-stdin", input=token, timeout=60)
        run("docker", "pull", image, timeout=300)
        metadata = json.loads(inspect(image))[0]
        if metadata["Config"].get("Labels", {}).get("org.opencontainers.image.revision") != revision:
            raise RuntimeError("Image revision does not match requested commit")

        path = ROOT / ".env"
        original = path.read_text()
        matches = re.findall(r"^GOLDBOOK_IMAGE=(.*)$", original, re.MULTILINE)
        if len(matches) > 1:
            raise RuntimeError("Expected at most one GOLDBOOK_IMAGE setting")
        previous = matches[0].strip().strip("\"'") if matches else "goldbook"
        compose = ["docker", "compose", "-p", "goldbook", "--env-file", str(path),
                   "-f", str(ROOT / "app/server/compose.yaml")]
        if re.search(r"^GOLDBOOK_HOST=\S+", original, re.MULTILINE):
            compose += ["-f", str(ROOT / "app/server/compose.traefik.yaml")]
            if re.search(r"^GOLDBOOK_PATH_HOST=\S+", original, re.MULTILINE):
                compose += ["-f", str(ROOT / "app/server/compose.path.yaml")]
        container = run(*compose, "ps", "-q", "goldbook", capture=True).stdout.strip()
        if not container or "\n" in container:
            raise RuntimeError("Expected one running Goldbook container")
        if inspect(container, "--format", "{{.Config.Image}}") != previous:
            raise RuntimeError("Running image differs from configured image; reconcile before deployment")
        try:
            run("docker", "image", "inspect", previous, capture=True)
        except subprocess.CalledProcessError:
            # The running image may have lost its digest name (for example after
            # a prune of old tags); rollback needs it, so fetch it again.
            if not previous.startswith(REPOSITORY + "@sha256:"):
                raise
            run("docker", "pull", previous, timeout=300)
            run("docker", "image", "inspect", previous, capture=True)

        if verify_only:
            if inspect(container, "--format", "{{.State.Health.Status}}") != "healthy":
                raise RuntimeError("Goldbook is not healthy")
            print(json.dumps({"verified_revision": revision, "active_image": previous,
                              "health": "healthy", "service_changed": False}), flush=True)
            return

        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        database = ROOT / "data/goldbook.sqlite"
        if not database.is_file():
            raise RuntimeError(f"Expected the database at {database}")
        database_backup = ROOT / "backups" / f"goldbook-{stamp}-{revision}.sqlite"
        os.close(os.open(database_backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        source = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
        copy = sqlite3.connect(database_backup)
        try:
            source.backup(copy)
            integrity = copy.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            source.close()
            copy.close()
        if integrity != "ok":
            raise RuntimeError(f"Database backup {database_backup} failed its integrity check: {integrity}")

        backup = path.with_name(f".env.before-{stamp}-{revision[:12]}")
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as output:
            output.write(original)
        if matches:
            updated = re.sub(r"^GOLDBOOK_IMAGE=.*$", "GOLDBOOK_IMAGE=" + image,
                             original, flags=re.MULTILINE)
        else:
            updated = original.rstrip("\n") + "\nGOLDBOOK_IMAGE=" + image + "\n"
        if path.read_text() != original:
            raise RuntimeError("Deployment configuration changed during preparation")

        start = [*compose, "up", "-d", "--no-deps", "--no-build", "--pull", "never",
                 "--wait", "--wait-timeout", "120", "goldbook"]
        atomic_write(path, updated)
        try:
            configured = run(*compose, "config", "--images", capture=True).stdout.strip()
            if configured != image:
                raise RuntimeError("Compose must use GOLDBOOK_IMAGE for its image")
            run(*start, timeout=180)
            container = run(*compose, "ps", "-q", "goldbook", capture=True).stdout.strip()
            if inspect(container, "--format", "{{.State.Health.Status}}") != "healthy":
                raise RuntimeError("Goldbook is not healthy")
            if inspect(container, "--format", "{{.Config.Image}}") != image:
                raise RuntimeError("Unexpected active image")
        except Exception:
            print("Deployment failed; restoring previous image", flush=True)
            atomic_write(path, original)
            run(*start, timeout=180)
            raise
        print(json.dumps({"revision": revision, "active_image": image,
                          "previous_image": previous, "health": "healthy",
                          "rollback_config": str(backup),
                          "database_backup": str(database_backup)}), flush=True)


def github_request(path, token):
    api = "https://api.github.com/repos/" + GITHUB_REPOSITORY
    return OPENER.open(urllib.request.Request(api + path, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"}), timeout=120)


def verify_run(run_id, revision, token, workflows):
    with github_request(f"/actions/runs/{run_id}", token) as response:
        run = json.load(response)
    workflow = run["path"].split("@", 1)[0]
    if (run["head_sha"] != revision or run["head_branch"] != "main"
            or workflow not in workflows
            or run["repository"]["full_name"] != GITHUB_REPOSITORY
            or run["head_repository"]["full_name"] != GITHUB_REPOSITORY
            or run["actor"]["id"] != 156444954 or run["triggering_actor"]["id"] != 156444954
            or run["event"] not in ("workflow_dispatch", "push")):
        raise RuntimeError("Only a maintainer Goldbook workflow on main can deploy or publish")
    return workflow


def download_artifact(run_id, name, token, archive):
    with github_request(f"/actions/runs/{run_id}/artifacts", token) as response:
        artifacts = json.load(response)["artifacts"]
    matches = [a for a in artifacts if a["name"] == name and not a["expired"]]
    if len(matches) != 1:
        raise RuntimeError(f"Run {run_id} has {len(matches)} unexpired {name} artifacts; expected exactly one")
    with github_request(f"/actions/artifacts/{matches[0]['id']}/zip", token) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)


def feed_order(name, text):
    """Returns how a manifest sorts against another: by client version or addon sequence."""
    if name == "latest.json":
        version = json.loads(text)["version"]
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError(version)
        return tuple(map(int, version.split("."))), "version " + version
    sequence = json.loads(base64.b64decode(json.loads(text)["payload"], validate=True))["sequence"]
    if type(sequence) is not int:
        raise ValueError(sequence)
    return sequence, f"sequence {sequence}"


def publish_updates(run_id, revision, token, check_only=False):
    workflow = verify_run(run_id, revision, token, tuple(FEED_MANIFESTS))
    manifests = FEED_MANIFESTS[workflow]
    destination = ROOT / "data/updates"
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="goldbook-publish-", dir=destination.parent) as temporary:
        archive = Path(temporary) / "feed.zip"
        download_artifact(run_id, "Goldbook-update-feed", token, archive)
        staged = Path(temporary) / "feed"
        staged.mkdir()
        with zipfile.ZipFile(archive) as bundle:
            if sum(entry.file_size for entry in bundle.infolist()) > 1024 * 1024 * 1024:
                raise RuntimeError("Update feed exceeds 1 GiB")
            for entry in bundle.infolist():
                if entry.is_dir():
                    continue
                name = entry.filename
                if name not in ("latest.json", "addon.json") and not re.fullmatch(revision + r"/[A-Za-z0-9_.+-]+", name):
                    raise RuntimeError("Invalid update artifact path")
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(entry) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
        missing = [name for name in manifests if not (staged / name).is_file()]
        if missing:
            raise RuntimeError("Update feed is missing " + ", ".join(missing))
        package_dir = staged / revision
        existing = destination / revision
        if "latest.json" in manifests:
            manifest = json.loads((staged / "latest.json").read_text())
            for platform in manifest["platforms"].values():
                prefix = "https://app.jkc-be.com/goldbook/updates/" + revision + "/"
                if not platform["url"].startswith(prefix) or not platform["signature"]:
                    raise RuntimeError("Invalid update download URL or signature")
                if not (package_dir / platform["url"].removeprefix(prefix)).is_file():
                    raise RuntimeError("Update package is missing")
            # A retry must publish the same immutable files.
            if existing.exists() and ({p.name: p.read_bytes() for p in existing.iterdir()}
                                      != {p.name: p.read_bytes() for p in package_dir.iterdir()}):
                raise RuntimeError("This revision already has different update packages")
        # A stale promotion must not replace a newer feed; a retry republishes the same one.
        for name in manifests:
            try:
                staged_order, staged_label = feed_order(name, (staged / name).read_bytes())
            except (ValueError, KeyError, TypeError) as error:
                raise RuntimeError(f"Update feed has an invalid {name}") from error
            try:
                published_order, published_label = feed_order(name, (destination / name).read_bytes())
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if staged_order < published_order:
                raise RuntimeError(f"{name} has {staged_label}, older than the published {published_label}")
        if check_only:
            print(json.dumps({"checked": list(manifests), "revision": revision}), flush=True)
            return
        if "latest.json" in manifests and not existing.exists():
            os.rename(package_dir, existing)
        # Publish the manifests last; clients never see a partially copied package.
        for name in manifests:
            os.replace(staged / name, destination / name)
    print(json.dumps({"published": list(manifests), "revision": revision}), flush=True)


def main():
    command = re.fullmatch(r"(deploy|verify|publish|check-publish) ([0-9]+) ([0-9a-f]{40})",
                           os.environ.get("SSH_ORIGINAL_COMMAND", ""))
    if command is None:
        raise SystemExit("Only 'deploy <run ID> <SHA>', 'verify <run ID> <SHA>', 'publish <run ID> <SHA>', "
                         "or 'check-publish <run ID> <SHA>' is permitted")
    token = sys.stdin.read(16385).strip()
    if not token or len(token) > 16384 or any(character.isspace() for character in token):
        raise SystemExit("Expected a registry token on standard input")
    updates = command[1] in ("publish", "check-publish")
    with open(ROOT / (".updates.lock" if updates else ".deploy.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if updates else fcntl.LOCK_NB))
        if updates:
            publish_updates(command[2], command[3], token, check_only=command[1] == "check-publish")
        else:
            verify_run(command[2], command[3], token, DEPLOY_WORKFLOWS)
            deploy(command[2], command[3], token, verify_only=command[1] == "verify")


if __name__ == "__main__":
    main()
