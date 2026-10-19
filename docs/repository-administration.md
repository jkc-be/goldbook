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
threads, and the `test`, `local-stack`, `secrets`, `desktop-tests`, and `changes`
checks for anyone without bypass permission. `changes` enforces the change file,
version, changelog and release rules in [changes/README.md](../changes/README.md);
it reads the `no-changes` and `release` labels. The sole administrator can merge or push directly and can
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

A newly required check counts only once it has reported on a pull request's
head commit. After the script adds a required check, every open pull request
needs one new push, such as a rebase or an empty commit, before it can merge.

## Secrets and approvals

| Environment | Secrets | Reviewer | Allowed branch |
| --- | --- | --- | --- |
| `production` | `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_KNOWN_HOSTS`, `DEPLOY_SSH_KEY` | `jkc-be` | `main` |
| `release-signing` | `TAURI_SIGNING_PRIVATE_KEY` | `jkc-be` | `main` |
| `addon-mirror` | `ADDON_MIRROR_SSH_KEY` | `jkc-be` | `main` |

`release-signing` signs the installers and the addon update in **Release
build**. `production` approves **Deploy to OVH**, the `verify` job of
**Release build**, and the `server` and `publish` jobs of **Release promote**.
`addon-mirror` approves the mirror push in **Release promote**.

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
SHA. The run must be the one that built what is being shipped. Its head commit
must be that SHA or a later commit that contains it, as GitHub's compare API
reports, so a **Release build** can build an earlier commit of `main` than the
one `main` pointed at when the run started.

| Command | Accepted workflows | Effect |
| --- | --- | --- |
| `verify` | `deploy.yml`, `release-build.yml` | Pulls and checks the run's image and the running service, and reports whether `deploy` would replace it. Changes nothing. |
| `deploy` | `deploy.yml`, `release-build.yml` | When the commit is newer than the running one, backs up the database, then replaces the running image with the run's image. |
| `check-publish` | `release-build.yml` | Downloads and validates the run's update feed. Changes nothing. |
| `publish` | `release-build.yml` | Validates and publishes the run's update feed. |

The run's image is the one it pushed, not whatever its commit's tag points at
now, because another run for the same commit can push the tag again. The run
must have exactly one unexpired `Goldbook-server-image` artifact holding only
`image.json`, `{"revision": "<commit SHA>", "digest": "sha256:<64 hex digits>"}`.
The helper refuses the run when the revision differs from the command's or the
digest is malformed. It pulls `ghcr.io/jkc-be/goldbook-server@<digest>`, checks
that its `org.opencontainers.image.revision` label is the commit, and pins that
digest in `GOLDBOOK_IMAGE`. A **Deploy to OVH** run from before this artifact
existed cannot deploy; start a new run.

A deploy never moves the server back to an older commit. After the checks
above, the helper reads the `org.opencontainers.image.revision` label of the
running container and asks GitHub how the requested commit relates to it:

- The running commit is the requested one, or is newer and contains it, for
  example after a **Deploy to OVH** hotfix. `deploy` changes nothing and takes
  no backup. It fails when the running server is not healthy, and otherwise
  prints `{"skipped": true, "revision": ..., "active_revision": ...,
  "active_image": ..., "health": "healthy"}`. `verify` prints
  `"would_deploy": false`.
- The requested commit is newer and contains the running one. `deploy` goes
  ahead, and `verify` prints `"would_deploy": true`.
- The two commits have diverged. Both commands refuse and name both commits.

Both commands also refuse when the running image has no such label, for example
an image built on the server. Reconcile by hand: set `GOLDBOOK_IMAGE` to a
labelled image, such as the one the last deploy pinned, and restart the service.

A feed must come from a run with exactly one unexpired `Goldbook-update-feed`
artifact. Only a `release-build.yml` feed is accepted, and it publishes
`latest.json`, its package folder and `addon.json`. The helper rejects the feed before
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

**Deploy to OVH** first runs every check in `check.yml` for the same commit and
builds the image only when they pass. It shares the concurrency group
`goldbook-production` with **Release promote**, so a server-only deploy and a
promotion never interleave.

The server retains its Compose files. Review and copy Compose changes separately
before deploying an image that depends on them. On OVH, deployment and update
publication use separate locks. Releases go through **Release build** and
**Release promote**, described in [releasing](releasing.md). The SSH handling
for all three workflows lives in the composite action `.github/actions/ovh`.
Build artifacts are kept for 30 days, which is how long a build run can be
promoted. The public source import does not itself require publishing a new
release.

GitHub documents [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
and [environment protection](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
Public visibility still permits viewing and forking under
[GitHub's terms](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository);
the all-rights-reserved license does not make this open source.

## Addon distribution mirror

`jkc-be/goldbook-addon` is generated from this repository's `addon/` directory.
**Release promote** mirrors the released commit through the called **Mirror
addon** workflow, which has no trigger of its own; approve it in the
`addon-mirror` environment. The workflow uses a dedicated write deploy key for
the addon repository. It cannot deploy to OVH or sign client updates. Its push
starts the target's **Package addon release** workflow, which Release promote
waits for before it tags the release.

The addon repository's main branch permits updates only by the sole maintainer
or this deploy key. Force pushes and deletion are blocked, including for the
mirror. It has one write deploy key, titled `Mirror from public Goldbook`; do
not add other write keys unless they should also be allowed to mirror updates.
The former private-upstream mirror workflow is disabled and its key revoked.

The target's **Package addon release** workflow uses its own GitHub token to
publish an installable ZIP. It does not have production or signing secrets.
The workflow verifies byte-for-byte equality on retries and rejects overwriting
an existing version with different contents. Source ZIPs from GitHub have an
extra directory and must not be uploaded to CurseForge or WoWInterface.

The mirror stores `CURSEFORGE_API_TOKEN` only in its `curseforge` environment
and `WOWINTERFACE_API_TOKEN` only in its `wowinterface` environment. Both
environments permit the `main` branch, require approval by `jkc-be`, and
disable administrator bypass. The repository variable
`WOWINTERFACE_PROJECT_ID` enables WoWInterface publishing after the first
entry is created through its website. Wago Addons takes releases through a
webhook on `release` events to `https://addons.wago.io/api/github/webhook`.
The workflow's own Wago uploads are off until the repository variable
`WAGO_UPLOAD` is `true`; then `WAGO_API_TOKEN` lives only in a `wago`
environment with the same rules. Turn them on only after deleting the webhook,
or each release reaches Wago twice. There are no repository-level secrets. The
release workflow accepts only runs initiated and rerun by `jkc-be`; the
existing mirror key's pushes are attributed to that account. Tests and GitHub
packaging run before each publishing job can receive its token. WoWInterface
runs in a separate workflow after the CurseForge workflow succeeds, with its
own concurrency group. Release promotion waits only for the primary
GitHub/CurseForge workflow.

Only `jkc-be` is a collaborator, and the mirror key is the only write deploy
key. Public contributors can fork and propose pull requests, but cannot push
to this repository, merge changes, edit secrets, or approve publishing jobs.
External pull-request workflows require approval and receive no publishing
secrets. GitHub Actions has read-only permissions by default and cannot approve
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
