#!/usr/bin/env python3
"""Fail a pull request that changes the product without a change file.

    BASE_SHA=<base commit> LABELS='["no-changes"]' python3 scripts/check-changes.py

Compares HEAD with where it left BASE_SHA. A pull request labelled no-changes
passes. Otherwise one that touches a product folder must add a change file, and
every change file it adds or edits must be well formed. See changes/README.md.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prepare_release", ROOT / "scripts/prepare-release.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)
PRODUCT = ("addon/", "desktop/", "web/", "crates/", "server/")


def problems(base):
    diff = subprocess.run(["git", "diff", "--name-status", "--no-renames", f"{base}...HEAD"],
                          cwd=ROOT, check=True, capture_output=True, text=True).stdout
    changed = [line.split("\t", 1) for line in diff.splitlines()]
    changes = [(status, path) for status, path in changed
               if path.startswith("changes/") and path != "changes/README.md"]
    found = [PREPARE.problem(path.removeprefix("changes/"), (ROOT / path).read_text())
             for status, path in changes if status != "D"]
    product = [path for _, path in changed if path.startswith(PRODUCT)]
    if product and not any(status == "A" for status, _ in changes):
        more = f" and {len(product) - 1} more files" if len(product) > 1 else ""
        found.append(f"This pull request changes {product[0]}{more} but adds no change file. "
                     "Add changes/<section>-<slug>.md as changes/README.md describes, "
                     "or the no-changes label if no player or user would notice.")
    return [problem for problem in found if problem]


def main():
    if "no-changes" in json.loads(os.environ.get("LABELS") or "[]"):
        print("The no-changes label is set, so no change file is needed.")
        return
    found = problems(os.environ["BASE_SHA"])
    if found:
        # Actions reads workflow commands from stdout and shows them on the pull request.
        actions = os.environ.get("GITHUB_ACTIONS") == "true"
        for problem in found:
            print("::error::" + problem if actions else problem, file=sys.stdout if actions else sys.stderr)
        sys.exit(1)
    print("Change files are in order.")


if __name__ == "__main__":
    main()
