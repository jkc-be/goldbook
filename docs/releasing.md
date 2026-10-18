# Releasing Goldbook

A release is two manual runs on `main`. **Release build** tests one commit,
builds and signs everything, and checks OVH access without changing anything.
**Release promote** takes that build run's ID and ships exactly its artifacts:
the server first, then the update feed, then the addon mirror. It then waits
for goldbook-addon's own release and tags the commit.

Only `jkc-be` starts these workflows and approves their environments.

![How a Goldbook release works](release-flow/overview.png)

The examples use illustrative PR and run numbers.

- [Several agent PRs become one release](release-flow/example-release.png)
- [Finishing a stopped promotion, and what the guards refuse](release-flow/example-stops.png)
- [Hotfixes](release-flow/example-hotfixes.png)

The diagrams are the four pages of `docs/release-flow.drawio`. After editing it
in draw.io, export each page again, numbered from 1:

```sh
drawio -x -f png -s 1.25 --theme light -b 10 -p 1 -o docs/release-flow/overview.png docs/release-flow.drawio
```

## Release outputs

A release has six outputs. `scripts/release-state.py` reads five of them and
accepts each one only when it belongs to the build run being promoted.

| Output | Read from | Belongs to the build run when |
| --- | --- | --- |
| Server deploy | Not read | Deploying the same image again is harmless. |
| Client feed | `https://app.jkc-be.com/goldbook/updates/latest.json` | It is byte for byte the build run's `latest.json`. |
| Addon feed | `https://app.jkc-be.com/goldbook/updates/addon.json` | It is byte for byte the build run's `addon.json`. |
| Addon mirror | `jkc-be/goldbook-addon` HEAD | Its `upstream.json` names the revision. |
| Downstream addon release | Release `v<version>` in `jkc-be/goldbook-addon` | Its tag's commit has an `upstream.json` that names the revision. |
| Source tag | `v<version>` in `jkc-be/goldbook` | It points at the revision. |

Each output is reported as one of three states:

- `absent`: the output does not exist, or it holds an older release.
- `matches`: the output belongs to this build run.
- `conflict`: the output holds this version from another build, or a newer
  version. A conflict stops the run and needs a decision from you.

goldbook-addon is read through GitHub's public API without credentials,
because the workflow token reaches only its own repository. Unauthenticated
requests share a limit of 60 per hour per runner address. If a busy runner
address hits it, the job fails without changing anything and can be rerun.

## Build

1. Merge the release PR that `make prepare-release VERSION=<version>` produced.
2. Open **Actions > Release build > Run workflow** on `main`.
3. Approve `release-signing` once for the three installer jobs and the addon
   signing job, which wait together.
4. Approve `production` for the `verify` job.
5. Note the run ID. The `verify` summary lists the revision, the version, and
   the ID and digest of every artifact.

The `guard` job refuses to build when:

- the run is a rerun. Start a new Release build run instead.
- `scripts/set-version.py --check` finds version fields that disagree.
- `CHANGELOG.md` has no `## <version> - ` section, or `changes/` still holds
  change files.
- any output of this version is not `absent`. When the version is partly
  released, the message names the build run to promote. When it is fully
  released or no build run can finish it, the message asks for a new version.

A build run proves:

- the checks of `check.yml` pass for the commit
- the installers build and are signed
- the addon update is signed
- the feed has the layout the OVH helper accepts
- the helper accepts this build run (`verify`), and its feed passes the
  helper's validation (`check-publish`)
- the image is pushed and OVH can pull it
- the deployment is authorized

A build run does not start the candidate server or apply its migrations to
production data. The running service is checked, not replaced.

A failed build run is never rerun. Rerunning all jobs or only the failed jobs
fails at `guard` or `verify`, and promote refuses any run attempt after the
first. Start a new build run. Nothing was shipped, so nothing is lost.

Build artifacts are kept for 30 days, so a build run can be promoted for 30
days.

## Promote

1. Open **Actions > Release promote > Run workflow** on `main` and enter the
   build run ID.
2. Approve `production` for `server`. Its result line names the database
   backup. Check `https://app.jkc-be.com/goldbook`.
3. Approve `production` for `publish`.
4. Approve `addon-mirror` for the mirror.
5. Approve `curseforge` in the **Package addon release** run in
   `jkc-be/goldbook-addon`.
