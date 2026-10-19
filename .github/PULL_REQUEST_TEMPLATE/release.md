<!--
Release pull request. Open it from the branch that make prepare-release
produced, with only the release label:

    gh pr create --label release --template release.md

or open https://github.com/jkc-be/goldbook/compare/main...<branch>?template=release.md&labels=release
-->

Release <version> for the addon, sync agent, server, website and desktop app.

<!-- Say in a sentence or two what this release is for. The new CHANGELOG.md section in the diff lists every change. -->

## Before merging

The `changes` check enforces the version fields, the changelog section and
the deleted change files. These need a person:

- [ ] The new `CHANGELOG.md` section reads well. Only its prose was edited.
- [ ] The version fits: a minor bump when the release adds a feature, a patch
      bump when it only fixes.
- [ ] Any compose file changes this release needs are copied to OVH.

## After merging

Merging ships nothing. The maintainer releases the merge commit, as
[docs/releasing.md](https://github.com/jkc-be/goldbook/blob/main/docs/releasing.md) describes:

1. Run `make release REVISION=<merge commit>`.
2. In **Release build**, approve `release-signing`, then `production`.
3. Answer `y` to promote. In **Release promote**, approve `production` for
   `server`, check https://app.jkc-be.com/goldbook, then approve `production`
   for `publish` and `addon-mirror` for the mirror.
4. Approve `curseforge` and, when enabled, `wowinterface` in the **Package addon
   release** run in `jkc-be/goldbook-addon`.
5. The `tag` job creates `v<version>`.
