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
  changes nothing else. A picked release deletes the change files of the
  pull requests it picks, and keeps the others.
- Pick rule: a pull request that merges a picked release into main, as
  make pick-release opens it, ships only commits of main. Its first parent is
  the release commit. Every commit between the last release and it is a clean
  cherry-pick of a commit of main, except the release commit at the end, which
  only edits CHANGELOG.md and the version fields and deletes change files. A
  picked beta has no release commit, and merging it changes nothing on main.
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
PICK_FIX = "Start the release again with make pick-release."
# The line git cherry-pick -x adds to the message.
PICKED = re.compile(r"^\(cherry picked from commit ([0-9a-f]{40})\)$", re.MULTILINE)


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


def is_ancestor(commit, other):
    return subprocess.run(["git", "merge-base", "--is-ancestor", commit, other], cwd=ROOT).returncode == 0


def parents(commit):
    return git("rev-list", "--parents", "-n", "1", commit).split()[1:]


def change_files(commit):
    return {path for path in git("ls-tree", "-r", "--name-only", commit, "changes/").splitlines()
            if is_change_file(path)}


def short(commit):
    return commit[:12]


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


class Picked:
    """A pull request that merges a picked release into main. `release` is its
    first parent, the commit the release builds; `start` is the last release,
    where the release branch left main; `commits` lists each commit between
    them, oldest first, with the commit of main it picks, or None."""

    def __init__(self, release, start, commits):
        self.release, self.start, self.commits = release, start, commits

    @classmethod
    def find(cls, base, release_label):
        """The picked release HEAD merges, or None when HEAD merges none. A merge
        whose first parent main does not hold counts as one when that side holds
        cherry-picks, when the pull request has the release label, or when it
        changes nothing on main. So a release side without picks cannot pass as
        an ordinary release or as a merge that changes nothing."""
        heads = parents("HEAD")
        if len(heads) != 2 or is_ancestor(heads[0], base):
            return None
        release = heads[0]
        start = git("merge-base", release, base).strip()
        commits = []
        for commit in git("rev-list", "--reverse", "--topo-order", f"{start}..{release}").split():
            originals = PICKED.findall(git("log", "-1", "--format=%B", commit))
            commits.append((commit, originals[-1] if originals else None))
        if not (any(original for _, original in commits) or release_label
                or not git("diff", "--name-only", base, "HEAD").strip()):
            return None
        return cls(release, start, commits)

    def bookkeeping(self):
        """The commit the release commits start from: the last pick."""
        picks = [commit for commit, original in self.commits if original]
        return picks[-1] if picks else self.start

    def shipped(self):
        """The change files of the pull requests the release picks."""
        added = git("log", "--format=", "--name-only", "--diff-filter=A",
                    f"{self.start}..{self.release}", "--", "changes/")
        return {path for path in added.split() if is_change_file(path)}


def change_of(commit):
    """What `commit` changes, without context lines, line numbers or blob
    hashes, so a clean cherry-pick compares equal to the commit it picks."""
    diff = git("diff", "-U0", "--binary", "--no-renames", "--no-color", "--no-ext-diff", f"{commit}^", commit)
    return [line for line in diff.splitlines() if not line.startswith(("index ", "@@"))]


