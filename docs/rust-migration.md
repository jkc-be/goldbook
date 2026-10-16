# Verify the Rust migration

Run the original behavior checks against the Rust server and sync binaries:

```sh
cargo build --locked
python3 scripts/verify-migration.py
```

Python 3 is test tooling for this check. The server and sync processes under test are Rust binaries. Install LuaJIT to regenerate the SavedVariables fixture through the real addon tests.

To test binaries outside `target/debug`, pass their paths:

```sh
python3 scripts/verify-migration.py \
  --server /path/to/goldbook-server \
  --sync /path/to/goldbook-sync
```

The script starts the server on an available localhost port with a disposable SQLite database. It generates `fixtures/Goldbook.lua`, runs the sync CLI three times, and compares the HTTP responses with `scripts/migration-baseline.json`. A failed request, sync failure, or changed response fails the command. Random session cookie values are normalized. The script still compares the cookie attributes and security headers.

The committed baseline contains 129 observations captured from the original Python server and TypeScript sync through commit `5fd05c45947e9b2d39eaa00ee1427f0052a01dbb`. The first 126 observations were captured at `f974f766f76f1992cc4233de4de3b4c703f1e117` and stayed unchanged when three realm-alias observations were added. The original implementation and the Rust binaries pass the same baseline. Legacy SQLite checks also compare scan IDs, upload times, migration records, and foreign keys.

The checks cover:

- The Lua addon's generated auction scans, characters, gold history, bags, and bank.
- Upload retries with existing sync state and after lost sync state, including exact scan IDs and account payload hashes in the state file.
- Two snapshots in the same second, including migration from timestamp-only sync state.
- All read routes, pagination, literal text search, every price sort, history, and daily trend lows.
- Thirty daily scans of 8,000 items each, with market prices borrowed from the latest full scan.
- Invalid upload tokens, malformed JSON, invalid rows, query errors, and missing resources.
- Static HTML, JavaScript, CSS, HEAD requests, and rejected file traversal.
- Anonymous reads, login normalization, rate limits, cookie attributes, secure cookies, logout, and desktop login origins.
- Account ownership, rejected takeover, key rotation, revoked sessions, and repeated gold hours.
- Display-realm aliases merged into normalized characters without losing gold history or bank snapshots.
- Existing SQLite data from before hourly gold and scan fingerprints, with account sessions preserved across migration and restart.

To check the baseline against an unchanged checkout of the original application:

```sh
git worktree add --detach /tmp/goldbook-before-rust 5fd05c45947e9b2d39eaa00ee1427f0052a01dbb
python3 scripts/verify-migration.py --old-repo /tmp/goldbook-before-rust
```

The original comparison needs Node.js 22.18 or later. Its Python server runs through the standard library WSGI server, so it needs no installed Python packages. This mode is optional and does not run in the normal Rust verification.

Use `--capture-baseline --old-repo /path/to/original` only to capture a deliberate new reference. Review any baseline change as a change to expected application behavior.

## Verification of this change

The original test suite passed before replacement. The Rust unit and integration
tests, strict Clippy checks, and all 129 baseline observations pass. The baseline
also matched the original production Waitress server. The comparison includes
240,000 price rows and an existing database upgraded and restarted in place.

The macOS Tauri debug and release app bundles were built and exercised with an isolated settings
file, temporary game folder, and local Rust server. Saving installed all addon
files and uploaded three scans and two characters. Sync now reported no new
uploads. The native folder picker opened. Open website signed the browser into
the generated account and displayed both characters. Every installed Lua file
was byte-identical to the source. A marker placed only in the disposable release
bundle's TOC appeared in the installed copy, proving that release installation
reads the bundled addon resources. The release UI also synced successfully after
the test server restarted. The marker was removed after the check.
The original game installation and production
server were unchanged.

Docker's daemon was unavailable locally, so the container image was not run here.
Windows and Linux desktop builds run in the pull-request checks. Packaged login
autostart still needs an installed-app check on each operating system.
