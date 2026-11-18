# Rules for coding agents

- Branch from `main` and open one pull request per change. Run `make check`
  before you push; the pre-push hook from `make hooks` runs it too.
- Add a file under `changes/` for anything a player or user would notice, as
  [changes/README.md](changes/README.md) describes. Give refactors, tests and
  CI pull requests the `no-changes` label instead. The `changes` check
  enforces this.
- Never edit version fields or `CHANGELOG.md`, except in a release pull
  request. Prepare the kind of release the maintainer asks for. To release
  all of `main`, branch from `main`, run `make prepare-release VERSION=x.y.z`,
  edit the new section's prose, and open the pull request with the `release`
  label and nothing else in it. To release only the pull requests the
  maintainer names, run `make pick-release VERSION=x.y.z PRS="<numbers>"`,
  edit the prose in `.release/x.y.z/CHANGELOG.md`, and run
  `make pick-release-pr VERSION=x.y.z`, which opens the pull request. No
  other pull request edits the version or the changelog, and the `no-changes`
  label does not exempt one. The `changes` check enforces this too.
- A release ships the pull requests the maintainer picks, so a pull request
  may merge before its feature is finished. Each pull request must still
  pass `make check`, and work on top of the last release together with only
  the unreleased pull requests it names. Write `Depends on #N` in its
  description for each one it needs; `make pick-release` refuses to pick it
  without them. A beta of a commit of `main` ships all of it, unfinished work
  included, to the players who turned betas on. No beta deploys the server.
- A feature may sit behind a flag, such as an `ns.features` table in the
  addon, a Rust constant in the desktop app, or an environment variable read
  at server startup that defaults to off. A disabled feature changes nothing.
  Its migrations, background tasks and startup code are either absent until
  the feature is switched on, or proven harmless to existing data and
  requests by a test.
- Server changes stay compatible with every client and addon version at or
  above the support floor, the oldest version under `fixtures/clients/`. The
  server deploys before clients update, and users can skip releases.
- Never run **Release build**, **Release promote** or any other release
  workflow, never approve an environment deployment, and never
  create `v*` tags. Preparing a release pull request ships nothing; the
  maintainer merges it and runs the release.