6. The `tag` job creates `v<version>` on the built commit.

The jobs, in order:

| Job | Does |
| --- | --- |
| `guard` | Requires a successful first attempt of `release-build.yml` on `main` by `jkc-be` with its feed, addon feed and three updater artifacts unexpired. Checks out the built revision, reads its version, downloads its `Goldbook-update-feed` and requires every output to be `absent` or `matches`. |
| `server` | Runs the helper's `check-publish`, then `deploy`, for the build run and its revision. The deploy is skipped once the build's `latest.json` is published, because the feed is published only after that deploy succeeded. |
| `publish` | Runs the helper's `publish` for the build run. |
| `mirror` | Pushes the revision's `addon/` to goldbook-addon, or confirms that HEAD already holds it. |
| `addon-release` | Waits for goldbook-addon's **Package addon release** run for the mirror commit, including its CurseForge job. It polls every 3 minutes for at most 120 minutes. |
| `tag` | Creates `v<version>` at the revision. A tag already on that commit passes. |

Promote and **Deploy to OVH** share the concurrency group
`goldbook-production`, so they never run at the same time. GitHub keeps one
running and one pending run per group, and a newer pending run cancels the
older pending one.

Promote builds and uploads nothing. Running it again for a finished release
passes every job and changes nothing.

Promote does not create a GitHub release page in `jkc-be/goldbook`. Releases
before 0.2.5 had one made by hand. Create it after the tag if you want one.

## Finish a promotion that stopped partway

Run **Release promote** again with the same `build_run_id`, or rerun the
stopped promote run. Both are safe:

- promote builds nothing
- the helper accepts a second publish of the same files
- the mirror makes no commit when nothing changed
- the tag job accepts a tag already on the same commit

| Stopped after | A second promotion |
| --- | --- |
| Server deployed | Deploys the same image again, then continues. |
| `latest.json` published | Skips the deploy and publishes the same feed again. |
| Both manifests published | Skips the deploy, publishes again and mirrors. |
| Mirror pushed | Finds HEAD already holding the revision and waits for its run. |
| Downstream run failed | Fails at `addon-release` with the run's link. Rerun the failed jobs of that run in goldbook-addon. When it succeeds, rerun promote. |
| Downstream run succeeded | Tags the commit. |
| Tagged | Passes every job without changes. |

`main` may have moved on in the meantime. A promotion always ships its build
run's revision, never the current `main`.

After 30 days the build run's artifacts expire. A partly promoted release
cannot be finished after that, and the next release needs a new version.

## Database backups and restore

A real deploy takes a verified database backup before the new image starts and
prints its path as `database_backup`, such as
`/opt/goldbook/backups/goldbook-<stamp>-<revision>.sqlite`. The helper restores
the previous image when the new one fails its health check. It does not roll
back migrations, and it does not delete old backups.

To recover the database:

1. Stop the service.
2. Delete any `goldbook.sqlite-wal` and `goldbook.sqlite-shm` files beside the
   database.
3. Copy the backup over `/opt/goldbook/data/goldbook.sqlite`.
4. Set `GOLDBOOK_IMAGE` back from the `/opt/goldbook/.env.before-<stamp>-*`
   file with the backup's stamp.
5. Start the service.

Compose file changes are still copied to OVH by hand before a release that
needs them.

## Version numbers

You choose the version in the release PR. A release with only fixes bumps the
patch number. A release with new features bumps the minor number. The desktop
updater installs only a higher version than the one installed, and
goldbook-addon refuses to reuse a version with different contents, so every
release needs a new version.

## Hotfixes

When `main` is releasable, a hotfix is a fix PR with a change file, a release
PR with a patch bump, a build and a promotion.

A fix that touches only the server can go out through **Deploy to OVH**. It
runs the full checks for its commit first and shares the promotion lock.

When `main` is not releasable, either switch off or revert the unfinished work
and release as above, or add release branches. A release branch is
`release/x.y`, created from the last tag, with the fix cherry-picked onto it,
built and promoted from that branch. Release branches require changes to:

- the environment branch policies in `scripts/configure-github.py`
- the job conditions in every workflow
- the `head_branch` check in `scripts/deploy-ovh.py`
- `docs/repository-administration.md`

Add them the first time you need one. After a branch release, the next release
from `main` bumps at least the minor number.
