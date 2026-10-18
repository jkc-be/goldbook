#!/usr/bin/env python3
"""Check a pull request against the change file, version and changelog rules.

    BASE_SHA=<base commit> LABELS='["no-changes"]' python3 scripts/check-changes.py

Compares HEAD with the commit where it left BASE_SHA, so what main gained since
does not count. See changes/README.md for the rules.

- Change file rule: a pull request that touches a product folder adds a
  well-formed change file. The no-changes label waives this rule only.
- Version rule: only a release pull request changes a field that
  set-version.py writes.
- Changelog rule: only a release pull request edits the version sections of
  CHANGELOG.md. Others may reword its introduction, which holds no sections.
- Release rule: a pull request with the release label is what
  make prepare-release produces. It sets a higher version in every field,
  adds that version's CHANGELOG.md section, deletes every change file, and
  changes nothing else.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load("prepare_release", "scripts/prepare-release.py")
SET_VERSION = load("set_version", "scripts/set-version.py")
PRODUCT = ("addon/", "desktop/", "web/", "crates/", "server/")
TAURI = "desktop/src-tauri/tauri.conf.json"
VERSIONED = sorted({path for path, _ in SET_VERSION.FIELDS})
RELEASE_FIX = "To prepare a release, run make prepare-release VERSION=x.y.z on a branch from main and add the release label."


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def show(commit, path):
    """The text of `path` at `commit`, or "" when it does not exist there."""
    result = subprocess.run(["git", "show", f"{commit}:{path}"], cwd=ROOT, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def fields(path, text):
    """Every version field set-version.py writes in `path`, in order."""
    return [text[m.end(1):m.start(2)] for name, pattern in SET_VERSION.FIELDS if name == path
            for m in re.finditer(pattern, text, flags=re.MULTILINE)]


def without_fields(path, text):
    """`text` with each version field replaced, so only the other lines remain to compare."""
    for name, pattern in SET_VERSION.FIELDS:
        if name == path:
            text = re.sub(pattern, lambda m: m.group(1) + "<version>" + m.group(2), text, flags=re.MULTILINE)
    return text


def version(commit):
    found = fields(TAURI, show(commit, TAURI))
    return found[0] if len(found) == 1 else None


def numbers(value):
    return tuple(map(int, value.split(".")))


def version_check():
    """set-version.py --check at the head: (version, None) or (None, its error)."""
    result = subprocess.run([sys.executable, ROOT / "scripts/set-version.py", "--check"],
                            cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        return None, result.stderr.strip()
    return result.stdout.strip(), None


def is_change_file(path):
    return path.startswith("changes/") and path != "changes/README.md"


def change_file_problems(changed):
    changes = [(status, path) for status, path in changed if is_change_file(path)]
    found = [PREPARE.problem(path.removeprefix("changes/"), (ROOT / path).read_text())
             for status, path in changes if status != "D"]
    found = [f"Change file rule: {problem}" for problem in found if problem]
    product = [path for _, path in changed if path.startswith(PRODUCT)]
    if product and not any(status == "A" for status, _ in changes):
        more = f" and {len(product) - 1} more files" if len(product) > 1 else ""
        found.append(f"Change file rule: this pull request changes {product[0]}{more} but adds no change file. "
                     "Add changes/<section>-<slug>.md as changes/README.md describes, "
                     "or the no-changes label if no player or user would notice.")
    return found


def changelog_parts(text):
    """CHANGELOG.md split into its introduction and its version sections."""
    match = re.search(r"^## \d+\.\d+\.\d+ - ", text, flags=re.MULTILINE)
    return (text[:match.start()], text[match.start():]) if match else (text, "")


def ordinary_problems(base, changed):
    found = []
    paths = {path for _, path in changed}
    before, after = version(base), version("HEAD")
    _, error = version_check()
    if before != after:
        found.append(f"Version rule: this pull request changes the version from {before} to {after}, "
                     "but only a release pull request changes it. "
                     f"Restore the version fields from main. {RELEASE_FIX}")
    if error:
        found.append(f"Version rule: {error}. Only a release pull request changes version fields. "
                     f"Restore them from main. {RELEASE_FIX}")
    edited = [path for path in VERSIONED
              if path in paths and fields(path, show(base, path)) != fields(path, show("HEAD", path))]
    if edited and before == after and not error:
        found.append(f"Version rule: this pull request changes the version field in {', '.join(edited)}, "
                     "but only a release pull request changes version fields. "
                     f"Restore them from main. {RELEASE_FIX}")
    if "CHANGELOG.md" in paths:
        introduction, sections = changelog_parts(show("HEAD", "CHANGELOG.md"))
        if sections != changelog_parts(show(base, "CHANGELOG.md"))[1]:
            found.append("Changelog rule: this pull request edits the version sections of CHANGELOG.md, "
                         "but only a release pull request does. Describe the change in a file under changes/ "
                         "instead, as changes/README.md describes. " + RELEASE_FIX)
        elif re.search(r"^## ", introduction, flags=re.MULTILINE):
            found.append("Changelog rule: the introduction of CHANGELOG.md holds no sections. Describe "
                         "unreleased changes in files under changes/, as changes/README.md describes.")
    return found


def release_problems(base, changed):
    found = []
    extra = [path for status, path in changed
             if not (path == "CHANGELOG.md" or path in VERSIONED or (status == "D" and is_change_file(path)))]
    extra += [path for status, path in changed if path in VERSIONED
              and without_fields(path, show(base, path)) != without_fields(path, show("HEAD", path))]
    if extra:
        found.append("Release rule: a release pull request only edits CHANGELOG.md and the version fields "
                     f"and deletes change files, but this one also changes {', '.join(sorted(set(extra)))}. "
                     "Move those changes to their own pull request, and start the release from main "
                     "with make prepare-release VERSION=x.y.z.")
    before = version(base)
    current, error = version_check()
    if error:
        found.append(f"Release rule: {error}. Set every field with make prepare-release VERSION=x.y.z, "
                     "or python3 scripts/set-version.py x.y.z.")
    elif before and numbers(current) <= numbers(before):
        found.append(f"Release rule: a release pull request raises the version above {before}, "
                     f"but this one sets {current}. Run make prepare-release VERSION=x.y.z with a higher version.")
    if current and not re.search(rf"^## {re.escape(current)} - ", show("HEAD", "CHANGELOG.md"), flags=re.MULTILINE):
        found.append(f"Release rule: CHANGELOG.md has no \"## {current} - \" section. "
                     "Add it above the newest release, as make prepare-release does.")
    kept = set(git("ls-tree", "-r", "--name-only", "HEAD", "changes/").splitlines())
    left = sorted(path for path in git("ls-tree", "-r", "--name-only", base, "changes/").splitlines()
                  if is_change_file(path) and path in kept)
    if left:
        found.append(f"Release rule: a release collects every change file, but this pull request keeps "
                     f"{', '.join(left)}. Add its bullets to the new CHANGELOG.md section and delete it, "
                     "as make prepare-release does.")
    return found


def problems(base, labels):
    base = git("merge-base", base, "HEAD").strip()
    diff = git("diff", "--name-status", "--no-renames", base, "HEAD")
    changed = [tuple(line.split("\t", 1)) for line in diff.splitlines()]
    if "release" in labels:
        return release_problems(base, changed)
    found = ordinary_problems(base, changed)
    if "no-changes" not in labels:
        found += change_file_problems(changed)
    return found


def main():
    labels = json.loads(os.environ.get("LABELS") or "[]")
    found = problems(os.environ["BASE_SHA"], labels)
    if found:
        # Actions reads workflow commands from stdout and shows them on the pull request.
        actions = os.environ.get("GITHUB_ACTIONS") == "true"
        for problem in found:
            print("::error::" + problem if actions else problem, file=sys.stdout if actions else sys.stderr)
        sys.exit(1)
    if "release" in labels:
        print(f"This release pull request sets {version_check()[0]}, adds its changelog section "
              "and collects every change file.")
    elif "no-changes" in labels:
        print("The no-changes label is set, so no change file is needed. "
              "The version and the CHANGELOG.md sections are unchanged.")
    else:
        print("Change files are in order. The version and the CHANGELOG.md sections are unchanged.")


if __name__ == "__main__":
    main()
