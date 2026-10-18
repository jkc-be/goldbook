# Repository administration

The canonical source repository is https://github.com/jkc-be/goldbook. It contains
the desktop app, server, browser UI, addon, and their tests. Its public history
starts with a reviewed source snapshot. Private history, local databases,
SavedVariables, and credentials are excluded.

## Main branch

Keep @jkc-be as the only repository administrator. Contributors work through
forks and pull requests. `CODEOWNERS` assigns every file to @jkc-be.

The `main` ruleset restricts branch creation and updates to repository
administrators. It requires a pull request, code-owner approval, resolved review
threads, and the `test`, `local-stack`, and `secrets` checks for anyone without
bypass permission. The sole administrator can merge or push directly and can
bypass those review and check requirements. A separate rule blocks force pushes
and deletion for everyone, including the administrator. Changing that rule
requires an explicit settings change.

Do not grant another person admin access unless they should have equivalent
control. GitHub administrators can change repository rules and environments.
Auto-merge is disabled. GitHub Actions receives a read-only token by default
and cannot approve pull requests. External contributors need approval to run
fork pull-request workflows; approving CI does not approve a deployment.

Apply or verify these settings with the owner's authenticated GitHub CLI:

```sh
python3 scripts/configure-github.py
python3 scripts/configure-github.py --check
```

## Secrets and approvals

| Environment | Secrets | Reviewer | Allowed branch |
| --- | --- | --- | --- |
| `production` | `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_KNOWN_HOSTS`, `DEPLOY_SSH_KEY` | `jkc-be` | `main` |
| `release-signing` | `TAURI_SIGNING_PRIVATE_KEY` | `jkc-be` | `main` |
| `addon-mirror` | `ADDON_MIRROR_SSH_KEY` | `jkc-be` | `main` |

Administrator bypass is disabled for all three environments. Self-review is allowed
so the sole maintainer can approve a workflow they started. Only the listed
reviewer can approve. Jobs cannot receive environment secrets before approval.
No repository-level secrets are used. The `ci` environment contains no secrets
and is used for unsigned desktop builds.

GitHub does not reveal stored secret values through its UI or API, even to the
owner. The owner can replace them. Approved jobs can read them, so review the
commit, workflow, dependencies, scripts, and artifact paths before approval.
Masking is not a substitute for that review: public workflow logs and artifacts
are visible to contributors. Do not print credentials or upload configuration
files. All referenced Actions are pinned to commit SHAs, checkouts do not retain
credentials, and ordinary CI uses GitHub-hosted runners without production access.

Secret scanning and push protection are enabled. Gitleaks scans committed history
in CI with a pinned binary checksum. Its allowlist covers only the synthetic
account credential and its hash in named test files; test folders remain scanned.

## OVH setup and deployment

The existing OVH application settings and database stay on OVH. The Actions SSH
key has a forced command and cannot open a shell, forward ports, or run arbitrary
commands. The helper verifies the GitHub repository, main branch, workflow path,
revision, and initiating and rerunning maintainer identities before an operation.

After configuring GitHub, install the restricted helper and generate its key:

```sh
bash scripts/setup-deploy.sh <your-OVH-SSH-alias>
gh secret set TAURI_SIGNING_PRIVATE_KEY --repo jkc-be/goldbook --env release-signing < /path/to/existing-signing.key
```

Keep the existing signing key for updater compatibility. Never commit it.
`setup-deploy.sh` installs `/opt/goldbook/deploy-public.py` and replaces only the
key marked `goldbook-public-github-actions`. It stores the private key directly
in the protected `production` environment and deletes its temporary local copy.
Before it installs the helper, it checks that the SSH user can read
`/opt/goldbook/data/goldbook.sqlite` and creates `/opt/goldbook/backups` with
mode 700. Rerun it after every change to `scripts/deploy-ovh.py`; the server
keeps running the helper it last installed.

The helper accepts four commands, each given a workflow run ID and a commit
SHA. The run must be the one that built what is being shipped.

| Command | Accepted workflows | Effect |
| --- | --- | --- |
| `verify` | `deploy.yml`, `release-build.yml` | Pulls and checks the run's image and the running service. Changes nothing. |
| `deploy` | `deploy.yml`, `release-build.yml` | Backs up the database, then replaces the running image with the run's image. |
| `check-publish` | `release-desktop.yml`, `update-addon.yml`, `release-build.yml` | Downloads and validates the run's update feed. Changes nothing. |
| `publish` | `release-desktop.yml`, `update-addon.yml`, `release-build.yml` | Validates and publishes the run's update feed. |