def pick_problems(picked, base, release):
    if not any(original for _, original in picked.commits):
        return [f"Pick rule: this pull request merges {short(picked.release)}, but none of its commits since "
                "the last release is a cherry-pick of main. A picked release comes from make pick-release. "
                "A release of all of main is one commit on top of main: rebase it instead of merging main "
                "into it."]
    found = []
    after = None
    for commit, original in picked.commits:
        if len(parents(commit)) != 1:
            found.append(f"Pick rule: {short(commit)} is a merge, but a picked release holds only "
                         f"cherry-picks and its release commit. {PICK_FIX}")
        elif original is None:
            after = after or commit
        elif after:
            found.append(f"Pick rule: {short(commit)} picks {short(original)} after {short(after)}, "
                         f"but the cherry-picks come first and the release commit last. {PICK_FIX}")
        elif not is_ancestor(original, base):
            found.append(f"Pick rule: {short(commit)} picks {short(original)}, which is not a commit "
                         f"of main. {PICK_FIX}")
        elif is_ancestor(original, picked.start):
            found.append(f"Pick rule: {short(commit)} picks {short(original)}, which the last release "
                         f"already holds. {PICK_FIX}")
        elif change_of(commit) != change_of(original):
            found.append(f"Pick rule: {short(commit)} does not change exactly what {short(original)} "
                         f"changes, which it picks. {PICK_FIX}")
    if not release:
        if after:
            found.append(f"Pick rule: a picked beta holds only cherry-picks, but {short(after)} is not one. "
                         f"{PICK_FIX}")
        changed = git("diff", "--name-only", base, "HEAD").split()
        if changed:
            found.append(f"Pick rule: merging a picked beta changes nothing on main, but this pull request "
                         f"changes {', '.join(changed)}. {PICK_FIX}")
    elif after:
        start = picked.bookkeeping()
        diff = git("diff", "--name-status", "--no-renames", start, picked.release)
        edited = [path for status, path in (line.split("\t", 1) for line in diff.splitlines())
                  if not (path == "CHANGELOG.md" or (status == "D" and is_change_file(path))
                          or (path in VERSIONED and without_fields(path, show(start, path))
                              == without_fields(path, show(picked.release, path))))]
        if edited:
            found.append(f"Pick rule: the release commit {short(picked.release)} only edits CHANGELOG.md "
                         f"and the version fields and deletes change files, but it also changes "
                         f"{', '.join(sorted(edited))}. {PICK_FIX}")
    elif release:
        found.append(f"Pick rule: the release label needs a release commit after the cherry-picks, "
                     f"from make prepare-release. {PICK_FIX}")
    return found


def picked_release_problems(picked, base, current):
    """The release rule's change files and version, for a picked release."""
    found = []
    shipped, at_base, at_head = picked.shipped(), change_files(base), change_files("HEAD")
    kept = sorted(shipped & at_head)
    if kept:
        found.append(f"Release rule: the release picks the pull requests of {', '.join(kept)}, but this "
                     "pull request keeps those change files. Delete them, as make pick-release does.")
    foreign = sorted((at_base - at_head) - shipped)
    if foreign:
        found.append(f"Release rule: this pull request deletes {', '.join(foreign)}, but the release does "
                     "not pick their pull requests. Restore them from main.")
    picked_from = picked.bookkeeping()
    edited = sorted(path for path in shipped & at_base if show(base, path) != show(picked_from, path))
    if edited:
        found.append(f"Release rule: main's {', '.join(edited)} differs from the one the release picks, "
                     f"because a later pull request edited it. Pick that pull request too. {PICK_FIX}")
    released = sorted(shipped - at_base)
    if released:
        found.append(f"Release rule: the release ships {', '.join(released)}, which main no longer holds "
                     f"because an earlier release shipped them. {PICK_FIX}")
    left = sorted(change_files(picked.release))
    if left:
        found.append(f"Release rule: the release commit {short(picked.release)} still holds "
                     f"{', '.join(left)}. A release collects every change file it ships. {PICK_FIX}")
    if current and version(picked.release) != current:
        found.append(f"Release rule: the release commit {short(picked.release)} sets "
                     f"{version(picked.release)}, but this pull request sets {current}. {PICK_FIX}")
    return found


def release_problems(base, changed, picked=None):
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
    if picked:
        return found + picked_release_problems(picked, base, current)
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
    picked = Picked.find(base, "release" in labels)
    found = pick_problems(picked, base, "release" in labels) if picked else []
    if "release" in labels:
        return found + release_problems(base, changed, picked)
    found += ordinary_problems(base, changed)
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
    picked = Picked.find(git("merge-base", os.environ["BASE_SHA"], "HEAD").strip(), "release" in labels)
    if "release" in labels and picked:
        print(f"This release pull request sets {version_check()[0]}, adds its changelog section "
              "and collects the change files of the commits it picks from main.")
    elif "release" in labels:
        print(f"This release pull request sets {version_check()[0]}, adds its changelog section "
              "and collects every change file.")
    elif picked:
        print("This pull request merges a beta picked from the last release and changes nothing on main.")
    elif "no-changes" in labels:
        print("The no-changes label is set, so no change file is needed. "
              "The version and the CHANGELOG.md sections are unchanged.")
    else:
        print("Change files are in order. The version and the CHANGELOG.md sections are unchanged.")


if __name__ == "__main__":
    main()
