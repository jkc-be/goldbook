#!/usr/bin/env python3
"""Run the local suite, including real HTTP and SQLite integration tests."""
from pathlib import Path
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Also check Rust formatting and clippy")
    args = parser.parse_args()
    commands = []
    if args.check:
        commands.append(["cargo", "fmt", "--all", "--check"])
    commands.extend(["luajit", f"addon/tests/{name}.lua"]
                    for name in ("run", "scanner", "sellers", "orderbook", "professions", "trades", "mail", "accounting", "auctionhouse"))
    commands.append([sys.executable, "-m", "unittest", "discover", "-s", "addon/tests", "-p", "test_*.py"])
    commands.append(["cargo", "test", "--locked"])
    if args.check:
        commands.append(["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"])
    commands.append(["cargo", "build", "--locked"])
    commands.extend([sys.executable, f"scripts/verify-{name}.py"]
                    for name in ("migration", "sellers", "trades", "professions", "proxy", "server-data",
                                 "client-compatibility"))
    commands.append([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests"])
    for command in commands:
        print("\n> " + " ".join(command), flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
    subprocess.run([sys.executable, "scripts/sandbox.py", "--smoke"], cwd=ROOT, check=True)
    print("\nLocal suite passed. HTTP tests used disposable databases and loopback servers.")


if __name__ == "__main__":
    main()
