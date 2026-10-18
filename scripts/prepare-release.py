#!/usr/bin/env python3
"""Turn the change files into a changelog section and set the version.

    python3 scripts/prepare-release.py 0.2.5

Refuses before writing anything when the version fields disagree, when
changes/ holds no change file, when a change file is malformed, or when the
version is not higher than the current one. Then sets the version with
set-version.py, inserts `## <version> - <today>` above the newest release in
CHANGELOG.md with one heading per section, and deletes the change files.
Open the result as a pull request with the release label; the changes check
refuses any other pull request that edits the version or CHANGELOG.md.
"""
import datetime
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CHANGES = ROOT / "changes"
CHANGELOG = ROOT / "CHANGELOG.md"
# Change file prefix and changelog heading, in the order a release lists them.
SECTIONS = {"addon": "Addon", "app": "Desktop app", "website": "Website", "server": "Server", "build": "Build"}
VERSION = r"\d+\.\d+\.\d+"


def change_files():
    return sorted(path for path in CHANGES.iterdir() if path.name != "README.md")


def problem(name, text):
    """What is wrong with the change file `name`, relative to changes/, or None."""
    match = re.fullmatch(r"([a-z]+)-[a-z0-9][a-z0-9-]*\.md", name)
    if not match:
        return f"changes/{name}: name it <section>-<slug>.md, with a lowercase slug"
    if match.group(1) not in SECTIONS:
        return f"changes/{name}: unknown section {match.group(1)}; use one of {', '.join(SECTIONS)}"
    if not text.strip():
        return f"changes/{name}: the file is empty; write one or more Markdown bullets"
    if not text.lstrip().startswith("- "):
        return f"changes/{name}: start with a Markdown bullet, \"- \""
    return None


def section(files):
    lines = []
    for prefix, heading in SECTIONS.items():
        bodies = [path.read_text().strip() for path in files if path.name.startswith(prefix + "-")]
        if bodies:
            lines += [f"### {heading}", "", *bodies, ""]
    return "\n".join(lines)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(VERSION, sys.argv[1]):
        sys.exit("usage: scripts/prepare-release.py <major.minor.patch>, such as 0.2.5")
    version = sys.argv[1]
    check = subprocess.run([sys.executable, ROOT / "scripts/set-version.py", "--check"],
                           capture_output=True, text=True)
    if check.returncode:
        sys.exit(check.stderr.strip())
    current = check.stdout.strip()
    if tuple(map(int, version.split("."))) <= tuple(map(int, current.split("."))):
        sys.exit(f"{version} is not higher than the current version {current}")
    files = change_files()
    if not files:
        sys.exit("changes/ holds no change files; there is nothing to release")
    problems = [p for p in (problem(path.name, path.read_text() if path.is_file() else "") for path in files) if p]
    if problems:
        sys.exit("\n".join(problems))
    changelog = CHANGELOG.read_text()
    newest = re.search(r"^## ", changelog, flags=re.MULTILINE)
    if not newest:
        sys.exit("CHANGELOG.md has no release heading to insert above")

    subprocess.run([sys.executable, ROOT / "scripts/set-version.py", version], check=True)
    entry = f"## {version} - {datetime.date.today().isoformat()}\n\n{section(files)}\n"
    CHANGELOG.write_text(changelog[:newest.start()] + entry + changelog[newest.start():])
    for path in files:
        path.unlink()
    print(f"Added {version} to CHANGELOG.md from {len(files)} change files, and deleted them.\n"
          "Edit the new section's prose, commit, push, and open the pull request with\n"
          "gh pr create --label release --template release.md")


if __name__ == "__main__":
    main()
