#!/usr/bin/env python3
"""Set the client and addon version everywhere a release reads it.

    python3 scripts/set-version.py 0.1.5
    python3 scripts/set-version.py --check   prints the version, or fails naming the files that differ

The desktop updater compares tauri.conf.json, the addon feed reads the TOC,
the website's title bar shows it as the addon's does, and npm and Cargo
refuse a lock file that disagrees with its manifest. Each
file is edited in place, so its formatting stays as it is.
"""
from collections import Counter
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CRATES = {
    "goldbook-core": "crates/goldbook-core/Cargo.toml",
    "goldbook-server": "crates/goldbook-server/Cargo.toml",
    "goldbook-sync": "crates/goldbook-sync/Cargo.toml",
    "goldbook-desktop": "desktop/src-tauri/Cargo.toml",
}
VERSION = r"\d+\.\d+\.\d+"
# Each version field: its file and a pattern whose two groups surround the version.
FIELDS = [
    ("package.json", rf'(\A\{{\n  "name": "goldbook",\n  "version": "){VERSION}(")'),
    ("package-lock.json", rf'(\A\{{\n  "name": "goldbook",\n  "version": "){VERSION}(")'),
    ("package-lock.json", rf'(^    "": \{{\n      "name": "goldbook",\n      "version": "){VERSION}(")'),
    ("desktop/src-tauri/tauri.conf.json", rf'(^  "version": "){VERSION}(")'),
    ("addon/Goldbook/Goldbook.toc", rf"(^## Version: ){VERSION}()$"),
    ("web/index.html", rf'(<span class="version">){VERSION}(</span>)'),
]
for name, manifest in CRATES.items():
    FIELDS.append((manifest, rf'(\A\[package\]\n(?:\w[\w-]* = .*\n)*?name = "{name}"\nversion = "){VERSION}(")'))
    FIELDS.append(("Cargo.lock", rf'(^name = "{name}"\nversion = "){VERSION}(")'))


def replace(path, pattern, version, count):
    """Sets the version group of each match of `pattern` in `path`; `count`
    matches are expected, so that a moved field fails loudly."""
    file = ROOT / path
    text = file.read_text()
    updated, found = re.subn(pattern, lambda m: m.group(1) + version + m.group(2), text, flags=re.MULTILINE)
    if found != count:
        sys.exit(f"{path}: expected {count} version field(s), found {found}")
    file.write_text(updated)


def check():
    versions = []
    for path, pattern in FIELDS:
        text = (ROOT / path).read_text()
        found = [text[m.end(1):m.start(2)] for m in re.finditer(pattern, text, flags=re.MULTILINE)]
        if len(found) != 1:
            sys.exit(f"{path}: expected 1 version field(s), found {len(found)}")
        versions.append((path, found[0]))
    counts = Counter(version for _, version in versions)
    common = counts.most_common(1)[0][0]
    if len(counts) > 1:
        differ = sorted({f"{path} has {version}" for path, version in versions if version != common})
        sys.exit(f"The version fields disagree with {common}: " + ", ".join(differ))
    print(common)


def main():
    if sys.argv[1:] == ["--check"]:
        return check()
    if len(sys.argv) != 2 or not re.fullmatch(VERSION, sys.argv[1]):
        sys.exit("usage: scripts/set-version.py <major.minor.patch>, such as 0.1.5, or --check")
    version = sys.argv[1]
    for path, pattern in FIELDS:
        replace(path, pattern, version, 1)
    # Fails if Cargo.lock still disagrees with a manifest.
    subprocess.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    print(f"Set the client and addon version to {version}.")


if __name__ == "__main__":
    main()
