#!/usr/bin/env python3
"""Release only the pull requests you pick, on top of the last release.

    pick-release.py list
    pick-release.py start <version> <pull request number>...
    pick-release.py finish <version>

`list` shows the commits main gained since the last release tag that no
release picked yet, oldest first, with their change files and the pull
requests their descriptions say they depend on (`Depends on #N`).

`start` creates the branch release/<version> from the last release tag, in
its own worktree under .release/, and cherry-picks the merge commit of each
pull request in the order main merged them. For a release, such as 0.6.0, it
then runs that branch's prepare-release.py, which writes the changelog
section from the picked change files and sets the version. Edit the prose and
run `finish`. A beta, such as 0.6.0-beta.1, has no changelog section, so
`start` runs `finish` itself.

`finish` commits the release, pushes it to release/<version>, which starts
its Check run, and opens the pull request that merges it into main from
release-pr/<version>. Its merge commit holds main's files with the release's
changelog section and version and without the picked change files, so a
picked release changes nothing else on main, and a beta changes nothing at
all. Merge that pull request with a merge commit: Release build requires the
commit it builds to be in main's history. Run `finish` again after editing
the prose.

See docs/releasing.md.
"""
import argparse
from dataclasses import dataclass
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "jkc-be/goldbook"
MAIN = "refs/remotes/origin/main"
WORKTREES = ".release"
RELEASE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BETA = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]*")
# A squash merge ends its title with (#N); a merge commit starts with this.
PULL = re.compile(r"\(#([0-9]+)\)$|^Merge pull request #([0-9]+) ")
# The line git cherry-pick -x adds to the message.
PICKED = re.compile(r"^\(cherry picked from commit ([0-9a-f]{40})\)$", re.MULTILINE)
DEPENDS = re.compile(r"\bdepends on #([0-9]+)", re.IGNORECASE)
# What a revision needs before Release build can build it from a release
# branch: (file, text the file must hold, what that text does).
NEEDS = [
    (".github/workflows/check.yml", "'release/**'", "runs Check on release branches"),
]
BETA_NEEDS = [
    ("scripts/set-version.py", "--stamp", "stamps a beta version"),
]
_SPEC = importlib.util.spec_from_file_location("set_version", Path(__file__).with_name("set-version.py"))
SET_VERSION = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(SET_VERSION)


class Failure(Exception):
    """A refusal, with a message that says what to do next."""


def number_of(title):
    match = PULL.search(title)
    return int(match[1] or match[2]) if match else None


def version_key(version):
    numbers = re.findall(r"[0-9]+", version)
    major, minor, patch = map(int, numbers[:3])
    # A beta sorts below its release: 0.6.0-beta.2 < 0.6.0.
    return (major, minor, patch, 0, int(numbers[3])) if "-beta." in version else (major, minor, patch, 1, 0)


class Git:
    def __init__(self, cwd):
        self.cwd = Path(cwd)

    def run(self, *args, check=True):
        result = subprocess.run(["git", *args], cwd=self.cwd, capture_output=True, text=True)
        if check and result.returncode:
            raise Failure(f"git {' '.join(args)} failed:\n{result.stderr.strip()}")
        return result

    def __call__(self, *args):
        return self.run(*args).stdout.strip()

    def ok(self, *args):
        return self.run(*args, check=False).returncode == 0


