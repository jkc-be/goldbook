#!/usr/bin/env python3
"""List or block upload fingerprints or Battle.net identities in a deployed database."""

import argparse
from pathlib import Path
import re
import sqlite3
import sys


def fingerprint(value):
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise argparse.ArgumentTypeError("fingerprint must be 64 lowercase hexadecimal characters")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--identity-type", choices=("fingerprint", "battlenet"), default="fingerprint")
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("list")
    for command in ("block", "unblock"):
        commands.add_parser(command).add_argument("fingerprint", type=fingerprint)
    args = parser.parse_args(argv)
    if not args.database.is_file():
        parser.error("database must be an existing file")
    try:
        with sqlite3.connect(args.database.resolve().as_uri() + "?mode=rw", uri=True, timeout=30) as db:
            db.execute("PRAGMA foreign_keys=ON")
            battlenet = args.identity_type == "battlenet"
            table = "battlenet_identities" if battlenet else "upload_identities"
            column = "identity_hash" if battlenet else "fingerprint"
            if args.command in (None, "list"):
                print(f"{column}\tblocked\ttokens\tactive_tokens" + ("" if battlenet else "\tplayer_hash"))
                query = """
                    SELECT i.fingerprint, i.blocked_at IS NOT NULL OR b.blocked_at IS NOT NULL, count(t.token_hash),
                           coalesce(sum(t.token_hash IS NOT NULL AND t.revoked_at IS NULL AND i.blocked_at IS NULL AND b.blocked_at IS NULL),0),
                           coalesce(i.battlenet_identity,'')
                    FROM upload_identities i LEFT JOIN upload_tokens t USING (fingerprint)
                    LEFT JOIN battlenet_identities b ON b.identity_hash=i.battlenet_identity
                    GROUP BY i.fingerprint ORDER BY i.fingerprint
                """
                if battlenet:
                    query = """
                        SELECT b.identity_hash, b.blocked_at IS NOT NULL, count(t.token_hash),
                               coalesce(sum(t.token_hash IS NOT NULL AND t.revoked_at IS NULL AND i.blocked_at IS NULL AND b.blocked_at IS NULL),0)
                        FROM battlenet_identities b
                        LEFT JOIN upload_identities i ON i.battlenet_identity=b.identity_hash
                        LEFT JOIN upload_tokens t USING (fingerprint)
                        GROUP BY b.identity_hash ORDER BY b.identity_hash
                    """
                for row in db.execute(query):
                    print(f"{row[0]}\t{'yes' if row[1] else 'no'}\t{row[2]}\t{row[3]}" + ("" if battlenet else f"\t{row[4]}"))
                return 0
            db.execute("BEGIN IMMEDIATE")
            if args.command == "block":
                db.execute(f"""
                    INSERT INTO {table} ({column},blocked_at) VALUES (?,unixepoch())
                    ON CONFLICT({column}) DO UPDATE
                    SET blocked_at=coalesce(blocked_at,excluded.blocked_at)
                """, (args.fingerprint,))
            else:
                updated = db.execute(f"UPDATE {table} SET blocked_at=NULL WHERE {column}=?",
                                     (args.fingerprint,))
                if updated.rowcount == 0:
                    raise ValueError(f"{column} is unknown; nothing was unblocked")
            db.commit()
            print(f"{args.fingerprint}\t{'blocked' if args.command == 'block' else 'unblocked'}")
    except (sqlite3.Error, ValueError) as error:
        print(f"upload-access: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
