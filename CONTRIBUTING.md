# Contributing

Goldbook is source available under an all-rights-reserved license. Public
visibility does not grant an open-source license. See [LICENSE](LICENSE).
Ask @jkc-be for written permission before preparing code changes; describe the
proposed change in an issue first. Do not submit third-party code without its
license and permission to distribute it.

Contributors use forks and pull requests. @jkc-be owns every file and controls
merges and direct pushes to main. Run `make check` before submitting changes.
Pull-request CI uses disposable data and has no production or signing secrets.
External contributors' workflow runs require maintainer approval.

Each pull request describes a change that players or users would notice in a
file under `changes/`, as [changes/README.md](changes/README.md) describes,
and leaves `CHANGELOG.md` and the version fields alone; the release pull
request writes those. [AGENTS.md](AGENTS.md) lists the rules every pull
request follows, whether a person or a coding agent wrote it.

Never include real SavedVariables files, database copies, credentials, or
private keys in an issue, pull request, log, or artifact. Report security
issues using the repository's private vulnerability reporting form.