def run_gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode:
        raise Failure(f"gh {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout


@dataclass(frozen=True)
class Commit:
    """A commit of main that no release holds yet."""
    sha: str
    title: str
    number: int | None
    change_files: tuple
    depends_on: tuple
    merge: bool = False

    @property
    def name(self):
        return f"#{self.number}" if self.number else self.sha[:12]


@dataclass(frozen=True)
class Base:
    """The last release: its tag, its commit and its version."""
    tag: str
    commit: str
    version: str


class Picker:
    def __init__(self, root=ROOT, gh=run_gh, say=print):
        self.root, self.git, self.gh, self.say = Path(root), Git(root), gh, say

    # What main holds.

    def fetch(self):
        self.git("fetch", "-q", "--tags", "origin", f"+refs/heads/main:{MAIN}")

    def base(self):
        """The last release tag on main. main must hold its version: a release
        merged into main but not yet tagged must be finished first."""
        tags = [tag for tag in self.git("tag", "--list", "v[0-9]*", "--merged", MAIN).split()
                if RELEASE.fullmatch(tag[1:])]
        if not tags:
            raise Failure("main holds no release tag to pick from.")
        tag = max(tags, key=lambda tag: version_key(tag[1:]))
        committed = json.loads(self.git("show", f"{MAIN}:desktop/src-tauri/tauri.conf.json"))["version"]
        if committed != tag[1:]:
            raise Failure(f"main holds version {committed}, but the last release tag is {tag}. "
                          f"Release {committed} with make release first, or finish its promotion.")
        return Base(tag, self.git("rev-parse", f"{tag}^{{commit}}"), tag[1:])

    def descriptions(self):
        listing = json.loads(self.gh("pr", "list", "--repo", REPOSITORY, "--state", "merged", "--base", "main",
                                     "--limit", "300", "--json", "number,body"))
        return {pull["number"]: pull["body"] or "" for pull in listing}

    def unreleased(self, base):
        """The commits of main since the last release that no release picked, oldest first."""
        picked = set(PICKED.findall(self.git("log", "--format=%B", base.commit)))
        descriptions = self.descriptions()
        found = []
        for sha in self.git("rev-list", "--first-parent", "--reverse", f"{base.commit}..{MAIN}").split():
            merge = len(self.git("rev-list", "--parents", "-n", "1", sha).split()) > 2
            if sha in picked or (merge and self.merges_a_release(sha)):
                continue
            title = self.git("log", "-1", "--format=%s", sha)
            number = number_of(title)
            files = tuple(path for path in self.git("diff", "--name-only", "--diff-filter=A", f"{sha}^", sha,
                                                    "--", "changes/").split()
                          if path != "changes/README.md")
            depends = sorted({int(n) for n in DEPENDS.findall(descriptions.get(number, ""))} - {number})
            found.append(Commit(sha, title, number, files, tuple(depends), merge))
        return found

    def merges_a_release(self, sha):
        """Whether the merge commit `sha` merged the pull request of a picked
        release or beta: its second parent merges a release side that holds
        cherry-picks."""
        side = self.git("rev-list", "--parents", "-n", "1", f"{sha}^2").split()[1:]
        if len(side) != 2:
            return False
        start = self.git("merge-base", side[0], f"{sha}^1")
        return bool(PICKED.search(self.git("log", "--format=%B", f"{start}..{side[0]}")))

    def released_numbers(self, base):
        return {number for title in self.git("log", "--format=%s", base.commit).splitlines()
                if (number := number_of(title))}

    def files_of(self, sha):
        return set(self.git("diff", "--name-only", f"{sha}^", sha).split())

    def newest_tag(self):
        """The highest version any release or beta tag names."""
        versions = [tag[1:] for tag in self.git("tag", "--list", "v[0-9]*").split()
                    if RELEASE.fullmatch(tag[1:]) or BETA.fullmatch(tag[1:])]
        return max(versions, key=version_key)

    # The worktree that holds a release branch.

    def worktree(self, branch):
        current = None
        for line in self.git("worktree", "list", "--porcelain").splitlines():
            if line.startswith("worktree "):
                current = Path(line.removeprefix("worktree "))
            elif line == f"branch refs/heads/{branch}":
                return current
        return None

    def remove(self, path, branch):
        self.git.run("worktree", "remove", "--force", str(path), check=False)
        self.git.run("branch", "-D", branch, check=False)

    # Commands.

    def list(self):
        self.fetch()
        base = self.base()
        commits = self.unreleased(base)
        if not commits:
            self.say(f"main holds nothing that {base.tag} does not.")
            return
        self.say(f"Not released since {base.tag}, oldest first:\n")
        for commit in commits:
            self.say(f"  {commit.name:>6}  {commit.sha[:9]}  {commit.title}")
            for path in commit.change_files:
                self.say(f"          {path}")
            if commit.depends_on:
                self.say(f"          depends on {', '.join(f'#{n}' for n in commit.depends_on)}")
        self.say('\nPick some with: make pick-release VERSION=<x.y.z or x.y.z-beta.n> PRS="<numbers>"')

    def start(self, version, numbers):
        beta = BETA.fullmatch(version) is not None
        if not beta and not RELEASE.fullmatch(version):
            raise Failure(f"{version} is not a version such as 0.6.0 or a beta such as 0.6.0-beta.1.")
        if not numbers:
            raise Failure("Name the pull requests to pick, such as PRS=\"123 125\". "
                          "make pick-release lists them.")
        self.fetch()
        base = self.base()
        newest = self.newest_tag()
        if version_key(version) <= version_key(newest):
            raise Failure(f"{version} is not above {newest}, the newest release or beta. After a beta "
                          "x.y.z-beta.n, the next release is at least x.y.z.")
        commits = self.unreleased(base)
        by_number = {commit.number: commit for commit in commits if commit.number}
        unknown = [number for number in numbers if number not in by_number]
        if unknown:
            raise Failure(f"{', '.join(f'#{n}' for n in unknown)}: not a pull request merged into main since "
                          f"{base.tag} and not yet released. make pick-release lists them.")
        picks = [commit for commit in commits if commit.number in numbers]
        self.require_dependencies(base, picks, by_number)
        self.require_change_files(base, picks, commits)
        branch = f"release/{version}"
        if self.git.ok("rev-parse", "--verify", "--quiet", f"refs/heads/{branch}") or \
                self.git("ls-remote", "origin", f"refs/heads/{branch}"):
            raise Failure(f"{branch} already exists. If make pick-release started it, finish it with "
                          f"make pick-release-pr VERSION={version}. Otherwise pick another version, or delete "
                          "the branch, and its worktree with git worktree remove, to start it again.")
        path = self.root / WORKTREES / version
        self.git("worktree", "add", "-q", "-b", branch, str(path), base.commit)
        try:
            self.cherry_pick(Git(path), picks, commits)
            self.require(Git(path), NEEDS + (BETA_NEEDS if beta else []))
            if not beta:
                result = subprocess.run([sys.executable, "scripts/prepare-release.py", version], cwd=path,
                                        capture_output=True, text=True)
                if result.returncode:
                    raise Failure(f"prepare-release.py {version} failed:\n{(result.stderr or result.stdout).strip()}")
        except Failure:
            self.remove(path, branch)
            raise
        picked = ", ".join(commit.name for commit in picks)
        shown = path.relative_to(self.root)
        if beta:
            self.say(f"{branch} holds {picked} on top of {base.tag}.")
            try:
                return self.finish(version)
            except Failure as error:
                raise Failure(f"{error}\nThe beta's picks stay on {branch} in {shown}. "
                              f"Run make pick-release-pr VERSION={version} to try again.") from error
        self.say(f"{branch} holds {picked} on top of {base.tag}, and its CHANGELOG.md has a {version} section "
                 f"made from their change files. The worktree is {shown}.\n\n"
                 f"Edit the prose of that section in {shown}/CHANGELOG.md, then run:\n"
                 f"  make pick-release-pr VERSION={version}")

    def require_dependencies(self, base, picks, by_number):
        chosen = {commit.number for commit in picks}
        released = self.released_numbers(base)
        problems = []
        for commit in picks:
            for number in commit.depends_on:
                if number in chosen:
                    continue
                if number in by_number:
                    problems.append(f"{commit.name} depends on #{number}, which this release does not pick. "
                                    f"Pick #{number} too, or leave {commit.name} out.")
                elif number not in released:
                    problems.append(f"{commit.name} depends on #{number}, which main does not hold.")
        if problems:
            raise Failure("\n".join(problems))

    def require_change_files(self, base, picks, commits):
        """A later pull request that edits a picked change file must be picked
        too, or the release would delete its edit from main."""
        by_sha = {commit.sha: commit for commit in commits}
        problems = []
        for commit in picks:
            for path in commit.change_files:
                for sha in self.git("rev-list", "--first-parent", f"{commit.sha}..{MAIN}", "--", path).split():
                    other = by_sha.get(sha)
                    if other and other not in picks:
                        problems.append(f"{other.name} changes {path}, which {commit.name} adds. "
                                        f"Pick {other.name} too, or leave {commit.name} out.")
        if problems:
            raise Failure("\n".join(problems))

    def cherry_pick(self, work, picks, commits):
        for commit in picks:
            if work.ok("cherry-pick", "-x", *(["-m", "1"] if commit.merge else []), commit.sha):
                continue
            conflicts = set(work("diff", "--name-only", "--diff-filter=U").split())
            work.run("cherry-pick", "--abort", check=False)
            earlier = [other for other in commits[:commits.index(commit)]
                       if other not in picks and self.files_of(other.sha) & conflicts]
            hint = (f" It probably needs {', '.join(other.name for other in earlier)}, which this release does "
                    f"not pick. Pick them too, or leave {commit.name} out." if earlier else
                    f" Leave {commit.name} out, or release all of main with make prepare-release.")
            raise Failure(f"{commit.name} does not apply on top of the last release"
                          + (f": {', '.join(sorted(conflicts))} conflict." if conflicts else ".") + hint)

    def require(self, work, needs):
        for path, text, purpose in needs:
            if text in (work.cwd / path).read_text():
                continue
            added = self.git("log", "--reverse", "--format=%s", f"-S{text}", MAIN, "--", path).splitlines()
            number = number_of(added[0]) if added else None
            which = f"Pick #{number} too, which adds it." if number else "Pick the pull request that adds it."
            raise Failure(f"This release cannot be built: its {path} predates the change that {purpose}. {which}")

    def finish(self, version):
        beta = BETA.fullmatch(version) is not None
        branch, head = f"release/{version}", f"release-pr/{version}"
        path = self.worktree(branch)
        if path is None:
            raise Failure(f"No worktree holds {branch}. Start the release with "
                          f"make pick-release VERSION={version} PRS=\"<numbers>\".")
        work = Git(path)
        self.fetch()
        base = self.base()
        if not work.ok("merge-base", "--is-ancestor", base.commit, "HEAD"):
            raise Failure(f"{branch} does not start from {base.tag}, the last release. "
                          "Start it again with make pick-release.")
        pushed = self.git("ls-remote", "origin", f"refs/heads/{branch}").split()
        if pushed and self.git.ok("merge-base", "--is-ancestor", pushed[0], MAIN):
            raise Failure(f"{branch} is already merged into main. Release it with make release.")
        dirty = bool(work("status", "--porcelain"))
        commits = work("rev-list", "--reverse", f"{base.commit}..HEAD").split()
        picks = [sha for sha in commits if PICKED.search(work("log", "-1", "--format=%B", sha))]
        numbers = [number for sha in picks if (number := number_of(work("log", "-1", "--format=%s", sha)))]
        names = ", ".join(f"#{number}" for number in numbers)
        if beta:
            if dirty or commits != picks:
                raise Failure(f"{branch} holds more than cherry-picks, but a beta holds only those. "
                              "Start it again with make pick-release.")
        else:
            if dirty:
                self.require_bookkeeping(work, branch)
                work("add", "-A")
                # A prose edit after the first finish goes into the one release commit.
                amend = ["--amend"] if commits[-1:] != picks[-1:] else []
                work("commit", "-q", *amend, "-m", f"release {version}\n\nPicks {names} on top of {base.tag}.")
            self.require_release_commit(work, version, picks)
        release = work("rev-parse", "HEAD")
        main = self.git("rev-parse", MAIN)
        tree = (self.git("rev-parse", f"{main}^{{tree}}") if beta
                else self.merged_tree(version, main, work, base, release))
        merge = self.git("commit-tree", tree, "-p", release, "-p", main, "-m",
                         f"Merge {'beta' if beta else 'release'} {version} into main")
        self.push(release, branch)
        self.push(merge, head)
        url = self.open_pull_request(version, beta, head, base, release, names)
        command = f"make release REVISION={release}" + (f" BETA={version}" if beta else "")
        self.say(f"Pushed {release[:12]} to {branch}; its Check run has started.\n"
                 f"Pull request: {url}\n"
                 "Merge it with Create a merge commit, not squash or rebase. Then release it with:\n"
                 f"  {command}")

    def push(self, commit, branch):
        """Pushes `commit` to `branch`, replacing only what this clone pushed
        there last, as its remote-tracking ref records it."""
        tracked = self.git.run("rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}",
                               check=False).stdout.strip()
        result = self.git.run("push", "-q", f"--force-with-lease=refs/heads/{branch}:{tracked}", "origin",
                              f"{commit}:refs/heads/{branch}", check=False)
        if result.returncode:
            raise Failure(f"Pushing {branch} failed:\n{result.stderr.strip()}\nIf someone else pushed {branch} "
                          "since this clone last did, compare it with yours before you finish again.")

    def require_bookkeeping(self, work, branch):
        """Uncommitted changes may only be the release's own: CHANGELOG.md, the
        version fields and deleted change files."""
        versioned = {path for path, _ in SET_VERSION.FIELDS}
        stray = []
        for line in work.run("status", "--porcelain", "--untracked-files=all").stdout.splitlines():
            status, path = line[:2], line[3:]
            if not (path == "CHANGELOG.md" or path in versioned
                    or (path.startswith("changes/") and "D" in status)):
                stray.append(path)
        if stray:
            raise Failure(f"{branch} has changes beyond the changelog, the version and the change files: "
                          f"{', '.join(stray)}. Undo them; a picked release ships only the picked pull requests.")

    def require_release_commit(self, work, version, picks):
        head = work("rev-parse", "HEAD")
        if picks and head == picks[-1]:
            raise Failure(f"release/{version} has no release commit. "
                          "Start it again with make pick-release.")
        left = [path for path in work("ls-tree", "-r", "--name-only", "HEAD", "changes/").split()
                if path != "changes/README.md"]
        if left:
            raise Failure(f"The release still holds {', '.join(left)}. Its CHANGELOG.md section collects "
                          "every change file; start it again with make pick-release.")
        if not re.search(rf"^## {re.escape(version)} - ", (work.cwd / "CHANGELOG.md").read_text(), re.MULTILINE):
            raise Failure(f"CHANGELOG.md has no \"## {version} - \" section. Start it again with make pick-release.")
        committed = json.loads((work.cwd / "desktop/src-tauri/tauri.conf.json").read_text())["version"]
        if committed != version:
            raise Failure(f"The release sets version {committed}, not {version}. Start it again with make pick-release.")

    def merged_tree(self, version, main, work, base, release):
        """main's files with the release's changelog section and version, and
        without the change files the release picked."""
        changelog = (work.cwd / "CHANGELOG.md").read_text()
        section = re.search(rf"^## {re.escape(version)} - .*?(?=^## |\Z)", changelog, re.MULTILINE | re.DOTALL)[0]
        shipped = set(work("log", "--format=", "--name-only", "--diff-filter=A",
                           f"{base.commit}..{release}", "--", "changes/").split()) - {"changes/README.md"}
        path = self.root / WORKTREES / f"{version}-merge"
        self.git.run("worktree", "remove", "--force", str(path), check=False)
        self.git("worktree", "add", "-q", "--detach", str(path), main)
        try:
            merge = Git(path)
            result = subprocess.run([sys.executable, "scripts/set-version.py", version], cwd=path,
                                    capture_output=True, text=True)
            if result.returncode:
                raise Failure(f"set-version.py {version} failed on main:\n{(result.stderr or result.stdout).strip()}")
            text = (path / "CHANGELOG.md").read_text()
            newest = re.search(r"^## ", text, re.MULTILINE)
            (path / "CHANGELOG.md").write_text(text[:newest.start()] + section + text[newest.start():])
            for file in sorted(shipped):
                if (path / file).exists():
                    merge("rm", "-q", file)
            merge("add", "-A")
            return merge("write-tree")
        finally:
            self.git.run("worktree", "remove", "--force", str(path), check=False)

    def open_pull_request(self, version, beta, head, base, release, names):
        if beta:
            title, labels = f"beta {version}", "no-changes"
            body = (f"Beta {version} of {names}, picked on top of {base.tag}.\n\n"
                    f"The beta builds `{release}` from `release/{version}`. This pull request "
                    "puts that commit in main's history, which Release build requires, and changes no "
                    "file on main.\n\n"
                    "Merge it with **Create a merge commit**. A squash or rebase merge leaves the beta's "
                    "commit out of main's history.\n\n"
                    "## After merging\n\n"
                    "Merging ships nothing. The maintainer releases the beta, as "
                    f"[docs/releasing.md](https://github.com/{REPOSITORY}/blob/main/docs/releasing.md) "
                    f"describes:\n\n```sh\nmake release REVISION={release} BETA={version}\n```\n")
        else:
            title, labels = f"release {version}", "release"
            body = (f"Release {version} of {names}, picked on top of {base.tag}.\n\n"
                    f"The release builds `{release}` from `release/{version}`. This pull request "
                    "merges it into main with its changelog section and version, and deletes the change "
                    "files it picked. The other change files stay on main for a later release.\n\n"
                    "## Before merging\n\n"
                    "- [ ] The new `CHANGELOG.md` section reads well. Only its prose was edited.\n"
                    "- [ ] The version fits: a minor bump when the release adds a feature, a patch\n"
                    "      bump when it only fixes.\n"
                    "- [ ] Any compose file changes this release needs are copied to OVH.\n\n"
                    "Merge it with **Create a merge commit**. A squash or rebase merge leaves the release "
                    "commit out of main's history, and Release build refuses it.\n\n"
                    "## After merging\n\n"
                    "Merging ships nothing. The maintainer releases the release commit, as "
                    f"[docs/releasing.md](https://github.com/{REPOSITORY}/blob/main/docs/releasing.md) "
                    f"describes:\n\n```sh\nmake release REVISION={release}\n```\n")
        found = json.loads(self.gh("pr", "list", "--repo", REPOSITORY, "--head", head, "--state", "open",
                                   "--json", "url"))
        if found:
            # A new release commit, after a prose edit, changes the command in the body.
            self.gh("pr", "edit", found[0]["url"], "--repo", REPOSITORY, "--body", body)
            return found[0]["url"]
        return self.gh("pr", "create", "--repo", REPOSITORY, "--base", "main", "--head", head,
                       "--title", title, "--label", labels, "--body", body).strip()


def main(argv=None, picker=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List the commits of main that no release holds")
    start = commands.add_parser("start", help="Pick pull requests onto release/<version>")
    start.add_argument("version", help="Version, such as 0.6.0, or beta, such as 0.6.0-beta.1")
    start.add_argument("numbers", nargs="*", type=lambda text: int(text.lstrip("#")),
                       help="Pull request numbers, such as 123 or #123")
    finish = commands.add_parser("finish", help="Push release/<version> and open its pull request")
    finish.add_argument("version")
    args = parser.parse_args(argv)
    picker = picker or Picker()
    try:
        if args.command == "list":
            picker.list()
        elif args.command == "start":
            picker.start(args.version, args.numbers)
        else:
            picker.finish(args.version)
    except Failure as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
