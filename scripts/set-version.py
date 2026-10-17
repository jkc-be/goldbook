#!/usr/bin/env python3
"""Set the client and addon version everywhere a release reads it.

    python3 scripts/set-version.py 0.1.5

The desktop updater compares tauri.conf.json, the addon feed reads the TOC,
and npm and Cargo refuse a lock file that disagrees with its manifest. Each
file is edited in place, so its formatting stays as it is.
"""
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


def replace(path, pattern, version, count):
    """Sets the version group of each match of `pattern` in `path`; `count`
    matches are expected, so that a moved field fails loudly."""
    file = ROOT / path
    text = file.read_text()
    updated, found = re.subn(pattern, lambda m: m.group(1) + version + m.group(2), text, flags=re.MULTILINE)
    if found != count:
        sys.exit(f"{path}: expected {count} version field(s), found {found}")
    file.write_text(updated)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(VERSION, sys.argv[1]):
        sys.exit("usage: scripts/set-version.py <major.minor.patch>, such as 0.1.5")
    version = sys.argv[1]
    replace("package.json", rf'(\A\{{\n  "name": "goldbook",\n  "version": "){VERSION}(")', version, 1)
    replace("package-lock.json", rf'(\A\{{\n  "name": "goldbook",\n  "version": "){VERSION}(")', version, 1)
    replace("package-lock.json", rf'(^    "": \{{\n      "name": "goldbook",\n      "version": "){VERSION}(")', version, 1)
    replace("desktop/src-tauri/tauri.conf.json", rf'(^  "version": "){VERSION}(")', version, 1)
    replace("addon/Goldbook/Goldbook.toc", rf"(^## Version: ){VERSION}()$", version, 1)
    for name, manifest in CRATES.items():
        replace(manifest, rf'(\A\[package\]\n(?:\w[\w-]* = .*\n)*?name = "{name}"\nversion = "){VERSION}(")', version, 1)
        replace("Cargo.lock", rf'(^name = "{name}"\nversion = "){VERSION}(")', version, 1)
    # Fails if Cargo.lock still disagrees with a manifest.
    subprocess.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    print(f"Set the client and addon version to {version}.")


if __name__ == "__main__":
    main()
