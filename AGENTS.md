# Rules for coding agents

- Branch from `main` and open one pull request per change. Run `make check`
  before you push; the pre-push hook from `make hooks` runs it too.
- Add a file under `changes/` for anything a player or user would notice, as
  [changes/README.md](changes/README.md) describes. Give refactors, tests, CI
  and release pull requests the `no-changes` label instead. The `changes`
  check enforces this.
- Never edit version fields or `CHANGELOG.md`. The release pull request does
  that with `make prepare-release`.
- Every pull request must be safe to release on its own. Keep new work
  unwired until it is complete, such as an endpoint nobody calls or a view
  missing from the rail. A change that alters existing behavior before it is
  complete goes behind a flag. The first pull request that needs a flag adds
  the mechanism for its component: an `ns.features` table in the addon, a
  Rust constant in the desktop app, or an environment variable read at server
  startup that defaults to off.
- A disabled feature changes nothing. Its migrations, background tasks and
  startup code are either absent until the feature is switched on, or proven
  harmless to existing data and requests by a test.
- Server changes stay compatible with every client and addon version at or
  above the support floor, the oldest version under `fixtures/clients/`. The
  server deploys before clients update, and users can skip releases.
- Never run **Release build**, **Release promote** or **Deploy to OVH**, never
  approve an environment deployment, and never create `v*` tags.
