# Security

Report vulnerabilities through GitHub's private vulnerability reporting form
at https://github.com/jkc-be/goldbook/security/advisories/new. Do not publish
credentials, account snapshots, or exploit details in public issues.

Only @jkc-be administers this repository. Production deployment and signing
credentials are environment secrets, available only to approved jobs on main.
See [repository administration](docs/repository-administration.md) for setup,
verification, and the limits of these controls.

## Client connections

Remote Goldbook servers must use HTTPS. The desktop app and sync CLI allow
plain HTTP only for `localhost` and loopback IP addresses. Those local requests
bypass environment proxies. API clients refuse redirects so upload credentials,
account data, and sign-in tokens stay with the configured server.

## Windows updater archives

Tauri updater 2.14.1 moves its Windows ZIP dependency from 4.x to 9.x.
Goldbook requires at least that updater release and locks ZIP to a patched
version. ZIP 9.0.5 fixes
[GHSA-m665-v7pm-7grj](https://github.com/advisories/GHSA-m665-v7pm-7grj)
and includes the earlier archive extraction fixes in 9.0.0.

`scripts/check-zip-dependency.py` rejects ZIP versions older than 9.0.5 and
prereleases in the shared lockfile. It runs in `make check` and the Windows
desktop test job. The updater continues to verify update signatures before
extracting or installing packages.

`desktop/src-tauri/tests/updater_zip.rs` exercises the same `ZipArchive::extract`
API as the Windows updater. It checks that oversized symlink targets are
rejected before filesystem operations, that symlinks cannot escape the update
directory, and that ordinary archives still extract. Both symlink checks fail
against the old ZIP 4.6.1.

## GLib security backport

Tauri 2 and its GTK 3 dependencies require GLib 0.18. The registry release
0.18.5 is affected by
[RUSTSEC-2024-0429](https://rustsec.org/advisories/RUSTSEC-2024-0429.html).
`vendor/glib` contains that release with the two-line
[upstream fix](https://github.com/gtk-rs/gtk-rs-core/pull/1343) applied to
`src/variant_iter.rs`. The out-parameter is mutable and passed as `&mut p`,
which prevents undefined behavior when the iterator reads a string.

The copy comes from the crates.io `glib-0.18.5.crate` archive, with SHA-256
`233daaf6e83ae6a12a52055f568f9d7cf4671dabb78ff9560ab6da230ce00ee5`.
Its source, metadata, tests, MIT license, and copyright notice are otherwise
unchanged. The workspace patch applies to every dependency on GLib 0.18.
The version stays 0.18.5 to reflect the source and preserve GTK compatibility;
version-only scanners may still report the advisory.

`desktop/src-tauri/tests/glib_variant.rs` exercises every affected iterator
operation. The test profile compiles GLib with optimization level 2, where
the original implementation fails. The Linux desktop test job runs it on
pull requests without building installers or using production secrets.

CodeQL alert [7](https://github.com/jkc-be/goldbook/security/code-scanning/7)
reports a write after `drop_in_place` in `PtrSlice::truncate`. The drop releases
the element's object, while the slice still owns the allocation holding its
pointer slots. The following `ptr::write` sets a slot to null without reading or
dropping its previous value, as permitted by Rust's
[`drop_in_place` contract](https://doc.rust-lang.org/std/ptr/fn.drop_in_place.html#safety).
`desktop/src-tauri/tests/glib_ptr_slice.rs` checks object lifetimes, null
termination, and reuse of the same allocation after truncation. This finding is
a false positive; the upstream collection implementation is unchanged.

Whenever Tauri or its GTK dependencies are updated, check for a compatible,
patched GLib release from crates.io. When one is supported, use that upstream
release and remove the vendored copy, Cargo patch, and test profile override.
Do not replace the copy with unpatched 0.18.5 or suppress the advisory without
verifying the resolved source.
