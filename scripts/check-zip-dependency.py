#!/usr/bin/env python3
"""Reject ZIP versions affected by the updater archive security advisories."""
import argparse
from pathlib import Path
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
FIXED = (9, 0, 5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lockfile", nargs="?", type=Path, default=ROOT / "Cargo.lock")
    args = parser.parse_args()
    with args.lockfile.open("rb") as source:
        packages = tomllib.load(source)["package"]
    versions = [package["version"] for package in packages if package["name"] == "zip"]
    for version in versions:
        stable = version.split("+", 1)[0]
        if "-" in stable or tuple(map(int, stable.split("."))) < FIXED:
            sys.exit(f"Unsafe zip {version} in {args.lockfile}; require stable zip 9.0.5 or newer.")
    print(f"ZIP security check passed: {', '.join(versions) if versions else 'no ZIP dependency'}.")


if __name__ == "__main__":
    main()
