#!/usr/bin/env python3
"""Print Makefile command help without running a command."""
import argparse
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def commands():
    result, detail = {}, []
    for line in (ROOT / "Makefile").read_text().splitlines():
        if line.startswith("#| "):
            detail.append(line[3:])
            continue
        match = re.fullmatch(r"([a-zA-Z_ -]+):.*## (.+)", line)
        if match:
            for target in match[1].split():
                result[target] = (match[2], "\n".join(detail))
        detail = []
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="*", help="Commands to describe; omit to list all commands")
    args = parser.parse_args()
    targets = args.targets or os.environ.get("GOLDBOOK_HELP_TARGETS", "").split()
    available = commands()
    unknown = [target for target in targets if target not in available]
    if unknown:
        parser.error(f"Unknown command: {', '.join(unknown)}. Run make help to list commands.")
    if targets:
        for target in dict.fromkeys(targets):
            summary, detail = available[target]
            print(f"make {target} - {summary}\n\n{detail}\n")
        return
    print("Usage: make <target> [VARIABLE=value]\n")
    for target, (summary, _) in available.items():
        print(f"  {target:18} {summary}")
    print("\nCommand help, without running it:\n"
          "  make help release             Usage, options, effects and examples\n"
          "  make help-release             Same help\n"
          "  make release HELP=1           Same help\n"
          "  make help build install-addon Help for several commands\n\n"
          "Make owns --help: make release --help shows Make's own help.\n"
          "Use VARIABLE=value for command options; see each command's help.\n\n"
          "Common examples:\n"
          "  make install-addon WOW=\"/Applications/World of Warcraft\"\n"
          "  make reset-local DRY_RUN=1\n"
          "  make prepare-release VERSION=1.2.3\n"
          "  make release REVISION=1a2b3c4\n\n"
          "Release preparation edits this checkout; release starts GitHub workflows.\n"
          "Read make help release before starting a release.")


if __name__ == "__main__":
    main()