The run's image is the one it pushed, not whatever its commit's tag points at
now, because another run for the same commit can push the tag again. The run
must have exactly one unexpired `Goldbook-server-image` artifact holding only
`image.json`, `{"revision": "<commit SHA>", "digest": "sha256:<64 hex digits>"}`.
The helper refuses the run when the revision differs from the command's or the
digest is malformed. It pulls `ghcr.io/jkc-be/goldbook-server@<digest>`, checks
that its `org.opencontainers.image.revision` label is the commit, and pins that
digest in `GOLDBOOK_IMAGE`. A **Deploy to OVH** run from before this artifact
existed cannot deploy; start a new run.

A feed must come from a run with exactly one unexpired `Goldbook-update-feed`
artifact. A `release-desktop.yml` feed publishes `latest.json` and its package
folder, an `update-addon.yml` feed publishes `addon.json`, and a
`release-build.yml` feed publishes `latest.json`, its package folder and
`addon.json`. The helper rejects the feed before
it replaces anything when a manifest is missing, a package is missing, the
revision already has different packages, or a manifest is older than the one
already published. A `latest.json` is older when its `version` is lower; an
`addon.json` is older when the `sequence` in its signed payload is lower. An
equal version or sequence is accepted, so a retry can publish again. A missing
or unreadable published manifest counts as nothing published. It moves the package folder into
place first, then replaces `latest.json`, then `addon.json`. Publishing the same
run again after an interruption finishes the publication with the same files.
`check-publish` runs every one of these checks and prints
`{"checked": [...], "revision": ...}`; `publish` prints
`{"published": [...], "revision": ...}`.

Use **Actions > Deploy to OVH > Run workflow** on `main`. The default
`verify_only` option builds and pushes `ghcr.io/jkc-be/goldbook-server`, records
the pushed digest as the run's `Goldbook-server-image` artifact, checks the
restricted SSH connection, pulls and validates that image, and checks the
running service without replacing it. Approve the `production` job after
reviewing the run. Uncheck `verify_only` for a deployment. That copies the
database through SQLite's backup API to
`/opt/goldbook/backups/goldbook-<stamp>-<revision>.sqlite`, stops before changing
the configuration or the service when the copy fails `PRAGMA integrity_check`, pins the image digest,
waits for health, and restores the previous image and configuration on startup
failure. The result line names the copy as `database_backup`. The helper does
not roll back database migrations. To restore the database, stop the service,
delete any `goldbook.sqlite-wal` and `goldbook.sqlite-shm` files beside the
database, copy the backup over `/opt/goldbook/data/goldbook.sqlite`, set `GOLDBOOK_IMAGE`
back from the `.env.before-<stamp>-*` file with the same stamp, and start the
service. The helper does not delete old backups.

The server retains its Compose files. Review and copy Compose changes separately
before deploying an image that depends on them. Deployment and update publication
use separate locks. Desktop releases and addon publication require signing
approval followed by production publication approval. The public source import
does not itself require publishing a new release.

GitHub documents [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
and [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
Public visibility still permits viewing and forking under
[GitHub's terms](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository);
the all-rights-reserved license does not make this open source.

## Addon distribution mirror

`jkc-be/goldbook-addon` is generated from this repository's `addon/` directory.
After a push to main changes the addon, approve **Mirror addon** in the
`addon-mirror` environment. The workflow uses a dedicated write deploy key for
the addon repository. It cannot deploy to OVH or sign client updates.

The addon repository's main branch permits updates only by the sole maintainer
or this deploy key. Force pushes and deletion are blocked, including for the
mirror. It has one write deploy key, titled `Mirror from public Goldbook`; do
not add other write keys unless they should also be allowed to mirror updates.
The former private-upstream mirror workflow is disabled and its key revoked.

The target's **Package addon release** workflow uses its own GitHub token to
publish an installable ZIP. It does not have production or signing secrets.
The workflow verifies byte-for-byte equality on retries and rejects overwriting
an existing version with different contents. Source ZIPs from GitHub have an
extra directory and must not be uploaded to CurseForge.

The mirror stores `CURSEFORGE_API_TOKEN` only in its `curseforge` environment.
That environment permits the `main` branch, requires approval by `jkc-be`, and
disables administrator bypass. There are no repository-level secrets. The
release workflow accepts only runs initiated and rerun by `jkc-be`; the
existing mirror key's pushes are attributed to that account. Tests and GitHub
packaging run before the separate job can receive the CurseForge token.

Only `jkc-be` is a collaborator, and the mirror key is the only write deploy
key. Public contributors can fork and propose pull requests, but cannot push
to this repository, merge changes, edit secrets, or approve publishing jobs.
External pull-request workflows require approval and receive no CurseForge
secret. GitHub Actions has read-only permissions by default and cannot approve
pull requests.

Public workflow logs remain readable. Keep secrets out of commands, source,
artifacts, and error messages even though GitHub masks registered secret
values. The uploader sends the token in a header, suppresses HTTP response
bodies and network error details, and refuses redirects. Review publishing
code before approving a run; approved code can use the environment secret.

Read back the mirror's access controls and secret placement with:

```sh
python3 scripts/check-addon-github.py
```
